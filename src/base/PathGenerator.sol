// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.6;
pragma abicoder v2;

import {IUniswapV3Factory} from "v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV2Factory} from "v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {UniswapV2Library} from "../libraries/UniswapV2Library.sol";
import {Pool} from "./OnchainRouterStructs.sol";
import {OnchainRouterImmutables} from "./OnchainRouterImmutables.sol";

/// @title Path Generator for Uniswap V2 and V3 Routes
/// @notice Generates all possible swap paths between token pairs across V2 and V3 pools
/// @dev Inherits from OnchainRouterImmutables to access factory contracts
abstract contract PathGenerator is OnchainRouterImmutables {
    // Default fee tiers to check for V3 pools (0.01%, 0.05%, 0.3%, 1%)
    // indices correspond to [100, 500, 3000, 10000] in basis points
    uint24[4] private defaultFeeTiers = [uint24(100), uint24(500), uint24(3000), uint24(10000)];

    // Default fee tier for V2 pools (0.3%)
    // for compatibility with V3 pool representations
    uint24 private constant V2_FEE_TIER = 3000;

    /// @notice Currently supported and active fee tiers
    /// @dev Dynamically populated based on enabled tiers in V3 factory
    uint24[] public feeTiers;

    /// @notice Initializes the path generator with supported V3 fee tiers
    /// @param v3Factory Address of the Uniswap V3 factory
    /// @dev Filters out fee tiers that aren't enabled in the factory
    constructor(address v3Factory) {
        for (uint256 i = 0; i < defaultFeeTiers.length; i++) {
            uint24 feeTier = defaultFeeTiers[i];
            if (IUniswapV3Factory(v3Factory).feeAmountTickSpacing(feeTier) != 0) {
                feeTiers.push(feeTier);
            }
        }
    }

    /// @notice Adds a new fee tier to the supported list
    /// @param feeTier The fee tier to add (e.g., 100 for 0.01%)
    /// @dev Reverts if the fee tier isn't enabled in the V3 factory
    function addNewFeeTier(uint24 feeTier) public {
        if (v3Factory.feeAmountTickSpacing(feeTier) == 0) {
            revert("Invalid fee tier");
        }
        feeTiers.push(feeTier);
    }

    /// @notice Generates all possible paths between two tokens
    /// @param tokenIn The input token address
    /// @param tokenOut The output token address
    /// @return paths Array of all valid pools (both V2 and V3) for the token pair
    /// @dev Combines results from generateV2Path and generateV3Paths
    function generatePaths(address tokenIn, address tokenOut) internal view returns (Pool[] memory paths) {
        Pool[] memory v2Path = generateV2Path(tokenIn, tokenOut);
        Pool[] memory v3Paths = generateV3Paths(tokenIn, tokenOut);

        paths = addPaths(v2Path, v3Paths);
    }

    /// @notice Generates all valid V3 paths for a token pair
    /// @param tokenIn The input token address
    /// @param tokenOut The output token address
    /// @return paths Array of valid V3 pools across all fee tiers
    /// @dev Checks each supported fee tier for existing pools
    function generateV3Paths(address tokenIn, address tokenOut) private view returns (Pool[] memory paths) {
        uint256 validPaths;
        paths = new Pool[](feeTiers.length);

        for (uint256 i = 0; i < feeTiers.length; i++) {
            uint24 feeTier = feeTiers[i];
            (address token0, address token1) = UniswapV2Library.sortTokens(tokenIn, tokenOut);
            address pool = v3Factory.getPool(token0, token1, feeTier);

            if (pool != address(0)) {
                Pool memory path = Pool({tokenIn: tokenIn, tokenOut: tokenOut, pool: pool, fee: feeTier, version: true});
                paths[validPaths] = path;
                validPaths++;
            }
        }
        // set paths length to validPaths
        assembly {
            mstore(paths, validPaths)
        }
    }

    /// @notice Generates V2 path for a token pair if it exists
    /// @param tokenIn The input token address
    /// @param tokenOut The output token address
    /// @return path Single-element array with V2 pool or empty if pair doesn't exist
    /// @dev Returns empty array if no V2 pair exists
    function generateV2Path(address tokenIn, address tokenOut) private view returns (Pool[] memory path) {
        (address token0, address token1) = UniswapV2Library.sortTokens(tokenIn, tokenOut);
        address v2Pool = v2Factory.getPair(token0, token1);

        path = new Pool[](1);
        if (v2Pool != address(0)) {
            path[0] = Pool({tokenIn: tokenIn, tokenOut: tokenOut, pool: v2Pool, fee: V2_FEE_TIER, version: false});
        } else {
            // set paths length to 0
            assembly {
                mstore(path, 0)
            }
        }
    }

    /// @notice Combines two arrays of paths into a single array
    /// @param path1 First array of paths
    /// @param path2 Second array of paths
    /// @return path Combined array containing all paths
    /// @dev Used to merge V2 and V3 paths into a single array
    function addPaths(Pool[] memory path1, Pool[] memory path2) private pure returns (Pool[] memory path) {
        uint256 length = path1.length + path2.length;
        path = new Pool[](length);

        for (uint256 i = 0; i < path1.length; i++) {
            path[i] = path1[i];
        }

        for (uint256 i = 0; i < path2.length; i++) {
            path[i + path1.length] = path2[i];
        }
    }
}
