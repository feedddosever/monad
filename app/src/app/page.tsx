import { chain } from "@/lib/monad";

export default function Home() {
  return (
    <main className="flex flex-1 flex-col items-center justify-center gap-2 p-8 font-sans">
      <h1 className="text-2xl font-semibold">Monad Metropolis</h1>
      <p className="text-zinc-600 dark:text-zinc-400">
        {chain.name} (chain id {chain.id})
      </p>
    </main>
  );
}
