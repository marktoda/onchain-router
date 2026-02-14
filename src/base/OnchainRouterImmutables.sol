// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IUniswapV3Factory} from "v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV2Factory} from "v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

abstract contract OnchainRouterImmutables {
    IUniswapV2Factory public immutable v2Factory;
    IUniswapV3Factory public immutable v3Factory;
    IPoolManager public immutable poolManager;

    constructor(address _v2Factory, address _v3Factory, address _poolManager) {
        v2Factory = IUniswapV2Factory(_v2Factory);
        v3Factory = IUniswapV3Factory(_v3Factory);
        poolManager = IPoolManager(_poolManager);
    }
}
