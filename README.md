# Piron Pools

## Project Overview

**Piron Pools** is the liquidity pool for Piron finance that enables collective investment in off-chain financial instruments (Treasury Bills, Corporate Bonds, etc.) through on-chain liquidity pools. The system bridges traditional finance with DeFi, allowing users to earn fixed returns from real-world assets.

## Core Concept

```
Users deposit USDC → Pool collects funds → SPV invests in real instruments → Users earn returns at maturity
```

**Example:**

- Pool target: $100,000 for 90-day Treasury Bills (18% discount)
- Users deposit USDC during funding period
- SPV invests $100,000 to buy $121,951 face value Treasury Bills
- At maturity: Users receive $121,951 total (21.95% APY)

## System Architecture

### Core Contracts

1. **PoolFactory** - Creates new investment pools
2. **LiquidityPool** - ERC4626 vault for user deposits/withdrawals
3. **Manager** - Core business logic and pool state management
4. **PoolEscrow** - Secure custody of funds (single manager control)
5. **AccessManager** - Role-based access control
6. **PoolRegistry** - Pool registration and discovery
7. **FeeManager** - Fee calculation (standalone, not integrated)
8. **PoolOracle** - Investment proof verification (optional, not implemented)

### System Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                                PIRON POOLS SYSTEM                               │
└─────────────────────────────────────────────────────────────────────────────────┘

┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Users     │    │ Pool Factory│    │ Pool Registry│   │Access Manager│
│             │    │             │    │             │    │             │
└──────┬──────┘    └──────┬──────┘    └──────┬──────┘    └──────┬──────┘
       │                  │                  │                  │
       │ 1. Deposit       │ 2. Create Pool   │ 3. Register     │ 4. Manage Roles
       │                  │                  │                  │
       ▼                  ▼                  ▼                  ▼
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│Liquidity    │◄──►│   Manager   │◄──►│   Escrow    │◄──►│ Fee Manager │
│Pool (ERC4626)│   │             │    │ (Single Mgr)│    │(Standalone) │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
       ▲                  ▲                  ▲                  ▲
       │                  │                  │                  │
       │ 5. Withdraw      │ 6. Process       │ 7. Release      │ 8. Calculate Fees
       │                  │    Investment    │    Funds        │    (Manual)
       ▼                  ▼                  ▼                  ▼
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Frontend  │    │     SPV     │    │Pool Oracle  │    │  Treasury   │
│             │    │ (Off-chain) │    │(Not Impl.)  │    │             │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
```

## Pool Lifecycle & Status Flow

### Pool Status States

```solidity
enum PoolStatus {
    FUNDING,           // 0 - Accepting user deposits
    PENDING_INVESTMENT,// 1 - Epoch closed, awaiting SPV investment
    INVESTED,          // 2 - SPV has invested, earning returns
    MATURED,           // 3 - Investment matured, users can withdraw
    EMERGENCY          // 4 - Emergency state, refunds available
}
```

### Status Transition Flow

```
FUNDING → PENDING_INVESTMENT → INVESTED → MATURED
   ↓              ↓               ↓
EMERGENCY ← EMERGENCY ← EMERGENCY
```

## Detailed Flow Documentation

### 1. Pool Creation Flow

**Actors:** Admin, Pool Creator
**Contracts:** PoolFactory, Manager, PoolRegistry, AccessManager

```solidity
// Step 1: Admin creates pool
PoolFactory.createPool(PoolConfig{
    asset: USDC_ADDRESS,
    instrumentType: DISCOUNTED,
    instrumentName: "US Treasury 90-Day Bills",
    targetRaise: 100000e6,      // $100,000 USDC
    epochDuration: 7 days,      // 1 week funding period
    maturityDate: block.timestamp + 90 days,
    discountRate: 1800,         // 18% discount (basis points)
    spvAddress: SPV_ADDRESS,
    couponDates: [],            // Empty for discounted instruments
    couponRates: []             // Empty for discounted instruments
})
```

**Function Call Sequence:**

1. `PoolFactory.createPool()` - Creates new LiquidityPool and PoolEscrow contracts
2. `PoolRegistry.registerPool()` - Registers pool in registry
3. `Manager.initializePool()` - Initializes pool configuration
4. Escrow configured with single manager control

**Events Emitted:**

- `PoolCreated(pool, manager, asset, instrumentName, targetRaise, maturityDate)`
- `PoolRegistered(pool, poolInfo)`

### 2. Deposit Flow

**Actors:** Users
**Contracts:** LiquidityPool, Manager, PoolEscrow
**Status:** FUNDING

```solidity
// Step 1: User deposits USDC
LiquidityPool.deposit(1000e6, userAddress) // Deposit $1,000
```

**Function Call Sequence:**

1. `LiquidityPool.deposit()` - User entry point
2. `USDC.transferFrom(user, escrow, amount)` - Transfer USDC to escrow
3. `Manager.handleDeposit()` - Process deposit logic
4. `PoolEscrow.receiveDeposit()` - Track deposit in escrow
5. `LiquidityPool._mint(user, shares)` - Mint pool shares to user

**State Changes:**

- `poolTotalRaised[pool] += amount`
- `poolUserDepositTime[pool][user] = block.timestamp`
- User receives ERC4626 shares representing their investment

**Events Emitted:**

- `Deposit(liquidityPool, sender, receiver, assets, shares)`

### 3. Epoch Close Flow

**Actors:** Operator
**Contracts:** Manager
**Status:** FUNDING → PENDING_INVESTMENT

```solidity
// Step 1: Operator closes funding epoch
Manager.closeEpoch(poolAddress)
```

**Function Call Sequence:**

1. `Manager.closeEpoch()` - Check if epoch ended and minimum raise met
2. `Manager._calculateFaceValue()` - Calculate face value for discounted instruments
3. `Manager._updateStatus()` - Update pool status

**Business Logic:**

```solidity
uint256 amountRaised = poolTotalRaised[pool];
uint256 minimumRaise = targetRaise * 50 / 100; // 50% minimum

if (amountRaised >= minimumRaise) {
    if (instrumentType == DISCOUNTED) {
        faceValue = (amountRaised * 10000) / (10000 - discountRate);
    }
    status = PENDING_INVESTMENT;
} else {
    status = EMERGENCY; // Refund users
}
```

**Events Emitted:**

- `StatusChanged(FUNDING, PENDING_INVESTMENT)`

### 4. Investment Processing Flow

**Actors:** SPV
**Contracts:** Manager, PoolEscrow
**Status:** PENDING_INVESTMENT → INVESTED

```solidity
// Step 1: SPV withdraws funds for investment
Manager.withdrawFundsForInvestment(poolAddress, amount)

// Step 2: SPV processes investment
Manager.processInvestment(poolAddress, actualAmount, "proof-hash")
```

**Function Call Sequence:**

1. `Manager.withdrawFundsForInvestment()` - SPV withdraws funds from escrow
2. `PoolEscrow.withdrawForInvestment()` - Release funds to SPV
3. `Manager.processInvestment()` - Process SPV investment confirmation
4. `Manager._validateSlippageProtection()` - Validate investment amount (±5% tolerance)
5. `Manager._updateStatus()` - Update to INVESTED status

**Business Logic:**

```solidity
uint256 expectedAmount = poolTotalRaised[pool];
// Fixed 5% slippage protection (hardcoded)
uint256 minAmount = (expectedAmount * 9500) / 10000; // 5% below expected
uint256 maxAmount = (expectedAmount * 10500) / 10000; // 5% above expected
require(actualAmount >= minAmount && actualAmount <= maxAmount, "SlippageProtectionTriggered");

if (instrumentType == DISCOUNTED) {
    uint256 totalDiscount = faceValue - actualAmount;
    poolTotalDiscountEarned[pool] = totalDiscount;
}
```

**Events Emitted:**

- `SPVFundsWithdrawn(pool, amount, transferId)`
- `InvestmentConfirmed(actualAmount, proofHash)`
- `StatusChanged(PENDING_INVESTMENT, INVESTED)`

### 5. Withdrawal Flow

**Actors:** Users
**Contracts:** LiquidityPool, Manager, PoolEscrow
**Status:** Depends on pool status

#### A. Funding Period Withdrawal (Penalty-Free)

```solidity
// User withdraws during funding period
LiquidityPool.withdraw(1000e6, userAddress, userAddress)
```

**Function Call Sequence:**

1. `LiquidityPool.withdraw()` - User entry point
2. `Manager.handleWithdraw()` - Route to appropriate handler
3. `Manager._handleFundingWithdrawal()` - Process funding withdrawal
4. `LiquidityPool.burnShares()` - Burn user shares
5. `PoolEscrow.releaseFunds()` - Release USDC to user

**Business Logic:**

```solidity
// No penalties during funding period
shares = assets; // 1:1 ratio
poolTotalRaised[pool] -= assets;
```

#### B. Early Withdrawal (BLOCKED)

**IMPORTANT:** Early withdrawals are **completely blocked** during INVESTED status.

```solidity
// User attempts withdrawal after investment
LiquidityPool.withdraw(1000e6, userAddress, userAddress)
// REVERTS with "WithdrawalNotAllowed()"
```

The current implementation **does not support** early withdrawals with penalties during the INVESTED phase.

#### C. Maturity Withdrawal (Full Returns)

```solidity
// User withdraws at maturity
LiquidityPool.withdraw(userShares, userAddress, userAddress)
```

**Function Call Sequence:**

1. `LiquidityPool.withdraw()` - User entry point
2. `Manager._handleMaturedWithdrawal()` - Process maturity withdrawal
3. `Manager._calculateTotalReturns()` - Calculate user's share of returns
4. `LiquidityPool.burnShares()` - Burn all user shares
5. `PoolEscrow.releaseFunds()` - Release full returns to user

**Return Calculation:**

```solidity
function _calculateTotalReturns(address pool, PoolConfig storage config) internal view returns (uint256) {
    if (config.instrumentType == DISCOUNTED) {
        return config.faceValue; // Full face value
    } else {
        // Interest-bearing: principal + undistributed coupons
        uint256 undistributedCoupons = poolTotalCouponsReceived[pool] - poolTotalCouponsDistributed[pool];
        return poolActualInvested[pool] + undistributedCoupons;
    }
}
```

### 6. Maturity Processing Flow

**Actors:** SPV
**Contracts:** Manager, PoolEscrow
**Status:** INVESTED → MATURED

```solidity
// Step 1: SPV processes maturity
Manager.processMaturity(poolAddress, 121951e6) // $121,951 received
```

**Function Call Sequence:**

1. `Manager.processMaturity()` - Process instrument maturity
2. `Manager._validateSlippageProtection()` - Validate maturity amount (±5% tolerance)
3. `PoolEscrow.trackMaturityReturn()` - Track maturity funds
4. `Manager._updateStatus()` - Update to MATURED status

**Business Logic:**

```solidity
require(block.timestamp >= config.maturityDate, "Manager/not-matured");

// 5% slippage protection applies to maturity amounts too
uint256 expectedAmount = config.faceValue;
uint256 minAmount = (expectedAmount * 9500) / 10000;
uint256 maxAmount = (expectedAmount * 10500) / 10000;
require(finalAmount >= minAmount && finalAmount <= maxAmount, "SlippageProtectionTriggered");
```

**Events Emitted:**

- `MaturityProcessed(finalAmount)`
- `StatusChanged(INVESTED, MATURED)`

### 7. Emergency Flow

**Actors:** Emergency Role, Users
**Contracts:** Manager, LiquidityPool, PoolEscrow
**Status:** Any → EMERGENCY

#### Emergency Triggers

1. **Insufficient Funding:**

   ```solidity
   if (amountRaised < minimumRaise) {
       status = EMERGENCY;
   }
   ```

2. **Manual Emergency Exit:**

   ```solidity
   Manager.emergencyExit() // Called by pool itself or emergency role
   ```

3. **Pool Cancellation:**
   ```solidity
   Manager.cancelPool() // Called by emergency role
   ```

#### Emergency Withdrawal

```solidity
// User claims emergency refund
LiquidityPool.withdraw(userShares, userAddress, userAddress)
```

**Refund Calculation:**

```solidity
function _getUserRefundInternal(address pool, address user) internal view returns (uint256) {
    uint256 userShares = IERC20(pool).balanceOf(user);
    uint256 totalShares = IERC20(pool).totalSupply();

    // Proportional refund based on original deposits
    return (userShares * poolTotalRaised[pool]) / totalShares;
}
```

## Access Control System

### Role Hierarchy

```solidity
bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
bytes32 public constant SPV_ROLE = keccak256("SPV_ROLE");
bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
bytes32 public constant POOL_CREATOR_ROLE = keccak256("POOL_CREATOR_ROLE");
```

### Role Permissions

| Role                  | Permissions                                         |
| --------------------- | --------------------------------------------------- |
| **DEFAULT_ADMIN**     | Grant/revoke roles, update configurations           |
| **SPV_ROLE**          | Process investments, submit proofs, handle maturity |
| **OPERATOR_ROLE**     | Close epochs, distribute coupons, pause pools       |
| **EMERGENCY_ROLE**    | Emergency exits, force close, emergency pause       |
| **POOL_CREATOR_ROLE** | Create new pools                                    |

### Security Features

1. **24-Hour Role Delays:** Critical role assignments have time delays
2. **Emergency Pause:** Immediate system shutdown capability
3. **Single Manager Control:** Escrow releases funds based on Manager instructions only
4. **Slippage Protection:** Fixed 5% tolerance on investment and maturity amounts

## Fee Management (Standalone)

The FeeManager contract exists with full functionality but is **NOT integrated** with the core deposit/withdrawal flows.

### Default Fee Structure

```solidity
FeeConfig({
    protocolFee: 50,         // 0.5%
    spvFee: 100,            // 1.0%
    performanceFee: 200,    // 2.0%
    earlyWithdrawalFee: 100, // 1.0% (not used - early withdrawals blocked)
    refundGasFee: 10,       // 0.1%
    isActive: true
});
```

**Note:** Fees are calculated by FeeManager but require manual integration to collect during transactions.

## Real-World Example

### Treasury Bill Investment Pool

**Pool Configuration:**

- Asset: USDC
- Instrument: 90-Day US Treasury Bills
- Target Raise: $100,000
- Discount Rate: 18%
- Funding Period: 7 days
- Maturity: 90 days

**Timeline:**

**Day 1-7: Funding Period**

- Users deposit USDC
- Pool collects $100,000
- Users receive pool shares

**Day 8: Epoch Close**

- Operator calls `closeEpoch()`
- Face value calculated: $121,951
- Status: PENDING_INVESTMENT

**Day 9: SPV Investment**

- SPV withdraws $100,000 from escrow
- SPV invests in Treasury Bills
- Receives $121,951 face value instruments
- Calls `processInvestment()`
- Status: INVESTED

**Day 10-98: Invested Period**

- **Early withdrawals are BLOCKED**
- Users must wait for maturity
- SPV manages off-chain investment

**Day 99: Maturity**

- Treasury Bills mature
- SPV receives $121,951
- Calls `processMaturity()`
- Status: MATURED

**Day 100+: User Withdrawals**

- Users withdraw with full returns
- User who deposited $1,000 receives $1,219.51
- ROI: 21.95% (90-day period)

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
forge test --match-path test/Manager.t.sol

# Generate gas report
forge test --gas-report
```

### Deployment

**Contract Deployment Order:**

1. **AccessManager** - Deploy first for role management
2. **PoolRegistry** - Deploy for pool registration
3. **Manager** - Deploy for pool logic
4. **PoolFactory** - Deploy with registry and manager addresses
5. **FeeManager** - Deploy standalone (optional)

**Configuration Steps:**

1. Set up roles in AccessManager
2. Configure factory in PoolRegistry
3. Approve assets in PoolRegistry
4. Grant necessary roles to SPV and operators

## Security Considerations

### Multi-Layer Security

1. **Access Control:** Role-based permissions with time delays
2. **Slippage Protection:** Fixed 5% tolerance on investment amounts
3. **Emergency Mechanisms:** Multiple emergency exit options
4. **Single Point Control:** Manager controls all fund releases from escrow
5. **Withdrawal Restrictions:** Early withdrawals blocked during investment period
