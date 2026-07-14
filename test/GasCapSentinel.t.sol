// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {SwapParams, Quote, Pool, SwapHop, V4} from "../src/base/OnchainRouterStructs.sol";
import {OnchainRouterExposed} from "./utils/OnchainRouterExposed.sol";
import {MockV3Factory, MockV2Factory} from "./utils/MockFactories.sol";
import {BaseForkFixture} from "./utils/ForkFixtures.sol";

/// @notice The quoters run under a 500k gas budget and return sentinels on failure:
/// 0 for exact-in, type(uint256).max for exact-out. These tests pin down both halves of
/// that contract: (1) a tick-dense pool actually produces the sentinel instead of
/// reverting the whole quote call, and (2) route selection treats a sentinel pool as
/// unusable, never letting it win a route.
contract GasCapSentinelTest is BaseForkFixture {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 constant DENSE_TICKS = 220; // initialized ticks on each side of spot

    IPoolManager manager;
    PoolModifyLiquidityTest lpRouter;
    OnchainRouterExposed router;
    MockERC20 tokenA;
    MockERC20 tokenB;
    PoolKey denseKey; // fee 100, spacing 1, hundreds of initialized ticks
    PoolKey healthyKey; // fee 3000, spacing 60, one wide position

    function setUp() public {
        _forkBase(32_000_000);
        manager = IPoolManager(POOL_MANAGER);
        lpRouter = new PoolModifyLiquidityTest(manager);

        tokenA = new MockERC20("TokenA", "TKA", 18);
        tokenB = new MockERC20("TokenB", "TKB", 18);

        router = new OnchainRouterExposed(
            address(new MockV2Factory()), address(new MockV3Factory()), POOL_MANAGER, WETH, address(this)
        );

        (Currency c0, Currency c1) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));

        denseKey = PoolKey({currency0: c0, currency1: c1, fee: 100, tickSpacing: 1, hooks: IHooks(address(0))});
        healthyKey = PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))});
        manager.initialize(denseKey, SQRT_PRICE_1_1);
        manager.initialize(healthyKey, SQRT_PRICE_1_1);

        tokenA.mint(address(this), type(uint128).max);
        tokenB.mint(address(this), type(uint128).max);
        tokenA.approve(address(lpRouter), type(uint256).max);
        tokenB.approve(address(lpRouter), type(uint256).max);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);

        // Dense pool: a distinct 1-tick-wide position on every tick around spot, so a
        // swap of any size must cross an initialized boundary every single tick and the
        // quoter's per-tick extsloads blow through the 500k budget
        for (int24 t = -DENSE_TICKS; t < DENSE_TICKS; t++) {
            lpRouter.modifyLiquidity(
                denseKey,
                ModifyLiquidityParams({tickLower: t, tickUpper: t + 1, liquidityDelta: int256(1e15), salt: 0}),
                ""
            );
        }

        // Healthy pool: one wide, deep position
        lpRouter.modifyLiquidity(
            healthyKey,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: int256(1e24), salt: 0}),
            ""
        );
    }

    function _pool(PoolKey memory key) internal view returns (Pool memory) {
        return Pool({
            tokenIn: address(tokenA), tokenOut: address(tokenB), fee: key.fee, pool: address(0), version: V4, key: key
        });
    }

    function test_quoter_returnsSentinel_onGasExhaustion() public {
        // Large enough to sweep across all initialized ticks
        uint256 amountIn = 1_000_000e18;
        uint256 quoted = router.externalV4QuoteExactIn(SwapHop({pool: _pool(denseKey), amountSpecified: amountIn}));
        assertEq(quoted, 0, "exact-in gas exhaustion must return the 0 sentinel, not revert");

        uint256 quotedIn =
            router.externalV4QuoteExactOut(SwapHop({pool: _pool(denseKey), amountSpecified: 1_000_000e18}));
        assertEq(quotedIn, type(uint256).max, "exact-out gas exhaustion must return the uint max sentinel, not revert");
    }

    /// @notice A pair whose ONLY pool gas-caps must be reported unroutable: exact-in
    /// quotes 0 and exact-out quotes the uint-max sentinel. This is the non-vacuous half
    /// of the property: with no healthy pool to win on economics, only correct sentinel
    /// handling produces these outcomes instead of a bogus winning quote.
    function test_routeSelection_onlySentinelPool_isUnroutable() public {
        MockERC20 tokenC = new MockERC20("TokenC", "TKC", 18);
        MockERC20 tokenD = new MockERC20("TokenD", "TKD", 18);
        (Currency c0, Currency c1) = address(tokenC) < address(tokenD)
            ? (Currency.wrap(address(tokenC)), Currency.wrap(address(tokenD)))
            : (Currency.wrap(address(tokenD)), Currency.wrap(address(tokenC)));
        PoolKey memory loneDense =
            PoolKey({currency0: c0, currency1: c1, fee: 100, tickSpacing: 1, hooks: IHooks(address(0))});
        manager.initialize(loneDense, SQRT_PRICE_1_1);
        tokenC.mint(address(this), type(uint128).max);
        tokenD.mint(address(this), type(uint128).max);
        tokenC.approve(address(lpRouter), type(uint256).max);
        tokenD.approve(address(lpRouter), type(uint256).max);
        for (int24 t = -DENSE_TICKS; t < DENSE_TICKS; t++) {
            lpRouter.modifyLiquidity(
                loneDense,
                ModifyLiquidityParams({tickLower: t, tickUpper: t + 1, liquidityDelta: int256(1e15), salt: 0}),
                ""
            );
        }

        SwapParams memory params =
            SwapParams({amountSpecified: 100_000e18, tokenIn: address(tokenC), tokenOut: address(tokenD)});
        Quote memory exactIn = router.externalRouteExactInputSingle(params);
        assertEq(exactIn.amountOut, 0, "Gas-capped only-pool must make exact-in unroutable, not mis-quoted");

        Quote memory exactOut = router.externalRouteExactOutputSingle(params);
        assertEq(exactOut.amountIn, type(uint256).max, "Gas-capped only-pool must surface the exact-out sentinel");
    }

    function test_routeSelection_treatsSentinelPoolAsUnusable() public {
        // Both pools exist for the pair as default configs; the dense pool gas-caps while
        // the healthy pool quotes fine. The router must pick the healthy pool.
        SwapParams memory params =
            SwapParams({amountSpecified: 100_000e18, tokenIn: address(tokenA), tokenOut: address(tokenB)});
        Quote memory quote = router.externalRouteExactInputSingle(params);

        assertGt(quote.amountOut, 0, "Route must find the healthy pool");
        assertEq(quote.path.length, 1, "Single-hop route expected");
        assertEq(uint256(quote.path[0].key.fee), 3000, "Sentinel (gas-capped) pool must never win a route");
    }

    function test_routeSelection_exactOut_sentinelNeverWins() public {
        SwapParams memory params =
            SwapParams({amountSpecified: 100_000e18, tokenIn: address(tokenA), tokenOut: address(tokenB)});
        Quote memory quote = router.externalRouteExactOutputSingle(params);

        assertGt(quote.amountIn, 0, "Route must find the healthy pool");
        assertTrue(quote.amountIn != type(uint256).max, "Sentinel input must not be treated as a real quote");
        assertEq(uint256(quote.path[0].key.fee), 3000, "Sentinel (gas-capped) pool must never win exact-out");
    }
}
