// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Core structs for Onchain Router
// Defines the main data structures used throughout the router

uint8 constant V2 = 0;
uint8 constant V3 = 1;
uint8 constant V4 = 2;

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

/// @notice Represents a liquidity pool (V2, V3, or V4)
struct Pool {
    // input token for this specific swap (address(0) for native ETH in V4)
    address tokenIn;
    // output token for this specific swap (address(0) for native ETH in V4)
    address tokenOut;
    // fee tier (0 for V2, actual fee for V3/V4)
    uint24 fee;
    // pool contract address (zero for V4 — pools live inside poolManager)
    address pool;
    // 0=V2, 1=V3, 2=V4
    uint8 version;
    // tick spacing (0 for V2/V3, actual value for V4)
    int24 tickSpacing;
    // hooks contract address (address(0) for V2/V3 and hookless V4 pools)
    address hooks;
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
