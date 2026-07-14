# Parity gate finishers (draft PR body)

Test-only PR completing the TDD 5.3 parity-gate exit criteria on top of the F8 quoter fix. No `src/` changes.

## Done so far

- **Seeded V4 pool parity** (`test/SeededV4Parity.t.sol`): fresh tokens, our own pool and positions on the live PoolManager at the pinned Base block. Staggered position ranges force deterministic multi-tick crossings; liquidity amounts are fuzzed so boundary rounding is explored across pool shapes (320 fuzz runs). Includes an 18/6-decimal pair and a protocol-fee variant (F8 coverage on a controlled pool shape).
- **Gas-cap sentinel coverage** (`test/GasCapSentinel.t.sol`): a pool with 440 one-tick-wide positions exhausts the quoter's 500k budget. Asserts the quoter returns the sentinels (0 exact-in, uint max exact-out) rather than reverting, and that route selection never lets a sentinel pool win a route in either direction.

- **Seeded V3 pool parity** (`test/SeededV3Parity.t.sol`): fresh tokens and a fresh pool created through the real mainnet factory at the pinned block (no committed 0.7.6 artifacts), multi-tick positions via a minimal mint-callback helper (`test/utils/V3PositionMinter.sol`). 256 fuzz runs of bit-for-bit parity, exact-in and exact-out, over fuzzed liquidity shapes.
- **Hooked-pool policy**: NatSpec on `V4Quoter` (hook-unaware by design; protocol fees and initialized dynamic LP fees ARE covered) and a README section, "Quoting guarantees and limits", documenting the parity guarantee, the hook limitation, the gas-cap sentinels, and exact-output-beyond-depth behavior.

## Status

All TDD 5.3 parity-gate exit criteria that were deferred from v1 are now covered. Together with the F8 fix (previous PR in the stack), the parity gate is complete except for hooked pools, which are excluded by documented design.

Note: `test/utils/MockFactories.sol` provides minimal V2/V3 factory stand-ins so V4-only suites need no real factory deployments.
