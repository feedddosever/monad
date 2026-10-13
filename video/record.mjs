// Records the demo video: slides plus the live app, driven by an injected test wallet and captured with CDP screencast.
// Narration clips come from make-voice.py; this logs when each one starts so build.py can lay the audio track.
//
// The app must be running at APP_URL, built from app/src/lib/deployment.json for the same chain.
// PRIVATE_KEY (the deployer/seed funder, from .env or the environment) derives the seeded demo wallets, and a fresh
// wallet for this take, which it funds with MON. Keys are used only on the Node side and never printed.
//
// env: PRIVATE_KEY, RPC_URL, APP_URL (default http://127.0.0.1:3000), TAKE (default: timestamp), CHROMIUM_PATH
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";
import { createPublicClient, createWalletClient, encodePacked, http, keccak256, numberToHex, parseAbi, parseEther } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const here = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.join(here, "out");
const deployment = JSON.parse(fs.readFileSync(path.join(here, "../app/src/lib/deployment.json"), "utf8"));
if (!deployment.contracts) throw new Error("app/src/lib/deployment.json has no contracts: deploy first");
const clips = JSON.parse(fs.readFileSync(path.join(outDir, "clips.json"), "utf8"));
const framesDir = path.join(outDir, "frames");
fs.rmSync(framesDir, { recursive: true, force: true });
fs.mkdirSync(framesDir, { recursive: true });

const APP_URL = process.env.APP_URL ?? "http://127.0.0.1:3000";
const RPC_URL = process.env.RPC_URL ?? (deployment.chainId === 10143 ? "https://testnet-rpc.monad.xyz" : "http://127.0.0.1:8545");
const chainId = deployment.chainId;
const network = chainId === 10143 ? "Monad Testnet (chain 10143)" : `local fork of Monad Testnet (chain ${chainId})`;
const funderKey = process.env.PRIVATE_KEY?.startsWith("0x") ? process.env.PRIVATE_KEY : `0x${process.env.PRIVATE_KEY ?? ""}`;
const take = process.env.TAKE ?? String(Date.now());

const ORDER = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
const derive = (prefix, label) =>
  numberToHex((BigInt(keccak256(encodePacked(["uint256", "string", "string"], [BigInt(funderKey), prefix, label]))) % (ORDER - 1n)) + 1n, { size: 32 });
const funder = privateKeyToAccount(funderKey);
const demo = privateKeyToAccount(derive("monad-metropolis-video:", take));
const goodPayer = privateKeyToAccount(derive("monad-metropolis-seed:", "good-payer")).address; // same derivation as SeedDemo
const latePayer = privateKeyToAccount(derive("monad-metropolis-seed:", "late-payer")).address;

const chain = { id: chainId, name: "target", nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 }, rpcUrls: { default: { http: [RPC_URL] } } };
const pub = createPublicClient({ chain, transport: http(RPC_URL) });
const wal = createWalletClient({ account: demo, chain, transport: http(RPC_URL) });

// Fresh wallet for this take: gas money from the funder, test stablecoins from the faucet.
if ((await pub.getBalance({ address: demo.address })) < parseEther("0.15")) {
  const fw = createWalletClient({ account: funder, chain, transport: http(RPC_URL) });
  await pub.waitForTransactionReceipt({ hash: await fw.sendTransaction({ to: demo.address, value: parseEther("0.3"), gas: 21_000n }) });
}
const usdc = deployment.contracts.MockUSDC;
const usdcAbi = parseAbi(["function mint(address,uint256)", "function balanceOf(address) view returns (uint256)"]);
if ((await pub.readContract({ address: usdc, abi: usdcAbi, functionName: "balanceOf", args: [demo.address] })) < 500_000_000n) {
  const h = await wal.writeContract({ address: usdc, abi: usdcAbi, functionName: "mint", args: [demo.address, 1_000_000_000n], gas: 125_000n });
  await pub.waitForTransactionReceipt({ hash: h });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let walletChain = 1; // start on Ethereum to show the wrong-network screen
let connected = false;
let shownAccount = demo.address;
const txs = [];

const browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : { channel: "chrome" });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
await page.exposeFunction("__walletRequest", async (method, params) => {
  switch (method) {
    case "eth_requestAccounts":
      connected = true;
      return [shownAccount];
    case "eth_accounts":
      return connected ? [shownAccount] : [];
    case "eth_chainId":
      return numberToHex(walletChain);
    case "wallet_switchEthereumChain":
      walletChain = Number(params[0].chainId);
      setTimeout(() => appFrame()?.evaluate((c) => window.__emit("chainChanged", c), numberToHex(walletChain)), 0);
      return null;
    case "wallet_addEthereumChain":
      return null;
    case "eth_sendTransaction": {
      const p = params[0];
      const hash = await wal.sendTransaction({ to: p.to, data: p.data, value: p.value ? BigInt(p.value) : undefined, gas: p.gas ? BigInt(p.gas) : undefined });
      txs.push({ hash, gas: p.gas ? String(BigInt(p.gas)) : "auto" });
      return hash;
    }
    default:
      return pub.request({ method, params });
  }
});
await page.addInitScript((appOrigin) => {
  // The app is laid out for ~560 px; zoom its document so it fills the stage with correct input coordinates.
  if (location.origin === appOrigin) document.addEventListener("DOMContentLoaded", () => (document.documentElement.style.zoom = "1.3"));
  const listeners = {};
  window.__emit = (event, arg) => (listeners[event] || []).forEach((f) => f(arg));
  window.ethereum = {
    isMetaMask: true,
    request: ({ method, params }) => window.__walletRequest(method, params ?? []),
    on: (e, f) => (listeners[e] = [...(listeners[e] || []), f]),
    removeListener: (e, f) => (listeners[e] = (listeners[e] || []).filter((g) => g !== f)),
  };
}, new URL(APP_URL).origin);

await page.goto(`file://${path.join(here, "stage.html")}`);
await page.evaluate(([u, n]) => { document.getElementById("app").src = u; window.setNetwork(n); }, [APP_URL, network]);
const app = page.frameLocator("#app");
const appFrame = () => page.frames().find((f) => f.url().startsWith(APP_URL));
await app.getByRole("button", { name: "Connect wallet" }).waitFor({ timeout: 30_000 });

// ---- capture
const cdp = await page.context().newCDPSession(page);
const frames = [];
cdp.on("Page.screencastFrame", async ({ data, metadata, sessionId }) => {
  const file = path.join(framesDir, `${String(frames.length).padStart(6, "0")}.jpg`);
  frames.push({ file, t: metadata.timestamp ?? Date.now() / 1000 });
  fs.writeFileSync(file, Buffer.from(data, "base64"));
  await cdp.send("Page.screencastFrameAck", { sessionId }).catch(() => {});
});
await cdp.send("Page.startScreencast", { format: "jpeg", quality: 92, maxWidth: 1920, maxHeight: 1080, everyNthFrame: 1 });
const timeline = [];
const tStart = Date.now() / 1000;

const stage = (fn, arg) => page.evaluate(fn, arg);
async function say(id, step) {
  const c = clips[id];
  timeline.push({ id, t: Date.now() / 1000, file: c.file, dur: c.dur });
  if (step) await stage(([s, t]) => window.setStep(s, t), [step, c.caption]);
  await sleep(c.dur * 1000 + 350);
}
async function pointAt(loc, fx = 0.5, fy = 0.5) {
  await loc.waitFor();
  const b = await loc.boundingBox();
  const xy = [b.x + b.width * fx, b.y + b.height * fy];
  await stage(([x, y]) => window.cursorTo(x, y), xy);
  return xy;
}
async function clickAt(loc) {
  const xy = await pointAt(loc);
  await sleep(850);
  await stage(([x, y]) => window.pulseAt(x, y), xy);
  await loc.click();
}
async function showAccount(addr, score) {
  shownAccount = addr;
  await appFrame().evaluate((a) => window.__emit("accountsChanged", [a]), addr);
  await app.getByTestId("score").filter({ hasText: score }).waitFor({ timeout: 20_000 });
  await app.getByTestId("apr").filter({ hasNotText: "…" }).waitFor();
}

// ---- 1. problem, 2. model
await sleep(400);
await stage(() => window.show("s-intro"));
await sleep(900);
await say("intro");
await stage(() => window.show("s-model"));
await sleep(700);
await say("model");

// ---- 3. live app
await stage(() => window.show("s-app"));
await sleep(900);
let p = say("connect", "1 · Connect");
await sleep(700);
await clickAt(app.getByRole("button", { name: "Connect wallet" }));
await app.getByText("Wrong network").waitFor();
await p;
p = say("switch", "1 · Connect");
await sleep(500);
await clickAt(app.getByRole("button", { name: /Switch to/ }));
await app.getByTestId("apr").filter({ hasNotText: "…" }).waitFor();
await p;

p = say("credit", "2 · Your credit");
await pointAt(app.getByTestId("score"), 1.02, 0.85);
await sleep(3200);
await pointAt(app.getByText("On-time repayments."), 0.3, 0.5);
await sleep(4300);
await pointAt(app.getByTestId("collateral"), 0.95, 0.95);
await p;

await clickAt(app.getByRole("button", { name: "Borrow", exact: true }));
await app.getByTestId("amount").waitFor();
await sleep(900);
p = say("borrow", "3 · Borrow");
await pointAt(app.getByTestId("collateral-required"), 0.4, 0.5);
await p;
p = say("borrowtx", "3 · Borrow");
await clickAt(app.getByTestId("borrow"));
await app.getByTestId("owed").waitFor({ timeout: 90_000 });
await p;

await pointAt(app.getByTestId("owed"), 0.55, 0.95);
await say("loan1", "4 · Loan open");
await pointAt(app.getByTestId("history-credit"), 0.25, 0.5);
await say("loan2", "4 · Loan open");
await say("loan3", "4 · Loan open");
await say("loan4", "4 · Loan open");
await stage(([s, t]) => window.setStep(s, t), ["4 · Loan open", "Waiting for ¾ of the term…"]);
await app.getByTestId("history-credit").filter({ hasText: "Full history credit:" }).waitFor({ timeout: 90_000 });
await sleep(1200);

p = say("repay", "5 · Repay");
await clickAt(app.getByTestId("repay"));
await app.getByTestId("score-change").waitFor({ timeout: 90_000 });
await app.getByTestId("score-change").filter({ hasText: "888" }).waitFor({ timeout: 10_000 }); // the narration quotes it
await p;
await sleep(500);
p = say("changed", "6 · What changed");
await pointAt(app.getByTestId("score-change"), 0.2, 1.0);
await sleep(4200);
await pointAt(app.getByTestId("score-change"), 0.55, 1.0);
await sleep(3300);
await pointAt(app.getByTestId("score-change"), 0.9, 1.0);
await p;

await clickAt(app.getByRole("button", { name: "Back to my credit" }));
await app.getByTestId("score").waitFor();
await sleep(1000);
await showAccount(goodPayer, "941");
p = say("good", "7 · Other borrowers");
await pointAt(app.getByTestId("score"), 1.02, 0.85);
await sleep(2400);
await pointAt(app.getByTestId("collateral"), 0.95, 0.95);
await p;
await showAccount(latePayer, "571");
p = say("late", "7 · Other borrowers");
await pointAt(app.getByTestId("score"), 1.02, 0.85);
await sleep(2400);
await pointAt(app.getByTestId("collateral"), 0.95, 0.95);
await p;
await stage(() => window.cursorHide());

// ---- 4. why monad, 5. next
await stage(() => window.show("s-monad"));
await sleep(700);
await say("monad");
await stage(() => window.show("s-next"));
await sleep(700);
await say("next");
await sleep(2200);
const tEnd = Date.now() / 1000;

await cdp.send("Page.stopScreencast");
await sleep(300);
fs.writeFileSync(path.join(outDir, "capture.json"), JSON.stringify({ tStart, tEnd, frames, timeline, network, demo: demo.address, txs }, null, 1));
console.log(JSON.stringify({ seconds: +(tEnd - tStart).toFixed(1), frames: frames.length, network, demo: demo.address, txs }, null, 1));
await browser.close();
