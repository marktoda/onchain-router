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

/// @notice Discovers V4 pools via default fee/tickSpacing configs and a per-pair leaderboard.
/// @dev Default configs check standard (fee, tickSpacing) combos with hooks=address(0).
/// The leaderboard holds up to 8 registered pools per pair. Joining a non-full board is
/// direct; a full board is contested through a TWO-PHASE CHALLENGE: declare, wait
/// CHALLENGE_DELAY, then finalize with a fresh liquidity comparison. The delay makes
/// just-in-time liquidity expensive (capital must stay parked for a day), and incumbents
/// that recently won routed swaps are shielded from eviction (an epoch-stamped win, so
/// squatting requires genuinely winning quotes every epoch, forever).
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
        uint64 lastWinEpoch;
    }

    struct V4Challenge {
        address tokenA;
        address tokenB;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        uint64 startedAt;
    }

    uint8 constant MAX_V4_POOLS_PER_PAIR = 8;
    uint256 internal constant CHALLENGE_DELAY = 1 days;
    uint256 internal constant CHALLENGE_EXPIRY = 3 days;
    uint256 internal constant WIN_EPOCH = 1 weeks;

    V4PoolConfig[] internal defaultV4Configs;
    mapping(bytes32 pairHash => V4PoolEntry[]) internal v4Leaderboard;
    mapping(bytes32 pairHash => V4Challenge) internal v4Challenges;

    event V4PoolRegistered(bytes32 indexed pairHash, uint24 fee, int24 tickSpacing, address hooks);
    event V4ChallengeStarted(bytes32 indexed pairHash, uint24 fee, int24 tickSpacing, address hooks);
    event V4ChallengeFinalized(bytes32 indexed pairHash, bool success);
    event V4PoolEvicted(bytes32 indexed pairHash, uint24 fee, int24 tickSpacing, address hooks);

    error PoolDoesNotExist();
    error DuplicatePool();
    error BoardFull();
    error ChallengerHasNoLiquidity();
    error ChallengePending();
    error NoChallenge();
    error ChallengeNotReady();

    constructor() {
        defaultV4Configs.push(V4PoolConfig({fee: 100, tickSpacing: 1}));
        defaultV4Configs.push(V4PoolConfig({fee: 500, tickSpacing: 10}));
        defaultV4Configs.push(V4PoolConfig({fee: 3000, tickSpacing: 60}));
        defaultV4Configs.push(V4PoolConfig({fee: 10000, tickSpacing: 200}));
    }

    /// @notice Register a V4 pool onto a NON-FULL leaderboard. Permissionless.
    /// @dev Pool must exist (sqrtPriceX96 != 0). A full board cannot be joined directly;
    /// use startV4Challenge / finalizeV4Challenge.
    function registerV4Pool(address tokenA, address tokenB, uint24 fee, int24 tickSpacing, address hooks) external {
        PoolKey memory key = _buildPoolKey(tokenA, tokenB, fee, tickSpacing, hooks);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) revert PoolDoesNotExist();

        bytes32 ph = _pairHash(tokenA, tokenB);
        V4PoolEntry[] storage entries = v4Leaderboard[ph];
        _checkNotListed(entries, fee, tickSpacing, hooks);
        if (entries.length >= MAX_V4_POOLS_PER_PAIR) revert BoardFull();

        entries.push(V4PoolEntry({fee: fee, tickSpacing: tickSpacing, hooks: hooks, lastWinEpoch: 0}));
        emit V4PoolRegistered(ph, fee, tickSpacing, hooks);
    }

    /// @notice Declare a challenge against a full leaderboard. Permissionless.
    /// @dev The challenger pool must exist, be unlisted, and have nonzero active
    /// liquidity NOW; the comparison that decides eviction happens at finalization,
    /// CHALLENGE_DELAY later, so flash or short-lived (JIT) liquidity cannot win a slot.
    /// One challenge per pair at a time; a stale one (past CHALLENGE_EXPIRY) is replaced.
    function startV4Challenge(address tokenA, address tokenB, uint24 fee, int24 tickSpacing, address hooks) external {
        bytes32 ph = _pairHash(tokenA, tokenB);
        V4PoolEntry[] storage entries = v4Leaderboard[ph];
        if (entries.length < MAX_V4_POOLS_PER_PAIR) revert BoardFull(); // not full: register directly
        _checkNotListed(entries, fee, tickSpacing, hooks);

        V4Challenge storage existing = v4Challenges[ph];
        if (existing.startedAt != 0 && block.timestamp <= existing.startedAt + CHALLENGE_EXPIRY) {
            revert ChallengePending();
        }

        PoolKey memory key = _buildPoolKey(tokenA, tokenB, fee, tickSpacing, hooks);
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolDoesNotExist();
        if (poolManager.getLiquidity(poolId) == 0) revert ChallengerHasNoLiquidity();

        v4Challenges[ph] = V4Challenge({
            tokenA: tokenA,
            tokenB: tokenB,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hooks,
            startedAt: uint64(block.timestamp)
        });
        emit V4ChallengeStarted(ph, fee, tickSpacing, hooks);
    }

    /// @notice Finalize a matured challenge. Callable by anyone.
    /// @dev Re-measures liquidity NOW. The eviction target is the lowest-liquidity
    /// incumbent WITHOUT a routed-swap win in the current or previous epoch (recently
    /// useful pools are shielded). The challenge succeeds only if the challenger's
    /// current liquidity exceeds the target's; either way the challenge slot is freed.
    /// A failed or expired challenge is simply discarded, never reverts, so a bogus
    /// challenge cannot block the pair for longer than CHALLENGE_DELAY.
    function finalizeV4Challenge(address tokenA, address tokenB) external returns (bool success) {
        bytes32 ph = _pairHash(tokenA, tokenB);
        V4Challenge memory challenge = v4Challenges[ph];
        if (challenge.startedAt == 0) revert NoChallenge();
        if (block.timestamp < challenge.startedAt + CHALLENGE_DELAY) revert ChallengeNotReady();

        delete v4Challenges[ph];

        if (block.timestamp > challenge.startedAt + CHALLENGE_EXPIRY) {
            emit V4ChallengeFinalized(ph, false);
            return false;
        }

        V4PoolEntry[] storage entries = v4Leaderboard[ph];

        // Board may have changed since the challenge started; a listed challenger or a
        // no-longer-full board makes the challenge moot (register directly instead)
        for (uint256 i = 0; i < entries.length; i++) {
            if (
                entries[i].fee == challenge.fee && entries[i].tickSpacing == challenge.tickSpacing
                    && entries[i].hooks == challenge.hooks
            ) {
                emit V4ChallengeFinalized(ph, false);
                return false;
            }
        }
        if (entries.length < MAX_V4_POOLS_PER_PAIR) {
            emit V4ChallengeFinalized(ph, false);
            return false;
        }

        // Eviction target: lowest CURRENT liquidity among unshielded incumbents
        uint64 currentEpoch = uint64(block.timestamp / WIN_EPOCH);
        bool found;
        uint256 targetIdx;
        uint128 targetLiquidity = type(uint128).max;
        for (uint256 i = 0; i < entries.length; i++) {
            // Shield: a win in the current or previous epoch marks the pool as recently
            // useful; it cannot be evicted no matter how low its active-tick reading is
            if (entries[i].lastWinEpoch + 1 >= currentEpoch && entries[i].lastWinEpoch != 0) continue;
            PoolKey memory incumbentKey = _buildPoolKey(
                challenge.tokenA, challenge.tokenB, entries[i].fee, entries[i].tickSpacing, entries[i].hooks
            );
            uint128 liquidity = poolManager.getLiquidity(incumbentKey.toId());
            if (!found || liquidity < targetLiquidity) {
                found = true;
                targetIdx = i;
                targetLiquidity = liquidity;
            }
        }

        if (!found) {
            // Every incumbent recently won a routed swap: the board is healthy
            emit V4ChallengeFinalized(ph, false);
            return false;
        }

        PoolKey memory challengerKey =
            _buildPoolKey(challenge.tokenA, challenge.tokenB, challenge.fee, challenge.tickSpacing, challenge.hooks);
        uint128 challengerLiquidity = poolManager.getLiquidity(challengerKey.toId());
        if (challengerLiquidity <= targetLiquidity) {
            emit V4ChallengeFinalized(ph, false);
            return false;
        }

        emit V4PoolEvicted(ph, entries[targetIdx].fee, entries[targetIdx].tickSpacing, entries[targetIdx].hooks);
        entries[targetIdx] = V4PoolEntry({
            fee: challenge.fee, tickSpacing: challenge.tickSpacing, hooks: challenge.hooks, lastWinEpoch: 0
        });
        emit V4PoolRegistered(ph, challenge.fee, challenge.tickSpacing, challenge.hooks);
        emit V4ChallengeFinalized(ph, true);
        return true;
    }

    function _checkNotListed(V4PoolEntry[] storage entries, uint24 fee, int24 tickSpacing, address hooks) private view {
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].fee == fee && entries[i].tickSpacing == tickSpacing && entries[i].hooks == hooks) {
                revert DuplicatePool();
            }
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

    /// @notice Stamp a leaderboard entry as having won a routed swap this epoch.
    /// @dev Skips the SSTORE when the entry is already stamped for the current epoch,
    /// so the hot-path cost is one warm write per pool per epoch at most.
    function _recordV4Win(bytes32 ph, uint24 fee, int24 tickSpacing, address hooks) internal {
        V4PoolEntry[] storage entries = v4Leaderboard[ph];
        uint64 currentEpoch = uint64(block.timestamp / WIN_EPOCH);
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].fee == fee && entries[i].tickSpacing == tickSpacing && entries[i].hooks == hooks) {
                if (entries[i].lastWinEpoch != currentEpoch) entries[i].lastWinEpoch = currentEpoch;
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
