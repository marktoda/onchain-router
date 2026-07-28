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
import {SwapExecutor} from "../src/base/SwapExecutor.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {OnchainRouterExposed} from "./utils/OnchainRouterExposed.sol";
import {BaseForkFixture} from "./utils/ForkFixtures.sol";

contract MockV3Factory {
    function feeAmountTickSpacing(uint24) external pure returns (int24) {
        return 0;
    }

    function getPool(address, address, uint24) external pure returns (address) {
        return address(0);
    }
}

contract MockV2Factory {
    function getPair(address, address) external pure returns (address) {
        return address(0);
    }
}

/// @notice V4 exact-output must reject a pool that can only partial-fill, mirroring V3's
/// V3InvalidAmountOut. Without the check a shallow pool quotes an artificially low
/// amountIn, wins better(), and under-delivers at execution.
contract V4FullFillTest is BaseForkFixture {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    IPoolManager manager;
    PoolModifyLiquidityTest lpRouter;
    OnchainRouterExposed router;
    MockERC20 tokenA;
    MockERC20 tokenB;
    PoolKey poolKey;
    Pool pool;
    address recipient;

    function setUp() public {
        _forkBase(32_000_000);
        manager = IPoolManager(POOL_MANAGER);
        lpRouter = new PoolModifyLiquidityTest(manager);
        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        router =
            new OnchainRouterExposed(address(new MockV2Factory()), address(new MockV3Factory()), POOL_MANAGER, WETH);
        recipient = makeAddr("recipient");

        (Currency c0, Currency c1) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));
        poolKey = PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))});
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        tokenA.mint(address(this), type(uint128).max);
        tokenB.mint(address(this), type(uint128).max);
        tokenA.approve(address(lpRouter), type(uint256).max);
        tokenB.approve(address(lpRouter), type(uint256).max);
        tokenA.approve(address(router), type(uint256).max);

        // Shallow, single narrow position
        lpRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: int256(1e15), salt: 0}), ""
        );

        pool = Pool({
            tokenIn: address(tokenA), tokenOut: address(tokenB), fee: 3000, pool: address(0), version: V4, key: poolKey
        });
    }

    /// @dev Execution is not gas-capped, so an over-depth exact-output request cleanly
    /// partial-fills at the pool; the executor's full-fill check must reject it rather
    /// than silently deliver less than requested.
    function test_v4ExactOut_overDepth_executionRevertsInvalidAmountOut() public {
        Pool[] memory path = new Pool[](1);
        path[0] = pool;
        // amountOut far exceeds pool depth; amountIn generously funded and bounded
        Quote memory quote = Quote({path: path, amountIn: 1e24, amountOut: 1_000e18});

        vm.expectRevert(SwapExecutor.V4InvalidAmountOut.selector);
        router.swapExactOutput(quote, recipient, block.timestamp, false, 1e24);
    }

    /// @dev A fillable exact-output request still quotes a real amountIn and executes.
    function test_v4ExactOut_withinDepth_quotesAndExecutes() public {
        uint256 amountOut = 1e11;
        uint256 quotedIn = router.externalV4QuoteExactOut(SwapHop({pool: pool, amountSpecified: amountOut}));
        assertGt(quotedIn, 0, "Fillable exact-out must quote a real amountIn");
        assertTrue(quotedIn != type(uint256).max, "Fillable exact-out must not be the sentinel");

        Pool[] memory path = new Pool[](1);
        path[0] = pool;
        Quote memory quote = Quote({path: path, amountIn: quotedIn, amountOut: amountOut});
        uint256 amountIn = router.swapExactOutput(quote, recipient, block.timestamp, false, quotedIn);
        assertEq(MockERC20(address(tokenB)).balanceOf(recipient), amountOut, "Exact output delivered");
        assertLe(amountIn, quotedIn, "Input within bound");
    }

    /// @notice BEHAVIOR CHANGE: an exact-input hop that cannot consume its full funded
    /// amount now reverts instead of partial-filling and refunding the remainder.
    /// @dev Previously this asserted a partial fill plus refund. Full consumption is now
    /// enforced on every hop, not just non-first hops, because the alternative was that a
    /// drained pool partial-fills when routed directly but reverts when routed as hop two
    /// (the remainder of a later hop is an intermediate token no refund path can measure).
    /// "Exact input" should not quietly become "some of the input" on either route shape.
    /// The input refund in OnchainRouter remains as defense-in-depth.
    function test_v4ExactIn_partialFill_revertsIncompleteInput() public {
        uint256 amountIn = 5_000e18; // far more than the shallow pool can absorb
        Pool[] memory path = new Pool[](1);
        path[0] = pool;
        // minAmountOut = 1: deliberately loose, so only the full-consumption check can fire
        Quote memory quote = Quote({path: path, amountIn: amountIn, amountOut: 0});

        vm.expectRevert(SwapExecutor.V4IncompleteInput.selector);
        router.swapExactInput(quote, recipient, block.timestamp, false, 1);

        assertEq(tokenA.balanceOf(address(router)), 0, "No input token may strand in the router");
    }

    /// @notice A swap sized within the pool's depth still succeeds, so the new check is not
    /// simply rejecting everything.
    function test_v4ExactIn_withinDepth_consumesFullInputAndSucceeds() public {
        // Sized like the exact-output sibling: this pool holds only 1e15 liquidity across
        // ticks -60..60, so anything larger legitimately cannot be absorbed.
        uint256 amountIn = 1e11;
        Pool[] memory path = new Pool[](1);
        path[0] = pool;
        Quote memory quote = Quote({path: path, amountIn: amountIn, amountOut: 0});

        uint256 selfBefore = tokenA.balanceOf(address(this));
        uint256 amountOut = router.swapExactInput(quote, recipient, block.timestamp, false, 1);

        assertGt(amountOut, 0, "In-depth swap must deliver output");
        assertEq(selfBefore - tokenA.balanceOf(address(this)), amountIn, "Full input must be consumed");
        assertEq(tokenA.balanceOf(address(router)), 0, "No input token may strand in the router");
    }

    receive() external payable {}
}

/// @notice Native-ETH analogs of the exact-input hop checks: when the V4 pool uses
/// Currency.wrap(address(0)) on either side, the executor must unwrap only the consumed input
/// and must wrap output the router itself holds. Neither may leave native ETH or WETH behind,
/// since the refund accounting is WETH-denominated.
contract V4NativeFullFillTest is BaseForkFixture {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    IPoolManager manager;
    PoolModifyLiquidityTest lpRouter;
    OnchainRouterExposed router;
    MockERC20 tokenB;
    PoolKey poolKey;
    Pool pool;
    address recipient;

    function setUp() public {
        _forkBase(32_000_000);
        manager = IPoolManager(POOL_MANAGER);
        lpRouter = new PoolModifyLiquidityTest(manager);
        tokenB = new MockERC20("B", "B", 18);
        router =
            new OnchainRouterExposed(address(new MockV2Factory()), address(new MockV3Factory()), POOL_MANAGER, WETH);
        recipient = makeAddr("recipient");

        // Native ETH (address(0)) sorts below every token, so it is always currency0
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tokenB)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        tokenB.mint(address(this), type(uint128).max);
        tokenB.approve(address(lpRouter), type(uint256).max);
        vm.deal(address(this), 20_000e18);

        // Shallow, single narrow position; the LP router refunds unused ETH
        lpRouter.modifyLiquidity{value: 1e18}(
            poolKey, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: int256(1e15), salt: 0}), ""
        );

        pool = Pool({
            tokenIn: address(0), tokenOut: address(tokenB), fee: 3000, pool: address(0), version: V4, key: poolKey
        });
    }

    /// @notice BEHAVIOR CHANGE: native-ETH twin of
    /// test_v4ExactIn_partialFill_revertsIncompleteInput. Previously asserted a partial fill
    /// plus refund; full consumption is now enforced on every hop. See that test for why.
    function test_v4ExactIn_nativePartialFill_revertsIncompleteInput() public {
        uint256 amountIn = 5_000e18; // far more than the shallow pool can absorb
        Pool[] memory path = new Pool[](1);
        path[0] = pool;
        // minAmountOut = 1: deliberately loose, so only the full-consumption check can fire
        Quote memory quote = Quote({path: path, amountIn: amountIn, amountOut: 0});

        vm.expectRevert(SwapExecutor.V4IncompleteInput.selector);
        router.swapExactInput{value: amountIn}(quote, recipient, block.timestamp, false, 1);

        assertEq(address(router).balance, 0, "No native ETH may strand in the router");
        assertEq(ERC20(WETH).balanceOf(address(router)), 0, "No WETH may strand in the router");
    }

    receive() external payable {}
}

/// @notice A pool whose exact-input quote fails (the quoter's gas-capped 0 sentinel) must
/// not be installed as bestQuote when it is the only candidate: route selection must
/// return a clean empty quote, and that quote must not be executable.
contract SentinelRouteSelectionTest is BaseForkFixture {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    IPoolManager manager;
    OnchainRouterExposed router;
    MockERC20 tokenA;
    MockERC20 tokenB;
    address recipient;

    function setUp() public {
        _forkBase(32_000_000);
        manager = IPoolManager(POOL_MANAGER);
        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        router =
            new OnchainRouterExposed(address(new MockV2Factory()), address(new MockV3Factory()), POOL_MANAGER, WETH);
        recipient = makeAddr("recipient");

        (Currency c0, Currency c1) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));
        // tickSpacing 1 with zero liquidity: an exact-in quote walks the entire tick
        // range word by word, exceeds the quoter's 500K gas cap, and yields the 0
        // sentinel. This initialized pool is the ONLY candidate for the pair.
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 100, tickSpacing: 1, hooks: IHooks(address(0))});
        manager.initialize(key, SQRT_PRICE_1_1);

        tokenA.mint(address(this), 10e18);
        tokenA.approve(address(router), type(uint256).max);
    }

    function test_routeSelection_onlySentinelPool_isUnroutable() public {
        SwapParams memory params =
            SwapParams({amountSpecified: 1e18, tokenIn: address(tokenA), tokenOut: address(tokenB)});
        Quote memory q = router.routeExactInput(params);

        assertEq(q.amountOut, 0, "Sentinel-only pair must quote zero output");
        assertEq(q.amountIn, 0, "Unroutable quote must not carry the requested amountIn");
        assertEq(q.path.length, 0, "Sentinel pool must not be installed as a route");

        // Non-executability: before normalization the quote carried a non-empty path
        // with amountOut 0, which the 4-arg entrypoint would happily execute with an
        // effective minAmountOut of 0. The empty quote must revert instead.
        vm.expectRevert();
        router.swapExactInput(q, recipient, block.timestamp, false);
    }
}
