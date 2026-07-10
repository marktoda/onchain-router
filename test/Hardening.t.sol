// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IUniswapV3Factory} from "v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV2Factory} from "v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {OnchainRouter} from "../src/OnchainRouter.sol";
import {PathGenerator} from "../src/base/PathGenerator.sol";
import {SwapExecutor} from "../src/base/SwapExecutor.sol";
import {SwapParams, Quote, Pool, V2} from "../src/base/OnchainRouterStructs.sol";
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

contract HardeningForkTest is Test {
    OnchainRouter router;
    IUniswapV3Factory v3Factory;
    IUniswapV2Factory v2Factory;

    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 constant USDC_BALANCE_SLOT = 9;
    uint256 constant USDC_AMOUNT = 1000 * 1e6;
    uint256 constant ETH_AMOUNT = 1 ether;

    address recipient;

    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpc, 19685800);

        v3Factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
        v2Factory = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);

        router = new OnchainRouter(address(v2Factory), address(v3Factory), address(0), WETH);
        recipient = makeAddr("recipient");
    }

    function _dealUSDC(address to, uint256 amount) internal {
        vm.store(USDC, keccak256(abi.encode(to, USDC_BALANCE_SLOT)), bytes32(amount));
    }

    // ======== F2: addNewFeeTier hardening ========

    function test_addNewFeeTier_revertsOnDuplicate() public {
        vm.expectRevert(PathGenerator.DuplicateFeeTier.selector);
        router.addNewFeeTier(500);
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

        vm.expectRevert(PathGenerator.DuplicateFeeTier.selector);
        router.addNewFeeTier(newFeeTier);
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

        // Bound below what the swap needs: the per-hop cap must trip.
        uint256 maxAmountIn = (quote.amountIn * 95) / 100;
        _dealUSDC(address(this), maxAmountIn);
        ERC20(USDC).approve(address(router), maxAmountIn);

        vm.expectRevert();
        router.swapExactOutput(quote, recipient, block.timestamp, false, maxAmountIn);
    }

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
        vm.expectRevert(OnchainRouter.InsufficientETH.selector);
        router.swapExactOutput{value: maxAmountIn + 1}(quote, recipient, block.timestamp, false, maxAmountIn);

        // Deposit below the bound would refund WETH the caller never sent
        vm.expectRevert(OnchainRouter.InsufficientETH.selector);
        router.swapExactOutput{value: maxAmountIn - 1}(quote, recipient, block.timestamp, false, maxAmountIn);
    }

    function test_swapExactInput_ETH_revertsOnDepositMismatch() public {
        SwapParams memory params = SwapParams({amountSpecified: ETH_AMOUNT, tokenIn: WETH, tokenOut: USDC});
        Quote memory quote = router.routeExactInput(params);

        vm.expectRevert(OnchainRouter.InsufficientETH.selector);
        router.swapExactInput{value: ETH_AMOUNT - 1}(quote, recipient, block.timestamp, false);
    }

    receive() external payable {}

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

    // ======== F4: fee-on-transfer detection ========

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

        vm.expectRevert(OnchainRouter.FeeOnTransferNotSupported.selector);
        router.swapExactInput(_fotQuote(address(fot)), recipient, block.timestamp, false);
    }

    function test_swapExactOutput_revertsOnFeeOnTransferToken() public {
        MockFeeOnTransferToken fot = new MockFeeOnTransferToken();
        fot.mint(address(this), 10e18);
        fot.approve(address(router), type(uint256).max);

        vm.expectRevert(OnchainRouter.FeeOnTransferNotSupported.selector);
        router.swapExactOutput(_fotQuote(address(fot)), recipient, block.timestamp, false);
    }

    function test_swapExactInput_normalTokenPullUnaffected() public {
        SwapParams memory params = SwapParams({amountSpecified: USDC_AMOUNT, tokenIn: USDC, tokenOut: WETH});
        Quote memory quote = router.routeExactInput(params);

        _dealUSDC(address(this), quote.amountIn);
        ERC20(USDC).approve(address(router), quote.amountIn);

        uint256 amountOut = router.swapExactInput(quote, recipient, block.timestamp, false);
        assertGt(amountOut, 0, "Normal token swap must be unaffected by the FOT check");
    }
}
