// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.6;

import {IUniswapV3Factory} from "v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {MockV3Pool} from "./MockV3Pool.sol";

contract MockV3Factory is IUniswapV3Factory {
    mapping(uint24 => bool) public feeAmountEnabled;
    mapping(address => mapping(address => mapping(uint24 => address))) public override getPool;
    mapping(uint24 => int24) public override feeAmountTickSpacing;
    address private _owner;

    constructor() {
        _owner = msg.sender;
        feeAmountEnabled[500] = true;
        feeAmountEnabled[3000] = true;
        feeAmountEnabled[10000] = true;
        
        feeAmountTickSpacing[500] = 10;
        feeAmountTickSpacing[3000] = 60;
        feeAmountTickSpacing[10000] = 200;
    }

    function createPool(address tokenA, address tokenB, uint24 fee) external override returns (address pool) {
        require(tokenA != tokenB, 'V3: IDENTICAL_ADDRESSES');
        require(fee == 500 || fee == 3000 || fee == 10000, 'V3: INVALID_FEE');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'V3: ZERO_ADDRESS');
        require(getPool[token0][token1][fee] == address(0), 'V3: POOL_EXISTS');

        pool = address(new MockV3Pool(token0, token1, fee));
        getPool[token0][token1][fee] = pool;
        getPool[token1][token0][fee] = pool;
    }

    function enableFeeAmount(uint24 fee, int24 tickSpacing) external override {
        require(msg.sender == _owner, 'V3: FORBIDDEN');
        require(fee < 1000000, 'V3: FEE_TOO_LARGE');
        require(!feeAmountEnabled[fee], 'V3: FEE_ALREADY_ENABLED');
        
        feeAmountEnabled[fee] = true;
        feeAmountTickSpacing[fee] = tickSpacing;
    }

    function owner() external view override returns (address) {
        return _owner;
    }

    function setOwner(address newOwner) external override {
        require(msg.sender == _owner, 'V3: FORBIDDEN');
        _owner = newOwner;
    }
} 