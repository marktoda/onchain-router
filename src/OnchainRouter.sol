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
    error InsufficientETH();

    constructor(address _v2Factory, address _v3Factory, address _poolManager, address _weth)
        OnchainRouterImmutables(_v2Factory, _v3Factory, _poolManager, _weth)
        PathGenerator(_v3Factory)
    {}

    receive() external payable {}

    // ─────────────────────────────────────────────────────────────
    //  Swap Execution (with V4 score tracking)
    // ─────────────────────────────────────────────────────────────

    function swapExactInput(Quote memory quote, address recipient, uint256 deadline, bool unwrapOutput)
        external
        payable
        returns (uint256 amountOut)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();

        // When a V4 native ETH pool wins, path[0].tokenIn is address(0) but the
        // user-facing token is intermediateToken (WETH). Resolve that here.
        address userTokenIn = _resolveUserToken(quote.path[0].tokenIn);

        if (msg.value > 0) {
            IWETH9(intermediateToken).deposit{value: msg.value}();
        } else {
            SafeTransferLib.safeTransferFrom(ERC20(userTokenIn), msg.sender, address(this), quote.amountIn);
        }

        address swapRecipient = unwrapOutput ? address(this) : recipient;
        amountOut = _swapExactInput(quote, swapRecipient);

        _updateV4Scores(quote);

        if (unwrapOutput) {
            IWETH9(intermediateToken).withdraw(amountOut);
            SafeTransferLib.safeTransferETH(recipient, amountOut);
        }
    }

    function swapExactOutput(Quote memory quote, address recipient, uint256 deadline, bool unwrapOutput)
        external
        payable
        returns (uint256 amountIn)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();

        address userTokenIn = _resolveUserToken(quote.path[0].tokenIn);

        if (msg.value > 0) {
            IWETH9(intermediateToken).deposit{value: msg.value}();
        } else {
            SafeTransferLib.safeTransferFrom(ERC20(userTokenIn), msg.sender, address(this), quote.amountIn);
        }

        address swapRecipient = unwrapOutput ? address(this) : recipient;
        amountIn = _swapExactOutput(quote, swapRecipient);

        _updateV4Scores(quote);

        if (unwrapOutput) {
            uint256 outputAmount = quote.amountOut;
            IWETH9(intermediateToken).withdraw(outputAmount);
            SafeTransferLib.safeTransferETH(recipient, outputAmount);
        }

        uint256 excess = quote.amountIn - amountIn;
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

    function _updateV4Scores(Quote memory quote) private {
        for (uint256 i = 0; i < quote.path.length; i++) {
            Pool memory pool = quote.path[i];
            if (pool.version == V4) {
                bytes32 ph = _pairHash(pool.tokenIn, pool.tokenOut);
                _incrementV4Score(ph, pool.fee, pool.tickSpacing, pool.hooks);
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  Routing (3-way version checks)
    // ─────────────────────────────────────────────────────────────

    function routeExactInput(SwapParams memory params) public view returns (Quote memory bestQuote) {
        if (params.tokenIn == intermediateToken || params.tokenOut == intermediateToken) {
            return routeExactInputSingle(params);
        }

        Quote memory multi = routeExactInputMulti(params, intermediateToken);
        Quote memory single = routeExactInputSingle(params);
        return multi.better(single);
    }

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
