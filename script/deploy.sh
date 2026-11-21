#!/usr/bin/env bash
# Deploy SteppedAgentVaultFactory to Ethereum mainnet (1) or Base (8453).
#   Dry run (default, sends nothing):   RPC_URL=... ./script/deploy.sh
#   Live broadcast (real ETH!):         RPC_URL=... CONFIRM_MAINNET=yes ./script/deploy.sh --broadcast
# Signer (broadcast only): DEPLOYER_ACCOUNT (Foundry --account), DEPLOYER_KEYSTORE (JSON path),
#   or DEPLOYER_KEY (raw private key). Secrets are read from env and never echoed.
# Optional: ETHERSCAN_API_KEY (adds --verify via Etherscan v2).
set -euo pipefail
export PATH="${HOME}/.foundry/bin:${PATH}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

: "${RPC_URL:?set RPC_URL to an Ethereum mainnet or Base RPC endpoint}"
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
case "$CHAIN_ID" in
  1)     CHAIN_NAME="Ethereum mainnet" ;;
  8453)  CHAIN_NAME="Base" ;;
  31337) CHAIN_NAME="Local anvil (use deploy-anvil.sh)" ;;
  *) echo "Refusing: chain $CHAIN_ID is not supported (only 1, 8453)" >&2; exit 1 ;;
esac
echo "==> Chain: $CHAIN_NAME (chainId $CHAIN_ID)"

ARGS=(script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL")
if [ "${1:-}" = "--broadcast" ]; then
  if [ "$CHAIN_ID" != "31337" ] && [ "${CONFIRM_MAINNET:-}" != "yes" ]; then
    echo "Refusing to broadcast on $CHAIN_NAME: set CONFIRM_MAINNET=yes to deploy with real funds." >&2; exit 1
  fi
  if [ -n "${DEPLOYER_ACCOUNT:-}" ]; then
    ARGS+=(--broadcast --account "$DEPLOYER_ACCOUNT")
  elif [ -n "${DEPLOYER_KEYSTORE:-}" ]; then
    ARGS+=(--broadcast --keystore "$DEPLOYER_KEYSTORE")
  elif [ -n "${DEPLOYER_KEY:-}" ]; then
    ARGS+=(--broadcast --private-key "$DEPLOYER_KEY")
  else
    echo "Set DEPLOYER_ACCOUNT (Foundry keystore name), DEPLOYER_KEYSTORE, or DEPLOYER_KEY to broadcast." >&2
    exit 1
  fi
  if [ -n "${ETHERSCAN_API_KEY:-}" ]; then
    ARGS+=(--verify --verifier etherscan --verifier-url "https://api.etherscan.io/v2/api?chainid=${CHAIN_ID}")
  fi
  echo "==> LIVE broadcast on $CHAIN_NAME"
else
  echo "==> Dry run only (pass --broadcast with CONFIRM_MAINNET=yes to deploy)"
  ARGS+=(--sender "${DRY_RUN_SENDER:-0x000000000000000000000000000000000000dEaD}")
fi
forge script "${ARGS[@]}"

if [ "${1:-}" = "--broadcast" ]; then
  BROADCAST_FILE="broadcast/Deploy.s.sol/${CHAIN_ID}/run-latest.json"
  if [ -f "$BROADCAST_FILE" ]; then
    FACTORY=$(jq -r '[.transactions[]? | select(.contractName=="SteppedAgentVaultFactory") | .contractAddress] | last // empty' "$BROADCAST_FILE")
    USDC=$(jq -r '[.transactions[]? | select(.contractName=="MockUSDC") | .contractAddress] | last // empty' "$BROADCAST_FILE")
    if [ -z "$USDC" ]; then
      case "$CHAIN_ID" in
        1) USDC="0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48" ;;
        8453) USDC="0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" ;;
      esac
    fi
    if [ -n "$FACTORY" ]; then
      ./script/write-web-config.sh "$CHAIN_ID" "$FACTORY" "$USDC"
    else
      echo "Warning: could not find SteppedAgentVaultFactory in $BROADCAST_FILE" >&2
    fi
  fi
fi
