# Piron Pools - Tokenized Fixed-Income Platform

## Project Overview

**Piron Pools** is a tokenized fixed-income platform that enables borderless access to real-world financial instruments. The platform implements two complementary pool architectures: **Flexible Stable Yield Pools** for retail accessibility with NAV-based pricing and liquidity management, and **Single-Asset Pools** for direct institutional investment in specific instruments like Treasury bills, commercial paper, and corporate bonds.

> _"Building the structured finance layer for a unified global money market"_ - Piron Finance Vision

## Core Architecture

Piron Pools supports two distinct pool architectures:

### **1. Flexible Pool System (Primary Focus)**

Piron's main architecture centers around **Flexible Pools** that prioritize liquidity and accessibility:

```
Users deposit stablecoin → Get shares at current NAV → 30-day minimum hold → Flexible exit with queue system
```

**Key Features:**

- **30-day minimum holding period** (as per Piron's flexible pool design)
- **NAV-based pricing** with real-time updates
- **Cross-border accessibility** via stablecoin rails (USDC, USDT, DAI, etc.)
- **Withdrawal queue system** for liquidity management
- **Fee-transparent** user experience (net-of-fees)
- **ERC4626 compliant** for DeFi integrations

### **2. Single-Asset Pool System (Traditional Pools)**

Direct investment pools for specific financial instruments with fixed terms:

```
Users deposit during epoch → SPV invests in specific instrument → Hold until maturity → Redeem principal + yield
```

**Key Features:**

- **Fixed-term investment** in specific instruments (T-bills, commercial paper, bonds)
- **Epoch-based funding** with defined start/end times
- **Two instrument types**: Discounted (T-bills) and Interest-bearing (bonds/notes)
- **Direct instrument exposure** with transparent pricing
- **Coupon payment system** for interest-bearing instruments
- **Emergency withdrawal** during funding phase only
- **Maturity-based redemption** with full returns

**Pool Lifecycle:**

1. **FUNDING** → Pool accepts deposits during epoch
2. **PENDING_INVESTMENT** → Funding complete, awaiting SPV investment
3. **INVESTED** → SPV purchased instrument, pool active
4. **MATURED** → Instrument matured, returns available
5. **EMERGENCY** → Emergency state for proportional refunds

## System Architecture

### Core Contracts

#### **Flexible Pool Infrastructure**

1. **StableYieldPool** - ERC4626 vault with 30-day holding periods and NAV pricing
2. **StableYieldManager** - Advanced business logic for NAV calculation, fee handling, and queue management
3. **StableYieldEscrow** - Secure custody with SPV coordination and fee allocation
4. **ManagedPoolFactory** - Deployment factory for new flexible pools

#### **Single-Asset Pool Infrastructure**

5. **LiquidityPool** - ERC4626 vault for fixed-term instrument investment
6. **Manager** - Business logic for epoch management, SPV coordination, and coupon distribution
7. **PoolEscrow** - Custody contract for single-asset pool funds
8. **PoolFactory** - Deployment factory for new single-asset pools

#### **Shared Infrastructure**

9. **PoolRegistry** - Asset approval authority and unified pool registry
10. **AccessManager** - Role-based access control system
11. **FeeManager** - Comprehensive fee calculation and collection

#### **Type Definitions**

12. **IStableYieldTypes** - Complete type system for flexible pools
13. **IPoolTypes** - Type system for single-asset pools

### System Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          PIRON FLEXIBLE POOLS SYSTEM                           │
└─────────────────────────────────────────────────────────────────────────────────┘

                                    USERS
                                      │
                                      ▼
                        ┌─────────────────────────────┐
                        │     StableYieldPool         │
                        │      (ERC4626 Vault)        │
                        │  • 30-day holding period    │
                        │  • NAV-based pricing        │
                        │  • Cross-border access      │
                        └─────────────┬───────────────┘
                                      │
                                      ▼
                        ┌─────────────────────────────┐
                        │    StableYieldManager       │
                        │   • NAV calculation         │
                        │   • Fee handling            │
                        │   • Queue management        │
                        │   • Instrument tracking     │
                        └─────────────┬───────────────┘
                                      │
                                      ▼
                        ┌─────────────────────────────┐
                        │    StableYieldEscrow        │
                        │   • Secure custody          │
                        │   • SPV coordination        │
                        │   • Fee allocation          │
                        └─────────────┬───────────────┘
                                      │
                                      ▼
                        ┌─────────────────────────────┐
                        │         SPV Layer           │
                        │   • T-bill investments      │
                        │   • Instrument management   │
                        │   • Maturity processing     │
                        └─────────────────────────────┘

                    SHARED INFRASTRUCTURE
        ┌─────────────────┬─────────────────┬─────────────────┐
        │  PoolRegistry   │ AccessManager   │   FeeManager    │
        │ • Asset approval│ • Role control  │ • Fee calculation│
        │ • Pool registry │ • Security      │ • Collection    │
        └─────────────────┴─────────────────┴─────────────────┘
```

## Detailed Flow Documentation

### 1. Pool Creation Flow

**Actors:** Pool Creator (POOL_CREATOR_ROLE)
**Contracts:** ManagedPoolFactory, StableYieldManager, PoolRegistry

```solidity
// Deploy a new flexible pool
ManagedPoolFactory.createStableYieldPool(
    USDC_ADDRESS,                    // Underlying stablecoin
    "Piron USDC Flexible Pool",     // Pool name
    "pUSDC",                        // Pool symbol
    escrowAddress,                  // Pre-deployed escrow
    100e6                           // $100 minimum investment
)
```

**Function Call Sequence:**

1. `ManagedPoolFactory.createStableYieldPool()` - Deploy new StableYieldPool
2. `StableYieldManager.registerPool()` - Register pool with manager
3. `PoolRegistry.registerStableYieldPool()` - Add to unified registry
4. Pool immediately available for deposits

### 2. Deposit Flow

**Actors:** Users
**Contracts:** StableYieldPool, StableYieldManager, StableYieldEscrow

```solidity
// User deposits $1,000 USDC
StableYieldPool.deposit(1000e6, userAddress)
```

**Function Call Sequence:**

1. `StableYieldPool.deposit()` - User entry point
2. `USDC.transferFrom(user, escrow, 1000e6)` - Transfer assets to escrow
3. `StableYieldManager.validateDeposit()` - Process deposit with fee calculation
4. `StableYieldEscrow.allocateDeposit()` - Allocate between reserves and fees
5. `StableYieldPool._mint(user, shares)` - Mint shares based on net deposit

**Fee Handling:**

```solidity
// Example with 0.5% protocol fee
uint256 transactionFee = 1000e6 * 50 / 10000;  // 5 USDC fee
uint256 netDeposit = 1000e6 - 5e6;             // 995 USDC net
uint256 shares = (995e6 * 1e18) / navPerShare; // Shares based on net amount
```

**State Changes:**

- User receives shares based on **net deposit amount** (after fees)
- `lastDepositTime[user] = block.timestamp` (for 30-day holding period)
- Escrow reserves and fee buckets updated

### 3. NAV Calculation

**Actors:** System (view functions)
**Contracts:** StableYieldManager

The NAV system provides real-time pool valuation:

```solidity
// NAV Components
totalNAV = grossAssetValue + poolReserves - accruedFees

// Where:
// grossAssetValue = sum of all instrument current values
// poolReserves = liquid cash available for withdrawals
// accruedFees = time-based management fees
```

**Instrument Valuation:**

- **Discounted Instruments (T-bills)**: Linear appreciation to face value
- **Interest-bearing Instruments**: Face value + accrued interest

### 4. Withdrawal Flow

**Actors:** Users
**Contracts:** StableYieldPool, StableYieldManager, StableYieldEscrow

#### A. Immediate Withdrawal (Sufficient Liquidity)

```solidity
// User redeems 1000 shares
StableYieldPool.redeem(1000, userAddress, userAddress)
```

**Function Call Sequence:**

1. `StableYieldPool.redeem()` - User entry point
2. `_enforceHoldingPeriod(user)` - Check 30-day minimum hold
3. `StableYieldManager.validateWithdrawal()` - Calculate withdrawal value and fees
4. `StableYieldPool._burn(user, shares)` - Burn user shares
5. `StableYieldEscrow.withdraw(user, netAmount)` - Transfer net amount to user

**Fee Calculation:**

```solidity
// User redeems shares worth $1000 gross
uint256 grossValue = (shares * navPerShare) / 1e18;     // $1000
uint256 transactionFee = grossValue * 50 / 10000;      // $5 fee
uint256 netWithdrawal = grossValue - transactionFee;   // $995 to user
```

#### B. Queued Withdrawal (Insufficient Liquidity)

When escrow reserves are insufficient:

1. Withdrawal request queued in `poolQueues[poolAddress]`
2. User receives `WithdrawalRequested` event
3. Operator processes queue when liquidity available via `processWithdrawalQueue()`

### 5. SPV Coordination

**Actors:** SPV (SPV_ROLE), Operators (OPERATOR_ROLE)
**Contracts:** StableYieldManager, StableYieldEscrow

#### Fund Allocation to SPV

```solidity
// Operator allocates $50,000 to SPV for T-bill purchases
StableYieldManager.allocateToSPV(poolAddress, spvAddress, 50000e6)
```

#### Instrument Management

```solidity
// SPV adds new T-bill to pool
StableYieldManager.addInstrument(
    poolAddress,
    IStableYieldTypes.InstrumentType.DISCOUNTED,
    95000e6,        // Purchase price
    100000e6,       // Face value
    maturityDate,   // 90 days from now
    0,              // No coupon rate (T-bill)
    0               // No coupon frequency
)
```

#### Maturity Processing

```solidity
// SPV processes matured instrument
StableYieldManager.matureInstrument(poolAddress, instrumentId)

// SPV returns proceeds to pool
StableYieldManager.receiveSPVMaturity(poolAddress, 100000e6)
```

### 6. Emergency Functions

**Actors:** Operators (OPERATOR_ROLE)
**Contracts:** StableYieldPool

```solidity
// Emergency withdrawal bypassing holding period
StableYieldPool.emergencyRedeem(shares, receiver, owner)

// Pool pause/unpause
StableYieldPool.pause()
StableYieldPool.unpause()
```

## Single-Asset Pool Flows

### 1. Single-Asset Pool Creation

**Actors:** Pool Creator (POOL_CREATOR_ROLE)
**Contracts:** PoolFactory, Manager, PoolRegistry

```solidity
// Deploy a new single-asset pool for specific instrument
PoolFactory.createPool({
    asset: USDC_ADDRESS,                    // Underlying stablecoin
    targetRaise: 1000000e6,                 // $1M target raise
    epochDuration: 7 days,                  // 7-day funding period
    maturityDate: block.timestamp + 90 days, // 90-day T-bill
    instrumentType: InstrumentType.DISCOUNTED,
    discountRate: 500,                      // 5% discount (500 basis points)
    spvAddress: SPV_ADDRESS,                // SPV for instrument purchase
    instrumentName: "US Treasury 90-day Bill",
    minimumFundingThreshold: 8000           // 80% minimum funding
})
```

**State Changes:**

- New LiquidityPool deployed with ERC4626 interface
- PoolEscrow deployed for custody
- Pool registered in PoolRegistry
- Manager initialized with pool configuration
- Pool status set to FUNDING

### 2. Single-Asset Deposit Flow (During Funding)

**Actors:** Retail/Institutional Investors
**Contracts:** LiquidityPool, Manager, PoolEscrow

**Function Call Sequence:**

1. `LiquidityPool.deposit(1000e6, user)` - User deposits $1000 USDC
2. `USDC.transferFrom(user, escrow, 1000e6)` - Transfer to escrow
3. `Manager.handleDeposit()` - Validate and process deposit
4. `PoolEscrow.receiveDeposit()` - Track deposit in escrow
5. `LiquidityPool._mint(user, 1000e18)` - Mint 1:1 shares (during funding)

**Key Characteristics:**

- **1:1 share ratio** during funding phase (1 USDC = 1 share)
- **No fees** during funding (fees apply at instrument level)
- **Immediate liquidity** - can withdraw anytime during funding
- **Epoch deadline** - funding closes at epochEndTime or when target reached

### 3. Epoch Management & Investment Flow

**Actors:** Operators (OPERATOR_ROLE), SPV (SPV_ROLE)
**Contracts:** Manager, PoolEscrow

**Close Epoch:**

```solidity
// When funding period ends or target reached
Manager.closeEpoch(poolAddress)
// Checks: funding threshold met (e.g., 80% of target)
// Result: Status changes to PENDING_INVESTMENT
```

**SPV Investment Process:**

```solidity
// 1. SPV withdraws funds for investment
Manager.withdrawFundsForInvestment(poolAddress, 950000e6) // $950k invested

// 2. SPV confirms actual instrument purchase
Manager.processInvestment(
    poolAddress,
    950000e6,                               // Actual amount invested
    "ipfs://QmProofHash..."                 // Investment proof
)
// Result: Status changes to INVESTED
// For discounted instruments: faceValue calculated automatically
```

### 4. Coupon Payment System (Interest-Bearing Instruments)

**Actors:** SPV (SPV_ROLE), Operators (OPERATOR_ROLE)
**Contracts:** Manager, PoolEscrow, LiquidityPool

**SPV Coupon Payment:**

```solidity
// SPV sends coupon payment to pool
Manager.processCouponPayment(poolAddress, 25000e6) // $25k coupon
// Transfers funds from SPV to escrow
// Updates totalCouponsReceived
```

**Operator Distribution:**

```solidity
// Operator makes coupons available for user claims
Manager.distributeCouponPayment(poolAddress)
// Marks coupons as distributed and claimable
```

**User Coupon Claiming:**

```solidity
// Users claim their proportional coupon share
LiquidityPool.claimCoupon()
// Calculates: (userShares / totalShares) * totalDistributedCoupons
// Transfers coupon payment to user
```

### 5. Maturity & Redemption Flow

**Actors:** SPV (SPV_ROLE), Users
**Contracts:** Manager, LiquidityPool, PoolEscrow

**SPV Maturity Processing:**

```solidity
// SPV returns principal + yield at maturity
Manager.processMaturity(poolAddress, 1050000e6) // $1.05M total return
// For T-bills: face value (purchase price + discount)
// For bonds: principal + final coupon
// Status changes to MATURED
```

**User Redemption:**

```solidity
// Users can withdraw their full entitlement
LiquidityPool.withdraw(assets, receiver, owner)
// Calculates: (userShares / totalShares) * totalMaturityReturns
// Burns user shares and transfers proportional return
```

### 6. Emergency Scenarios

**During Funding Phase:**

```solidity
// Users can withdraw 1:1 during funding
LiquidityPool.withdraw(1000e6, user, user) // Get back $1000 USDC
// Burns shares and releases funds from escrow
```

**Emergency Pool Cancellation:**

```solidity
// Admin cancels pool (regulatory/operational reasons)
Manager.cancelPool(poolAddress)
// Status changes to EMERGENCY
// Users can claim proportional refunds
```

**Emergency Withdrawal:**

```solidity
// Proportional emergency refunds
LiquidityPool.emergencyWithdraw()
// Calculates proportional share of available funds
// Burns all user shares
```

### 7. Single-Asset Pool Example Scenarios

**Scenario A: 90-Day US Treasury Bill**

- **Instrument**: $1M face value T-bill at 5% discount
- **Purchase Price**: $950,000 (5% discount)
- **Funding Target**: $950,000
- **Maturity**: 90 days → Return $1M (5.26% annualized return)
- **User Experience**: Deposit → Hold 90 days → Redeem with 5.26% return

**Scenario B: 6-Month Corporate Bond (Semi-Annual Coupon)**

- **Instrument**: $1M corporate bond, 8% annual coupon
- **Purchase Price**: $1M (par value)
- **Coupon**: $40,000 after 6 months
- **Maturity**: 12 months → Return $1M principal + $80,000 total coupons
- **User Experience**: Deposit → Claim $40k coupon at 6 months → Redeem principal + final coupon at maturity

## Access Control System

### Role Hierarchy

```solidity
bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
bytes32 public constant SPV_ROLE = keccak256("SPV_ROLE");
bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
bytes32 public constant POOL_CREATOR_ROLE = keccak256("POOL_CREATOR_ROLE");
```

### Role Permissions

| Role                  | Permissions                                                  |
| --------------------- | ------------------------------------------------------------ |
| **DEFAULT_ADMIN**     | Grant/revoke roles, update configurations, system management |
| **SPV_ROLE**          | Add/mature instruments, process coupons, return proceeds     |
| **OPERATOR_ROLE**     | Process withdrawal queues, collect fees, allocate to SPV     |
| **POOL_CREATOR_ROLE** | Create new flexible pools                                    |

## Fee Management System

### Integrated Fee Structure

The system implements comprehensive fee handling with automatic collection:

```solidity
// Default fee configuration
FeeConfig({
    protocolFee: 50,         // 0.5% on deposits/withdrawals
    managementFee: 100,      // 1.0% annual management fee
    performanceFee: 200,     // 2.0% on profits
    isActive: true
})
```

### Fee Collection Points

1. **Deposit Fees**: Deducted from deposit amount before share calculation
2. **Withdrawal Fees**: Deducted from withdrawal amount before transfer
3. **Management Fees**: Accrued daily, collected monthly via `collectMonthlyFees()`

## Real-World Example: Piron USDC Flexible Pool

### Pool Configuration

- **Asset**: USDC (6 decimals)
- **Pool Name**: "Piron USDC Flexible Pool"
- **Minimum Investment**: $100
- **Holding Period**: 30 days minimum
- **Target Yield**: 4-6% APY (market dependent)

### User Journey

**Day 1: Deposit**

- User deposits $10,000 USDC
- Protocol fee: $50 (0.5%)
- Net deposit: $9,950
- Shares received: 9,950 (assuming $1.00 NAV)
- Holding period starts

**Day 1-30: Locked Period**

- User cannot withdraw (30-day minimum)
- NAV updates daily based on T-bill performance
- Management fees accrue (1% annually)

**Day 31+: Flexible Exit Available**

- User can withdraw anytime
- Withdrawal fee: 0.5% of gross withdrawal
- Queue system if insufficient liquidity

**Day 365: Full Year**

- Assuming 5% annual return
- User's shares worth: ~$10,447 (5% return - 1% management fee)
- Net withdrawal after fees: ~$10,395

## ERC4626 Compliance

Piron Flexible Pools are fully ERC4626 compliant with enhanced features:

### Standard Functions

- `deposit(assets, receiver)` - Deposit exact asset amount
- `mint(shares, receiver)` - Mint exact share amount
- `withdraw(assets, receiver, owner)` - Withdraw exact asset amount
- `redeem(shares, receiver, owner)` - Redeem exact share amount

### Enhanced Features

- **Holding Period Enforcement**: 30-day minimum on all withdrawals
- **Fee Integration**: Automatic fee deduction with transparent calculation
- **Queue System**: Graceful handling of liquidity constraints
- **NAV-based Pricing**: Real-time valuation updates

### Consistent Outcomes

All functions ensure mathematically consistent results:

```solidity
// Deposit $1000 → Get shares worth $995 (after 0.5% fee)
deposit(1000e6, user) → returns shares worth $995

// Mint shares worth $995 → Pay ~$1005 (including fees)
mint(995_shares, user) → costs ~$1005

// Withdraw $1000 → Burn shares worth ~$1005 (including fees)
withdraw(1000e6, user, user) → burns ~$1005 worth of shares

// Redeem 995 shares → Get ~$990 (after 0.5% fee)
redeem(995_shares, user, user) → returns ~$990
```

## Development & Testing

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
# Run all tests
forge test

# Run with verbose output
forge test -vvv

# Run specific test file
forge test --match-path test/StableYieldManager.t.sol

# Generate gas report
forge test --gas-report
```

## Pool Type Comparison

### Flexible Pools vs Single-Asset Pools

| Feature                | **Flexible Pools**                          | **Single-Asset Pools**                         |
| ---------------------- | ------------------------------------------- | ---------------------------------------------- |
| **Investment Model**   | Multi-instrument portfolio with NAV pricing | Direct investment in specific instrument       |
| **Liquidity**          | Flexible exit after 30-day minimum hold     | Fixed-term until maturity (no early exit)      |
| **Entry/Exit**         | Anytime entry, queue-based exit             | Epoch-based entry, maturity-based exit         |
| **Pricing**            | NAV-based with real-time updates            | 1:1 during funding, proportional at maturity   |
| **Fees**               | Protocol fees on deposits/withdrawals       | No fees during funding, instrument-level costs |
| **Risk Profile**       | Diversified across multiple instruments     | Concentrated single-instrument exposure        |
| **Target Users**       | Retail savers, fintech integrations         | Institutional investors, fixed-term savers     |
| **Minimum Investment** | Configurable (e.g., $100)                   | Pool-specific (e.g., $1000)                    |
| **Yield Source**       | Blended yield from instrument portfolio     | Direct instrument yield (discount/coupon)      |
| **Complexity**         | Higher (NAV calculation, queue management)  | Lower (straightforward instrument tracking)    |

### When to Use Each Pool Type

**Choose Flexible Pools for:**

- ✅ Retail/consumer applications requiring liquidity
- ✅ Fintech integrations needing flexible entry/exit
- ✅ Users wanting diversified exposure without instrument selection
- ✅ Cross-border remittance and savings applications
- ✅ DeFi integrations requiring ERC4626 compatibility

**Choose Single-Asset Pools for:**

- ✅ Institutional investors with specific instrument preferences
- ✅ Users comfortable with fixed-term commitments
- ✅ Direct exposure to high-yield instruments (e.g., emerging market bonds)
- ✅ Transparent, predictable returns with known maturity dates
- ✅ Lower operational complexity and gas costs

### Technical Implementation Differences

**Flexible Pools:**

```solidity
// NAV-based share calculation
shares = (netDepositAmount * 1e18) / navPerShare;

// Queue-based withdrawal system
if (insufficientLiquidity) {
    addToWithdrawalQueue(user, shares, withdrawalValue);
}
```

**Single-Asset Pools:**

```solidity
// 1:1 share ratio during funding
shares = assets; // Simple 1:1 mapping

// Proportional maturity redemption
userEntitlement = (userShares * totalMaturityReturns) / totalShares;
```

### Deployment Strategy

**Phase 1: Single-Asset Pools**

- Simpler implementation for MVP
- Direct institutional onboarding
- Proven fixed-income mechanics

**Phase 2: Flexible Pools**

- Advanced retail features
- Fintech partnership enablement
- Cross-border accessibility focus

### Deployment

**Contract Deployment Order:**

**Shared Infrastructure:**

1. **AccessManager** - Deploy first for role management
2. **PoolRegistry** - Deploy for pool registration
3. **FeeManager** - Deploy for fee management

**Single-Asset Pool System:** 4. **Manager** - Deploy single-asset pool business logic 5. **PoolFactory** - Deploy factory for single-asset pools

**Flexible Pool System:** 6. **StableYieldManager** - Deploy flexible pool business logic 7. **ManagedPoolFactory** - Deploy factory for flexible pools

**Configuration Steps:**

1. Set up roles in AccessManager (Admin, SPV, Operator, Pool Creator)
2. Configure factories in PoolRegistry
3. Approve stablecoins in PoolRegistry (USDC, USDT, DAI, CNGN, etc.)
4. Grant necessary roles to SPV addresses and operators
5. Deploy implementation contracts for pools and escrows
6. Create initial pools:
   - Single-asset pools for specific instruments (T-bills, bonds)
   - Flexible pools for approved stablecoins

## Security Considerations

### Multi-Layer Security

1. **Access Control**: Role-based permissions with granular controls
2. **Holding Periods**: 30-day minimum prevents flash loan attacks
3. **Emergency Mechanisms**: Operator emergency withdrawals and pool pausing
4. **Fee Transparency**: All fees calculated and displayed before execution
5. **Queue System**: Graceful degradation under liquidity stress

### Audit Considerations

- **Reentrancy Protection**: All external calls protected
- **Integer Overflow**: SafeMath patterns throughout
- **Access Control**: Comprehensive role-based security
- **Fee Calculation**: Precise arithmetic with proper rounding

## Cross-Border Accessibility

Piron Flexible Pools enable true borderless investing:

### Supported Stablecoins

- **USDC**: US Dollar exposure
- **USDT**: Tether USD exposure
- **DAI**: Decentralized USD exposure
- **CNGN**: Nigerian Naira exposure
- **Any ERC20**: 6 or 18 decimal stablecoins supported

### Global Access Patterns

- **Nigerian saver** → Turkish Eurobonds via USDC pool
- **US family office** → Ugandan commercial paper via local stablecoin
- **Turkish pension fund** → Nigerian Treasury Bills via CNGN pool

## Future Enhancements

### Planned Features

1. **Multi-Asset Pools**: Diversified instrument portfolios
2. **Automated Rebalancing**: Dynamic cash buffer management
3. **Oracle Integration**: On-chain price feeds for instruments
4. **Governance Token**: Community governance for pool parameters
5. **Insurance Integration**: Coverage for SPV counterparty risk

### Scalability Roadmap

- **Phase 1**: Single-asset flexible pools (Current)
- **Phase 2**: Multi-asset diversified pools
- **Phase 3**: Algorithmic portfolio management
- **Phase 4**: Decentralized SPV coordination

---

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Contact

- **Website**: [piron.finance](https://piron.finance)
- **Documentation**: [docs.piron.finance](https://docs.piron.finance)
- **Twitter**: [@PironFinance](https://twitter.com/PironFinance)
