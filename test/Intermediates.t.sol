// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IUniswapV3Factory} from "v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {OnchainRouter} from "../src/OnchainRouter.sol";
import {Ownable2Step} from "../src/base/Ownable2Step.sol";
import {SwapParams, Quote} from "../src/base/OnchainRouterStructs.sol";
import {OnchainRouterExposed} from "./utils/OnchainRouterExposed.sol";
import {MainnetForkFixture} from "./utils/ForkFixtures.sol";
import {V3PositionMinter} from "./utils/V3PositionMinter.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice F6: configurable intermediate-token set. WETH's wrapper role (native ETH) is
/// pinned to the immutable; only the ROUTING intermediates are configurable, owner-gated.
contract IntermediatesTest is MainnetForkFixture {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    OnchainRouterExposed router;
    V3PositionMinter minter;
    MockERC20 tokenA; // 18 decimals
    MockERC20 tokenB; // 18 decimals

    address recipient;

    function setUp() public {
        _forkMainnet();
        router = new OnchainRouterExposed(V2_FACTORY, V3_FACTORY, address(0), WETH, address(this));
        minter = new V3PositionMinter();
        recipient = makeAddr("recipient");

        tokenA = new MockERC20("TokenA", "TKA", 18);
        tokenB = new MockERC20("TokenB", "TKB", 18);

        // The ONLY route between tokenA and tokenB is through USDC: no direct pool, no
        // WETH pools. With the default intermediate set ([WETH]) the pair is unroutable;
        // adding USDC as an intermediate is what makes it routable.
        _createPool(address(tokenA), USDC);
        _createPool(USDC, address(tokenB));

        tokenA.mint(address(this), type(uint128).max);
        tokenA.approve(address(router), type(uint256).max);
    }

    function _createPool(address t0, address t1) internal {
        address pool = IUniswapV3Factory(V3_FACTORY).createPool(t0, t1, 3000);
        IUniswapV3Pool(pool).initialize(SQRT_PRICE_1_1);
        if (t0 != USDC) MockERC20(t0).mint(address(minter), type(uint128).max);
        if (t1 != USDC) MockERC20(t1).mint(address(minter), type(uint128).max);
        _dealUSDC(address(minter), type(uint128).max);
        minter.mint(pool, -6000, 6000, 3e22);
    }

    // ======== Admin: access control, cap, dedup ========

    function test_intermediates_initialSetIsWeth() public {
        assertEq(router.intermediateTokensLength(), 1);
        assertEq(router.intermediateTokens(0), WETH);
    }

    function test_addIntermediateToken_onlyOwner() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(Ownable2Step.NotOwner.selector);
        router.addIntermediateToken(USDC);
    }

    function test_removeIntermediateToken_onlyOwner() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(Ownable2Step.NotOwner.selector);
        router.removeIntermediateToken(WETH);
    }

    function test_addIntermediateToken_rejectsDuplicateAndZero() public {
        vm.expectRevert(OnchainRouter.DuplicateIntermediate.selector);
        router.addIntermediateToken(WETH);
        vm.expectRevert(OnchainRouter.InvalidIntermediate.selector);
        router.addIntermediateToken(address(0));
    }

    function test_addIntermediateToken_enforcesCap() public {
        router.addIntermediateToken(USDC);
        router.addIntermediateToken(DAI);
        router.addIntermediateToken(WBTC);
        router.addIntermediateToken(address(tokenA));
        vm.expectRevert(OnchainRouter.TooManyIntermediates.selector);
        router.addIntermediateToken(address(tokenB));
    }

    function test_removeIntermediateToken_removesAndReverts() public {
        router.addIntermediateToken(USDC);
        router.removeIntermediateToken(USDC);
        assertEq(router.intermediateTokensLength(), 1);
        vm.expectRevert(OnchainRouter.IntermediateNotFound.selector);
        router.removeIntermediateToken(USDC);
    }

    function test_constructor_rejectsZeroOwner() public {
        vm.expectRevert(Ownable2Step.ZeroOwner.selector);
        new OnchainRouterExposed(V2_FACTORY, V3_FACTORY, address(0), WETH, address(0));
    }

    function test_acceptOwnership_revertsForNonPendingCaller() public {
        router.transferOwnership(makeAddr("newOwner"));
        vm.prank(makeAddr("rando"));
        vm.expectRevert(Ownable2Step.NotPendingOwner.selector);
        router.acceptOwnership();
    }

    function test_intermediateEvents_emitted() public {
        vm.expectEmit(true, false, false, true);
        emit OnchainRouter.IntermediateTokenAdded(USDC);
        router.addIntermediateToken(USDC);

        vm.expectEmit(true, false, false, true);
        emit OnchainRouter.IntermediateTokenRemoved(USDC);
        router.removeIntermediateToken(USDC);
    }

    function test_ownershipEvents_emitted() public {
        address newOwner = makeAddr("newOwner");
        vm.expectEmit(true, true, false, true);
        emit Ownable2Step.OwnershipTransferStarted(address(this), newOwner);
        router.transferOwnership(newOwner);

        vm.expectEmit(true, true, false, true);
        emit Ownable2Step.OwnershipTransferred(address(this), newOwner);
        vm.prank(newOwner);
        router.acceptOwnership();
    }

    function test_ownership_twoStepTransfer() public {
        address newOwner = makeAddr("newOwner");
        router.transferOwnership(newOwner);
        assertEq(router.owner(), address(this), "Transfer must not complete before acceptance");

        vm.prank(newOwner);
        router.acceptOwnership();
        assertEq(router.owner(), newOwner);

        // Old owner has lost admin rights
        vm.expectRevert(Ownable2Step.NotOwner.selector);
        router.addIntermediateToken(USDC);
    }

    // ======== Routing through a configured intermediate ========

    function test_routeExactInput_findsRouteOnlyViaAddedIntermediate() public {
        SwapParams memory params =
            SwapParams({amountSpecified: 100e18, tokenIn: address(tokenA), tokenOut: address(tokenB)});

        // Default set (WETH only): unroutable
        Quote memory before = router.routeExactInput(params);
        assertEq(before.amountOut, 0, "Pair must be unroutable via WETH alone");

        router.addIntermediateToken(USDC);
        Quote memory quote = router.routeExactInput(params);
        assertGt(quote.amountOut, 0, "USDC intermediate must make the pair routable");
        assertEq(quote.path.length, 2, "Route must be 2-hop");
        assertEq(quote.path[0].tokenOut, USDC, "First hop must land on the added intermediate");

        // And the route executes with correct delivery
        uint256 amountOut = router.swapExactInput(quote, recipient, block.timestamp, false);
        assertEq(amountOut, quote.amountOut, "Parity must hold through the added intermediate");
        assertEq(ERC20(address(tokenB)).balanceOf(recipient), amountOut);
    }

    function test_routeExactOutput_refundsInInputUnits_viaAddedIntermediate() public {
        router.addIntermediateToken(USDC);

        SwapParams memory params =
            SwapParams({amountSpecified: 100e18, tokenIn: address(tokenA), tokenOut: address(tokenB)});
        Quote memory quote = router.routeExactOutput(params);
        assertGt(quote.amountIn, 0, "Exact-out route must exist via USDC");

        uint256 maxAmountIn = (quote.amountIn * 101) / 100;
        uint256 balanceBefore = ERC20(address(tokenA)).balanceOf(address(this));
        uint256 amountIn = router.swapExactOutput(quote, recipient, block.timestamp, false, maxAmountIn);

        assertEq(ERC20(address(tokenB)).balanceOf(recipient), 100e18, "Exact output must be delivered");
        assertEq(
            ERC20(address(tokenA)).balanceOf(address(this)),
            balanceBefore - amountIn,
            "Refund must be exact, in tokenA units, through the non-WETH intermediate"
        );
        assertEq(ERC20(address(tokenA)).balanceOf(address(router)), 0, "Nothing stranded");
    }

    function test_intermediateEqualToEndpoint_isSkippedNotFatal() public {
        router.addIntermediateToken(USDC);

        // tokenOut IS the intermediate: the USDC candidate must be skipped while the
        // route still resolves (direct tokenA -> USDC pool exists)
        SwapParams memory params = SwapParams({amountSpecified: 100e18, tokenIn: address(tokenA), tokenOut: USDC});
        Quote memory quote = router.routeExactInput(params);
        assertGt(quote.amountOut, 0, "Direct route must be found");
        assertEq(quote.path.length, 1, "Must be the direct single-hop route");
    }

    // ======== Native-ETH handling is unaffected by the routing set ========

    function test_nativeEth_worksWithNonWethIntermediateConfigured() public {
        router.addIntermediateToken(USDC);

        // ETH in (wraps to WETH via the immutable), USDC out; USDC-as-intermediate is
        // skipped because it is the output token, and the wrapper role is untouched
        SwapParams memory params = SwapParams({amountSpecified: 1 ether, tokenIn: WETH, tokenOut: USDC});
        Quote memory quote = router.routeExactInput(params);
        assertGt(quote.amountOut, 0);

        uint256 amountOut = router.swapExactInput{value: 1 ether}(quote, recipient, block.timestamp, false);
        assertEq(amountOut, quote.amountOut, "Native-ETH swap must be unaffected by the routing set");
        assertEq(ERC20(USDC).balanceOf(recipient), amountOut);
    }

    function test_removingWeth_disablesWethRouting_notWrapping() public {
        router.addIntermediateToken(USDC);
        router.removeIntermediateToken(WETH);

        // WETH no longer a routing hop: DAI -> WBTC (real tokens, best route was via
        // WETH) must now route via USDC or direct only. Prove the negative: no hop of
        // the winning route may pass through WETH anymore.
        SwapParams memory params = SwapParams({amountSpecified: 1_000e18, tokenIn: DAI, tokenOut: WBTC});

        Quote memory baseline = router.externalRouteExactInputMulti(params, WETH);
        assertGt(baseline.amountOut, 0, "A WETH-hop route must exist for this pair (test precondition)");

        Quote memory quote = router.routeExactInput(params);
        assertGt(quote.amountOut, 0, "Pair must remain routable without WETH as an intermediate");
        for (uint256 i = 0; i < quote.path.length; i++) {
            assertTrue(
                quote.path[i].tokenOut != WETH || i == quote.path.length - 1,
                "No intermediate hop may pass through WETH after its removal from the set"
            );
        }

        // But native-ETH wrapping still works (wrapper role is the immutable, not the set)
        SwapParams memory ethParams = SwapParams({amountSpecified: 1 ether, tokenIn: WETH, tokenOut: USDC});
        Quote memory ethQuote = router.routeExactInput(ethParams);
        uint256 amountOut = router.swapExactInput{value: 1 ether}(ethQuote, recipient, block.timestamp, false);
        assertGt(amountOut, 0, "Wrapping must survive WETH's removal from the routing set");
    }

    receive() external payable {}
}
