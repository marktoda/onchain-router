// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {V4QuoterMath} from "./libraries/V4QuoterMath.sol";
import {OnchainRouterImmutables} from "./base/OnchainRouterImmutables.sol";
import {SwapHop} from "./base/OnchainRouterStructs.sol";

/// @title Uniswap V4 Pool Quoter
/// @notice Simulates V4 swaps offchain by reading pool state via StateLibrary (extsload).
/// @dev Uses try/catch with 500K gas limit to safely handle pools with extreme tick depth.
/// Returns 0 (exact-in) or type(uint256).max (exact-out) on failure.
abstract contract V4Quoter is OnchainRouterImmutables {
    using PoolIdLibrary for PoolKey;

    /// @dev Thrown when an exact-output quote cannot fully fill from the pool's liquidity.
    /// Caught by v4QuoteExactOut and converted to the unfillable sentinel.
    error V4PartialFill();

    function v4QuoteExactIn(SwapHop memory swap) internal view returns (uint256 amountOut) {
        try this._v4QuoteExactIn{gas: 500_000}(swap) returns (uint256 _amountOut) {
            amountOut = _amountOut;
        } catch {
            amountOut = 0;
        }
    }

    function _v4QuoteExactIn(SwapHop memory swap) external view returns (uint256 amountOut) {
        PoolKey memory key = swap.pool.key;
        bool zeroForOne = Currency.wrap(swap.pool.tokenIn) < Currency.wrap(swap.pool.tokenOut);

        V4QuoterMath.QuoteParams memory quoteParams = V4QuoterMath.QuoteParams({
            zeroForOne: zeroForOne,
            exactInput: true,
            fee: 0, // placeholder: V4QuoterMath composes the effective fee from slot0 (protocol fee + LP fee)
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        (int256 amount0, int256 amount1,,) =
            V4QuoterMath.quote(poolManager, key.toId(), key.tickSpacing, -int256(swap.amountSpecified), quoteParams);

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
        PoolKey memory key = swap.pool.key;
        bool zeroForOne = Currency.wrap(swap.pool.tokenIn) < Currency.wrap(swap.pool.tokenOut);

        V4QuoterMath.QuoteParams memory quoteParams = V4QuoterMath.QuoteParams({
            zeroForOne: zeroForOne,
            exactInput: false,
            fee: 0, // placeholder: V4QuoterMath composes the effective fee from slot0 (protocol fee + LP fee)
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        (int256 amount0, int256 amount1,,) =
            V4QuoterMath.quote(poolManager, key.toId(), key.tickSpacing, int256(swap.amountSpecified), quoteParams);

        // Full-fill check, mirroring V3 (SwapExecutor.V3InvalidAmountOut). The V4 loop
        // exits when the pool is exhausted, leaving a partial fill that would otherwise
        // quote an artificially low amountIn, win better(), then under-deliver at
        // execution. Reverting here is caught by v4QuoteExactOut and surfaces the
        // type(uint256).max "unfillable" sentinel, so the pool loses the route.
        uint256 delivered = uint256(zeroForOne ? amount1 : amount0);
        if (delivered != swap.amountSpecified) revert V4PartialFill();

        amountIn = zeroForOne ? uint256(-amount0) : uint256(-amount1);
    }
}
