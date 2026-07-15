// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {SwapParams, Quote, V4} from "../src/base/OnchainRouterStructs.sol";
import {OnchainRouterExposed} from "./utils/OnchainRouterExposed.sol";
import {MockV3Factory, MockV2Factory} from "./utils/MockFactories.sol";
import {BaseForkFixture} from "./utils/ForkFixtures.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice The CONFIGURED intermediate fold (addIntermediateToken + routeExactInput /
/// routeExactOutput) exercised over real V4 pools. IntermediatesTest constructs the
/// router with poolManager = address(0), so without this suite the configurable fold
/// had no V4 coverage at all.
contract IntermediatesV4Test is BaseForkFixture {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    IPoolManager manager;
    PoolModifyLiquidityTest lpRouter;
    OnchainRouterExposed router;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 mid;

    address recipient;

    function setUp() public {
        _forkBase(32_000_000);
        manager = IPoolManager(POOL_MANAGER);
        lpRouter = new PoolModifyLiquidityTest(manager);
        router = new OnchainRouterExposed(
            address(new MockV2Factory()), address(new MockV3Factory()), POOL_MANAGER, WETH, address(this)
        );
        recipient = makeAddr("recipient");

        tokenA = new MockERC20("TokenA", "TKA", 18);
        tokenB = new MockERC20("TokenB", "TKB", 18);
        mid = new MockERC20("MID", "MID", 18);

        // The ONLY route between tokenA and tokenB is the V4 pools through mid: no
        // direct pool, no WETH pools, and no V2/V3 anywhere (mock factories).
        _seed(address(tokenA), address(mid), int256(1e24));
        _seed(address(mid), address(tokenB), int256(1e24));

        tokenA.approve(address(router), type(uint256).max);
    }

    function _fund(address token) internal {
        if (token == WETH) deal(WETH, address(this), type(uint128).max);
        else MockERC20(token).mint(address(this), type(uint128).max);
    }

    function _seed(address t0, address t1, int256 liq) internal {
        (Currency c0, Currency c1) =
            t0 < t1 ? (Currency.wrap(t0), Currency.wrap(t1)) : (Currency.wrap(t1), Currency.wrap(t0));
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))});
        manager.initialize(key, SQRT_PRICE_1_1);
        _fund(t0);
        _fund(t1);
        ERC20(t0).approve(address(lpRouter), type(uint256).max);
        ERC20(t1).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: liq, salt: 0}), ""
        );
    }

    /// @notice Regression: a WETH-endpoint pair with no direct pool plus a configured
    /// intermediate whose WETH leg is unfillable. routeExactOutputMulti short-circuits to
    /// the internal {amountIn: uint256.max} sentinel and better() prefers that over the
    /// empty direct quote (only amountIn == 0 reads as no-route there), so
    /// routeExactOutput used to return the sentinel to external callers. It must
    /// normalize to the empty no-route quote instead.
    function test_routeExactOutput_unfillableIntermediateLeg_returnsEmptyNotSentinel() public {
        MockERC20 tokenC = new MockERC20("TokenC", "TKC", 18);
        // Deep tokenC <-> mid pool: only the mid <-> WETH leg is the problem
        _seed(address(tokenC), address(mid), int256(1e24));
        // Shallow mid <-> WETH pool: cannot fill a large exact output
        _seed(address(mid), WETH, int256(1e15));
        router.addIntermediateToken(address(mid));

        // tokenOut is WETH: the WETH intermediate is skipped as an endpoint, there is no
        // direct tokenC/WETH pool, and the mid candidate's unfillable output leg
        // short-circuits to the sentinel — the only surviving fold candidate.
        SwapParams memory params = SwapParams({amountSpecified: 1_000e18, tokenIn: address(tokenC), tokenOut: WETH});
        Quote memory q = router.routeExactOutput(params);

        assertEq(q.amountIn, 0, "No-route exact-out must quote zero input, never the uint max sentinel");
        assertEq(q.amountOut, 0, "No-route exact-out must quote zero output");
        assertEq(q.path.length, 0, "No-route exact-out must have an empty path");
    }

    receive() external payable {}
}
