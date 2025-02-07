// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.6;
pragma abicoder v2;

import {Test, console, console2} from "forge-std/Test.sol";
import {IUniswapV3Factory} from "v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV2Pair} from "v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {OnchainRouter} from "../src/OnchainRouter.sol";
import {SwapParams, Quote} from "../src/base/OnchainRouterStructs.sol";
import {IFeeOnTransferDetector} from "../src/interfaces/IFeeOnTransferDetector.sol";
import {PathGenerator} from "../src/base/PathGenerator.sol";
import {OnchainRouterExposed} from "./utils/OnchainRouterExposed.sol";

contract RouterForkTest is Test {
    OnchainRouterExposed onchainRouter;
    IUniswapV3Factory v3Factory;
    IUniswapV2Factory v2Factory;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    uint24[4] currentV3FeeTiers = [uint24(100), uint24(500), uint24(3000), uint24(10000)];

    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpc, 19685800);

        v3Factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
        v2Factory = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);

        onchainRouter = new OnchainRouterExposed(address(v2Factory), address(v3Factory), WETH);
    }

    function test_getsFeeTiers() public {
        assertEq(uint256(onchainRouter.feeTiers(0)), 100);
        assertEq(uint256(onchainRouter.feeTiers(1)), 500);
        assertEq(uint256(onchainRouter.feeTiers(2)), 3000);
        assertEq(uint256(onchainRouter.feeTiers(3)), 10000);
        vm.expectRevert();
        onchainRouter.feeTiers(4);
    }

    function test_routeUsdcWethExactInput() public {
        SwapParams memory params = SwapParams({amountSpecified: 1000 * 1e6, tokenIn: USDC, tokenOut: WETH});

        Quote memory quote = onchainRouter.routeExactInput(params);

        // Should use V3 pool with 0.05% fee
        assertEq(quote.path.length, 1);
        assertEq(quote.path[0].pool, 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);
        assertEq(quote.amountOut, 326411625325180335);

        // Single hop should match since it's WETH
        Quote memory single = onchainRouter.externalRouteExactInputSingle(params);
        assertEq(single.amountOut, quote.amountOut);
        assertEq(single.path.length, quote.path.length);
        assertEq(single.path[0].pool, quote.path[0].pool);
    }

    function test_routeUsdcWethExactOutput() public {
        uint256 amountOut = 1 ether;
        SwapParams memory params = SwapParams({amountSpecified: amountOut, tokenIn: USDC, tokenOut: WETH});

        Quote memory quote = onchainRouter.routeExactOutput(params);

        // Should use V3 pool with 0.05% fee
        assertEq(quote.path.length, 1);
        assertEq(quote.path[0].pool, 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);
        assertTrue(quote.amountIn > 0);

        // Single hop should match since it's WETH
        Quote memory single = onchainRouter.externalRouteExactOutputSingle(params);
        assertEq(single.amountIn, quote.amountIn);
        assertEq(single.path.length, quote.path.length);
        assertEq(single.path[0].pool, quote.path[0].pool);
    }

    function test_routeUsdcWbtcExactInput() public {
        SwapParams memory params = SwapParams({amountSpecified: 1000 * 1e6, tokenIn: USDC, tokenOut: WBTC});

        Quote memory quote = onchainRouter.routeExactInput(params);

        // Should find best path through WETH
        assertEq(quote.path.length, 2);
        assertTrue(quote.amountOut > 0);
    }

    function test_routeUsdcWbtcExactOutput() public {
        uint256 amountOut = 1e8; // 1 WBTC
        SwapParams memory params = SwapParams({amountSpecified: amountOut, tokenIn: USDC, tokenOut: WBTC});

        Quote memory quote = onchainRouter.routeExactOutput(params);

        // Should find best path through WETH
        assertEq(quote.path.length, 2);
        assertTrue(quote.amountIn > 0);
    }

    function test_routeHarryPotter() public {
        SwapParams memory request = SwapParams({
            amountSpecified: 1000 * 1e6,
            tokenIn: USDC,
            tokenOut: 0x72e4f9F808C49A2a61dE9C5896298920Dc4EEEa9
        });

        Quote memory quote = onchainRouter.routeExactInput(request);
        console.log(quote.amountOut);
        console.log(quote.path.length);
        console.log(quote.path[0].pool);
        console.log(quote.path[1].pool);

        //address path = quotes[0].path[0].pool;
        // console.log(validQuotes);
        //
        // Quote memory multihopQuote;
        // uint256 multihopOut;
        // if ((quote.tokenIn != WETH) && (quote.tokenOut != WETH)) {
        //     (multihopQuote, multihopOut) = onchainRouter.generateAndPriceMultiHop(quote);
        // }
        // (Quote memory singehopQuote, uint256 singlehopOut) = onchainRouter.findBestQuote(quotes);
        //
        // if (singlehopOut > multihopOut) {
        //     console.log("single");
        //     console.log(singlehopOut - multihopOut);
        //     console.log(singlehopOut);
        //     address addr = singehopQuote.path[0].pool;
        //     console2.log(addr);
        // } else {
        //     console.log("multi");
        //     console.log(multihopOut - singlehopOut);
        //     console.log(multihopOut);
        //     address addr = multihopQuote.path[0].pool;
        //     console2.log(addr);
        //     addr = multihopQuote.path[1].pool;
        //     console2.log(addr);
        // }
        // assertEq(true, true);
    }

    function test_ingestNewFeeTierFail() public {
        uint24 feeTier = 123412;
        vm.expectRevert("Invalid fee tier");
        onchainRouter.addNewFeeTier(feeTier);
    }

    function test_ingestNewFeeTier() public {
        uint24 feeTier = 123412;
        vm.prank(v3Factory.owner());
        v3Factory.enableFeeAmount(feeTier, 60);

        onchainRouter.addNewFeeTier(feeTier);
        assertEq(uint256(onchainRouter.feeTiers(4)), feeTier);
    }
}
