// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {V4QuoterMath} from "./libraries/V4QuoterMath.sol";
import {OnchainRouterImmutables} from "./base/OnchainRouterImmutables.sol";
import {SwapHop} from "./base/OnchainRouterStructs.sol";

/// @title Uniswap V4 Pool Quoter
/// @notice Provides functions for quoting V4 pool swaps without execution
abstract contract V4Quoter is OnchainRouterImmutables {
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;

    function v4QuoteExactIn(SwapHop memory swap) internal view returns (uint256 amountOut) {
        try this._v4QuoteExactIn{gas: 500_000}(swap) returns (uint256 _amountOut) {
            amountOut = _amountOut;
        } catch {
            amountOut = 0;
        }
    }

    function _v4QuoteExactIn(SwapHop memory swap) external view returns (uint256 amountOut) {
        PoolKey memory key = _buildV4PoolKey(swap);
        PoolId poolId = key.toId();

        bool zeroForOne = _isZeroForOne(swap.pool.tokenIn, swap.pool.tokenOut);

        V4QuoterMath.QuoteParams memory quoteParams = V4QuoterMath.QuoteParams({
            zeroForOne: zeroForOne,
            exactInput: true, // will be overridden by V4QuoterMath.quote
            fee: swap.pool.fee,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // V4 convention: negative = exact input
        (int256 amount0, int256 amount1,,) =
            V4QuoterMath.quote(poolManager, poolId, swap.pool.tickSpacing, -int256(swap.amountSpecified), quoteParams);

        // Output is the positive delta
        amountOut = zeroForOne ? uint256(amount1) : uint256(amount0);
    }

    function v4QuoteExactOut(SwapHop memory swap) internal view returns (uint256 amountIn) {
        try this._v4QuoteExactOut{gas: 500_000}(swap) returns (uint256 _amountIn) {
            amountIn = _amountIn;
        } catch {
            amountIn = type(uint256).max;
        }
    }

    function _v4QuoteExactOut(SwapHop memory swap) external view returns (uint256 amountIn) {
        PoolKey memory key = _buildV4PoolKey(swap);
        PoolId poolId = key.toId();

        bool zeroForOne = _isZeroForOne(swap.pool.tokenIn, swap.pool.tokenOut);

        V4QuoterMath.QuoteParams memory quoteParams = V4QuoterMath.QuoteParams({
            zeroForOne: zeroForOne,
            exactInput: false, // will be overridden
            fee: swap.pool.fee,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // V4 convention: positive = exact output
        (int256 amount0, int256 amount1,,) =
            V4QuoterMath.quote(poolManager, poolId, swap.pool.tickSpacing, int256(swap.amountSpecified), quoteParams);

        // Input is the negative delta (absolute value)
        amountIn = zeroForOne ? uint256(-amount0) : uint256(-amount1);
    }

    function _buildV4PoolKey(SwapHop memory swap) private pure returns (PoolKey memory) {
        Currency c0 = Currency.wrap(swap.pool.tokenIn);
        Currency c1 = Currency.wrap(swap.pool.tokenOut);
        if (c0 > c1) {
            (c0, c1) = (c1, c0);
        }
        return PoolKey({
            currency0: c0,
            currency1: c1,
            fee: swap.pool.fee,
            tickSpacing: swap.pool.tickSpacing,
            hooks: IHooks(swap.pool.hooks)
        });
    }

    function _isZeroForOne(address tokenIn, address tokenOut) private pure returns (bool) {
        // Currency comparison: wrap and compare
        return Currency.wrap(tokenIn) < Currency.wrap(tokenOut);
    }
}
