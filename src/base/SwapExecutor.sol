// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.26;

import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {V3Path} from "@uniswap/universal-router/contracts/modules/uniswap/v3/V3Path.sol";
import {BytesLib} from "@uniswap/universal-router/contracts/modules/uniswap/v3/BytesLib.sol";
import {SafeCast} from "@uniswap/v3-core/contracts/libraries/SafeCast.sol";
import {CalldataDecoder} from "@uniswap/v4-periphery/src/libraries/CalldataDecoder.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {MaxInputAmount} from "briefcase/protocols/universal-router/libraries/MaxInputAmount.sol";
import {Quote, Pool} from "../interfaces/IOnchainRouter.sol";
import {UniswapV2Library} from "../libraries/UniswapV2Library.sol";
import "./OnchainRouterImmutables.sol";

/// @title Swap Executor for Uniswap V2 and V3 Trades
/// @notice Handles the execution of swaps across Uniswap V2 and V3 protocols
/// @dev This contract implements the core swap logic and callbacks for both Uniswap versions
abstract contract SwapExecutor is OnchainRouterImmutables {
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

    /// @notice Thrown when a V3 swap is invalid (e.g., zero liquidity)
    error V3InvalidSwap();
    /// @notice Thrown when V2 swap requires more input tokens than allowed
    error V2TooMuchRequested();
    /// @notice Thrown when V3 swap requires more input tokens than allowed
    error V3TooMuchRequested();
    /// @notice Thrown when V3 swap requires more input tokens than allowed
    error TooLittleReceived();
    /// @notice Thrown when V3 swap returns incorrect output amount
    error V3InvalidAmountOut();
    /// @notice Thrown when V3 callback is called by unauthorized pool
    error V3InvalidCaller();

    /// @notice Executes a swap with exact input amount
    /// @dev Processes multi-hop swaps sequentially, handling both V2 and V3 pools
    /// @param quote The quote containing swap path and amount details
    /// @param recipient The address that will receive the final output tokens
    /// @return amountOut The amount of output tokens received from the swap
    function _swapExactInput(Quote memory quote, address recipient) internal returns (uint256 amountOut) {
        uint256 amountIn = quote.amountIn;
        for (uint256 i = 0; i < quote.path.length; i++) {
            Pool memory pool = quote.path[i];
            // This contract custodies intermediate funds
            address currentRecipient = i < quote.path.length - 1 ? address(this) : recipient;

            // set the next amountIn to the current amountOut
            if (pool.version) {
                // v3 swap
                amountIn = _v3SwapExactInput(quote, amountIn, currentRecipient, i);
            } else {
                // v2 swap
                amountIn = _v2SwapExactInput(pool, amountIn, currentRecipient);
            }
        }
        amountOut = amountIn;
        if (amountOut < quote.amountOut) revert TooLittleReceived();
    }

    /// @notice Executes a swap with exact output amount
    /// @dev Sets up maximum input amount protection before executing the swap
    /// @param quote The quote containing swap path and amount details
    /// @param recipient The address that will receive the output tokens
    /// @return amountIn The amount of input tokens used for the swap
    /// @custom:throws V2TooMuchRequested If V2 swap requires more than maximum input
    /// @custom:throws V3TooMuchRequested If V3 swap requires more than maximum input
    function _swapExactOutput(Quote memory quote, address recipient) internal returns (uint256 amountIn) {
        MaxInputAmount.set(quote.amountIn);
        amountIn = _swapExactOutput(quote, quote.amountOut, recipient, quote.path.length - 1);
        MaxInputAmount.set(0);
    }

    /// @notice Internal recursive function for exact output swaps
    /// @dev Processes multi-hop swaps recursively, starting from the last pool
    /// @param quote The quote containing swap path and amount details
    /// @param amountOut The exact amount of output tokens required
    /// @param recipient The address that will receive the output tokens
    /// @param pathIndex The current index in the swap path
    /// @return amountIn The amount of input tokens required for this hop
    /// @custom:throws V2TooMuchRequested If V2 swap requires more than maximum input
    /// @custom:throws V3TooMuchRequested If V3 swap requires more than maximum input
    function _swapExactOutput(Quote memory quote, uint256 amountOut, address recipient, uint256 pathIndex)
        private
        returns (uint256 amountIn)
    {
        Pool memory pool = quote.path[pathIndex];
        if (pool.version) {
            // v3 swap
            amountIn = _v3SwapExactOutput(quote, amountOut, recipient, pathIndex);
        } else {
            // v2 swap
            amountIn = _v2SwapExactOutput(quote, amountOut, recipient, pathIndex);
        }
    }

    /// @notice Executes a V2 swap with exact input amount
    /// @dev Handles single-hop V2 swaps, calculating output amount based on reserves
    /// @param pool The pool information for the swap
    /// @param amountIn The exact amount of input tokens to swap
    /// @param recipient The address that will receive the output tokens
    /// @return amountOut The amount of output tokens received
    function _v2SwapExactInput(Pool memory pool, uint256 amountIn, address recipient)
        private
        returns (uint256 amountOut)
    {
        // Send input funds in
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

    /// @notice Executes a V3 swap with exact input amount
    /// @dev Handles single-hop V3 swaps, using the pool's swap function
    /// @param quote The quote containing swap path and amount details
    /// @param amountIn The exact amount of input tokens to swap
    /// @param recipient The address that will receive the output tokens
    /// @param pathIndex The current index in the swap path
    /// @return amountOut The amount of output tokens received
    /// @custom:throws V3InvalidAmountOut If the received amount doesn't match expected
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

    /// @notice Executes a V3 exact output swap
    /// @dev Handles single-hop V3 swaps with exact output amount
    /// @param quote The quote containing swap path and amount details
    /// @param amountOut The exact output amount required
    /// @param recipient The address that will receive the output tokens
    /// @param pathIndex The current index in the swap path
    /// @return amountIn The amount of input tokens used
    /// @custom:throws V3InvalidAmountOut If the received amount doesn't match expected
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

    /// @notice Executes a V2 exact output swap
    /// @dev Handles single-hop V2 swaps with exact output amount
    /// @param quote The quote containing swap path and amount details
    /// @param amountOut The exact output amount required
    /// @param recipient The address that will receive the output tokens
    /// @param pathIndex The current index in the swap path
    /// @return amountIn The amount of input tokens used
    /// @custom:throws V2TooMuchRequested If input amount exceeds maximum allowed
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

        // either initiate the next swap or pay
        if (pathIndex > 0) {
            // this is an intermediate step so the payer is actually this contract
            _swapExactOutput(quote, amountOut, pool.pool, pathIndex - 1);
        } else {
            if (amountIn > MaxInputAmount.get()) revert V2TooMuchRequested();
            SafeTransferLib.safeTransfer(ERC20(pool.tokenIn), pool.pool, amountIn);
        }

        (uint256 amount0Out, uint256 amount1Out) =
            pool.tokenIn == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
        pair.swap(amount0Out, amount1Out, recipient, new bytes(0));
    }

    /// @notice Callback for V3 swaps, required by IUniswapV3SwapCallback
    /// @dev Handles payment for V3 swaps, either by executing next swap in path or transferring tokens
    /// @param amount0Delta The amount of token0 being borrowed
    /// @param amount1Delta The amount of token1 being borrowed
    /// @param data Encoded quote and path index information
    /// @custom:throws V3InvalidSwap If swap is entirely within 0-liquidity regions
    /// @custom:throws V3InvalidCaller If not called by the expected V3 pool
    /// @custom:throws V3TooMuchRequested If input amount exceeds maximum allowed
    /// @custom:throws V2TooMuchRequested If V2 swap in path requires more than maximum input
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (amount0Delta <= 0 && amount1Delta <= 0) revert V3InvalidSwap(); // swaps entirely within 0-liquidity regions are not supported
        (Quote memory quote, uint256 pathIndex, bool isExactInput) = abi.decode(data, (Quote, uint256, bool));

        Pool memory pool = quote.path[pathIndex];

        if (pool.pool != msg.sender) revert V3InvalidCaller();
        (uint256 amountToPay) = amount0Delta > 0 ? (uint256(amount0Delta)) : (uint256(amount1Delta));

        if (isExactInput) {
            SafeTransferLib.safeTransfer(ERC20(pool.tokenIn), msg.sender, amountToPay);
        } else {
            // either initiate the next swap or pay
            if (pathIndex > 0) {
                // this is an intermediate step so the payer is actually this contract
                _swapExactOutput(quote, amountToPay, msg.sender, pathIndex - 1);
            } else {
                if (amountToPay > MaxInputAmount.get()) revert V3TooMuchRequested();
                SafeTransferLib.safeTransfer(ERC20(pool.tokenIn), msg.sender, amountToPay);
            }
        }
    }
}
