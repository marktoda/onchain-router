# Pre-pilot hardening bundle (draft PR body)

Implements the pre-pilot changes from the OnchainRouter Hardening TDD (section 5.1) as one audited bundle. No existing function signatures change (TDD N3), with two deliberate failure-path exceptions on the legacy signatures, both fixes for latent fund-safety bugs: native-ETH calls now require `msg.value == quote.amountIn` (previously a mismatched deposit could strand or borrow router-held WETH), and multihop exact-output refunds are now computed correctly (see below).

## Changes

### F1: Canonical slippage bound (`src/OnchainRouter.sol`)
- New overloads `swapExactInput(quote, recipient, deadline, unwrapOutput, uint256 minAmountOut)` and `swapExactOutput(..., uint256 maxAmountIn)`.
- The caller bound is authoritative on the hot path: it is threaded into `quote.amountOut` / `quote.amountIn` before execution, so the executor's existing enforcement points (`TooLittleReceived` at SwapExecutor.sol exact-in checks; `MaxInputAmount` transient + per-hop `*TooMuchRequested` for exact-out) enforce the caller value on both the direct and V4-unlock paths. No re-fetched quote is ever consulted.
- Exact-out semantics: `maxAmountIn` replaces `quote.amountIn` as the funding amount (pulled via transferFrom, or expected as msg.value) and the per-hop cap; unspent input is refunded as before.
- The 4-arg signatures delegate with bound = quoted amount, preserving today's zero-tolerance happy-path behavior.
- A zero bound falls back to the quoted amount rather than disabling protection: `minAmountOut = 0` would otherwise silently accept any price (a free MEV sandwich), and `maxAmountIn = 0` would fund nothing and always revert. Both default to the legacy zero-tolerance behavior.

### F2: `addNewFeeTier` hardening (`src/base/PathGenerator.sol`)
- Added a dedup check (`DuplicateFeeTier`) and converted the string revert to a custom error (`InvalidFeeTier`).
- **Deliberate deviation from the TDD, for reviewer sign-off:** the TDD says `onlyOwner` + dedup. The factory-validity check (already present) plus dedup fully bounds the array to the set of governance-enabled fee tiers, each addable once, which removes the gas-griefing vector entirely. Keeping the function permissionless preserves the router's no-admin trust model and avoids introducing ownership, a constructor change, and deploy-script churn for this fix alone. If ownership lands later (e.g. for the post-pilot configurable intermediate set), gating this function is a one-line follow-up.

### F3: Reentrancy guard (`src/OnchainRouter.sol`)
- Transient-storage `nonReentrant` (Solidity 0.8.28 `transient` keyword, cancun) on both swap entrypoints. Zero storage cost, auto-resets per transaction.
- The guard covers the external entrypoints only. `unlockCallback` and `uniswapV3SwapCallback` are re-entered by the poolManager / V3 pools while the lock is held and remain access-controlled by caller checks instead (unchanged).

### F4: Fee-on-transfer detect-and-revert (`src/OnchainRouter.sol`)
- `_pullInput` measures the router's balance delta around `transferFrom` and reverts `FeeOnTransferNotSupported` on any shortfall. Applied on both entrypoints.
- Balance-check approach (no detector contract, no new immutable): catches FOT input tokens with a clear error before any pool interaction. FOT tokens in intermediate/output legs still revert deep in pool code as today; full FOT routing is post-pilot per the TDD.

### Native-ETH deposit/bound equality check (found in adversarial self-review)
- Both entrypoints now revert `ETHValueMismatch(expected, actual)` unless `msg.value == quote.amountIn` on the ETH path (replaces the previously declared-but-unused `InsufficientETH`, whose name misread the over-payment case).
- Without this, the exact-output refund is computed against the max-input bound while only `msg.value` was deposited: sending more than the bound strands WETH in the router, and sending less makes the refund draw on WETH the caller never deposited (cross-user fund loss once any WETH is stranded). The new `maxAmountIn` overload made this latent mismatch easy to hit, so it is enforced for the legacy signatures too.

### Multihop exact-output refund fix (found in deep review)
- `_swapExactOutput` returns the LAST hop's input, which on a 2-hop route is denominated in the intermediate token (WETH), not the user's input token. The old `excess = quote.amountIn - amountIn` refund therefore mixed units: USDC->WETH->DAI style routes underflowed and reverted (DoS of every multihop exact-out), and 18-decimal-input routes computed refunds the router could not cover (or would over-refund any stranded router balance).
- Root cause predates this branch, but the `maxAmountIn` overload builds its refund guarantee on that math, so it is fixed here: realized input is now derived from the router's own balance delta of the user's input token, which is unit-correct for any path shape. Covered by a forced 2-hop exact-out test.

### Safety-invariant NatSpec
- Documented the layered defense (deadline, guard, FOT check, bound enforcement, stateless-per-call invariant) on both swap paths.

## Testing

- New `test/Hardening.t.sol` (18 tests, mainnet fork at the existing pinned block 19685800): native-ETH exact-out with `maxAmountIn` (refund correctness, no stranded WETH, deposit/bound mismatch reverts both ways, exact-in mismatch reverts both ways); multihop (2-hop) exact-out with `maxAmountIn` asserting the refund and return value are in input-token units with nothing stranded; bound authority for exact-in (inflated quote + loose bound succeeds; unmet bound reverts `TooLittleReceived`), exact-out tolerance + refund of unspent input, bound-exceeded revert, legacy 4-arg zero-tolerance behavior unchanged, duplicate/invalid fee tier reverts, new tier still addable once, reentrancy attempt via ETH-receive callback reverts `Reentrancy` (attacker contract), FOT mock token reverts on both entrypoints, normal-token pull unaffected.
- Updated `test/OnchainRouter.t.sol` fee-tier test for the custom error.
- Full suite green: 53 tests passing, 1 conditional skip (RouterForkTest, SwapExecutionForkTest, HardeningForkTest on mainnet fork; V4BaseForkTest + V4LeaderboardTest on Base fork). New V4-path bound tests in `V4Integration.t.sol` exercise `minAmountOut`/`maxAmountIn` through the `unlock()` execution path (including the reentrancy guard held across `unlockCallback`); the exact-in variant self-skips when the live Base route does not select a V4 pool.
- Local verification used public RPCs (eth.drpc.org, mainnet.base.org) since CI secrets are unavailable locally; CI will rerun with its own endpoints.

## Gas (TDD N2: under 5% regression)

Same fork block, existing SwapExecutionForkTest, main vs this branch:

| Test | main | branch | delta |
|---|---|---|---|
| swapExactInput ERC20→ERC20 | 733,707 | 738,229 | +0.62% |
| swapExactInput ERC20→ETH unwrap | 760,094 | 764,616 | +0.59% |
| swapExactInput ETH→ERC20 | 752,728 | 753,543 | +0.11% |
| swapExactInput multihop | 1,957,532 | 1,962,274 | +0.24% |
| swapExactOutput ERC20→ERC20 | 734,739 | 742,844 | +1.10% |
| swapExactOutput ETH→ERC20 refund | 756,371 | 759,190 | +0.37% |

Worst case +1.10% (FOT-detection and refund-accounting balanceOf calls plus the transient guard). ETH paths skip the FOT check.

## Notes for reviewers

- The exact-out overload changes what is pulled from the caller: `maxAmountIn`, not `quote.amountIn`. SDKs should fund approvals accordingly.
- Overloaded signatures: ABI tooling must select by full signature (selectors differ).
- Error-type change in `addNewFeeTier` (string → custom error) is a failure-path-only change.
