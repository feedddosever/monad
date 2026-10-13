# Metropolis submission

Copy-ready text for the hackathon form, field by field. Track: **Onchain Finance & Trading**.

## Project details

**Name** (120)

Monadic

**Tagline** (200)

Undercollateralised loans priced on your onchain repayment history.

**Logo:** [`docs/logo.png`](logo.png), a 1000 × 1000 PNG (522 KB).

**Describe the problem, your solution, and what makes it useful** (8,000)

```text
The problem
Onchain lending only works if you already have money. Every major market asks for 120-150% collateral, from everyone. A borrower who has repaid a hundred loans gets exactly the same terms as a wallet created five minutes ago. Repayment history is public onchain, but nothing prices it. The few undercollateralised protocols that exist rely on offchain underwriting, KYC or whitelists, so lenders can't see or verify how a loan was priced.

The solution
Monadic is a lending pool on Monad where every loan you repay on time improves your terms, priced entirely from onchain data.

- Credit model. Your probability of default (PD) is a Bayesian estimate: a cautious prior, updated by every loan you repay on time in the protocol and by any late repayment or liquidation. Wallet age and liquidations on other protocols arrive as signed EIP-712 attestations with a capped influence. Score = 1000 x (1 - PD). Everyone starts at 800.
- The score sets three terms, transparently. Collateral: 100% until you have one full loan of history, then falling with PD to a 25% floor. Rate: the pool rate (2% + 10% x utilisation, paid to lenders) plus a risk premium equal to PD x the unsecured share per loan, which is the fair price of the collateral you didn't post. Limit: 100 mUSDC plus half of the principal you've repaid on time, up to 5,000.
- History is time-weighted. Instant borrow-and-repay loops earn nothing; a loan held for at least 3/4 of its term counts in full. Each loan earns at most one unit, and an address can have one open loan at a time.
- Lenders deposit into an ERC-4626 vault and earn the pool rate. Risk premiums fund a first-loss reserve, and total unsecured credit can never exceed it. If a borrower misses the due date plus 3 days of grace, anyone can mark the loan defaulted. Collateral pays first, then the reserve, and only then lenders, and the address is barred for good.
- MON can also be used as collateral in the contracts, priced by Pyth at a 20% haircut and converted to stablecoin if it falls.

What a borrower sees
Connect a wallet and the app shows your score and why, in plain language, along with your limit, collateral ratio and cost per loan. Borrow within your limit, watch interest accrue every second, and repay. In the demo a brand-new wallet repays its first 100 mUSDC loan on time: score 800 -> 888, collateral 100% -> 67%, limit 100 -> 150, all in the same transaction. A seeded wallet with three on-time loans sits at 941 with 47% collateral; one with a single late payment sits at 571, fully secured again.

Why Monad
- 0.3 s blocks (we measured a 0.302 s average over 100,000 blocks). Debts accrue per second, the lender share price moves continuously, and a repayment updates the score in the same transaction, with no epochs or offchain scoring jobs.
- Cheap execution. At our explicit gas limits (Monad charges the limit, so every call carries a measured limit plus ~20%), a full borrow-and-repay cycle costs about $0.0016. Small, frequent credit-building loans only make sense when gas is a rounding error.
- Code size. The whole lending pool is one 27.5 KB contract: over Ethereum's 24 KB limit, inside Monad's 128 KB.

What makes it useful
- Borrowers get a path from fully collateralised to undercollateralised credit that is earned, portable and public. No KYC, no offchain underwriter.
- Lenders can audit exactly how every loan was priced, and are protected by collateral plus a first-loss reserve funded by the borrowers who take the risk.
- Other Monad protocols can read the score straight from the registry contract.

Engineering
Solidity 0.8.24 with OpenZeppelin and Foundry 1.8 (network = "monad"). 74 tests, including fuzz tests of the score-to-terms mapping and an invariant campaign (128 runs x 100 random calls) checking that books balance, debt is funded only by lender capital, no loan exceeds its limit, on-time repayments never lower a score, and lender share price never falls while the reserve covers defaults. Every slither high and medium finding is fixed or justified. Next.js + viem frontend. Built with Claude Code, disclosed in the README.
```

**Who are your first users, and how will you reach them?** (8,000)

```text
First users
1. Active Monad users ("nads") who already transact onchain and want to borrow stablecoins without locking up 150% of the loan. They are the people with the most onchain history to build on.
2. Small borrowers who want to build credit from scratch. A fully collateralised first loan costs only the pool rate and about $0.0016 in gas, so building a track record with small loans is cheap. Each on-time loan visibly lowers the collateral needed next time.
3. Stablecoin lenders who want yield with transparent risk: every loan's pricing is onchain, and a first-loss reserve funded by risk premiums sits between them and defaults.
4. Monad protocols that want a credit signal. The score lives in a public registry contract any app can read.

How we will reach them
- Monad community first. Launch on testnet with a "build your score" campaign: borrow and repay small loans on time and watch your collateral fall. Share it on X and in Monad community channels, and with Monad ecosystem projects and wallets.
- A score page anyone can open for their own wallet, to share and compare.
- Seed the lender side ourselves and invite early LPs, with the first-loss reserve as the pitch. Grow limits gradually as the reserve grows, since total unsecured credit is capped by it.
- Integrations: show the score in partner apps and wallets, and add attestations for wallet age and liquidations on other Monad protocols, so good history elsewhere counts on day one.
- Mainnet after an audit, starting with small limits.
```

**GitHub**

https://github.com/feedddosever/monad

## Demo and pitch

**Product link** (must run on Monad Mainnet or Testnet): TODO, the hosted app URL once the testnet deploy is done.

**Demo video** (up to 3 min): TODO, a public YouTube/Loom link. The video is generated by `video/` (see `video/README.md`) and is 2:49 long.

**Pitch video** (up to 2 min): TODO, record yourself (Loom works) using this script, about 75 s:

```text
Hi, I'm [your name], and I built Monadic for Monad Metropolis.
Onchain lending only works if you're already rich. Every market asks for 150% collateral, so someone who has repaid a hundred loans gets the same terms as a brand-new wallet. Repayment history is public. Nobody prices it.
Monadic does. Every loan you repay on time updates an onchain credit score, and that score sets how much collateral you post, what you pay, and how much you can borrow. Start fully collateralised; repay on time and your collateral falls, all the way to 25%. Lenders earn the pool rate, protected by collateral and a first-loss reserve funded by risk premiums.
I'm building it on Monad because a credit market should update every block. Interest accrues every second, a repayment changes your terms in the same transaction, and a full borrow-and-repay costs a fraction of a cent.
I'm an economist and a Solidity developer, and I built this solo during the hackathon. Next: wallet-age attestations, MON collateral live with Pyth, and a mainnet launch with small limits. Your history is your collateral.
```

**Steps to try the product** (private to judges; 8,000)

```text
No login needed. You need a browser wallet (MetaMask, Rabby or similar) and a little Monad Testnet MON for gas (faucet: https://testnet.monad.xyz).

1. Open the product link and click "Connect wallet". If your wallet is on another network, click "Switch to Monad Testnet" (the app adds the network if needed).
2. You'll see your score (800 for a new wallet) and why, plus your limit, collateral and cost per loan.
3. Click Borrow. If you have no test stablecoin, click "Get 1,000 test mUSDC" (a free mock stablecoin), then "Approve & borrow" up to your limit (100 mUSDC for a new wallet). A first loan is fully collateralised.
4. Demo clock: 1 second = 12 hours, so the 30-day loan lasts 60 seconds. Wait until the loan screen says "Full history credit" (after 45 s), then click "Approve & repay" before 60 s have passed.
5. The app shows what changed: score 800 -> 888, collateral 100% -> 67%, limit 100 -> 150. Borrow again to see the better terms.

Each transaction shows its hash with a link to MonadVision. Contract addresses, the seeded demo wallets (good payer 941, late payer 571) and every deployment and seed transaction are in the README under "Contracts & tx hashes". Any score can be read on MonadVision via CreditRegistry.score(address).
```

**Bounties:** none (optional).
