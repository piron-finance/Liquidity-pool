# Piron Pools

Tokenized fixed-income platform enabling borderless access to real-world financial instruments.

## What is Piron Pools?

Piron Pools connects users to treasury bills, bonds, and fixed-income instruments through three pool types:

- **Single Asset Pools** - Direct investment in specific instruments with fixed terms
- **Stable Yield Pools** - Revolving portfolio with NAV-based flexible access
- **Locked Pools** - Fixed deposits with guaranteed APY across multiple tenors

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/)
- Git

### Installation

```bash
git clone https://github.com/piron-finance/piron-pools.git
cd piron-pools
forge install
```

### Build

```bash
forge build
```

### Test

```bash
forge test           # Run all tests
forge test -vvv      # Verbose output
forge test --gas-report  # Gas analysis
```

### Deploy

```bash
# Set environment variables
export RPC_URL=<your_rpc_url>
export PRIVATE_KEY=<deployer_key>

# Deploy
forge script script/DeployUpgradeable.s.sol --rpc-url $RPC_URL --broadcast
```

## Project Structure

```
piron-pools/
├── src/
│   ├── AccessManager.sol              # Role-based access control
│   ├── PoolRegistry.sol               # Central registry & asset approval
│   │
│   ├── Manager.sol                    # Single Asset pool business logic
│   ├── StableYieldManager.sol         # Stable Yield pool business logic
│   ├── LockedPoolManager.sol          # Locked pool business logic
│   │
│   ├── LiquidityPool.sol              # Single Asset ERC4626 vault
│   │
│   ├── managed/
│   │   ├── StableYieldPool.sol        # Stable Yield ERC4626 vault
│   │   └── LockedPool.sol             # Locked Pool ERC4626 vault
│   │
│   ├── escrows/
│   │   ├── PoolEscrow.sol             # Single Asset fund custody
│   │   ├── StableYieldEscrow.sol      # Stable Yield fund custody
│   │   ├── LockedPoolEscrow.sol       # Locked Pool fund custody
│   │   └── YieldReserveEscrow.sol     # Protocol reserve
│   │
│   ├── factories/
│   │   ├── PoolFactory.sol            # Single Asset pool deployment
│   │   └── ManagedPoolFactory.sol     # StableYield & Locked deployment
│   │
│   ├── governance/
│   │   ├── TimelockController.sol     # 72h upgrade delay
│   │   └── UpgradeGuardian.sol        # Emergency controls
│   │
│   ├── interfaces/                    # Contract interfaces
│   │
│   ├── libraries/
│   │   ├── CalculationLibrary.sol     # Single Asset calculations
│   │   ├── ValidationLibrary.sol      # Single Asset validations
│   │   ├── DepositWithdrawalLibrary.sol
│   │   ├── PoolLifecycleLibrary.sol
│   │   ├── StableYieldNAVLibrary.sol  # NAV calculations
│   │   └── LockedPoolLibrary.sol      # Locked pool calculations
│   │
│   └── types/
│       ├── IPoolTypes.sol             # Single Asset types
│       ├── IStableYieldTypes.sol      # Stable Yield types
│       └── ILockedPoolTypes.sol       # Locked Pool types
│
├── script/
│   ├── DeployUpgradeable.s.sol        # Main deployment script
│   └── ...
│
├── test/
│   ├── SingleAssetPool.t.sol
│   ├── StableYieldPool.t.sol
│   ├── LockedPool.t.sol
│   └── ...
│
├── docs/
│   ├── BACKEND_GUIDE.md               # Technical integration guide
│   ├── INTERNAL_DASHBOARD.md          # Admin/SPV dashboard spec
│   ├── USER_DASHBOARD.md              # User dashboard spec
│   └── POOL_TYPES.md                  # Pool comparison
│
├── lib/                               # Dependencies (forge-std, openzeppelin)
├── out/                               # Build artifacts
└── foundry.toml                       # Foundry configuration
```

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      GOVERNANCE                              │
│         AccessManager • TimelockController                  │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────┴──────────────────────────────────┐
│                    INFRASTRUCTURE                            │
│              PoolRegistry • Factories                        │
└──────────────────────────┬──────────────────────────────────┘
                           │
        ┌──────────────────┼──────────────────┐
        │                  │                  │
        ▼                  ▼                  ▼
┌───────────────┐  ┌───────────────┐  ┌───────────────┐
│ Single Asset  │  │ Stable Yield  │  │    Locked     │
│    Manager    │  │    Manager    │  │    Manager    │
│      Pool     │  │      Pool     │  │      Pool     │
│    Escrow     │  │    Escrow     │  │    Escrow     │
└───────────────┘  └───────────────┘  └───────────────┘
```

## Key Features

- **ERC4626 Compliant** - All pools implement standard vault interface
- **Upgradeable** - UUPS proxy pattern with timelock protection
- **Role-Based Access** - Granular permissions via AccessManager
- **Multi-Asset Support** - USDC, USDT, cNGN, and other stablecoins

## Roles

| Role | Purpose |
|------|---------|
| DEFAULT_ADMIN | System configuration, role management |
| OPERATOR_ROLE | Pool operations, queue processing |
| SPV_ROLE | Investment operations |
| POOL_CREATOR_ROLE | Deploy new pools |
| EMERGENCY_ROLE | Pause, emergency actions |

## Configuration

Key settings in `foundry.toml`:

```toml
[profile.default]
optimizer = true
optimizer_runs = 100
via_ir = true
```

## Documentation

Detailed documentation in `/docs/`:

- **BACKEND_GUIDE.md** - Complete technical reference for integration
- **INTERNAL_DASHBOARD.md** - Admin and SPV dashboard specifications
- **USER_DASHBOARD.md** - User-facing dashboard specifications
- **POOL_TYPES.md** - Detailed pool type comparison

## Dependencies

- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) - Security primitives
- [OpenZeppelin Upgradeable](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable) - Proxy patterns
- [Forge Std](https://github.com/foundry-rs/forge-std) - Testing utilities

## License

MIT

## Links

- Website: [piron.finance](https://piron.finance)
- Docs: [docs.piron.finance](https://docs.piron.finance)
