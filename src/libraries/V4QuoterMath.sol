// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SwapMath} from "v4-core/src/libraries/SwapMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {ProtocolFeeLibrary} from "v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {V4PoolTickBitmap} from "./V4PoolTickBitmap.sol";

/// @title V4 Quoter Math
/// @notice Mirrors QuoterMath but reads V4 pool state via StateLibrary (extsload)
library V4QuoterMath {
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int256;
    using ProtocolFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint16;

    struct QuoteParams {
        bool zeroForOne;
        bool exactInput;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    struct QuoteContext {
        IPoolManager manager;
        PoolId poolId;
        int24 tickSpacing;
    }

    struct SwapState {
        int256 amountSpecifiedRemaining;
        int256 amountCalculated;
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
    }

    struct StepComputations {
        uint160 sqrtPriceStartX96;
        int24 tickNext;
        bool initialized;
        uint160 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;
    }

    function quote(
        IPoolManager manager,
        PoolId poolId,
        int24 tickSpacing,
        int256 amount,
        QuoteParams memory quoteParams
    ) public view returns (int256 amount0, int256 amount1, uint160 sqrtPriceAfterX96, uint32 initializedTicksCrossed) {
        QuoteContext memory ctx = QuoteContext({manager: manager, poolId: poolId, tickSpacing: tickSpacing});
        (amount0, amount1, sqrtPriceAfterX96, initializedTicksCrossed) = _quoteInternal(ctx, amount, quoteParams);
    }

    function _quoteInternal(QuoteContext memory ctx, int256 amount, QuoteParams memory quoteParams)
        private
        view
        returns (int256 amount0, int256 amount1, uint160 sqrtPriceAfterX96, uint32 initializedTicksCrossed)
    {
        quoteParams.exactInput = amount < 0; // V4 convention: negative = exact input
        initializedTicksCrossed = 1;

        SwapState memory state;
        {
            (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = ctx.manager.getSlot0(ctx.poolId);
            uint128 liquidity = ctx.manager.getLiquidity(ctx.poolId);
            state = SwapState({
                amountSpecifiedRemaining: amount,
                amountCalculated: 0,
                sqrtPriceX96: sqrtPriceX96,
                tick: tick,
                liquidity: liquidity
            });

            // Mirror Pool.swap's fee composition instead of trusting the caller's key.fee:
            // the swap fee is the directional protocol fee compounded with the pool's
            // current LP fee read from slot0. Because it reads the live lpFee, a
            // dynamic-fee pool quotes against its currently-set fee rather than the
            // 0x800000 DYNAMIC_FEE_FLAG sentinel in key.fee; that path is covered by
            // test/DynamicFeeParity.t.sol. Swap-time hook fee overrides remain out of
            // scope: the quoter is hook-unaware by design.
            uint16 directionalProtocolFee =
                quoteParams.zeroForOne ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee();
            quoteParams.fee = directionalProtocolFee == 0 ? lpFee : directionalProtocolFee.calculateSwapFee(lpFee);
        }

        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != quoteParams.sqrtPriceLimitX96) {
            StepComputations memory step;
            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.tickNext, step.initialized) = V4PoolTickBitmap.nextInitializedTickWithinOneWord(
                ctx.manager, ctx.poolId, ctx.tickSpacing, state.tick, quoteParams.zeroForOne
            );

            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            step.sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(step.tickNext);

            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                SwapMath.getSqrtPriceTarget(
                    quoteParams.zeroForOne, step.sqrtPriceNextX96, quoteParams.sqrtPriceLimitX96
                ),
                state.liquidity,
                state.amountSpecifiedRemaining,
                quoteParams.fee
            );

            if (quoteParams.exactInput) {
                unchecked {
                    state.amountSpecifiedRemaining += (step.amountIn + step.feeAmount).toInt256();
                }
                state.amountCalculated = state.amountCalculated + step.amountOut.toInt256();
            } else {
                unchecked {
                    state.amountSpecifiedRemaining -= step.amountOut.toInt256();
                }
                state.amountCalculated = state.amountCalculated - (step.amountIn + step.feeAmount).toInt256();
            }

            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                if (step.initialized) {
                    _crossTick(ctx, state, step.tickNext, quoteParams.zeroForOne);
                    initializedTicksCrossed++;
                }
                state.tick = quoteParams.zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                state.tick = TickMath.getTickAtSqrtPrice(state.sqrtPriceX96);
            }
        }

        (amount0, amount1) = quoteParams.zeroForOne == quoteParams.exactInput
            ? (amount - state.amountSpecifiedRemaining, state.amountCalculated)
            : (state.amountCalculated, amount - state.amountSpecifiedRemaining);

        sqrtPriceAfterX96 = state.sqrtPriceX96;
    }

    function _crossTick(QuoteContext memory ctx, SwapState memory state, int24 tickNext, bool zeroForOne) private view {
        (, int128 liquidityNet) = ctx.manager.getTickLiquidity(ctx.poolId, tickNext);

        if (zeroForOne) liquidityNet = -liquidityNet;

        if (liquidityNet < 0) {
            state.liquidity = state.liquidity - uint128(-liquidityNet);
        } else {
            state.liquidity = state.liquidity + uint128(liquidityNet);
        }
    }
}
