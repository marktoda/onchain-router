// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IUniswapV3Factory} from "v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {SwapExecutor} from "../src/base/SwapExecutor.sol";
import {SwapParams, Quote} from "../src/base/OnchainRouterStructs.sol";
import {OnchainRouterExposed} from "./utils/OnchainRouterExposed.sol";
import {MainnetForkFixture} from "./utils/ForkFixtures.sol";
import {V3PositionMinter} from "./utils/V3PositionMinter.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice F7: opt-in 3-hop routing. A deterministic chain of fresh pools
/// (A -> X -> Y -> B, nothing else) makes the pair unroutable at 2 hops and
/// routable only by the 3-hop search through configured intermediates X and Y.
contract ThreeHopTest is MainnetForkFixture {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    OnchainRouterExposed router;
    V3PositionMinter minter;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 tokenX; // intermediate 1
    MockERC20 tokenY; // intermediate 2

    address recipient;

    function setUp() public {
        _forkMainnet();
        router = new OnchainRouterExposed(V2_FACTORY, V3_FACTORY, address(0), WETH, address(this));
        minter = new V3PositionMinter();
        recipient = makeAddr("recipient");

        tokenA = new MockERC20("TokenA", "TKA", 18);
        tokenB = new MockERC20("TokenB", "TKB", 18);
        tokenX = new MockERC20("TokenX", "TKX", 18);
        tokenY = new MockERC20("TokenY", "TKY", 18);

        // The ONLY liquidity chain is A -> X -> Y -> B
        _createPool(address(tokenA), address(tokenX));
        _createPool(address(tokenX), address(tokenY));
        _createPool(address(tokenY), address(tokenB));

        router.addIntermediateToken(address(tokenX));
        router.addIntermediateToken(address(tokenY));

        tokenA.mint(address(this), type(uint128).max);
        tokenA.approve(address(router), type(uint256).max);
    }

    function _createPool(address t0, address t1) internal {
        _createPoolLiq(t0, t1, 3e22);
    }

    function _createPoolLiq(address t0, address t1, uint128 liq) internal {
        address pool = IUniswapV3Factory(V3_FACTORY).createPool(t0, t1, 3000);
        IUniswapV3Pool(pool).initialize(SQRT_PRICE_1_1);
        MockERC20(t0).mint(address(minter), type(uint128).max);
        MockERC20(t1).mint(address(minter), type(uint128).max);
        minter.mint(pool, -6000, 6000, liq);
    }

    // ======== Routing ========

    function test_threeHop_findsRouteTwoHopCannot() public {
        SwapParams memory params =
            SwapParams({amountSpecified: 100e18, tokenIn: address(tokenA), tokenOut: address(tokenB)});

        // Standard (2-hop) routing cannot reach B
        Quote memory twoHop = router.routeExactInput(params);
        assertEq(twoHop.amountOut, 0, "Pair must be unroutable at 2 hops (test precondition)");

        // Opt-in 3-hop search finds A -> X -> Y -> B
        Quote memory quote = router.routeExactInput3Hop(params);
        assertGt(quote.amountOut, 0, "3-hop search must find the chain");
        assertEq(quote.path.length, 3, "Route must be 3 hops");
        assertEq(quote.path[0].tokenOut, address(tokenX));
        assertEq(quote.path[1].tokenOut, address(tokenY));
        assertEq(quote.path[2].tokenOut, address(tokenB));
    }

    function test_threeHop_neverWorseThanTwoHop() public {
        // Create an A -> Y pool so BOTH a 2-hop route (A -> Y -> B) and a genuine 3-hop
        // candidate (A -> X -> Y -> B) exist for the pair; the superset search must
        // compare them and return at least the 2-hop result
        _createPool(address(tokenA), address(tokenY));

        SwapParams memory params =
            SwapParams({amountSpecified: 100e18, tokenIn: address(tokenA), tokenOut: address(tokenB)});
        Quote memory twoHop = router.routeExactInput(params);
        assertGt(twoHop.amountOut, 0, "2-hop route must exist (test precondition)");

        Quote memory threeHop = router.routeExactInput3Hop(params);
        assertGe(threeHop.amountOut, twoHop.amountOut, "Superset search must never be worse");
        assertTrue(threeHop.path.length == 2 || threeHop.path.length == 3, "Winner must be a real route");
    }

    function test_threeHop_exactOut_neverWorseThanTwoHop() public {
        // Competing 2-hop (A -> Y -> B) and 3-hop (A -> X -> Y -> B) routes must both be
        // searched; the superset result can never cost more input than the 2-hop route
        _createPool(address(tokenA), address(tokenY));

        SwapParams memory params =
            SwapParams({amountSpecified: 50e18, tokenIn: address(tokenA), tokenOut: address(tokenB)});
        Quote memory twoHop = router.routeExactOutput(params);
        assertGt(twoHop.amountIn, 0, "2-hop route must exist (test precondition)");
        assertTrue(twoHop.amountIn != type(uint256).max, "2-hop route must be real");

        Quote memory threeHop = router.routeExactOutput3Hop(params);
        assertLe(threeHop.amountIn, twoHop.amountIn, "Superset search must never cost more");
        assertTrue(threeHop.path.length == 2 || threeHop.path.length == 3, "Winner must be a real route");
    }

    function test_threeHop_exactOut_skipsUnfillableLeg() public {
        // Make the X -> Y leg exist but be far too shallow to fill the requested output:
        // its exact-out quote returns the uint-max sentinel, which the 3-hop search must
        // skip rather than fold into the result
        SwapParams memory params =
            SwapParams({amountSpecified: 50_000e18, tokenIn: address(tokenA), tokenOut: address(tokenB)});
        Quote memory quote = router.routeExactOutput3Hop(params);

        // The only chain runs through the shallow legs; an unfillable request must come
        // back unroutable (0 or sentinel), never a poisoned combined quote
        assertTrue(
            quote.amountIn == 0 || quote.amountIn == type(uint256).max,
            "Unfillable 3-hop request must be reported unroutable, not mis-priced"
        );
    }

    // ======== Execution: the executor is N-hop agnostic ========

    function test_threeHop_exactIn_executesWithParity() public {
        SwapParams memory params =
            SwapParams({amountSpecified: 100e18, tokenIn: address(tokenA), tokenOut: address(tokenB)});
        Quote memory quote = router.routeExactInput3Hop(params);
        assertGt(quote.amountOut, 0);

        uint256 amountOut = router.swapExactInput(quote, recipient, block.timestamp, false);
        assertEq(amountOut, quote.amountOut, "3-hop exact-in: parity must hold bit-for-bit");
        assertEq(ERC20(address(tokenB)).balanceOf(recipient), amountOut);
    }

    function test_threeHop_exactIn_minAmountOutEnforced() public {
        SwapParams memory params =
            SwapParams({amountSpecified: 100e18, tokenIn: address(tokenA), tokenOut: address(tokenB)});
        Quote memory quote = router.routeExactInput3Hop(params);

        vm.expectRevert(SwapExecutor.TooLittleReceived.selector);
        router.swapExactInput(quote, recipient, block.timestamp, false, quote.amountOut + 1);
    }

    function test_threeHop_exactOut_executesWithExactRefund() public {
        SwapParams memory params =
            SwapParams({amountSpecified: 50e18, tokenIn: address(tokenA), tokenOut: address(tokenB)});
        Quote memory quote = router.routeExactOutput3Hop(params);
        assertGt(quote.amountIn, 0, "Exact-out 3-hop route must exist");
        assertTrue(quote.amountIn != type(uint256).max, "Quote must be real");
        assertEq(quote.path.length, 3, "Route must be 3 hops");

        uint256 maxAmountIn = (quote.amountIn * 101) / 100;
        uint256 balanceBefore = ERC20(address(tokenA)).balanceOf(address(this));
        uint256 amountIn = router.swapExactOutput(quote, recipient, block.timestamp, false, maxAmountIn);

        assertEq(ERC20(address(tokenB)).balanceOf(recipient), 50e18, "Exact output must be delivered");
        assertEq(
            ERC20(address(tokenA)).balanceOf(address(this)),
            balanceBefore - amountIn,
            "Refund must be exact in tokenA units across 3 hops"
        );
        assertEq(ERC20(address(tokenA)).balanceOf(address(router)), 0, "Nothing stranded");
    }

    function test_threeHop_exactOut_maxAmountInEnforced() public {
        SwapParams memory params =
            SwapParams({amountSpecified: 50e18, tokenIn: address(tokenA), tokenOut: address(tokenB)});
        Quote memory quote = router.routeExactOutput3Hop(params);

        uint256 maxAmountIn = (quote.amountIn * 95) / 100;
        vm.expectRevert(SwapExecutor.V3TooMuchRequested.selector);
        router.swapExactOutput(quote, recipient, block.timestamp, false, maxAmountIn);
    }

    /// @notice Exercises the INNER skip branches: with a deep A->Z->B path available and
    /// a shallow middle X->Z pool, the 3-hop candidate through (X, Z) must skip on the
    /// unfillable middle leg (legTwo) rather than fold a bad quote, while the good route
    /// still wins.
    function test_threeHop_innerSkip_onUnfillableMiddleLeg() public {
        MockERC20 tokenZ = new MockERC20("TokenZ", "TKZ", 18);
        router.addIntermediateToken(address(tokenZ));

        // Deep A->Z and Z->B so a 3-hop through Z is viable; shallow X->Z so any candidate
        // routing X->Z hits the exact-out sentinel and takes the inner skip.
        _createPoolLiq(address(tokenA), address(tokenZ), 5e23);
        _createPoolLiq(address(tokenZ), address(tokenB), 5e23);
        _createPoolLiq(address(tokenX), address(tokenZ), 1e12);

        SwapParams memory params =
            SwapParams({amountSpecified: 100e18, tokenIn: address(tokenA), tokenOut: address(tokenB)});
        Quote memory q = router.routeExactOutput3Hop(params);

        // A real route exists (A->Z->B at least); it must be priced, not poisoned by the
        // shallow X->Z candidate that the inner skip discards.
        assertGt(q.amountIn, 0, "A viable route must be found");
        assertTrue(q.amountIn != type(uint256).max, "Result must not be the unfillable sentinel");
    }

    receive() external payable {}
}
