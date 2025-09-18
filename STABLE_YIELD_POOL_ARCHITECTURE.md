# Stable Yield Pools - Technical Architecture v1.1

## Overview

Stable Yield Pools are **composable, currency-agnostic** managed investment products that aggregate short-term government bills (≤6 months). The architecture supports plug-and-play deployment across any approved stablecoin (CNGN, KES, USDT, USDC, etc.) with professional NAV-based pricing, enterprise-grade SPV integration, and separated business logic for maintainability and scalability.

## Core Components

### 1. **StableYieldPool.sol** - Simple ERC4626 Vault

- **Purpose**: Simple vault that delegates all business logic to StableYieldManager
- **Type**: UUPS Upgradeable ERC4626 Vault (currency-agnostic)
- **Key Features**:
  - ERC4626 compliant (deposit, withdraw, redeem, mint)
  - Currency-agnostic (works with any approved stablecoin)
  - Delegates all business logic to StableYieldManager
  - Professional NAV-based share pricing
  - Minimal logic for maximum composability

### 2. **StableYieldManager.sol** - Core Business Logic Engine

- **Purpose**: Currency-agnostic business logic for all managed pool operations
- **Type**: UUPS Upgradeable business logic engine
- **Key Features**:
  - Professional NAV calculation and share pricing
  - Tenor-based position management (90d/180d/270d/360d)
  - Queue-based withdrawal processing with penalties
  - Pool-level cash reserve management (10%+ of AUM)
  - Enterprise SPV coordination for rolling T-bill investments
  - Dynamic rebalancing across T-bill maturities

### 3. **YieldCalculator.sol** - Mathematical Engine

- **Purpose**: Sophisticated yield mathematics for display and projections
- **Type**: UUPS Upgradeable calculation library
- **Key Features**:
  - Pool-weighted APY calculation: `APY_pool = Σ(w_i × APY_i)`
  - Tenor-specific APY: `APY_L = ((1 + APY_pool)^(L/365) - 1) × 365/L`
  - Daily NAV accrual: `NAV = T-bills + Cash + AccruedInterest - Fees`
  - Early exit penalty calculation

### 4. **ManagedPoolEscrow.sol** - Secure Fund Custody

- **Purpose**: Asset-agnostic custody with SPV integration
- **Type**: UUPS Upgradeable with emergency controls
- **Key Features**:
  - Secure custody of any approved stablecoin
  - Pool-level cash buffer management
  - SPV coordination for T-bill investments
  - Laddered allocation maintenance (50%/30%/20%)
  - Emergency pause/unpause functionality

### 5. **ManagedPoolFactory.sol** - Plug-and-Play Deployment

- **Purpose**: Deploy composable managed pools for any approved asset
- **Type**: UUPS Upgradeable factory with flexible configuration
- **Key Features**:
  - Completely composable deployment via PoolDeploymentConfig
  - Asset-agnostic (CNGN, KES, USDT, USDC, etc.)
  - Automatic escrow deployment and linking
  - Integration with PoolRegistry for asset approval
  - SPV configuration per deployment

### 6. **PoolRegistry.sol** - Asset Approval Authority

- **Purpose**: Central authority for approved assets and metadata
- **Type**: Enhanced registry with asset management
- **Key Features**:
  - Asset approval system with metadata (country, region, name)
  - Frontend display information provider
  - Validation authority for all deployments
  - Unified registry for both single-asset and managed pools

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                   USER SELECTS COUNTRY POOL                     │
│    [Nigeria Pool] [Dollar Pool] [Turkey Pool] [Kenya Pool]     │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│              StableYieldPool.sol (Country-Specific)            │
│                    (ERC4626 Vault Logic)                       │
│  • User selects tenor (90d/180d/270d/360d)                    │
│  • Tenor-specific APY calculation                             │
│  • Early exit with penalties (30-day minimum)                 │
│  • Compound/withdraw choice at maturity                       │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                 ManagedPoolEscrow.sol                          │
│                  (Secure Fund Custody)                         │
│  • stablecoin(depends on country CNGN, KES, USDT) custody and transfers                                  │
│  • Laddered T-bill allocation                                 │
│  • Cash buffer for early exits                                │
│  • Rolling reinvestment within country                        │
└─────────────────────────────────────────────────────────────────┘
                                │
                    ┌───────────┼───────────┐
                    ▼           ▼           ▼
          ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
          │ Short-term  │ │ Medium-term │ │ Long-term   │
          │  T-bills    │ │  T-bills    │ │  T-bills    │
          │ (30-90d)    │ │ (90-180d)   │ │ (180-365d)  │
          │   50%       │ │    30%      │ │    20%      │
          └─────────────┘ └─────────────┘ └─────────────┘
                    │           │           │
                    └───────────┼───────────┘
                                ▼
                    ┌─────────────────────────┐
                    │    Country SPV Custody  │
                    │  (Nigerian T-bills, or  │
                    │   US T-bills, etc.)     │
                    └─────────────────────────┘
```

## Fund Flow Architecture

### **Deposit Flow (New v1.1):**

```
1. User selects: Piron Nigeria Pool + 180-day tenor
2. YieldCalculator shows: "8.9% APY for 180 days"
3. User deposits 1000 USDC + selects "Compound at maturity"
4. StableYieldPool transfers stablecoin to ManagedPoolEscrow
5. StableYieldPool mints shares with 180-day lock
6. ManagedPoolEscrow allocates via laddered strategy:
   - 500 USDC → Nigerian short-term T-bills (30-90d)
   - 300 USDC → Nigerian medium-term T-bills (90-180d)
   - 200 USDC → Nigerian long-term T-bills (180-365d)
7. Daily yield accrual: AccruedValue = Principal × (1 + DailyRate)^days
```

### **Early Exit Flow (New v1.1):**

```
1. User requests early exit after 45 days (minimum 30 days met)
2. StableYieldPool calculates: AccruedValue = 1000 × (1 + DailyRate)^45
3. Apply penalty: FinalAmount = AccruedValue × (1 - 0.03) // 3% penalty
4. Check escrow cash buffer for immediate settlement (T+0/1)
5. If insufficient liquidity → Add to withdrawal queue
6. Process queue when T-bills mature or external capital added
7. Penalty fees go to protocol revenue
8. User receives: Submit → Queue → Processing → Claim (up to 7 days)
```

### **Maturity & Reinvestment Flow (New v1.1):**

```
1. User's 180-day lock period ends
2. StableYieldPool calculates final value with full yield accrual
3. Check user's maturity preference:
   a) COMPOUND: Roll funds into new 180-day lock automatically
   b) WITHDRAW: Transfer final amount to user wallet
4. For compounding: Reinvest into new laddered T-bills
5. For withdrawal: Process via escrow cash buffer
6. Continuous laddered reinvestment maintains pool liquidity
```

## Key Calling Sequences

### **Pool Creation:**

```solidity
1. ManagedPoolFactory.createStableYieldPool()
   ├── Deploy ManagedPoolEscrow proxy
   ├── Deploy StableYieldPool proxy
   ├── Link pool to escrow
   ├── Register with PoolRegistry
   └── Return pool address
```

### **NAV Calculation:**

```solidity
1. StableYieldPool.totalAssets()
   └── NAVCalculator.calculateManagedPoolNAV()
       ├── Get underlying pools value
       ├── Calculate accrued interest (time-based)
       ├── Add cash buffer
       ├── Subtract pending withdrawals
       └── Return total NAV
```

### **Deposit Process:**

```solidity
1. StableYieldPool.deposit(assets, receiver)
   ├── Transfer USDC from user to escrow
   ├── Update cash buffer
   ├── Calculate shares based on current NAV
   ├── Mint shares to receiver
   └── Emit Deposit event
```

### **Withdrawal Window Management:**

```solidity
1. StableYieldPool.requestWithdrawal(shares)
   ├── Require withdrawal window is open
   ├── Update user's pending withdrawals
   ├── Update window's total requested
   └── Emit WithdrawalRequested event

2. StableYieldPool.processWithdrawals() [Operator only]
   ├── Calculate total assets needed
   ├── Process withdrawals from escrow
   ├── Handle pro-rata if insufficient liquidity
   ├── Schedule next withdrawal window
   └── Emit WithdrawalProcessed events
```

## Security Architecture

### **Separation of Concerns:**

- **StableYieldPool**: User interface and business logic
- **ManagedPoolEscrow**: Secure fund custody
- **NAVCalculator**: Isolated calculation engine
- **Underlying Pools**: Individual instrument exposure

### **Access Control:**

- **Users**: Deposit, withdraw (during windows), view balances
- **Operators**: Process withdrawals, execute reinvestments, rebalance
- **Admins**: Upgrade contracts, emergency controls, add underlying pools
- **Timelock**: Authorize upgrades (24-48 hour delay)

### **Emergency Controls:**

- **Emergency Pause**: Stop all operations except viewing
- **Emergency Withdraw**: Admin can withdraw all funds to pool (last resort)
- **Upgrade Mechanism**: UUPS with timelock authorization

## Gas Optimization

### **Storage Patterns:**

- **Packed structs** for withdrawal windows and pool data
- **Mapping-based enumeration** instead of arrays for managed pools
- **Single storage reads** with memory caching in functions

### **Batch Operations:**

- **Batch reinvestment** across multiple underlying pools
- **Batch withdrawal processing** for multiple users
- **Single NAV calculation** for multiple operations

## Integration Points

### **With Existing System:**

- **Manager.sol**: Manages underlying single-asset pools
- **PoolRegistry.sol**: Registers and tracks all pools
- **AccessManager.sol**: Unified role-based permissions
- **PoolEscrow.sol**: Individual pool escrows for underlying assets

### **External Dependencies:**

- **OpenZeppelin UUPS**: Upgrade pattern
- **ERC4626**: Vault standard compliance
- **SPV Custody**: Real-world asset custody

## Deployment Sequence

```
1. Deploy implementation contracts:
   ├── StableYieldPool implementation
   ├── ManagedPoolEscrow implementation
   └── NAVCalculator implementation

2. Deploy ManagedPoolFactory with implementations

3. Create first Stable Yield Pool:
   ├── Configure underlying pools (US, NG, KE)
   ├── Set allocation weights (40%, 30%, 20%, 10%)
   ├── Deploy via factory
   └── Register with existing system

4. Initialize operations:
   ├── Seed initial liquidity
   ├── Set up operator roles
   ├── Schedule first withdrawal window
   └── Begin accepting user deposits
```

## Monitoring & Maintenance

### **Key Metrics:**

- **NAV Accuracy**: ±0.1% target vs underlying pools
- **Withdrawal Fulfillment**: >95% of requests fulfilled
- **Cash Buffer Ratio**: 5-15% of total assets
- **Geographic Allocation**: Within ±5% of targets

### **Operational Tasks:**

- **Daily**: NAV calculation and reporting
- **Weekly**: Cash buffer rebalancing
- **Quarterly**: Withdrawal window processing
- **As needed**: Rolling reinvestment, emergency responses

---

_This architecture provides a secure, scalable foundation for managed pool operations while maintaining compatibility with the existing Piron protocol infrastructure._
