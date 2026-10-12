# Gas report and gas limits

Monad charges `gas_limit × gas_price`, not gas used ([docs](https://docs.monad.xyz/developer-essentials/differences)). An over-generous limit is paid in full, so every call our scripts and frontend send carries an explicit, tight limit.

**Method.** `FOUNDRY_ETH_RPC_URL= forge test --gas-report` with `network = "monad"` (Foundry 1.8.5, MonadTen gas model including MIP-8 storage pages). Limit = (max execution gas + 21,000 intrinsic) × ~1.2, rounded up. The limits live in `script/Params.sol` (`GasLimits`) and the frontend uses the same numbers. Contract creations can't take a gas option in Solidity, so the deploy script uses forge's estimate with `--gas-estimate-multiplier 120`.

**Prices** (Oct 12, 2026): base fee 100 gwei (MON) on testnet and mainnet (the protocol minimum); MON = $0.0256 (CoinGecko).

| Call | Max gas used | Gas limit | Cost at limit (MON) | Cost (USD) |
|---|---:|---:|---:|---:|
| `CreditPool.borrowStable` | 285,918 | 370,000 | 0.0370 | $0.00095 |
| `CreditPool.repay` | 196,762 | 265,000 | 0.0265 | $0.00068 |
| `CreditPool.markDefault` (stable) | 273,728 | 355,000 | 0.0355 | $0.00091 |
| `CreditPool.deposit` | 166,343 | 230,000 | 0.0230 | $0.00059 |
| `CreditPool.withdraw` | 99,459 | 145,000 | 0.0145 | $0.00037 |
| `CreditPool.fundReserve` | 107,521 | 155,000 | 0.0155 | $0.00040 |
| `CreditRegistry.submitAttestation` | 85,033 | 130,000 | 0.0130 | $0.00033 |
| `CreditRegistry.setPool` | 51,689 | 90,000 | 0.0090 | $0.00023 |
| `MockUSDC.approve` | 53,027 | 90,000 | 0.0090 | $0.00023 |
| `MockUSDC.mint` | 80,700 | 125,000 | 0.0125 | $0.00032 |
| Native MON transfer | 21,000 | 21,000 | 0.0021 | $0.00005 |

**A full loan cycle** (borrow + repay) costs 0.0635 MON, about **$0.0016** at the gas limits. Interest on a 100 mUSDC, 30-day loan at the 7% base rate is 0.58 mUSDC, so gas is under 0.3% of the interest. That is why small "credit-builder" loans are viable here.

**MON-collateral calls** (`borrowMon`, `liquidate`, `markDefault` on a MON loan) include a Pyth price update that verifies Wormhole signatures. Its cost depends on the update payload, and the mock used in tests (borrowMon max 299,197) understates it. The frontend estimates these calls live (`eth_estimateGas`) and adds 20% instead of using a fixed constant.

Full output: `FOUNDRY_ETH_RPC_URL= forge test --gas-report --no-match-contract 'Invariant|HandlerSmoke|SeedDemo'`.
