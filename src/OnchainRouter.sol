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
import {Ownable2Step} from "./base/Ownable2Step.sol";

/// @title Onchain Router for Uniswap V2, V3, and V4
/// @notice Finds and executes optimal swap paths across Uniswap V2, V3, and V4 pools
contract OnchainRouter is
    OnchainRouterImmutables,
    V3Quoter,
    V2Quoter,
    V4Quoter,
    PathGenerator,
    SwapExecutor,
    Ownable2Step
{
    using QuoteLibrary for Quote;
    using QuoteLibrary for Pool;

    /// @dev Cap on the intermediate set: quoting cost grows linearly per intermediate
    /// (roughly two extra full pool sweeps each), so the set stays small by construction.
    uint256 private constant MAX_INTERMEDIATES = 5;

    /// @dev Reentrancy lock for the swap entrypoints. Transient so it costs no storage
    /// and always resets at the end of the transaction.
    bool private transient locked;

    /// @notice Routing intermediates for 2-hop paths. WETH's OTHER role, the canonical
    /// wrapper for native ETH (msg.value handling, V4 address(0) aliasing), stays pinned
    /// to the intermediateToken immutable and is unaffected by this set.
    address[] public intermediateTokens;

    event IntermediateTokenAdded(address indexed token);
    event IntermediateTokenRemoved(address indexed token);

    error DeadlineExpired();
    error ETHValueMismatch(uint256 expected, uint256 actual);
    error Reentrancy();
    error InputAmountMismatch(uint256 expected, uint256 received);
    error TooManyIntermediates();
    error DuplicateIntermediate();
    error IntermediateNotFound();
    error InvalidIntermediate();

    /// @dev Guards the external swap entrypoints only. Internal callback re-entry from
    /// poolManager (unlockCallback) and V3 pools (uniswapV3SwapCallback) happens while
    /// the lock is held and must stay unguarded.
    /// Deliberate consequence: a contract recipient cannot start another router swap from
    /// its receive() while an unwrapped-ETH swap is mid-flight (that call shape is
    /// indistinguishable from a reentrancy attack). Complete the swap first, then act.
    modifier nonReentrant() {
        if (locked) revert Reentrancy();
        locked = true;
        _;
        locked = false;
    }

    constructor(address _v2Factory, address _v3Factory, address _poolManager, address _weth, address _initialOwner)
        OnchainRouterImmutables(_v2Factory, _v3Factory, _poolManager, _weth)
        PathGenerator(_v3Factory)
        Ownable2Step(_initialOwner)
    {
        // WETH starts as the sole routing intermediate: behavior at deploy is identical
        // to the previous hard-coded single-intermediate routing
        intermediateTokens.push(_weth);
        emit IntermediateTokenAdded(_weth);
    }

    /// @notice Register a routing intermediate for 2-hop path search.
    function addIntermediateToken(address token) external onlyOwner {
        if (token == address(0)) revert InvalidIntermediate();
        uint256 length = intermediateTokens.length;
        if (length >= MAX_INTERMEDIATES) revert TooManyIntermediates();
        for (uint256 i = 0; i < length; i++) {
            if (intermediateTokens[i] == token) revert DuplicateIntermediate();
        }
        intermediateTokens.push(token);
        emit IntermediateTokenAdded(token);
    }

    /// @notice Remove a routing intermediate. Removing WETH from the set only stops it
    /// being used as a routing hop; native-ETH handling is unaffected.
    function removeIntermediateToken(address token) external onlyOwner {
        uint256 length = intermediateTokens.length;
        for (uint256 i = 0; i < length; i++) {
            if (intermediateTokens[i] == token) {
                intermediateTokens[i] = intermediateTokens[length - 1];
                intermediateTokens.pop();
                emit IntermediateTokenRemoved(token);
                return;
            }
        }
        revert IntermediateNotFound();
    }

    /// @notice Number of configured routing intermediates.
    function intermediateTokensLength() external view returns (uint256) {
        return intermediateTokens.length;
    }

    receive() external payable {}

    // ─────────────────────────────────────────────────────────────
    //  Swap Execution
    // ─────────────────────────────────────────────────────────────

    /// @notice Execute an exact-input swap using a previously obtained quote.
    /// @dev Send ETH as msg.value for native ETH input (wraps to WETH automatically);
    /// msg.value must equal quote.amountIn exactly. Set unwrapOutput=true to receive ETH
    /// instead of WETH. The quote's amountOut acts as the minimum-output bound (zero
    /// slippage tolerance); use the minAmountOut overload to allow tolerance.
    /// The bound is checked against the pool-reported output (pre any output-token
    /// transfer fee), not the recipient's delivered balance: output-side fee-on-transfer
    /// detection is out of scope for v1, so a fee-on-transfer output token can deliver
    /// below the bound. Input-side short-delivery is rejected (see _fundInput).
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
    /// never a re-fetched quote. A zero minAmountOut would silently disable slippage
    /// protection, so it falls back to the quote's zero-tolerance behavior instead.
    /// @param minAmountOut Minimum acceptable output; the swap reverts with TooLittleReceived
    /// below it. Pass 0 to default to quote.amountOut (zero tolerance)
    function swapExactInput(
        Quote memory quote,
        address recipient,
        uint256 deadline,
        bool unwrapOutput,
        uint256 minAmountOut
    ) external payable nonReentrant returns (uint256 amountOut) {
        return _swapExactInputWithBound(
            quote, recipient, deadline, unwrapOutput, minAmountOut == 0 ? quote.amountOut : minAmountOut
        );
    }

    /// @dev Layered safety on this path: (1) deadline check; (2) nonReentrant entrypoints —
    /// the contract is otherwise stateless per call (the MaxInputAmount transient is the
    /// only write); (3) FOT input detection via balance measurement;
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

        uint256 balanceBefore = _fundInput(userTokenIn, quote.amountIn);

        address swapRecipient = unwrapOutput ? address(this) : recipient;
        amountOut = _swapExactInput(quote, swapRecipient);

        if (unwrapOutput) {
            IWETH9(intermediateToken).withdraw(amountOut);
            SafeTransferLib.safeTransferETH(recipient, amountOut);
        }

        // Refund unconsumed input. A V4 first hop can partial-fill (consume less than the
        // funded amount before hitting its price limit); with a loose minAmountOut the
        // TooLittleReceived check does not fire, so without this the remainder would
        // strand in the router, sweepable by a later caller. Output is a different token
        // than userTokenIn on every real route, so the balance delta is purely input.
        // Clamped so a mid-swap credit cannot underflow (mirrors the exact-output path).
        uint256 excess = ERC20(userTokenIn).balanceOf(address(this)) - balanceBefore;
        if (excess > quote.amountIn) excess = quote.amountIn;
        if (excess > 0) {
            if (msg.value > 0) {
                IWETH9(intermediateToken).withdraw(excess);
                SafeTransferLib.safeTransferETH(msg.sender, excess);
            } else {
                SafeTransferLib.safeTransfer(ERC20(userTokenIn), msg.sender, excess);
            }
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
    /// and the input cap enforced per-hop, so the swap tolerates adverse price drift up to
    /// maxAmountIn. For native ETH input, msg.value must equal maxAmountIn exactly, the
    /// bound, not the quoted amount. Unspent input is refunded. The bound is enforced
    /// against realized input, never a re-fetched quote. A zero maxAmountIn would fund
    /// nothing and always revert, so it falls back to the quote's zero-tolerance behavior.
    /// @param maxAmountIn Maximum acceptable input; the swap reverts with *TooMuchRequested
    /// above it. Pass 0 to default to quote.amountIn (zero tolerance)
    function swapExactOutput(
        Quote memory quote,
        address recipient,
        uint256 deadline,
        bool unwrapOutput,
        uint256 maxAmountIn
    ) external payable nonReentrant returns (uint256 amountIn) {
        return _swapExactOutputWithBound(
            quote, recipient, deadline, unwrapOutput, maxAmountIn == 0 ? quote.amountIn : maxAmountIn
        );
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

        uint256 balanceBefore = _fundInput(userTokenIn, quote.amountIn);

        address swapRecipient = unwrapOutput ? address(this) : recipient;
        // Return value deliberately ignored: for multihop paths the executor returns the
        // LAST hop's input, denominated in the intermediate token, not userTokenIn.
        // Realized input is derived from the balance delta below instead.
        _swapExactOutput(quote, swapRecipient);

        if (unwrapOutput) {
            uint256 outputAmount = quote.amountOut;
            IWETH9(intermediateToken).withdraw(outputAmount);
            SafeTransferLib.safeTransferETH(recipient, outputAmount);
        }

        // Leftover userTokenIn above the pre-funding balance is refunded to the caller.
        // Clamped to the funded amount: a mid-swap credit of userTokenIn (e.g. a V4 hook
        // or token callback) is refunded to the caller up to what they funded, and only
        // any overflow beyond the funded amount stays in the router. Note the returned
        // amountIn is derived from this delta, so a credit below the unspent margin makes
        // it under-report true consumed input; integrators settling on the return value
        // should treat it as a lower bound, not an exact consumed figure.
        uint256 excess = ERC20(userTokenIn).balanceOf(address(this)) - balanceBefore;
        if (excess > quote.amountIn) excess = quote.amountIn;
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

    /// @notice Fund the swap with the caller's input: wrap msg.value for native ETH, or
    /// pull tokens via transferFrom, rejecting tokens that do not deliver the exact amount.
    /// @dev Routing and refund math assume transfer amounts arrive in full. Tokens that
    /// deliver less, fee-on-transfer tokens and share-rounding rebasing tokens like stETH,
    /// would otherwise fail deep in pool code with an opaque error (or, under a loose
    /// slippage bound, settle with silently wrong accounting), so they are rejected here
    /// with a clear one. For native ETH, msg.value must equal `amount` exactly (which is
    /// the caller's bound, maxAmountIn, on the exact-output overload): the refund is
    /// computed against `amount`, so depositing more strands WETH in the router and
    /// depositing less makes the refund draw on WETH the caller never sent.
    /// @return balanceBefore The router's `token` balance before funding, for refund accounting
    function _fundInput(address token, uint256 amount) private returns (uint256 balanceBefore) {
        balanceBefore = ERC20(token).balanceOf(address(this));
        if (msg.value > 0) {
            if (msg.value != amount) revert ETHValueMismatch(amount, msg.value);
            IWETH9(intermediateToken).deposit{value: msg.value}();
        } else {
            SafeTransferLib.safeTransferFrom(ERC20(token), msg.sender, address(this), amount);
            uint256 received = ERC20(token).balanceOf(address(this)) - balanceBefore;
            if (received != amount) revert InputAmountMismatch(amount, received);
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  Routing (3-way version checks)
    // ─────────────────────────────────────────────────────────────

    /// @notice Find the optimal route for an exact-input swap.
    /// @dev Compares the direct route against a 2-hop route through every configured
    /// intermediate. An intermediate equal to either end of the pair is skipped (that
    /// candidate is the direct route); the others still get their multi-hop check.
    function routeExactInput(SwapParams memory params) public view returns (Quote memory bestQuote) {
        bestQuote = routeExactInputSingle(params);
        uint256 length = intermediateTokens.length;
        for (uint256 i = 0; i < length; i++) {
            address intermediate = intermediateTokens[i];
            if (intermediate == params.tokenIn || intermediate == params.tokenOut) continue;
            bestQuote = routeExactInputMulti(params, intermediate).better(bestQuote);
        }
    }

    /// @notice Find the optimal route for an exact-output swap.
    function routeExactOutput(SwapParams memory params) public view returns (Quote memory bestQuote) {
        bestQuote = routeExactOutputSingle(params);
        uint256 length = intermediateTokens.length;
        for (uint256 i = 0; i < length; i++) {
            address intermediate = intermediateTokens[i];
            if (intermediate == params.tokenIn || intermediate == params.tokenOut) continue;
            bestQuote = routeExactOutputMulti(params, intermediate).better(bestQuote);
        }
    }

    /// @notice Find the optimal route allowing up to 3 hops. OPT-IN: strictly more
    /// expensive than routeExactInput (it tries every ordered pair of configured
    /// intermediates, up to MAX*(MAX-1) extra 3-hop candidates, each costing three full
    /// single-hop sweeps), so callers choose it explicitly; the standard entrypoints
    /// stay 2-hop. The result is a superset search: direct and 2-hop candidates are
    /// always included, so this never returns a worse route than routeExactInput.
    function routeExactInput3Hop(SwapParams memory params) external view returns (Quote memory bestQuote) {
        // Fold direct, 2-hop, and 3-hop candidates in one pass. The tokenIn->first leg is
        // computed once per intermediate and reused for both the 2-hop and every 3-hop
        // candidate through that intermediate, instead of calling routeExactInput (which
        // would re-sweep each first leg).
        bestQuote = routeExactInputSingle(params);
        uint256 length = intermediateTokens.length;
        for (uint256 i = 0; i < length; i++) {
            address first = intermediateTokens[i];
            if (first == params.tokenIn || first == params.tokenOut) continue;
            Quote memory legOne = routeExactInputSingle(
                SwapParams({tokenIn: params.tokenIn, tokenOut: first, amountSpecified: params.amountSpecified})
            );
            if (legOne.amountOut == 0) continue;

            // 2-hop candidate through `first`
            Quote memory firstToOut = routeExactInputSingle(
                SwapParams({tokenIn: first, tokenOut: params.tokenOut, amountSpecified: legOne.amountOut})
            );
            if (firstToOut.amountOut != 0) bestQuote = legOne.combine(firstToOut).better(bestQuote);

            // 3-hop candidates first -> second -> tokenOut
            for (uint256 j = 0; j < length; j++) {
                if (j == i) continue;
                address second = intermediateTokens[j];
                if (second == params.tokenIn || second == params.tokenOut) continue;

                Quote memory legTwo = routeExactInputSingle(
                    SwapParams({tokenIn: first, tokenOut: second, amountSpecified: legOne.amountOut})
                );
                if (legTwo.amountOut == 0) continue;
                Quote memory legThree = routeExactInputSingle(
                    SwapParams({tokenIn: second, tokenOut: params.tokenOut, amountSpecified: legTwo.amountOut})
                );
                if (legThree.amountOut == 0) continue;

                bestQuote = legOne.combine(legTwo).combine(legThree).better(bestQuote);
            }
        }
    }

    /// @notice Exact-output twin of routeExactInput3Hop: legs are sized backwards from
    /// the requested output, then combined forward. Same opt-in cost profile.
    function routeExactOutput3Hop(SwapParams memory params) external view returns (Quote memory bestQuote) {
        // Fold direct, 2-hop, and 3-hop in one pass. The outer loop walks the LAST
        // intermediate (second) because exact-output legs are sized backwards from the
        // requested output; second->tokenOut is computed once per intermediate and reused
        // for both the 2-hop and every 3-hop candidate through it, instead of calling
        // routeExactOutput (which would re-sweep each of those legs).
        bestQuote = routeExactOutputSingle(params);
        uint256 length = intermediateTokens.length;
        for (uint256 i = 0; i < length; i++) {
            address second = intermediateTokens[i];
            if (second == params.tokenIn || second == params.tokenOut) continue;
            Quote memory legThree = routeExactOutputSingle(
                SwapParams({tokenIn: second, tokenOut: params.tokenOut, amountSpecified: params.amountSpecified})
            );
            if (legThree.amountIn == 0 || legThree.amountIn == type(uint256).max) continue;

            // 2-hop candidate tokenIn -> second -> tokenOut
            Quote memory inToSecond = routeExactOutputSingle(
                SwapParams({tokenIn: params.tokenIn, tokenOut: second, amountSpecified: legThree.amountIn})
            );
            if (inToSecond.amountIn != 0 && inToSecond.amountIn != type(uint256).max) {
                bestQuote = inToSecond.combine(legThree).better(bestQuote);
            }

            // 3-hop candidates tokenIn -> first -> second -> tokenOut
            for (uint256 j = 0; j < length; j++) {
                if (j == i) continue;
                address first = intermediateTokens[j];
                if (first == params.tokenIn || first == params.tokenOut) continue;

                Quote memory legTwo = routeExactOutputSingle(
                    SwapParams({tokenIn: first, tokenOut: second, amountSpecified: legThree.amountIn})
                );
                if (legTwo.amountIn == 0 || legTwo.amountIn == type(uint256).max) continue;
                Quote memory legOne = routeExactOutputSingle(
                    SwapParams({tokenIn: params.tokenIn, tokenOut: first, amountSpecified: legTwo.amountIn})
                );
                if (legOne.amountIn == 0 || legOne.amountIn == type(uint256).max) continue;

                bestQuote = legOne.combine(legTwo).combine(legThree).better(bestQuote);
            }
        }
    }

    function routeExactInputMulti(SwapParams memory params, address intermediate)
        internal
        view
        returns (Quote memory bestQuote)
    {
        Quote memory inputToIntermediate = routeExactInputSingle(
            SwapParams({tokenIn: params.tokenIn, tokenOut: intermediate, amountSpecified: params.amountSpecified})
        );
        // A one-sided route (first leg routable, second not) must not combine into a
        // quote whose path dead-ends at the intermediate: that bogus quote has
        // amountOut 0 but a non-empty path, and better() would still prefer it over an
        // empty direct quote, so a caller keying off path.length would deliver the
        // intermediate token instead of tokenOut. Return an empty quote instead.
        if (inputToIntermediate.amountOut == 0) return bestQuote;
        Quote memory intermediateToOutput = routeExactInputSingle(
            SwapParams({
                tokenIn: intermediate, tokenOut: params.tokenOut, amountSpecified: inputToIntermediate.amountOut
            })
        );
        if (intermediateToOutput.amountOut == 0) return bestQuote;
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
        // Short-circuit an unfillable first leg: feeding the uint256.max sentinel forward
        // as the next leg's amountSpecified would wrap through int256() to -1 and quote a
        // bogus ~1-wei "winning" route. Return the sentinel so this route loses better().
        if (outputToIntermediate.amountIn == 0 || outputToIntermediate.amountIn == type(uint256).max) {
            bestQuote.amountIn = type(uint256).max;
            return bestQuote;
        }
        Quote memory intermediateToInput = routeExactOutputSingle(
            SwapParams({
                tokenIn: params.tokenIn, tokenOut: intermediate, amountSpecified: outputToIntermediate.amountIn
            })
        );
        // Same one-sided guard for the input leg: an unroutable second leg must surface
        // the sentinel, not a combined quote that dead-ends at the intermediate.
        if (intermediateToInput.amountIn == 0 || intermediateToInput.amountIn == type(uint256).max) {
            bestQuote.amountIn = type(uint256).max;
            return bestQuote;
        }

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
