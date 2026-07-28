// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {OnchainRouterExposed} from "./utils/OnchainRouterExposed.sol";
import {SwapExecutor} from "../src/base/SwapExecutor.sol";
import {Pool, Quote, V3} from "../src/base/OnchainRouterStructs.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Regression tests for V3 swap-callback authentication.
/// @dev The callback used to authenticate msg.sender against a pool address decoded from
/// its own `data` argument, which is caller-supplied. The check was therefore circular:
/// naming yourself as the pool passed it. Because the callback is external and sits
/// outside the reentrancy guard by necessity, anyone could call it directly from an EOA
/// with a forged Quote and have the router transfer any token it held.
contract V3CallbackAuthTest is Test {
    OnchainRouterExposed router;

    address constant V2_FACTORY = address(0xF2);
    address constant V3_FACTORY = address(0xF3);
    address constant POOL_MANAGER = address(0xBEEF);
    address constant WETH = address(0xC);

    /// @dev The address the factory will vouch for as the real pool.
    address constant REAL_POOL = address(0xDEAD);

    MockERC20 token;
    address attacker;

    function setUp() public {
        vm.etch(POOL_MANAGER, hex"00");
        vm.etch(V3_FACTORY, hex"00");
        vm.etch(V2_FACTORY, hex"00");
        // PathGenerator's constructor probes enabled fee tiers; none needed here.
        vm.mockCall(V3_FACTORY, abi.encodeWithSignature("feeAmountTickSpacing(uint24)"), abi.encode(int24(0)));

        router = new OnchainRouterExposed(V2_FACTORY, V3_FACTORY, POOL_MANAGER, WETH);

        token = new MockERC20("Token", "TKN", 18);
        attacker = makeAddr("attacker");

        // Residual balance of the kind the refund/sweep paths can leave behind.
        token.mint(address(router), 100e18);
    }

    /// @dev Make the factory name REAL_POOL as the pool for any (tokenIn, tokenOut, fee).
    function _mockFactoryPool(address pool) internal {
        vm.mockCall(V3_FACTORY, abi.encodeWithSignature("getPool(address,address,uint24)"), abi.encode(pool));
    }

    function _forgedData(address claimedPool, address tokenIn, bool isExactInput)
        internal
        view
        returns (bytes memory)
    {
        Pool[] memory path = new Pool[](1);
        path[0] = Pool({
            tokenIn: tokenIn,
            tokenOut: WETH,
            fee: 3000,
            pool: claimedPool,
            version: V3,
            key: PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(0)),
                fee: 0,
                tickSpacing: 0,
                hooks: IHooks(address(0))
            })
        });
        return abi.encode(Quote({path: path, amountIn: 0, amountOut: 0}), uint256(0), isExactInput);
    }

    /// @notice The exploit: caller names itself as the pool. Must revert, and the router's
    /// balance must be untouched.
    function test_uniswapV3SwapCallback_revertsWhenCallerForgesItselfAsPool() public {
        _mockFactoryPool(REAL_POOL);

        bytes memory data = _forgedData(attacker, address(token), true);

        vm.prank(attacker);
        vm.expectRevert(SwapExecutor.V3InvalidCaller.selector);
        router.uniswapV3SwapCallback(int256(100e18), int256(0), data);

        assertEq(token.balanceOf(address(router)), 100e18, "router balance must be untouched");
        assertEq(token.balanceOf(attacker), 0, "attacker must gain nothing");
    }

    /// @notice Same forgery on the exact-output branch.
    function test_uniswapV3SwapCallback_revertsWhenCallerForgesItselfAsPool_exactOutput() public {
        _mockFactoryPool(REAL_POOL);

        bytes memory data = _forgedData(attacker, address(token), false);

        vm.prank(attacker);
        vm.expectRevert(SwapExecutor.V3InvalidCaller.selector);
        router.uniswapV3SwapCallback(int256(100e18), int256(0), data);

        assertEq(token.balanceOf(address(router)), 100e18, "router balance must be untouched");
    }

    /// @notice Authentication must follow the FACTORY, not the calldata: a caller that is
    /// the genuine pool passes even though it never appears in `data`.
    function test_uniswapV3SwapCallback_acceptsFactoryDerivedPool() public {
        _mockFactoryPool(REAL_POOL);

        // pool.pool is deliberately a bogus address; only msg.sender should matter now.
        bytes memory data = _forgedData(address(0xBAD), address(token), true);

        vm.prank(REAL_POOL);
        router.uniswapV3SwapCallback(int256(1e18), int256(0), data);

        assertEq(token.balanceOf(REAL_POOL), 1e18, "genuine pool must be paid");
    }

    /// @notice A pair the factory does not know (getPool returns the zero address) must
    /// never authenticate, including when the caller itself is address(0)-adjacent.
    function test_uniswapV3SwapCallback_revertsWhenFactoryKnowsNoPool() public {
        _mockFactoryPool(address(0));

        bytes memory data = _forgedData(attacker, address(token), true);

        vm.prank(attacker);
        vm.expectRevert(SwapExecutor.V3InvalidCaller.selector);
        router.uniswapV3SwapCallback(int256(100e18), int256(0), data);
    }
}
