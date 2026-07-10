// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {PathGenerator} from "./base/PathGenerator.sol";
import {QuoteLibrary} from "./libraries/QuoteLibrary.sol";
import {SwapParams, Pool, SwapHop, Quote, V2, V3, V4} from "./base/OnchainRouterStructs.sol";
import {OnchainRouterImmutables} from "./base/OnchainRouterImmutables.sol";
import {V3Quoter} from "./V3Quoter.sol";
import {V2Quoter} from "./V2Quoter.sol";
import {V4Quoter} from "./V4Quoter.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SwapExecutor} from "./base/SwapExecutor.sol";

/// @title Onchain Router for Uniswap V2, V3, and V4
/// @notice Finds and executes optimal swap paths across Uniswap V2, V3, and V4 pools
contract OnchainRouter is OnchainRouterImmutables, V3Quoter, V2Quoter, V4Quoter, PathGenerator, SwapExecutor {
    using QuoteLibrary for Quote;
    using QuoteLibrary for Pool;

    error DeadlineExpired();
    error ETHValueMismatch(uint256 expected, uint256 actual);
    error Reentrancy();
    error FeeOnTransferNotSupported();

    /// @dev Reentrancy lock for the swap entrypoints. Transient so it costs no storage
    /// and always resets at the end of the transaction.
    bool private transient locked;

    /// @dev Guards the external swap entrypoints only. Internal callback re-entry from
    /// poolManager (unlockCallback) and V3 pools (uniswapV3SwapCallback) happens while
    /// the lock is held and must stay unguarded.
    modifier nonReentrant() {
        if (locked) revert Reentrancy();
        locked = true;
        _;
        locked = false;
    }

    constructor(address _v2Factory, address _v3Factory, address _poolManager, address _weth)
        OnchainRouterImmutables(_v2Factory, _v3Factory, _poolManager, _weth)
        PathGenerator(_v3Factory)
    {}

    receive() external payable {}

    // ─────────────────────────────────────────────────────────────
    //  Swap Execution (with V4 score tracking)
    // ─────────────────────────────────────────────────────────────

    /// @notice Execute an exact-input swap using a previously obtained quote.
    /// @dev Send ETH as msg.value for native ETH input (wraps to WETH automatically).
    /// Set unwrapOutput=true to receive ETH instead of WETH.
    /// The quote's amountOut acts as the minimum-output bound (zero slippage tolerance);
    /// use the minAmountOut overload to allow tolerance.
    /// @param quote Quote from routeExactInput containing path and amounts
    /// @param recipient Address that receives output tokens
    /// @param deadline Unix timestamp after which the swap reverts
    /// @param unwrapOutput If true, unwraps WETH output to native ETH
    /// @return amountOut Actual output amount received
    function swapExactInput(Quote memory quote, address recipient, uint256 deadline, bool unwrapOutput)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        return _swapExactInputWithBound(quote, recipient, deadline, unwrapOutput, quote.amountOut);
    }

    /// @notice Execute an exact-input swap with an explicit minimum-output bound.
    /// @dev Same as swapExactInput but the caller-supplied minAmountOut is the authoritative
    /// slippage bound instead of quote.amountOut, allowing the swap to succeed on adverse
    /// price drift down to minAmountOut. The bound is enforced against realized output,
    /// never a re-fetched quote.
    /// @param minAmountOut Minimum acceptable output; the swap reverts with TooLittleReceived below it
    function swapExactInput(
        Quote memory quote,
        address recipient,
        uint256 deadline,
        bool unwrapOutput,
        uint256 minAmountOut
    ) external payable nonReentrant returns (uint256 amountOut) {
        return _swapExactInputWithBound(quote, recipient, deadline, unwrapOutput, minAmountOut);
    }

    /// @dev Layered safety on this path: (1) deadline check; (2) nonReentrant entrypoints —
    /// the contract is otherwise stateless per call (V4 scores and the MaxInputAmount
    /// transient are the only writes); (3) FOT input detection via balance measurement;
    /// (4) minAmountOut enforced by the executor (SwapExecutor.TooLittleReceived) against
    /// realized output on both the direct and V4-unlock paths.
    function _swapExactInputWithBound(
        Quote memory quote,
        address recipient,
        uint256 deadline,
        bool unwrapOutput,
        uint256 minAmountOut
    ) private returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert DeadlineExpired();

        // The executor enforces quote.amountOut as the min-output bound; thread the
        // caller bound through it so minAmountOut is authoritative on the hot path.
        quote.amountOut = minAmountOut;

        // When a V4 native ETH pool wins, path[0].tokenIn is address(0) but the
        // user-facing token is intermediateToken (WETH). Resolve that here.
        address userTokenIn = _resolveUserToken(quote.path[0].tokenIn);

        if (msg.value > 0) {
            // The swap consumes quote.amountIn; a mismatched deposit would strand or
            // borrow WETH held by the router.
            if (msg.value != quote.amountIn) revert ETHValueMismatch(quote.amountIn, msg.value);
            IWETH9(intermediateToken).deposit{value: msg.value}();
        } else {
            _pullInput(userTokenIn, quote.amountIn);
        }

        address swapRecipient = unwrapOutput ? address(this) : recipient;
        amountOut = _swapExactInput(quote, swapRecipient);

        _updateV4Scores(quote);

        if (unwrapOutput) {
            IWETH9(intermediateToken).withdraw(amountOut);
            SafeTransferLib.safeTransferETH(recipient, amountOut);
        }
    }

    /// @notice Execute an exact-output swap. Excess input is refunded to msg.sender.
    /// @dev The quote's amountIn acts as both the funding amount and the maximum-input
    /// bound (zero slippage tolerance); use the maxAmountIn overload to allow tolerance.
    /// @param quote Quote from routeExactOutput containing path and max input
    /// @param recipient Address that receives the exact output amount
    /// @param deadline Unix timestamp after which the swap reverts
    /// @param unwrapOutput If true, unwraps WETH output to native ETH
    /// @return amountIn Actual input amount consumed (may be less than quote.amountIn)
    function swapExactOutput(Quote memory quote, address recipient, uint256 deadline, bool unwrapOutput)
        external
        payable
        nonReentrant
        returns (uint256 amountIn)
    {
        return _swapExactOutputWithBound(quote, recipient, deadline, unwrapOutput, quote.amountIn);
    }

    /// @notice Execute an exact-output swap with an explicit maximum-input bound.
    /// @dev maxAmountIn replaces quote.amountIn as both the amount pulled from the caller
    /// (or expected as msg.value) and the input cap enforced per-hop, so the swap tolerates
    /// adverse price drift up to maxAmountIn. Unspent input is refunded. The bound is
    /// enforced against realized input, never a re-fetched quote.
    /// @param maxAmountIn Maximum acceptable input; the swap reverts with *TooMuchRequested above it
    function swapExactOutput(
        Quote memory quote,
        address recipient,
        uint256 deadline,
        bool unwrapOutput,
        uint256 maxAmountIn
    ) external payable nonReentrant returns (uint256 amountIn) {
        return _swapExactOutputWithBound(quote, recipient, deadline, unwrapOutput, maxAmountIn);
    }

    /// @dev Layered safety on this path: (1) deadline check; (2) nonReentrant entrypoints;
    /// (3) FOT input detection via balance measurement; (4) maxAmountIn funds the swap and
    /// is enforced per-hop by the executor via the MaxInputAmount transient
    /// (V2/V3/V4TooMuchRequested); (5) unspent input is refunded to msg.sender.
    function _swapExactOutputWithBound(
        Quote memory quote,
        address recipient,
        uint256 deadline,
        bool unwrapOutput,
        uint256 maxAmountIn
    ) private returns (uint256 amountIn) {
        if (block.timestamp > deadline) revert DeadlineExpired();

        // The executor pulls, caps, and refunds against quote.amountIn; thread the caller
        // bound through it so maxAmountIn is authoritative on the hot path.
        quote.amountIn = maxAmountIn;

        address userTokenIn = _resolveUserToken(quote.path[0].tokenIn);

        // The executor's return value for a multihop path is the LAST hop's input, which
        // is denominated in the intermediate token, not userTokenIn. Realized input must
        // therefore be derived from the router's own balance of the user's input token.
        uint256 balanceBefore = ERC20(userTokenIn).balanceOf(address(this));

        if (msg.value > 0) {
            // The refund below is computed against quote.amountIn (the max-input bound),
            // so the deposit must match it exactly: depositing more strands WETH in the
            // router, depositing less makes the refund draw on WETH the caller never sent.
            if (msg.value != quote.amountIn) revert ETHValueMismatch(quote.amountIn, msg.value);
            IWETH9(intermediateToken).deposit{value: msg.value}();
        } else {
            _pullInput(userTokenIn, quote.amountIn);
        }

        address swapRecipient = unwrapOutput ? address(this) : recipient;
        _swapExactOutput(quote, swapRecipient);

        _updateV4Scores(quote);

        if (unwrapOutput) {
            uint256 outputAmount = quote.amountOut;
            IWETH9(intermediateToken).withdraw(outputAmount);
            SafeTransferLib.safeTransferETH(recipient, outputAmount);
        }

        // Leftover userTokenIn above the pre-funding balance is exactly the unspent input,
        // in the right units regardless of path shape.
        uint256 excess = ERC20(userTokenIn).balanceOf(address(this)) - balanceBefore;
        amountIn = quote.amountIn - excess;
        if (excess > 0) {
            if (msg.value > 0) {
                IWETH9(intermediateToken).withdraw(excess);
                SafeTransferLib.safeTransferETH(msg.sender, excess);
            } else {
                SafeTransferLib.safeTransfer(ERC20(userTokenIn), msg.sender, excess);
            }
        }
    }

    /// @notice V4 native ETH pools use address(0) as currency, but users hold WETH
    function _resolveUserToken(address token) private view returns (address) {
        return token == address(0) ? intermediateToken : token;
    }

    /// @notice Pull input tokens from the caller, rejecting fee-on-transfer tokens.
    /// @dev Routing math assumes transfer amounts arrive in full; a token that takes a fee
    /// on transfer would otherwise fail deep in pool code with an opaque error (or worse,
    /// under a loose slippage bound, settle with silently wrong accounting).
    function _pullInput(address token, uint256 amount) private {
        uint256 balanceBefore = ERC20(token).balanceOf(address(this));
        SafeTransferLib.safeTransferFrom(ERC20(token), msg.sender, address(this), amount);
        if (ERC20(token).balanceOf(address(this)) - balanceBefore != amount) revert FeeOnTransferNotSupported();
    }

    function _updateV4Scores(Quote memory quote) private {
        for (uint256 i = 0; i < quote.path.length; i++) {
            Pool memory pool = quote.path[i];
            if (pool.version == V4) {
                bytes32 ph = _pairHash(pool.tokenIn, pool.tokenOut);
                _incrementV4Score(ph, pool.key.fee, pool.key.tickSpacing, address(pool.key.hooks));
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  Routing (3-way version checks)
    // ─────────────────────────────────────────────────────────────

    /// @notice Find the optimal route for an exact-input swap.
    /// @dev Compares direct routes and multi-hop routes through intermediateToken.
    /// For pairs involving intermediateToken, only single-hop is checked.
    function routeExactInput(SwapParams memory params) public view returns (Quote memory bestQuote) {
        if (params.tokenIn == intermediateToken || params.tokenOut == intermediateToken) {
            return routeExactInputSingle(params);
        }

        Quote memory multi = routeExactInputMulti(params, intermediateToken);
        Quote memory single = routeExactInputSingle(params);
        return multi.better(single);
    }

    /// @notice Find the optimal route for an exact-output swap.
    function routeExactOutput(SwapParams memory params) public view returns (Quote memory bestQuote) {
        if (params.tokenIn == intermediateToken || params.tokenOut == intermediateToken) {
            return routeExactOutputSingle(params);
        }

        Quote memory multi = routeExactOutputMulti(params, intermediateToken);
        Quote memory single = routeExactOutputSingle(params);
        return multi.better(single);
    }

    function routeExactInputMulti(SwapParams memory params, address intermediate)
        internal
        view
        returns (Quote memory bestQuote)
    {
        Quote memory inputToIntermediate = routeExactInputSingle(
            SwapParams({tokenIn: params.tokenIn, tokenOut: intermediate, amountSpecified: params.amountSpecified})
        );
        Quote memory intermediateToOutput = routeExactInputSingle(
            SwapParams({
                tokenIn: intermediate, tokenOut: params.tokenOut, amountSpecified: inputToIntermediate.amountOut
            })
        );
        bestQuote = inputToIntermediate.combine(intermediateToOutput);
    }

    function routeExactOutputMulti(SwapParams memory params, address intermediate)
        internal
        view
        returns (Quote memory bestQuote)
    {
        Quote memory outputToIntermediate = routeExactOutputSingle(
            SwapParams({tokenIn: intermediate, tokenOut: params.tokenOut, amountSpecified: params.amountSpecified})
        );
        Quote memory intermediateToInput = routeExactOutputSingle(
            SwapParams({
                tokenIn: params.tokenIn, tokenOut: intermediate, amountSpecified: outputToIntermediate.amountIn
            })
        );

        bestQuote = intermediateToInput.combine(outputToIntermediate);
    }

    function routeExactInputSingle(SwapParams memory params) internal view returns (Quote memory bestQuote) {
        Pool[] memory pools = generatePaths(params.tokenIn, params.tokenOut);

        for (uint256 i = 0; i < pools.length; i++) {
            Pool memory pool = pools[i];
            SwapHop memory swap = SwapHop({pool: pool, amountSpecified: params.amountSpecified});
            uint256 amountOut;
            if (pool.version == V4) amountOut = v4QuoteExactIn(swap);
            else if (pool.version == V3) amountOut = v3QuoteExactIn(swap);
            else amountOut = v2QuoteExactIn(swap);

            if (bestQuote.amountOut == 0 || amountOut > bestQuote.amountOut) {
                bestQuote = pool.createQuoteSingle(params.amountSpecified, amountOut);
            }
        }
    }

    function routeExactOutputSingle(SwapParams memory params) internal view returns (Quote memory bestQuote) {
        Pool[] memory pools = generatePaths(params.tokenIn, params.tokenOut);

        for (uint256 i = 0; i < pools.length; i++) {
            Pool memory pool = pools[i];
            SwapHop memory swap = SwapHop({pool: pool, amountSpecified: params.amountSpecified});
            uint256 amountIn;
            if (pool.version == V4) amountIn = v4QuoteExactOut(swap);
            else if (pool.version == V3) amountIn = v3QuoteExactOut(swap);
            else amountIn = v2QuoteExactOut(swap);

            if (bestQuote.amountIn == 0 || amountIn < bestQuote.amountIn) {
                bestQuote = pool.createQuoteSingle(amountIn, params.amountSpecified);
            }
        }
    }
}
