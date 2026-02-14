// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.0;

import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {V3Path} from "@uniswap/universal-router/contracts/modules/uniswap/v3/V3Path.sol";
import {BytesLib} from "@uniswap/universal-router/contracts/modules/uniswap/v3/BytesLib.sol";
import {SafeCast} from "@uniswap/v3-core/contracts/libraries/SafeCast.sol";
import {CalldataDecoder} from "@uniswap/v4-periphery/src/libraries/CalldataDecoder.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {MaxInputAmount} from "briefcase/protocols/universal-router/libraries/MaxInputAmount.sol";
import {Quote, Pool, V2, V3, V4} from "../base/OnchainRouterStructs.sol";
import {UniswapV2Library} from "../libraries/UniswapV2Library.sol";
import "./OnchainRouterImmutables.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams as V4SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";

/// @title Swap Executor for Uniswap V2, V3, and V4 Trades
/// @notice Handles the execution of swaps across Uniswap V2, V3, and V4 protocols
abstract contract SwapExecutor is OnchainRouterImmutables, IUnlockCallback {
    /// @dev Uniswap V3 pool initialization code hash used for pool address computation
    bytes32 private constant UNISWAP_V3_POOL_INIT_CODE_HASH =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    /// @dev Uniswap V2 pair initialization code hash used for pair address computation
    bytes32 private constant UNISWAP_V2_PAIR_INIT_CODE_HASH =
        0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

    /// @dev The minimum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MIN_TICK)
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;

    /// @dev The maximum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MAX_TICK)
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    using V3Path for bytes;
    using BytesLib for bytes;
    using CalldataDecoder for bytes;
    using SafeCast for uint256;

    error V3InvalidSwap();
    error V2TooMuchRequested();
    error V3TooMuchRequested();
    error V4TooMuchRequested();
    error TooLittleReceived();
    error V3InvalidAmountOut();
    error V3InvalidCaller();
    error V4InvalidCaller();

    // ─────────────────────────────────────────────────────────────
    //  Exact Input
    // ─────────────────────────────────────────────────────────────

    function _swapExactInput(Quote memory quote, address recipient) internal returns (uint256 amountOut) {
        if (_hasV4Hop(quote)) {
            bytes memory result = poolManager.unlock(abi.encode(quote, recipient, true));
            amountOut = abi.decode(result, (uint256));
        } else {
            amountOut = _swapExactInputDirect(quote, recipient);
        }
    }

    function _swapExactInputDirect(Quote memory quote, address recipient) private returns (uint256 amountOut) {
        uint256 amountIn = quote.amountIn;
        for (uint256 i = 0; i < quote.path.length; i++) {
            Pool memory pool = quote.path[i];
            address currentRecipient = i < quote.path.length - 1 ? address(this) : recipient;

            if (pool.version == V3) {
                amountIn = _v3SwapExactInput(quote, amountIn, currentRecipient, i);
            } else if (pool.version == V2) {
                amountIn = _v2SwapExactInput(pool, amountIn, currentRecipient);
            }
        }
        amountOut = amountIn;
        if (amountOut < quote.amountOut) revert TooLittleReceived();
    }

    // ─────────────────────────────────────────────────────────────
    //  Exact Output
    // ─────────────────────────────────────────────────────────────

    function _swapExactOutput(Quote memory quote, address recipient) internal returns (uint256 amountIn) {
        if (_hasV4Hop(quote)) {
            bytes memory result = poolManager.unlock(abi.encode(quote, recipient, false));
            amountIn = abi.decode(result, (uint256));
        } else {
            MaxInputAmount.set(quote.amountIn);
            amountIn = _swapExactOutputHop(quote, quote.amountOut, recipient, quote.path.length - 1);
            MaxInputAmount.set(0);
        }
    }

    function _swapExactOutputHop(Quote memory quote, uint256 amountOut, address recipient, uint256 pathIndex)
        private
        returns (uint256 amountIn)
    {
        Pool memory pool = quote.path[pathIndex];
        if (pool.version == V3) {
            amountIn = _v3SwapExactOutput(quote, amountOut, recipient, pathIndex);
        } else if (pool.version == V2) {
            amountIn = _v2SwapExactOutput(quote, amountOut, recipient, pathIndex);
        } else if (pool.version == V4) {
            amountIn = _v4SwapExactOutputHop(quote, amountOut, recipient, pathIndex);
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  V4 Unlock Callback
    // ─────────────────────────────────────────────────────────────

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert V4InvalidCaller();
        (Quote memory quote, address recipient, bool isExactInput) = abi.decode(data, (Quote, address, bool));

        if (isExactInput) {
            return abi.encode(_unlockExactInput(quote, recipient));
        } else {
            MaxInputAmount.set(quote.amountIn);
            uint256 amountIn = _swapExactOutputHop(quote, quote.amountOut, recipient, quote.path.length - 1);
            MaxInputAmount.set(0);
            return abi.encode(amountIn);
        }
    }

    function _unlockExactInput(Quote memory quote, address recipient) private returns (uint256 amountOut) {
        uint256 amountIn = quote.amountIn;
        for (uint256 i = 0; i < quote.path.length; i++) {
            Pool memory pool = quote.path[i];
            address currentRecipient = i < quote.path.length - 1 ? address(this) : recipient;

            if (pool.version == V4) {
                amountIn = _v4SwapExactInput(pool, amountIn, currentRecipient, i < quote.path.length - 1);
            } else if (pool.version == V3) {
                amountIn = _v3SwapExactInput(quote, amountIn, currentRecipient, i);
            } else if (pool.version == V2) {
                amountIn = _v2SwapExactInput(pool, amountIn, currentRecipient);
            }
        }
        amountOut = amountIn;
        if (amountOut < quote.amountOut) revert TooLittleReceived();
    }

    // ─────────────────────────────────────────────────────────────
    //  V4 Swap Execution
    // ─────────────────────────────────────────────────────────────

    function _v4SwapExactInput(Pool memory pool, uint256 amountIn, address recipient, bool isIntermediate)
        private
        returns (uint256 amountOut)
    {
        address weth = intermediateToken;
        PoolKey memory key = _buildV4PoolKey(pool);
        bool zeroForOne = Currency.wrap(pool.tokenIn) < Currency.wrap(pool.tokenOut);
        Currency inputCurrency = Currency.wrap(pool.tokenIn);
        Currency outputCurrency = Currency.wrap(pool.tokenOut);

        // Pre-swap: unwrap WETH→ETH if V4 pool uses native ETH for input
        if (inputCurrency.isAddressZero()) {
            IWETH9(weth).withdraw(amountIn);
        }

        // V4 convention: negative amountSpecified = exact input
        BalanceDelta delta = poolManager.swap(
            key,
            V4SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        // Determine actual amounts from delta
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        // Settle input (negative delta = we owe pool manager)
        uint256 inputAmount = uint256(uint128(zeroForOne ? -delta0 : -delta1));
        _v4Settle(inputCurrency, inputAmount);

        // Take output (positive delta = pool manager owes us)
        amountOut = uint256(uint128(zeroForOne ? delta1 : delta0));
        poolManager.take(outputCurrency, isIntermediate ? address(this) : recipient, amountOut);

        // Post-swap: wrap ETH→WETH if output is native ETH and we need ERC20 for next hop
        if (outputCurrency.isAddressZero() && isIntermediate) {
            IWETH9(weth).deposit{value: amountOut}();
        }
    }

    function _v4SwapExactOutputHop(Quote memory quote, uint256 amountOut, address recipient, uint256 pathIndex)
        private
        returns (uint256 amountIn)
    {
        Pool memory pool = quote.path[pathIndex];
        address weth = intermediateToken;
        PoolKey memory key = _buildV4PoolKey(pool);
        bool zeroForOne = Currency.wrap(pool.tokenIn) < Currency.wrap(pool.tokenOut);
        Currency inputCurrency = Currency.wrap(pool.tokenIn);
        Currency outputCurrency = Currency.wrap(pool.tokenOut);

        // V4 convention: positive amountSpecified = exact output
        BalanceDelta delta = poolManager.swap(
            key,
            V4SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(amountOut),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        amountIn = uint256(uint128(zeroForOne ? -delta0 : -delta1));

        // Get input tokens: either from previous hop or from initial funds
        if (pathIndex > 0) {
            _swapExactOutputHop(quote, amountIn, address(this), pathIndex - 1);
        } else {
            if (amountIn > MaxInputAmount.get()) revert V4TooMuchRequested();
        }

        // Pre-settle: unwrap WETH→ETH if V4 pool uses native ETH for input
        if (inputCurrency.isAddressZero()) {
            IWETH9(weth).withdraw(amountIn);
        }

        // Settle input
        _v4Settle(inputCurrency, amountIn);

        // Take output
        uint256 outputAmount = uint256(uint128(zeroForOne ? delta1 : delta0));
        poolManager.take(outputCurrency, recipient, outputAmount);

        // Post-take: wrap ETH→WETH if recipient is this contract and output is native ETH
        if (outputCurrency.isAddressZero() && recipient == address(this)) {
            IWETH9(weth).deposit{value: outputAmount}();
        }
    }

    function _v4Settle(Currency currency, uint256 amount) private {
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            SafeTransferLib.safeTransfer(ERC20(Currency.unwrap(currency)), address(poolManager), amount);
            poolManager.settle();
        }
    }

    function _buildV4PoolKey(Pool memory pool) private pure returns (PoolKey memory) {
        Currency c0 = Currency.wrap(pool.tokenIn);
        Currency c1 = Currency.wrap(pool.tokenOut);
        if (c0 > c1) {
            (c0, c1) = (c1, c0);
        }
        return PoolKey({
            currency0: c0, currency1: c1, fee: pool.fee, tickSpacing: pool.tickSpacing, hooks: IHooks(pool.hooks)
        });
    }

    function _hasV4Hop(Quote memory quote) private pure returns (bool) {
        for (uint256 i = 0; i < quote.path.length; i++) {
            if (quote.path[i].version == V4) return true;
        }
        return false;
    }

    // ─────────────────────────────────────────────────────────────
    //  V2 Swap Execution (unchanged)
    // ─────────────────────────────────────────────────────────────

    function _v2SwapExactInput(Pool memory pool, uint256 amountIn, address recipient)
        private
        returns (uint256 amountOut)
    {
        SafeTransferLib.safeTransfer(ERC20(pool.tokenIn), pool.pool, amountIn);
        IUniswapV2Pair pair = IUniswapV2Pair(pool.pool);
        (address token0,) = UniswapV2Library.sortTokens(pool.tokenIn, pool.tokenOut);
        (uint256 reserve0, uint256 reserve1,) = IUniswapV2Pair(pair).getReserves();
        (uint256 reserveIn, uint256 reserveOut) = pool.tokenIn == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
        amountOut = UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut);

        (uint256 amount0Out, uint256 amount1Out) =
            pool.tokenIn == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
        pair.swap(amount0Out, amount1Out, recipient, new bytes(0));
    }

    // ─────────────────────────────────────────────────────────────
    //  V3 Swap Execution (unchanged)
    // ─────────────────────────────────────────────────────────────

    function _v3SwapExactInput(Quote memory quote, uint256 amountIn, address recipient, uint256 pathIndex)
        private
        returns (uint256 amountOut)
    {
        Pool memory pool = quote.path[pathIndex];
        bool zeroForOne = pool.tokenIn < pool.tokenOut;
        (int256 amount0Delta, int256 amount1Delta) = IUniswapV3Pool(pool.pool)
            .swap(
                recipient,
                zeroForOne,
                int256(amountIn),
                (zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1),
                abi.encode(quote, pathIndex, true)
            );

        amountOut = zeroForOne ? uint256(-amount1Delta) : uint256(-amount0Delta);
    }

    function _v3SwapExactOutput(Quote memory quote, uint256 amountOut, address recipient, uint256 pathIndex)
        internal
        returns (uint256 amountIn)
    {
        Pool memory pool = quote.path[pathIndex];
        bool zeroForOne = pool.tokenIn < pool.tokenOut;
        (int256 amount0Delta, int256 amount1Delta) = IUniswapV3Pool(pool.pool)
            .swap(
                recipient,
                zeroForOne,
                -int256(amountOut),
                (zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1),
                abi.encode(quote, pathIndex, false)
            );

        uint256 amountOutReceived = zeroForOne ? uint256(-amount1Delta) : uint256(-amount0Delta);
        amountIn = zeroForOne ? uint256(amount0Delta) : uint256(amount1Delta);

        if (amountOutReceived != amountOut) revert V3InvalidAmountOut();
    }

    function _v2SwapExactOutput(Quote memory quote, uint256 amountOut, address recipient, uint256 pathIndex)
        internal
        returns (uint256 amountIn)
    {
        Pool memory pool = quote.path[pathIndex];

        IUniswapV2Pair pair = IUniswapV2Pair(pool.pool);
        (address token0,) = UniswapV2Library.sortTokens(pool.tokenIn, pool.tokenOut);
        (uint256 reserve0, uint256 reserve1,) = IUniswapV2Pair(pair).getReserves();
        (uint256 reserveIn, uint256 reserveOut) = pool.tokenIn == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
        amountIn = UniswapV2Library.getAmountIn(amountOut, reserveIn, reserveOut);

        if (pathIndex > 0) {
            _swapExactOutputHop(quote, amountIn, pool.pool, pathIndex - 1);
        } else {
            if (amountIn > MaxInputAmount.get()) revert V2TooMuchRequested();
            SafeTransferLib.safeTransfer(ERC20(pool.tokenIn), pool.pool, amountIn);
        }

        (uint256 amount0Out, uint256 amount1Out) =
            pool.tokenIn == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
        pair.swap(amount0Out, amount1Out, recipient, new bytes(0));
    }

    // ─────────────────────────────────────────────────────────────
    //  V3 Callback (unchanged)
    // ─────────────────────────────────────────────────────────────

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (amount0Delta <= 0 && amount1Delta <= 0) revert V3InvalidSwap();
        (Quote memory quote, uint256 pathIndex, bool isExactInput) = abi.decode(data, (Quote, uint256, bool));

        Pool memory pool = quote.path[pathIndex];

        if (pool.pool != msg.sender) revert V3InvalidCaller();
        (uint256 amountToPay) = amount0Delta > 0 ? (uint256(amount0Delta)) : (uint256(amount1Delta));

        if (isExactInput) {
            SafeTransferLib.safeTransfer(ERC20(pool.tokenIn), msg.sender, amountToPay);
        } else {
            if (pathIndex > 0) {
                _swapExactOutputHop(quote, amountToPay, msg.sender, pathIndex - 1);
            } else {
                if (amountToPay > MaxInputAmount.get()) revert V3TooMuchRequested();
                SafeTransferLib.safeTransfer(ERC20(pool.tokenIn), msg.sender, amountToPay);
            }
        }
    }
}
