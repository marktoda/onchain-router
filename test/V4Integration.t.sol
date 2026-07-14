// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {OnchainRouter} from "../src/OnchainRouter.sol";
import {SwapExecutor} from "../src/base/SwapExecutor.sol";
import {V4PoolRegistry} from "../src/base/V4PoolRegistry.sol";
import {SwapParams, Pool, Quote, V2, V3, V4} from "../src/base/OnchainRouterStructs.sol";
import {OnchainRouterExposed} from "./utils/OnchainRouterExposed.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {hasV4Hop} from "./utils/ForkFixtures.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @notice Base fork tests for V4 pool discovery, quoting, and execution
contract V4BaseForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    OnchainRouterExposed router;

    // Base addresses
    address constant V2_FACTORY = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
    address constant V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // USDC on Base uses FiatTokenProxy; `balances` mapping is at storage slot 9
    uint256 constant USDC_BALANCE_SLOT = 9;

    uint256 constant USDC_AMOUNT = 1000 * 1e6;
    uint256 constant ETH_AMOUNT = 1 ether;

    address recipient;

    // We'll discover which V4 pools exist in setUp and skip tests if none found
    bool v4WethUsdcExists;
    bool v4NativeEthUsdcExists;
    uint24 v4WethUsdcFee;
    int24 v4WethUsdcTickSpacing;
    uint24 v4NativeEthUsdcFee;
    int24 v4NativeEthUsdcTickSpacing;

    function setUp() public {
        string memory rpc = vm.envString("BASE_RPC_URL");
        // Pinned for deterministic CI: an unpinned fork made results depend on live Base
        // state at run time, so a swap could pass locally and revert in CI at a different
        // block. 32_000_000 matches the other Base-fork suites.
        vm.createSelectFork(rpc, 32_000_000);

        router = new OnchainRouterExposed(V2_FACTORY, V3_FACTORY, POOL_MANAGER, WETH, address(this));
        recipient = makeAddr("recipient");

        // Probe for V4 pools with default configs
        IPoolManager pm = IPoolManager(POOL_MANAGER);
        uint24[4] memory fees = [uint24(100), uint24(500), uint24(3000), uint24(10000)];
        int24[4] memory tickSpacings = [int24(1), int24(10), int24(60), int24(200)];

        for (uint256 i = 0; i < 4; i++) {
            // Check WETH/USDC V4 pool
            if (!v4WethUsdcExists) {
                PoolKey memory key = _makeKey(WETH, USDC, fees[i], tickSpacings[i]);
                (uint160 sqrtPrice,,,) = pm.getSlot0(key.toId());
                if (sqrtPrice != 0) {
                    v4WethUsdcExists = true;
                    v4WethUsdcFee = fees[i];
                    v4WethUsdcTickSpacing = tickSpacings[i];
                }
            }
            // Check native ETH/USDC V4 pool
            if (!v4NativeEthUsdcExists) {
                PoolKey memory key = _makeKey(address(0), USDC, fees[i], tickSpacings[i]);
                (uint160 sqrtPrice,,,) = pm.getSlot0(key.toId());
                if (sqrtPrice != 0) {
                    v4NativeEthUsdcExists = true;
                    v4NativeEthUsdcFee = fees[i];
                    v4NativeEthUsdcTickSpacing = tickSpacings[i];
                }
            }
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

    // ======== V4 Pool Discovery ========

    function test_v4PoolDiscovery_wethUsdc() public {
        vm.skip(!v4WethUsdcExists);

        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: USDC, tokenOut: WETH});
        Quote memory quote = router.routeExactInput(params);
        assertTrue(quote.amountOut > 0, "Should find a route");
    }

    function test_v4PoolDiscovery_nativeEthUsdc() public {
        vm.skip(!v4NativeEthUsdcExists);

        // When routing WETH→USDC, the router should also discover native ETH V4 pools
        SwapParams memory params = SwapParams({amountSpecified: ETH_AMOUNT, tokenIn: WETH, tokenOut: USDC});
        Quote memory quote = router.routeExactInput(params);
        assertTrue(quote.amountOut > 0, "Should find a route (possibly via native ETH V4 pool)");
    }

    function test_v4PoolDiscovery_returnsV4Version() public {
        vm.skip(!v4WethUsdcExists);

        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: USDC, tokenOut: WETH});
        Quote memory quote = router.routeExactInput(params);

        // Check if any pool in the winning path is V4
        bool hasV4 = false;
        for (uint256 i = 0; i < quote.path.length; i++) {
            if (quote.path[i].version == V4) {
                hasV4 = true;
                assertEq(quote.path[i].pool, address(0), "V4 pools should have pool=address(0)");
                assertTrue(quote.path[i].key.tickSpacing != 0, "V4 pools should have non-zero tickSpacing");
            }
        }
        // V4 might or might not win vs V2/V3, so just log
        if (hasV4) {
            console.log("V4 pool won the route");
        } else {
            console.log("V2/V3 pool won the route (V4 pool exists but not cheapest)");
        }
    }

    // ======== V4 Quoting ========

    function test_v4QuoteExactIn() public {
        vm.skip(!v4WethUsdcExists);

        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: USDC, tokenOut: WETH});
        Quote memory quote = router.routeExactInput(params);
        assertTrue(quote.amountOut > 0, "V4 quote should return non-zero output");
        assertTrue(quote.amountIn == USDC_AMOUNT, "Input should match specified");
    }

    function test_v4QuoteExactOut() public {
        vm.skip(!v4WethUsdcExists);

        SwapParams memory params = SwapParams({amountSpecified: ETH_AMOUNT, tokenIn: USDC, tokenOut: WETH});
        Quote memory quote = router.routeExactOutput(params);
        assertTrue(quote.amountIn > 0, "V4 quote should return non-zero input");
        assertTrue(quote.amountIn < type(uint256).max, "V4 quote should not fail");
    }

    // ======== V4 Swap Execution ========

    function test_v4SwapExactInput_ERC20() public {
        vm.skip(!v4WethUsdcExists && !v4NativeEthUsdcExists);

        SwapParams memory params = SwapParams({amountSpecified: ETH_AMOUNT, tokenIn: WETH, tokenOut: USDC});
        Quote memory quote = router.routeExactInput(params);

        deal(WETH, address(this), quote.amountIn);
        ERC20(WETH).approve(address(router), quote.amountIn);

        uint256 amountOut = router.swapExactInput(quote, recipient, block.timestamp, false);
        assertGt(amountOut, 0, "Should receive USDC");
        assertEq(ERC20(USDC).balanceOf(recipient), amountOut, "Recipient should receive USDC");
    }

    function test_v4SwapExactInput_ETH() public {
        vm.skip(!v4WethUsdcExists && !v4NativeEthUsdcExists);

        SwapParams memory params = SwapParams({amountSpecified: ETH_AMOUNT, tokenIn: WETH, tokenOut: USDC});
        Quote memory quote = router.routeExactInput(params);

        uint256 amountOut = router.swapExactInput{value: ETH_AMOUNT}(quote, recipient, block.timestamp, false);
        assertGt(amountOut, 0, "Should receive USDC");
        assertEq(ERC20(USDC).balanceOf(recipient), amountOut, "Recipient should receive USDC");
    }

    function test_v4SwapExactOutput_ERC20() public {
        vm.skip(!v4WethUsdcExists && !v4NativeEthUsdcExists);

        // Use ETH input to avoid WETH deal/approve complexity when native ETH pool wins
        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: WETH, tokenOut: USDC});
        Quote memory quote = router.routeExactOutput(params);

        uint256 amountIn = router.swapExactOutput{value: quote.amountIn}(quote, recipient, block.timestamp, false);
        assertEq(ERC20(USDC).balanceOf(recipient), USDC_AMOUNT, "Recipient should receive exact USDC");
        assertLe(amountIn, quote.amountIn, "Should not exceed quoted max input");
    }

    function test_v4SwapExactInput_unwrapOutput() public {
        vm.skip(!v4WethUsdcExists && !v4NativeEthUsdcExists);

        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: USDC, tokenOut: WETH});
        Quote memory quote = router.routeExactInput(params);

        _dealUSDC(address(this), quote.amountIn);
        ERC20(USDC).approve(address(router), quote.amountIn);

        uint256 ethBefore = recipient.balance;
        uint256 amountOut = router.swapExactInput(quote, recipient, block.timestamp, true);
        assertGt(amountOut, 0, "Should receive output");
        assertEq(recipient.balance - ethBefore, amountOut, "Recipient should receive ETH");
    }

    // ======== V4 caller-supplied bounds (hardening) ========

    function test_v4SwapExactInput_minAmountOut_bounds() public {
        vm.skip(!v4WethUsdcExists && !v4NativeEthUsdcExists);

        SwapParams memory params = SwapParams({amountSpecified: ETH_AMOUNT, tokenIn: WETH, tokenOut: USDC});
        Quote memory quote = router.routeExactInput(params);
        // Early return, not vm.skip: Foundry forbids skipping after state-changing calls,
        // and whether V4 wins this live route is only known after quoting
        if (!hasV4Hop(quote)) return;

        // Unmet bound must revert inside the V4 unlock path
        vm.expectRevert(SwapExecutor.TooLittleReceived.selector);
        router.swapExactInput{value: ETH_AMOUNT}(quote, recipient, block.timestamp, false, quote.amountOut + 1);

        // Loose caller bound must dominate an inflated quote.amountOut
        uint256 quotedOut = quote.amountOut;
        quote.amountOut = quotedOut * 2;
        uint256 minAmountOut = (quotedOut * 99) / 100;
        uint256 amountOut =
            router.swapExactInput{value: ETH_AMOUNT}(quote, recipient, block.timestamp, false, minAmountOut);
        assertGe(amountOut, minAmountOut, "Realized output should meet the caller bound");
    }

    function test_v4SwapExactOutput_maxAmountIn_bounds() public {
        vm.skip(!v4WethUsdcExists && !v4NativeEthUsdcExists);

        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: WETH, tokenOut: USDC});
        Quote memory quote = router.routeExactOutput(params);
        // Early return, not vm.skip: see exact-in variant
        if (!hasV4Hop(quote)) return;

        uint256 maxAmountIn = (quote.amountIn * 101) / 100;
        uint256 balanceBefore = address(this).balance;
        uint256 amountIn =
            router.swapExactOutput{value: maxAmountIn}(quote, recipient, block.timestamp, false, maxAmountIn);

        assertEq(ERC20(USDC).balanceOf(recipient), USDC_AMOUNT, "Recipient should receive exact USDC");
        assertLe(amountIn, maxAmountIn, "Actual input should not exceed the caller bound");
        assertEq(address(this).balance, balanceBefore - amountIn, "Unspent ETH must come back to the caller");
    }

    // ======== V4 Multi-hop (mixed V3→V4 or V4→V3) ========

    function test_v4MultiHop_routing() public {
        vm.skip(!v4WethUsdcExists && !v4NativeEthUsdcExists);

        // Route a pair that requires going through WETH (e.g., USDC→WETH→another token)
        // This tests that the router can compose V2/V3 and V4 hops
        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: USDC, tokenOut: WETH});
        Quote memory quote = router.routeExactInput(params);

        // The route should work regardless of which version wins
        assertTrue(quote.amountOut > 0, "Should find a route");
        assertTrue(quote.path.length >= 1, "Should have at least one hop");
    }

    function _dealUSDC(address to, uint256 amount) internal {
        vm.store(USDC, keccak256(abi.encode(to, USDC_BALANCE_SLOT)), bytes32(amount));
    }

    receive() external payable {}
}

/// @notice Unit tests for V4PoolRegistry leaderboard mechanism (no fork needed)
contract V4LeaderboardTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    OnchainRouterExposed router;
    address constant POOL_MANAGER = address(0xBEEF);

    // Mock tokens
    address constant TOKEN_A = address(0xA);
    address constant TOKEN_B = address(0xB);
    address constant WETH = address(0xC);

    uint256 constant CHALLENGE_DELAY = 1 days;
    uint256 constant CHALLENGE_EXPIRY = 3 days;

    function setUp() public {
        vm.etch(POOL_MANAGER, hex"00");

        address v3Factory = address(0xF3);
        vm.etch(v3Factory, hex"00");
        vm.mockCall(v3Factory, abi.encodeWithSignature("feeAmountTickSpacing(uint24)"), abi.encode(int24(0)));
        address v2Factory = address(0xF2);
        vm.etch(v2Factory, hex"00");

        router = new OnchainRouterExposed(v2Factory, v3Factory, POOL_MANAGER, WETH, address(this));
        // Start at a realistic timestamp so epoch math has room
        vm.warp(365 days * 56);
    }

    // ======== Direct registration (non-full board) ========

    function test_registerV4Pool_success() public {
        _mockPool(address(0), 1e18);
        router.registerV4Pool(TOKEN_A, TOKEN_B, 500, 10, address(0));
    }

    function test_registerV4Pool_reverts_nonExistentPool() public {
        PoolKey memory key = _makeKey(TOKEN_A, TOKEN_B, 500, 10, address(0));
        _mockSlot0(PoolId.unwrap(key.toId()), 0);
        vm.expectRevert(V4PoolRegistry.PoolDoesNotExist.selector);
        router.registerV4Pool(TOKEN_A, TOKEN_B, 500, 10, address(0));
    }

    function test_registerV4Pool_reverts_duplicate() public {
        _mockPool(address(0), 1e18);
        router.registerV4Pool(TOKEN_A, TOKEN_B, 500, 10, address(0));
        vm.expectRevert(V4PoolRegistry.DuplicatePool.selector);
        router.registerV4Pool(TOKEN_A, TOKEN_B, 500, 10, address(0));
    }

    function test_registerV4Pool_reverts_whenBoardFull() public {
        _fillBoard(100e18);
        _mockPool(address(uint160(9000)), 1000e18);
        vm.expectRevert(V4PoolRegistry.BoardFull.selector);
        router.registerV4Pool(TOKEN_A, TOKEN_B, 500, 10, address(uint160(9000)));
    }

    // ======== Two-phase challenge ========

    function test_challenge_fullFlow_evictsLowestLiquidityIncumbent() public {
        _fillBoard(100e18);
        // Incumbent #3 is the weakest
        _mockLiquidityFor(address(uint160(3000)), 5e18);

        address challenger = address(uint160(9000));
        _mockPool(challenger, 1000e18);
        router.startV4Challenge(TOKEN_A, TOKEN_B, 500, 10, challenger);

        vm.warp(block.timestamp + CHALLENGE_DELAY);
        bool success = router.finalizeV4Challenge(TOKEN_A, TOKEN_B, 500, 10, challenger);
        assertTrue(success, "Challenge must succeed against the weakest unshielded incumbent");
    }

    function test_challenge_reverts_beforeDelay() public {
        _fillBoard(100e18);
        address challenger = address(uint160(9000));
        _mockPool(challenger, 1000e18);
        router.startV4Challenge(TOKEN_A, TOKEN_B, 500, 10, challenger);

        vm.warp(block.timestamp + CHALLENGE_DELAY - 1);
        vm.expectRevert(V4PoolRegistry.ChallengeNotReady.selector);
        router.finalizeV4Challenge(TOKEN_A, TOKEN_B, 500, 10, challenger);
    }

    function test_challenge_jitLiquidity_failsAtFinalize() public {
        _fillBoard(100e18);
        address challenger = address(uint160(9000));
        _mockPool(challenger, 1000e18); // huge at declaration (the JIT deposit)
        router.startV4Challenge(TOKEN_A, TOKEN_B, 500, 10, challenger);

        // JIT capital leaves before finalization
        _mockLiquidityFor(challenger, 1);

        vm.warp(block.timestamp + CHALLENGE_DELAY);
        bool success = router.finalizeV4Challenge(TOKEN_A, TOKEN_B, 500, 10, challenger);
        assertFalse(success, "Liquidity withdrawn during the delay must lose the challenge");
    }

    function test_challenge_recentWinShieldsIncumbent() public {
        _fillBoard(100e18);
        // Incumbent #3 is weakest by liquidity BUT recently won a routed swap
        _mockLiquidityFor(address(uint160(3000)), 5e18);
        router.exposedRecordV4Win(TOKEN_A, TOKEN_B, 500, 10, address(uint160(3000)));
        // Incumbent #5 is the weakest UNSHIELDED entry
        _mockLiquidityFor(address(uint160(5000)), 50e18);

        address challenger = address(uint160(9000));
        _mockPool(challenger, 1000e18);
        router.startV4Challenge(TOKEN_A, TOKEN_B, 500, 10, challenger);
        vm.warp(block.timestamp + CHALLENGE_DELAY);
        assertTrue(router.finalizeV4Challenge(TOKEN_A, TOKEN_B, 500, 10, challenger));

        // The shielded winner survived; #5 was evicted instead. Verify by re-challenging:
        // #3 must still be listed (duplicate check hits), #5 must not be
        vm.expectRevert(V4PoolRegistry.DuplicatePool.selector);
        router.startV4Challenge(TOKEN_A, TOKEN_B, 500, 10, address(uint160(3000)));
        _mockPool(address(uint160(5000)), 10e18);
        router.startV4Challenge(TOKEN_A, TOKEN_B, 500, 10, address(uint160(5000))); // relisting attempt OK
    }

    function test_challenge_shieldExpires_afterTwoEpochs() public {
        _fillBoard(100e18);
        _mockLiquidityFor(address(uint160(3000)), 5e18);
        router.exposedRecordV4Win(TOKEN_A, TOKEN_B, 500, 10, address(uint160(3000)));

        // Two epochs later the win no longer shields
        vm.warp(block.timestamp + 2 weeks + 1 days);
        address challenger = address(uint160(9000));
        _mockPool(challenger, 1000e18);
        router.startV4Challenge(TOKEN_A, TOKEN_B, 500, 10, challenger);
        vm.warp(block.timestamp + CHALLENGE_DELAY);
        assertTrue(router.finalizeV4Challenge(TOKEN_A, TOKEN_B, 500, 10, challenger), "Stale win must not shield");

        // #3 is gone: relisting it as a challenger works (no duplicate revert)
        _mockPool(address(uint160(3000)), 10e18);
        router.startV4Challenge(TOKEN_A, TOKEN_B, 500, 10, address(uint160(3000)));
    }

    function test_challenge_allShielded_boardIsHealthy() public {
        _fillBoard(100e18);
        for (uint256 i = 1; i <= 8; i++) {
            router.exposedRecordV4Win(TOKEN_A, TOKEN_B, 500, 10, address(uint160(i * 1000)));
        }
        address challenger = address(uint160(9000));
        _mockPool(challenger, 1000e18);
        router.startV4Challenge(TOKEN_A, TOKEN_B, 500, 10, challenger);
        vm.warp(block.timestamp + CHALLENGE_DELAY);
        assertFalse(
            router.finalizeV4Challenge(TOKEN_A, TOKEN_B, 500, 10, challenger),
            "A fully shielded board cannot be evicted from"
        );
    }

    function test_challenge_perConfigKeying_concurrentChallengersAllowed() public {
        _fillBoard(100e18);
        address challengerOne = address(uint160(9000));
        _mockPool(challengerOne, 1000e18);
        router.startV4Challenge(TOKEN_A, TOKEN_B, 500, 10, challengerOne);

        // A different challenger runs concurrently: one bogus challenge cannot occupy
        // a per-pair slot and freeze eviction (the griefing DoS the keying prevents)
        address challengerTwo = address(uint160(9100));
        _mockPool(challengerTwo, 1000e18);
        router.startV4Challenge(TOKEN_A, TOKEN_B, 500, 10, challengerTwo);

        // Re-declaring the SAME challenge cannot reset its clock while it is live
        vm.expectRevert(V4PoolRegistry.ChallengePending.selector);
        router.startV4Challenge(TOKEN_A, TOKEN_B, 500, 10, challengerOne);

        // Past expiry the same config can start fresh
        vm.warp(block.timestamp + CHALLENGE_EXPIRY + 1);
        router.startV4Challenge(TOKEN_A, TOKEN_B, 500, 10, challengerOne);
    }

    function test_challenge_finalizesAtExactExpiryBoundary() public {
        _fillBoard(100e18);
        _mockLiquidityFor(address(uint160(3000)), 5e18);
        address challenger = address(uint160(9000));
        _mockPool(challenger, 1000e18);
        router.startV4Challenge(TOKEN_A, TOKEN_B, 500, 10, challenger);

        // Exactly at EXPIRY the challenge is still valid and must evict
        vm.warp(block.timestamp + CHALLENGE_EXPIRY);
        assertTrue(
            router.finalizeV4Challenge(TOKEN_A, TOKEN_B, 500, 10, challenger),
            "Finalize at exactly the expiry boundary must still succeed"
        );
    }

    function test_challenge_previousEpochWin_stillShields() public {
        _fillBoard(100e18);
        _mockLiquidityFor(address(uint160(3000)), 5e18);
        _mockLiquidityFor(address(uint160(5000)), 50e18);
        router.exposedRecordV4Win(TOKEN_A, TOKEN_B, 500, 10, address(uint160(3000)));

        // Roll into the NEXT epoch: a previous-epoch win must still shield
        vm.warp((block.timestamp / 1 weeks + 1) * 1 weeks + 1 hours);
        address challenger = address(uint160(9000));
        _mockPool(challenger, 1000e18);
        router.startV4Challenge(TOKEN_A, TOKEN_B, 500, 10, challenger);
        vm.warp(block.timestamp + CHALLENGE_DELAY);
        assertTrue(router.finalizeV4Challenge(TOKEN_A, TOKEN_B, 500, 10, challenger));

        // Shielded previous-epoch winner survived; unshielded #5 was evicted
        vm.expectRevert(V4PoolRegistry.DuplicatePool.selector);
        router.startV4Challenge(TOKEN_A, TOKEN_B, 500, 10, address(uint160(3000)));
        _mockPool(address(uint160(5000)), 10e18);
        router.startV4Challenge(TOKEN_A, TOKEN_B, 500, 10, address(uint160(5000)));
    }

    function test_challenge_expired_finalizesAsFailure() public {
        _fillBoard(100e18);
        address challenger = address(uint160(9000));
        _mockPool(challenger, 1000e18);
        router.startV4Challenge(TOKEN_A, TOKEN_B, 500, 10, challenger);

        vm.warp(block.timestamp + CHALLENGE_EXPIRY + 1);
        assertFalse(
            router.finalizeV4Challenge(TOKEN_A, TOKEN_B, 500, 10, challenger), "Expired challenge must fail, not evict"
        );
    }

    function test_startChallenge_reverts_zeroLiquidityChallenger() public {
        _fillBoard(100e18);
        address challenger = address(uint160(9000));
        _mockPool(challenger, 0);
        vm.expectRevert(V4PoolRegistry.ChallengerHasNoLiquidity.selector);
        router.startV4Challenge(TOKEN_A, TOKEN_B, 500, 10, challenger);
    }

    // ======== Helpers ========

    function _fillBoard(uint128 liquidityEach) internal {
        for (uint256 i = 1; i <= 8; i++) {
            address hooks = address(uint160(i * 1000));
            _mockPool(hooks, liquidityEach);
            router.registerV4Pool(TOKEN_A, TOKEN_B, 500, 10, hooks);
        }
    }

    function _mockPool(address hooks, uint128 liquidity) internal {
        PoolKey memory key = _makeKey(TOKEN_A, TOKEN_B, 500, 10, hooks);
        _mockSlot0(PoolId.unwrap(key.toId()), 1 << 96);
        _mockLiquidity(PoolId.unwrap(key.toId()), liquidity);
    }

    function _mockLiquidityFor(address hooks, uint128 liquidity) internal {
        PoolKey memory key = _makeKey(TOKEN_A, TOKEN_B, 500, 10, hooks);
        _mockLiquidity(PoolId.unwrap(key.toId()), liquidity);
    }

    function _makeKey(address tokenA, address tokenB, uint24 fee, int24 tickSpacing, address hooks)
        private
        pure
        returns (PoolKey memory)
    {
        Currency c0 = Currency.wrap(tokenA);
        Currency c1 = Currency.wrap(tokenB);
        if (c0 > c1) (c0, c1) = (c1, c0);
        return PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(hooks)});
    }

    /// @dev StateLibrary reads via extsload(slot); mock the specific slots
    function _mockSlot0(bytes32 poolId, uint160 sqrtPriceX96) internal {
        bytes32 stateSlot = _poolStateSlot(poolId);
        vm.mockCall(
            POOL_MANAGER,
            abi.encodeWithSignature("extsload(bytes32)", stateSlot),
            abi.encode(bytes32(uint256(sqrtPriceX96)))
        );
    }

    function _mockLiquidity(bytes32 poolId, uint128 liquidity) internal {
        bytes32 liquiditySlot = bytes32(uint256(_poolStateSlot(poolId)) + 3);
        vm.mockCall(
            POOL_MANAGER,
            abi.encodeWithSignature("extsload(bytes32)", liquiditySlot),
            abi.encode(bytes32(uint256(liquidity)))
        );
    }

    function _poolStateSlot(bytes32 poolId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(poolId, uint256(6)));
    }
}
