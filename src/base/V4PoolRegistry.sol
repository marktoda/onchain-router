// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Pool, V4} from "./OnchainRouterStructs.sol";
import {OnchainRouterImmutables} from "./OnchainRouterImmutables.sol";
import {UniswapV2Library} from "../libraries/UniswapV2Library.sol";

abstract contract V4PoolRegistry is OnchainRouterImmutables {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    struct V4PoolConfig {
        uint24 fee;
        int24 tickSpacing;
    }

    struct V4PoolEntry {
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        uint64 score;
    }

    uint8 constant MAX_V4_POOLS_PER_PAIR = 8;

    V4PoolConfig[] internal defaultV4Configs;
    mapping(bytes32 pairHash => V4PoolEntry[]) internal v4Leaderboard;

    constructor() {
        defaultV4Configs.push(V4PoolConfig({fee: 100, tickSpacing: 1}));
        defaultV4Configs.push(V4PoolConfig({fee: 500, tickSpacing: 10}));
        defaultV4Configs.push(V4PoolConfig({fee: 3000, tickSpacing: 60}));
        defaultV4Configs.push(V4PoolConfig({fee: 10000, tickSpacing: 200}));
    }

    function addDefaultV4Config(uint24 fee, int24 tickSpacing) external {
        defaultV4Configs.push(V4PoolConfig({fee: fee, tickSpacing: tickSpacing}));
    }

    function registerV4Pool(address tokenA, address tokenB, uint24 fee, int24 tickSpacing, address hooks) external {
        // Construct PoolKey and verify pool exists
        PoolKey memory key = _buildPoolKey(tokenA, tokenB, fee, tickSpacing, hooks);
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        require(sqrtPriceX96 != 0, "Pool does not exist");

        // Compute pair hash (order-independent)
        bytes32 ph = _pairHash(tokenA, tokenB);
        V4PoolEntry[] storage entries = v4Leaderboard[ph];

        // Check for duplicates
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].fee == fee && entries[i].tickSpacing == tickSpacing && entries[i].hooks == hooks) {
                revert("Duplicate pool");
            }
        }

        if (entries.length < MAX_V4_POOLS_PER_PAIR) {
            entries.push(V4PoolEntry({fee: fee, tickSpacing: tickSpacing, hooks: hooks, score: 0}));
        } else {
            // Find lowest-scoring entry
            uint256 lowestIdx = 0;
            uint64 lowestScore = entries[0].score;
            for (uint256 i = 1; i < entries.length; i++) {
                if (entries[i].score < lowestScore) {
                    lowestScore = entries[i].score;
                    lowestIdx = i;
                }
            }
            // Challenger must have more liquidity than the incumbent
            uint128 challengerLiquidity = poolManager.getLiquidity(poolId);

            PoolKey memory incumbentKey = _buildPoolKey(
                tokenA, tokenB, entries[lowestIdx].fee, entries[lowestIdx].tickSpacing, entries[lowestIdx].hooks
            );
            uint128 incumbentLiquidity = poolManager.getLiquidity(incumbentKey.toId());

            require(challengerLiquidity > incumbentLiquidity, "Insufficient liquidity to replace");
            entries[lowestIdx] = V4PoolEntry({fee: fee, tickSpacing: tickSpacing, hooks: hooks, score: 0});
        }
    }

    function getV4Pools(address tokenIn, address tokenOut, address intermediateToken)
        internal
        view
        returns (Pool[] memory pools)
    {
        // Skip V4 discovery if poolManager is not set
        if (address(poolManager) == address(0)) {
            pools = new Pool[](0);
            return pools;
        }

        // Max possible: defaultConfigs * 2 (for native ETH dual-check) + MAX_V4_POOLS_PER_PAIR
        uint256 maxPools = defaultV4Configs.length * 2 + MAX_V4_POOLS_PER_PAIR;
        pools = new Pool[](maxPools);
        uint256 count;

        // Check default configs with hooks=address(0)
        for (uint256 i = 0; i < defaultV4Configs.length; i++) {
            V4PoolConfig memory cfg = defaultV4Configs[i];

            // Standard ERC20 pair check
            count = _tryAddDefaultPool(pools, count, tokenIn, tokenOut, cfg, false, intermediateToken);

            // Native ETH dual-check: if either token is WETH, also check with address(0) substituted
            if (tokenIn == intermediateToken || tokenOut == intermediateToken) {
                count = _tryAddDefaultPool(pools, count, tokenIn, tokenOut, cfg, true, intermediateToken);
            }
        }

        // Check leaderboard entries
        bytes32 ph = _pairHash(tokenIn, tokenOut);
        V4PoolEntry[] storage entries = v4Leaderboard[ph];
        for (uint256 i = 0; i < entries.length; i++) {
            V4PoolEntry storage entry = entries[i];
            // Skip entries that match a default config (dedup)
            if (entry.hooks == address(0) && _isDefaultConfig(entry.fee, entry.tickSpacing)) {
                continue;
            }

            PoolKey memory key = _buildPoolKey(tokenIn, tokenOut, entry.fee, entry.tickSpacing, entry.hooks);
            PoolId poolId = key.toId();
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
            if (sqrtPriceX96 != 0) {
                pools[count++] = Pool({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: entry.fee,
                    pool: address(0),
                    version: V4,
                    tickSpacing: entry.tickSpacing,
                    hooks: entry.hooks
                });
            }
        }

        // Also check leaderboard with native ETH pair if WETH involved
        if (tokenIn == intermediateToken || tokenOut == intermediateToken) {
            bytes32 nativePh = _pairHash(
                tokenIn == intermediateToken ? address(0) : tokenIn,
                tokenOut == intermediateToken ? address(0) : tokenOut
            );
            if (nativePh != ph) {
                V4PoolEntry[] storage nativeEntries = v4Leaderboard[nativePh];
                for (uint256 i = 0; i < nativeEntries.length; i++) {
                    V4PoolEntry storage entry = nativeEntries[i];
                    if (entry.hooks == address(0) && _isDefaultConfig(entry.fee, entry.tickSpacing)) {
                        continue;
                    }

                    address nativeIn = tokenIn == intermediateToken ? address(0) : tokenIn;
                    address nativeOut = tokenOut == intermediateToken ? address(0) : tokenOut;
                    PoolKey memory key = _buildPoolKey(nativeIn, nativeOut, entry.fee, entry.tickSpacing, entry.hooks);
                    PoolId poolId = key.toId();
                    (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
                    if (sqrtPriceX96 != 0) {
                        pools[count++] = Pool({
                            tokenIn: nativeIn,
                            tokenOut: nativeOut,
                            fee: entry.fee,
                            pool: address(0),
                            version: V4,
                            tickSpacing: entry.tickSpacing,
                            hooks: entry.hooks
                        });
                    }
                }
            }
        }

        // Trim array
        assembly {
            mstore(pools, count)
        }
    }

    function _tryAddDefaultPool(
        Pool[] memory pools,
        uint256 count,
        address tokenIn,
        address tokenOut,
        V4PoolConfig memory cfg,
        bool useNativeETH,
        address intermediateToken
    ) private view returns (uint256) {
        address effIn = useNativeETH && tokenIn == intermediateToken ? address(0) : tokenIn;
        address effOut = useNativeETH && tokenOut == intermediateToken ? address(0) : tokenOut;

        // Don't create a pool where both sides became the same after substitution
        if (effIn == effOut) return count;
        // For useNativeETH=true, at least one side must have changed
        if (useNativeETH && effIn == tokenIn && effOut == tokenOut) return count;

        PoolKey memory key = _buildPoolKey(effIn, effOut, cfg.fee, cfg.tickSpacing, address(0));
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 != 0) {
            pools[count] = Pool({
                tokenIn: effIn,
                tokenOut: effOut,
                fee: cfg.fee,
                pool: address(0),
                version: V4,
                tickSpacing: cfg.tickSpacing,
                hooks: address(0)
            });
            return count + 1;
        }
        return count;
    }

    function _incrementV4Score(bytes32 ph, uint24 fee, int24 tickSpacing, address hooks) internal {
        V4PoolEntry[] storage entries = v4Leaderboard[ph];
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].fee == fee && entries[i].tickSpacing == tickSpacing && entries[i].hooks == hooks) {
                entries[i].score++;
                return;
            }
        }
    }

    function _buildPoolKey(address tokenA, address tokenB, uint24 fee, int24 tickSpacing, address hooks)
        internal
        pure
        returns (PoolKey memory)
    {
        Currency c0 = Currency.wrap(tokenA);
        Currency c1 = Currency.wrap(tokenB);
        if (c0 > c1) {
            (c0, c1) = (c1, c0);
        }
        return PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(hooks)});
    }

    function _pairHash(address tokenA, address tokenB) internal pure returns (bytes32) {
        if (tokenA > tokenB) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        return keccak256(abi.encodePacked(tokenA, tokenB));
    }

    function _isDefaultConfig(uint24 fee, int24 tickSpacing) private view returns (bool) {
        for (uint256 i = 0; i < defaultV4Configs.length; i++) {
            if (defaultV4Configs[i].fee == fee && defaultV4Configs[i].tickSpacing == tickSpacing) {
                return true;
            }
        }
        return false;
    }
}
