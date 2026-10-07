# Spec: undercollateralised lending on onchain credit

**Track:** Onchain Finance & Trading · Monad Testnet (10143) · 4-day solo build, draft Oct 7, 2026

One lender pool; collateral in mUSDC or MON. Each on-time repayment lowers a borrower's estimated default probability (PD), cutting collateral and APR.

## 1. Users and demo

- **Borrower:** "My repayment record should replace the flat 150% collateral with my own terms."
- **Lender:** "I earn the base rate; a first-loss reserve takes defaults before I do."

| Time | Demo (3:00). Clock: 1 s = 12 h, so a 30-day loan runs 60 s. Each step shows its tx |
|---|---|
| 0:00 | Problem: DeFi only lends against overcollateral. Lender deposits 10,000 mUSDC; share price ticks per block |
| 0:30 | Old wallet attests its age → score 889; first loan is secured: borrow 100 against 100 |
| 0:55 | Interest ticks per second; repay at term → score 923, collateral 100% → 54% one block later |
| 1:30 | Seeded veteran (10 on-time loans, no wallet age) borrows 600 at 33% collateral, APR 7% base + 18% premium |
| 2:05 | Defaulter past due + grace; anyone calls `markDefault`; collateral and reserve cover it; address barred |
| 2:35 | Why Monad, explorer links. MON liquidation is in tests only (we can't move testnet prices) |

## 2. Credit model

**Inputs:** pool history (on-time repayments $P_k$ over $\tau_k$, late repayments, liquidations, defaults), plus wallet age and external liquidations, which contracts can't read, so our attestor signs them (EIP-712, from the Monadscan API).

```math
\begin{aligned}
E &= \textstyle\sum_{k\ \text{on time}} \min\!\left(1,\ \frac{P_k\,\tau_k}{\bar P\,\bar T}\right) && \text{history in reference-loan units}\\
PD &= \frac{b + F}{a + gA + E + b + F}, \quad F = \tfrac12\left(n_{\text{late}} + n_{\text{liq}} + n_{\text{extLiq}}\right), \quad A = \min\!\left(1, \tfrac{\text{age}}{1\,\text{yr}}\right) && \text{Beta}(a,b)\text{ posterior mean}\\
c &= 1 \text{ if } E < 1, \text{ else } c_{\min} + (1 - c_{\min})\min\!\left(1, PD/PD_0\right), \quad PD_0 = \tfrac{b}{a+b} && \text{collateral ratio}\\
APR &= \underbrace{r_0 + r_1 U}_{\text{to LPs}} + \underbrace{PD\,(1-c)/T}_{\text{to reserve}}, \qquad L = \min(L_{\max},\ L_0 + mV) && V = \text{repaid principal}
\end{aligned}
```

Score $= 1000\,(1-PD)$; a default bars the address. Premium = fair price of the unsecured share (PD × LGD per term). MON counts at haircut value: $C\,p\,(1-h) \ge cP$.

**Parameters:** $a=1$, $b=0.25$ (so $PD_0=20\%$), $g=1$, $c_{\min}=25\%$, $T=\bar T=30$ d, $\bar P=100$, $r_0=2\%$, $r_1=10\%$, $L_0=100$, $m=0.5$, $L_{\max}=5000$, $h=20\%$, $\theta=85\%$, max utilisation 90%.

| 1-yr-old wallet, $U=50\%$ | E = 0 | E = 1 | E = 5 | E = 10 | E = 10, 1 late, 1 liq |
|---|---|---|---|---|---|
| PD · score | 11.1% · 889 | 7.7% · 923 | 3.4% · 966 | 2.0% · 980 | 9.4% · 906 |
| collateral · APR | 100% · 7% | 54% · 50% | 38% · 33% | 33% · 24% | 60% · 53% |
| limit · unsecured | 100 · 0 | 150 · 69 | 350 · 217 | 600 · 404 | 600 · 238 |

## 3. Contracts

```solidity
// CreditRegistry (Ownable2Step). Record: E, V, late, liq, extLiq, firstTxTime, attestedAt, defaulted
submitAttestation(Attestation a, bytes sig)       // anyone; EIP-712 signed by attestor
terms(address b, uint256 baseRate) view returns (pd, c, apr, limit)
onRepaid(b, principal, elapsed, late) | onLiquidated(b) | onDefaulted(b)   // onlyPool
setParams(p) | setAttestor(a)  // onlyOwner, bounded. events: Attested, HistoryUpdated(b, pd, score)
// CreditPool (ERC4626 on mUSDC, Ownable2Step, ReentrancyGuard). One open Loan per borrower:
//   principal, collateral, unsecured, start, due, baseRate, premium, kind (Stable | Mon)
// Aggregates: totalPrincipal, sumBaseRate, accruedBase, reserve, stableCollateral, totalUnsecured
borrowStable(amount, maxApr) | borrowMon(amount, maxApr, pythUpdate) payable | repay()
markDefault(b, pythUpdate) payable | liquidate(b, pythUpdate) payable   // anyone, when eligible
fundReserve(amount) | pauseBorrowing(bool)        // anyone | owner (new loans only)
events: Borrowed, Repaid(toLPs, toReserve, late), Defaulted(recovered, cover, lpLoss), Liquidated
// Also: MonPriceOracle.updateAndRead(update) payable (Pyth adapter); MockUSDC.mint (faucet)
```

**Access control:** owner sets bounded params, rotates the attestor, pauses new loans; can't move funds or block exits.

**MON liquidation:** if $C\,p\,(1-h) < \theta\,c\,D$, anyone buys the MON at oracle −5%; the loan continues on stable collateral.

## 4. Failure modes

- **Default:** after due + 3 d grace, losses hit collateral → reserve → LPs; the address is barred.
- **Sybil and bust-out:** at origination $\sum(1-c)P \le kR$ ($R$ = reserve); with $k=1$, LP principal survives every unsecured loan defaulting. One secured loan (0.58 interest) unlocks about 50 mUSDC of bust-out per sybil; only $kR$ caps it.
- **Wash borrowing:** ≤ 1 unit of $E$ per loan and one open loan per address, so ≤ 1 unit per 30 days; premiums are sunk.
- **Oracles:** none for mUSDC. MON: Pyth pull update in every tx (testnet price 8 days stale; ≤ 60 s, conf ≤ 2%; Hermes key server-side). No Chainlink MON/USD on testnet. Attestations expire, no replay.
- **Reentrancy:** CEI + `nonReentrant`; MON sent last; exact Pyth fee, excess refunded; OZ virtual shares.
- **Rounding:** against the user (debt, collateral, PD up; payouts down); LP cash, reserve, collateral counted separately.

## 5. Why Monad

- **Blocks are 0.3 s, not 0.4 s** (measured 0.302 s, Oct 7; 600 ms finality); timestamps are 1-s, so we accrue **per second** (per-block accrual tuned for 0.4 s would overcharge 33%).
- **Freshness:** debts exact to the second; a repayment updates the score in-tx, new terms in ~0.6 s (pool writes serialise).
- **Cheap starter loans:** borrow + repay costs about 0.001 USD in gas against 0.58 USD of interest on 100 mUSDC.
- **Smaller MON haircut:** the haircut scales with $\sigma\sqrt{\Delta t}$ of liquidation latency, and the chain is no longer the slow part.

## 6. Scope (4 days, solo)

**MUST:** D1 registry and fuzz tests; D2 pool stable path and invariants; D3 MON path, attestor API route, deploy and seed; D4 frontend (lender view, score card with formula, interest ticker), README tx hashes, video.

**SHOULD:** external-liquidation indexing, keeper bot, partial repay, collateral top-up, verification, mainnet.

**WON'T:** proof of personhood, cross-chain credit, tranches or P2P, revolving lines, upgrades, multi-asset, auctions.

**Decisions (veto any):** per-second accrual; Pyth adapter; premiums fund a reserve we seed ($k=1$); first loan secured; permanent default; native MON; no upgrades.

