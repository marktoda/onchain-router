# F7: opt-in 3-hop routing (draft PR body)

Implements TDD 5.2 F7. New opt-in entrypoints find routes through two intermediates when no direct or 2-hop route exists (or when 3 hops is simply better). Stacked on the F6 branch; only meaningful with a multi-token intermediate set.

## Design

- `routeExactInput3Hop` / `routeExactOutput3Hop` (external view): superset searches that start from the standard 2-hop result and fold in a candidate per ordered pair of distinct configured intermediates (both != endpoints). Exact-out legs are sized backwards from the requested output, then combined forward. Failed legs (0 or the uint-max sentinel) are skipped before they can touch the fold.
- Existing entrypoints are byte-identical in behavior: 3-hop is caller-opt-in only, per the TDD (bounding default query gas).
- Cost: up to MAX*(MAX-1) = 20 extra candidates at the cap of 5 intermediates, each up to three single-hop sweeps (~29 pool probes each). Documented; callers choose when to pay it.
- Execution needed NO changes: SwapExecutor's hop loop and exact-out recursion are already N-hop agnostic, and the balance-delta refund accounting from the pre-pilot bundle is unit-correct at any path length.

## Testing

`test/ThreeHop.t.sol` (6 tests, deterministic seeded chain A -> X -> Y -> B with no other liquidity): 2-hop search provably cannot route the pair while the 3-hop search finds the exact chain; superset property against a genuinely competing 2-hop route; bit-for-bit execution parity exact-in; exact-out delivery with exact refund in input-token units and nothing stranded; both slippage bounds enforced on 3-hop paths (TooLittleReceived / V3TooMuchRequested). Full suite: 90 tests passing, 1 conditional skip.

Adversarial review (code-reviewer agent): no confirmed correctness findings (leg composition, sentinel skips, degenerate-path impossibility, and better() branch selection all verified); one vacuous test flagged and rewritten against a real competing route.
