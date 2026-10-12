-include .env
export

SCRIPT      := script/DeployUpgradeable.s.sol:DeployUpgradeable
FORGE_FLAGS := --broadcast --slow

# ── Deploy all funded testnets in one go ──────────────────────────────────────

deploy-all:
	@mkdir -p deployments
	forge script $(SCRIPT) --rpc-url celo_sepolia $(FORGE_FLAGS) --resume --private-key $(PRIVATE_KEY)
	forge script $(SCRIPT) --rpc-url arbitrum_sepolia $(FORGE_FLAGS)
	forge script $(SCRIPT) --rpc-url optimism_sepolia $(FORGE_FLAGS) --resume --private-key $(PRIVATE_KEY)
	@echo "" > deployments/all-chains.txt
	@for f in deployments/[0-9]*.txt; do cat "$$f" >> deployments/all-chains.txt; done
	@echo "All deployments complete. Addresses written to deployments/all-chains.txt"

# ── Needs funding before running ──────────────────────────────────────────────
# deploy-plume-testnet  — RPC unreachable, check back later
# deploy-lisk-sepolia   — 0 ETH, fund 0xFeed27... at faucet.sepolia-api.lisk.com

# ── Individual chains ─────────────────────────────────────────────────────────

deploy-base-sepolia:
	@mkdir -p deployments
	forge script $(SCRIPT) --rpc-url base_sepolia $(FORGE_FLAGS)

deploy-arbitrum-sepolia:
	@mkdir -p deployments
	forge script $(SCRIPT) --rpc-url arbitrum_sepolia $(FORGE_FLAGS)

deploy-celo-sepolia:
	@mkdir -p deployments
	forge script $(SCRIPT) --rpc-url celo_sepolia $(FORGE_FLAGS) --resume --private-key $(PRIVATE_KEY)

deploy-optimism-sepolia:
	@mkdir -p deployments
	forge script $(SCRIPT) --rpc-url optimism_sepolia $(FORGE_FLAGS)

deploy-plume-testnet:
	@mkdir -p deployments
	forge script $(SCRIPT) --rpc-url plume_testnet $(FORGE_FLAGS)

deploy-lisk-sepolia:
	@mkdir -p deployments
	forge script $(SCRIPT) --rpc-url lisk_sepolia $(FORGE_FLAGS)

deploy-arc-testnet:
	@mkdir -p deployments
	forge script $(SCRIPT) --rpc-url arc_testnet $(FORGE_FLAGS)

# Robinhood is an Arbitrum-Orbit-style chain: forge's default gas estimate
# undershoots L1 data-gas, so bump the multiplier (you only pay for gas used).
deploy-robinhood-testnet:
	@mkdir -p deployments
	forge script $(SCRIPT) --rpc-url robinhood_testnet $(FORGE_FLAGS) --gas-estimate-multiplier 400

# Monad prices cold storage and account access above Ethereum, so forge's own simulation
# under-estimates gas there and small configuration calls run out. --skip-simulation makes
# forge take each transaction's estimate from the Monad node instead. Monad also charges
# for the gas LIMIT, not the gas used, so don't raise the multiplier: the padding is paid for.
deploy-monad-testnet:
	@mkdir -p deployments
	forge script $(SCRIPT) --rpc-url monad_testnet $(FORGE_FLAGS) --skip-simulation

# ── Dry-run (no broadcast) ────────────────────────────────────────────────────

simulate-all:
	forge script $(SCRIPT) --rpc-url celo_sepolia -vvvv
	forge script $(SCRIPT) --rpc-url arbitrum_sepolia -vvvv
	forge script $(SCRIPT) --rpc-url optimism_sepolia -vvvv

# ── Helpers ───────────────────────────────────────────────────────────────────

build:
	forge build

test:
	forge test -vv

.PHONY: build test deploy-all simulate-all \
	deploy-base-sepolia deploy-arbitrum-sepolia deploy-celo-sepolia \
	deploy-optimism-sepolia deploy-plume-testnet deploy-lisk-sepolia \
	deploy-arc-testnet deploy-robinhood-testnet deploy-monad-testnet

# ---------------------------------------------------------------- multi-runtime
#
# The Stellar and Solana implementations live in their own repository, ../../piron-rust.
# Solidity here is the reference; that repo follows it and tracks drift with `make parity`.
# Nothing in it writes to src/.
