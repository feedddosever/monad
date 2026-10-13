# Security notes

Hackathon code: unaudited, testnet only. This file records the static-analysis results and the trust assumptions.

## Slither

`slither . --exclude-dependencies --filter-paths "lib/|test/|script/" --exclude-informational --exclude-optimization` (slither 0.11.6, Oct 12, 2026). Every high and medium finding is below with what we did about it.

| # | Severity | Detector | Location | Resolution |
|---|---|---|---|---|
| H1 | High | arbitrary-send-eth | `CreditPool._sendMon` | **Justified.** MON is only ever sent to (a) the borrower, returning their own collateral on `repay`, or (b) `msg.sender` of `liquidate`/`markDefault`, who has just paid the oracle price minus the bonus for exactly that MON in the same transaction. No caller can direct MON to an address of their choosing beyond these. |
| H2 | High | reentrancy-eth | `CreditPool.liquidate` | **Justified.** The only external call before state writes is `oracle.updateAndRead`, which is needed to compute the effects. The oracle is an immutable address set at deployment (our `MonPriceOracle`, which calls Pyth). Every state-changing pool function is `nonReentrant`, so a call back into the pool reverts. Views called back mid-call (`loans`, `debtOf`) see consistent pre-call state, because nothing has been written yet. Token and MON transfers happen after all effects. |
| H3 | High | reentrancy-eth | `CreditPool.markDefault` | **Fixed in part, rest justified.** The price read now happens before `_accrue()` and every other write (it previously came after `_accrue`). The remaining "write after external call" is inherent to pricing collateral and is covered as in H2. |
| M1 | Medium | incorrect-equality | `CreditPool._baseRateAfter`, `utilization` (`book == 0`) | **False positive.** `book` is internal accounting (`lpCash + totalPrincipal`), not a token balance, so donations can't move it; the check only avoids division by zero. |
| M2 | Medium | incorrect-equality | `CreditPool.debtOf` (`loan.kind == Kind.None`) | **False positive.** An enum comparison, not a balance. |
| M3 | Medium | pyth-unchecked-confidence | `MonPriceOracle.updateAndRead` | **False positive.** We reject prices whose confidence interval exceeds `maxConfBps` (2%): `if (uint256(p.conf) * BPS > price * maxConfBps) revert PriceTooUncertain()`. Covered by `test_RevertWhen_ConfidenceTooWide`. |

Low findings, all accepted:
- **timestamp** (×11): due dates, grace and attestation deadlines use `block.timestamp`. Monad timestamps have 1-s resolution and validators can skew them by a few seconds. That is harmless on a 30-day term, but on the demo clock (`TIME_SCALE = 43,200`, 1 s = 12 h) a few seconds is a few protocol days. The demo clock is for testnet only; production uses `TIME_SCALE = 1`.
- **reentrancy-benign** (×3): writes after calls to our own registry, inside `nonReentrant`.
- **missing-zero-check** (×2): `setAttestor` and the constructor's attestor. Setting the attestor to zero simply disables attestations (`ECDSA.recover` never returns zero). `setPool` now rejects zero, since the pool can only be set once (fixed, `test_RevertWhen_PoolIsZero`).

`forge lint` flags the same reentrancy-event and timestamp patterns, plus two intentional, range-checked casts in `MonPriceOracle` (annotated inline).

## Tests behind these claims

74 tests, including fuzzing and an invariant campaign (128 runs × 100 calls, `fail_on_revert = true`) across lenders, 6 borrowers and a keeper. It checks that stablecoin books balance; that debt is funded only by LP capital and the reserve only pays for defaults; that aggregates equal the sum of open loans; that no open loan exceeds its limit; that on-time repayments never lower a score; and that LP share price never falls while the reserve covers defaults.

## Trust assumptions and known risks

- **Owner** (`Ownable2Step`) can change parameters within hard-coded bounds, rotate the attestor and pause *new* borrowing. The owner can't move funds or block repay, withdraw, default or liquidate. There are no upgrades or proxies.
- **Attestor key** signs wallet-age and external-liquidation claims (EIP-712, with a deadline and a monotonic `issuedAt`). A leaked key can improve a borrower's prior by at most one pseudo-success, and can never make a first loan less than fully collateralised.
- **Pyth**: MON prices must be ≤ 60 s old with confidence ≤ 2%. Fetching price updates from Pyth's Hermes API needs an API key, held server-side only.
- **Sybils and bust-out** (spec §4): per-address limits don't stop sybils. With the spec parameters, one secured loan unlocks about 50 mUSDC of unsecured credit per address. Total unsecured exposure at origination is capped at `k × reserve` (k = 1), so LP principal is covered by the reserve, except for MON price moves between liquidations.
- **MockUSDC** has an open faucet. It exists only for the testnet demo and must never back real value.
