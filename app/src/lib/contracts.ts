import { parseAbi, type Address } from "viem";
import deployment from "./deployment.json";

type Contracts = { CreditPool: Address; CreditRegistry: Address; MonPriceOracle: Address; MockUSDC: Address };

/** Null until scripts/collect-deployment.mjs writes the deployed addresses. */
export const contracts = deployment.contracts as Contracts | null;
/** Protocol seconds per real second (43,200 on the demo clock: a 30-day loan lasts 60 s). */
export const timeScale = deployment.timeScale;

export const WAD = 10n ** 18n;
export const USDC_DECIMALS = 6;

/**
 * Explicit gas limits (same as script/Params.sol). Monad charges the gas LIMIT, so these are measured max + ~20%.
 * See docs/gas-report.md.
 */
export const GAS = {
  approve: 90_000n,
  mint: 125_000n,
  borrowStable: 370_000n,
  repay: 265_000n,
} as const;

export const registryAbi = parseAbi([
  "function records(address) view returns (uint128 earned, uint128 repaid, uint32 late, uint32 liquidations, uint32 extLiquidations, uint64 firstTxTime, uint64 attestedAt, bool defaulted)",
  "function params() view returns (uint256 a, uint256 b, uint256 g, uint256 failWeight, uint256 cMin, uint256 term, uint256 refPrincipal, uint256 baseLimit, uint256 limitPerRepaid, uint256 maxLimit)",
  "function terms(address) view returns ((uint256 pd, uint256 collateralRatio, uint256 premium, uint256 limit))",
  "function score(address) view returns (uint256)",
]);

export const poolAbi = parseAbi([
  "function quote(address borrower, uint256 amount) view returns ((uint256 pd, uint256 collateralRatio, uint256 baseRate, uint256 premium, uint256 apr, uint256 limit, uint256 collateralValue))",
  "function loans(address) view returns (uint128 principal, uint128 collateral, uint128 unsecured, uint64 start, uint64 due, uint64 baseRate, uint64 premium, uint8 kind)",
  "function debtOf(address) view returns (uint256 total, uint256 baseInterest, uint256 riskInterest)",
  "function lpCash() view returns (uint256)",
  "function borrowStable(uint256 amount, uint256 maxApr)",
  "function repay()",
  "error BorrowingIsPaused()",
  "error LoanOpen()",
  "error NoLoan()",
  "error Barred()",
  "error ExceedsLimit()",
  "error UtilizationTooHigh()",
  "error AprAboveMax()",
  "error ReserveCapacityExceeded()",
]);

export const usdcAbi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function mint(address to, uint256 amount)",
]);
