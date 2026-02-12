// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IUniswapV3Factory} from "v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV2Pair} from "v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IFeeOnTransferDetector} from "../src/interfaces/IFeeOnTransferDetector.sol";
import {UniswapV2Library} from "./libraries/UniswapV2Library.sol";
import {PathGenerator} from "./base/PathGenerator.sol";
import {QuoteLibrary} from "./libraries/QuoteLibrary.sol";
import {SwapParams, Pool, SwapHop, Quote} from "./base/OnchainRouterStructs.sol";
import {OnchainRouterImmutables} from "./base/OnchainRouterImmutables.sol";
import {IV3Quoter} from "./interfaces/IV3Quoter.sol";
import {V3Quoter} from "./V3Quoter.sol";
import {V2Quoter} from "./V2Quoter.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SwapExecutor} from "./base/SwapExecutor.sol";

/// @title Onchain Router for Uniswap V2 and V3
/// @notice Finds and executes optimal swap paths across Uniswap V2 and V3 pools
/// @dev Combines V2Quoter, V3Quoter, and PathGenerator functionality for best pricing
contract OnchainRouter is OnchainRouterImmutables, V3Quoter, V2Quoter, PathGenerator, SwapExecutor {
    using QuoteLibrary for Quote;
    using QuoteLibrary for Pool;

    /// @notice The intermediate token address used for intermediary swaps
    /// @dev Used when direct pools don't exist between tokens
    address public immutable intermediateToken;

    error DeadlineExpired();
    error InsufficientETH();

    constructor(address _v2Factory, address _v3Factory, address _intermediateToken)
        OnchainRouterImmutables(_v2Factory, _v3Factory)
        PathGenerator(_v3Factory)
    {
        intermediateToken = _intermediateToken;
    }

    receive() external payable {}

    /// @notice Executes an exact input swap using a previously quoted route
    /// @param quote The quote obtained from routeExactInput
    /// @param recipient The address that will receive the output tokens
    /// @param deadline The unix timestamp after which the swap will revert
    /// @param unwrapOutput If true, unwraps WETH output to ETH before sending to recipient
    /// @return amountOut The amount of output tokens received
    function swapExactInput(Quote memory quote, address recipient, uint256 deadline, bool unwrapOutput)
        external
        payable
        returns (uint256 amountOut)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();

        if (msg.value > 0) {
            IWETH9(intermediateToken).deposit{value: msg.value}();
        } else {
            SafeTransferLib.safeTransferFrom(
                ERC20(quote.path[0].tokenIn), msg.sender, address(this), quote.amountIn
            );
        }

        address swapRecipient = unwrapOutput ? address(this) : recipient;
        amountOut = _swapExactInput(quote, swapRecipient);

        if (unwrapOutput) {
            IWETH9(intermediateToken).withdraw(amountOut);
            SafeTransferLib.safeTransferETH(recipient, amountOut);
        }
    }

    /// @notice Executes an exact output swap using a previously quoted route
    /// @param quote The quote obtained from routeExactOutput
    /// @param recipient The address that will receive the output tokens
    /// @param deadline The unix timestamp after which the swap will revert
    /// @param unwrapOutput If true, unwraps WETH output to ETH before sending to recipient
    /// @return amountIn The actual amount of input tokens consumed
    function swapExactOutput(Quote memory quote, address recipient, uint256 deadline, bool unwrapOutput)
        external
        payable
        returns (uint256 amountIn)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();

        if (msg.value > 0) {
            IWETH9(intermediateToken).deposit{value: msg.value}();
        } else {
            SafeTransferLib.safeTransferFrom(
                ERC20(quote.path[0].tokenIn), msg.sender, address(this), quote.amountIn
            );
        }

        address swapRecipient = unwrapOutput ? address(this) : recipient;
        amountIn = _swapExactOutput(quote, swapRecipient);

        if (unwrapOutput) {
            uint256 outputAmount = quote.amountOut;
            IWETH9(intermediateToken).withdraw(outputAmount);
            SafeTransferLib.safeTransferETH(recipient, outputAmount);
        }

        // Refund excess input
        uint256 excess = quote.amountIn - amountIn;
        if (excess > 0) {
            if (msg.value > 0) {
                IWETH9(intermediateToken).withdraw(excess);
                SafeTransferLib.safeTransferETH(msg.sender, excess);
            } else {
                SafeTransferLib.safeTransfer(ERC20(quote.path[0].tokenIn), msg.sender, excess);
            }
        }
    }

    /// @notice Finds the optimal route for an exact input swap
    /// @param params The swap parameters including input token, output token, and input amount
    /// @return bestQuote The optimal quote containing path and output amount
    /// @dev Tries both direct routes and routes through intermediateToken
    function routeExactInput(SwapParams memory params) public view returns (Quote memory bestQuote) {
        if (params.tokenIn == intermediateToken || params.tokenOut == intermediateToken) {
            return routeExactInputSingle(params);
        }

        Quote memory multi = routeExactInputMulti(params, intermediateToken);
        Quote memory single = routeExactInputSingle(params);
        return multi.better(single);
    }

    /// @notice Finds the optimal route for an exact output swap
    /// @param params The swap parameters including input token, output token, and desired output amount
    /// @return bestQuote The optimal quote containing path and required input amount
    /// @dev Tries both direct routes and routes through intermediateToken
    function routeExactOutput(SwapParams memory params) public view returns (Quote memory bestQuote) {
        if (params.tokenIn == intermediateToken || params.tokenOut == intermediateToken) {
            return routeExactOutputSingle(params);
        }

        Quote memory multi = routeExactOutputMulti(params, intermediateToken);
        Quote memory single = routeExactOutputSingle(params);
        return multi.better(single);
    }

    /// @notice Finds the best route through an intermediate token for exact input swaps
    /// @param params The swap parameters
    /// @param intermediate The intermediate token address (usually intermediateToken)
    /// @return bestQuote The optimal multi-hop quote
    /// @dev Combines two single-hop swaps through the intermediate token
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

    /// @notice Finds the best route through an intermediate token for exact output swaps
    /// @param params The swap parameters
    /// @param intermediate The intermediate token address (usually intermediateToken)
    /// @return bestQuote The optimal multi-hop quote
    /// @dev Works backwards from desired output amount
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

    /// @notice Finds the best single pool for an exact input swap
    /// @param params The swap parameters
    /// @return bestQuote The optimal single-hop quote
    /// @dev Tries all available pools (V2 and V3) for the token pair
    function routeExactInputSingle(SwapParams memory params) internal view returns (Quote memory bestQuote) {
        Pool[] memory pools = generatePaths(params.tokenIn, params.tokenOut);

        for (uint256 i = 0; i < pools.length; i++) {
            Pool memory pool = pools[i];
            SwapHop memory swap = SwapHop({pool: pool, amountSpecified: params.amountSpecified});
            uint256 amountOut = pool.version ? v3QuoteExactIn(swap) : v2QuoteExactIn(swap);

            if (bestQuote.amountOut == 0 || amountOut > bestQuote.amountOut) {
                bestQuote = pool.createQuoteSingle(params.amountSpecified, amountOut);
            }
        }
    }

    /// @notice Finds the best single pool for an exact output swap
    /// @param params The swap parameters
    /// @return bestQuote The optimal single-hop quote
    /// @dev Tries all available pools (V2 and V3) for the token pair
    function routeExactOutputSingle(SwapParams memory params) internal view returns (Quote memory bestQuote) {
        Pool[] memory pools = generatePaths(params.tokenIn, params.tokenOut);

        for (uint256 i = 0; i < pools.length; i++) {
            Pool memory pool = pools[i];
            SwapHop memory swap = SwapHop({pool: pool, amountSpecified: params.amountSpecified});
            uint256 amountIn = pool.version ? v3QuoteExactOut(swap) : v2QuoteExactOut(swap);

            if (bestQuote.amountIn == 0 || amountIn < bestQuote.amountIn) {
                bestQuote = pool.createQuoteSingle(amountIn, params.amountSpecified);
            }
        }
    }
}
