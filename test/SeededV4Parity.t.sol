// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {ProtocolFees} from "v4-core/src/ProtocolFees.sol";
import {Quote, Pool, SwapHop, V4} from "../src/base/OnchainRouterStructs.sol";
import {OnchainRouterExposed} from "./utils/OnchainRouterExposed.sol";
import {MockV3Factory, MockV2Factory} from "./utils/MockFactories.sol";
import {BaseForkFixture} from "./utils/ForkFixtures.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice Parity properties against SEEDED V4 pools: fresh tokens, our own pool, our own
/// positions, on the live PoolManager at a pinned Base block.
/// @dev Live-pool fuzzing rarely crosses many initialized ticks, so the tick-crossing
/// loops in V4QuoterMath stay undertested there. Here the pool shape is ours: staggered
/// positions force deterministic multi-tick crossings and liquidity is fuzzed so boundary
/// rounding is explored across pool shapes. The pinned fork keeps counterexamples
/// reproducible; nothing about the pool state depends on live liquidity.
contract SeededV4ParityTest is BaseForkFixture {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    IPoolManager manager;
    PoolModifyLiquidityTest lpRouter;
    OnchainRouterExposed router;
    MockERC20 token18;
    MockERC20 token6;
    PoolKey poolKey;

    address recipient;

    uint256 constant MAX_IN = 1_000_000e18;

    function setUp() public {
        _forkBase(32_000_000);
        manager = IPoolManager(POOL_MANAGER);
        lpRouter = new PoolModifyLiquidityTest(manager);

        token18 = new MockERC20("Token18", "T18", 18);
        token6 = new MockERC20("Token6", "T6", 6);

        // Mock V2/V3 factories: this suite exercises only the seeded V4 pool
        router = new OnchainRouterExposed(
            address(new MockV2Factory()), address(new MockV3Factory()), POOL_MANAGER, WETH, address(this)
        );

        recipient = makeAddr("recipient");

        (Currency c0, Currency c1) = address(token18) < address(token6)
            ? (Currency.wrap(address(token18)), Currency.wrap(address(token6)))
            : (Currency.wrap(address(token6)), Currency.wrap(address(token18)));
        poolKey = PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))});
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        token18.mint(address(this), type(uint128).max);
        token6.mint(address(this), type(uint128).max);
        token18.approve(address(lpRouter), type(uint256).max);
        token6.approve(address(lpRouter), type(uint256).max);
        token18.approve(address(router), type(uint256).max);
        token6.approve(address(router), type(uint256).max);
    }

    /// @dev Staggered ranges around the current tick so a large-enough swap must cross
    /// several initialized tick boundaries with different liquidity on each side.
    function _seedPositions(uint128 l1, uint128 l2, uint128 l3, uint128 l4) internal {
        int24[4] memory lowers = [int24(-60), int24(-180), int24(-600), int24(-3000)];
        int24[4] memory uppers = [int24(60), int24(180), int24(600), int24(3000)];
        uint128[4] memory liqs = [l1, l2, l3, l4];
        for (uint256 i = 0; i < 4; i++) {
            lpRouter.modifyLiquidity(
                poolKey,
                ModifyLiquidityParams({
                    tickLower: lowers[i], tickUpper: uppers[i], liquidityDelta: int256(uint256(liqs[i])), salt: 0
                }),
                ""
            );
        }
    }

    function _v4Pool(address tokenIn, address tokenOut) internal view returns (Pool memory) {
        return
            Pool({tokenIn: tokenIn, tokenOut: tokenOut, fee: poolKey.fee, pool: address(0), version: V4, key: poolKey});
    }

    function _bounds(uint128 l1, uint128 l2, uint128 l3, uint128 l4)
        internal
        view
        returns (uint128, uint128, uint128, uint128)
    {
        return (
            uint128(bound(l1, 1e15, 1e24)),
            uint128(bound(l2, 1e15, 1e24)),
            uint128(bound(l3, 1e15, 1e24)),
            uint128(bound(l4, 1e15, 1e24))
        );
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_seededParity_exactIn(uint256 amountIn, uint128 l1, uint128 l2, uint128 l3, uint128 l4) public {
        (l1, l2, l3, l4) = _bounds(l1, l2, l3, l4);
        _seedPositions(l1, l2, l3, l4);

        amountIn = bound(amountIn, 1e3, MAX_IN);

        Pool memory pool = _v4Pool(address(token18), address(token6));
        uint256 quoted = router.externalV4QuoteExactIn(SwapHop({pool: pool, amountSpecified: amountIn}));
        vm.assume(quoted > 0);

        Pool[] memory path = new Pool[](1);
        path[0] = pool;
        Quote memory quote = Quote({path: path, amountIn: amountIn, amountOut: quoted});

        uint256 amountOut = router.swapExactInput(quote, recipient, block.timestamp, false);
        assertEq(amountOut, quoted, "seeded V4 exact-in: realized output must equal quote bit-for-bit");
        assertEq(ERC20(address(token6)).balanceOf(recipient), amountOut, "recipient must hold the output");
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_seededParity_exactOut(uint256 amountOut, uint128 l1, uint128 l2, uint128 l3, uint128 l4) public {
        (l1, l2, l3, l4) = _bounds(l1, l2, l3, l4);
        _seedPositions(l1, l2, l3, l4);

        amountOut = bound(amountOut, 1e3, 1_000_000e6);

        Pool memory pool = _v4Pool(address(token18), address(token6));
        uint256 quotedIn = router.externalV4QuoteExactOut(SwapHop({pool: pool, amountSpecified: amountOut}));
        // Beyond pool depth the full-fill check returns the uint256.max sentinel (V4 now
        // matches the V3 behavior), so this assume filters unfillable requests and only
        // fully-fillable quotes reach the parity assertion below.
        vm.assume(quotedIn > 0 && quotedIn < MAX_IN);

        Pool[] memory path = new Pool[](1);
        path[0] = pool;
        Quote memory quote = Quote({path: path, amountIn: quotedIn, amountOut: amountOut});

        uint256 amountIn = router.swapExactOutput(quote, recipient, block.timestamp, false);
        assertEq(amountIn, quotedIn, "seeded V4 exact-out: realized input must equal quote bit-for-bit");
        assertEq(ERC20(address(token6)).balanceOf(recipient), amountOut, "recipient must receive the exact output");
    }

    /// @notice Same parity with a protocol fee set on the seeded pool (F8 coverage on a
    /// pool whose shape we control)
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_seededParity_exactIn_withProtocolFee(uint256 amountIn, uint128 liq) public {
        liq = uint128(bound(liq, 1e18, 1e24));
        _seedPositions(liq, liq / 2, liq / 4, liq / 8);

        vm.prank(ProtocolFees(POOL_MANAGER).protocolFeeController());
        ProtocolFees(POOL_MANAGER).setProtocolFee(poolKey, (uint24(700) << 12) | uint24(300));

        amountIn = bound(amountIn, 1e3, MAX_IN);

        Pool memory pool = _v4Pool(address(token18), address(token6));
        uint256 quoted = router.externalV4QuoteExactIn(SwapHop({pool: pool, amountSpecified: amountIn}));
        vm.assume(quoted > 0);

        Pool[] memory path = new Pool[](1);
        path[0] = pool;
        Quote memory quote = Quote({path: path, amountIn: amountIn, amountOut: quoted});

        uint256 amountOut = router.swapExactInput(quote, recipient, block.timestamp, false);
        assertEq(amountOut, quoted, "protocol-fee seeded pool: parity must hold bit-for-bit");
    }

    /// @notice Reverse direction (token6 -> token18): the opposite swap direction of
    /// testFuzz_seededParity_exactIn, so tick crossings and boundary rounding are
    /// exercised on the other side of spot.
    /// @dev The pool is priced 1:1 in raw units, so the raw input bound mirrors MAX_IN.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_seededParity_exactIn_reverse(uint256 amountIn, uint128 l1, uint128 l2, uint128 l3, uint128 l4)
        public
    {
        (l1, l2, l3, l4) = _bounds(l1, l2, l3, l4);
        _seedPositions(l1, l2, l3, l4);

        amountIn = bound(amountIn, 1e3, MAX_IN);

        Pool memory pool = _v4Pool(address(token6), address(token18));
        uint256 quoted = router.externalV4QuoteExactIn(SwapHop({pool: pool, amountSpecified: amountIn}));
        vm.assume(quoted > 0);

        Pool[] memory path = new Pool[](1);
        path[0] = pool;
        Quote memory quote = Quote({path: path, amountIn: amountIn, amountOut: quoted});

        uint256 amountOut = router.swapExactInput(quote, recipient, block.timestamp, false);
        assertEq(amountOut, quoted, "seeded V4 reverse exact-in: realized output must equal quote bit-for-bit");
        assertEq(ERC20(address(token18)).balanceOf(recipient), amountOut, "recipient must hold the output");
    }

    /// @notice Reverse direction (token6 -> token18) exact-out, mirroring
    /// testFuzz_seededParity_exactOut on the opposite swap direction.
    /// @dev The pool is priced 1:1 in raw units, so the raw output bound (1e12) mirrors
    /// the forward test's 1_000_000e6 and the raw input cap (1e24) mirrors MAX_IN.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_seededParity_exactOut_reverse(uint256 amountOut, uint128 l1, uint128 l2, uint128 l3, uint128 l4)
        public
    {
        (l1, l2, l3, l4) = _bounds(l1, l2, l3, l4);
        _seedPositions(l1, l2, l3, l4);

        amountOut = bound(amountOut, 1e3, 1e12);

        Pool memory pool = _v4Pool(address(token6), address(token18));
        uint256 quotedIn = router.externalV4QuoteExactOut(SwapHop({pool: pool, amountSpecified: amountOut}));
        // Beyond pool depth the full-fill check surfaces the uint256.max unfillable
        // sentinel; this assume filters those so only fully-fillable quotes reach the
        // parity assertion below.
        vm.assume(quotedIn > 0 && quotedIn < 1e24);

        Pool[] memory path = new Pool[](1);
        path[0] = pool;
        Quote memory quote = Quote({path: path, amountIn: quotedIn, amountOut: amountOut});

        uint256 amountIn = router.swapExactOutput(quote, recipient, block.timestamp, false);
        assertEq(amountIn, quotedIn, "seeded V4 reverse exact-out: realized input must equal quote bit-for-bit");
        assertEq(ERC20(address(token18)).balanceOf(recipient), amountOut, "recipient must receive the exact output");
    }

    /// @notice Reverse direction (token6 -> token18) with the same asymmetric protocol
    /// fee config as testFuzz_seededParity_exactIn_withProtocolFee. The config sets a
    /// different fee for each swap direction, so swapping the opposite way exercises the
    /// directional fee component the forward test does not.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_seededParity_exactIn_withProtocolFee_reverse(uint256 amountIn, uint128 liq) public {
        liq = uint128(bound(liq, 1e18, 1e24));
        _seedPositions(liq, liq / 2, liq / 4, liq / 8);

        vm.prank(ProtocolFees(POOL_MANAGER).protocolFeeController());
        ProtocolFees(POOL_MANAGER).setProtocolFee(poolKey, (uint24(700) << 12) | uint24(300));

        amountIn = bound(amountIn, 1e3, MAX_IN);

        Pool memory pool = _v4Pool(address(token6), address(token18));
        uint256 quoted = router.externalV4QuoteExactIn(SwapHop({pool: pool, amountSpecified: amountIn}));
        vm.assume(quoted > 0);

        Pool[] memory path = new Pool[](1);
        path[0] = pool;
        Quote memory quote = Quote({path: path, amountIn: amountIn, amountOut: quoted});

        uint256 amountOut = router.swapExactInput(quote, recipient, block.timestamp, false);
        assertEq(amountOut, quoted, "protocol-fee seeded pool (reverse): parity must hold bit-for-bit");
    }
}
