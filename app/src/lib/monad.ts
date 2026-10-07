import { createPublicClient, http } from "viem";
import { monadTestnet } from "viem/chains";

// Target chain. For mainnet, swap in `monad` (chain id 143) from "viem/chains".
export const chain = monadTestnet;

// Falls back to the chain's default RPC (https://testnet-rpc.monad.xyz) when unset.
export const publicClient = createPublicClient({
  chain,
  transport: http(process.env.NEXT_PUBLIC_MONAD_RPC_URL),
});
