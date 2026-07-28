// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Pool, V4} from "./OnchainRouterStructs.sol";
import {OnchainRouterImmutables} from "./OnchainRouterImmutables.sol";

/// @notice Discovers V4 pools via default fee/tickSpacing configs and a per-pair leaderboard.
/// @dev Default configs check standard (fee, tickSpacing) combos with hooks=address(0).
/// The leaderboard holds up to 8 registered pools per pair with win-counter scoring.
/// When full, new pools must have more liquidity than the lowest-scored incumbent.
abstract contract V4PoolRegistry is OnchainRouterImmutables {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using Hooks for IHooks;

    /// @dev Thrown when a pool's hook can serve swaps from its own balances, which the
    /// quoter cannot price. See _rejectCustomAccountingHook.
    error CustomAccountingHookNotAllowed();

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

    /// @notice Register a V4 pool to the leaderboard. Permissionless.
    /// @dev Pool must exist (sqrtPriceX96 != 0). If leaderboard is full, challenger must
    /// have more liquidity than the lowest-scored incumbent to replace it.
    function registerV4Pool(address tokenA, address tokenB, uint24 fee, int24 tickSpacing, address hooks) external {
        _rejectCustomAccountingHook(hooks);

        PoolKey memory key = _buildPoolKey(tokenA, tokenB, fee, tickSpacing, hooks);
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        require(sqrtPriceX96 != 0, "Pool does not exist");

        bytes32 ph = _pairHash(tokenA, tokenB);
        V4PoolEntry[] storage entries = v4Leaderboard[ph];

        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].fee == fee && entries[i].tickSpacing == tickSpacing && entries[i].hooks == hooks) {
                revert("Duplicate pool");
            }
        }

        if (entries.length < MAX_V4_POOLS_PER_PAIR) {
            entries.push(V4PoolEntry({fee: fee, tickSpacing: tickSpacing, hooks: hooks, score: 0}));
        } else {
            uint256 lowestIdx = 0;
            uint64 lowestScore = entries[0].score;
            for (uint256 i = 1; i < entries.length; i++) {
                if (entries[i].score < lowestScore) {
                    lowestScore = entries[i].score;
                    lowestIdx = i;
                }
            }
            uint128 challengerLiquidity = poolManager.getLiquidity(poolId);
            PoolKey memory incumbentKey = _buildPoolKey(
                tokenA, tokenB, entries[lowestIdx].fee, entries[lowestIdx].tickSpacing, entries[lowestIdx].hooks
            );
            uint128 incumbentLiquidity = poolManager.getLiquidity(incumbentKey.toId());
            require(challengerLiquidity > incumbentLiquidity, "Insufficient liquidity to replace");
            entries[lowestIdx] = V4PoolEntry({fee: fee, tickSpacing: tickSpacing, hooks: hooks, score: 0});
        }
    }

    /// @notice Finds all V4 pools for a token pair.
    /// @dev If intermediateToken is involved, also checks native ETH variants since
    /// V4 pools may use Currency.wrap(address(0)) instead of the wrapped native token.
    function getV4Pools(address tokenIn, address tokenOut) internal view returns (Pool[] memory pools) {
        if (address(poolManager) == address(0)) {
            return new Pool[](0);
        }

        uint256 maxPools = (defaultV4Configs.length + MAX_V4_POOLS_PER_PAIR) * 2;
        pools = new Pool[](maxPools);
        uint256 count;

        count = _findPools(pools, count, tokenIn, tokenOut);

        // intermediateToken (WETH) may have native ETH equivalents in V4
        if (tokenIn == intermediateToken || tokenOut == intermediateToken) {
            address nativeIn = tokenIn == intermediateToken ? address(0) : tokenIn;
            address nativeOut = tokenOut == intermediateToken ? address(0) : tokenOut;
            count = _findPools(pools, count, nativeIn, nativeOut);
        }

        assembly {
            mstore(pools, count)
        }
    }

    function _findPools(Pool[] memory pools, uint256 count, address tokenIn, address tokenOut)
        private
        view
        returns (uint256)
    {
        // Default configs (hooks = address(0))
        for (uint256 i = 0; i < defaultV4Configs.length; i++) {
            V4PoolConfig memory cfg = defaultV4Configs[i];
            PoolKey memory key = _buildPoolKey(tokenIn, tokenOut, cfg.fee, cfg.tickSpacing, address(0));
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
            if (sqrtPriceX96 != 0) {
                pools[count++] =
                    Pool({tokenIn: tokenIn, tokenOut: tokenOut, fee: 0, pool: address(0), version: V4, key: key});
            }
        }

        // Leaderboard entries
        bytes32 ph = _pairHash(tokenIn, tokenOut);
        V4PoolEntry[] storage entries = v4Leaderboard[ph];
        for (uint256 i = 0; i < entries.length; i++) {
            V4PoolEntry storage entry = entries[i];
            if (entry.hooks == address(0) && _isDefaultConfig(entry.fee, entry.tickSpacing)) {
                continue;
            }
            PoolKey memory key = _buildPoolKey(tokenIn, tokenOut, entry.fee, entry.tickSpacing, entry.hooks);
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
            if (sqrtPriceX96 != 0) {
                pools[count++] =
                    Pool({tokenIn: tokenIn, tokenOut: tokenOut, fee: 0, pool: address(0), version: V4, key: key});
            }
        }

        return count;
    }

    function _incrementV4Score(bytes32 ph, uint24 fee, int24 tickSpacing, address hooks) internal {
        V4PoolEntry[] storage entries = v4Leaderboard[ph];
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].fee == fee && entries[i].tickSpacing == tickSpacing && entries[i].hooks == hooks) {
                unchecked {
                    entries[i].score++;
                }
                return;
            }
        }
    }

    /// @notice Reject pools whose hook can alter swap amounts via custom accounting.
    /// @dev The quoter prices pools on core pool math only (V4Quoter is HOOK-UNAWARE BY
    /// DESIGN). A hook holding either *_RETURNS_DELTA permission can serve a swap from its
    /// own balances instead of the curve, so its quote and its execution are unrelated, and
    /// its core getLiquidity (what the leaderboard scores) is not its real depth either.
    /// Such a pool wins its slot and the route on a quote the router cannot honor.
    ///
    /// Hook permissions are encoded in the hook's ADDRESS bits and enforced by
    /// poolManager, so this is a pure bit test that the hook cannot lie about and that
    /// needs no external call. Hooks.sol guarantees *_RETURNS_DELTA implies its base
    /// *_SWAP flag, so testing the delta bits alone is sufficient.
    ///
    /// KNOWINGLY PERMITTED, and NOT covered by the quoter:
    ///  - beforeSwap/afterSwap hooks that only observe or revert. A hook that reverts can
    ///    hold a slot on honest liquidity and never trade; discovery keeps offering it and
    ///    swaps through it keep failing.
    ///  - a per-swap lpFeeOverride on a dynamic-fee pool, up to LPFeeLibrary.MAX_LP_FEE
    ///    (100%), which the quoter cannot see because it reads the stored slot0 fee.
    /// Both are quote-vs-execution divergences bounded by the caller's slippage bound:
    /// zero-tolerance callers revert, loose-bound callers eat up to their tolerance.
    /// Accepted deliberately so dynamic-fee pools and ordinary observer hooks stay
    /// routable; revisit with an amount-neutral hook allowlist if abuse appears.
    function _rejectCustomAccountingHook(address hooks) private pure {
        if (hooks == address(0)) return;
        IHooks h = IHooks(hooks);
        if (
            h.hasPermission(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)
                || h.hasPermission(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)
        ) revert CustomAccountingHookNotAllowed();
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
