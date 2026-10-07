# Project Name

> One-line pitch. TODO

Built for the [Monad Metropolis hackathon](https://hackathon.monad.xyz) (Sept 1 to Oct 13, 2026).
Submission checklist: [docs/rules-checklist.md](docs/rules-checklist.md).

| | |
|---|---|
| Track | TODO (exactly one, see [Track](#track)) |
| Network | Monad Testnet (10143) / Monad Mainnet (143) |
| Demo video | TODO link (3:00 max) |
| Live app | TODO link (optional) |
| License | [MIT](LICENSE) |

## Problem

TODO: who has the problem, what it costs them today, why existing solutions fall short.

## Track

Competing in exactly one track:

- [ ] Onchain Finance & Trading
- [ ] Consumer Products & Payments
- [ ] Social, Attention & Culture
- [ ] Trust, Identity & AI Infrastructure

TODO: one sentence on why the project fits this track.

## How it works

TODO: architecture overview and user flow.

```
user -> app (Next.js + viem) -> contracts on Monad
```

| Component | Path | Description |
|---|---|---|
| Contracts | `src/` | TODO |
| Deploy scripts | `script/` | TODO |
| Tests | `test/` | TODO |
| Frontend | `app/` | Next.js + viem (`monadTestnet`) |

## Why Monad

TODO: what the project needs from Monad specifically, and why it would be worse or impossible on another chain. Back claims with numbers from your own transactions where possible.

- TODO: throughput / ~400 ms blocks / fast finality and what that enables here
- TODO: low fees and what interaction pattern that makes viable
- TODO: full EVM compatibility (same Solidity, Foundry, viem)

## Contracts & tx hashes

Deployment evidence (mainnet or testnet). Broadcast logs for non-local chains are committed under `broadcast/`.

| Contract | Network | Address | Explorer |
|---|---|---|---|
| TODO | Monad Testnet (10143) | `0x...` | [MonadVision](https://testnet.monadvision.com/address/0x...) |

| Action | Network | Tx hash | Explorer |
|---|---|---|---|
| Deploy TODO | Monad Testnet (10143) | `0x...` | [MonadVision](https://testnet.monadvision.com/tx/0x...) |
| TODO key user action | Monad Testnet (10143) | `0x...` | [MonadVision](https://testnet.monadvision.com/tx/0x...) |

Verified source: TODO (yes/no, explorer link).

## Run locally

### Prerequisites

- **Foundry v1.8.0 or later** (official release, which includes native Monad support). The legacy `category-labs` Monad Foundry fork stops at the `MonadNine` hardfork and is not supported.
  ```shell
  curl -L https://foundry.paradigm.xyz | bash
  foundryup
  ./scripts/check-foundry.sh   # fails if forge is older than 1.8.0 or is the legacy fork
  ```
- Node.js 20.9 or later (22 LTS recommended) and npm
- Testnet MON from the [faucet](https://testnet.monad.xyz)

### Contracts

`foundry.toml` sets `network = "monad"`, so local tests and scripts run with Monad's gas model, opcode pricing, precompiles and 128 KB contract size limit. The default profile targets Monad Testnet; the `mainnet` profile targets Monad Mainnet.

```shell
git clone --recurse-submodules <this repo>
cd <repo>
cp .env.example .env

forge build
forge test                       # forks live Monad Testnet (eth-rpc-url in foundry.toml)
FOUNDRY_ETH_RPC_URL= forge test  # local Monad EVM, no RPC: fast, works offline (what CI runs)
```

Deploy with an encrypted keystore (never a raw private key):

```shell
cast wallet import monad-deployer --interactive   # name must match ETH_KEYSTORE_ACCOUNT in .env
cast wallet address --account monad-deployer      # fund this address from the faucet

# Monad Testnet (default profile)
forge script script/<Script>.s.sol --broadcast

# Monad Mainnet
FOUNDRY_PROFILE=mainnet forge script script/<Script>.s.sol --broadcast
```

Verify on MonadVision (Sourcify, no API key):

```shell
forge verify-contract <address> <ContractName> \
  --chain 10143 \
  --verifier sourcify \
  --verifier-url https://sourcify-api-monad.blockvision.org/
# mainnet: --chain 143
```

### Frontend

```shell
cd app
cp .env.example .env.local
npm install
npm run dev   # http://localhost:3000
```

## Demo video

TODO: link (YouTube / Loom / Vimeo, public, **3:00 max**) showing the working product making real Monad transactions.

## AI tools used

This project was built with AI coding assistance, disclosed as required by the hackathon rules.

| Tool | Used for |
|---|---|
| [Claude Code](https://claude.com/claude-code) (Anthropic) | Repository scaffolding (Foundry config, Next.js setup, README and checklist skeletons). TODO: list further uses, e.g. contract drafting, tests, frontend, debugging. |

## Built during the hackathon (Sept 1 to Oct 13)

All project code was written during the Monad Metropolis build window, Sept 1 to Oct 13, 2026 (deadline Oct 13, 11:59 PM ET). The git history is the record.

Pre-existing code used as a foundation (not original work):

| Source | What | License |
|---|---|---|
| [monad-developers/foundry-monad](https://github.com/monad-developers/foundry-monad) | Foundry template: config, `Counter` example, CI (imported unchanged in the first commit) | No license file |
| [foundry-rs/forge-std](https://github.com/foundry-rs/forge-std) | Test and script library (`lib/`) | MIT / Apache-2.0 |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | Contract library (`lib/`) | MIT |
| [create-next-app](https://nextjs.org/docs/app/api-reference/cli/create-next-app) | Next.js boilerplate in `app/` | MIT |

## License

[MIT](LICENSE)
