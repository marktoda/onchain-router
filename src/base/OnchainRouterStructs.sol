// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

// Core structs for Onchain Router

uint8 constant V2 = 0;
uint8 constant V3 = 1;
uint8 constant V4 = 2;

struct SwapParams {
    address tokenIn;
    address tokenOut;
    uint256 amountSpecified;
}

/// @notice Represents a liquidity pool (V2, V3, or V4)
struct Pool {
    address tokenIn; // swap direction: input token (address(0) for native ETH in V4)
    address tokenOut; // swap direction: output token
    uint24 fee; // fee tier (V2/V3)
    address pool; // pool contract address (V2/V3; zero for V4)
    uint8 version; // V2=0, V3=1, V4=2
    PoolKey key; // V4 pool key (zero for V2/V3). Contains fee, tickSpacing, hooks, sorted currencies.
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
