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
/// @dev Default configs check standard (fee, tickSpacing) combos with hooks=address(0);
/// they are always probed and may never occupy leaderboard slots. The leaderboard holds
/// up to 8 registered pools per pair. Joining a non-full board is direct; a full board is
/// contested through a PAIRWISE, POKEABLE CHALLENGE: the challenger names one incumbent
/// slot as its target, both pools' active liquidity is sampled at declaration, at any
/// point during the window (permissionless pokes), and once more at finalization, and
/// each side's score is the MINIMUM of all its samples. The challenger evicts the named
/// target only if its min strictly exceeds the target's. Min-scoring makes flash/JIT
/// liquidity useless (a single low sample pins the score for the whole window) and makes
/// late defense pointless (a min can never be raised), so winning a slot takes capital
/// genuinely parked for the full CHALLENGE_DELAY. Slots that just changed hands are
/// protected by a short cooldown (see SLOT_COOLDOWN).
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
        /// @dev Timestamp before which this SLOT cannot be named as a challenge target.
        uint64 cooldownUntil;
    }

    /// @dev A pending pairwise challenge, keyed by (pair, challenger config). The two
    /// mins start as the declaration-time samples and only ever decrease (via pokes and
    /// the finalization sample).
    struct V4Challenge {
        uint64 startedAt;
        uint24 targetFee;
        int24 targetTickSpacing;
        address targetHooks;
        uint128 challengerMin;
        uint128 targetMin;
    }

    uint8 constant MAX_V4_POOLS_PER_PAIR = 8;
    uint256 internal constant CHALLENGE_DELAY = 1 days;
    uint256 internal constant CHALLENGE_EXPIRY = 3 days;
    /// @dev Quiet period stamped on a slot ONLY when its membership changes: a new entry
    /// joining a non-full board via registerV4Pool, or a challenger taking the slot by
    /// eviction. Deliberately NO cooldown after a failed or void challenge: if losing a
    /// challenge protected the target, an incumbent could self-challenge with a dust
    /// pool, lose on purpose, and repeat forever for permanent immunity. Failed
    /// challenges cost incumbents nothing (defense is passive — the target's liquidity
    /// is merely sampled, its LPs do nothing), so only membership changes need the
    /// quiet period.
    uint256 internal constant SLOT_COOLDOWN = 3 days;

    V4PoolConfig[] internal defaultV4Configs;
    mapping(bytes32 pairHash => V4PoolEntry[]) internal v4Leaderboard;
    /// @dev Challenges are keyed by (pair, challenger config), NOT one slot per pair:
    /// a single-slot design would let a griefer with any dust pool perpetually occupy
    /// the slot and make stale incumbents un-evictable. Concurrent challenges by
    /// different challengers are independent, even against the same target (the first
    /// finalized eviction wins; later ones void when the target is gone).
    mapping(bytes32 challengeId => V4Challenge) internal v4Challenges;

    event V4PoolRegistered(bytes32 indexed pairHash, uint24 fee, int24 tickSpacing, address hooks);
    event V4ChallengeStarted(
        bytes32 indexed pairHash,
        uint24 challengerFee,
        int24 challengerTickSpacing,
        address challengerHooks,
        uint24 targetFee,
        int24 targetTickSpacing,
        address targetHooks,
        uint64 startedAt
    );
    event V4ChallengePoked(
        bytes32 indexed pairHash,
        uint24 challengerFee,
        int24 challengerTickSpacing,
        address challengerHooks,
        uint128 challengerMin,
        uint128 targetMin
    );
    event V4ChallengeFinalized(bytes32 indexed pairHash, bool success);
    event V4PoolEvicted(bytes32 indexed pairHash, uint24 fee, int24 tickSpacing, address hooks);

    error PoolDoesNotExist();
    error PoolHasNoLiquidity();
    error DuplicatePool();
    error BoardFull();
    error BoardNotFull();
    error DefaultConfigNotAllowed();
    error TargetNotListed();
    error SlotInCooldown();
    error ChallengePending();
    error NoChallenge();
    error ChallengeNotReady();
    error ChallengeExpired();

    constructor() {
        defaultV4Configs.push(V4PoolConfig({fee: 100, tickSpacing: 1}));
        defaultV4Configs.push(V4PoolConfig({fee: 500, tickSpacing: 10}));
        defaultV4Configs.push(V4PoolConfig({fee: 3000, tickSpacing: 60}));
        defaultV4Configs.push(V4PoolConfig({fee: 10000, tickSpacing: 200}));
    }

    /// @notice Register a V4 pool onto a NON-FULL leaderboard. Permissionless.
    /// @dev Pool must exist AND have nonzero active liquidity (an initialized-but-empty
    /// pool is not a routing candidate and must not squat a slot). Default configs are
    /// rejected: they are probed unconditionally during discovery, so listing one would
    /// waste a board slot. A full board cannot be joined directly; use startV4Challenge /
    /// finalizeV4Challenge. The new slot starts in cooldown (membership change).
    function registerV4Pool(address tokenA, address tokenB, uint24 fee, int24 tickSpacing, address hooks) external {
        if (hooks == address(0) && _isDefaultConfig(fee, tickSpacing)) revert DefaultConfigNotAllowed();

        PoolKey memory key = _buildPoolKey(tokenA, tokenB, fee, tickSpacing, hooks);
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolDoesNotExist();
        if (poolManager.getLiquidity(poolId) == 0) revert PoolHasNoLiquidity();

        bytes32 ph = _pairHash(tokenA, tokenB);
        V4PoolEntry[] storage entries = v4Leaderboard[ph];
        _checkNotListed(entries, fee, tickSpacing, hooks);
        if (entries.length >= MAX_V4_POOLS_PER_PAIR) revert BoardFull();

        entries.push(
            V4PoolEntry({
                fee: fee,
                tickSpacing: tickSpacing,
                hooks: hooks,
                cooldownUntil: uint64(block.timestamp + SLOT_COOLDOWN)
            })
        );
        emit V4PoolRegistered(ph, fee, tickSpacing, hooks);
    }

    /// @notice Declare a pairwise challenge against one named incumbent slot of a full
    /// leaderboard. Permissionless.
    /// @dev The challenger pool must exist, be unlisted, not be a default config, and
    /// have nonzero active liquidity NOW. The named target must be listed and its slot
    /// out of cooldown. Both pools are sampled immediately; the samples seed each side's
    /// running MINIMUM, which pokes and the finalization sample can only lower. The
    /// challenge is keyed by (pair, challenger config): re-declaring the same challenge
    /// is blocked until it expires so its clock (and its recorded mins) cannot be reset.
    function startV4Challenge(
        address tokenA,
        address tokenB,
        uint24 challengerFee,
        int24 challengerTickSpacing,
        address challengerHooks,
        uint24 targetFee,
        int24 targetTickSpacing,
        address targetHooks
    ) external {
        bytes32 ph = _pairHash(tokenA, tokenB);
        V4PoolEntry[] storage entries = v4Leaderboard[ph];
        if (entries.length < MAX_V4_POOLS_PER_PAIR) revert BoardNotFull(); // not full: register directly
        _checkNotListed(entries, challengerFee, challengerTickSpacing, challengerHooks);
        if (challengerHooks == address(0) && _isDefaultConfig(challengerFee, challengerTickSpacing)) {
            revert DefaultConfigNotAllowed();
        }

        (bool listed, uint256 targetIdx) = _findEntry(entries, targetFee, targetTickSpacing, targetHooks);
        if (!listed) revert TargetNotListed();
        if (block.timestamp < entries[targetIdx].cooldownUntil) revert SlotInCooldown();

        // Re-declaring the same challenge would reset its clock and mins; block until it expires
        bytes32 challengeId = _challengeId(ph, challengerFee, challengerTickSpacing, challengerHooks);
        uint64 existing = v4Challenges[challengeId].startedAt;
        if (existing != 0 && block.timestamp <= existing + CHALLENGE_EXPIRY) revert ChallengePending();

        PoolId challengerId = _buildPoolKey(tokenA, tokenB, challengerFee, challengerTickSpacing, challengerHooks).toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(challengerId);
        if (sqrtPriceX96 == 0) revert PoolDoesNotExist();
        uint128 challengerLiquidity = poolManager.getLiquidity(challengerId);
        if (challengerLiquidity == 0) revert PoolHasNoLiquidity();

        uint128 targetLiquidity =
            poolManager.getLiquidity(_buildPoolKey(tokenA, tokenB, targetFee, targetTickSpacing, targetHooks).toId());

        v4Challenges[challengeId] = V4Challenge({
            startedAt: uint64(block.timestamp),
            targetFee: targetFee,
            targetTickSpacing: targetTickSpacing,
            targetHooks: targetHooks,
            challengerMin: challengerLiquidity,
            targetMin: targetLiquidity
        });
        emit V4ChallengeStarted(
            ph,
            challengerFee,
            challengerTickSpacing,
            challengerHooks,
            targetFee,
            targetTickSpacing,
            targetHooks,
            uint64(block.timestamp)
        );
    }

    /// @notice Sample both sides of a pending challenge and lower their stored minimums.
    /// Callable by anyone, any number of times, while the challenge is live.
    /// @dev A poke can only ever LOWER a side's score, never raise it. This is the teeth
    /// of the mechanism: one poke while a challenger's flash/JIT liquidity is absent pins
    /// its score near zero for the rest of the window, and one poke while a stale target
    /// is empty makes topping it up before finalization pointless. Defenders and
    /// challengers alike are expected to poke at moments favorable to them.
    function pokeV4Challenge(address tokenA, address tokenB, uint24 fee, int24 tickSpacing, address hooks) external {
        bytes32 ph = _pairHash(tokenA, tokenB);
        V4Challenge storage challenge = v4Challenges[_challengeId(ph, fee, tickSpacing, hooks)];
        uint64 startedAt = challenge.startedAt;
        if (startedAt == 0) revert NoChallenge();
        if (block.timestamp > startedAt + CHALLENGE_EXPIRY) revert ChallengeExpired();

        (uint128 challengerMin, uint128 targetMin) = _sampleChallenge(challenge, tokenA, tokenB, fee, tickSpacing, hooks);
        emit V4ChallengePoked(ph, fee, tickSpacing, hooks, challengerMin, targetMin);
    }

    /// @notice Finalize a matured challenge. Callable by anyone.
    /// @dev Valid in [start+DELAY, start+EXPIRY]: takes one final min-sample of both
    /// sides, deletes the challenge, then evicts the named target iff the challenger's
    /// min STRICTLY exceeds the target's min. If the target already lost its slot to a
    /// concurrently finalized challenge, the challenge is void (deleted, no eviction).
    /// Past EXPIRY finalization just discards the stale challenge and reports failure,
    /// never reverts, so an abandoned challenge cannot wedge its challenger config.
    /// On eviction the challenger takes the slot and the slot enters cooldown
    /// (membership change). A failed challenge stamps NO cooldown — see SLOT_COOLDOWN
    /// for why that is load-bearing.
    function finalizeV4Challenge(address tokenA, address tokenB, uint24 fee, int24 tickSpacing, address hooks)
        external
        returns (bool success)
    {
        bytes32 ph = _pairHash(tokenA, tokenB);
        bytes32 challengeId = _challengeId(ph, fee, tickSpacing, hooks);
        V4Challenge storage challenge = v4Challenges[challengeId];
        uint64 startedAt = challenge.startedAt;
        if (startedAt == 0) revert NoChallenge();
        if (block.timestamp < startedAt + CHALLENGE_DELAY) revert ChallengeNotReady();

        if (block.timestamp > startedAt + CHALLENGE_EXPIRY) {
            delete v4Challenges[challengeId];
            emit V4ChallengeFinalized(ph, false);
            return false;
        }

        (uint128 challengerMin, uint128 targetMin) = _sampleChallenge(challenge, tokenA, tokenB, fee, tickSpacing, hooks);
        (uint24 targetFee, int24 targetTickSpacing, address targetHooks) =
            (challenge.targetFee, challenge.targetTickSpacing, challenge.targetHooks);
        delete v4Challenges[challengeId];

        success = _executeEviction(
            ph, fee, tickSpacing, hooks, targetFee, targetTickSpacing, targetHooks, challengerMin, targetMin
        );
        emit V4ChallengeFinalized(ph, success);
    }

    /// @dev Evict the named target and seat the challenger, if the min-scores allow it.
    function _executeEviction(
        bytes32 ph,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint24 targetFee,
        int24 targetTickSpacing,
        address targetHooks,
        uint128 challengerMin,
        uint128 targetMin
    ) private returns (bool) {
        V4PoolEntry[] storage entries = v4Leaderboard[ph];

        // Void if the named target already lost its slot to a concurrently finalized
        // challenge (first eviction wins). Also void, defensively, if the challenger
        // is somehow already listed: the board must never hold duplicates.
        (bool targetListed, uint256 targetIdx) = _findEntry(entries, targetFee, targetTickSpacing, targetHooks);
        if (!targetListed) return false;
        (bool challengerListed,) = _findEntry(entries, fee, tickSpacing, hooks);
        if (challengerListed) return false;

        // Strict inequality: a tie keeps the incumbent
        if (challengerMin <= targetMin) return false;

        emit V4PoolEvicted(ph, targetFee, targetTickSpacing, targetHooks);
        entries[targetIdx] = V4PoolEntry({
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hooks,
            cooldownUntil: uint64(block.timestamp + SLOT_COOLDOWN)
        });
        emit V4PoolRegistered(ph, fee, tickSpacing, hooks);
        return true;
    }

    /// @dev Sample the current active liquidity of both sides of a challenge and fold
    /// each into its stored running minimum (min-update only; a sample can never raise
    /// a score). Returns the updated mins.
    function _sampleChallenge(
        V4Challenge storage challenge,
        address tokenA,
        address tokenB,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    ) private returns (uint128 challengerMin, uint128 targetMin) {
        uint128 challengerLiquidity =
            poolManager.getLiquidity(_buildPoolKey(tokenA, tokenB, fee, tickSpacing, hooks).toId());
        challengerMin = challenge.challengerMin;
        if (challengerLiquidity < challengerMin) {
            challengerMin = challengerLiquidity;
            challenge.challengerMin = challengerLiquidity;
        }

        uint128 targetLiquidity = poolManager.getLiquidity(
            _buildPoolKey(tokenA, tokenB, challenge.targetFee, challenge.targetTickSpacing, challenge.targetHooks).toId()
        );
        targetMin = challenge.targetMin;
        if (targetLiquidity < targetMin) {
            targetMin = targetLiquidity;
            challenge.targetMin = targetLiquidity;
        }
    }

    function _challengeId(bytes32 ph, uint24 fee, int24 tickSpacing, address hooks) private pure returns (bytes32) {
        return keccak256(abi.encode(ph, fee, tickSpacing, hooks));
    }

    function _findEntry(V4PoolEntry[] storage entries, uint24 fee, int24 tickSpacing, address hooks)
        private
        view
        returns (bool found, uint256 idx)
    {
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].fee == fee && entries[i].tickSpacing == tickSpacing && entries[i].hooks == hooks) {
                return (true, i);
            }
        }
    }

    function _checkNotListed(V4PoolEntry[] storage entries, uint24 fee, int24 tickSpacing, address hooks) private view {
        (bool listed,) = _findEntry(entries, fee, tickSpacing, hooks);
        if (listed) revert DuplicatePool();
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
