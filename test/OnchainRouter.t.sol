// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {IUniswapV3Factory} from "v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV2Factory} from "v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {OnchainRouter} from "../src/OnchainRouter.sol";
import {PathGenerator} from "../src/base/PathGenerator.sol";
import {SwapParams, Quote} from "../src/base/OnchainRouterStructs.sol";
import {OnchainRouterExposed} from "./utils/OnchainRouterExposed.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

contract RouterForkTest is Test {
    // ======== Storage ========
    OnchainRouterExposed router;
    IUniswapV3Factory v3Factory;
    IUniswapV2Factory v2Factory;

    // ======== Constants ========
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    uint24 constant FEE_LOW = 500;
    uint24 constant FEE_MEDIUM = 3000;
    uint24 constant FEE_HIGH = 10000;

    // Common test amounts
    uint256 constant USDC_AMOUNT = 1000 * 1e6; // 1000 USDC
    uint256 constant ETH_AMOUNT = 1 ether;
    uint256 constant WBTC_AMOUNT = 1e8; // 1 WBTC

    // ======== Setup ========
    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpc, 19685800);

        v3Factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
        v2Factory = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);

        router = new OnchainRouterExposed(address(v2Factory), address(v3Factory), address(0), WETH, address(this));
    }

    // ======== Fee Tier Tests ========
    function test_defaultFeeTiers() public {
        assertEq(uint256(router.feeTiers(0)), uint256(FEE_LOW) / 5); // 100
        assertEq(uint256(router.feeTiers(1)), uint256(FEE_LOW)); // 500
        assertEq(uint256(router.feeTiers(2)), uint256(FEE_MEDIUM)); // 3000
        assertEq(uint256(router.feeTiers(3)), uint256(FEE_HIGH)); // 10000
        vm.expectRevert();
        router.feeTiers(4);
    }

    function test_addNewFeeTier() public {
        uint24 newFeeTier = 1234;
        vm.prank(v3Factory.owner());
        v3Factory.enableFeeAmount(newFeeTier, 60);

        router.addNewFeeTier(newFeeTier);
        assertEq(uint256(router.feeTiers(4)), uint256(newFeeTier));
    }

    function test_addNewFeeTier_fails_whenNotEnabled() public {
        uint24 invalidFeeTier = 123412;
        vm.expectRevert(PathGenerator.InvalidFeeTier.selector);
        router.addNewFeeTier(invalidFeeTier);
    }

    // ======== Single Hop Tests ========
    function test_exactInput_singleHop_USDC_WETH() public {
        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: USDC, tokenOut: WETH});

        Quote memory quote = router.routeExactInput(params);

        // Should use V3 pool with 0.05% fee
        address expectedPool = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
        assertEq(quote.path.length, 1, "Should be single hop");
        assertEq(quote.path[0].pool, expectedPool, "Should use optimal pool");
        assertTrue(quote.amountOut > 0, "Should have non-zero output");

        // Verify single hop matches
        Quote memory singleHop = router.externalRouteExactInputSingle(params);
        assertEq(singleHop.amountOut, quote.amountOut, "Single hop amount should match");
        assertEq(singleHop.path.length, quote.path.length, "Path length should match");
        assertEq(singleHop.path[0].pool, quote.path[0].pool, "Pool should match");
    }

    function test_exactOutput_singleHop_USDC_WETH() public {
        SwapParams memory params = SwapParams({amountSpecified: ETH_AMOUNT, tokenIn: USDC, tokenOut: WETH});

        Quote memory quote = router.routeExactOutput(params);

        // Should use V3 pool with 0.05% fee
        address expectedPool = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
        assertEq(quote.path.length, 1, "Should be single hop");
        assertEq(quote.path[0].pool, expectedPool, "Should use optimal pool");
        assertTrue(quote.amountIn > 0, "Should have non-zero input");

        // Verify single hop matches
        Quote memory singleHop = router.externalRouteExactOutputSingle(params);
        assertEq(singleHop.amountIn, quote.amountIn, "Single hop amount should match");
        assertEq(singleHop.path.length, quote.path.length, "Path length should match");
        assertEq(singleHop.path[0].pool, quote.path[0].pool, "Pool should match");
    }

    // ======== Multi Hop Tests ========
    function test_exactInput_multiHop_USDC_WBTC() public {
        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: USDC, tokenOut: WBTC});

        Quote memory quote = router.routeExactInput(params);

        assertEq(quote.path.length, 2, "Should be two hops");
        assertTrue(quote.amountOut > 0, "Should have non-zero output");
    }

    function test_exactOutput_multiHop_USDC_WBTC() public {
        SwapParams memory params = SwapParams({amountSpecified: WBTC_AMOUNT, tokenIn: USDC, tokenOut: WBTC});

        Quote memory quote = router.routeExactOutput(params);

        assertEq(quote.path.length, 2, "Should be two hops");
        assertTrue(quote.amountIn > 0, "Should have non-zero input");
    }

    // ======== Edge Cases ========
    function test_routeExactInput_fails_whenTokensAreSame() public {
        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: USDC, tokenOut: USDC});

        vm.expectRevert(bytes("UniswapV2Library: IDENTICAL_ADDRESSES"));
        router.routeExactInput(params);
    }

    function test_routeExactOutput_fails_whenTokensAreSame() public {
        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: USDC, tokenOut: USDC});

        vm.expectRevert(bytes("UniswapV2Library: IDENTICAL_ADDRESSES"));
        router.routeExactOutput(params);
    }

    // ======== Different Fee Tier Tests ========

    // ======== Token Decimals Tests ========
    function test_exactInput_differentDecimals_DAI_USDC() public {
        // DAI (18 decimals) to USDC (6 decimals)
        SwapParams memory params = SwapParams({
            amountSpecified: 1000 * 1e18, // 1000 DAI
            tokenIn: DAI,
            tokenOut: USDC
        });

        Quote memory quote = router.routeExactInput(params);
        assertTrue(quote.amountOut > 0, "Should have non-zero output");
        assertTrue(quote.amountOut < 1e12, "Output should be in USDC decimals (6)");
    }

    function test_exactOutput_differentDecimals_DAI_USDC() public {
        // Want 1000 USDC (6 decimals) paying with DAI (18 decimals)
        SwapParams memory params = SwapParams({
            amountSpecified: 1000 * 1e6, // 1000 USDC
            tokenIn: DAI,
            tokenOut: USDC
        });

        Quote memory quote = router.routeExactOutput(params);
        assertTrue(quote.amountIn > 0, "Should have non-zero input");
        assertTrue(quote.amountIn > 1e18, "Input should be in DAI decimals (18)");
    }

    // ======== Multi-Pool Route Tests ========
    function test_routeExactInput_prefersSingleHop() public {
        // Test that router prefers single-hop route when available
        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: USDC, tokenOut: WETH});

        Quote memory quote = router.routeExactInput(params);
        assertEq(quote.path.length, 1, "Should prefer single-hop route");
    }

    function test_routeExactOutput_prefersSingleHop() public {
        // Test that router prefers single-hop route when available
        SwapParams memory params = SwapParams({amountSpecified: ETH_AMOUNT, tokenIn: USDC, tokenOut: WETH});

        Quote memory quote = router.routeExactOutput(params);
        assertEq(quote.path.length, 1, "Should prefer single-hop route");
    }
}

contract SwapExecutionForkTest is Test {
    OnchainRouter router;
    IUniswapV3Factory v3Factory;
    IUniswapV2Factory v2Factory;

    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // USDC uses FiatTokenProxy; `balances` mapping is at storage slot 9
    uint256 constant USDC_BALANCE_SLOT = 9;

    uint256 constant USDC_AMOUNT = 1000 * 1e6;
    uint256 constant ETH_AMOUNT = 1 ether;

    address recipient;

    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpc, 19685800);

        v3Factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
        v2Factory = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);

        router = new OnchainRouter(address(v2Factory), address(v3Factory), address(0), WETH, address(this));
        recipient = makeAddr("recipient");
    }

    /// @dev Write directly to USDC's balance storage slot (proxy-safe)
    function _dealUSDC(address to, uint256 amount) internal {
        vm.store(USDC, keccak256(abi.encode(to, USDC_BALANCE_SLOT)), bytes32(amount));
    }

    // ======== ERC20 → ERC20 Exact Input ========
    function test_swapExactInput_ERC20_to_ERC20() public {
        // USDC → WETH
        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: USDC, tokenOut: WETH});
        Quote memory quote = router.routeExactInput(params);

        _dealUSDC(address(this), quote.amountIn);
        ERC20(USDC).approve(address(router), quote.amountIn);

        uint256 amountOut = router.swapExactInput(quote, recipient, block.timestamp, false);

        assertGt(amountOut, 0, "Should receive output tokens");
        assertEq(ERC20(WETH).balanceOf(recipient), amountOut, "Recipient should receive WETH");
    }

    // ======== ERC20 → ERC20 Exact Output ========
    function test_swapExactOutput_ERC20_to_ERC20() public {
        // USDC → WETH, want exactly 1 ETH worth of WETH
        SwapParams memory params = SwapParams({amountSpecified: ETH_AMOUNT, tokenIn: USDC, tokenOut: WETH});
        Quote memory quote = router.routeExactOutput(params);

        _dealUSDC(address(this), quote.amountIn);
        ERC20(USDC).approve(address(router), quote.amountIn);

        uint256 balanceBefore = ERC20(USDC).balanceOf(address(this));
        uint256 amountIn = router.swapExactOutput(quote, recipient, block.timestamp, false);

        uint256 balanceAfter = ERC20(USDC).balanceOf(address(this));
        assertEq(ERC20(WETH).balanceOf(recipient), ETH_AMOUNT, "Recipient should receive exact WETH");
        assertLe(amountIn, quote.amountIn, "Actual input should not exceed quoted max");
        assertEq(balanceAfter, balanceBefore - amountIn, "Excess should be refunded");
    }

    // ======== ETH → ERC20 Exact Input ========
    function test_swapExactInput_ETH_to_ERC20() public {
        // ETH → USDC
        SwapParams memory params = SwapParams({amountSpecified: ETH_AMOUNT, tokenIn: WETH, tokenOut: USDC});
        Quote memory quote = router.routeExactInput(params);

        uint256 amountOut = router.swapExactInput{value: ETH_AMOUNT}(quote, recipient, block.timestamp, false);

        assertGt(amountOut, 0, "Should receive USDC");
        assertEq(ERC20(USDC).balanceOf(recipient), amountOut, "Recipient should receive USDC");
    }

    // ======== ETH → ERC20 Exact Output with Refund ========
    function test_swapExactOutput_ETH_to_ERC20_refund() public {
        // ETH → USDC, want exactly 1000 USDC
        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: WETH, tokenOut: USDC});
        Quote memory quote = router.routeExactOutput(params);

        uint256 ethBefore = address(this).balance;
        uint256 amountIn = router.swapExactOutput{value: quote.amountIn}(quote, recipient, block.timestamp, false);

        assertEq(ERC20(USDC).balanceOf(recipient), USDC_AMOUNT, "Recipient should receive exact USDC");
        uint256 ethAfter = address(this).balance;
        assertEq(ethAfter, ethBefore - amountIn, "Excess ETH should be refunded");
    }

    // ======== ERC20 → ETH Exact Input with Unwrap ========
    function test_swapExactInput_ERC20_to_ETH_unwrap() public {
        // USDC → WETH, unwrap to ETH
        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: USDC, tokenOut: WETH});
        Quote memory quote = router.routeExactInput(params);

        _dealUSDC(address(this), quote.amountIn);
        ERC20(USDC).approve(address(router), quote.amountIn);

        uint256 ethBefore = recipient.balance;
        uint256 amountOut = router.swapExactInput(quote, recipient, block.timestamp, true);

        assertGt(amountOut, 0, "Should receive output");
        assertEq(recipient.balance - ethBefore, amountOut, "Recipient should receive ETH");
        assertEq(ERC20(WETH).balanceOf(recipient), 0, "Recipient should not have WETH");
    }

    // ======== Deadline Revert ========
    function test_swapExactInput_reverts_deadlineExpired() public {
        // Use ETH input to avoid USDC deal issues in revert test
        SwapParams memory params = SwapParams({amountSpecified: ETH_AMOUNT, tokenIn: WETH, tokenOut: USDC});
        Quote memory quote = router.routeExactInput(params);

        vm.expectRevert(OnchainRouter.DeadlineExpired.selector);
        router.swapExactInput{value: ETH_AMOUNT}(quote, recipient, block.timestamp - 1, false);
    }

    function test_swapExactOutput_reverts_deadlineExpired() public {
        // Use ETH input to avoid USDC deal issues in revert test
        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: WETH, tokenOut: USDC});
        Quote memory quote = router.routeExactOutput(params);

        vm.expectRevert(OnchainRouter.DeadlineExpired.selector);
        router.swapExactOutput{value: quote.amountIn}(quote, recipient, block.timestamp - 1, false);
    }

    // ======== Multi-hop Swap Execution ========
    function test_swapExactInput_multiHop_USDC_WBTC() public {
        // USDC → WBTC via WETH (multi-hop)
        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: USDC, tokenOut: WBTC});
        Quote memory quote = router.routeExactInput(params);

        assertEq(quote.path.length, 2, "Should be multi-hop");

        _dealUSDC(address(this), quote.amountIn);
        ERC20(USDC).approve(address(router), quote.amountIn);

        uint256 amountOut = router.swapExactInput(quote, recipient, block.timestamp, false);

        assertGt(amountOut, 0, "Should receive WBTC");
        assertEq(ERC20(WBTC).balanceOf(recipient), amountOut, "Recipient should receive WBTC");
    }

    receive() external payable {}
}
