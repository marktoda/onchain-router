// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {OnchainRouter} from "../src/OnchainRouter.sol";
import {PathGenerator} from "../src/base/PathGenerator.sol";
import {SwapExecutor} from "../src/base/SwapExecutor.sol";
import {SwapParams, Quote, Pool, V2} from "../src/base/OnchainRouterStructs.sol";
import {OnchainRouterExposed} from "./utils/OnchainRouterExposed.sol";
import {MainnetForkFixture} from "./utils/ForkFixtures.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice ERC20 that takes a fee on every transfer/transferFrom
contract MockFeeOnTransferToken is ERC20("FOT", "FOT", 18) {
    uint256 public constant FEE_BPS = 100; // 1%

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * FEE_BPS) / 10_000;
        _burn(msg.sender, fee);
        return super.transfer(to, amount - fee);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * FEE_BPS) / 10_000;
        super.transferFrom(from, address(this), fee);
        return super.transferFrom(from, to, amount - fee);
    }
}

/// @notice Recipient that attempts to re-enter the router when it receives ETH
contract ReentrantRecipient {
    OnchainRouter immutable router;
    bytes4 public reentryRevertSelector;
    bool public reentered;

    constructor(OnchainRouter _router) {
        router = _router;
    }

    receive() external payable {
        Pool[] memory path = new Pool[](1);
        Quote memory quote = Quote({path: path, amountIn: 1, amountOut: 0});
        try router.swapExactInput(quote, address(this), type(uint256).max, false) {
            reentered = true;
        } catch (bytes memory reason) {
            reentryRevertSelector = bytes4(reason);
        }
    }
}

contract HardeningForkTest is MainnetForkFixture {
    OnchainRouterExposed router;

    uint256 constant USDC_AMOUNT = 1000 * 1e6;
    uint256 constant ETH_AMOUNT = 1 ether;

    address recipient;

    function setUp() public {
        _forkMainnet();
        router = new OnchainRouterExposed(V2_FACTORY, V3_FACTORY, address(0), WETH, address(this));
        recipient = makeAddr("recipient");
    }

    // ======== F2: addNewFeeTier hardening ========

    function test_addNewFeeTier_duplicateIsNoOp() public {
        uint256 lengthBefore = 4; // constructor seeds the four default tiers
        router.addNewFeeTier(500);
        assertEq(uint256(router.feeTiers(3)), 10000, "List must be unchanged");
        vm.expectRevert();
        router.feeTiers(lengthBefore); // still exactly 4 entries
    }

    function test_addNewFeeTier_revertsOnInvalidTier() public {
        vm.expectRevert(PathGenerator.InvalidFeeTier.selector);
        router.addNewFeeTier(1234);
    }

    function test_addNewFeeTier_newTierStillAddable() public {
        uint24 newFeeTier = 1234;
        vm.prank(v3Factory.owner());
        v3Factory.enableFeeAmount(newFeeTier, 60);

        router.addNewFeeTier(newFeeTier);
        assertEq(uint256(router.feeTiers(4)), uint256(newFeeTier));

        // Re-registering is an idempotent no-op, safe for re-runnable scripts
        router.addNewFeeTier(newFeeTier);
        vm.expectRevert();
        router.feeTiers(5);
    }

    // ======== F1: exact-input minAmountOut bound ========

    function test_swapExactInput_minAmountOut_boundIsAuthoritative() public {
        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: USDC, tokenOut: WETH});
        Quote memory quote = router.routeExactInput(params);
        uint256 quotedOut = quote.amountOut;

        // Inflate the quote's amountOut to simulate adverse drift since quoting.
        // Without the caller bound this would revert TooLittleReceived; the loose
        // minAmountOut must dominate.
        quote.amountOut = quotedOut * 2;

        _dealUSDC(address(this), quote.amountIn);
        ERC20(USDC).approve(address(router), quote.amountIn);

        uint256 minAmountOut = (quotedOut * 99) / 100;
        uint256 amountOut = router.swapExactInput(quote, recipient, block.timestamp, false, minAmountOut);

        assertGe(amountOut, minAmountOut, "Realized output should meet the caller bound");
        assertEq(ERC20(WETH).balanceOf(recipient), amountOut, "Recipient should receive WETH");
    }

    function test_swapExactInput_minAmountOut_revertsWhenUnmet() public {
        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: USDC, tokenOut: WETH});
        Quote memory quote = router.routeExactInput(params);

        _dealUSDC(address(this), quote.amountIn);
        ERC20(USDC).approve(address(router), quote.amountIn);

        uint256 minAmountOut = quote.amountOut + 1;
        vm.expectRevert(SwapExecutor.TooLittleReceived.selector);
        router.swapExactInput(quote, recipient, block.timestamp, false, minAmountOut);
    }

    function test_swapExactInput_zeroMinAmountOut_defaultsToQuote() public {
        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: USDC, tokenOut: WETH});
        Quote memory quote = router.routeExactInput(params);

        // A zero bound must NOT disable protection: it falls back to quote.amountOut,
        // so an unreachable quote still reverts.
        quote.amountOut = quote.amountOut + 1;

        _dealUSDC(address(this), quote.amountIn);
        ERC20(USDC).approve(address(router), quote.amountIn);

        vm.expectRevert(SwapExecutor.TooLittleReceived.selector);
        router.swapExactInput(quote, recipient, block.timestamp, false, 0);
    }

    function test_swapExactOutput_zeroMaxAmountIn_defaultsToQuote() public {
        SwapParams memory params = SwapParams({amountSpecified: ETH_AMOUNT, tokenIn: USDC, tokenOut: WETH});
        Quote memory quote = router.routeExactOutput(params);

        _dealUSDC(address(this), quote.amountIn);
        ERC20(USDC).approve(address(router), quote.amountIn);

        // A zero bound falls back to quote.amountIn: funds the swap exactly like the
        // legacy 4-arg signature instead of pulling nothing and reverting.
        uint256 amountIn = router.swapExactOutput(quote, recipient, block.timestamp, false, 0);

        assertEq(ERC20(WETH).balanceOf(recipient), ETH_AMOUNT, "Recipient should receive exact WETH");
        assertLe(amountIn, quote.amountIn, "Should behave exactly like the legacy signature");
    }

    function test_swapExactInput_legacySignature_zeroToleranceUnchanged() public {
        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: USDC, tokenOut: WETH});
        Quote memory quote = router.routeExactInput(params);
        quote.amountOut = quote.amountOut + 1;

        _dealUSDC(address(this), quote.amountIn);
        ERC20(USDC).approve(address(router), quote.amountIn);

        vm.expectRevert(SwapExecutor.TooLittleReceived.selector);
        router.swapExactInput(quote, recipient, block.timestamp, false);
    }

    // ======== F1: exact-output maxAmountIn bound ========

    function test_swapExactOutput_maxAmountIn_allowsTolerance() public {
        SwapParams memory params = SwapParams({amountSpecified: ETH_AMOUNT, tokenIn: USDC, tokenOut: WETH});
        Quote memory quote = router.routeExactOutput(params);

        uint256 maxAmountIn = (quote.amountIn * 101) / 100;
        _dealUSDC(address(this), maxAmountIn);
        ERC20(USDC).approve(address(router), maxAmountIn);

        uint256 balanceBefore = ERC20(USDC).balanceOf(address(this));
        uint256 amountIn = router.swapExactOutput(quote, recipient, block.timestamp, false, maxAmountIn);

        assertEq(ERC20(WETH).balanceOf(recipient), ETH_AMOUNT, "Recipient should receive exact WETH");
        assertLe(amountIn, maxAmountIn, "Actual input should not exceed the caller bound");
        assertEq(
            ERC20(USDC).balanceOf(address(this)),
            balanceBefore - amountIn,
            "Everything above realized input should be refunded"
        );
    }

    function test_swapExactOutput_maxAmountIn_revertsWhenExceeded() public {
        SwapParams memory params = SwapParams({amountSpecified: ETH_AMOUNT, tokenIn: USDC, tokenOut: WETH});
        Quote memory quote = router.routeExactOutput(params);

        // Bound below what the swap needs: the per-hop cap must trip. Fund and approve
        // generously so only the cap (not the fixture) can cause the revert.
        uint256 maxAmountIn = (quote.amountIn * 95) / 100;
        _dealUSDC(address(this), quote.amountIn * 2);
        ERC20(USDC).approve(address(router), quote.amountIn * 2);

        vm.expectRevert(SwapExecutor.V3TooMuchRequested.selector);
        router.swapExactOutput(quote, recipient, block.timestamp, false, maxAmountIn);
    }

    function test_swapExactOutput_maxAmountIn_multihop_refundsInInputUnits() public {
        // Force a 2-hop USDC -> WETH -> WBTC exact-output route: the executor's return
        // value is the last hop's (WETH-denominated) input, so refund accounting must
        // come from the router's own USDC balance delta.
        SwapParams memory params = SwapParams({amountSpecified: 0.01e8, tokenIn: USDC, tokenOut: WBTC});
        Quote memory quote = router.externalRouteExactOutputMulti(params, WETH);
        assertEq(quote.path.length, 2, "Route must be 2-hop for this test");

        uint256 maxAmountIn = (quote.amountIn * 101) / 100;
        _dealUSDC(address(this), maxAmountIn);
        ERC20(USDC).approve(address(router), maxAmountIn);

        uint256 balanceBefore = ERC20(USDC).balanceOf(address(this));
        uint256 amountIn = router.swapExactOutput(quote, recipient, block.timestamp, false, maxAmountIn);

        assertEq(ERC20(WBTC).balanceOf(recipient), 0.01e8, "Recipient should receive exact WBTC");
        // amountIn must be in USDC units (close to the quote), not WETH units
        assertApproxEqRel(amountIn, quote.amountIn, 0.05e18, "Realized input must be denominated in tokenIn");
        assertEq(
            ERC20(USDC).balanceOf(address(this)), balanceBefore - amountIn, "Refund must equal the unspent USDC exactly"
        );
        assertEq(ERC20(USDC).balanceOf(address(router)), 0, "No USDC may be stranded in the router");
    }

    // ======== Native-ETH deposit/bound equality ========

    function test_swapExactOutput_ETH_maxAmountIn_refundsAgainstDeposit() public {
        // WETH is tokenIn: send native ETH, cap at maxAmountIn, expect refund of the difference
        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: WETH, tokenOut: USDC});
        Quote memory quote = router.routeExactOutput(params);

        uint256 maxAmountIn = (quote.amountIn * 101) / 100;
        uint256 balanceBefore = address(this).balance;
        uint256 amountIn =
            router.swapExactOutput{value: maxAmountIn}(quote, recipient, block.timestamp, false, maxAmountIn);

        assertEq(ERC20(USDC).balanceOf(recipient), USDC_AMOUNT, "Recipient should receive exact USDC");
        assertEq(address(this).balance, balanceBefore - amountIn, "Unspent ETH must come back to the caller");
        assertEq(ERC20(WETH).balanceOf(address(router)), 0, "No WETH may be stranded in the router");
    }

    function test_swapExactOutput_ETH_revertsOnDepositBoundMismatch() public {
        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: WETH, tokenOut: USDC});
        Quote memory quote = router.routeExactOutput(params);

        uint256 maxAmountIn = (quote.amountIn * 101) / 100;

        // Deposit above the bound would strand WETH in the router
        vm.expectRevert(abi.encodeWithSelector(OnchainRouter.ETHValueMismatch.selector, maxAmountIn, maxAmountIn + 1));
        router.swapExactOutput{value: maxAmountIn + 1}(quote, recipient, block.timestamp, false, maxAmountIn);

        // Deposit below the bound would refund WETH the caller never sent
        vm.expectRevert(abi.encodeWithSelector(OnchainRouter.ETHValueMismatch.selector, maxAmountIn, maxAmountIn - 1));
        router.swapExactOutput{value: maxAmountIn - 1}(quote, recipient, block.timestamp, false, maxAmountIn);
    }

    function test_swapExactInput_ETH_revertsOnDepositMismatch() public {
        SwapParams memory params = SwapParams({amountSpecified: ETH_AMOUNT, tokenIn: WETH, tokenOut: USDC});
        Quote memory quote = router.routeExactInput(params);

        // Under-payment would make the swap draw on WETH the caller never sent
        vm.expectRevert(abi.encodeWithSelector(OnchainRouter.ETHValueMismatch.selector, ETH_AMOUNT, ETH_AMOUNT - 1));
        router.swapExactInput{value: ETH_AMOUNT - 1}(quote, recipient, block.timestamp, false);

        // Over-payment would strand WETH in the router
        vm.expectRevert(abi.encodeWithSelector(OnchainRouter.ETHValueMismatch.selector, ETH_AMOUNT, ETH_AMOUNT + 1));
        router.swapExactInput{value: ETH_AMOUNT + 1}(quote, recipient, block.timestamp, false);
    }

    // ======== F3: reentrancy guard ========

    function test_swapExactInput_reentrancyBlocked() public {
        ReentrantRecipient attacker = new ReentrantRecipient(router);

        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: USDC, tokenOut: WETH});
        Quote memory quote = router.routeExactInput(params);

        _dealUSDC(address(this), quote.amountIn);
        ERC20(USDC).approve(address(router), quote.amountIn);

        // unwrapOutput=true sends ETH to the attacker mid-swap; its receive() re-enters.
        router.swapExactInput(quote, address(attacker), block.timestamp, true);

        assertFalse(attacker.reentered(), "Reentrant call must not succeed");
        assertEq(
            attacker.reentryRevertSelector(),
            OnchainRouter.Reentrancy.selector,
            "Reentrant call must revert with Reentrancy"
        );
    }

    // ======== F4: fee-on-transfer / short-delivery detection ========

    function _fotQuote(address token) internal pure returns (Quote memory quote) {
        Pool[] memory path = new Pool[](1);
        PoolKey memory emptyKey;
        path[0] = Pool({tokenIn: token, tokenOut: address(1), fee: 3000, pool: address(1), version: V2, key: emptyKey});
        quote = Quote({path: path, amountIn: 1e18, amountOut: 1});
    }

    function test_swapExactInput_revertsOnFeeOnTransferToken() public {
        MockFeeOnTransferToken fot = new MockFeeOnTransferToken();
        fot.mint(address(this), 10e18);
        fot.approve(address(router), type(uint256).max);

        uint256 expected = 1e18;
        uint256 received = expected - (expected * fot.FEE_BPS()) / 10_000;
        vm.expectRevert(abi.encodeWithSelector(OnchainRouter.InputAmountMismatch.selector, expected, received));
        router.swapExactInput(_fotQuote(address(fot)), recipient, block.timestamp, false);
    }

    function test_swapExactOutput_revertsOnFeeOnTransferToken() public {
        MockFeeOnTransferToken fot = new MockFeeOnTransferToken();
        fot.mint(address(this), 10e18);
        fot.approve(address(router), type(uint256).max);

        uint256 expected = 1e18;
        uint256 received = expected - (expected * fot.FEE_BPS()) / 10_000;
        vm.expectRevert(abi.encodeWithSelector(OnchainRouter.InputAmountMismatch.selector, expected, received));
        router.swapExactOutput(_fotQuote(address(fot)), recipient, block.timestamp, false);
    }

    function test_swapExactInput_normalTokenPullUnaffected() public {
        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: USDC, tokenOut: WETH});
        Quote memory quote = router.routeExactInput(params);

        _dealUSDC(address(this), quote.amountIn);
        ERC20(USDC).approve(address(router), quote.amountIn);

        uint256 amountOut = router.swapExactInput(quote, recipient, block.timestamp, false);
        assertGt(amountOut, 0, "Normal token swap must be unaffected by the input check");
    }

    receive() external payable {}
}

/// @notice ERC20 that donates extra tokens to the router whenever it is transferred to a
/// pool, simulating a mid-swap credit (the case the exact-output excess clamp guards)
contract MockDonatingToken is ERC20("DON", "DON", 18) {
    address public router;
    address public pool;

    function configure(address _router, address _pool) external {
        router = _router;
        pool = _pool;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        // Mid-swap credit: paying the pool triggers a donation to the router
        if (to == pool && router != address(0)) _mint(router, amount * 3);
        return ok;
    }
}

/// @notice Minimal V2-pair stand-in: reports reserves and pays out on swap
contract MockV2Pair {
    address public token0;
    address public token1;

    constructor(address _token0, address _token1) {
        (token0, token1) = _token0 < _token1 ? (_token0, _token1) : (_token1, _token0);
    }

    function getReserves() external pure returns (uint112, uint112, uint32) {
        return (uint112(1_000_000e18), uint112(1_000_000e18), 0);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        if (amount0Out > 0) ERC20(token0).transfer(to, amount0Out);
        if (amount1Out > 0) ERC20(token1).transfer(to, amount1Out);
    }
}

contract ExcessClampForkTest is MainnetForkFixture {
    OnchainRouterExposed router;
    address recipient;

    function setUp() public {
        _forkMainnet();
        router = new OnchainRouterExposed(V2_FACTORY, V3_FACTORY, address(0), WETH);
        recipient = makeAddr("recipient");
    }

    /// @notice Exercises the TRUE branch of the exact-output excess clamp: a token that
    /// credits the router mid-swap must not underflow amountIn; the surplus stays in the
    /// router and the refund is capped at what the caller funded.
    function test_swapExactOutput_midSwapCredit_clampsExcess() public {
        MockERC20 outToken = new MockERC20("OUT", "OUT", 18);
        MockDonatingToken donating = new MockDonatingToken();
        MockV2Pair pair = new MockV2Pair(address(donating), address(outToken));
        donating.configure(address(router), address(pair));
        outToken.mint(address(pair), type(uint128).max);

        donating.mint(address(this), 1_000e18);
        donating.approve(address(router), type(uint256).max);

        Pool[] memory path = new Pool[](1);
        PoolKey memory emptyKey;
        path[0] = Pool({
            tokenIn: address(donating),
            tokenOut: address(outToken),
            fee: 3000,
            pool: address(pair),
            version: V2,
            key: emptyKey
        });
        Quote memory quote = Quote({path: path, amountIn: 100e18, amountOut: 50e18});

        uint256 balanceBefore = donating.balanceOf(address(this));
        // Without the clamp this underflows: the mid-swap donation makes the router's
        // balance delta exceed the funded amount
        uint256 amountIn = router.swapExactOutput(quote, recipient, block.timestamp, false);

        assertEq(outToken.balanceOf(recipient), 50e18, "Exact output must be delivered");
        assertEq(amountIn, 0, "Clamp floors realized input at zero when credits exceed spend");
        assertEq(donating.balanceOf(address(this)), balanceBefore, "Refund is capped at the funded amount");
        assertGt(donating.balanceOf(address(router)), 0, "The mid-swap credit stays in the router");
    }
}

contract ReentrancyExactOutForkTest is MainnetForkFixture {
    OnchainRouterExposed router;

    function setUp() public {
        _forkMainnet();
        router = new OnchainRouterExposed(V2_FACTORY, V3_FACTORY, address(0), WETH);
    }

    /// @notice Symmetric coverage of the guard on the exact-output entrypoint
    function test_swapExactOutput_reentrancyBlocked() public {
        ReentrantRecipient attacker = new ReentrantRecipient(router);

        // Reentry is triggered via the unwrapped-ETH output landing on the attacker
        SwapParams memory ethParams = SwapParams({amountSpecified: 1 ether, tokenIn: USDC, tokenOut: WETH});
        Quote memory ethQuote = router.routeExactOutput(ethParams);
        _dealUSDC(address(this), ethQuote.amountIn);
        ERC20(USDC).approve(address(router), ethQuote.amountIn);

        router.swapExactOutput(ethQuote, address(attacker), block.timestamp, true);

        assertFalse(attacker.reentered(), "Reentrant call must not succeed");
        assertEq(
            attacker.reentryRevertSelector(),
            OnchainRouter.Reentrancy.selector,
            "Reentrant call must revert with Reentrancy"
        );
    }
}
