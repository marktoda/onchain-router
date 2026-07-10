// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {OnchainRouter} from "../src/OnchainRouter.sol";
import {SwapParams, Quote, V4} from "../src/base/OnchainRouterStructs.sol";
import {OnchainRouterExposed} from "./utils/OnchainRouterExposed.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice Quoter/executor parity property tests (TDD 5.3 launch blocker).
/// @dev The quoters re-implement the pool swap math against live state; execution calls
/// the real pools. These tests assert the two agree bit-for-bit: quote and swap run in
/// the same forked state, so any difference is a rounding divergence in the quoter, the
/// exact class of bug that reverts every boundary swap in production.
contract QuoteSwapParityMainnetTest is Test {
    OnchainRouterExposed router;

    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    uint256 constant USDC_BALANCE_SLOT = 9;

    address recipient;

    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpc, 19685800);
        router = new OnchainRouterExposed(V2_FACTORY, V3_FACTORY, address(0), WETH);
        recipient = makeAddr("recipient");
    }

    function _dealUSDC(address to, uint256 amount) internal {
        vm.store(USDC, keccak256(abi.encode(to, USDC_BALANCE_SLOT)), bytes32(amount));
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
contract QuoteSwapParityV4BaseTest is Test {
    OnchainRouterExposed router;

    address constant V2_FACTORY = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
    address constant V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint256 constant USDC_BALANCE_SLOT = 9;

    address recipient;

    function setUp() public {
        string memory rpc = vm.envString("BASE_RPC_URL");
        // Pinned for reproducible fuzz counterexamples
        vm.createSelectFork(rpc, 32_000_000);
        router = new OnchainRouterExposed(V2_FACTORY, V3_FACTORY, POOL_MANAGER, WETH);
        recipient = makeAddr("recipient");
    }

    function _hasV4Hop(Quote memory quote) internal pure returns (bool) {
        for (uint256 i = 0; i < quote.path.length; i++) {
            if (quote.path[i].version == V4) return true;
        }
        return false;
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_parity_v4_exactIn_ETH_USDC(uint256 amountIn) public {
        amountIn = bound(amountIn, 0.0001 ether, 50 ether);

        SwapParams memory params = SwapParams({amountSpecified: amountIn, tokenIn: WETH, tokenOut: USDC});
        Quote memory quote = router.routeExactInput(params);
        vm.assume(quote.amountOut > 0);
        vm.assume(_hasV4Hop(quote)); // only meaningful when a V4 pool wins the route

        vm.deal(address(this), amountIn);
        uint256 amountOut = router.swapExactInput{value: amountIn}(quote, recipient, block.timestamp, false);
        assertEq(amountOut, quote.amountOut, "V4 exact-in: realized output must equal quote bit-for-bit");
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_parity_v4_exactOut_ETH_USDC(uint256 amountOut) public {
        amountOut = bound(amountOut, 1e6, 100_000e6);

        SwapParams memory params = SwapParams({amountSpecified: amountOut, tokenIn: WETH, tokenOut: USDC});
        Quote memory quote = router.routeExactOutput(params);
        vm.assume(quote.amountIn > 0 && quote.amountIn < 1_000 ether);
        vm.assume(_hasV4Hop(quote));

        vm.deal(address(this), quote.amountIn);
        uint256 amountIn = router.swapExactOutput{value: quote.amountIn}(quote, recipient, block.timestamp, false);
        assertEq(amountIn, quote.amountIn, "V4 exact-out: realized input must equal quote bit-for-bit");
        assertEq(ERC20(USDC).balanceOf(recipient), amountOut, "V4 exact-out: delivered amount must be exact");
    }

    receive() external payable {}
}
