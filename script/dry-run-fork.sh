#!/usr/bin/env bash
# Dry-run Deploy.s.sol against a local anvil fork (default port 8630). Sends nothing to a live chain.
# Usage: ./script/dry-run-fork.sh mainnet|base
# Also checks that --broadcast without CONFIRM_MAINNET=yes is refused.
set -euo pipefail
export PATH="${HOME}/.foundry/bin:${PATH}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CHAIN=${1:-mainnet}
PORT=${ANVIL_PORT:-8630}
case "$CHAIN" in
  mainnet)
    RPC=${MAINNET_RPC_URL:-https://ethereum-rpc.publicnode.com}
    EXPECT=1
    NAME="Ethereum mainnet"
    ;;
  base)
    RPC=${BASE_RPC_URL:-https://mainnet.base.org}
    EXPECT=8453
    NAME="Base"
    ;;
  *)
    echo "usage: $0 mainnet|base" >&2
    exit 1
    ;;
esac

RPC_LOCAL="http://127.0.0.1:${PORT}"
STARTED=0
ANVIL_PID=""

cleanup() {
  if [ "$STARTED" = 1 ] && [ -n "$ANVIL_PID" ]; then
    kill "$ANVIL_PID" 2>/dev/null || true
    wait "$ANVIL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

chain_ready() {
  cast chain-id --rpc-url "$RPC_LOCAL" >/dev/null 2>&1
}

if chain_ready; then
  GOT=$(cast chain-id --rpc-url "$RPC_LOCAL")
  if [ "$GOT" != "$EXPECT" ]; then
    echo "Port $PORT is already in use by chain $GOT (expected $EXPECT for $NAME). Stop that process or set ANVIL_PORT." >&2
    exit 1
  fi
  echo "==> Reusing anvil on $RPC_LOCAL (chainId $GOT)"
else
  echo "==> Starting anvil $NAME fork on port $PORT"
  anvil --port "$PORT" --fork-url "$RPC" --silent >/tmp/stepped-agent-line-anvil-${PORT}.log 2>&1 &
  ANVIL_PID=$!
  STARTED=1
  for _ in $(seq 1 90); do
    if chain_ready; then break; fi
    if ! kill -0 "$ANVIL_PID" 2>/dev/null; then
      echo "anvil exited early. Last log lines:" >&2
      tail -n 40 "/tmp/stepped-agent-line-anvil-${PORT}.log" >&2 || true
      exit 1
    fi
    sleep 1
  done
  if ! chain_ready; then
    echo "anvil on port $PORT did not become ready" >&2
    exit 1
  fi
fi

GOT=$(cast chain-id --rpc-url "$RPC_LOCAL")
echo "==> Dry run on $NAME fork (chainId $GOT) at $RPC_LOCAL"
if [ "$GOT" != "$EXPECT" ]; then
  echo "Unexpected chain id $GOT (wanted $EXPECT)" >&2
  exit 1
fi

# Simulation only: no --broadcast. The dead sender is fine; this does not send a transaction.
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_LOCAL" \
  --sender "${DRY_RUN_SENDER:-0x000000000000000000000000000000000000dEaD}"

# Negative check against the LOCAL fork only. Force-unset CONFIRM_MAINNET so a parent env cannot
# accidentally authorize a broadcast. Uses anvil's unlocked account, never a private key.
echo "==> Guard check: --broadcast without CONFIRM_MAINNET=yes must be refused"
set +e
CONFIRM_MAINNET= forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_LOCAL" \
  --broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
STATUS=$?
set -e
if [ "$STATUS" -eq 0 ]; then
  echo "FAIL: deploy broadcast succeeded without CONFIRM_MAINNET=yes" >&2
  exit 1
fi
echo "OK: broadcast refused (exit $STATUS)"
echo "==> Dry run complete. Nothing was sent to $NAME."
