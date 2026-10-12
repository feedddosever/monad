#!/usr/bin/env bash
# Deploys to Monad Testnet, verifies every contract on Sourcify (shown on MonadVision), then records
# addresses and tx hashes in deployments/testnet.json and the README.
#
# Needs PRIVATE_KEY in .env (read by the script itself; never echoed). Calls carry explicit gas limits
# (script/Params.sol); contract creations get forge's estimate +20% because Monad charges the gas limit.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/check-foundry.sh
grep -q '^PRIVATE_KEY=.\+' .env 2>/dev/null || { echo "Set PRIVATE_KEY in .env (see .env.example)" >&2; exit 1; }

forge script script/Deploy.s.sol \
  --rpc-url monad_testnet \
  --broadcast --slow \
  --gas-estimate-multiplier 120 \
  --verify --verifier sourcify --verifier-url https://sourcify-api-monad.blockvision.org/

node scripts/collect-deployment.mjs
