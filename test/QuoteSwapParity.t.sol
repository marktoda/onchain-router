// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {SwapParams, Quote, Pool, SwapHop, V4} from "../src/base/OnchainRouterStructs.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {OnchainRouterExposed} from "./utils/OnchainRouterExposed.sol";
import {MainnetForkFixture, BaseForkFixture, hasV4Hop} from "./utils/ForkFixtures.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice Quoter/executor parity property tests (TDD 5.3 launch blocker).
/// @dev The quoters re-implement the pool swap math against live state; execution calls
/// the real pools. These tests assert the two agree bit-for-bit: quote and swap run in
/// the same forked state, so any difference is a rounding divergence in the quoter, the
/// exact class of bug that reverts every boundary swap in production.
contract QuoteSwapParityMainnetTest is MainnetForkFixture {
    OnchainRouterExposed router;

    address recipient;

    function setUp() public {
        _forkMainnet();
        router = new OnchainRouterExposed(V2_FACTORY, V3_FACTORY, address(0), WETH);
        recipient = makeAddr("recipient");
    }

    // ======== Exact-input parity: realized output must equal quoted output exactly ========

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_parity_exactIn_USDC_WETH(uint256 amountIn) public {
        // 1 USDC .. 5M USDC: deep enough to force multi-tick crossings on V3
        amountIn = bound(amountIn, 1e6, 5_000_000e6);

        SwapParams memory params = SwapParams({amountSpecified: amountIn, tokenIn: USDC, tokenOut: WETH});
        Quote memory quote = router.routeExactInput(params);
        vm.assume(quote.amountOut > 0); // quoter gas-cap failure is a legitimate outcome, tested separately

        _dealUSDC(address(this), amountIn);
        ERC20(USDC).approve(address(router), amountIn);

        uint256 amountOut = router.swapExactInput(quote, recipient, block.timestamp, false);
        assertEq(amountOut, quote.amountOut, "exact-in: realized output must equal quote bit-for-bit");
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_parity_exactIn_WETH_WBTC(uint256 amountIn) public {
        amountIn = bound(amountIn, 0.001 ether, 500 ether);

        SwapParams memory params = SwapParams({amountSpecified: amountIn, tokenIn: WETH, tokenOut: WBTC});
        Quote memory quote = router.routeExactInput(params);
        vm.assume(quote.amountOut > 0);

        deal(WETH, address(this), amountIn);
        ERC20(WETH).approve(address(router), amountIn);

        uint256 amountOut = router.swapExactInput(quote, recipient, block.timestamp, false);
        assertEq(amountOut, quote.amountOut, "exact-in: realized output must equal quote bit-for-bit");
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_parity_exactIn_multihop_USDC_WBTC(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e6, 1_000_000e6);

        // Force the 2-hop route so per-hop quoting parity compounds across the path
        SwapParams memory params = SwapParams({amountSpecified: amountIn, tokenIn: USDC, tokenOut: WBTC});
        Quote memory quote = router.externalRouteExactInputMulti(params, WETH);
        vm.assume(quote.amountOut > 0);

        _dealUSDC(address(this), amountIn);
        ERC20(USDC).approve(address(router), amountIn);

        uint256 amountOut = router.swapExactInput(quote, recipient, block.timestamp, false);
        assertEq(amountOut, quote.amountOut, "exact-in multihop: realized output must equal quote bit-for-bit");
    }

    // ======== Exact-output parity: realized input must equal quoted input exactly ========

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_parity_exactOut_USDC_WETH(uint256 amountOut) public {
        // Bounded below pool depth: beyond it the quoter reports a partial fill the
        // executor would reject, a separate behavior from rounding parity
        amountOut = bound(amountOut, 0.0001 ether, 500 ether);

        SwapParams memory params = SwapParams({amountSpecified: amountOut, tokenIn: USDC, tokenOut: WETH});
        Quote memory quote = router.routeExactOutput(params);
        vm.assume(quote.amountIn > 0 && quote.amountIn < type(uint128).max);

        _dealUSDC(address(this), quote.amountIn);
        ERC20(USDC).approve(address(router), quote.amountIn);

        uint256 amountIn = router.swapExactOutput(quote, recipient, block.timestamp, false);
        assertEq(amountIn, quote.amountIn, "exact-out: realized input must equal quote bit-for-bit");
        assertEq(ERC20(WETH).balanceOf(recipient), amountOut, "exact-out: delivered amount must be exact");
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_parity_exactOut_multihop_USDC_WBTC(uint256 amountOut) public {
        amountOut = bound(amountOut, 0.0001e8, 10e8);

        SwapParams memory params = SwapParams({amountSpecified: amountOut, tokenIn: USDC, tokenOut: WBTC});
        Quote memory quote = router.externalRouteExactOutputMulti(params, WETH);
        vm.assume(quote.amountIn > 0 && quote.amountIn < type(uint128).max);

        _dealUSDC(address(this), quote.amountIn);
        ERC20(USDC).approve(address(router), quote.amountIn);

        uint256 amountIn = router.swapExactOutput(quote, recipient, block.timestamp, false);
        assertEq(amountIn, quote.amountIn, "exact-out multihop: realized input must equal quote bit-for-bit");
        assertEq(ERC20(WBTC).balanceOf(recipient), amountOut, "exact-out: delivered amount must be exact");
    }
}

/// @notice V4 parity on a Base fork against live discovered pools.
/// @dev Scope: hookless pools with zero protocol fee. Hooked pools may legitimately
/// diverge (the quoter is hook-unaware by design) and a nonzero protocol fee is a KNOWN
/// quoter gap (V4QuoterMath passes only key.fee to computeSwapStep); pools where either
/// applies are skipped here and must be addressed before the parity gate is complete.
contract QuoteSwapParityV4BaseTest is BaseForkFixture {
    OnchainRouterExposed router;

    address recipient;

    function setUp() public {
        // Pinned for reproducible fuzz counterexamples
        _forkBase(32_000_000);
        router = new OnchainRouterExposed(V2_FACTORY, V3_FACTORY, POOL_MANAGER, WETH);
        recipient = makeAddr("recipient");
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_parity_v4_exactIn_ETH_USDC(uint256 amountIn) public {
        amountIn = bound(amountIn, 0.0001 ether, 50 ether);

        SwapParams memory params = SwapParams({amountSpecified: amountIn, tokenIn: WETH, tokenOut: USDC});
        Quote memory quote = router.routeExactInput(params);
        if (quote.amountOut == 0 || !hasV4Hop(quote)) return; // skip runs where V4 does not win

        vm.deal(address(this), amountIn);
        uint256 amountOut = router.swapExactInput{value: amountIn}(quote, recipient, block.timestamp, false);
        assertEq(amountOut, quote.amountOut, "V4 exact-in: realized output must equal quote bit-for-bit");
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_parity_v4_exactOut_ETH_USDC(uint256 amountOut) public {
        // Kept well within live-pool depth: the V4 full-fill check now returns the
        // unfillable sentinel for over-depth requests, so a wide range would reject too
        // many fuzz inputs via the assume below
        amountOut = bound(amountOut, 1e6, 5_000e6);

        SwapParams memory params = SwapParams({amountSpecified: amountOut, tokenIn: WETH, tokenOut: USDC});
        Quote memory quote = router.routeExactOutput(params);
        // Early return, not vm.assume: after the V4 full-fill fix an over-depth request
        // is correctly excluded and V3 may win, so a V4 route is not guaranteed at every
        // fuzzed size; skip those runs cleanly rather than exhausting the assume budget
        if (quote.amountIn == 0 || quote.amountIn >= 1_000 ether || !hasV4Hop(quote)) return;

        vm.deal(address(this), quote.amountIn);
        uint256 amountIn = router.swapExactOutput{value: quote.amountIn}(quote, recipient, block.timestamp, false);
        assertEq(amountIn, quote.amountIn, "V4 exact-out: realized input must equal quote bit-for-bit");
        assertEq(ERC20(USDC).balanceOf(recipient), amountOut, "V4 exact-out: delivered amount must be exact");
    }

    receive() external payable {}
}

/// @notice F8: V4 parity must hold when the pool charges a protocol fee.
/// @dev Pool.swap composes swapFee = protocolFee + lpFee; a quoter that only uses key.fee
/// quotes high on every protocol-fee pool and the exact-bound design then reverts every
/// swap. The fee is set here by impersonating the protocol fee controller on a live pool.
contract QuoteSwapParityV4ProtocolFeeTest is BaseForkFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    OnchainRouterExposed router;
    IPoolManager pm;

    address recipient;
    PoolKey poolKey;
    bool poolFound;
    address tokenIn; // address(0) for native ETH pools

    function setUp() public {
        _forkBase(32_000_000);
        pm = IPoolManager(POOL_MANAGER);
        router = new OnchainRouterExposed(V2_FACTORY, V3_FACTORY, POOL_MANAGER, WETH);
        recipient = makeAddr("recipient");

        // Probe default hookless configs for an ETH/USDC or WETH/USDC pool with real
        // liquidity (an initialized-but-empty pool would quote zero and prove nothing)
        uint24[4] memory fees = [uint24(500), uint24(3000), uint24(10000), uint24(100)];
        int24[4] memory spacings = [int24(10), int24(60), int24(200), int24(1)];
        address[2] memory candidates = [address(0), WETH];
        for (uint256 c = 0; c < candidates.length && !poolFound; c++) {
            for (uint256 i = 0; i < fees.length && !poolFound; i++) {
                PoolKey memory key = _makeKey(candidates[c], USDC, fees[i], spacings[i]);
                (uint160 sqrtPrice,,,) = pm.getSlot0(key.toId());
                if (sqrtPrice != 0 && pm.getLiquidity(key.toId()) > 1e15) {
                    poolKey = key;
                    poolFound = true;
                    tokenIn = candidates[c];
                }
            }
        }

        if (poolFound) {
            // 0.05% protocol fee in both directions (max is 0.1%)
            // Asymmetric on purpose: the two directional fee getters must diverge
            uint24 protocolFee = (uint24(700) << 12) | uint24(300);
            vm.prank(pm.protocolFeeController());
            pm.setProtocolFee(poolKey, protocolFee);
        }
    }

    function _makeKey(address tokenA, address tokenB, uint24 fee, int24 tickSpacing)
        private
        pure
        returns (PoolKey memory)
    {
        Currency c0 = Currency.wrap(tokenA);
        Currency c1 = Currency.wrap(tokenB);
        if (c0 > c1) (c0, c1) = (c1, c0);
        return PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(address(0))});
    }

    function _poolQuote(uint256 amountIn) internal view returns (Quote memory quote, uint256 quoted) {
        Pool[] memory path = new Pool[](1);
        path[0] =
            Pool({tokenIn: tokenIn, tokenOut: USDC, fee: poolKey.fee, pool: address(0), version: V4, key: poolKey});
        quoted = router.externalV4QuoteExactIn(SwapHop({pool: path[0], amountSpecified: amountIn}));
        quote = Quote({path: path, amountIn: amountIn, amountOut: quoted});
    }

    /// forge-config: default.fuzz.runs = 24
    function testFuzz_parity_v4_protocolFee_exactIn(uint256 amountIn) public {
        vm.skip(!poolFound);
        amountIn = bound(amountIn, 0.0001 ether, 20 ether);

        (Quote memory quote, uint256 quoted) = _poolQuote(amountIn);
        vm.assume(quoted > 0);

        vm.deal(address(this), amountIn);
        uint256 amountOut = router.swapExactInput{value: amountIn}(quote, recipient, block.timestamp, false);
        assertEq(amountOut, quoted, "protocol-fee pool: realized output must equal quote bit-for-bit");
    }

    /// @notice Exact-out through the protocol-fee pool: covers the fee composition on
    /// the exact-output quote path
    function test_parity_v4_protocolFee_exactOut() public {
        vm.skip(!poolFound);

        uint256 amountOut = 1_000e6;
        Pool[] memory path = new Pool[](1);
        path[0] =
            Pool({tokenIn: tokenIn, tokenOut: USDC, fee: poolKey.fee, pool: address(0), version: V4, key: poolKey});
        uint256 quotedIn = router.externalV4QuoteExactOut(SwapHop({pool: path[0], amountSpecified: amountOut}));
        vm.assume(quotedIn > 0 && quotedIn < 100 ether);

        Quote memory quote = Quote({path: path, amountIn: quotedIn, amountOut: amountOut});
        vm.deal(address(this), quotedIn);
        uint256 amountIn = router.swapExactOutput{value: quotedIn}(quote, recipient, block.timestamp, false);
        assertEq(amountIn, quotedIn, "protocol-fee exact-out: realized input must equal quote bit-for-bit");
    }

    /// @notice The reverse direction (USDC in): exercises getOneForZeroFee, which differs
    /// from the zeroForOne fee because the configured protocol fee is asymmetric
    function test_parity_v4_protocolFee_oneForZero() public {
        vm.skip(!poolFound);

        _dealUSDC(address(this), 10_000e6);
        ERC20(USDC).approve(address(router), type(uint256).max);

        Pool[] memory path = new Pool[](1);
        path[0] =
            Pool({tokenIn: USDC, tokenOut: tokenIn, fee: poolKey.fee, pool: address(0), version: V4, key: poolKey});
        uint256 quoted = router.externalV4QuoteExactIn(SwapHop({pool: path[0], amountSpecified: 5_000e6}));
        vm.assume(quoted > 0);

        Quote memory quote = Quote({path: path, amountIn: 5_000e6, amountOut: quoted});
        uint256 amountOut = router.swapExactInput(quote, recipient, block.timestamp, false);
        assertEq(amountOut, quoted, "protocol-fee oneForZero: realized output must equal quote bit-for-bit");
    }

    function test_parity_v4_protocolFee_singleShot() public {
        vm.skip(!poolFound);
        (Quote memory quote, uint256 quoted) = _poolQuote(0.05 ether);
        assertGt(quoted, 0, "Probed pool must produce a usable quote");

        vm.deal(address(this), 0.05 ether);
        uint256 amountOut = router.swapExactInput{value: 0.05 ether}(quote, recipient, block.timestamp, false);
        assertEq(amountOut, quoted, "protocol-fee pool: realized output must equal quote bit-for-bit");
    }

    receive() external payable {}
}
