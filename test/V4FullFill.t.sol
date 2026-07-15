// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {SwapParams, Quote, Pool, SwapHop, V4} from "../src/base/OnchainRouterStructs.sol";
import {SwapExecutor} from "../src/base/SwapExecutor.sol";
import {OnchainRouterExposed} from "./utils/OnchainRouterExposed.sol";
import {BaseForkFixture} from "./utils/ForkFixtures.sol";

contract MockV3Factory {
    function feeAmountTickSpacing(uint24) external pure returns (int24) {
        return 0;
    }

    function getPool(address, address, uint24) external pure returns (address) {
        return address(0);
    }
}

contract MockV2Factory {
    function getPair(address, address) external pure returns (address) {
        return address(0);
    }
}

/// @notice V4 exact-output must reject a pool that can only partial-fill, mirroring V3's
/// V3InvalidAmountOut. Without the check a shallow pool quotes an artificially low
/// amountIn, wins better(), and under-delivers at execution.
contract V4FullFillTest is BaseForkFixture {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    IPoolManager manager;
    PoolModifyLiquidityTest lpRouter;
    OnchainRouterExposed router;
    MockERC20 tokenA;
    MockERC20 tokenB;
    PoolKey poolKey;
    Pool pool;
    address recipient;

    function setUp() public {
        _forkBase(32_000_000);
        manager = IPoolManager(POOL_MANAGER);
        lpRouter = new PoolModifyLiquidityTest(manager);
        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        router =
            new OnchainRouterExposed(address(new MockV2Factory()), address(new MockV3Factory()), POOL_MANAGER, WETH);
        recipient = makeAddr("recipient");

        (Currency c0, Currency c1) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));
        poolKey = PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))});
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        tokenA.mint(address(this), type(uint128).max);
        tokenB.mint(address(this), type(uint128).max);
        tokenA.approve(address(lpRouter), type(uint256).max);
        tokenB.approve(address(lpRouter), type(uint256).max);
        tokenA.approve(address(router), type(uint256).max);

        // Shallow, single narrow position
        lpRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: int256(1e15), salt: 0}), ""
        );

        pool = Pool({
            tokenIn: address(tokenA), tokenOut: address(tokenB), fee: 3000, pool: address(0), version: V4, key: poolKey
        });
    }

    /// @dev Execution is not gas-capped, so an over-depth exact-output request cleanly
    /// partial-fills at the pool; the executor's full-fill check must reject it rather
    /// than silently deliver less than requested.
    function test_v4ExactOut_overDepth_executionRevertsInvalidAmountOut() public {
        Pool[] memory path = new Pool[](1);
        path[0] = pool;
        // amountOut far exceeds pool depth; amountIn generously funded and bounded
        Quote memory quote = Quote({path: path, amountIn: 1e24, amountOut: 1_000e18});

        vm.expectRevert(SwapExecutor.V4InvalidAmountOut.selector);
        router.swapExactOutput(quote, recipient, block.timestamp, false, 1e24);
    }

    /// @dev A fillable exact-output request still quotes a real amountIn and executes.
    function test_v4ExactOut_withinDepth_quotesAndExecutes() public {
        uint256 amountOut = 1e11;
        uint256 quotedIn = router.externalV4QuoteExactOut(SwapHop({pool: pool, amountSpecified: amountOut}));
        assertGt(quotedIn, 0, "Fillable exact-out must quote a real amountIn");
        assertTrue(quotedIn != type(uint256).max, "Fillable exact-out must not be the sentinel");

        Pool[] memory path = new Pool[](1);
        path[0] = pool;
        Quote memory quote = Quote({path: path, amountIn: quotedIn, amountOut: amountOut});
        uint256 amountIn = router.swapExactOutput(quote, recipient, block.timestamp, false, quotedIn);
        assertEq(MockERC20(address(tokenB)).balanceOf(recipient), amountOut, "Exact output delivered");
        assertLe(amountIn, quotedIn, "Input within bound");
    }

    receive() external payable {}
}
