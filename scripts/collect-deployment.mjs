#!/usr/bin/env node
// Builds deployments/testnet.json (every contract address and every tx hash, with explorer links) from
// forge's broadcast logs, rewrites the README's "Contracts & tx hashes" tables, and copies the
// addresses the frontend needs into app/src/lib/deployment.json. Reads only public data.
import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const CHAIN_ID = 10143;
const EXPLORER = "https://testnet.monadvision.com";
const root = new URL("..", import.meta.url).pathname;
const read = (p) => JSON.parse(readFileSync(join(root, p), "utf8"));

const deployment = read("deployments/testnet.json");
const wallets = existsSync(join(root, "deployments/demo-wallets.json")) ? read("deployments/demo-wallets.json") : {};
const contractNames = ["CreditPool", "CreditRegistry", "MonPriceOracle", "MockUSDC"];
const nameOf = Object.fromEntries(contractNames.map((n) => [deployment[n].toLowerCase(), n]));
const labelOf = Object.fromEntries(Object.entries(wallets).map(([label, a]) => [a.toLowerCase(), label]));
labelOf[deployment.deployer.toLowerCase()] = "deployer";

function broadcastRuns(script) {
  const dir = join(root, "broadcast", script, String(CHAIN_ID));
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((f) => /^run-\d+\.json$/.test(f))
    .sort()
    .map((f) => JSON.parse(readFileSync(join(dir, f), "utf8")));
}

const transactions = [];
for (const [script, step] of [["Deploy.s.sol", "deploy"], ["SeedDemo.s.sol", "seed"]]) {
  for (const run of broadcastRuns(script)) {
    const ok = new Set(run.receipts.filter((r) => r.status === "0x1").map((r) => r.transactionHash));
    for (const tx of run.transactions) {
      if (!ok.has(tx.hash)) continue;
      const from = tx.transaction.from.toLowerCase();
      const to = (tx.contractAddress || tx.transaction.to || "").toLowerCase();
      const target = nameOf[to] || labelOf[to] || tx.contractName || "address";
      const action =
        tx.transactionType === "CREATE"
          ? `deploy ${tx.contractName}`
          : tx.function
            ? `${target}.${tx.function.split("(")[0]}`
            : `send MON to ${target}`;
      transactions.push({ step, by: labelOf[from] || from, action, hash: tx.hash, url: `${EXPLORER}/tx/${tx.hash}` });
    }
  }
}

const out = {
  network: "Monad Testnet",
  chainId: CHAIN_ID,
  explorer: EXPLORER,
  deployBlock: deployment.deployBlock,
  timeScale: deployment.timeScale,
  deployer: deployment.deployer,
  attestor: deployment.attestor,
  contracts: Object.fromEntries(
    contractNames.map((n) => [n, { address: deployment[n], url: `${EXPLORER}/address/${deployment[n]}` }]),
  ),
  demoWallets: Object.fromEntries(
    Object.entries(wallets).map(([label, a]) => [label, { address: a, url: `${EXPLORER}/address/${a}` }]),
  ),
  transactions,
};
// Keep the flat address fields SeedDemo.s.sol reads.
for (const n of contractNames) out[n] = deployment[n];
writeFileSync(join(root, "deployments/testnet.json"), JSON.stringify(out, null, 2) + "\n");

writeFileSync(
  join(root, "app/src/lib/deployment.json"),
  JSON.stringify(
    {
      chainId: CHAIN_ID,
      explorer: EXPLORER,
      timeScale: Number(deployment.timeScale),
      contracts: Object.fromEntries(contractNames.map((n) => [n, deployment[n]])),
      demoWallets: wallets,
    },
    null,
    2,
  ) + "\n",
);

const short = (h) => `${h.slice(0, 10)}…${h.slice(-6)}`;
const md = [
  "| Contract | Address |",
  "|---|---|",
  ...contractNames.map((n) => `| ${n} | [\`${deployment[n]}\`](${EXPLORER}/address/${deployment[n]}) |`),
  "",
  ...(Object.keys(wallets).length
    ? [
        "| Demo wallet | Address |",
        "|---|---|",
        ...Object.entries(wallets).map(([l, a]) => `| ${l} | [\`${a}\`](${EXPLORER}/address/${a}) |`),
        "",
      ]
    : []),
  "| # | Step | By | Action | Tx hash |",
  "|---|---|---|---|---|",
  ...transactions.map((t, i) => `| ${i + 1} | ${t.step} | ${t.by} | ${t.action} | [${short(t.hash)}](${t.url}) |`),
].join("\n");

const readmePath = join(root, "README.md");
const readme = readFileSync(readmePath, "utf8");
const start = "<!-- deployment:start -->";
const end = "<!-- deployment:end -->";
if (!readme.includes(start)) throw new Error("README is missing the deployment markers");
const updated = readme.replace(new RegExp(`${start}[\\s\\S]*?${end}`), `${start}\n${md}\n${end}`);
writeFileSync(readmePath, updated);

console.log(`deployments/testnet.json: ${contractNames.length} contracts, ${transactions.length} transactions`);
