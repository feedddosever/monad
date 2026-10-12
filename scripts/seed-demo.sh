#!/usr/bin/env bash
# Seeds three demo borrowers (good payer, new wallet, late payer) on Monad Testnet.
# A loan must stay open for real time (60 s on the demo clock), so this re-runs one SeedDemo tick
# every few seconds until the script reports SEED_DONE (~3-4 minutes), then records the tx hashes.
set -euo pipefail
cd "$(dirname "$0")/.."

for i in $(seq 1 120); do
  out=$(forge script script/SeedDemo.s.sol --rpc-url monad_testnet --broadcast --slow 2>&1) || {
    echo "$out" | tail -25 >&2
    exit 1
  }
  echo "$out" | grep -E 'borrowed|repaid' || true
  if echo "$out" | grep -q SEED_DONE; then
    echo "$out" | grep -E ' score '
    break
  fi
  sleep 4
done

node scripts/collect-deployment.mjs
