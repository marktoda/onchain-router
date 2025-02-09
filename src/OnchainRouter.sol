// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.6;
pragma abicoder v2;

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

/// @title Onchain Router for Uniswap V2 and V3
/// @notice Finds and executes optimal swap paths across Uniswap V2 and V3 pools
/// @dev Combines V2Quoter, V3Quoter, and PathGenerator functionality for best pricing
contract OnchainRouter is OnchainRouterImmutables, V3Quoter, V2Quoter, PathGenerator {
    using QuoteLibrary for Quote;
    using QuoteLibrary for Pool;

    /// @notice The intermediate token address used for intermediary swaps
    /// @dev Used when direct pools don't exist between tokens
    address public immutable intermediateToken;

    constructor(address _v2Factory, address _v3Factory, address _intermediateToken)
        OnchainRouterImmutables(_v2Factory, _v3Factory)
        PathGenerator(_v3Factory)
    {
        intermediateToken = _intermediateToken;
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
                tokenIn: intermediate,
                tokenOut: params.tokenOut,
                amountSpecified: inputToIntermediate.amountOut
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
            SwapParams({tokenIn: params.tokenIn, tokenOut: intermediate, amountSpecified: outputToIntermediate.amountIn})
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

            if (amountOut > bestQuote.amountOut) {
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
