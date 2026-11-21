#!/usr/bin/env bash
# Tests the deploy script against a local anvil fork of Ethereum mainnet and, if reachable, Base.
# Uses only port 8630. Broadcasts go to the local fork, never to a public RPC.
# No deployer keys are used (anvil --unlocked account #0). Nothing is deployed on a live chain.
set -euo pipefail
export PATH="${HOME}/.foundry/bin:${PATH}"

PORT="${ANVIL_PORT:-8630}"
RPC="http://127.0.0.1:${PORT}"
ANVIL_SENDER="${ANVIL_SENDER:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"
MAINNET_RPC="${MAINNET_RPC_URL:-https://ethereum-rpc.publicnode.com}"
BASE_RPC="${BASE_RPC_URL:-https://mainnet.base.org}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

STARTED=0
ANVIL_PID=""
PREEXISTING=0
CONFIG="web/src/deployments.json"

cleanup() {
  if [ "$STARTED" = 1 ] && [ -n "${ANVIL_PID}" ]; then
    kill "$ANVIL_PID" 2>/dev/null || true
    wait "$ANVIL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

rpc_up() { cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; }

wait_rpc() {
  local i
  for i in $(seq 1 90); do
    if rpc_up; then return 0; fi
    sleep 1
  done
  echo "anvil on ${RPC} did not become ready" >&2
  return 1
}

start_fork() {
  local name="$1" url="$2" expected_id="$3"
  if [ "$STARTED" = 1 ] && [ -n "${ANVIL_PID}" ]; then
    kill "$ANVIL_PID" 2>/dev/null || true
    wait "$ANVIL_PID" 2>/dev/null || true
    STARTED=0
    ANVIL_PID=""
    sleep 1
  fi
  if rpc_up; then
    local existing
    existing="$(cast chain-id --rpc-url "$RPC")"
    if [ "$existing" = "$expected_id" ]; then
      echo "==> Reusing existing node on port ${PORT} (chain ${existing}, ${name})"
      return 0
    fi
    if [ "$PREEXISTING" = 1 ]; then
      echo "Port ${PORT} is already in use with chain ${existing}, expected ${expected_id}. Not killing a process we did not start." >&2
      return 2
    fi
    echo "Port ${PORT} still occupied with chain ${existing} after stopping our anvil." >&2
    return 1
  fi
  echo "==> Starting anvil fork of ${name} on port ${PORT}"
  anvil --port "$PORT" --fork-url "$url" --silent >"/tmp/sal-anvil-${PORT}.log" 2>&1 &
  ANVIL_PID=$!
  STARTED=1
  PREEXISTING=0
  if ! wait_rpc; then
    echo "---- anvil log ----" >&2
    tail -n 40 "/tmp/sal-anvil-${PORT}.log" >&2 || true
    return 1
  fi
  local cid
  cid="$(cast chain-id --rpc-url "$RPC")"
  if [ "$cid" != "$expected_id" ]; then
    echo "Fork chain mismatch: got ${cid}, expected ${expected_id}" >&2
    return 1
  fi
}

# Extract gas / address lines only; never dump broadcast JSON (it can contain keys).
summarize_broadcast() {
  local log_file="$1"
  grep -E 'SteppedAgentVaultFactory|USDC |Gas used:|Contract Address:|wrote factory|wrote dapp deployments|==> Chain:|chainId:|USDC verified' "$log_file" || true
}

assert_refused() {
  local label="$1" expected="$2"
  local log="$3" status="$4"
  if [ "$status" -eq 0 ]; then
    echo "FAIL: ${label} should have been refused" >&2
    exit 1
  fi
  if ! grep -q "$expected" "$log"; then
    echo "FAIL: ${label} did not mention ${expected}. Output:" >&2
    cat "$log" >&2
    exit 1
  fi
  echo "    refused as expected (${label})"
}

check_config() {
  python3 -c '
import json, sys
path, chain = sys.argv[1], sys.argv[2]
data = json.load(open(path))
entry = data.get(chain) or data.get(str(int(chain)))
assert entry, data
factory = entry.get("factory") or ""
usdc = entry.get("usdc") or ""
assert factory.startswith("0x") and len(factory) == 42, factory
assert factory.lower() != "0x0000000000000000000000000000000000000000", factory
assert usdc.startswith("0x") and len(usdc) == 42, usdc
print("    deployments.json[%s].factory=%s" % (chain, factory))
print("    deployments.json[%s].usdc=%s" % (chain, usdc))
' "$1" "$2"
}

run_suite() {
  local name="$1" expected_id="$2"
  echo "==> Deploy-script tests on ${name} fork (chain ${expected_id})"
  local cid
  cid="$(cast chain-id --rpc-url "$RPC")"
  if [ "$cid" != "$expected_id" ]; then
    echo "Expected chain ${expected_id}, got ${cid}" >&2
    exit 1
  fi

  echo "-- dry run (no broadcast)"
  local dry_log
  dry_log="$(mktemp /tmp/sal-dry.XXXXXX)"
  RPC_URL="$RPC" ./script/deploy.sh >"$dry_log" 2>&1
  summarize_broadcast "$dry_log"
  grep -q "dry run" "$dry_log"
  rm -f "$dry_log"

  echo "-- deploy.sh --broadcast without CONFIRM_MAINNET must be refused"
  local refuse_log
  refuse_log="$(mktemp /tmp/sal-refuse.XXXXXX)"
  set +e
  CONFIRM_MAINNET= RPC_URL="$RPC" ./script/deploy.sh --broadcast >"$refuse_log" 2>&1
  local st=$?
  set -e
  assert_refused "deploy.sh" "CONFIRM_MAINNET=yes" "$refuse_log" "$st"
  rm -f "$refuse_log"

  echo "-- Deploy.s.sol --broadcast without CONFIRM_MAINNET must revert"
  refuse_log="$(mktemp /tmp/sal-refuse.XXXXXX)"
  set +e
  env -u CONFIRM_MAINNET forge script script/Deploy.s.sol:Deploy \
    --rpc-url "$RPC" --unlocked --sender "$ANVIL_SENDER" --broadcast \
    >"$refuse_log" 2>&1
  st=$?
  set -e
  assert_refused "Deploy.s.sol" "CONFIRM_MAINNET=yes" "$refuse_log" "$st"
  rm -f "$refuse_log"

  echo "-- Deploy.s.sol --broadcast with CONFIRM_MAINNET=yes on the local fork (not a live chain)"
  local dep_log bak
  bak="$(mktemp /tmp/sal-deployments-bak.XXXXXX.json)"
  cp "$CONFIG" "$bak"
  dep_log="$(mktemp /tmp/sal-live.XXXXXX)"
  set +e
  CONFIRM_MAINNET=yes \
    forge script script/Deploy.s.sol:Deploy \
      --rpc-url "$RPC" --unlocked --sender "$ANVIL_SENDER" --broadcast \
      >"$dep_log" 2>&1
  local live_st=$?
  set -e
  if [ "$live_st" -ne 0 ]; then
    echo "FAIL: expected a successful broadcast to the local fork" >&2
    cat "$dep_log" >&2
    mv "$bak" "$CONFIG"
    rm -f "$dep_log"
    exit 1
  fi
  summarize_broadcast "$dep_log"
  if ! check_config "$CONFIG" "$expected_id"; then
    mv "$bak" "$CONFIG"
    rm -f "$dep_log"
    exit 1
  fi
  mv "$bak" "$CONFIG"
  rm -f "$dep_log"
  echo "-- ${name} deploy-script tests passed"
}

if rpc_up; then
  PREEXISTING=1
  echo "==> Port ${PORT} is already in use (chain $(cast chain-id --rpc-url "$RPC")); will not kill it"
fi

echo "==> Checking Ethereum RPC"
if ! cast chain-id --rpc-url "$MAINNET_RPC" >/dev/null 2>&1; then
  echo "Cannot reach Ethereum RPC at the configured URL; cannot run mainnet fork tests." >&2
  exit 1
fi

start_fork "Ethereum mainnet" "$MAINNET_RPC" 1
run_suite "Ethereum mainnet" 1

if [ "$PREEXISTING" = 1 ] && [ "$STARTED" = 0 ]; then
  echo "==> Skipping Base fork: port ${PORT} was already in use and we will not restart it"
  exit 0
fi

echo "==> Checking Base RPC"
if ! cast chain-id --rpc-url "$BASE_RPC" >/dev/null 2>&1; then
  echo "==> Base RPC is not reachable; skipping Base fork deploy tests"
  exit 0
fi

if ! start_fork "Base" "$BASE_RPC" 8453; then
  st=$?
  if [ "$st" = 2 ]; then
    echo "==> Skipping Base fork deploy tests (port busy)"
    exit 0
  fi
  exit "$st"
fi
run_suite "Base" 8453

echo "==> All deploy-script fork tests passed"
