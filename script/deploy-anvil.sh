#!/usr/bin/env bash
# Local only: deploys factory + MockUSDC to a running `anvil` (chain 31337) using anvil's
# unlocked dev account #0 - no private key needed or stored.
set -euo pipefail
export PATH="${HOME}/.foundry/bin:${PATH}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
RPC=${ANVIL_RPC:-http://127.0.0.1:8545}
SENDER=${ANVIL_SENDER:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC" --unlocked --sender "$SENDER" --broadcast
CHAIN_ID=$(cast chain-id --rpc-url "$RPC")
BROADCAST_FILE="broadcast/Deploy.s.sol/${CHAIN_ID}/run-latest.json"
if [ -f "$BROADCAST_FILE" ]; then
  FACTORY=$(jq -r '[.transactions[]? | select(.contractName=="SteppedAgentVaultFactory") | .contractAddress] | last // empty' "$BROADCAST_FILE")
  USDC=$(jq -r '[.transactions[]? | select(.contractName=="MockUSDC") | .contractAddress] | last // empty' "$BROADCAST_FILE")
  if [ -n "$FACTORY" ]; then
    ./script/write-web-config.sh "$CHAIN_ID" "$FACTORY" "$USDC"
  fi
fi
