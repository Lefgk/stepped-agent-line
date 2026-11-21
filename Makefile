# Stepped Agent Line
# Foundry may live in ~/.foundry/bin. Live deploys still need CONFIRM_MAINNET=yes and a signer.
export PATH := $(HOME)/.foundry/bin:$(PATH)

# This worker uses only port 8630 (other apps use other ports).
ANVIL_PORT ?= 8630
MAINNET_RPC_URL ?= https://ethereum-rpc.publicnode.com
BASE_RPC_URL ?= https://mainnet.base.org

.PHONY: help test test-dapp test-fork-deploy test-fork-mainnet test-fork-base dapp-build \
        dry-run-mainnet dry-run-base deploy-mainnet-dry deploy-base-dry deploy-mainnet deploy-base

help:
	@echo "make test                 forge unit/fuzz/invariant tests + dapp build"
	@echo "make test-dapp            production build of the Vite dapp"
	@echo "make test-fork-deploy     deploy-script tests on a local mainnet/Base anvil fork (port $(ANVIL_PORT))"
	@echo "make deploy-mainnet-dry   dry-run factory deploy on Ethereum (no broadcast)"
	@echo "make deploy-base-dry      dry-run factory deploy on Base (no broadcast)"
	@echo "make deploy-mainnet       LIVE Ethereum deploy; requires CONFIRM_MAINNET=yes and a deployer"
	@echo "make deploy-base          LIVE Base deploy; requires CONFIRM_MAINNET=yes and a deployer"
	@echo "See DEPLOY.md."

test:
	forge test
	$(MAKE) test-dapp

test-dapp dapp-build:
	cd web && npm ci --prefer-offline --no-audit --fund=false && npm run build

test-fork-deploy:
	ANVIL_PORT=$(ANVIL_PORT) MAINNET_RPC_URL=$(MAINNET_RPC_URL) BASE_RPC_URL=$(BASE_RPC_URL) ./script/test-deploy-fork.sh

# Full suite + Ethereum fork tests, against a local anvil fork on $(ANVIL_PORT).
test-fork-mainnet:
	@if ! cast chain-id --rpc-url http://127.0.0.1:$(ANVIL_PORT) >/dev/null 2>&1; then \
	  echo "Start a mainnet fork first, e.g. anvil --port $(ANVIL_PORT) --fork-url $(MAINNET_RPC_URL)"; \
	  exit 1; \
	fi
	forge test --fork-url http://127.0.0.1:$(ANVIL_PORT)

test-fork-base:
	forge test --fork-url $(BASE_RPC_URL)

# Simulate Deploy.s.sol on a local anvil fork (port $(ANVIL_PORT)). Sends nothing live.
# Also checks that --broadcast without CONFIRM_MAINNET=yes is refused.
dry-run-mainnet:
	ANVIL_PORT=$(ANVIL_PORT) MAINNET_RPC_URL=$(MAINNET_RPC_URL) ./script/dry-run-fork.sh mainnet

dry-run-base:
	ANVIL_PORT=$(ANVIL_PORT) BASE_RPC_URL=$(BASE_RPC_URL) ./script/dry-run-fork.sh base

# RPC dry run (no local anvil, nothing sent)
deploy-mainnet-dry:
	RPC_URL=$(MAINNET_RPC_URL) ./script/deploy.sh

deploy-base-dry:
	RPC_URL=$(BASE_RPC_URL) ./script/deploy.sh

# LIVE deploy. Requires CONFIRM_MAINNET=yes and DEPLOYER_ACCOUNT (keystore), DEPLOYER_KEYSTORE, or DEPLOYER_KEY.
# Example: CONFIRM_MAINNET=yes DEPLOYER_ACCOUNT=lef make deploy-mainnet
deploy-mainnet:
	RPC_URL=$(MAINNET_RPC_URL) ./script/deploy.sh --broadcast

deploy-base:
	RPC_URL=$(BASE_RPC_URL) ./script/deploy.sh --broadcast
