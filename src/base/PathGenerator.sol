// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IUniswapV3Factory} from "v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV2Factory} from "v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {UniswapV2Library} from "../libraries/UniswapV2Library.sol";
import {Pool, V2, V3} from "./OnchainRouterStructs.sol";
import {OnchainRouterImmutables} from "./OnchainRouterImmutables.sol";
import {V4PoolRegistry} from "./V4PoolRegistry.sol";

/// @title Path Generator for Uniswap V2, V3, and V4 Routes
/// @notice Generates all possible swap paths between token pairs
abstract contract PathGenerator is V4PoolRegistry {
    uint24[4] private defaultFeeTiers = [uint24(100), uint24(500), uint24(3000), uint24(10000)];
    uint24 private constant V2_FEE_TIER = 3000;

    uint24[] public feeTiers;

    constructor(address v3Factory) {
        for (uint256 i = 0; i < defaultFeeTiers.length; i++) {
            uint24 feeTier = defaultFeeTiers[i];
            if (IUniswapV3Factory(v3Factory).feeAmountTickSpacing(feeTier) != 0) {
                feeTiers.push(feeTier);
            }
        }
    }

    function addNewFeeTier(uint24 feeTier) public {
        if (v3Factory.feeAmountTickSpacing(feeTier) == 0) {
            revert("Invalid fee tier");
        }
        feeTiers.push(feeTier);
    }

    function generatePaths(address tokenIn, address tokenOut) internal view returns (Pool[] memory paths) {
        Pool[] memory v2Path = _generateV2Path(tokenIn, tokenOut);
        Pool[] memory v3Paths = _generateV3Paths(tokenIn, tokenOut);
        Pool[] memory v4Paths = getV4Pools(tokenIn, tokenOut);

        paths = _addPaths(_addPaths(v2Path, v3Paths), v4Paths);
    }

    function _generateV3Paths(address tokenIn, address tokenOut) private view returns (Pool[] memory paths) {
        uint256 validPaths;
        paths = new Pool[](feeTiers.length);

        for (uint256 i = 0; i < feeTiers.length; i++) {
            uint24 feeTier = feeTiers[i];
            (address token0, address token1) = UniswapV2Library.sortTokens(tokenIn, tokenOut);
            address pool = v3Factory.getPool(token0, token1, feeTier);

            if (pool != address(0)) {
                paths[validPaths++] = Pool({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    pool: pool,
                    fee: feeTier,
                    version: V3,
                    tickSpacing: 0,
                    hooks: address(0)
                });
            }
        }
        assembly {
            mstore(paths, validPaths)
        }
    }

    function _generateV2Path(address tokenIn, address tokenOut) private view returns (Pool[] memory path) {
        (address token0, address token1) = UniswapV2Library.sortTokens(tokenIn, tokenOut);
        address v2Pool = v2Factory.getPair(token0, token1);

        path = new Pool[](1);
        if (v2Pool != address(0)) {
            path[0] = Pool({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                pool: v2Pool,
                fee: V2_FEE_TIER,
                version: V2,
                tickSpacing: 0,
                hooks: address(0)
            });
        } else {
            assembly {
                mstore(path, 0)
            }
        }
    }

    function _addPaths(Pool[] memory path1, Pool[] memory path2) private pure returns (Pool[] memory path) {
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
