// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Quote, Pool, V4} from "../src/base/OnchainRouterStructs.sol";
import {SwapExecutor} from "../src/base/SwapExecutor.sol";
import {OnchainRouterExposed} from "./utils/OnchainRouterExposed.sol";
import {BaseForkFixture} from "./utils/ForkFixtures.sol";

contract StrandingMockV3Factory {
    function feeAmountTickSpacing(uint24) external pure returns (int24) {
        return 0;
    }

    function getPool(address, address, uint24) external pure returns (address) {
        return address(0);
    }
}

contract StrandingMockV2Factory {
    function getPair(address, address) external pure returns (address) {
        return address(0);
    }
}

/// @notice A multihop exact-input swap whose LATER hop cannot consume its full input must
/// revert rather than strand the intermediate token in the router.
/// @dev This is the case the input refund in OnchainRouter structurally cannot cover: the
/// refund measures the caller's input token, but a second hop's remainder is denominated in
/// the intermediate. Under a loose minAmountOut the terminal TooLittleReceived check does not
/// fire either, so before the full-consumption check the swap "succeeded" while the caller
/// silently lost the stranded intermediate, and any later caller could sweep it.
contract IntermediateStrandingTest is BaseForkFixture {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    // Full range for tickSpacing 60
    int24 constant FULL_RANGE_LOWER = -887220;
    int24 constant FULL_RANGE_UPPER = 887220;

    IPoolManager manager;
    PoolModifyLiquidityTest lpRouter;
    OnchainRouterExposed router;
    MockERC20 tokenA;
    MockERC20 tokenI; // intermediate
    MockERC20 tokenB;
    PoolKey deepKey; // A <-> I, deep
    PoolKey shallowKey; // I <-> B, shallow
    address recipient;

    function setUp() public {
        _forkBase(32_000_000);
        manager = IPoolManager(POOL_MANAGER);
        lpRouter = new PoolModifyLiquidityTest(manager);
        router = new OnchainRouterExposed(
            address(new StrandingMockV2Factory()), address(new StrandingMockV3Factory()), POOL_MANAGER, WETH
        );
        recipient = makeAddr("recipient");

        tokenA = new MockERC20("A", "A", 18);
        tokenI = new MockERC20("I", "I", 18);
        tokenB = new MockERC20("B", "B", 18);

        deepKey = _key(address(tokenA), address(tokenI));
        shallowKey = _key(address(tokenI), address(tokenB));
        manager.initialize(deepKey, SQRT_PRICE_1_1);
        manager.initialize(shallowKey, SQRT_PRICE_1_1);

        tokenA.mint(address(this), type(uint128).max);
        tokenI.mint(address(this), type(uint128).max);
        tokenB.mint(address(this), type(uint128).max);
        tokenA.approve(address(lpRouter), type(uint256).max);
        tokenI.approve(address(lpRouter), type(uint256).max);
        tokenB.approve(address(lpRouter), type(uint256).max);
        tokenA.approve(address(router), type(uint256).max);

        // Hop 1 is deep and full-range, so it absorbs the whole input.
        lpRouter.modifyLiquidity(
            deepKey,
            ModifyLiquidityParams({
                tickLower: FULL_RANGE_LOWER,
                tickUpper: FULL_RANGE_UPPER,
                liquidityDelta: int256(1e21),
                salt: 0
            }),
            ""
        );
        // Hop 2 is deliberately shallow and narrow, so it cannot.
        lpRouter.modifyLiquidity(
            shallowKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: int256(1e15), salt: 0}),
            ""
        );
    }

    function _key(address t0, address t1) internal pure returns (PoolKey memory) {
        (Currency c0, Currency c1) =
            t0 < t1 ? (Currency.wrap(t0), Currency.wrap(t1)) : (Currency.wrap(t1), Currency.wrap(t0));
        return PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))});
    }

    function _twoHopPath() internal view returns (Pool[] memory path) {
        path = new Pool[](2);
        path[0] = Pool({
            tokenIn: address(tokenA),
            tokenOut: address(tokenI),
            fee: 3000,
            pool: address(0),
            version: V4,
            key: deepKey
        });
        path[1] = Pool({
            tokenIn: address(tokenI),
            tokenOut: address(tokenB),
            fee: 3000,
            pool: address(0),
            version: V4,
            key: shallowKey
        });
    }

    /// @notice The stranding case: hop 1 fills fully, hop 2 cannot, loose bound.
    function test_multihop_secondHopPartialFill_revertsAndStrandsNothing() public {
        // Large enough that the shallow second hop cannot absorb hop 1's output.
        Quote memory quote = Quote({path: _twoHopPath(), amountIn: 1e14, amountOut: 0});

        // minAmountOut = 1: deliberately loose, so TooLittleReceived cannot mask the issue
        vm.expectRevert(SwapExecutor.V4IncompleteInput.selector);
        router.swapExactInput(quote, recipient, block.timestamp, false, 1);

        assertEq(tokenI.balanceOf(address(router)), 0, "No intermediate may strand in the router");
        assertEq(tokenA.balanceOf(address(router)), 0, "No input may strand in the router");
    }

    /// @notice A multihop sized within BOTH hops' depth still succeeds, so the guard is not
    /// simply rejecting all multihop routes.
    function test_multihop_withinDepth_succeeds() public {
        Quote memory quote = Quote({path: _twoHopPath(), amountIn: 1e11, amountOut: 0});

        uint256 amountOut = router.swapExactInput(quote, recipient, block.timestamp, false, 1);

        assertGt(amountOut, 0, "In-depth multihop must deliver output");
        assertEq(tokenB.balanceOf(recipient), amountOut, "Recipient must receive the output token");
        assertEq(tokenI.balanceOf(address(router)), 0, "No intermediate may strand in the router");
    }
}
