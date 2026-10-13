"use client";

import { useCallback, useEffect, useState } from "react";
import { formatUnits, parseUnits, type Address, type WalletClient } from "viem";
import { GAS, USDC_DECIMALS, WAD, contracts, poolAbi, timeScale, usdcAbi } from "@/lib/contracts";
import { explain, FULL_CREDIT_SHARE, fmtPct, heldFraction, readCredit, scoreAfterOnTimeRepay, type Credit } from "@/lib/credit";
import { addressUrl, chain, publicClient } from "@/lib/monad";
import { TxStatus, describeError, useTx } from "./Tx";
import { useWallet } from "./useWallet";

type Screen = "credit" | "borrow" | "loan";
type Quote = { baseRate: bigint; premium: bigint; apr: bigint; collateralValue: bigint; collateralRatio: bigint };

const FAUCET = "https://testnet.monad.xyz";
const YEAR = 365 * 24 * 3600;
const usd = (x: bigint, digits = 2) =>
  Number(formatUnits(x, USDC_DECIMALS)).toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });
const pct = (x: bigint, digits = 1) => fmtPct(Number(x) / 1e18, digits);
/** Interest per loan term as a share of principal, from an annual rate (WAD) and the term in protocol seconds. */
const perTerm = (apr: bigint, term: number) => (apr * BigInt(term)) / BigInt(YEAR);
const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;

export default function App() {
  const wallet = useWallet();
  const [credit, setCredit] = useState<Credit | null>(null);
  const [screen, setScreen] = useState<Screen>("credit");
  const [error, setError] = useState<string | null>(null);
  const now = useNow();

  const refresh = useCallback(async () => {
    if (!wallet.account || !wallet.onRightChain || !contracts) return null;
    try {
      const c = await readCredit(wallet.account);
      setCredit(c);
      setError(null);
      return c;
    } catch (e) {
      setError(describeError(e));
      return null;
    }
  }, [wallet.account, wallet.onRightChain]);

  useEffect(() => {
    // Polls on a timer; the first read is just the first tick so state isn't set synchronously in the effect.
    const id = setInterval(refresh, 3000);
    const first = setTimeout(refresh, 0);
    return () => {
      clearInterval(id);
      clearTimeout(first);
    };
  }, [refresh]);

  let body: React.ReactNode;
  if (!contracts) body = <Notice title="Not deployed yet">Run scripts/deploy-testnet.sh to deploy the contracts.</Notice>;
  else if (!wallet.ready) body = <Notice title="Loading…" />;
  else if (!wallet.hasWallet)
    body = (
      <Notice title="No wallet found">
        Install an EVM wallet (MetaMask, Rabby, Phantom) to continue, then reload this page.
      </Notice>
    );
  else if (!wallet.account)
    body = (
      <Notice title="See what your onchain history is worth">
        <p>Connect a wallet to see your credit score, why it is what it is, and what you can borrow.</p>
        <button className={btn} onClick={wallet.connect}>
          Connect wallet
        </button>
      </Notice>
    );
  else if (!wallet.onRightChain)
    body = (
      <Notice title="Wrong network">
        <p>
          Your wallet is on chain {wallet.chainId ?? "?"}. This app runs on {chain.name} (chain {chain.id}).
        </p>
        <button className={btn} onClick={() => wallet.switchNetwork().catch((e) => setError(describeError(e)))}>
          Switch to {chain.name}
        </button>
      </Notice>
    );
  else if (!credit) body = <Notice title="Reading your history…" />;
  else if (screen === "borrow" && !credit.loan)
    body = (
      <BorrowScreen
        credit={credit}
        account={wallet.account}
        walletClient={wallet.walletClient!}
        onBack={() => setScreen("credit")}
        onBorrowed={async () => {
          await refresh();
          setScreen("loan");
        }}
      />
    );
  else if (screen === "loan" || (screen === "borrow" && credit.loan))
    body = (
      <LoanScreen
        credit={credit}
        account={wallet.account}
        walletClient={wallet.walletClient!}
        now={now}
        refresh={refresh}
        onDone={() => setScreen("credit")}
      />
    );
  else
    body = (
      <CreditScreen
        credit={credit}
        account={wallet.account}
        now={now}
        onBorrow={() => setScreen(credit.loan ? "loan" : "borrow")}
      />
    );

  return (
    <div className="mx-auto flex w-full max-w-xl flex-1 flex-col gap-4 px-4 py-8">
      <header className="flex items-center justify-between">
        <span className="text-lg font-semibold tracking-tight">Monad Credit</span>
        {wallet.account ? (
          <a className={chip} href={addressUrl(wallet.account)} target="_blank" rel="noreferrer">
            <span className={wallet.onRightChain ? "text-emerald-500" : "text-rose-500"}>●</span> {short(wallet.account)}
          </a>
        ) : null}
      </header>
      {wallet.account && wallet.onRightChain && credit ? <Steps screen={screen} hasLoan={!!credit.loan} /> : null}
      {error ? <p className="rounded-lg bg-rose-50 px-3 py-2 text-sm text-rose-900 dark:bg-rose-950 dark:text-rose-100">{error}</p> : null}
      {body}
    </div>
  );
}

// ---------------------------------------------------------------- screen 1: credit

function CreditScreen({ credit, account, now, onBorrow }: { credit: Credit; account: Address; now: number; onBorrow: () => void }) {
  const limit = credit.terms.limit;
  const quote = useQuote(account, limit);
  const barred = credit.record.defaulted;
  const nextScore = scoreAfterOnTimeRepay(credit, limit, now);
  return (
    <>
      <Card>
        <p className={label}>Your credit score</p>
        <div className="flex items-end gap-3">
          <span className="text-6xl font-semibold tabular-nums" data-testid="score">
            {credit.score}
          </span>
          <span className="pb-2 text-sm text-zinc-500">/ 1000</span>
        </div>
        <p className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">
          Estimated chance a loan isn&apos;t repaid: <b>{fmtPct(credit.terms.pd)}</b>
        </p>
      </Card>

      <Card>
        <p className={label}>Why</p>
        <ul className="mt-2 flex flex-col gap-3">
          {explain(credit, now).map((f) => (
            <li key={f.title} className="flex gap-3 text-sm">
              <span className={f.effect === "up" ? "text-emerald-500" : f.effect === "down" ? "text-rose-500" : "text-zinc-400"}>
                {f.effect === "up" ? "▲" : f.effect === "down" ? "▼" : "●"}
              </span>
              <span>
                <b>{f.title}.</b> {f.detail}
              </span>
            </li>
          ))}
        </ul>
      </Card>

      <Card>
        <p className={label}>What you can borrow</p>
        <div className="mt-2 grid grid-cols-3 gap-3">
          <Stat title="Credit limit" value={`${usd(limit, 0)} mUSDC`} testId="limit" />
          <Stat title="Collateral" value={`${fmtPct(credit.terms.collateralRatio, 0)} of loan`} testId="collateral" />
          <Stat
            title={`Cost per ${Math.round(credit.params.term / 86400)}-day loan`}
            value={quote ? pct(perTerm(quote.apr, credit.params.term), 2) : "…"}
            testId="apr"
          />
        </div>
        {quote ? (
          <p className="mt-3 text-xs text-zinc-500" data-testid="apr-breakdown">
            {quote.premium === 0n ? (
              <>
                That&apos;s {pct(quote.apr)} APR, the pool rate. Your loan is fully secured, so there&apos;s no risk
                premium.
              </>
            ) : (
              <>
                That&apos;s {pct(quote.apr)} APR: {pct(quote.baseRate)} pool rate + {pct(quote.premium)} risk premium. You
                skip posting {fmtPct(1 - credit.terms.collateralRatio, 0)} of the loan as collateral; the premium is the
                fair price of that unsecured share (default chance × unsecured share, per loan) and funds the lenders&apos;
                first-loss reserve.
              </>
            )}
          </p>
        ) : null}
        {!barred && !credit.loan ? (
          <p className="mt-2 text-xs text-zinc-500">
            Repay a {usd(limit, 0)} mUSDC loan on time, at least ¾ of the way through its term, and your score rises to
            about {nextScore}. Repaying sooner earns proportionally less history.
          </p>
        ) : null}
      </Card>

      <button className={btn} disabled={barred} onClick={onBorrow}>
        {barred ? "Borrowing closed for this address" : credit.loan ? "View your open loan" : "Borrow"}
      </button>
    </>
  );
}

// ---------------------------------------------------------------- screen 2: borrow

function BorrowScreen({
  credit,
  account,
  walletClient,
  onBack,
  onBorrowed,
}: {
  credit: Credit;
  account: Address;
  walletClient: WalletClient;
  onBack: () => void;
  onBorrowed: () => void;
}) {
  const limit = credit.terms.limit;
  const [input, setInput] = useState(() => formatUnits(limit < 100_000_000n ? limit : 100_000_000n, USDC_DECIMALS));
  const amount = safeParse(input);
  const quote = useQuote(account, amount);
  const balances = useBalances(account, [quote]);
  const tx = useTx();

  const collateral = quote?.collateralValue ?? 0n;
  const needApprove = balances !== null && balances.allowance < collateral;
  const gasNeeded = (GAS.borrowStable + (needApprove ? GAS.approve : 0n)) * (balances?.gasPrice ?? 0n);
  const termSeconds = credit.params.term / timeScale;
  const interest = quote ? (amount * quote.apr * BigInt(credit.params.term)) / (WAD * BigInt(YEAR)) : 0n;

  let problem: React.ReactNode = null;
  if (amount === 0n) problem = "Enter an amount.";
  else if (amount > limit) problem = `Your limit is ${usd(limit)} mUSDC.`;
  else if (balances && balances.mon < gasNeeded)
    problem = (
      <>
        You need about {formatUnits(gasNeeded, 18).slice(0, 6)} MON for gas (Monad charges the gas limit).{" "}
        <a className="underline" href={FAUCET} target="_blank" rel="noreferrer">
          Get testnet MON ↗
        </a>
      </>
    );
  else if (balances && balances.usdc < collateral) problem = `You need ${usd(collateral)} mUSDC of collateral; you have ${usd(balances.usdc)}.`;

  const busy = tx.state.status === "confirm" || tx.state.status === "pending";

  async function borrow() {
    if (!quote || !contracts) return;
    if (needApprove) {
      const ok = await tx.run("Approve mUSDC", () =>
        walletClient.writeContract({
          account,
          chain: walletClient.chain,
          address: contracts!.MockUSDC,
          abi: usdcAbi,
          functionName: "approve",
          args: [contracts!.CreditPool, collateral],
          gas: GAS.approve,
        }),
      );
      if (!ok) return;
    }
    const maxApr = quote.apr + quote.apr / 100n; // tolerate a 1% relative move from utilisation
    const ok = await tx.run("Borrow", async () => {
      const { request } = await publicClient.simulateContract({
        account,
        address: contracts!.CreditPool,
        abi: poolAbi,
        functionName: "borrowStable",
        args: [amount, maxApr],
        gas: GAS.borrowStable,
      });
      return walletClient.writeContract(request);
    });
    if (ok) onBorrowed();
  }

  async function mint() {
    await tx.run("Get 1,000 test mUSDC", () =>
      walletClient.writeContract({
        account,
        chain: walletClient.chain,
        address: contracts!.MockUSDC,
        abi: usdcAbi,
        functionName: "mint",
        args: [account, 1_000_000_000n],
        gas: GAS.mint,
      }),
    );
  }

  return (
    <>
      <Card>
        <p className={label}>Borrow mUSDC</p>
        <div className="mt-2 flex items-center gap-2">
          <input
            aria-label="Amount"
            data-testid="amount"
            className="w-full rounded-lg border border-zinc-300 bg-transparent px-3 py-2 text-2xl tabular-nums dark:border-zinc-700"
            inputMode="decimal"
            value={input}
            onChange={(e) => setInput(e.target.value)}
          />
          <button className={btnGhost} onClick={() => setInput(formatUnits(limit, USDC_DECIMALS))}>
            Max {usd(limit, 0)}
          </button>
        </div>
        <dl className="mt-4 grid grid-cols-2 gap-x-4 gap-y-2 text-sm">
          <dt className="text-zinc-500">You post as collateral</dt>
          <dd className="text-right tabular-nums" data-testid="collateral-required">
            {quote ? `${usd(collateral)} mUSDC (${pct(quote.collateralRatio, 0)})` : "…"}
          </dd>
          <dt className="text-zinc-500">Rate (APR)</dt>
          <dd className="text-right tabular-nums">
            {quote ? `${pct(quote.apr)} = ${pct(quote.baseRate)} + ${pct(quote.premium)} risk` : "…"}
          </dd>
          <dt className="text-zinc-500">Interest if held to term</dt>
          <dd className="text-right tabular-nums">{quote ? `${usd(interest, 4)} mUSDC` : "…"}</dd>
          <dt className="text-zinc-500">Due in</dt>
          <dd className="text-right tabular-nums">
            30 days <span className="text-zinc-500">({termSeconds}s on the demo clock)</span>
          </dd>
          <dt className="text-zinc-500">Your balance</dt>
          <dd className="text-right tabular-nums">
            {balances ? `${usd(balances.usdc)} mUSDC · ${Number(formatUnits(balances.mon, 18)).toFixed(3)} MON` : "…"}
          </dd>
        </dl>
        {problem ? <p className="mt-3 text-sm text-rose-600 dark:text-rose-400">{problem}</p> : null}
        <TxStatus state={tx.state} />
      </Card>
      <div className="flex gap-2">
        <button className={btnGhost} onClick={onBack} disabled={busy}>
          Back
        </button>
        {balances && amount > 0n && balances.usdc < collateral ? (
          <button className={btn} onClick={mint} disabled={busy}>
            Get 1,000 test mUSDC
          </button>
        ) : (
          <button className={btn} onClick={borrow} disabled={busy || !!problem || !quote} data-testid="borrow">
            {needApprove ? "Approve & borrow" : "Borrow"} {amount > 0n ? `${usd(amount)} mUSDC` : ""}
          </button>
        )}
      </div>
    </>
  );
}

// ---------------------------------------------------------------- screen 3: loan, repay, what changed

function LoanScreen({
  credit,
  account,
  walletClient,
  now,
  refresh,
  onDone,
}: {
  credit: Credit;
  account: Address;
  walletClient: WalletClient;
  now: number;
  refresh: () => Promise<Credit | null>;
  onDone: () => void;
}) {
  const [before, setBefore] = useState<Credit | null>(null);
  const [after, setAfter] = useState<Credit | null>(null);
  const [debt, setDebt] = useState<bigint | null>(null);
  const balances = useBalances(account, [debt === null]);
  const tx = useTx();
  const loan = credit.loan;

  useEffect(() => {
    if (!loan || !contracts) return;
    const read = () =>
      publicClient
        .readContract({ address: contracts!.CreditPool, abi: poolAbi, functionName: "debtOf", args: [account] })
        .then(([total]) => setDebt(total))
        .catch(() => {});
    const id = setInterval(read, 1000);
    const first = setTimeout(read, 0);
    return () => {
      clearInterval(id);
      clearTimeout(first);
    };
  }, [loan, account]);

  if (after && before) {
    return (
      <>
        <Card>
          <p className={label}>Repaid. Here&apos;s what changed</p>
          <div className="mt-3 grid grid-cols-3 gap-3">
            <Change title="Score" from={`${before.score}`} to={`${after.score}`} testId="score-change" />
            <Change
              title="Collateral"
              from={fmtPct(before.terms.collateralRatio, 0)}
              to={fmtPct(after.terms.collateralRatio, 0)}
            />
            <Change title="Limit" from={usd(before.terms.limit, 0)} to={usd(after.terms.limit, 0)} />
          </div>
          <TxStatus state={tx.state} />
        </Card>
        <button className={btn} onClick={onDone}>
          Back to my credit
        </button>
      </>
    );
  }
  if (!loan) return <Notice title="No open loan" />;

  const graceSeconds = Math.ceil((3 * 24 * 3600) / timeScale);
  const secondsLeft = loan.due - now;
  const termSeconds = loan.due - loan.start;
  const fullCreditAt = loan.start + Math.ceil(FULL_CREDIT_SHARE * termSeconds);
  const held = heldFraction(now - loan.start, termSeconds);
  const historyLine =
    now === 0
      ? "…"
      : secondsLeft < 0
        ? "Repaying late counts as half a missed payment, so your score will drop."
        : now >= fullCreditAt
          ? `Full history credit: repay now and your score rises to about ${scoreAfterOnTimeRepay(credit, loan.principal, now)}.`
          : `Full history credit in ${fullCreditAt - now}s (¾ of the term). Repaying now counts as ${Math.round(100 * held)}% of it: score about ${scoreAfterOnTimeRepay(credit, loan.principal, now, held)}.`;
  const status =
    now === 0
      ? "…"
      : secondsLeft >= 0
      ? `On time: due in ${secondsLeft}s (${fmtDays(secondsLeft * timeScale)} on the demo clock)`
      : -secondsLeft <= graceSeconds
        ? `Late by ${-secondsLeft}s: repay now. Anyone can mark a default after ${graceSeconds}s of grace.`
        : "Past the grace period: anyone can mark this loan defaulted. Repay now if it's still open.";
  const owed = debt ?? loan.principal;
  const pull = owed + owed / 100n; // interest keeps accruing until the tx lands
  const needApprove = balances !== null && balances.allowance < pull;
  const gasNeeded = (GAS.repay + (needApprove ? GAS.approve : 0n)) * (balances?.gasPrice ?? 0n);
  const busy = tx.state.status === "confirm" || tx.state.status === "pending";
  let problem: string | null = null;
  if (balances && balances.usdc < owed) problem = `You need ${usd(owed)} mUSDC to repay; you have ${usd(balances.usdc)}.`;
  else if (balances && balances.mon < gasNeeded) problem = "Not enough MON for gas. Get some from the testnet faucet.";

  async function repay() {
    if (!contracts) return;
    setBefore(credit);
    if (needApprove) {
      const ok = await tx.run("Approve mUSDC", () =>
        walletClient.writeContract({
          account,
          chain: walletClient.chain,
          address: contracts!.MockUSDC,
          abi: usdcAbi,
          functionName: "approve",
          args: [contracts!.CreditPool, pull],
          gas: GAS.approve,
        }),
      );
      if (!ok) return;
    }
    const ok = await tx.run("Repay", async () => {
      const { request } = await publicClient.simulateContract({
        account,
        address: contracts!.CreditPool,
        abi: poolAbi,
        functionName: "repay",
        gas: GAS.repay,
      });
      return walletClient.writeContract(request);
    });
    if (ok) setAfter(await refresh());
  }

  return (
    <>
      <Card>
        <p className={label}>Your loan</p>
        <div className="mt-1 text-4xl font-semibold tabular-nums" data-testid="owed">
          {usd(owed, 4)} <span className="text-base font-normal text-zinc-500">mUSDC owed</span>
        </div>
        <p className={`mt-1 text-sm ${secondsLeft >= 0 ? "text-emerald-600 dark:text-emerald-400" : "text-rose-600 dark:text-rose-400"}`}>
          {status}
        </p>
        <dl className="mt-4 grid grid-cols-2 gap-x-4 gap-y-2 text-sm">
          <dt className="text-zinc-500">Borrowed</dt>
          <dd className="text-right tabular-nums">{usd(loan.principal)} mUSDC</dd>
          <dt className="text-zinc-500">Interest so far</dt>
          <dd className="text-right tabular-nums">{usd(owed - loan.principal, 4)} mUSDC</dd>
          <dt className="text-zinc-500">Collateral (returned on repay)</dt>
          <dd className="text-right tabular-nums">{usd(loan.collateral)} mUSDC</dd>
          <dt className="text-zinc-500">Rate (APR)</dt>
          <dd className="text-right tabular-nums">{fmtPct(loan.baseRate + loan.premium)}</dd>
        </dl>
        <p className="mt-3 text-xs text-zinc-500" data-testid="history-credit">
          {historyLine}
        </p>
        {problem ? <p className="mt-3 text-sm text-rose-600 dark:text-rose-400">{problem}</p> : null}
        <TxStatus state={tx.state} />
      </Card>
      <button className={btn} onClick={repay} disabled={busy || !!problem} data-testid="repay">
        {needApprove ? "Approve & repay" : "Repay"} {usd(owed, 2)} mUSDC
      </button>
    </>
  );
}

// ---------------------------------------------------------------- data hooks

function useQuote(account: Address, amount: bigint) {
  const [quote, setQuote] = useState<Quote | null>(null);
  useEffect(() => {
    if (!contracts || amount === 0n) return;
    let live = true;
    const t = setTimeout(() => {
      publicClient
        .readContract({ address: contracts!.CreditPool, abi: poolAbi, functionName: "quote", args: [account, amount] })
        .then((q) => live && setQuote(q))
        .catch(() => live && setQuote(null));
    }, 250);
    return () => {
      live = false;
      clearTimeout(t);
    };
  }, [account, amount]);
  return quote;
}

function useBalances(account: Address, deps: unknown[]) {
  const [b, setB] = useState<{ usdc: bigint; allowance: bigint; mon: bigint; gasPrice: bigint } | null>(null);
  const key = JSON.stringify(deps, (_, v) => (typeof v === "bigint" ? v.toString() : v));
  useEffect(() => {
    if (!contracts) return;
    const read = async () => {
      const [usdc, allowance] = await publicClient.multicall({
        allowFailure: false,
        contracts: [
          { address: contracts!.MockUSDC, abi: usdcAbi, functionName: "balanceOf", args: [account] },
          { address: contracts!.MockUSDC, abi: usdcAbi, functionName: "allowance", args: [account, contracts!.CreditPool] },
        ],
      });
      const [mon, gasPrice] = await Promise.all([publicClient.getBalance({ address: account }), publicClient.getGasPrice()]);
      setB({ usdc, allowance, mon, gasPrice });
    };
    read().catch(() => {});
    const id = setInterval(() => read().catch(() => {}), 3000);
    return () => clearInterval(id);
  }, [account, key]);
  return b;
}

/** Wall-clock seconds, ticking every second. 0 until mounted (prerendering can't read the clock). */
function useNow() {
  const [now, setNow] = useState(0);
  useEffect(() => {
    const tick = () => setNow(Math.floor(Date.now() / 1000));
    const first = setTimeout(tick, 0);
    const id = setInterval(tick, 1000);
    return () => {
      clearTimeout(first);
      clearInterval(id);
    };
  }, []);
  return now;
}

// ---------------------------------------------------------------- small pieces

const btn =
  "w-full rounded-lg bg-violet-600 px-4 py-3 font-medium text-white transition hover:bg-violet-500 disabled:cursor-not-allowed disabled:opacity-40";
const btnGhost =
  "shrink-0 rounded-lg border border-zinc-300 px-4 py-3 text-sm transition hover:bg-zinc-100 disabled:opacity-40 dark:border-zinc-700 dark:hover:bg-zinc-900";
const chip = "rounded-full border border-zinc-300 px-3 py-1 font-mono text-xs dark:border-zinc-700";
const label = "text-xs font-medium uppercase tracking-wide text-zinc-500";

function Card({ children }: { children: React.ReactNode }) {
  return <section className="rounded-2xl border border-zinc-200 p-5 dark:border-zinc-800">{children}</section>;
}

function Notice({ title, children }: { title: string; children?: React.ReactNode }) {
  return (
    <Card>
      <h1 className="text-xl font-semibold">{title}</h1>
      <div className="mt-2 flex flex-col gap-4 text-sm text-zinc-600 dark:text-zinc-400">{children}</div>
    </Card>
  );
}

function Stat({ title, value, testId }: { title: string; value: string; testId?: string }) {
  return (
    <div>
      <p className="text-xs text-zinc-500">{title}</p>
      <p className="text-lg font-semibold tabular-nums" data-testid={testId}>
        {value}
      </p>
    </div>
  );
}

function Change({ title, from, to, testId }: { title: string; from: string; to: string; testId?: string }) {
  return (
    <div>
      <p className="text-xs text-zinc-500">{title}</p>
      <p className="text-lg font-semibold tabular-nums" data-testid={testId}>
        <span className="text-zinc-400">{from}</span> → {to}
      </p>
    </div>
  );
}

function Steps({ screen, hasLoan }: { screen: Screen; hasLoan: boolean }) {
  const steps: [Screen, string][] = [
    ["credit", "1 Your credit"],
    ["borrow", "2 Borrow"],
    ["loan", "3 Repay"],
  ];
  const active = screen === "borrow" && hasLoan ? "loan" : screen;
  return (
    <ol className="flex gap-2 text-xs">
      {steps.map(([s, text]) => (
        <li
          key={s}
          className={`rounded-full px-3 py-1 ${s === active ? "bg-violet-600 text-white" : "bg-zinc-100 text-zinc-500 dark:bg-zinc-900"}`}
        >
          {text}
        </li>
      ))}
    </ol>
  );
}

function safeParse(input: string) {
  try {
    return input.trim() === "" ? 0n : parseUnits(input.trim(), USDC_DECIMALS);
  } catch {
    return 0n;
  }
}

function fmtDays(protocolSeconds: number) {
  const days = protocolSeconds / 86400;
  return days >= 1 ? `${days.toFixed(1)} days` : `${(protocolSeconds / 3600).toFixed(0)} h`;
}
