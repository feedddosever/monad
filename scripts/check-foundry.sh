#!/usr/bin/env bash
# Verifies the installed Foundry has native Monad support (official Foundry >= 1.8.0).
# The legacy category-labs "Monad Foundry" fork stops at MonadNine and is not supported here.
set -euo pipefail

MIN="1.8.0"

if ! command -v forge >/dev/null 2>&1; then
  echo "forge not found. Install: curl -L https://foundry.paradigm.xyz | bash && foundryup" >&2
  exit 1
fi

out="$(forge --version)"
raw="${out%%$'\n'*}"
ver="$(printf '%s\n' "$raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^ ]*' | sed -n 1p || true)"
base="${ver%%-*}"

echo "Installed: $raw"

if [[ -z "$base" ]]; then
  echo "Could not parse a version from 'forge --version'." >&2
  exit 1
fi

if [[ "$ver" == *monad* ]]; then
  echo "This is the legacy Monad Foundry fork ($ver). It does not support MonadTen/MIP-8." >&2
  echo "Migrate: curl -L https://foundry.paradigm.xyz | bash && foundryup" >&2
  exit 1
fi

if [[ "$(printf '%s\n%s\n' "$MIN" "$base" | sort -V | sed -n 1p)" != "$MIN" ]]; then
  echo "Foundry $base is older than $MIN and has no Monad execution support. Run: foundryup" >&2
  exit 1
fi

echo "OK: Foundry $base >= $MIN (native Monad support)."
