// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.0;

import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {MaxInputAmount} from "briefcase/protocols/universal-router/libraries/MaxInputAmount.sol";
import {Quote, Pool, V2, V3, V4} from "../base/OnchainRouterStructs.sol";
import {UniswapV2Library} from "../libraries/UniswapV2Library.sol";
import {OnchainRouterImmutables} from "./OnchainRouterImmutables.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams as V4SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";

/// @title Swap Executor for Uniswap V2, V3, and V4 Trades
/// @notice Executes multi-hop swaps across V2, V3, and V4 pools.
/// @dev V4 Strategy: if any hop is V4, the entire swap is wrapped in poolManager.unlock().
/// Inside the unlock callback, V2/V3 hops execute normally (direct token transfers / V3 callbacks).
/// V4 hops use poolManager.swap() with flash accounting: settle input, take output.
///
/// Native ETH: V4 pools may use Currency.wrap(address(0)) instead of WETH. At V4 hop boundaries,
/// the executor unwraps WETH→ETH before native ETH settlement and wraps ETH→WETH after native
/// ETH output when the next hop needs an ERC20.
///
/// V4 sign convention: negative amountSpecified = exact input, positive = exact output.
/// BalanceDelta: negative = owed by swapper (settle), positive = owed to swapper (take).
abstract contract SwapExecutor is OnchainRouterImmutables, IUnlockCallback {
    uint160 private constant MIN_SQRT_RATIO = 4295128739;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    error V3InvalidSwap();
    error V2TooMuchRequested();
    error V3TooMuchRequested();
    error V4TooMuchRequested();
    error TooLittleReceived();
    error V3InvalidAmountOut();
    error V4InvalidAmountOut();
    error V3IncompleteInput();
    error V4IncompleteInput();
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

    /// @dev CAUTION: for multihop paths the returned amountIn is the LAST hop's input,
    /// denominated in that hop's input token (the intermediate), NOT the caller's input
    /// token. Earlier hops' inputs are paid inside callbacks/recursion and are not
    /// aggregated here. Do not use this return value for user-facing accounting; derive
    /// realized input from a balance delta instead (see OnchainRouter).
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
        PoolKey memory key = pool.key;
        bool zeroForOne = Currency.wrap(pool.tokenIn) < Currency.wrap(pool.tokenOut);
        Currency inputCurrency = Currency.wrap(pool.tokenIn);
        Currency outputCurrency = Currency.wrap(pool.tokenOut);

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

        // A hop can consume less than it was funded when the pool's liquidity in this
        // direction is exhausted before the full amount. Reject rather than proceed: on a
        // non-first hop the remainder is an intermediate token that no refund path can see
        // (the refund in OnchainRouter is denominated in the caller's input token), so it
        // strands here, and under a loose minAmountOut the terminal TooLittleReceived
        // check does not fire, so the swap "succeeds" while the caller silently loses that
        // value. Enforced on EVERY hop rather than only later ones: exempting the first hop
        // would mean a drained pool partial-fills when routed directly but reverts when
        // routed as hop two, and "exact input" should not quietly become "some of the
        // input" on either shape. Mirrors V4InvalidAmountOut on the exact-output side.
        if (inputAmount != amountIn) revert V4IncompleteInput();

        // Pre-settle: unwrap WETH→ETH if the V4 pool uses native ETH for input, for
        // exactly the consumed amount (mirrors the exact-output hop). Unwrapping the
        // full funded amountIn would strand the unconsumed remainder as native ETH on
        // a partial fill, invisible to the WETH-denominated refund in OnchainRouter.
        if (inputCurrency.isAddressZero()) {
            IWETH9(weth).withdraw(inputAmount);
        }
        _v4Settle(inputCurrency, inputAmount);

        // Take output (positive delta = pool manager owes us)
        amountOut = uint256(uint128(zeroForOne ? delta1 : delta0));
        poolManager.take(outputCurrency, isIntermediate ? address(this) : recipient, amountOut);

        // Post-swap: wrap ETH→WETH whenever the ROUTER itself holds the output, matching the
        // exact-output hop's condition. Keying on isIntermediate alone missed the final-hop
        // case where the router is the recipient because unwrapOutput=true: the router kept
        // raw ETH and OnchainRouter's immediate WETH.withdraw(amountOut) then
        // underflow-reverted, so exact-input reverted on a route the exact-output twin
        // handled. recipient == address(this) subsumes the intermediate case, since every
        // non-final hop is already passed address(this) as its recipient.
        if (outputCurrency.isAddressZero() && recipient == address(this)) {
            IWETH9(weth).deposit{value: amountOut}();
        }
    }

    function _v4SwapExactOutputHop(Quote memory quote, uint256 amountOut, address recipient, uint256 pathIndex)
        private
        returns (uint256 amountIn)
    {
        Pool memory pool = quote.path[pathIndex];
        address weth = intermediateToken;
        PoolKey memory key = pool.key;
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
        // Full-fill check, mirroring V3 (V3InvalidAmountOut): a V4 pool can partial-fill
        // an exact-output swap when its liquidity is exhausted before the target output.
        if (outputAmount != amountOut) revert V4InvalidAmountOut();
        poolManager.take(outputCurrency, recipient, outputAmount);

        // Post-take: wrap ETH→WETH if recipient is this contract and output is native ETH
        if (outputCurrency.isAddressZero() && recipient == address(this)) {
            IWETH9(weth).deposit{value: outputAmount}();
        }
    }

    /// @dev Settle a V4 balance delta. Native ETH: settle{value}. ERC20: sync → transfer → settle.
    function _v4Settle(Currency currency, uint256 amount) private {
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            SafeTransferLib.safeTransfer(ERC20(Currency.unwrap(currency)), address(poolManager), amount);
            poolManager.settle();
        }
    }

    function _hasV4Hop(Quote memory quote) private pure returns (bool) {
        for (uint256 i = 0; i < quote.path.length; i++) {
            if (quote.path[i].version == V4) return true;
        }
        return false;
    }

    // ─────────────────────────────────────────────────────────────
    //  V2 Swap Execution
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
    //  V3 Swap Execution
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

        // Symmetric with the V4 hop: a V3 pool whose liquidity is exhausted stops at the
        // price limit and consumes less than requested. See _v4SwapExactInput for why this
        // is rejected on every hop rather than refunded.
        if (uint256(zeroForOne ? amount0Delta : amount1Delta) != amountIn) revert V3IncompleteInput();

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
    //  V3 Callback
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
