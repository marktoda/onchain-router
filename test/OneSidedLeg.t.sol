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

contract OSLV3Factory {
    function feeAmountTickSpacing(uint24) external pure returns (int24) {
        return 0;
    }

    function getPool(address, address, uint24) external pure returns (address) {
        return address(0);
    }
}

contract OSLV2Factory {
    function getPair(address, address) external pure returns (address) {
        return address(0);
    }
}

/// @notice A one-sided route (tokenIn->WETH routable, WETH->tokenOut not) must resolve to
/// an empty quote, never a combined quote whose path dead-ends at the intermediate.
contract OneSidedLegTest is BaseForkFixture {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    IPoolManager manager;
    PoolModifyLiquidityTest lpRouter;
    OnchainRouterExposed router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;

    function setUp() public {
        _forkBase(32_000_000);
        manager = IPoolManager(POOL_MANAGER);
        lpRouter = new PoolModifyLiquidityTest(manager);
        router = new OnchainRouterExposed(address(new OSLV2Factory()), address(new OSLV3Factory()), POOL_MANAGER, WETH);

        tokenIn = new MockERC20("IN", "IN", 18);
        tokenOut = new MockERC20("OUT", "OUT", 18);

        // Only the tokenIn <-> WETH leg exists; WETH <-> tokenOut has no pool anywhere
        _seed(address(tokenIn), WETH);
    }

    function _seed(address t0, address t1) internal {
        (Currency c0, Currency c1) =
            t0 < t1 ? (Currency.wrap(t0), Currency.wrap(t1)) : (Currency.wrap(t1), Currency.wrap(t0));
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))});
        manager.initialize(key, SQRT_PRICE_1_1);
        MockERC20(t0).mint(address(this), type(uint128).max);
        deal(t1, address(this), type(uint128).max);
        MockERC20(t0).approve(address(lpRouter), type(uint256).max);
        MockERC20(t1).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: int256(1e21), salt: 0}), ""
        );
    }

    function test_exactIn_oneSidedLeg_returnsEmptyNotDeadEnd() public {
        SwapParams memory params =
            SwapParams({amountSpecified: 1e18, tokenIn: address(tokenIn), tokenOut: address(tokenOut)});
        Quote memory q = router.routeExactInput(params);
        assertEq(q.amountOut, 0, "Unroutable pair must have zero output");
        assertEq(q.path.length, 0, "Must not return a path that dead-ends at the intermediate");
    }

    function test_exactOut_oneSidedLeg_returnsUnroutable() public {
        SwapParams memory params =
            SwapParams({amountSpecified: 1e18, tokenIn: address(tokenIn), tokenOut: address(tokenOut)});
        Quote memory q = router.routeExactOutput(params);
        // Unroutable: sentinel input and no dead-end path
        assertTrue(
            q.amountIn == 0 || q.amountIn == type(uint256).max, "Unroutable exact-out must not quote a real input"
        );
        assertEq(q.path.length, 0, "Must not return a dead-end path");
    }

    receive() external payable {}
}
