// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Quote, Pool, SwapHop, V4} from "../src/base/OnchainRouterStructs.sol";
import {OnchainRouterExposed} from "./utils/OnchainRouterExposed.sol";
import {MockV3Factory, MockV2Factory} from "./utils/MockFactories.sol";
import {BaseForkFixture} from "./utils/ForkFixtures.sol";

/// @notice Minimal hook that only sets a dynamic LP fee OUT-OF-BAND, in its own transaction.
/// @dev updateDynamicLPFee requires msg.sender == key.hooks, so the call has to originate
/// here. Deliberately carries no swap-phase permissions: v4-core allows a flagless hook
/// address precisely when the pool's fee is dynamic (Hooks.isValidHookAddress), and the
/// registry's hook gate accepts it because it holds neither *_RETURNS_DELTA permission.
/// The manager is a parameter rather than an immutable so the runtime code can be etched to a
/// chosen address without carrying constructor state.
contract OutOfBandDynamicFeeHook {
    function setFee(IPoolManager manager, PoolKey calldata key, uint24 newFee) external {
        manager.updateDynamicLPFee(key, newFee);
    }
}

/// @notice Quoter/executor parity on a DYNAMIC-FEE V4 pool.
/// @dev Closes the "by construction, not yet tested" gap that V4Quoter, V4QuoterMath, and the
/// README all hedged about. The quoter reads the effective LP fee from live slot0 rather than
/// from key.fee (which holds only the 0x800000 sentinel on these pools), so a dynamic-fee pool
/// should quote and execute identically, and the quote should track the fee when it changes.
/// Only OUT-OF-BAND updates are in scope: a per-swap lpFeeOverride returned from beforeSwap
/// never reaches slot0 before the quote reads it and is documented as uncovered.
contract DynamicFeeParityTest is BaseForkFixture {
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    /// @dev Low 14 bits clear, so the address carries no hook permission flags.
    address constant HOOK_ADDR = 0x1234000000000000000000000000000000000000;

    IPoolManager manager;
    PoolModifyLiquidityTest lpRouter;
    OnchainRouterExposed router;
    OutOfBandDynamicFeeHook hook;
    MockERC20 tokenA;
    MockERC20 tokenB;
    PoolKey poolKey;
    Pool pool;
    address recipient;

    function setUp() public {
        _forkBase(32_000_000);
        manager = IPoolManager(POOL_MANAGER);
        lpRouter = new PoolModifyLiquidityTest(manager);
        router =
            new OnchainRouterExposed(address(new MockV2Factory()), address(new MockV3Factory()), POOL_MANAGER, WETH);
        recipient = makeAddr("recipient");

        // Deploy, then place the runtime code at a flag-free address. A CREATE address would
        // carry arbitrary low bits and could fail Hooks.isValidHookAddress.
        vm.etch(HOOK_ADDR, address(new OutOfBandDynamicFeeHook()).code);
        hook = OutOfBandDynamicFeeHook(HOOK_ADDR);

        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);

        (Currency c0, Currency c1) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));
        poolKey = PoolKey({
            currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 60, hooks: IHooks(HOOK_ADDR)
        });
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        tokenA.mint(address(this), type(uint128).max);
        tokenB.mint(address(this), type(uint128).max);
        tokenA.approve(address(lpRouter), type(uint256).max);
        tokenB.approve(address(lpRouter), type(uint256).max);
        tokenA.approve(address(router), type(uint256).max);

        // Deep, wide liquidity: this suite is about fee handling, not depth limits.
        lpRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: int256(1e21), salt: 0}),
            ""
        );

        pool = Pool({
            tokenIn: address(tokenA), tokenOut: address(tokenB), fee: 0, pool: address(0), version: V4, key: poolKey
        });
    }

    function _quoteIn(uint256 amountIn) internal view returns (uint256) {
        return router.externalV4QuoteExactIn(SwapHop({pool: pool, amountSpecified: amountIn}));
    }

    function _swapIn(uint256 amountIn) internal returns (uint256) {
        Pool[] memory path = new Pool[](1);
        path[0] = pool;
        Quote memory quote = Quote({path: path, amountIn: amountIn, amountOut: 0});
        return router.swapExactInput(quote, recipient, block.timestamp, false, 1);
    }

    /// @notice The pool really is dynamic-fee, and slot0 carries the out-of-band fee rather
    /// than the sentinel. Guards the premise of every other test here.
    function test_dynamicFeePool_slot0CarriesFeeNotSentinel() public {
        hook.setFee(manager, poolKey, 3000);

        (,,, uint24 lpFee) = manager.getSlot0(poolKey.toId());
        assertEq(lpFee, 3000, "slot0 must hold the out-of-band fee");
        assertTrue(poolKey.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG, "key.fee must still be the sentinel");
        assertTrue(LPFeeLibrary.DYNAMIC_FEE_FLAG != 3000, "sentinel must never be usable as a literal fee");
    }

    /// @notice The headline property: quote equals realized execution on a dynamic-fee pool.
    function test_dynamicFeePool_quoteMatchesExecution() public {
        hook.setFee(manager, poolKey, 3000);

        uint256 amountIn = 1e18;
        uint256 quoted = _quoteIn(amountIn);
        assertGt(quoted, 0, "dynamic-fee pool must quote a real output");

        uint256 realized = _swapIn(amountIn);
        assertEq(realized, quoted, "dynamic-fee quote must match execution bit-for-bit");
    }

    /// @notice Parity must hold across the fee range, not just at one value.
    function test_dynamicFeePool_quoteMatchesExecutionAcrossFees() public {
        uint24[4] memory fees = [uint24(100), uint24(500), uint24(3000), uint24(10_000)];
        for (uint256 i = 0; i < fees.length; i++) {
            hook.setFee(manager, poolKey, fees[i]);
            uint256 amountIn = 1e17;
            uint256 quoted = _quoteIn(amountIn);
            uint256 realized = _swapIn(amountIn);
            assertEq(realized, quoted, "quote must match execution at every dynamic fee");
        }
    }

    /// @notice The quote must MOVE with the live fee. This is what proves the quoter reads
    /// slot0 rather than treating key.fee as a literal or ignoring the fee entirely.
    function test_dynamicFeePool_quoteTracksOutOfBandFeeChange() public {
        uint256 amountIn = 1e18;

        hook.setFee(manager, poolKey, 500);
        uint256 lowFeeOut = _quoteIn(amountIn);

        hook.setFee(manager, poolKey, 10_000);
        uint256 highFeeOut = _quoteIn(amountIn);

        assertGt(lowFeeOut, 0, "low-fee quote must be real");
        assertLt(highFeeOut, lowFeeOut, "raising the LP fee must lower the quoted output");
    }

    /// @notice A fee raised between quote time and execution shows up as a shortfall the
    /// caller's bound is responsible for catching. Documents why the bound matters on these
    /// pools rather than asserting the quoter can see the future.
    function test_dynamicFeePool_feeRaisedAfterQuote_shortfallCaughtByBound() public {
        hook.setFee(manager, poolKey, 500);
        uint256 amountIn = 1e18;
        uint256 quoted = _quoteIn(amountIn);

        hook.setFee(manager, poolKey, 10_000);

        Pool[] memory path = new Pool[](1);
        path[0] = pool;
        // Zero-tolerance: the quoted output is the bound, so the stale quote must revert.
        Quote memory quote = Quote({path: path, amountIn: amountIn, amountOut: quoted});
        vm.expectRevert();
        router.swapExactInput(quote, recipient, block.timestamp, false, quoted);
    }

    receive() external payable {}
}
