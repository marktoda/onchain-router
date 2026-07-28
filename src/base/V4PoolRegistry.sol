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
/// @dev Default configs check standard (fee, tickSpacing) combos with hooks=address(0);
/// they are always probed and may never occupy leaderboard slots. The leaderboard holds
/// up to 8 registered pools per pair. Joining a non-full board is direct; a full board is
/// contested through a PAIRWISE, POKEABLE CHALLENGE: the challenger names one incumbent slot
/// as its target, and each side's score is its liquidity INTEGRATED OVER TIME across the
/// window. Every sample (declaration, any permissionless poke, finalization) credits the
/// PREVIOUS observation for the seconds it actually held. The challenger evicts the named
/// target only if its integral strictly exceeds the target's.
///
/// Weighting by duration makes both sides honest. Flash/JIT capital present for one
/// transaction earns ~0 weight, so a challenger cannot buy a slot with a flash loan.
/// Symmetrically, a transient dip manufactured against a target (swap its price out of range,
/// poke, swap back, all atomic) also earns ~0 weight. That symmetry is the correction to the
/// previous min-of-samples design, under which one manufactured dip pinned a healthy pool for
/// the entire window and the incumbent had NO defensive move, because a minimum can only ever
/// fall.
///
/// RESIDUAL, accepted, and it is a VIGILANCE ASSUMPTION, not a guarantee: an observation is
/// carried forward until the next one, so a sample left uncorrected accrues weight for as long
/// as nobody pokes. Two cases, and they are not equally bounded.
///
/// Mid-window manipulation is well bounded. An attacker cannot get large weight without a
/// correspondingly long exposure, since weight is proportional to the uncorrected duration and
/// any single counter-poke by any party ends it. A sample taken at finalization is worth
/// nothing at all (zero elapsed time, and finalization does not sample).
///
/// The DECLARATION sample is NOT bounded that way, and this is the sharp edge. startV4Challenge
/// records both sides and starts them accruing immediately, so on a challenge that nobody ever
/// pokes, the declaration samples decide the outcome for the entire window. A challenger can
/// flash-borrow liquidity, declare in the same transaction, release it, and win unpoked: full
/// window of weight for one transaction of exposure. One poke by anyone collapses that to
/// almost nothing, which is exactly why this is an assumption about observers rather than a
/// property of the mechanism. See test_challenge_unpokedFlashChallenger_winsKnownResidual.
///
/// Pokes are deliberately NOT rate-limited so a counter-poke can land in the next block, and
/// the poke/finalize events carry both accumulators so this is monitorable offchain. If the
/// assumption proves too weak in practice, the fix is a minimum-observation gate (fail
/// finalization closed when the window is under-sampled); slots 2 and 3 of V4Challenge keep
/// spare bits for it precisely so it can be added without a storage layout change.
///
/// Ties keep the incumbent. Finalize timing is neutral: both sides accrue over the same span,
/// and no sample taken at finalization can earn weight. Slots that just changed hands are
/// protected by a short cooldown (see SLOT_COOLDOWN).
abstract contract V4PoolRegistry is OnchainRouterImmutables {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using Hooks for IHooks;

    struct V4PoolConfig {
        uint24 fee;
        int24 tickSpacing;
    }

    struct V4PoolEntry {
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        /// @dev Timestamp before which this SLOT cannot be named as a challenge target.
        /// uint48 so the whole entry packs into a single storage slot (EIP-170 headroom;
        /// uint48 seconds overflow around year 8,921,556).
        uint48 cooldownUntil;
    }

    /// @dev A pending pairwise challenge, keyed by (pair, challenger config). Each side
    /// carries a TIME-WEIGHTED accumulator rather than a running minimum: its score is
    /// liquidity integrated over the window, not the worst instant observed. Field order is
    /// load-bearing for packing, 4 slots:
    ///   0: startedAt | targetFee | targetTickSpacing | targetHooks  (48+24+24+160 = 256)
    ///   1: challengerLast | targetLast                              (128+128     = 256)
    ///   2: challengerAcc | lastSampleAt                             (160+48      = 208)
    ///   3: targetAcc                                                (160)
    /// Slots 2 and 3 keep 48 and 96 spare bits, so a future sampling-coverage gate can be
    /// added without disturbing the layout of any existing field.
    struct V4Challenge {
        uint48 startedAt;
        uint24 targetFee;
        int24 targetTickSpacing;
        address targetHooks;
        /// @dev Most recent observation for each side, carried forward until the next sample
        /// credits it for the time it actually held.
        uint128 challengerLast;
        uint128 targetLast;
        /// @dev Sum of liquidity * seconds. A uint128 liquidity over at most CHALLENGE_EXPIRY
        /// seconds is ~8.8e43 against a uint160 ceiling of ~1.46e48: cannot overflow.
        uint160 challengerAcc;
        uint48 lastSampleAt;
        uint160 targetAcc;
    }

    /// @dev In-memory bundle of a pending challenge's identifying configs (caller-supplied
    /// pair + challenger config, stored target config), shared by the poke/finalize
    /// sampling and eviction paths; it is never stored.
    struct V4ChallengeRef {
        address tokenA;
        address tokenB;
        uint24 challengerFee;
        int24 challengerTickSpacing;
        address challengerHooks;
        uint24 targetFee;
        int24 targetTickSpacing;
        address targetHooks;
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
    /// @dev Carries both the fresh samples and the running accumulators. The trust model is
    /// explicitly vigilance-based (see the contract NatSpec), so the chain has to make paying
    /// attention cheap: anyone can watch these and alert an incumbent's LPs that their
    /// time-weighted score is being dragged down.
    event V4ChallengePoked(
        bytes32 indexed pairHash,
        uint24 challengerFee,
        int24 challengerTickSpacing,
        address challengerHooks,
        uint128 challengerSample,
        uint128 targetSample,
        uint160 challengerAcc,
        uint160 targetAcc
    );
    event V4ChallengeFinalized(bytes32 indexed pairHash, bool success, uint160 challengerAcc, uint160 targetAcc);
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
    error CustomAccountingHookNotAllowed();

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
        _rejectDefaultConfig(fee, tickSpacing, hooks);
        _rejectCustomAccountingHook(hooks);

        _requireLivePool(tokenA, tokenB, fee, tickSpacing, hooks);

        bytes32 ph = _pairHash(tokenA, tokenB);
        V4PoolEntry[] storage entries = v4Leaderboard[ph];
        _checkNotListed(entries, fee, tickSpacing, hooks);
        if (entries.length >= MAX_V4_POOLS_PER_PAIR) revert BoardFull();

        // Accepted-low griefing surface: on a FRESH board an attacker can register 8
        // dust pools (each needs only nonzero liquidity) and these join-time cooldowns
        // then lock real pools out of challenging for one SLOT_COOLDOWN. Bounded and
        // non-renewable: failed/void challenges stamp nothing, so after the one period
        // every dust slot is permanently contestable, and the default configs keep
        // routing throughout.
        entries.push(_cooldownEntry(fee, tickSpacing, hooks));
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
        _rejectDefaultConfig(challengerFee, challengerTickSpacing, challengerHooks);
        _rejectCustomAccountingHook(challengerHooks);

        {
            (bool listed, uint256 targetIdx) = _findEntry(entries, targetFee, targetTickSpacing, targetHooks);
            if (!listed) revert TargetNotListed();
            if (block.timestamp < entries[targetIdx].cooldownUntil) revert SlotInCooldown();
        }

        // Re-declaring the same challenge would reset its clock and mins; block until it expires
        bytes32 challengeId = _challengeId(ph, challengerFee, challengerTickSpacing, challengerHooks);
        unchecked {
            // existing is a uint48; adding a small constant cannot overflow uint256
            uint48 existing = v4Challenges[challengeId].startedAt;
            if (existing != 0 && block.timestamp <= existing + CHALLENGE_EXPIRY) revert ChallengePending();
        }

        uint128 challengerLiquidity =
            _requireLivePool(tokenA, tokenB, challengerFee, challengerTickSpacing, challengerHooks);

        uint128 targetLiquidity = _activeLiquidity(tokenA, tokenB, targetFee, targetTickSpacing, targetHooks);

        v4Challenges[challengeId] = V4Challenge({
            startedAt: uint48(block.timestamp),
            targetFee: targetFee,
            targetTickSpacing: targetTickSpacing,
            targetHooks: targetHooks,
            // Declaration samples start accruing now; both accumulators start empty, so a
            // challenger who manipulates at declaration time earns zero weight for it.
            challengerLast: challengerLiquidity,
            targetLast: targetLiquidity,
            challengerAcc: 0,
            lastSampleAt: uint48(block.timestamp),
            targetAcc: 0
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

    /// @notice Sample both sides of a pending challenge, crediting the previous observation
    /// for the time it held. Callable by anyone, any number of times, while the challenge is
    /// live.
    /// @dev Deliberately NOT rate-limited. A minimum spacing between pokes would lock a
    /// defender out for exactly as long as it constrained an attacker, and defense has to be
    /// able to land in the very next block: a single counter-poke overwrites a manipulated
    /// observation and limits its weight to the gap between the two samples.
    ///
    /// RETRACTED: an earlier version of this comment claimed defenders and challengers alike
    /// poke at moments favorable to them, and that one poke defends an incumbent's slot. Under
    /// the previous min-of-samples scoring that was false in a load-bearing way, because a
    /// minimum can only fall, so poking could never help a defender and an incumbent had no
    /// defensive move at all. It is true under time-weighted scoring, which is why the scoring
    /// changed rather than the comment.
    function pokeV4Challenge(address tokenA, address tokenB, uint24 fee, int24 tickSpacing, address hooks) external {
        (bytes32 ph,, V4Challenge storage challenge, uint48 startedAt) =
            _liveChallenge(tokenA, tokenB, fee, tickSpacing, hooks);
        unchecked {
            // startedAt is a uint48; adding a small constant cannot overflow uint256
            if (block.timestamp > startedAt + CHALLENGE_EXPIRY) revert ChallengeExpired();
        }

        (uint128 challengerSample, uint128 targetSample) =
            _accrueChallenge(challenge, _challengeRef(tokenA, tokenB, fee, tickSpacing, hooks, challenge));
        emit V4ChallengePoked(
            ph, fee, tickSpacing, hooks, challengerSample, targetSample, challenge.challengerAcc, challenge.targetAcc
        );
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
        (bytes32 ph, bytes32 challengeId, V4Challenge storage challenge, uint48 startedAt) =
            _liveChallenge(tokenA, tokenB, fee, tickSpacing, hooks);
        bool live;
        unchecked {
            // startedAt is a uint48; adding a small constant cannot overflow uint256
            if (block.timestamp < startedAt + CHALLENGE_DELAY) revert ChallengeNotReady();
            live = block.timestamp <= startedAt + CHALLENGE_EXPIRY;
        }
        uint160 challengerAcc;
        uint160 targetAcc;
        if (live) {
            // Snapshot the target config into memory before the delete below
            V4ChallengeRef memory c = _challengeRef(tokenA, tokenB, fee, tickSpacing, hooks, challenge);
            // Credit the trailing interval but take NO fresh sample: see _accrueElapsed.
            _accrueElapsed(challenge);
            challengerAcc = challenge.challengerAcc;
            targetAcc = challenge.targetAcc;
            success = _executeEviction(ph, c, challengerAcc, targetAcc);
        }
        // Past EXPIRY the stale challenge is just discarded (success stays false)
        delete v4Challenges[challengeId];
        emit V4ChallengeFinalized(ph, success, challengerAcc, targetAcc);
    }

    /// @dev Load a pending challenge by (pair, challenger config), reverting if none
    /// exists. Shared head of the poke and finalize paths.
    function _liveChallenge(address tokenA, address tokenB, uint24 fee, int24 tickSpacing, address hooks)
        private
        view
        returns (bytes32 ph, bytes32 challengeId, V4Challenge storage challenge, uint48 startedAt)
    {
        ph = _pairHash(tokenA, tokenB);
        challengeId = _challengeId(ph, fee, tickSpacing, hooks);
        challenge = v4Challenges[challengeId];
        startedAt = challenge.startedAt;
        if (startedAt == 0) revert NoChallenge();
    }

    /// @dev Bundle a pending challenge's full identity (caller-supplied pair + challenger
    /// config, stored target config) into a V4ChallengeRef.
    function _challengeRef(
        address tokenA,
        address tokenB,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        V4Challenge storage challenge
    ) private view returns (V4ChallengeRef memory c) {
        c.tokenA = tokenA;
        c.tokenB = tokenB;
        c.challengerFee = fee;
        c.challengerTickSpacing = tickSpacing;
        c.challengerHooks = hooks;
        c.targetFee = challenge.targetFee;
        c.targetTickSpacing = challenge.targetTickSpacing;
        c.targetHooks = challenge.targetHooks;
    }

    /// @dev Evict the named target and seat the challenger, if the time-weighted scores allow
    /// it. Compares the raw accumulators rather than averages: both sides accrued over the
    /// identical span, so dividing each by the window changes nothing except introducing
    /// shared-floor ties.
    function _executeEviction(bytes32 ph, V4ChallengeRef memory c, uint160 challengerAcc, uint160 targetAcc)
        private
        returns (bool)
    {
        V4PoolEntry[] storage entries = v4Leaderboard[ph];

        // Void if the named target already lost its slot to a concurrently finalized
        // challenge (first eviction wins). Also void, defensively, if the challenger
        // is somehow already listed: the board must never hold duplicates.
        (bool targetListed, uint256 targetIdx) = _findEntry(entries, c.targetFee, c.targetTickSpacing, c.targetHooks);
        if (!targetListed) return false;
        (bool challengerListed,) = _findEntry(entries, c.challengerFee, c.challengerTickSpacing, c.challengerHooks);
        if (challengerListed) return false;

        // Strict inequality: a tie keeps the incumbent
        if (challengerAcc <= targetAcc) return false;

        emit V4PoolEvicted(ph, c.targetFee, c.targetTickSpacing, c.targetHooks);
        entries[targetIdx] = _cooldownEntry(c.challengerFee, c.challengerTickSpacing, c.challengerHooks);
        emit V4PoolRegistered(ph, c.challengerFee, c.challengerTickSpacing, c.challengerHooks);
        return true;
    }

    /// @dev Fold the interval since the last sample into each side's accumulator, crediting
    /// the PREVIOUSLY observed liquidity for the time it actually held, then record fresh
    /// samples as the values that accrue from here.
    ///
    /// Crediting the OLD value is the mechanism. A manipulated observation earns weight only
    /// from the moment it is recorded forward, so the atomic swap-out-of-range / poke /
    /// swap-back attack costs the target ~0 weighted seconds. And because a later sample
    /// overwrites it, ANY party (the incumbent's LPs, an arbitrageur, a keeper) can neutralize
    /// a manipulated sample with a single counter-poke, mis-crediting only the gap between the
    /// two. This is the property the previous min-of-samples design could not have: a minimum
    /// can only fall, so the target had no defensive move at all.
    function _accrueChallenge(V4Challenge storage challenge, V4ChallengeRef memory c)
        private
        returns (uint128 challengerSample, uint128 targetSample)
    {
        _accrueElapsed(challenge);

        challengerSample =
            _activeLiquidity(c.tokenA, c.tokenB, c.challengerFee, c.challengerTickSpacing, c.challengerHooks);
        targetSample = _activeLiquidity(c.tokenA, c.tokenB, c.targetFee, c.targetTickSpacing, c.targetHooks);
        challenge.challengerLast = challengerSample;
        challenge.targetLast = targetSample;
    }

    /// @dev Credit both sides' last observation for the time since it was recorded. Split out
    /// so finalization can accrue WITHOUT taking a fresh sample: a sample only earns weight
    /// for the interval between it and the next one, so a reading taken at finalization would
    /// be credited zero seconds and cannot affect the outcome. Skipping it saves two
    /// staticcalls and, more importantly, makes finalize timing provably neutral. Under the
    /// previous min-of-samples design the finalization sample WAS decisive, which is exactly
    /// what made finalize timing worth racing.
    function _accrueElapsed(V4Challenge storage challenge) private {
        uint256 elapsed = block.timestamp - challenge.lastSampleAt;
        if (elapsed == 0) return;
        unchecked {
            // See V4Challenge.challengerAcc for the overflow bound.
            challenge.challengerAcc += uint160(uint256(challenge.challengerLast) * elapsed);
            challenge.targetAcc += uint160(uint256(challenge.targetLast) * elapsed);
        }
        challenge.lastSampleAt = uint48(block.timestamp);
    }

    /// @notice Reject pools whose hook can alter swap amounts via custom accounting.
    /// @dev The quoter prices pools on core pool math only (V4Quoter is HOOK-UNAWARE BY
    /// DESIGN). A hook holding either *_RETURNS_DELTA permission serves swaps from its own
    /// balances, so its quote and its execution are unrelated and its core getLiquidity, which
    /// is what this leaderboard scores, is not its real depth either. Such a pool earns a slot
    /// on a measurement that means nothing and then wins routes on a quote the router cannot
    /// honor.
    ///
    /// Permissions are encoded in the hook's ADDRESS bits and enforced by poolManager, so this
    /// is a pure bit test the hook cannot misreport and that needs no external call. Hooks.sol
    /// guarantees *_RETURNS_DELTA implies its base *_SWAP flag, so the delta bits suffice.
    ///
    /// KNOWINGLY PERMITTED, and NOT covered by the quoter: observer hooks that only watch or
    /// revert (a reverting hook can hold a slot on honest sustained liquidity and never trade),
    /// and a per-swap lpFeeOverride on a dynamic-fee pool up to LPFeeLibrary.MAX_LP_FEE (100%).
    /// Both are quote-vs-execution divergences bounded by the caller's slippage bound, and are
    /// accepted so that dynamic-fee pools and ordinary observer hooks stay routable.
    function _rejectCustomAccountingHook(address hooks) private pure {
        if (hooks == address(0)) return;
        IHooks h = IHooks(hooks);
        if (
            h.hasPermission(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)
                || h.hasPermission(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)
        ) revert CustomAccountingHookNotAllowed();
    }

    /// @dev Default configs are probed unconditionally during discovery, so letting one
    /// onto the board (directly or via challenge) would waste a slot. Shared gate for
    /// both entry paths.
    function _rejectDefaultConfig(uint24 fee, int24 tickSpacing, address hooks) private view {
        if (hooks == address(0) && _isDefaultConfig(fee, tickSpacing)) revert DefaultConfigNotAllowed();
    }

    /// @dev A board slot stamped with the membership-change cooldown (see SLOT_COOLDOWN).
    function _cooldownEntry(uint24 fee, int24 tickSpacing, address hooks) private view returns (V4PoolEntry memory) {
        unchecked {
            // block.timestamp + a small constant cannot overflow uint256
            return V4PoolEntry({
                fee: fee, tickSpacing: tickSpacing, hooks: hooks, cooldownUntil: uint48(block.timestamp + SLOT_COOLDOWN)
            });
        }
    }

    /// @dev The challenge/eviction paths repeatedly need "active liquidity of
    /// (pair, config)"; one shared helper keeps the key-build + staticcall plumbing
    /// from being duplicated at every sample site (contract-size, EIP-170).
    function _activeLiquidity(address tokenA, address tokenB, uint24 fee, int24 tickSpacing, address hooks)
        private
        view
        returns (uint128)
    {
        return poolManager.getLiquidity(_buildPoolKey(tokenA, tokenB, fee, tickSpacing, hooks).toId());
    }

    /// @dev Shared existence + nonzero-active-liquidity gate for pools entering the
    /// registry (direct registration and challenge declaration). Returns the sampled
    /// liquidity so challenge declaration can seed the challenger's running minimum.
    function _requireLivePool(address tokenA, address tokenB, uint24 fee, int24 tickSpacing, address hooks)
        private
        view
        returns (uint128 liquidity)
    {
        PoolId poolId = _buildPoolKey(tokenA, tokenB, fee, tickSpacing, hooks).toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolDoesNotExist();
        liquidity = poolManager.getLiquidity(poolId);
        if (liquidity == 0) revert PoolHasNoLiquidity();
    }

    function _challengeId(bytes32 ph, uint24 fee, int24 tickSpacing, address hooks) private pure returns (bytes32) {
        return keccak256(abi.encode(ph, fee, tickSpacing, hooks));
    }

    function _findEntry(V4PoolEntry[] storage entries, uint24 fee, int24 tickSpacing, address hooks)
        private
        view
        returns (bool found, uint256 idx)
    {
        uint256 len = entries.length;
        for (uint256 i = 0; i < len;) {
            V4PoolEntry storage entry = entries[i];
            if (entry.fee == fee && entry.tickSpacing == tickSpacing && entry.hooks == hooks) {
                return (true, i);
            }
            unchecked {
                ++i;
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
