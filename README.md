# Monadic

> Undercollateralised loans priced on your onchain repayment history.

Built for the [Monad Metropolis hackathon](https://hackathon.monad.xyz) (Sept 1 to Oct 13, 2026).
Spec: [docs/spec.md](docs/spec.md) · Security notes: [docs/security-notes.md](docs/security-notes.md) · Gas: [docs/gas-report.md](docs/gas-report.md)

| | |
|---|---|
| Track | Onchain Finance & Trading |
| Network | Monad Testnet (10143) |
| Live app | [monadic-test11-17fe.vercel.app](https://monadic-test11-17fe.vercel.app) |
| License | [MIT](LICENSE) |

## Problem

DeFi lending only works for people who already have money. Every major market asks for 120–150% collateral, so a borrower who has repaid a hundred loans gets exactly the same terms as a wallet created five minutes ago. Repayment history is public onchain, but nothing prices it. The result is that onchain credit is a leverage tool for the wealthy rather than a way to reach capital you don't already hold.

Lenders face the mirror image of this problem. Undercollateralised protocols that do exist rely on offchain underwriting, KYC, or whitelisted borrowers, and lenders can't see or verify how a loan was priced.

## Track

Competing in exactly one track:

- [x] Onchain Finance & Trading
- [ ] Consumer Products & Payments
- [ ] Social, Attention & Culture
- [ ] Trust, Identity & AI Infrastructure

It's a lending market: a pool of lenders, loans priced by risk, and a transparent default waterfall, with credit risk modelled entirely from onchain data.

## How it works

Borrowers start fully collateralised. Every loan repaid on time lowers their estimated probability of default (PD). That cuts the collateral they must post, sets their rate, and raises their limit. The model ([spec §2](docs/spec.md#2-credit-model)) fits on one slide:

| | |
|---|---|
| History | E = Σ over on-time loans of min(1, principal × time held / (100 mUSDC × 30 days)); a loan repaid after at least ¾ of its term counts as held for all of it |
| Default probability | PD = (b + ½·(late + liquidations)) / (a + g·wallet-age + E + b + ½·(late + liquidations)): the mean of a Beta prior updated by your history |
| Score | 1000 × (1 − PD) |
| Collateral ratio | 100% until one full loan is repaid, then linear in PD, down to a 25% floor |
| APR | pool rate (2% + 10% × utilisation, paid to lenders) + PD × (1 − collateral) per term (the fair premium for the unsecured share, paid into a first-loss reserve) |
| Limit | 100 mUSDC + 0.5 × time-weighted principal repaid on time, max 5,000 |

Lenders deposit mUSDC into an ERC-4626 vault and earn the pool rate. Risk premiums go to a first-loss reserve. Total unsecured credit can never exceed the reserve (k = 1), so lender principal is covered even if every unsecured loan defaults at once. If a borrower misses the due date plus a 3-day grace period, anyone can mark the loan defaulted. Losses are absorbed by the collateral first, then the reserve, then lenders, and the address is barred for good. Wallet age and liquidations on other protocols, which no contract can read, arrive as EIP-712 attestations with a capped influence. MON can also be used as collateral, priced by Pyth at a 20% haircut and converted to stablecoin if it falls.

```
lender ──deposit──▶ CreditPool (ERC-4626) ◀──borrow / repay── borrower ◀── app (Next.js + viem)
                        │   ▲                                   │
           terms, history   │ premiums → first-loss reserve     │ MON price (Pyth pull update)
                        ▼   │                                   ▼
                  CreditRegistry ◀── EIP-712 wallet-age attestation        MonPriceOracle
```

| Component | Path | What it does |
|---|---|---|
| `CreditRegistry` | [`src/CreditRegistry.sol`](src/CreditRegistry.sol) | Credit history, score, collateral ratio, premium and limit; verifies attestations |
| `CreditPool` | [`src/CreditPool.sol`](src/CreditPool.sol) | ERC-4626 lender vault, loans, interest, reserve, default waterfall, MON liquidation |
| `MonPriceOracle` | [`src/MonPriceOracle.sol`](src/MonPriceOracle.sol) | Pyth MON/USD pull-oracle adapter (max age 60 s, confidence ≤ 2%) |
| `MockUSDC` | [`src/MockUSDC.sol`](src/MockUSDC.sol) | Testnet stablecoin with a capped faucet |
| Scripts | [`script/`](script), [`scripts/`](scripts) | Deploy and demo seeding with explicit gas limits; address and tx-hash collection |
| Tests | [`test/`](test) | 74 unit, fuzz and invariant tests ([summary](#tests)) |
| App | [`app/`](app) | Three screens: your score and why → borrow within your limit → repay and watch your terms change |

## Why Monad

Numbers from our own measurements and tests, Oct 12, 2026:

- **Interest and scores update every 0.3 s.** We measured a 0.302 s average block time over the last 100,000 blocks on Monad Testnet and Mainnet, with 600 ms finality per the docs. Debts accrue per second, the lender share price moves every block, and a repayment updates the borrower's score in the same transaction. Better terms are usable in the next block, with no epochs or batch scoring jobs.
- **Small "credit-builder" loans are economical.** At our explicit gas limits, a borrow costs 0.037 MON and a repay 0.0265 MON at the 100 gwei base fee. A full loan cycle comes to about $0.0016, under 0.3% of the interest on a 100 mUSDC, 30-day loan (details in [docs/gas-report.md](docs/gas-report.md)). Building history with small, frequent loans only makes sense when gas is a rounding error.
- **The pool contract needs Monad's code size.** `CreditPool` compiles to 27.5 KB, over Ethereum's 24 KB limit and well inside Monad's 128 KB, so the full lending logic ships as one contract without proxies.
- **Liquidation latency comes from the oracle, not the chain.** The MON haircut a lender needs scales with σ√Δt of liquidation delay. With 0.3 s blocks, Pyth updates and keeper speed are the limiting factor.
- **Full EVM tooling.** The same Solidity, OpenZeppelin, Foundry 1.8 (with `network = "monad"`, so tests run under Monad's gas model) and viem.

Monad-specific details we designed around:
- **Gas is charged on the limit, not on gas used.** Every call carries a measured limit plus about 20% headroom.
- **Timestamps have 1-second resolution, about 3 blocks per second.** That's why we accrue interest per second rather than per block.

## Contracts & tx hashes

Monad Testnet (chain 10143). Generated by `scripts/collect-deployment.mjs` from forge's broadcast logs (committed under `broadcast/`). The full machine-readable list is in [`deployments/testnet.json`](deployments/testnet.json). Source is verified on Sourcify, so contract pages on MonadVision show it.

<!-- deployment:start -->
| Contract | Address |
|---|---|
| CreditPool | [`0x3462118Be4c5d89576ED1219100E2AfdDcF1ad6A`](https://testnet.monadvision.com/address/0x3462118Be4c5d89576ED1219100E2AfdDcF1ad6A) |
| CreditRegistry | [`0xb71c3cD30a325aD98822D1d0949AA93b3E13D75F`](https://testnet.monadvision.com/address/0xb71c3cD30a325aD98822D1d0949AA93b3E13D75F) |
| MonPriceOracle | [`0x2570A9fad7151DeA8DC968aaF0689b67b46262b8`](https://testnet.monadvision.com/address/0x2570A9fad7151DeA8DC968aaF0689b67b46262b8) |
| MockUSDC | [`0x77354D89Bb4b1B2455957C8097995f2C3DA7F758`](https://testnet.monadvision.com/address/0x77354D89Bb4b1B2455957C8097995f2C3DA7F758) |

| # | Step | By | Action | Tx hash |
|---|---|---|---|---|
| 1 | deploy | deployer | deploy MockUSDC | [0x58dc3491…c2c163](https://testnet.monadvision.com/tx/0x58dc3491a8d27cca39d00fceb5f0f026aef9ef6016378e171b327a2fdbc2c163) |
| 2 | deploy | deployer | deploy CreditRegistry | [0xdc65ba28…ffca23](https://testnet.monadvision.com/tx/0xdc65ba28215422351edaa4628ba299a8b9b2f3ae2b347814a7dd971120ffca23) |
| 3 | deploy | deployer | deploy MonPriceOracle | [0xbac6b96c…c12460](https://testnet.monadvision.com/tx/0xbac6b96ca439fbde8e89e4a56950eb3426324411ab39c95b3fd73c2bd1c12460) |
| 4 | deploy | deployer | deploy CreditPool | [0xc8a9ab7f…fac4d2](https://testnet.monadvision.com/tx/0xc8a9ab7f51950d8a5c6a514bed0183955a2b70f50840a92c7e75747144fac4d2) |
| 5 | deploy | deployer | CreditRegistry.setPool | [0x0098afd7…364b27](https://testnet.monadvision.com/tx/0x0098afd7871cb8fea64bd2bda4839fb1e8057b0a9c626012bc2525e712364b27) |
| 6 | deploy | deployer | MockUSDC.mint | [0x6aad5837…8ac12b](https://testnet.monadvision.com/tx/0x6aad58375bb34bdd7a75d13ab5cb0bf2cdf68d0a8545aa6de72d736c148ac12b) |
| 7 | deploy | deployer | MockUSDC.approve | [0xfa959b42…cc5815](https://testnet.monadvision.com/tx/0xfa959b42c0a83f95246510ed2a2a6373b65b77bfdddb7097ca62c9213ecc5815) |
| 8 | deploy | deployer | CreditPool.fundReserve | [0x8e731d12…e2e6bd](https://testnet.monadvision.com/tx/0x8e731d1255325b0b86e9de6c386557462911f5140a164ead0143855118e2e6bd) |
| 9 | deploy | deployer | CreditPool.deposit | [0x6c150f81…2c8bee](https://testnet.monadvision.com/tx/0x6c150f81764730d8a6780a036ba1b251fd2b4455b45c2364bb341331912c8bee) |
<!-- deployment:end -->

## Run locally

### Prerequisites

- **Foundry v1.8.0 or later** (the official release, which includes native Monad support). The legacy `category-labs` Monad Foundry fork stops at the `MonadNine` hardfork and isn't supported.
  ```shell
  curl -L https://foundry.paradigm.xyz | bash
  foundryup
  ./scripts/check-foundry.sh   # fails if forge is older than 1.8.0 or is the legacy fork
  ```
- Node.js 20.9 or later (22 LTS recommended) and npm
- Testnet MON from the [faucet](https://testnet.monad.xyz); deploying and seeding needs about 3 MON

### Contracts

`foundry.toml` sets `network = "monad"`, so local tests and scripts run with Monad's gas model, opcode pricing, precompiles and 128 KB contract size limit.

```shell
git clone --recurse-submodules https://github.com/feedddosever/monad
cd monad
FOUNDRY_ETH_RPC_URL= forge test             # local Monad EVM, what CI runs
FOUNDRY_ETH_RPC_URL= forge test --gas-report
```

### Deploy and seed the demo (Monad Testnet)

```shell
cp .env.example .env                 # set PRIVATE_KEY to a funded, testnet-only key (or export it)
scripts/deploy-testnet.sh            # deploy, verify on Sourcify, write deployments/testnet.json + README table
scripts/seed-demo.sh                 # optional, ~3-4 min: good payer, new wallet, late payer
```

The demo clock runs at `TIME_SCALE = 43,200` (1 s = 12 h), so a 30-day loan lasts 60 s. Deploy with `TIME_SCALE=1` for real time.

To rehearse on a local fork instead, start `anvil --fork-url https://testnet-rpc.monad.xyz --block-time 1` and prefix the `forge script` commands with `FOUNDRY_CHAIN_ID=31337`. `foundry.toml` pins `chain_id = 10143`, which also sets `block.chainid` in scripts, so without the override a local run would write to the testnet deployment files.

### App

```shell
cd app
npm install
npm run dev                          # http://localhost:3000
```

The app reads contract addresses from `app/src/lib/deployment.json`, which the deploy script writes. It uses viem's `monadTestnet` chain and offers to switch your wallet to it.

### Tests

74 tests: unit tests for every external function, fuzz tests that check score → collateral, rate and limit against the spec formulas, and an invariant campaign (128 runs × 100 random calls, `fail_on_revert`). The invariants check that stablecoin books balance, that debt is funded only by lender capital (never the reserve or collateral), that no open loan exceeds its limit, that on-time repayments never lower a score, and that lender share price never falls while the reserve covers defaults. Static analysis (slither 0.11.6): every high and medium finding is fixed or justified in [docs/security-notes.md](docs/security-notes.md).

## Demo video

The demo video (2:48) and pitch video (1:15) are linked from the project's Metropolis submission. Both are narrated by a synthetic voice (Piper TTS). You can also try the live app yourself: **https://monadic-test11-17fe.vercel.app** (Monad Testnet; bring your own wallet with a little testnet MON).

The demo video is generated from the live app by [`video/`](video): narrated slides, then a fresh wallet connecting, borrowing, waiting for full history credit, repaying and watching its terms change, then the seeded profiles. See [video/README.md](video/README.md) to re-record it on Monad Testnet. A shot list for recording by hand is in [docs/demo-script.md](docs/demo-script.md).

## AI tools used

This project was built with AI coding assistance, disclosed as the hackathon rules require.

| Tool | Used for |
|---|---|
| [Claude Code](https://claude.com/claude-code) (Anthropic) | Most of the code and docs in this repository, written from the author's instructions: repository scaffolding (Foundry, Next.js, CI); the spec, built around design decisions the author made (track, both collateral types, signed wallet-age attestations, bounded loss with a first-loss reserve, one pool with fixed-term loans); the Solidity contracts, tests, fuzz and invariant suites; the deploy and seed scripts; the gas report and slither triage; the frontend; the submission docs; and the demo-video tooling and narration script. |
| [Piper](https://github.com/rhasspy/piper) (open-source TTS, run locally) | The synthetic narration voice in the demo video |

## Built during the hackathon (Sept 1 to Oct 13)

All project code was written during the Monad Metropolis build window. The first commit in this repository is from Oct 7, 2026, and the git history is the record.

Pre-existing code used as a foundation (not original work):

| Source | What | License |
|---|---|---|
| [monad-developers/foundry-monad](https://github.com/monad-developers/foundry-monad) | Foundry template: config, `Counter` example, CI (imported unchanged in the first commit, later replaced) | No license file |
| [foundry-rs/forge-std](https://github.com/foundry-rs/forge-std) | Test and script library (`lib/`) | MIT / Apache-2.0 |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | ERC-20, ERC-4626, Ownable2Step, ReentrancyGuard, EIP-712, math (`lib/`) | MIT |
| [create-next-app](https://nextjs.org/docs/app/api-reference/cli/create-next-app) | Next.js boilerplate in `app/` | MIT |
| [viem](https://viem.sh) | Chain client in `app/` | MIT |

## License

[MIT](LICENSE)
