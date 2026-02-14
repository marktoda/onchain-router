// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IUniswapV3Pool} from "v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "v3-core/contracts/libraries/TickMath.sol";
import {SafeCast} from "v3-core/contracts/libraries/SafeCast.sol";
import {QuoterMath} from "./libraries/QuoterMath.sol";
import {IV3Quoter} from "./interfaces/IV3Quoter.sol";
import {OnchainRouterImmutables} from "./base/OnchainRouterImmutables.sol";
import {SwapHop} from "./base/OnchainRouterStructs.sol";

/// @title Uniswap V3 Pool Quoter
/// @notice Provides functions for quoting V3 pool swaps without execution
abstract contract V3Quoter is OnchainRouterImmutables {
    using QuoterMath for *;
    using SafeCast for uint256;
    using SafeCast for int256;

    function v3QuoteExactIn(SwapHop memory swap) internal view returns (uint256 amountOut) {
        IV3Quoter.QuoteExactInputSingleWithPoolParams memory params = IV3Quoter.QuoteExactInputSingleWithPoolParams({
            tokenIn: swap.pool.tokenIn,
            tokenOut: swap.pool.tokenOut,
            amountIn: swap.amountSpecified,
            pool: swap.pool.pool,
            fee: swap.pool.fee,
            sqrtPriceLimitX96: 0
        });

        try this.v3QuoteExactInputSingleWithPool{gas: 500_000}(params) returns (uint256 _amountOut, uint160, uint32) {
            amountOut = _amountOut;
        } catch {
            amountOut = 0;
        }
    }

    function v3QuoteExactOut(SwapHop memory swap) internal view returns (uint256 amountIn) {
        IV3Quoter.QuoteExactOutputSingleWithPoolParams memory params = IV3Quoter.QuoteExactOutputSingleWithPoolParams({
            tokenIn: swap.pool.tokenIn,
            tokenOut: swap.pool.tokenOut,
            amount: swap.amountSpecified,
            pool: swap.pool.pool,
            fee: swap.pool.fee,
            sqrtPriceLimitX96: 0
        });

        try this.v3QuoteExactOutputSingleWithPool{gas: 500_000}(params) returns (uint256 _amountIn, uint160, uint32) {
            amountIn = _amountIn;
        } catch {
            amountIn = type(uint256).max;
        }
    }

    function v3QuoteExactInputSingleWithPool(IV3Quoter.QuoteExactInputSingleWithPoolParams memory params)
        public
        view
        returns (uint256 amountReceived, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed)
    {
        bool zeroForOne = params.tokenIn < params.tokenOut;
        IUniswapV3Pool pool = IUniswapV3Pool(params.pool);

        QuoterMath.QuoteParams memory quoteParams = QuoterMath.QuoteParams({
            zeroForOne: zeroForOne,
            fee: params.fee,
            sqrtPriceLimitX96: params.sqrtPriceLimitX96 == 0
                ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                : params.sqrtPriceLimitX96,
            exactInput: false
        });

        int256 amount0;
        int256 amount1;
        (amount0, amount1, sqrtPriceX96After, initializedTicksCrossed) =
            QuoterMath.quote(pool, params.amountIn.toInt256(), quoteParams);

        amountReceived = amount0 > 0 ? uint256(-amount1) : uint256(-amount0);
    }

    function v3QuoteExactOutputSingleWithPool(IV3Quoter.QuoteExactOutputSingleWithPoolParams memory params)
        public
        view
        returns (uint256 amountIn, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed)
    {
        bool zeroForOne = params.tokenIn < params.tokenOut;
        IUniswapV3Pool pool = IUniswapV3Pool(params.pool);

        uint256 amountOutCached = 0;
        if (params.sqrtPriceLimitX96 == 0) amountOutCached = params.amount;

        QuoterMath.QuoteParams memory quoteParams = QuoterMath.QuoteParams({
            zeroForOne: zeroForOne,
            exactInput: true, // will be overridden
            fee: params.fee,
            sqrtPriceLimitX96: params.sqrtPriceLimitX96 == 0
                ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                : params.sqrtPriceLimitX96
        });

        int256 amount0;
        int256 amount1;
        (amount0, amount1, sqrtPriceX96After, initializedTicksCrossed) =
            QuoterMath.quote(pool, -(params.amount.toInt256()), quoteParams);

        amountIn = amount0 > 0 ? uint256(amount0) : uint256(amount1);
        uint256 amountReceived = amount0 > 0 ? uint256(-amount1) : uint256(-amount0);

        if (amountOutCached != 0) require(amountReceived == amountOutCached);
    }
}
