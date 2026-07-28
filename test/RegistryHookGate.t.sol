// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {OnchainRouterExposed} from "./utils/OnchainRouterExposed.sol";
import {V4PoolRegistry} from "../src/base/V4PoolRegistry.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @notice Registration must reject hooks that can serve swaps from their own balances
/// (custom accounting), because the quoter prices core pool math only and would otherwise
/// hand out quotes the router cannot honor.
/// @dev V4 encodes hook permissions in the hook's ADDRESS bits, so these tests use bare
/// addresses whose low bits carry the relevant flags. No hook code is needed: hasPermission
/// is pure address arithmetic and poolManager enforces it the same way.
contract RegistryHookGateTest is Test {
    OnchainRouterExposed router;

    address constant V2_FACTORY = address(0xF2);
    address constant V3_FACTORY = address(0xF3);
    address constant POOL_MANAGER = address(0xBEEF);
    address constant WETH = address(0xC);
    address constant TOKEN_A = address(0xA);
    address constant TOKEN_B = address(0xB);

    // Flag values, kept explicit so a change in v4-core is caught here.
    // BEFORE_SWAP = 1<<7, AFTER_SWAP = 1<<6, BEFORE_SWAP_RETURNS_DELTA = 1<<3,
    // AFTER_SWAP_RETURNS_DELTA = 1<<2, BEFORE_ADD_LIQUIDITY = 1<<11.
    address constant HOOK_BEFORE_SWAP_DELTA = address(uint160((1 << 7) | (1 << 3)));
    address constant HOOK_AFTER_SWAP_DELTA = address(uint160((1 << 6) | (1 << 2)));
    address constant HOOK_BEFORE_SWAP_ONLY = address(uint160(1 << 7));
    address constant HOOK_AFTER_SWAP_ONLY = address(uint160(1 << 6));
    address constant HOOK_LIQUIDITY_ONLY = address(uint160(1 << 11));

    function setUp() public {
        vm.etch(POOL_MANAGER, hex"00");
        vm.etch(V3_FACTORY, hex"00");
        vm.etch(V2_FACTORY, hex"00");
        vm.mockCall(V3_FACTORY, abi.encodeWithSignature("feeAmountTickSpacing(uint24)"), abi.encode(int24(0)));

        router = new OnchainRouterExposed(V2_FACTORY, V3_FACTORY, POOL_MANAGER, WETH);
    }

    /// @dev Make any pool read as live (nonzero sqrtPriceX96) so registration reaches, or
    /// gets past, the hook gate. Slot-precise mocking is unnecessary here: these tests are
    /// about the hook bits, not about which pool id was probed.
    function _mockLivePool() internal {
        vm.mockCall(POOL_MANAGER, abi.encodeWithSignature("extsload(bytes32)"), abi.encode(bytes32(uint256(1 << 96))));
    }

    // ───────────────────────── rejected ─────────────────────────

    function test_registerV4Pool_revertsOnBeforeSwapReturnsDeltaHook() public {
        _mockLivePool();
        vm.expectRevert(V4PoolRegistry.CustomAccountingHookNotAllowed.selector);
        router.registerV4Pool(TOKEN_A, TOKEN_B, 500, 10, HOOK_BEFORE_SWAP_DELTA);
    }

    function test_registerV4Pool_revertsOnAfterSwapReturnsDeltaHook() public {
        _mockLivePool();
        vm.expectRevert(V4PoolRegistry.CustomAccountingHookNotAllowed.selector);
        router.registerV4Pool(TOKEN_A, TOKEN_B, 500, 10, HOOK_AFTER_SWAP_DELTA);
    }

    /// @dev The gate must run before any pool lookup, so a custom-accounting hook is
    /// rejected even for a pool that does not exist. Guards against someone reordering it
    /// behind the existence check and changing which error surfaces.
    function test_registerV4Pool_hookGateRunsBeforePoolExistenceCheck() public {
        vm.expectRevert(V4PoolRegistry.CustomAccountingHookNotAllowed.selector);
        router.registerV4Pool(TOKEN_A, TOKEN_B, 500, 10, HOOK_BEFORE_SWAP_DELTA);
    }

    // ───────────────────────── permitted ─────────────────────────

    function test_registerV4Pool_allowsBeforeSwapOnlyHook() public {
        _mockLivePool();
        router.registerV4Pool(TOKEN_A, TOKEN_B, 500, 10, HOOK_BEFORE_SWAP_ONLY);
    }

    function test_registerV4Pool_allowsAfterSwapOnlyHook() public {
        _mockLivePool();
        router.registerV4Pool(TOKEN_A, TOKEN_B, 500, 10, HOOK_AFTER_SWAP_ONLY);
    }

    function test_registerV4Pool_allowsLiquidityPhaseHook() public {
        _mockLivePool();
        router.registerV4Pool(TOKEN_A, TOKEN_B, 500, 10, HOOK_LIQUIDITY_ONLY);
    }

    function test_registerV4Pool_allowsHooklessPool() public {
        _mockLivePool();
        router.registerV4Pool(TOKEN_A, TOKEN_B, 500, 10, address(0));
    }

    /// @dev A dynamic-fee pool needs a hook to set its fee, so banning hooks outright would
    /// have made dynamic-fee pools permanently unroutable. This pins that they are not.
    function test_registerV4Pool_allowsOutOfBandDynamicFeePool() public {
        uint24 dynamicFee = 0x800000;
        _mockLivePool();
        router.registerV4Pool(TOKEN_A, TOKEN_B, dynamicFee, 60, HOOK_LIQUIDITY_ONLY);
    }

    /// @dev Pin the flag constants this gate depends on.
    function test_flagConstantsMatchV4Core() public {
        assertEq(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG, 1 << 3);
        assertEq(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG, 1 << 2);
        assertEq(Hooks.BEFORE_SWAP_FLAG, 1 << 7);
        assertEq(Hooks.AFTER_SWAP_FLAG, 1 << 6);
    }
}
