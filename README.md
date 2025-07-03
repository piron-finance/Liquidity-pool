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
4. **Escrow** - Multi-signature custody of funds
5. **AccessManager** - Role-based access control
6. **FeeManager** - Fee calculation and distribution
7. **PoolOracle** - Investment proof verification (optional)
8. **PoolRegistry** - Pool registration and discovery

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
│Pool (ERC4626)│   │             │    │ (MultiSig)  │    │             │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
       ▲                  ▲                  ▲                  ▲
       │                  │                  │                  │
       │ 5. Withdraw      │ 6. Process       │ 7. Release      │ 8. Collect Fees
       │                  │    Investment    │    Funds        │
       ▼                  ▼                  ▼                  ▼
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Frontend  │    │     SPV     │    │Pool Oracle  │    │  Treasury   │
│             │    │ (Off-chain) │    │ (Optional)  │    │             │
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
    multisigSigners: [signer1, signer2, signer3]
})
```

**Function Call Sequence:**

1. `PoolFactory.createPool()` - Creates pool and manager contracts
2. `PoolRegistry.registerPool()` - Registers pool in registry
3. `Manager.initializePool()` - Initializes pool configuration
4. `AccessManager.grantRole()` - Assigns roles to SPV and operators

**Events Emitted:**

- `PoolCreated(pool, manager, asset, instrumentName, targetRaise, maturityDate)`
- `PoolRegistered(pool, poolInfo)`

### 2. Deposit Flow

**Actors:** Users
**Contracts:** LiquidityPool, Manager, Escrow
**Status:** FUNDING

```solidity
// Step 1: User deposits USDC
LiquidityPool.deposit(1000e6, userAddress) // Deposit $1,000
```

**Function Call Sequence:**

1. `LiquidityPool.deposit()` - User entry point
2. `USDC.transferFrom(user, escrow, amount)` - Transfer USDC to escrow
3. `Manager.handleDeposit()` - Process deposit logic
4. `LiquidityPool._mint(user, shares)` - Mint pool shares to user

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
**Contracts:** Manager, PoolOracle (optional), Escrow
**Status:** PENDING_INVESTMENT → INVESTED

#### Option A: With Oracle Verification

```solidity
// Step 1: SPV submits investment proof
PoolOracle.submitInvestmentProof(
    poolAddress,
    "0x1234abcd...", // Cryptographic proof hash
    100000e6        // Actual investment amount
)

// Step 2: Oracles verify proof (after 24-hour timelock)
PoolOracle.verifyProof(poolAddress) // Called by multiple oracles

// Step 3: SPV processes investment
Manager.processInvestment(poolAddress, 100000e6, "0x1234abcd...")
```

#### Option B: Without Oracle (Trust-Based)

```solidity
// Step 1: SPV directly processes investment
Manager.processInvestment(poolAddress, 100000e6, "") // Empty proof hash
```

**Function Call Sequence:**

1. `Manager.processInvestment()` - Process SPV investment
2. `Manager.checkSlippageProtection()` - Validate investment amount
3. `Manager._updateStatus()` - Update to INVESTED status

**Business Logic:**

```solidity
uint256 expectedAmount = poolTotalRaised[pool];
checkSlippageProtection(pool, expectedAmount, actualAmount); // ±5% tolerance

if (instrumentType == DISCOUNTED) {
    uint256 totalDiscount = faceValue - actualAmount;
    poolTotalDiscountEarned[pool] = totalDiscount;
}
```

**Events Emitted:**

- `InvestmentConfirmed(actualAmount, proofHash)`
- `StatusChanged(PENDING_INVESTMENT, INVESTED)`

### 5. Withdrawal Flow

**Actors:** Users
**Contracts:** LiquidityPool, Manager, Escrow
**Status:** Any status

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
5. `Escrow.releaseFunds()` - Release USDC to user

**Business Logic:**

```solidity
// No penalties during funding period
shares = assets; // 1:1 ratio
poolTotalRaised[pool] -= assets;
```

#### B. Early Withdrawal (With Penalties)

```solidity
// User withdraws after investment
LiquidityPool.withdraw(1000e6, userAddress, userAddress)
```

**Function Call Sequence:**

1. `LiquidityPool.withdraw()` - User entry point
2. `Manager._handleInvestedWithdrawal()` - Process early withdrawal
3. `Manager._calculateDynamicPenalty()` - Calculate time-based penalty
4. `LiquidityPool.burnShares()` - Burn user shares
5. `Escrow.releaseFunds()` - Release net amount to user

**Penalty Structure:**

```solidity
function _calculateDynamicPenalty(address pool, uint256 assets, address owner) internal view returns (uint256) {
    uint256 timeHeld = block.timestamp - poolUserDepositTime[pool][owner];

    if (timeHeld < 7 days) {
        return (assets * 500) / 10000; // 5% penalty
    } else if (timeHeld < 30 days) {
        return (assets * 300) / 10000; // 3% penalty
    } else if (timeHeld < 90 days) {
        return (assets * 200) / 10000; // 2% penalty
    } else {
        return (assets * 100) / 10000; // 1% penalty
    }
}
```

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
5. `Escrow.releaseFunds()` - Release full returns to user

**Return Calculation:**

```solidity
function _calculateTotalReturns(address pool, PoolConfig storage config) internal view returns (uint256) {
    if (config.instrumentType == DISCOUNTED) {
        return config.faceValue; // Full face value
    } else {
        // Interest-bearing: principal + coupons
        uint256 undistributedCoupons = poolTotalCouponsReceived[pool] - poolTotalCouponsDistributed[pool];
        return poolActualInvested[pool] + undistributedCoupons;
    }
}
```

### 6. Maturity Processing Flow

**Actors:** SPV
**Contracts:** Manager, Escrow
**Status:** INVESTED → MATURED

```solidity
// Step 1: SPV processes maturity
Manager.processMaturity(poolAddress, 121951e6) // $121,951 received
```

**Function Call Sequence:**

1. `Manager.processMaturity()` - Process instrument maturity
2. `Manager.checkSlippageProtection()` - Validate maturity amount
3. `Manager._updateStatus()` - Update to MATURED status

**Business Logic:**

```solidity
require(block.timestamp >= config.maturityDate, "Manager/not-matured");

if (config.instrumentType == DISCOUNTED) {
    // Validate final amount matches expected face value (±5% tolerance)
    checkSlippageProtection(pool, config.faceValue, finalAmount);
}
```

**Events Emitted:**

- `MaturityProcessed(finalAmount)`
- `StatusChanged(INVESTED, MATURED)`

### 7. Emergency Flow

**Actors:** Emergency Role, Users
**Contracts:** Manager, LiquidityPool, Escrow
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
   Manager.emergencyExit() // Called by emergency role
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

## Fee System

### Fee Types & Rates

```solidity
struct FeeConfig {
    uint256 protocolFee;      // 0.5% - Protocol revenue
    uint256 spvFee;           // 1.0% - SPV management fee
    uint256 performanceFee;   // 2.0% - Performance-based fee
    uint256 earlyWithdrawalFee; // 1.0% - Early exit penalty
    uint256 refundGasFee;     // 0.1% - Gas compensation
}
```

### Fee Collection Points

1. **Investment Processing:** Protocol and SPV fees
2. **Early Withdrawal:** Penalty fees
3. **Maturity:** Performance fees on profits
4. **Emergency Refund:** Gas fees

### Fee Distribution

```solidity
// 50/50 split between protocol and SPV
FeeDistribution {
    protocolTreasury: PROTOCOL_ADDRESS,
    spvAddress: SPV_ADDRESS,
    protocolShare: 5000, // 50%
    spvShare: 5000       // 50%
}
```

## Access Control System

### Role Hierarchy

```solidity
bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
bytes32 public constant SPV_ROLE = keccak256("SPV_ROLE");
bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");
```

### Role Permissions

| Role               | Permissions                                         |
| ------------------ | --------------------------------------------------- |
| **DEFAULT_ADMIN**  | Grant/revoke roles, update configurations           |
| **SPV_ROLE**       | Process investments, submit proofs, handle maturity |
| **OPERATOR_ROLE**  | Close epochs, distribute coupons, pause pools       |
| **EMERGENCY_ROLE** | Emergency exits, force close, emergency pause       |
| **ORACLE_ROLE**    | Verify proofs, update valuations                    |
| **VERIFIER_ROLE**  | Verify investment proofs                            |
| **FACTORY_ROLE**   | Create pools, update implementations                |

### Security Features

1. **24-Hour Role Delays:** Critical role assignments have time delays
2. **Emergency Pause:** Immediate system shutdown capability
3. **Multi-Signature:** Escrow requires multiple signatures
4. **Slippage Protection:** Investment amount validation (±5% tolerance)

## Oracle System (Optional)

### Investment Proof Verification

```solidity
struct InvestmentProofData {
    string proofHash;           // Cryptographic proof hash
    uint256 amount;             // Investment amount
    uint256 timestamp;          // Submission time
    bool verified;              // Verification status
    address verifier;           // Verifying oracle
    address submitter;          // SPV submitter
    uint256 blockNumber;        // Block number
    string ipfsHash;            // IPFS document hash
    uint256 verificationCount;  // Number of verifications
}
```

### Verification Process

1. **Proof Submission:** SPV submits proof with IPFS documentation
2. **24-Hour Timelock:** Prevents rushed verifications
3. **Multi-Oracle Verification:** Minimum 2 oracles must verify
4. **Challenge Period:** Oracles can challenge disputed proofs
5. **Reputation System:** Oracle reputation affects weighting

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

- SPV invests $100,000 in Treasury Bills
- Receives $121,951 face value instruments
- Calls `processInvestment()`
- Status: INVESTED

**Day 99: Maturity**

- Treasury Bills mature
- SPV receives $121,951
- Calls `processMaturity()`
- Status: MATURED

**Day 100+: User Withdrawals**

- Users withdraw with full returns
- User who deposited $1,000 receives $1,219.51
- ROI: 21.95% (90-day period)

## Deployment Guide

### Contract Deployment Order

1. **AccessManager** - Deploy first for role management
2. **PoolRegistry** - Deploy for pool registration
3. **FeeManager** - Deploy for fee management
4. **PoolOracle** - Deploy for proof verification (optional)
5. **Manager Implementation** - Deploy as template
6. **LiquidityPool Implementation** - Deploy as template
7. **Escrow Implementation** - Deploy as template
8. **PoolFactory** - Deploy with all implementations

### Configuration Steps

1. **Set up roles** in AccessManager
2. **Configure default fees** in FeeManager
3. **Add oracles** to PoolOracle (if using)
4. **Grant factory role** to PoolFactory
5. **Set treasury addresses** for fee collection

### Frontend Integration

**Key Contract Interactions:**

```typescript
// Pool creation
const tx = await poolFactory.createPool(poolConfig);

// User deposit
const tx = await liquidityPool.deposit(amount, userAddress);

// User withdrawal
const tx = await liquidityPool.withdraw(amount, userAddress, userAddress);

// Check user returns
const returns = await liquidityPool.getUserReturn(userAddress);

// Check pool status
const status = await manager.status();
```

## Security Considerations

### Multi-Layer Security

1. **Access Control:** Role-based permissions with time delays
2. **Slippage Protection:** Investment amount validation
3. **Emergency Mechanisms:** Multiple emergency exit options
4. **Multi-Signature:** Escrow requires multiple signatures
5. **Oracle Verification:** Investment proof verification (optional)
6. **Fee Caps:** Maximum fee rates to prevent exploitation

### Risk Mitigation

1. **Minimum Raise:** 50% minimum funding requirement
2. **Liquidity Buffer:** 10% available for early withdrawals
3. **Time-Based Penalties:** Discourage short-term speculation
4. **Emergency Refunds:** Full refund capability in emergencies

## Conclusion

Piron Pools provides a comprehensive DeFi solution for investing in traditional financial instruments. The system balances security, flexibility, and user experience while maintaining transparency and decentralization. The modular architecture allows for optional features like oracle verification while keeping the core functionality simple and robust.

The discount calculation is mathematically sound, the fee system is fair and transparent, and the emergency mechanisms provide multiple layers of user protection. The system can operate with or without oracle verification, making it adaptable to different trust models and operational requirements.
