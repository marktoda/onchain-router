// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IUniswapV3Factory} from "v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV2Factory} from "v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {Quote, V4} from "../../src/base/OnchainRouterStructs.sol";

/// @notice True if any hop in the quoted path is a V4 pool
function hasV4Hop(Quote memory quote) pure returns (bool) {
    for (uint256 i = 0; i < quote.path.length; i++) {
        if (quote.path[i].version == V4) return true;
    }
    return false;
}

/// @notice Shared mainnet fork fixture: single source of truth for the pinned block,
/// token/factory addresses, and the USDC balance-slot trick.
abstract contract MainnetForkFixture is Test {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    uint256 constant MAINNET_FORK_BLOCK = 19685800;
    uint256 constant USDC_BALANCE_SLOT = 9;

    IUniswapV3Factory v3Factory = IUniswapV3Factory(V3_FACTORY);
    IUniswapV2Factory v2Factory = IUniswapV2Factory(V2_FACTORY);

    function _forkMainnet() internal {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), MAINNET_FORK_BLOCK);
    }

    /// @dev Write directly to USDC's balance storage slot (proxy-safe)
    function _dealUSDC(address to, uint256 amount) internal {
        vm.store(USDC, keccak256(abi.encode(to, USDC_BALANCE_SLOT)), bytes32(amount));
    }
}

/// @notice Shared Base fork fixture: V4 PoolManager and token addresses on Base.
abstract contract BaseForkFixture is Test {
    address constant V2_FACTORY = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
    address constant V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint256 constant USDC_BALANCE_SLOT = 9;

    /// @param blockNumber Pin to this block; pass 0 to fork the latest block
    function _forkBase(uint256 blockNumber) internal {
        string memory rpc = vm.envString("BASE_RPC_URL");
        if (blockNumber == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blockNumber);
    }

    function _dealUSDC(address to, uint256 amount) internal {
        vm.store(USDC, keccak256(abi.encode(to, USDC_BALANCE_SLOT)), bytes32(amount));
    }
}
