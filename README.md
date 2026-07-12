User/marketing monorepo: https://github.com/piron-finance/apps
admin/spv monorepo: https://github.com/piron-finance/apps-internal
Backend: https://github.com/piron-finance/piron-backend

# Piron Pools

Institutional-grade on-chain infrastructure for tokenized fixed-income products. Piron Pools connects capital providers with real-world financial instruments — treasury bills, commercial paper, corporate bonds — through permissioned liquidity pools with full lifecycle management.

## Overview

Piron Pools is a modular smart contract protocol built on Ethereum that enables the issuance, management, and settlement of structured fixed-income products entirely on-chain. The system supports multiple pool architectures to accommodate different investment profiles, from single-instrument deals to diversified managed portfolios.

All fund custody is handled through segregated escrow contracts. Capital deployment to Special Purpose Vehicles (SPVs) is tracked end-to-end with on-chain accounting. A protocol-level yield reserve provides liquidity backstopping and shortfall coverage across all pool types.

## Pool Types

### Single Asset Pools
Fixed-term, single-instrument deals. Investors deposit during a funding window; once the target is met, capital is deployed to the designated SPV. Supports both discounted instruments (e.g. T-bills) and interest-bearing instruments with periodic coupon payments. Full principal + yield returned at maturity.

### Stable Yield Pools
Revolving managed portfolios with NAV-based share pricing. Deposits and withdrawals are available on a rolling basis (subject to a configurable holding period). The manager allocates capital across multiple instruments, and the pool's Net Asset Value adjusts as instruments accrue value, pay coupons, or mature. Withdrawal queues ensure orderly redemptions even when liquidity is deployed.

### Locked Pools
Fixed-term deposits across configurable tenors (e.g. 30, 60, 90, 180, 360 days) with guaranteed APY at the time of deposit. Each deposit creates a discrete position with its own maturity schedule. Supports upfront or at-maturity interest payment, auto-rollover, early exit with penalty, and position transfer.

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

**Governance layer** — Role-based access control with time-delayed upgrades and emergency circuit breakers. All contract upgrades require a 72-hour timelock. Role grants require a 24-hour proposal window and multisig execution.

**Infrastructure layer** — Shared services across all pool types: asset registry, pool factories (CREATE2 deterministic deployment), protocol fee management with configurable splits, and a yield reserve that provides liquidity backstopping, shortfall coverage, and cross-pool capital deployment.

**Pool layer** — Each pool type has three components: a Manager (business logic), a Vault (ERC4626 share token), and an Escrow (segregated fund custody). Managers are upgradeable via UUPS proxy; vaults and escrows are deployed per pool.

## Security Model

| Mechanism | Description |
|-----------|-------------|
| UUPS Proxy + Timelock | All upgradeable contracts require a 72-hour delay via TimelockController |
| Multisig Governance | Role revocation, implementation approval, and upgrade authorization require multisig |
| Role Separation | Seven distinct roles with least-privilege access; `renounceRole` is disabled system-wide |
| Emergency Controls | Pause can be triggered by admin or emergency role; unpause is admin-only |
| Fund Segregation | Each pool's funds are held in a dedicated escrow contract, separate from protocol logic |
| Reentrancy Protection | All state-changing external functions are guarded |
| SafeERC20 | All token transfers use OpenZeppelin SafeERC20 |
| Authorized Escrows | Fee collection and reserve operations require explicit escrow registration |

## Governance Roles

| Role | Scope |
|------|-------|
| Default Admin | System configuration, fee parameters, asset and SPV approval |
| Multisig Admin | Role revocation, implementation approval, upgrade authorization |
| Operator | Pool operations, queue processing, maturity management, tier configuration |
| SPV | Capital deployment execution, fund allocation and return |
| Pool Creator | Pool deployment (granted to factories and managers) |
| Factory | Pool creation via factory contracts |
| Emergency | Emergency pause (cannot unpause) |

## Core Contracts

### Managers (Upgradeable)

| Contract | Purpose |
|----------|---------|
| Manager | Single Asset pool lifecycle: funding, investment, maturity, coupon distribution |
| StableYieldManager | Stable Yield pool operations: NAV computation, instrument management, withdrawal queues |
| LockedPoolManager | Locked pool operations: multi-tenor deposits, rollovers, early exit, SPV allocation |

### Vaults (ERC4626)

| Contract | Purpose |
|----------|---------|
| LiquidityPool | Single Asset share token with refund and coupon claim support |
| StableYieldPool | NAV-priced share token with holding period enforcement |
| LockedPool | Position-tracked share token with transfer restrictions |

### Escrows

| Contract | Purpose |
|----------|---------|
| PoolEscrow | Single Asset fund custody and SPV disbursement |
| StableYieldEscrow | Stable Yield fund custody with instrument-level accounting |
| LockedPoolEscrow | Locked Pool fund custody with interest payment and penalty handling |
| YieldReserveEscrow | Protocol-level reserve: yield aggregation, loan facility, treasury sweeps |

### Infrastructure

| Contract | Purpose |
|----------|---------|
| AccessManager | Role-based access control with time-delayed role grants |
| PoolRegistry | Central registry for pools, approved assets, and authorized SPVs |
| FeeManager | Fee collection, configurable splits (treasury/ops/reserve), per-pool overrides |
| PoolFactory | Deterministic deployment of Single Asset pools |
| ManagedPoolFactory | Deterministic deployment of Stable Yield and Locked pools |
| TimelockController | 72-hour delay on contract upgrades |
| UpgradeGuardian | Emergency pause and upgrade veto |

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/)
- Git

### Setup

```bash
git clone https://github.com/piron-finance/piron-pools.git
cd piron-pools
forge install
forge build
```

### Testing

```bash
forge test
```

198 tests across 5 suites covering pool lifecycle, deposits, withdrawals, maturity, NAV pricing, fee collection, early exits, rollovers, SPV allocation, access control, cross-pool operations, and stress scenarios.

### Deployment

Configure environment variables:

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

Deploy:

```bash
forge script script/DeployUpgradeable.s.sol --rpc-url $RPC_URL --broadcast --verify
```

The deployment script handles all contract creation, proxy setup, role configuration, factory registration, and cross-contract wiring in a single atomic batch.

### Upgrades

1. Propose new implementation via `UpgradeManager.s.sol`
2. Wait 72-hour timelock delay
3. Execute upgrade via `ExecuteUpgrade.s.sol`

## Dependencies

- [OpenZeppelin Contracts v5](https://github.com/OpenZeppelin/openzeppelin-contracts)
- [OpenZeppelin Upgradeable v5](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable)
- [Forge Std](https://github.com/foundry-rs/forge-std)

## License

MIT
