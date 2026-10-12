import { createPublicClient, defineChain, http, type Chain } from "viem";
import { monadTestnet } from "viem/chains";
import deployment from "./deployment.json";

const rpcOverride = process.env.NEXT_PUBLIC_MONAD_RPC_URL || undefined;

// viem's monadTestnet (chain 10143). A local fork (scripts use chain 31337) gets the same chain under its own id.
export const chain: Chain =
  deployment.chainId === monadTestnet.id
    ? monadTestnet
    : defineChain({
        ...monadTestnet,
        id: deployment.chainId,
        name: "Monad Testnet (local fork)",
        rpcUrls: { default: { http: [rpcOverride ?? "http://127.0.0.1:8545"] } },
      });

// Falls back to the chain's default RPC (https://testnet-rpc.monad.xyz) when unset.
export const publicClient = createPublicClient({
  chain,
  transport: http(rpcOverride),
});

export const explorer = deployment.explorer;
export const txUrl = (hash: string) => `${explorer}/tx/${hash}`;
export const addressUrl = (address: string) => `${explorer}/address/${address}`;
