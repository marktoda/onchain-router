// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IUniswapV3Factory} from "v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {SwapParams, Quote} from "../src/base/OnchainRouterStructs.sol";
import {OnchainRouterExposed} from "./utils/OnchainRouterExposed.sol";
import {MainnetForkFixture} from "./utils/ForkFixtures.sol";
import {V3PositionMinter} from "./utils/V3PositionMinter.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice Parity properties against a SEEDED V3 pool: fresh tokens, a fresh pool created
/// through the real mainnet factory at the pinned block, positions we control.
/// @dev Same rationale as SeededV4Parity: live pools rarely force multi-tick crossings,
/// so QuoterMath's tick loop needs a pool whose initialized-tick layout is ours. Creating
/// the pool through the canonical factory avoids committing prebuilt 0.7.6 artifacts.
contract SeededV3ParityTest is MainnetForkFixture {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    OnchainRouterExposed router;
    V3PositionMinter minter;
    MockERC20 token18;
    MockERC20 token6;
    address pool;

    address recipient;

    function setUp() public {
        _forkMainnet();
        router = new OnchainRouterExposed(V2_FACTORY, V3_FACTORY, address(0), WETH);
        minter = new V3PositionMinter();
        recipient = makeAddr("recipient");

        token18 = new MockERC20("Token18", "T18", 18);
        token6 = new MockERC20("Token6", "T6", 6);

        pool = IUniswapV3Factory(V3_FACTORY).createPool(address(token18), address(token6), 3000);
        IUniswapV3Pool(pool).initialize(SQRT_PRICE_1_1);

        // Fund the minter; it pays whatever each mint's callback demands
        token18.mint(address(minter), type(uint128).max);
        token6.mint(address(minter), type(uint128).max);

        token18.mint(address(this), type(uint128).max);
        token6.mint(address(this), type(uint128).max);
        token18.approve(address(router), type(uint256).max);
        token6.approve(address(router), type(uint256).max);
    }

    /// @dev Staggered ranges so large swaps must cross several initialized ticks
    function _seedPositions(uint128 l1, uint128 l2, uint128 l3, uint128 l4) internal {
        int24[4] memory lowers = [int24(-60), int24(-180), int24(-600), int24(-3000)];
        int24[4] memory uppers = [int24(60), int24(180), int24(600), int24(3000)];
        uint128[4] memory liqs = [l1, l2, l3, l4];
        for (uint256 i = 0; i < 4; i++) {
            minter.mint(pool, lowers[i], uppers[i], liqs[i]);
        }
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
    function testFuzz_seededV3Parity_exactIn(uint256 amountIn, uint128 l1, uint128 l2, uint128 l3, uint128 l4) public {
        (l1, l2, l3, l4) = _bounds(l1, l2, l3, l4);
        _seedPositions(l1, l2, l3, l4);

        amountIn = bound(amountIn, 1e3, 1_000_000e18);

        SwapParams memory params =
            SwapParams({amountSpecified: amountIn, tokenIn: address(token18), tokenOut: address(token6)});
        Quote memory quote = router.routeExactInput(params);
        vm.assume(quote.amountOut > 0);

        uint256 amountOut = router.swapExactInput(quote, recipient, block.timestamp, false);
        assertEq(amountOut, quote.amountOut, "seeded V3 exact-in: realized output must equal quote bit-for-bit");
        assertEq(ERC20(address(token6)).balanceOf(recipient), amountOut, "recipient must hold the output");
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_seededV3Parity_exactOut(uint256 amountOut, uint128 l1, uint128 l2, uint128 l3, uint128 l4)
        public
    {
        (l1, l2, l3, l4) = _bounds(l1, l2, l3, l4);
        _seedPositions(l1, l2, l3, l4);

        amountOut = bound(amountOut, 1e3, 1_000_000e6);

        SwapParams memory params =
            SwapParams({amountSpecified: amountOut, tokenIn: address(token18), tokenOut: address(token6)});
        Quote memory quote = router.routeExactOutput(params);
        // Beyond pool depth the quoter's full-fill check surfaces the uint256.max
        // unfillable sentinel; this assume filters those so only fully-fillable quotes
        // reach the parity assertion below.
        vm.assume(quote.amountIn > 0 && quote.amountIn < 1_000_000e18);

        uint256 amountIn = router.swapExactOutput(quote, recipient, block.timestamp, false);
        assertEq(amountIn, quote.amountIn, "seeded V3 exact-out: realized input must equal quote bit-for-bit");
        assertEq(ERC20(address(token6)).balanceOf(recipient), amountOut, "recipient must receive the exact output");
    }

    /// @notice Reverse direction (token6 -> token18) for the opposite tick-crossing halves.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_seededV3Parity_exactIn_reverse(uint256 amountIn, uint128 l1, uint128 l2, uint128 l3, uint128 l4)
        public
    {
        (l1, l2, l3, l4) = _bounds(l1, l2, l3, l4);
        _seedPositions(l1, l2, l3, l4);

        amountIn = bound(amountIn, 1e3, 1_000_000e6);

        SwapParams memory params =
            SwapParams({amountSpecified: amountIn, tokenIn: address(token6), tokenOut: address(token18)});
        Quote memory quote = router.routeExactInput(params);
        vm.assume(quote.amountOut > 0);

        uint256 amountOut = router.swapExactInput(quote, recipient, block.timestamp, false);
        assertEq(amountOut, quote.amountOut, "seeded V3 reverse exact-in: realized output must equal quote bit-for-bit");
        assertEq(ERC20(address(token18)).balanceOf(recipient), amountOut, "recipient must hold the output");
    }

    /// @notice Reverse direction (token6 -> token18) exact-out, mirroring
    /// testFuzz_seededV3Parity_exactOut on the opposite swap direction.
    /// @dev The pool is priced 1:1 in raw units, so the raw output bound (1e12) mirrors
    /// the forward test's 1_000_000e6 and the raw input cap (1e24) mirrors 1_000_000e18.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_seededV3Parity_exactOut_reverse(uint256 amountOut, uint128 l1, uint128 l2, uint128 l3, uint128 l4)
        public
    {
        (l1, l2, l3, l4) = _bounds(l1, l2, l3, l4);
        _seedPositions(l1, l2, l3, l4);

        amountOut = bound(amountOut, 1e3, 1e12);

        SwapParams memory params =
            SwapParams({amountSpecified: amountOut, tokenIn: address(token6), tokenOut: address(token18)});
        Quote memory quote = router.routeExactOutput(params);
        // Beyond pool depth the quoter's full-fill check surfaces the uint256.max
        // unfillable sentinel; this assume filters those so only fully-fillable quotes
        // reach the parity assertion below.
        vm.assume(quote.amountIn > 0 && quote.amountIn < 1e24);

        uint256 amountIn = router.swapExactOutput(quote, recipient, block.timestamp, false);
        assertEq(amountIn, quote.amountIn, "seeded V3 reverse exact-out: realized input must equal quote bit-for-bit");
        assertEq(ERC20(address(token18)).balanceOf(recipient), amountOut, "recipient must receive the exact output");
    }
}
