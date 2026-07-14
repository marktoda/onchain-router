// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

/// @notice Minimal V3 mint-callback helper: holds token balances and pays the pool
/// whatever the mint requires.
contract V3PositionMinter {
    function mint(address pool, int24 tickLower, int24 tickUpper, uint128 liquidity) external {
        IUniswapV3Pool(pool).mint(address(this), tickLower, tickUpper, liquidity, abi.encode(pool));
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        address pool = abi.decode(data, (address));
        require(msg.sender == pool, "bad caller");
        if (amount0Owed > 0) {
            SafeTransferLib.safeTransfer(ERC20(IUniswapV3Pool(pool).token0()), pool, amount0Owed);
        }
        if (amount1Owed > 0) {
            SafeTransferLib.safeTransfer(ERC20(IUniswapV3Pool(pool).token1()), pool, amount1Owed);
        }
    }
}
