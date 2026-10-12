"use client";

import { useCallback, useEffect, useMemo, useState, useSyncExternalStore } from "react";
import { createWalletClient, custom, type Address, type EIP1193Provider } from "viem";
import { chain } from "@/lib/monad";

declare global {
  interface Window {
    ethereum?: EIP1193Provider;
  }
}

const noSubscribe = () => () => {};

/** Injected-wallet state: account, chain, and helpers to connect and switch to Monad Testnet. */
export function useWallet() {
  // undefined while server-rendering / before hydration; null when the browser has no injected wallet
  const provider = useSyncExternalStore(
    noSubscribe,
    () => window.ethereum ?? null,
    () => undefined,
  );
  const [account, setAccount] = useState<Address | null>(null);
  const [chainId, setChainId] = useState<number | null>(null);

  useEffect(() => {
    const eth = provider;
    if (!eth) return;
    eth.request({ method: "eth_accounts" }).then((a) => setAccount((a[0] as Address) ?? null));
    eth.request({ method: "eth_chainId" }).then((c) => setChainId(Number(c)));
    const onAccounts = (a: string[]) => setAccount((a[0] as Address) ?? null);
    const onChain = (c: string) => setChainId(Number(c));
    eth.on("accountsChanged", onAccounts);
    eth.on("chainChanged", onChain);
    return () => {
      eth.removeListener("accountsChanged", onAccounts);
      eth.removeListener("chainChanged", onChain);
    };
  }, [provider]);

  const walletClient = useMemo(
    () => (provider && account ? createWalletClient({ account, chain, transport: custom(provider) }) : null),
    [provider, account],
  );

  const connect = useCallback(async () => {
    if (!provider) return;
    const accounts = await provider.request({ method: "eth_requestAccounts" });
    setAccount((accounts[0] as Address) ?? null);
    setChainId(Number(await provider.request({ method: "eth_chainId" })));
  }, [provider]);

  const switchNetwork = useCallback(async () => {
    if (!provider) return;
    const client = createWalletClient({ chain, transport: custom(provider) });
    try {
      await client.switchChain({ id: chain.id });
    } catch (e) {
      // 4902: the wallet doesn't know the chain yet
      if ((e as { code?: number }).code === 4902 || String(e).includes("4902")) {
        await client.addChain({ chain });
      } else {
        throw e;
      }
    }
    setChainId(Number(await provider.request({ method: "eth_chainId" })));
  }, [provider]);

  return {
    ready: provider !== undefined,
    hasWallet: !!provider,
    account,
    chainId,
    onRightChain: chainId === chain.id,
    walletClient,
    connect,
    switchNetwork,
  };
}
