# Demo video script (2:40, hard cap 3:00)

This is the shot list for recording by hand. An automated, narrated version of the same flow is produced by [`video/`](../video/README.md), with its narration in `video/narration.json`.

Recording setup: app at 560 px wide next to a MonadVision tab, a wallet holding testnet MON, and a fresh wallet for the live flow. Have the seeded `good-payer` and `late-payer` addresses from `deployments/testnet.json` ready to paste. The demo clock runs 1 s = 12 h, so a 30-day loan lasts 60 s.

| Time | Screen | Voiceover |
|---|---|---|
| **0:00–0:20** · Problem | Title card, then an Aave-style "150% collateral" figure | "Onchain lending only works if you're already rich. Every market wants 150% collateral, so someone who has repaid a hundred loans gets the same terms as a wallet made five minutes ago. Repayment history is public; nobody prices it. Monad Credit does." |
| **0:20–0:35** · Connect | Click *Connect wallet* → *Wrong network* → *Switch to Monad Testnet* → score **800** | "I connect a brand-new wallet. Everyone starts at 800: we assume a one-in-five chance a loan isn't repaid until you show otherwise." |
| **0:35–0:50** · Why | Hover the four factors and the terms card: limit 100, collateral 100%, cost per loan | "Here's why, in plain language: no history yet, no late payments, wallet age not verified. So my first loan is fully secured, with a 100 mUSDC limit at the pool rate." |
| **0:50–1:10** · Borrow (**real tx**) | *Borrow* screen: collateral and APR breakdown → *Approve & borrow* → pending → confirmed → click the hash to open **MonadVision** | "I borrow 100. The app shows exactly what I post and why the rate is what it is. Confirmed in under a second. Here's the transaction on MonadVision." |
| **1:10–1:30** · Loan ticking | Loan screen: interest ticking every second, due countdown, "full history credit in …s" | "Interest accrues every second, because Monad blocks land every 0.3 seconds. On our demo clock a second is twelve hours, so this is a 30-day loan compressed into a minute. Once I'm three-quarters through the term, repaying counts as a full loan of history." |
| **1:30–1:50** · Repay, score moves | *Repay* (after "Full history credit" shows) → confirmed → score **800 → 888**, collateral **100% → 67%**, limit **100 → 150** | "I repay on time. Same transaction, my history updates: score up, collateral down by a third, limit up. Nothing waits for an epoch or an offchain job." |
| **1:50–2:00** · Seeded profiles | Paste `good-payer` → score 941, collateral 47%; paste `late-payer` → score 571, collateral 100% | "Three loans repaid on time: 941, and under half the collateral. One late payment: 571, and back to fully secured. Same formula, public inputs." |
| **2:00–2:20** · Why Monad | Slide with three numbers | "Why Monad? 0.3-second blocks, so debts and scores are live. About $0.0016 in gas for a whole borrow-and-repay cycle, so tiny credit-builder loans make sense. And room for the full lending engine in one 27-kilobyte contract." |
| **2:20–2:40** · What's next | Slide: roadmap | "Next: verified wallet-age and cross-protocol liquidation attestations in the app, MON collateral live with Pyth, tranches for lenders who want more risk, and identity proofs to close the sybil gap. Monad Credit: your history is your collateral." |

Notes:
- Show at least one real Monad Testnet tx hash on MonadVision. The borrow at 0:50 is the one to open.
- Repay between 45 s and 60 s into the loan: from 45 s (¾ of the term) it earns full history credit, and the loan screen says so. After 60 s it counts as late.
- Keep the cursor still while the voiceover covers numbers, and crop to the app and explorer.
