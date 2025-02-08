// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {IUniswapV2Factory} from "v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {UniswapV2Library} from "./libraries/UniswapV2Library.sol";
import {SwapHop} from "./base/OnchainRouterStructs.sol";
import {OnchainRouterImmutables} from "./base/OnchainRouterImmutables.sol";

/// @title Uniswap V2 Pool Quoter
/// @notice Provides functions for quoting V2 pool swaps without execution
/// @dev Uses UniswapV2Library for core calculations
abstract contract V2Quoter is OnchainRouterImmutables {
    /// @notice Quotes an exact input swap on a V2 pool
    /// @param swap The swap parameters including pool and amount
    /// @return amountOut The expected output amount
    /// @dev Uses getAmountOut from UniswapV2Library
    function v2QuoteExactIn(SwapHop memory swap) internal view returns (uint256 amountOut) {
        (uint256 reserveIn, uint256 reserveOut) = getReserves(swap);

        amountOut = UniswapV2Library.getAmountOut(swap.amountSpecified, reserveIn, reserveOut);
    }

    /// @notice Quotes an exact output swap on a V2 pool
    /// @param swap The swap parameters including pool and desired output amount
    /// @return amountIn The required input amount
    /// @dev Uses getAmountIn from UniswapV2Library
    function v2QuoteExactOut(SwapHop memory swap) internal view returns (uint256 amountIn) {
        (uint256 reserveIn, uint256 reserveOut) = getReserves(swap);

        amountIn = UniswapV2Library.getAmountIn(swap.amountSpecified, reserveIn, reserveOut);
    }

    /// @notice Gets the reserves for a V2 pool in the correct order
    /// @param swap The swap parameters containing pool info
    /// @return reserveIn Reserve of the input token
    /// @return reserveOut Reserve of the output token
    /// @dev Handles token ordering based on addresses
    function getReserves(SwapHop memory swap) internal view returns (uint256 reserveIn, uint256 reserveOut) {
        (address token0,) = UniswapV2Library.sortTokens(swap.pool.tokenIn, swap.pool.tokenOut);
        (reserveIn, reserveOut,) = IUniswapV2Pair(swap.pool.pool).getReserves();

        // we need to reverse the tokens
        if (token0 != swap.pool.tokenIn) {
            (reserveIn, reserveOut) = (reserveOut, reserveIn);
        }
    }
}
