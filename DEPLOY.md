# Deploy Stepped Agent Line

Targets: **Ethereum mainnet (1)** and **Base (8453)** only. There is no testnet path. Local anvil (31337) is for development.

Nothing in this repo has been deployed. A live deploy needs Lef's own wallet, ETH on the target chain for gas, and an explicit `CONFIRM_MAINNET=yes`. Do not put a key in a file that can be committed.

## One-time setup

```bash
cp .env.example .env          # git-ignored
# Set MAINNET_RPC_URL and/or BASE_RPC_URL (or RPC_URL).
# Set a deployer in .env, one of:
#   DEPLOYER_ACCOUNT    Foundry keystore account name (preferred)
#   DEPLOYER_KEYSTORE   path to a keystore JSON file
#   DEPLOYER_KEY        private key (env only; never commit)
# Optional: ETHERSCAN_API_KEY for Etherscan v2 verification (one key covers Ethereum and Base).
set -a && source .env && set +a
```

The deployer is never hardcoded. The scripts never echo keys or API keys.

Canonical USDC (checked on every run: symbol `USDC`, 6 decimals):

| Chain | Id | USDC |
|---|---|---|
| Ethereum mainnet | 1 | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| Base | 8453 | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

## Commands

Dry run (no transaction is sent; prints chain, checks USDC, estimates gas):

```bash
make deploy-mainnet-dry
make deploy-base-dry
# or:  RPC_URL=<rpc> ./script/deploy.sh
```

Local anvil-fork dry run (port **8630**) plus a check that `--broadcast` without `CONFIRM_MAINNET=yes` is refused:

```bash
make dry-run-mainnet
make dry-run-base
```

Live deploy (real ETH). Both the shell wrapper and `Deploy.s.sol` refuse unless `CONFIRM_MAINNET` is exactly `yes`:

```bash
CONFIRM_MAINNET=yes make deploy-mainnet
CONFIRM_MAINNET=yes make deploy-base
# or:  CONFIRM_MAINNET=yes RPC_URL=<rpc> ./script/deploy.sh --broadcast
```

If `ETHERSCAN_API_KEY` is set, the broadcast also verifies through the Etherscan v2 API (`foundry.toml` `[etherscan]` entries for chainid 1 and 8453). You can verify later with:

```bash
RPC_URL=<rpc> ./script/verify.sh factory <factoryAddress> <usdcAddress>
RPC_URL=<rpc> ./script/verify.sh vault <vaultAddress> <ownerAddress> <usdcAddress>
```

A successful broadcast writes the factory and USDC addresses into `web/src/deployments.json` (override the path with `DEPLOYMENTS_PATH`). The dapp reads that file; `VITE_FACTORY_*` in `web/.env` can still override it.

## Local anvil (no keys, no funds)

```bash
anvil                                 # terminal 1, chain 31337
./script/deploy-anvil.sh              # uses anvil's unlocked dev account #0
cd web && npm install && npm run dev  # http://localhost:5173
```

## What gets deployed

One `SteppedAgentVaultFactory`, constructed with the chain's canonical USDC (or a MockUSDC on anvil). Users then call `createVault()` (the caller becomes the vault backer/owner). The factory deploy is the only step this script performs.

## Safety

- `CONFIRM_MAINNET=yes` is required for any broadcast on chain 1 or 8453, even if someone calls `forge script --broadcast` directly.
- The contracts are a prototype and **not audited**. Do not deposit funds you cannot afford to lose.
- Never commit `.env`, keystores, or `broadcast/` (they are git-ignored).
