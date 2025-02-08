# Onchain Router

A gas-optimized smart contract router for finding optimal swap paths across Uniswap V2 and V3 pools.

## Overview

The Onchain Router is a smart contract system that:
- Finds the most efficient swap paths across Uniswap V2 and V3 liquidity pools
- Supports both exact input and exact output swaps
- Handles single-hop and multi-hop trades
- Optimizes for gas usage by doing path finding onchain
- Supports all fee tiers in Uniswap V3 (0.01%, 0.05%, 0.3%, 1%)

## Architecture

The system consists of several key components:

### Core Contracts

- `OnchainRouter.sol`: Main router contract that coordinates path finding and execution
- `V3Quoter.sol`: Handles quoting and simulation of V3 pool swaps
- `V2Quoter.sol`: Handles quoting and simulation of V2 pool swaps

### Libraries

- `QuoterMath.sol`: Core math for computing swap amounts and prices
- `PoolTickBitmap.sol`: Efficient tick bitmap operations for V3 pools
- `PoolAddress.sol`: Computing pool addresses deterministically

## Features

- **Optimal Path Finding**: Automatically finds the best path for trades across both V2 and V3 pools
- **Gas Efficiency**: Performs all routing logic onchain without external oracle dependencies
- **Multi-Pool Support**: Can route through multiple pools to achieve better pricing
- **Fee Tier Optimization**: Automatically selects the most efficient fee tier for V3 swaps
- **Exact Output Swaps**: Supports specifying exact output amounts for trades
- **Slippage Protection**: Built-in slippage checks and limits

## Installation

```bash
forge install
```

## Testing

The project includes both unit tests and fork tests:

```bash
# Run all tests
forge test

# Run with verbosity for debugging
forge test -vvv

# Run fork tests (requires MAINNET_RPC_URL)
forge test --fork-url $MAINNET_RPC_URL
```

### Test Coverage

- Unit tests cover core routing logic and edge cases
- Fork tests verify behavior against mainnet pools
- Tests include both exact input and exact output scenarios
- Coverage for different token decimals and fee tiers

## Usage

### Basic Swap Example

```solidity
// Create swap parameters
SwapParams memory params = SwapParams({
    tokenIn: USDC,
    tokenOut: WETH,
    amountSpecified: 1000e6 // 1000 USDC
});

// Get quote for swap
Quote memory quote = router.routeExactInput(params);

// Execute swap (implementation depends on your needs)
router.executeSwap(quote);
```

### Advanced Usage

```solidity
// Example with custom fee tiers
router.addNewFeeTier(100); // Add 0.01% fee tier

// Multi-hop example
SwapParams memory params = SwapParams({
    tokenIn: USDC,
    tokenOut: WBTC,
    amountSpecified: 1000e6
});

Quote memory quote = router.routeExactInput(params);
// Quote will contain optimal path through multiple pools
```

## Security Considerations

- All math operations use safe math to prevent overflows
- Slippage protection built into core swap functions
- Gas limits on quote computation to prevent DOS
- Reentrancy protection on state-modifying functions

## Contributing

Contributions are welcome! Please check out our [Contributing Guide](CONTRIBUTING.md).

## License

GPL-2.0-or-later

## Acknowledgments

Built with:
- [Foundry](https://github.com/foundry-rs/foundry)
- [Uniswap V2](https://github.com/Uniswap/v2-core)
- [Uniswap V3](https://github.com/Uniswap/v3-core)
