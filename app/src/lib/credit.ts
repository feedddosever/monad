import type { Address } from "viem";
import { WAD, contracts, poolAbi, registryAbi } from "./contracts";
import { publicClient } from "./monad";

const YEAR = 365 * 24 * 3600;
const num = (x: bigint) => Number(x) / 1e18;

export type CreditRecord = {
  earned: number; // E, in reference loans
  repaid: bigint; // V, mUSDC units
  late: number;
  liquidations: number;
  extLiquidations: number;
  firstTxTime: number;
  defaulted: boolean;
};

export type Params = {
  a: number;
  b: number;
  g: number;
  failWeight: number;
  cMin: number;
  term: number; // protocol seconds
  refPrincipal: bigint;
};

export type Terms = { pd: number; collateralRatio: number; premium: number; limit: bigint };

export type Loan = {
  principal: bigint;
  collateral: bigint;
  start: number;
  due: number;
  baseRate: number;
  premium: number;
};

export type Credit = { score: number; record: CreditRecord; params: Params; terms: Terms; loan: Loan | null };

export async function readCredit(account: Address): Promise<Credit> {
  if (!contracts) throw new Error("Contracts not deployed");
  const [score, rec, par, terms, loan] = await publicClient.multicall({
    allowFailure: false,
    contracts: [
      { address: contracts.CreditRegistry, abi: registryAbi, functionName: "score", args: [account] },
      { address: contracts.CreditRegistry, abi: registryAbi, functionName: "records", args: [account] },
      { address: contracts.CreditRegistry, abi: registryAbi, functionName: "params" },
      { address: contracts.CreditRegistry, abi: registryAbi, functionName: "terms", args: [account] },
      { address: contracts.CreditPool, abi: poolAbi, functionName: "loans", args: [account] },
    ],
  });
  const [earned, repaid, late, liquidations, extLiquidations, firstTxTime, , defaulted] = rec;
  const [a, b, g, failWeight, cMin, term, refPrincipal] = par;
  const [principal, collateral, , start, due, baseRate, premium] = loan;
  return {
    score: Number(score),
    record: {
      earned: num(earned),
      repaid,
      late,
      liquidations,
      extLiquidations,
      firstTxTime: Number(firstTxTime),
      defaulted,
    },
    params: { a: num(a), b: num(b), g: num(g), failWeight: num(failWeight), cMin: num(cMin), term: Number(term), refPrincipal },
    terms: { pd: num(terms.pd), collateralRatio: num(terms.collateralRatio), premium: num(terms.premium), limit: terms.limit },
    loan:
      principal === 0n
        ? null
        : { principal, collateral, start: Number(start), due: Number(due), baseRate: num(baseRate), premium: num(premium) },
  };
}

/** Wallet age as a fraction of a year (attested), 0 when unknown. */
function ageYears(r: CreditRecord, now: number) {
  return r.firstTxTime === 0 || r.firstTxTime >= now ? 0 : (now - r.firstTxTime) / YEAR;
}

/** Same formula as CreditRegistry.pd, in floating point, for explanations and previews. */
export function pdOf(p: Params, r: CreditRecord, now: number, extraEarned = 0) {
  if (r.defaulted) return 1;
  const failures = p.b + p.failWeight * (r.late + r.liquidations + r.extLiquidations);
  const successes = p.a + p.g * Math.min(1, ageYears(r, now)) + r.earned + extraEarned;
  return failures / (successes + failures);
}

export type Factor = { title: string; detail: string; effect: "up" | "down" | "neutral" };

/** Plain-language reasons behind the score. */
export function explain(c: Credit, now: number): Factor[] {
  const { record: r, params: p } = c;
  if (r.defaulted) {
    return [{ title: "Defaulted", detail: "This address missed a repayment past the grace period and can't borrow again.", effect: "down" }];
  }
  const startScore = Math.floor(1000 * (1 - p.b / (p.a + p.b)));
  const years = ageYears(r, now);
  const failures = r.late + r.liquidations + r.extLiquidations;
  return [
    {
      title: "Starting point",
      detail: `Everyone starts at ${startScore}: until you show otherwise we assume a ${Math.round((100 * p.b) / (p.a + p.b))}% chance a loan isn't repaid.`,
      effect: "neutral",
    },
    {
      title: "On-time repayments",
      detail:
        r.earned === 0
          ? "None yet. Your first loan is fully secured. One full loan of history (100 mUSDC repaid on time after at least ¾ of its term) starts lowering your collateral."
          : `Worth ${r.earned.toFixed(2)} full ${r.earned.toFixed(2) === "1.00" ? "loan" : "loans"} (100 mUSDC repaid on time after at least ¾ of its term). Each one pushes your score up.`,
      effect: r.earned > 0 ? "up" : "neutral",
    },
    {
      title: "Late repayments and liquidations",
      detail:
        failures === 0
          ? "None. Each one would count as half a missed payment."
          : `${r.late} late, ${r.liquidations + r.extLiquidations} liquidated. Each counts as half a missed payment.`,
      effect: failures > 0 ? "down" : "neutral",
    },
    {
      title: "Wallet age",
      detail:
        years === 0
          ? "Not verified. A verified wallet a year or older counts like one extra on-time loan."
          : `${years.toFixed(1)} years (verified), worth ${Math.min(1, years).toFixed(2)} of an on-time loan.`,
      effect: years > 0 ? "up" : "neutral",
    },
  ];
}

/** Matches CreditRegistry.FULL_CREDIT_SHARE: an on-time loan held this share of its term counts as fully held. */
export const FULL_CREDIT_SHARE = 0.75;

/** History credit for having held a loan `elapsed` of `term` seconds (CreditRegistry.heldFractionOf). */
export function heldFraction(elapsed: number, term: number) {
  const f = term > 0 ? Math.max(0, elapsed) / term : 0;
  return f >= FULL_CREDIT_SHARE ? 1 : f;
}

/** Score after repaying `principal` on time, having held it for `held` (0-1) of the term. */
export function scoreAfterOnTimeRepay(c: Credit, principal: bigint, now: number, held = 1) {
  const extra = Math.min(1, (Number(principal) * held) / Number(c.params.refPrincipal));
  return Math.floor(1000 * (1 - pdOf(c.params, c.record, now, extra)));
}

export const fmtPct = (x: number, digits = 1) => `${(100 * x).toFixed(digits)}%`;
export const toWadNumber = (x: bigint) => Number(x) / Number(WAD);
