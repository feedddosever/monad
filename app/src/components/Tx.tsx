"use client";

import { useCallback, useState } from "react";
import { BaseError, ContractFunctionRevertedError, type Hash } from "viem";
import { publicClient, txUrl } from "@/lib/monad";

export type TxState =
  | { status: "idle" }
  | { status: "confirm"; label: string }
  | { status: "pending"; label: string; hash: Hash }
  | { status: "done"; label: string; hash: Hash }
  | { status: "error"; label: string; message: string; hash?: Hash };

/** Readable reason for a failed call: the contract's custom error, a wallet rejection, or viem's short message. */
export function describeError(e: unknown): string {
  if (e instanceof BaseError) {
    const revert = e.walk((err) => err instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError && revert.data?.errorName) {
      return REVERT_TEXT[revert.data.errorName] ?? revert.data.errorName;
    }
    if (e.walk((err) => (err as { code?: number }).code === 4001)) return "Rejected in your wallet.";
    return e.shortMessage;
  }
  return e instanceof Error ? e.message : String(e);
}

const REVERT_TEXT: Record<string, string> = {
  ExceedsLimit: "That's above your credit limit.",
  LoanOpen: "You already have an open loan. Repay it first.",
  Barred: "This address defaulted and can't borrow again.",
  UtilizationTooHigh: "The pool doesn't have enough free liquidity for that amount.",
  ReserveCapacityExceeded: "The first-loss reserve can't cover more unsecured credit right now. Try a smaller amount.",
  AprAboveMax: "The rate moved since your quote. Review the new rate and try again.",
  BorrowingIsPaused: "New borrowing is paused.",
  NoLoan: "There's no open loan to repay.",
};

/** Runs one transaction: wallet confirmation, pending with hash, then confirmed or failed. */
export function useTx() {
  const [state, setState] = useState<TxState>({ status: "idle" });

  const run = useCallback(async (label: string, send: () => Promise<Hash>) => {
    setState({ status: "confirm", label });
    let hash: Hash | undefined;
    try {
      const sent = await send();
      hash = sent;
      setState({ status: "pending", label, hash: sent });
      const receipt = await publicClient
        .waitForTransactionReceipt({ hash: sent, pollingInterval: 500, timeout: 60_000 })
        .catch(async (e) => {
          // Never leave the UI spinning: look the receipt up once more before giving up.
          const found = await publicClient.getTransactionReceipt({ hash: sent }).catch(() => null);
          if (found) return found;
          throw new Error(`Not confirmed after 60 s (${describeError(e)}). Check the explorer link.`);
        });
      if (receipt.status !== "success") throw new Error("The transaction reverted onchain.");
      setState({ status: "done", label, hash: sent });
      return true;
    } catch (e) {
      setState({ status: "error", label, message: describeError(e), hash });
      return false;
    }
  }, []);

  return { state, run, reset: () => setState({ status: "idle" }) };
}

export function TxStatus({ state }: { state: TxState }) {
  if (state.status === "idle") return null;
  const link =
    "hash" in state && state.hash ? (
      <a className="font-mono underline underline-offset-2" href={txUrl(state.hash)} target="_blank" rel="noreferrer">
        {state.hash.slice(0, 10)}…{state.hash.slice(-6)} ↗
      </a>
    ) : null;
  const tone = {
    confirm: "border-amber-300 bg-amber-50 text-amber-900 dark:border-amber-700 dark:bg-amber-950 dark:text-amber-100",
    pending: "border-sky-300 bg-sky-50 text-sky-900 dark:border-sky-700 dark:bg-sky-950 dark:text-sky-100",
    done: "border-emerald-300 bg-emerald-50 text-emerald-900 dark:border-emerald-700 dark:bg-emerald-950 dark:text-emerald-100",
    error: "border-rose-300 bg-rose-50 text-rose-900 dark:border-rose-700 dark:bg-rose-950 dark:text-rose-100",
  }[state.status];
  const text = {
    confirm: `${state.label}: confirm in your wallet…`,
    pending: `${state.label}: pending`,
    done: `${state.label}: confirmed`,
    error: `${state.label} failed: ${"message" in state ? state.message : ""}`,
  }[state.status];
  return (
    <div role="status" className={`mt-3 rounded-lg border px-3 py-2 text-sm ${tone}`}>
      <span>{text}</span> {link}
    </div>
  );
}
