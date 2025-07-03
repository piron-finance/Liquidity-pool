# Piron Finance - Tokenized Money Market Securities Platform

## Project Overview

Piron Finance is a decentralized tokenized money market securities platform that allows users to invest in various financial instruments including Treasury Bills (T-bills), Commercial Paper, Corporate Bonds, and Fixed Deposits through ERC4626 vault tokens with rebasing share models.

## Architecture Overview

### Core Components

1. **Factory Contract** - Creates and manages pool deployments
2. **Manager Contract** - Handles pool logic, deposits, withdrawals, and lifecycle management
3. **LiquidityPool Contract** - ERC4626 vault implementation for user interactions
4. **Registry Contract** - Maintains pool metadata and approved assets
5. **Escrow Contract** - Multi-signature fund management and transfers

### Contract Addresses Structure

```
Factory → Creates → [LiquidityPool + Manager + Escrow]
                           ↓
Registry ← Registers ← Pool Information
```

## Financial Instruments Supported

### 1. Discounted Instruments (T-Bills, Commercial Paper)

- **Discount Rate**: Known at pool creation (e.g., 18% for Nigerian commercial paper)
- **Face Value**: Calculated when epoch closes based on actual amount raised
- **Returns**: Generated from discount between purchase price and face value
- **Formula**: `Face Value = Actual Raised / (1 - discount rate)`

### 2. Interest-Bearing Instruments (Bonds, Fixed Deposits)

- **Coupon Structure**: Defined coupon dates and rates
- **Returns**: Generated from periodic coupon payments plus principal repayment
- **Validation**: Coupon dates must be in future, arrays must match in length

## Pool Lifecycle States

### 1. FUNDING

- **Duration**: From pool creation to epoch end time
- **User Actions**: Deposit, withdraw (penalty-free)
- **Share Ratio**: 1:1 (1 asset = 1 share)
- **Requirements**: Must reach minimum 50% of target raise

### 2. PENDING_INVESTMENT

- **Trigger**: Epoch closes with sufficient funds
- **Face Value**: Calculated based on actual raised amount
- **Duration**: Until investment is processed
- **User Actions**: Limited (early withdrawal with penalty)

### 3. INVESTED

- **Trigger**: Investment processed and confirmed
- **Duration**: From investment to maturity date
- **User Actions**: Early withdrawal with 2% penalty
- **Returns**: Accrue over time based on instrument type

### 4. MATURED

- **Trigger**: Maturity date reached and final amount processed
- **User Actions**: Full withdrawal with complete returns
- **Calculation**: Based on face value (discounted) or principal + coupons (interest-bearing)

### 5. EMERGENCY

- **Trigger**: Failed to meet minimum raise or emergency exit
- **User Actions**: Claim proportional refund
- **Refund**: Based on original deposit amount

## Smart Contract APIs

### Factory Contract

#### Create Pool

```solidity
function createPool(
    address asset,
    string memory name,
    string memory symbol,
    PoolConfig memory config,
    address[] memory escrowSigners,
    uint256 requiredConfirmations
) external returns (address pool, address manager, address escrow)
```

**PoolConfig Structure:**

```solidity
struct PoolConfig {
    uint256 targetRaise;        // Target amount to raise
    uint256 epochEndTime;       // Funding period end
    uint256 maturityDate;       // Investment maturity date
    uint256 discountRate;       // For discounted instruments (basis points)
    uint256 faceValue;          // Calculated at epoch close
    InstrumentType instrumentType; // DISCOUNTED or INTEREST_BEARING
    uint256[] couponDates;      // For interest-bearing instruments
    uint256[] couponRates;      // Corresponding coupon rates (basis points)
}
```

### LiquidityPool Contract (ERC4626)

#### Deposit Functions

```solidity
// Standard ERC4626 deposit
function deposit(uint256 assets, address receiver) external returns (uint256 shares)

// Mint specific shares amount
function mint(uint256 shares, address receiver) external returns (uint256 assets)
```

#### Withdrawal Functions

```solidity
// Withdraw specific asset amount
function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares)

// Redeem specific shares amount
function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets)
```

#### Emergency Functions

```solidity
// Claim refund during emergency status
function claimRefund() external

// Emergency withdrawal bypassing normal logic
function emergencyWithdraw() external
```

#### View Functions

```solidity
// Get user's current return value
function getUserReturn(address user) external view returns (uint256)

// Get user's discount earned (discounted instruments)
function getUserDiscount(address user) external view returns (uint256)

// Check if pool is in funding period
function isInFundingPeriod() external view returns (bool)

// Check if pool has matured
function isMatured() external view returns (bool)

// Get time remaining to maturity
function getTimeToMaturity() external view returns (uint256)

// Get expected return at maturity
function getExpectedReturn() external view returns (uint256)
```

### Manager Contract

#### Pool Information

```solidity
// Get pool configuration
function config() external view returns (PoolConfig memory)

// Get current pool status
function status() external view returns (PoolStatus)

// Get total amount raised
function totalRaised() external view returns (uint256)

// Get actual invested amount
function actualInvested() external view returns (uint256)

// Get user's deposit timestamp
function userDepositTime(address user) external view returns (uint256)
```

#### User Calculations

```solidity
// Calculate user's current return
function calculateUserReturn(address user) external view returns (uint256)

// Calculate user's discount earned
function calculateUserDiscount(address user) external view returns (uint256)

// Calculate expected maturity value
function calculateMaturityValue() external view returns (uint256)

// Get user's refund amount (emergency)
function getUserRefund(address user) external view returns (uint256)
```

### Registry Contract

#### Pool Queries

```solidity
// Get pool information
function getPoolInfo(address pool) external view returns (PoolInfo memory)

// Check if pool is registered
function isRegisteredPool(address pool) external view returns (bool)

// Check if pool is active
function isActivePool(address pool) external view returns (bool)

// Get all active pools
function getActivePools() external view returns (address[] memory)

// Get pools by instrument type
function getPoolsByType(string memory instrumentType) external view returns (address[] memory)

// Get pools by maturity range
function getPoolsByMaturityRange(uint256 minMaturity, uint256 maxMaturity) external view returns (address[] memory)
```

**PoolInfo Structure:**

```solidity
struct PoolInfo {
    address manager;
    address escrow;
    address asset;
    address creator;
    string instrumentType;
    uint256 createdAt;
    uint256 maturityDate;
    bool isActive;
}
```

## User Flows

### 1. Pool Creation Flow

1. User calls `Factory.createPool()` with pool configuration
2. Factory creates LiquidityPool, Manager, and Escrow contracts
3. Factory registers pool in Registry
4. Factory initializes Manager with pool configuration
5. Pool enters FUNDING status

### 2. Deposit Flow

1. User approves asset spending to Escrow contract
2. User calls `LiquidityPool.deposit()` or `mint()`
3. Assets transferred to Escrow contract
4. Manager validates deposit and updates state
5. Shares minted to user (1:1 ratio during funding)

### 3. Epoch Close Flow

1. Funding period ends or `closeEpoch()` called
2. Check if minimum raise (50% of target) achieved
3. Calculate face value for discounted instruments
4. Update status to PENDING_INVESTMENT or EMERGENCY

### 4. Investment Flow

1. Admin/SPV processes actual investment
2. Calls `Manager.processInvestment()` with proof
3. Validates investment amount (95-105% tolerance)
4. Updates pool status to INVESTED
5. For discounted instruments: calculates discount earned

### 5. Withdrawal Flow

#### During Funding (Penalty-Free)

1. User calls withdrawal function
2. Manager burns shares and reduces total raised
3. Escrow releases funds to user
4. No penalties applied

#### After Investment (Early Exit)

1. User calls withdrawal function
2. Manager calculates current pool value
3. Applies 2% early withdrawal penalty
4. Burns shares and releases net amount

#### At Maturity (Full Returns)

1. User calls withdrawal function
2. Manager calculates total returns
3. Burns shares and releases full return amount
4. Includes discount/coupon earnings

#### Emergency (Refund)

1. Pool enters EMERGENCY status
2. User calls `claimRefund()` or `emergencyWithdraw()`
3. Receives proportional refund based on original deposits

## Frontend Integration Guide

### Key State Management

#### Pool States to Track

```typescript
enum PoolStatus {
  FUNDING = 0,
  PENDING_INVESTMENT = 1,
  INVESTED = 2,
  MATURED = 3,
  EMERGENCY = 4,
}

enum InstrumentType {
  DISCOUNTED = 0,
  INTEREST_BEARING = 1,
}
```

#### Essential Pool Data

```typescript
interface PoolData {
  address: string;
  name: string;
  symbol: string;
  asset: string;
  status: PoolStatus;
  instrumentType: InstrumentType;
  targetRaise: bigint;
  totalRaised: bigint;
  actualInvested: bigint;
  epochEndTime: number;
  maturityDate: number;
  discountRate: number; // basis points
  faceValue: bigint;
  isActive: boolean;
  userShares: bigint;
  userReturn: bigint;
  userDiscount: bigint;
}
```

### Key Calculations for UI

#### Progress Calculations

```typescript
// Funding progress
const fundingProgress = (totalRaised * 100n) / targetRaise;

// Time remaining in funding
const timeRemaining = epochEndTime - Date.now() / 1000;

// Time to maturity
const timeToMaturity = maturityDate - Date.now() / 1000;
```

#### Return Calculations

```typescript
// Expected APY for discounted instruments
const expectedAPY =
  (discountRate * 365 * 24 * 3600) / (maturityDate - epochEndTime);

// User's share percentage
const userSharePercentage = (userShares * 100n) / totalSupply;
```

### Error Handling

#### Common Error Messages

- `"Manager/not-funding-phase"` - Pool not accepting deposits
- `"Manager/exceeds-target"` - Deposit would exceed target raise
- `"Manager/funding-ended"` - Funding period has ended
- `"Manager/insufficient-allowance"` - Need to approve more tokens
- `"Manager/withdrawal-not-allowed"` - Withdrawal not permitted in current state

### Events to Monitor

#### Pool Events

```solidity
event Deposit(address indexed pool, address indexed sender, address indexed receiver, uint256 assets, uint256 shares);
event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
event StatusChanged(PoolStatus oldStatus, PoolStatus newStatus);
event InvestmentConfirmed(uint256 amount, string proofHash);
event CouponReceived(uint256 amount, uint256 timestamp);
event MaturityProcessed(uint256 finalAmount);
event EmergencyExit(address indexed pool, uint256 timestamp);
```

## Security Considerations

### Multi-Signature Escrow

- All fund transfers require multiple signatures
- Configurable required confirmations
- Separate transfer types for different operations

### Access Controls

- Factory can only initialize pools
- Manager can only be called by registered pools
- Admin functions restricted to authorized addresses

### Validation Checks

- Asset approval validation
- Investment amount tolerance (95-105%)
- Coupon date and rate validation
- Minimum raise requirements

## Testing Scenarios

### Happy Path Testing

1. Create pool → Fund → Close epoch → Invest → Mature → Withdraw
2. Partial funding → Emergency refund
3. Early withdrawal with penalties

### Edge Cases

1. Funding exactly at minimum threshold
2. Investment amount at tolerance boundaries
3. Multiple coupon payments
4. Emergency exit scenarios

## Integration Examples

### Web3 Integration

```typescript
// Connect to pool contract
const poolContract = new ethers.Contract(poolAddress, poolABI, signer);

// Get pool status
const status = await poolContract.status();

// Make deposit
const tx = await poolContract.deposit(amount, userAddress);
await tx.wait();

// Check user return
const userReturn = await poolContract.getUserReturn(userAddress);
```

This documentation provides comprehensive context for frontend development, covering all major flows, contract interactions, and integration patterns needed to build the Piron Finance user interface.
