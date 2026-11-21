# Stepped Agent Line

Backer-funded **stepped** USDC credit lines for AI agents. The backer posts USDC into a vault. Each agent starts at a **starter cap** and, after every **on-time full repayment**, the cap **steps up** by a fixed amount, up to a **max cap**. A missed due date, after a short **grace**, lets anyone mark a **public default** and **freeze** the line. Other apps can read a public `creditHistory` (on-time count, defaults, current tier and cap). v1 is fully backer-collateralized: **no interest, no fee, no pooled lenders**.

> Prototype, **not audited**. It targets **Ethereum mainnet (1)** and **Base (8453)**, plus local anvil (31337) for development. The deploy scripts refuse any other chain and **refuse to broadcast on 1/8453 unless `CONFIRM_MAINNET=yes`**. Nothing has been deployed.

See [SPEC.md](SPEC.md) for the problem, competitors and choices, and [DEPLOY.md](DEPLOY.md) for the deploy runbook.

## Layout
| Path | What |
|---|---|
| `src/SteppedAgentVault.sol` | The vault: stepped caps, term/grace, borrow, repay, freeze on default, public history |
| `src/SteppedAgentVaultFactory.sol` | Deploys one vault per backer, pinned to the factory's USDC (`vaultsOf`) |
| `src/MockUSDC.sol` | 6-decimal test token, used locally only |
| `test/` | Unit, fuzz and invariant tests (Foundry) |
| `test/fork/` | Fork tests against the real Circle USDC, plus a fork test of `Deploy.s.sol` |
| `script/Deploy.s.sol`, `script/DeployConfig.sol` | Deploy script and per-chain config (USDC addresses, live-chain flag) |
| `script/deploy.sh`, `script/verify.sh`, `script/deploy-anvil.sh` | Dry-run/broadcast wrapper, Etherscan v2 verify, local deploy |
| `script/dry-run-fork.sh`, `script/write-web-config.sh` | Anvil-fork dry run (port 8630) and dapp-config writer |
| `web/` | Vite + React + wagmi/viem dapp (Ethereum, Base and anvil) |
| `web/src/deployments.json` | Per-chain factory/USDC addresses written by a successful deploy |

## Contract model
- `openLine(agent, starterCap, stepSize, maxCap, term, grace, allowlistEnabled)` is backer only. `term` is 1–365 days; `grace` is 0–14 days. A new line starts at `starterCap` (tier 0).
- `borrow(to, amount, memo)` is called by the agent. The first borrow of a cycle sets `dueDate = now + term`. Further borrows in the same cycle are allowed until `dueDate`. Checks: active, not frozen, not paused, not past due, allowlist (if enabled), `currentCap`, and vault liquidity.
- `repay(agent, amount)` may be called by anyone, including while paused, after revoke, and after a freeze. Overpayments are capped to the debt. A full repayment at or before `dueDate` steps `currentCap` up by `stepSize`, clamped to `maxCap`, and increments the on-time count and current tier. A full repayment after `dueDate` is late: no step, no automatic default.
- `markDefault(agent)` may be called by anyone after `dueDate + grace` if debt remains. It freezes the line and records a public default. New borrows stay blocked until the backer calls `clearDefault` after a full repayment, which resets cap and tier to the starter. Lifetime counts stay on-chain.
- `revokeAgent(agent)` can be called by the backer or guardian. It bumps the line's epoch so the old allowlist dies; debt and cap progress remain.
- `pause()` can be called by the backer or guardian, and `unpause()` by the backer only. `withdraw()` is backer only, works while paused, and takes unused USDC sitting in the vault.
- `creditHistory(agent)` is a public view for other apps: on-time count, default count, current tier, current/starter/max cap, frozen, active, last default timestamp.
- Ownership uses `Ownable2Step`, so a Safe can be the backer.

## Run the dapp

```bash
cd web
npm install
# optional: cp .env.example .env   # only to override RPCs or factory addresses
npm run dev      # http://localhost:5173
npm run build    # production build
```

The dapp is Vite + React + wagmi/viem, on Ethereum mainnet and Base (and local anvil). Contract addresses come from `web/src/deployments.json`, with optional `VITE_FACTORY_*` / `VITE_USDC_*` overrides in `web/.env`. When the factory address for the selected chain is empty, the page shows a clear **Not deployed yet** state and disables create-vault.

Connect a wallet, switch network, then: create or pick a vault, deposit USDC, open a stepped line, borrow or repay, look up any agent's public credit history, pause, revoke, or mark/clear a default.

## Tests

Needs Foundry (`forge` / `anvil`; this repo expects `~/.foundry/bin` on `PATH`) and Node 20+.

```bash
forge build
forge test              # unit, fuzz, invariant, and anvil deploy-script tests; fork tests skip without a fork
make dry-run-mainnet    # Deploy.s.sol dry-run + CONFIRM_MAINNET guard, on an anvil mainnet fork at port 8630
```

Fork tests (real Circle USDC, plus the deploy-script fork tests). This repo uses **port 8630 only**:

```bash
anvil --port 8630 --fork-url https://ethereum-rpc.publicnode.com   # Ethereum fork
make test-fork-mainnet
# Base, using Foundry's own fork (no extra anvil):
make test-fork-base
```

## Deploy to Ethereum or Base (not done: needs Lef's wallet and OK)

| Chain | Id | USDC (checked on fork: symbol USDC, 6 decimals) |
|---|---|---|
| Ethereum mainnet | 1 | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| Base | 8453 | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

Once the wallet is set (Foundry keystore account, keystore file, or `DEPLOYER_KEY` in a git-ignored `.env`):

```bash
cp .env.example .env && set -a && source .env && set +a
make dry-run-mainnet                 # local anvil fork on port 8630; sends nothing
CONFIRM_MAINNET=yes make deploy-mainnet
CONFIRM_MAINNET=yes make deploy-base
```

A successful broadcast writes the factory address into `web/src/deployments.json` and, if `ETHERSCAN_API_KEY` is set, verifies via the Etherscan v2 API. See [DEPLOY.md](DEPLOY.md) for signer options and `./script/verify.sh`.

- `deploy.sh` and `Deploy.s.sol` both print the chain. Each refuses to broadcast on 1 or 8453 without `CONFIRM_MAINNET=yes`, so the guard holds even if someone calls `forge script` directly.
- Never commit `.env`, keys, or `broadcast/`.

## Local end-to-end (anvil, no keys)

```bash
anvil                                   # terminal 1 (chain 31337)
./script/deploy-anvil.sh                # factory and MockUSDC on a fresh anvil
cd web && npm install && npm run dev
```

The anvil deploy uses anvil's unlocked dev accounts, so no private key is stored anywhere.

## Regenerate ABIs
`forge build && node tools/gen-abi.mjs` writes `web/src/abi.ts`.
