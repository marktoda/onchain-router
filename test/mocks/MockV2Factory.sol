// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.6;

import {IUniswapV2Factory} from "v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {MockV2Pair} from "./MockV2Pair.sol";

contract MockV2Factory is IUniswapV2Factory {
    mapping(address => mapping(address => address)) public override getPair;
    address[] public override allPairs;
    address private _feeTo;
    address private _feeToSetter;

    constructor() {
        _feeToSetter = msg.sender;
    }

    function createPair(address tokenA, address tokenB) external override returns (address pair) {
        require(tokenA != tokenB, 'V2: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'V2: ZERO_ADDRESS');
        require(getPair[token0][token1] == address(0), 'V2: PAIR_EXISTS');

        MockV2Pair mockPair = new MockV2Pair();
        mockPair.initialize(token0, token1);
        
        pair = address(mockPair);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);
    }

    function allPairsLength() external view override returns (uint) {
        return allPairs.length;
    }

    function feeTo() external view override returns (address) {
        return _feeTo;
    }

    function feeToSetter() external view override returns (address) {
        return _feeToSetter;
    }

    function setFeeTo(address _newFeeTo) external override {
        require(msg.sender == _feeToSetter, 'V2: FORBIDDEN');
        _feeTo = _newFeeTo;
    }

    function setFeeToSetter(address _newFeeToSetter) external override {
        require(msg.sender == _feeToSetter, 'V2: FORBIDDEN');
        _feeToSetter = _newFeeToSetter;
    }
} 