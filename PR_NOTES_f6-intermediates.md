# F6: configurable intermediate-token set (draft PR body)

Implements TDD 5.2 F6. Routing can now try multiple 2-hop intermediates instead of only WETH, managed by the contract's first owner. Stacked on the parity-finishers branch.

## Design

- **WETH's two roles are split.** The `intermediateToken` immutable keeps ALL native-ETH duties (msg.value wrap/unwrap, `_resolveUserToken` V4 address(0) aliasing, V4PoolRegistry native-variant discovery, SwapExecutor hop-boundary wrapping). The new owner-managed `intermediateTokens` array is read ONLY by the two routing loops. Removing WETH from the set disables it as a routing hop without touching wrapping; adding a non-WETH intermediate cannot reach any native-ETH code path.
- **Ownership**: minimal local `Ownable2Step` (the vendored OZ is 0.7-era and has no two-step variant). Constructor takes `initialOwner`; deploy script passes the broadcaster. `addNewFeeTier` deliberately stays permissionless (Open Question 4 unchanged).
- **Set management**: `addIntermediateToken` / `removeIntermediateToken` (onlyOwner), zero-address and duplicate rejection, hard cap of 5 to bound quote gas, add/remove events, `intermediateTokensLength()` view. The set starts as `[WETH]`, so deploy-time behavior is identical to the previous hard-coded routing.
- **Routing**: `routeExactInput`/`routeExactOutput` fold the direct route with a 2-hop candidate per configured intermediate via `QuoteLibrary.better`; an intermediate equal to either endpoint is skipped (that candidate IS the direct route). Failed legs collapse to 0-amount quotes that `better` discards; an emptied set degrades to direct-only routing.
- **Quote cost**: grows linearly, roughly two full single-hop sweeps (~29 pool probes each) per added intermediate. View-path only; execution gas unchanged.

## Breaking change

Constructor gained an `initialOwner` parameter (redeploy anyway; nothing is proxied). All test fixtures and the deploy script updated.

## Testing

`test/Intermediates.t.sol` (12 tests, mainnet fork): access control and two-step ownership transfer, cap/dedup/zero checks, remove semantics; a deterministic pair (fresh tokens, seeded V3 pools) routable ONLY via an added USDC intermediate, exact-in parity and exact-out refund in input-token units through it; endpoint-equals-intermediate skip; native-ETH swaps unaffected by a non-WETH set entry; WETH removal disables routing hops (proven against a baseline WETH route) without breaking wrapping. Full suite: 84 tests passing, 1 conditional skip.

Adversarial review (code-reviewer agent) on the diff: no confirmed correctness findings; one vacuous-test branch flagged and fixed (the WETH-removal negative is now asserted against a baseline).
