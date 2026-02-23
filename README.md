# Piron Pools

Tokenized fixed-income platform enabling borderless access to real-world financial instruments through on-chain liquidity pools.

## Pool Types

- **Single Asset Pools** — Direct investment in specific instruments with fixed terms, maturity dates, and coupon payments
- **Stable Yield Pools** — Revolving portfolio with NAV-based pricing and flexible deposit/withdrawal
- **Locked Pools** — Fixed deposits across multiple tenors (30/60/90/180/360 days) with guaranteed APY

## Prerequisites

- [Foundry](https://book.getfoundry.sh/)
- Git

## Installation

```bash
git clone https://github.com/piron-finance/piron-pools.git
cd piron-pools
forge install
```

## Build

```bash
forge build
```

For production-optimized builds:

```bash
forge build --profile production
```

Check contract sizes against EIP-170 limit:

```bash
forge build --sizes
```

## Test

```bash
forge test
forge test -vvv
forge test --gas-report
```

198 tests across 5 suites:

| Suite | Tests | Coverage |
|-------|-------|----------|
| SingleAssetPoolTest | 23 | Pool lifecycle, deposits, withdrawals, maturity, coupon payments |
| StableYieldPoolTest | 37 | NAV, shares, yield, holding periods, fee collection, withdrawal queues |
| LockedPoolTest | 56 | Multi-tenor deposits, early exit penalties, interest accrual, rollovers |
| FeeManagerTest | 30 | Fee collection, splits, distribution, YieldReserveEscrow ops |
| IntegrationTest | 52 | Full lifecycle, stress, access control, cross-pool, reserve wiring |

## Deploy

Required environment variables:

```bash
export PRIVATE_KEY=<deployer_private_key>
export RPC_URL=<rpc_endpoint>
export ADMIN_ADDRESS=<admin_wallet>
export MULTISIG_ADMIN_ADDRESS=<multisig_wallet>
export PROPOSER_ADDRESS=<timelock_proposer>
export EXECUTOR_ADDRESS=<timelock_executor>
export CANCELLER_ADDRESS=<timelock_canceller>
export GUARDIAN_ADDRESS=<emergency_guardian>
export SPV_ADDRESS=<spv_wallet>
export OPERATOR_ADDRESS=<operator_wallet>
export EMERGENCY_ADDRESS=<emergency_wallet>
export TREASURY_ADDRESS=<treasury_wallet>
export OPS_WALLET_ADDRESS=<ops_wallet>
```

Optional:

```bash
export BASE_TOKEN_ADDRESS=<usdc_address>
export DEPLOY_MOCK_TOKEN=false
export BASE_TOKEN_NAME="USD Coin"
export BASE_TOKEN_SYMBOL="USDC"
export DEFAULT_FEE_BPS=300
export TREASURY_BPS=5000
export MIN_RESERVE_FLOOR=100000000000
```

Run deployment:

```bash
forge script script/DeployUpgradeable.s.sol --rpc-url $RPC_URL --broadcast --verify
```

The script deploys all contracts, configures roles, links components, and verifies the entire system in a single transaction batch.

## Upgrade Flow

1. Deploy new implementation:

```bash
export TIMELOCK_CONTROLLER=<timelock_address>
export MANAGER_PROXY=<proxy_to_upgrade>
export PROPOSER_ADDRESS=<proposer_wallet>

forge script script/UpgradeManager.s.sol --rpc-url $RPC_URL --broadcast
```

2. Wait 72 hours (timelock delay)

3. Execute upgrade:

```bash
export OPERATION_ID=<scheduled_operation_id>
export TARGET_PROXY=<proxy_address>
export NEW_IMPLEMENTATION=<new_impl_address>
export EXECUTOR_ADDRESS=<executor_wallet>

forge script script/ExecuteUpgrade.s.sol --rpc-url $RPC_URL --broadcast
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        GOVERNANCE                           │
│    AccessManager · TimelockController · UpgradeGuardian     │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────┴──────────────────────────────────┐
│                      INFRASTRUCTURE                         │
│         PoolRegistry · PoolFactory · ManagedPoolFactory     │
│              FeeManager · YieldReserveEscrow                │
└──────────────────────────┬──────────────────────────────────┘
                           │
        ┌──────────────────┼──────────────────┐
        │                  │                  │
        ▼                  ▼                  ▼
┌───────────────┐  ┌───────────────┐  ┌───────────────┐
│  Single Asset │  │ Stable Yield  │  │    Locked     │
│    Manager    │  │    Manager    │  │    Manager    │
│  LiquidityPool│  │StableYieldPool│  │  LockedPool   │
│  PoolEscrow   │  │  SYEscrow     │  │  LPEscrow     │
└───────────────┘  └───────────────┘  └───────────────┘
```

## Project Structure

```
src/
├── AccessManager.sol
├── PoolRegistry.sol
├── FeeManager.sol
├── Manager.sol
├── StableYieldManager.sol
├── LockedPoolManager.sol
├── LiquidityPool.sol
├── managed/
│   ├── StableYieldPool.sol
│   └── LockedPool.sol
├── escrows/
│   ├── PoolEscrow.sol
│   ├── StableYieldEscrow.sol
│   ├── LockedPoolEscrow.sol
│   └── YieldReserveEscrow.sol
├── factories/
│   ├── PoolFactory.sol
│   └── ManagedPoolFactory.sol
├── governance/
│   ├── TimelockController.sol
│   └── UpgradeGuardian.sol
├── interfaces/
│   ├── IFeeManager.sol
│   ├── ILiquidityPool.sol
│   ├── ILockedPoolManager.sol
│   ├── IManager.sol
│   ├── IPoolEscrow.sol
│   ├── IPoolFactory.sol
│   ├── IPoolRegistry.sol
│   └── IYieldReserveEscrow.sol
├── libraries/
│   ├── CalculationLibrary.sol
│   ├── ValidationLibrary.sol
│   ├── DepositWithdrawalLibrary.sol
│   ├── PoolLifecycleLibrary.sol
│   ├── StableYieldNAVLibrary.sol
│   ├── LockedPoolLibrary.sol
│   └── LockedPoolManagerLib.sol
└── types/
    ├── IPoolTypes.sol
    ├── IStableYieldTypes.sol
    └── ILockedPoolTypes.sol

script/
├── DeployUpgradeable.s.sol
├── UpgradeManager.s.sol
└── ExecuteUpgrade.s.sol

test/
├── SingleAssetPool.t.sol
├── StableYieldPool.t.sol
├── LockedPool.t.sol
├── FeeManager.t.sol
├── Integration.t.sol
├── fixtures/BaseTest.sol
└── mocks/MockContracts.sol
```

## Contracts

### Governance

| Contract | Type | Purpose |
|----------|------|---------|
| AccessManager | Immutable | Role-based access control with 24h timelock on role grants |
| TimelockController | Immutable | 72h delay on all contract upgrades |
| UpgradeGuardian | Immutable | Emergency pause and upgrade veto |

### Core (Upgradeable via UUPS)

| Contract | Purpose |
|----------|---------|
| PoolRegistry | Central registry for pools, assets, and SPVs |
| Manager | Single Asset pool business logic |
| StableYieldManager | Stable Yield pool business logic and NAV calculation |
| LockedPoolManager | Locked pool business logic with multi-tenor support |
| FeeManager | Protocol fee collection, split, and distribution |
| YieldReserveEscrow | Protocol reserve for yield, loans, and shortfall coverage |

### Pool Vaults (ERC4626)

| Contract | Purpose |
|----------|---------|
| LiquidityPool | Single Asset vault |
| StableYieldPool | Flexible managed vault with NAV pricing |
| LockedPool | Fixed-term vault with position tracking |

### Escrows

| Contract | Purpose |
|----------|---------|
| PoolEscrow | Single Asset fund custody |
| StableYieldEscrow | Stable Yield fund custody with SPV coordination |
| LockedPoolEscrow | Locked Pool fund custody with interest payments |

### Factories

| Contract | Purpose |
|----------|---------|
| PoolFactory | Deploys Single Asset pools via CREATE2 |
| ManagedPoolFactory | Deploys Stable Yield and Locked pools via CREATE2 |

### Libraries

| Library | Purpose |
|---------|---------|
| CalculationLibrary | Share pricing, NAV math, discount/coupon calculations |
| ValidationLibrary | Input validation for deposits, withdrawals, pool config |
| DepositWithdrawalLibrary | Deposit/withdrawal processing for Single Asset pools |
| PoolLifecycleLibrary | Pool state transitions and lifecycle management |
| StableYieldNAVLibrary | NAV-per-share computation for Stable Yield pools |
| LockedPoolLibrary | Interest math, early-exit penalties, position building |
| LockedPoolManagerLib | Extracted LockedPoolManager logic (rollovers, debt settlement, early exit payments) |

## Contract Sizes

All contracts are within the EIP-170 deployment limit (24,576 bytes):

| Contract | Runtime Size | Margin |
|----------|-------------|--------|
| LockedPoolManager | 22,981 B | 1,595 B |
| StableYieldManager | 24,527 B | 49 B |
| Manager | 24,020 B | 556 B |
| PoolRegistry | 16,055 B | 8,521 B |
| LockedPoolEscrow | 16,406 B | 8,170 B |
| YieldReserveEscrow | 15,076 B | 9,500 B |
| FeeManager | 13,154 B | 11,422 B |
| LockedPool | 13,578 B | 10,998 B |
| StableYieldPool | 12,930 B | 11,646 B |
| ManagedPoolFactory | 12,971 B | 11,605 B |

## Roles

| Role | Purpose |
|------|---------|
| DEFAULT_ADMIN_ROLE | System configuration, fee management, asset approval |
| MULTISIG_ADMIN_ROLE | Role revocation, implementation approval, upgrade authorization |
| OPERATOR_ROLE | Pool operations, queue processing, status management |
| SPV_ROLE | Investment execution, fund allocation |
| POOL_CREATOR_ROLE | Pool deployment (granted to factories and managers) |
| FACTORY_ROLE | Pool creation via factory contracts |
| EMERGENCY_ROLE | Emergency pause (cannot unpause — admin only) |

## Security

- All upgradeable contracts use UUPS proxy pattern with TimelockController (72h delay)
- Role grants after deployment require 24h proposal + multisig execution
- `renounceRole` is disabled across the system
- Emergency pause can be triggered by admin or emergency role; unpause is admin-only
- All ERC20 transfers use SafeERC20
- Reentrancy guards on all state-changing external functions
- Fee collection requires authorized collector (escrow) registration

## Dependencies

- [OpenZeppelin Contracts v5](https://github.com/OpenZeppelin/openzeppelin-contracts)
- [OpenZeppelin Upgradeable v5](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable)
- [Forge Std](https://github.com/foundry-rs/forge-std)

## Configuration

`foundry.toml`:

```toml
[profile.default]
optimizer = true
optimizer_runs = 100
via_ir = true
evm_version = "shanghai"
solc_version = "0.8.22"

[profile.production]
optimizer_runs = 1000
via_ir = true
```

## License

MIT
