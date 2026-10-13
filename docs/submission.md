# Metropolis submission profile

**Project name:** Monadic

**Track:** Onchain Finance & Trading

**One-line pitch:** Undercollateralised loans priced on your onchain repayment history: every loan you repay on time cuts your collateral and your rate.

**Description (≤150 words):**

DeFi lending demands 150% collateral from everyone, so a borrower with a perfect repayment record gets the same terms as a wallet created five minutes ago. Monadic prices that history. Each on-time repayment updates an onchain credit score: a Bayesian estimate of default probability built from repayments, late payments, liquidations and attested wallet age. The score sets three things transparently: how much collateral you post (100% for a first loan, down to 25%), your rate (the pool rate plus an actuarially fair premium for the unsecured share) and your credit limit. Lenders deposit into an ERC-4626 vault and earn the pool rate. Risk premiums fund a first-loss reserve that caps total unsecured credit, so a default hits collateral, then the reserve, before lenders. Monad's 0.3-second blocks make debts and scores live, and a full borrow-and-repay cycle costs about $0.0016 in gas, which makes small credit-building loans practical.


**Links:**
- Repo: https://github.com/feedddosever/monad
- Demo video: TODO (author)
- Contracts and tx hashes: README → "Contracts & tx hashes" and `deployments/testnet.json`
