// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {SwapParams, Quote} from "../src/base/OnchainRouterStructs.sol";
import {OnchainRouterExposed} from "./utils/OnchainRouterExposed.sol";
import {BaseForkFixture} from "./utils/ForkFixtures.sol";

contract MHV3Factory {
    function feeAmountTickSpacing(uint24) external pure returns (int24) {
        return 0;
    }

    function getPool(address, address, uint24) external pure returns (address) {
        return address(0);
    }
}

contract MHV2Factory {
    function getPair(address, address) external pure returns (address) {
        return address(0);
    }
}

/// @notice #10 regression: in a 2-hop exact-output route the first (output-side) leg can
/// be unfillable and return the uint256.max sentinel. Feeding that forward as the next
/// leg's amountSpecified would wrap through int256() to -1 and quote a bogus ~1-wei
/// "winning" route. routeExactOutputMulti must short-circuit instead.
contract MultihopSentinelTest is BaseForkFixture {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    IPoolManager manager;
    PoolModifyLiquidityTest lpRouter;
    OnchainRouterExposed router;
    MockERC20 tokenIn;
    MockERC20 mid;
    MockERC20 tokenOut;

    function setUp() public {
        _forkBase(32_000_000);
        manager = IPoolManager(POOL_MANAGER);
        lpRouter = new PoolModifyLiquidityTest(manager);
        router = new OnchainRouterExposed(address(new MHV2Factory()), address(new MHV3Factory()), POOL_MANAGER, WETH);

        tokenIn = new MockERC20("IN", "IN", 18);
        mid = new MockERC20("MID", "MID", 18);
        tokenOut = new MockERC20("OUT", "OUT", 18);

        // Healthy input-side pool: tokenIn <-> mid, deep
        _seed(address(tokenIn), address(mid), int256(1e24));
        // Shallow output-side pool: mid <-> tokenOut, cannot cover a large exact-out
        _seed(address(mid), address(tokenOut), int256(1e15));
    }

    function _seed(address t0, address t1, int256 liq) internal {
        (Currency c0, Currency c1) =
            t0 < t1 ? (Currency.wrap(t0), Currency.wrap(t1)) : (Currency.wrap(t1), Currency.wrap(t0));
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))});
        manager.initialize(key, SQRT_PRICE_1_1);
        MockERC20(t0).mint(address(this), type(uint128).max);
        MockERC20(t1).mint(address(this), type(uint128).max);
        MockERC20(t0).approve(address(lpRouter), type(uint256).max);
        MockERC20(t1).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: liq, salt: 0}), ""
        );
    }

    function test_multihopExactOut_unfillableOutputLeg_shortCircuitsToSentinel() public {
        // Requested output far exceeds the shallow mid->tokenOut pool: that output leg
        // returns the unfillable sentinel, which must NOT wrap into a winning quote.
        SwapParams memory params =
            SwapParams({amountSpecified: 1_000e18, tokenIn: address(tokenIn), tokenOut: address(tokenOut)});
        Quote memory q = router.externalRouteExactOutputMulti(params, address(mid));

        assertEq(
            q.amountIn,
            type(uint256).max,
            "Unfillable output leg must short-circuit to the sentinel, never a wrapped ~1-wei quote"
        );
    }

    function test_multihopExactOut_fillable_stillRoutes() public {
        // A small output the shallow pool can cover still produces a real 2-hop quote
        SwapParams memory params =
            SwapParams({amountSpecified: 1e9, tokenIn: address(tokenIn), tokenOut: address(tokenOut)});
        Quote memory q = router.externalRouteExactOutputMulti(params, address(mid));

        assertGt(q.amountIn, 0, "Fillable multihop must quote a real input");
        assertTrue(q.amountIn != type(uint256).max, "Fillable multihop must not be the sentinel");
        assertEq(q.path.length, 2, "Fillable multihop must be a 2-hop route");
    }

    receive() external payable {}
}
