// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.6;
pragma abicoder v2;

/// @title Core structs for Onchain Router
/// @notice Defines the main data structures used throughout the router

/// @notice Parameters for a swap operation
/// @dev Used for both exact input and exact output swaps
struct SwapParams {
    // The token being sold
    address tokenIn;
    // token being bought
    address tokenOut;
    // amount of tokenIn (for exact input) or tokenOut (for exact output)
    uint256 amountSpecified;
}

/// @notice Represents a liquidity pool (V2 or V3)
struct Pool {
    // input token for this specific swap
    address tokenIn;
    // output token for this specific swap
    address tokenOut;
    // fee tier (0 for V2, actual fee for V3)
    uint24 fee;
    // pool contract address
    address pool;
    // this is a V3 pool (true) or V2 pool (false)
    bool version;
}

/// @notice A single step in a swap path
struct SwapHop {
    // pool to use for this hop
    Pool pool;
    // amount for this specific hop
    uint256 amountSpecified;
}

/// @notice A complete quote for a swap
struct Quote {
    // sequence of pools to use
    Pool[] path;
    // total input amount required
    uint256 amountIn;
    // total output amount to receive
    uint256 amountOut;
}
