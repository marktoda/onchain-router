# Onchain Router

Finds and executes optimal swap paths across Uniswap V2, V3, and V4 pools entirely onchain.

## How it works

```
User: swapExactInput(USDC -> WBTC, 1000 USDC)

1. DISCOVER  PathGenerator finds all pools for each hop:
             USDC/WETH: V2 pool, V3 pools (4 fee tiers), V4 pools (4 default configs + leaderboard)
             WETH/WBTC: same search

2. QUOTE     Each pool is simulated via tick-by-tick math (V3/V4) or reserves (V2).
             Best single-hop and multi-hop routes are compared.

3. EXECUTE   Winner executes: V2 via pair.swap(), V3 via pool.swap(),
             V4 via poolManager.unlock() → swap() → settle/take.
```

## Architecture

```
OnchainRouterImmutables          Shared immutables: v2Factory, v3Factory, poolManager, intermediateToken
    ├── V4PoolRegistry           V4 pool discovery: default configs + per-pair leaderboard (max 8)
    │   └── PathGenerator        Discovers all V2/V3/V4 pools for a token pair
    ├── SwapExecutor             Executes swaps across V2/V3/V4 (implements IUnlockCallback)
    ├── V2Quoter                 Simulates V2 swaps via reserve math
    ├── V3Quoter                 Simulates V3 swaps via tick-by-tick traversal
    └── V4Quoter                 Simulates V4 swaps via StateLibrary (extsload)
            │
            └── OnchainRouter    Entry point: routing + execution + ETH wrapping
```

### V4 Pool Discovery

V4 pools are identified by `PoolKey(currency0, currency1, fee, tickSpacing, hooks)` — 5 dimensions with no registry. The router uses two discovery mechanisms:

- **Default configs**: standard `(fee, tickSpacing)` combos `(100,1), (500,10), (3000,60), (10000,200)` with `hooks=address(0)`, checked for every pair
- **Leaderboard**: max 8 registered pools per pair with win-counter scoring. Anyone can register pools via `registerV4Pool()`. When full, challengers must have more liquidity than the lowest-scored incumbent.

### Native ETH in V4

V4 pools can use `Currency.wrap(address(0))` (native ETH) instead of WETH. The router handles this transparently:

- **Discovery**: when `intermediateToken` (WETH) is one of the tokens, the registry also checks for `address(0)` variants
- **Execution**: WETH is unwrapped to ETH before V4 native ETH settlement, and ETH is wrapped back to WETH after V4 native ETH output when needed for subsequent V2/V3 hops
- **Entry point**: `_resolveUserToken()` maps `address(0)` back to WETH for user-facing `transferFrom`/refund

### V4 Swap Execution

If any hop in the path is V4, the entire execution is wrapped in `poolManager.unlock()`:

```
poolManager.unlock(data)
  └── unlockCallback(data)
        ├── V2 hop: transfer tokens → pair.swap()
        ├── V3 hop: pool.swap() → uniswapV3SwapCallback → transfer tokens
        └── V4 hop: poolManager.swap() → settle(input) → take(output)
```

V2/V3 hops work normally inside the unlock callback — they don't interact with V4's accounting.

## Deployments

| Chain | OnchainRouter |
|-------|---------------|
| Base | [`0xCa7a19BD1E260DCd92B17DdAc068C2bF67539a02`](https://basescan.org/address/0xCa7a19BD1E260DCd92B17DdAc068C2bF67539a02) |
| Ethereum | [`0x362cC8306b42475DA640C4841E90630A79B9A6eE`](https://etherscan.io/address/0x362cC8306b42475DA640C4841E90630A79B9A6eE) |

### Registering V4 Pools

Non-default V4 pools can be registered to the leaderboard via `RegisterV4Pool`:

```bash
ROUTER=0xCa7a19BD1E260DCd92B17DdAc068C2bF67539a02 \
TOKEN_A=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
TOKEN_B=0xa53887F7e7c1bf5010b8627F1C1ba94fE7a5d6E0 \
FEE=10000 TICK_SPACING=100 \
forge script script/RegisterV4Pool.s.sol --broadcast --rpc-url $BASE_RPC_URL
```

## Usage

```solidity
// 1. Get a quote
SwapParams memory params = SwapParams({
    tokenIn: USDC,
    tokenOut: WETH,
    amountSpecified: 1000e6
});
Quote memory quote = router.routeExactInput(params);

// 2. Execute (ERC20 input)
USDC.approve(address(router), quote.amountIn);
uint256 amountOut = router.swapExactInput(quote, recipient, deadline, false);

// 2b. Execute (ETH input, unwrap output to ETH)
uint256 amountOut = router.swapExactInput{value: msg.value}(quote, recipient, deadline, true);
```

## Testing

```bash
# V2/V3 tests (Ethereum mainnet fork)
MAINNET_RPC_URL=... forge test --match-contract "RouterForkTest|SwapExecutionForkTest"

# V4 tests (Base fork)
BASE_RPC_URL=... forge test --match-contract V4BaseForkTest

# V4 leaderboard unit tests (no fork needed)
forge test --match-contract V4LeaderboardTest

# All tests
MAINNET_RPC_URL=... BASE_RPC_URL=... forge test
```

## License

GPL-2.0-or-later

## Quoting guarantees and limits

The view quoters are held to bit-for-bit parity with execution on V2, V3, and V4 core pool math (see `test/QuoteSwapParity.t.sol`, `test/SeededV3Parity.t.sol`, `test/SeededV4Parity.t.sol`): what `routeExact*` quotes is exactly what `swapExact*` delivers in the same state. V4 protocol fees are included and covered by tests; dynamic-fee pools quote against their live slot0 fee by construction (a dedicated dynamic-fee parity test is a tracked follow-up).

Known limits integrators should design around:

- **Hooked V4 pools are quoted hook-unaware.** Hooks that change amounts (beforeSwap deltas, LP-fee overrides, custom curves) will quote differently than they execute; under the exact-bound design those swaps revert instead of settling at an unquoted price. Supply explicit bounds when routing hooked pools.
- **Quoter gas budget.** Each pool quote runs under a 500k gas cap. A pool too tick-dense to quote within budget returns a sentinel (0 for exact-in, `type(uint256).max` for exact-out). A sentinel pool never beats a healthy candidate in single-hop route selection, but when it is the only candidate the returned quote still carries its path together with the sentinel amounts — gate on `amountOut == 0` / `amountIn == type(uint256).max` before executing, not on `path.length` (executing such an exact-in quote via the 4-arg `swapExactInput` would run with a zero minimum-output bound). See `test/GasCapSentinel.t.sol`. In multihop exact-output the sentinel is short-circuited so it cannot become a wrapped winning quote (see `test/MultihopSentinel.t.sol`).
- **Exact-output beyond pool depth** is unroutable by quote: the quoters' full-fill checks surface the `type(uint256).max` sentinel instead of a partial-fill quote; treat `type(uint256).max` as unroutable.
