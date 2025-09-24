# Single Asset Pools

## Overview

Single Asset Pools represent Piron Finance's v1.0 architecture - traditional fixed-income investment products that enable collective investment in specific real-world financial instruments. These pools follow a simple, transparent model where users deposit stablecoins to participate in pre-defined investment opportunities with fixed terms and maturity dates.

## Key Features

### 🎯 **Fixed-Term Investments**

- **Pre-defined maturity dates** set at pool creation
- **Specific financial instruments** (Treasury bills, commercial paper, bonds)
- **Fixed investment terms** with no early exit options
- **Transparent pricing** known at deposit time

### 📊 **Simple Pricing Model**

- **Static share price** until instrument maturity
- **Discount-based** or **interest-bearing** instrument support
- **Face value appreciation** for discounted instruments
- **Coupon payments** for interest-bearing instruments

### 🔒 **Security-First Design**

- **Immutable pool contracts** - no upgrades possible once deployed
- **Dedicated escrows** for each pool with secure custody
- **SPV integration** for professional asset management
- **Emergency controls** for crisis management

### 💰 **Predictable Returns**

- **Known yields** calculated at pool creation
- **Fixed maturity payouts** based on instrument performance
- **Transparent fee structure** with no hidden costs
- **Automatic distributions** at maturity

## How Single Asset Pools Work

### Investment Flow

```
1. Pool created for specific instrument (e.g., 90-day T-bill)
   ↓
2. Users deposit stablecoin during funding period
   ↓
3. Pool reaches target raise and closes to new deposits
   ↓
4. SPV purchases the specific financial instrument
   ↓
5. Instrument matures and returns principal + yield
   ↓
6. Users can withdraw their proportional share
```

### Pool Lifecycle States

#### **FUNDING**

- Pool accepting user deposits
- Target raise amount not yet reached
- Users can deposit and receive pool shares

#### **FILLED**

- Target raise amount reached
- Pool closed to new deposits
- Waiting for SPV investment execution

#### **PENDING_INVESTMENT**

- SPV preparing to invest in target instrument
- Funds transferred from escrow to SPV
- Investment execution in progress

#### **INVESTED**

- SPV has successfully purchased the instrument
- Pool is now exposed to instrument performance
- Waiting for maturity or coupon payments

#### **MATURED**

- Financial instrument has reached maturity
- Principal and yields returned to escrow
- Users can withdraw their share

#### **EMERGENCY**

- Emergency state triggered by admin
- Users can withdraw available funds
- Used for crisis management

## Architecture Components

### **LiquidityPool Contract**

- **Type**: ERC4626 vault that delegates to Manager
- **Purpose**: User-facing interface for deposits and withdrawals
- **Key Methods**:
  - `deposit()` - Standard ERC4626 deposit function
  - `withdraw()` - Withdraw at maturity or during emergency
  - `totalAssets()` - Current pool asset value

### **Manager Contract**

- **Purpose**: Core business logic for single asset pools
- **Responsibilities**:
  - Pool lifecycle management
  - Deposit and withdrawal processing
  - SPV coordination and fund transfers
  - Fee calculations and distributions
  - Emergency state management

### **PoolEscrow Contract**

- **Purpose**: Secure custody of user funds
- **Features**:
  - Immutable once deployed (no upgrades)
  - SPV fund transfers
  - Emergency withdrawal capabilities
  - Audit trail for all fund movements

### **PoolFactory Contract**

- **Purpose**: Standardized pool deployment
- **Features**:
  - Template-based pool creation
  - Parameter validation
  - Registry integration
  - Access control enforcement

## Instrument Types Supported

### **Discounted Instruments**

- **Treasury Bills**: Government-issued short-term securities
- **Commercial Paper**: Corporate short-term debt
- **Banker's Acceptances**: Trade finance instruments
- **Pricing**: Purchased below face value, mature at full value

### **Interest-Bearing Instruments**

- **Corporate Bonds**: Fixed-rate corporate debt
- **Government Bonds**: Sovereign debt securities
- **Municipal Bonds**: Local government obligations
- **Pricing**: Purchased at/near face value, receive periodic coupons

## User Experience

### **Investment Process**

1. **Browse Available Pools**: View active funding opportunities
2. **Review Terms**: Check maturity date, yield, minimum investment
3. **Deposit Funds**: Transfer stablecoin to pool during funding period
4. **Receive Shares**: Get ERC20 tokens representing pool ownership
5. **Wait for Maturity**: Monitor pool status and instrument performance
6. **Withdraw Returns**: Claim principal + yield after maturity

### **Pool Information**

- **Target Raise**: Total amount the pool aims to collect
- **Minimum Investment**: Smallest deposit amount accepted
- **Maturity Date**: When the underlying instrument expires
- **Expected Yield**: Projected return based on instrument terms
- **Pool Status**: Current lifecycle stage
- **Funding Progress**: Amount raised vs. target

### **Risk Disclosures**

- **No Early Exit**: Funds locked until maturity or emergency
- **Instrument Risk**: Returns depend on underlying asset performance
- **Liquidity Risk**: No secondary market for pool shares
- **Counterparty Risk**: SPV and instrument issuer creditworthiness

## Technical Specifications

### **Pool Configuration**

```solidity
struct PoolConfig {
    InstrumentType instrumentType;    // DISCOUNTED or INTEREST_BEARING
    uint256 faceValue;               // Face value (for discounted instruments)
    uint256 purchasePrice;           // Purchase price per unit
    uint256 targetRaise;             // Target funding amount
    uint256 epochEndTime;            // End of funding period
    uint256 maturityDate;            // Instrument maturity
    uint256[] couponDates;           // Coupon payment dates (if applicable)
    uint256[] couponRates;           // Coupon rates in basis points
    uint256 discountRate;            // Discount rate (for discounted instruments)
    uint256 minimumFundingThreshold; // Minimum raise required to proceed
}
```

### **User Position Tracking**

```solidity
struct UserPoolData {
    uint256 totalDeposited;          // Total amount deposited
    uint256 sharesOwned;             // Current share balance
    uint256 couponsClaimed;          // Coupons claimed to date
    uint256 principalWithdrawn;      // Principal already withdrawn
    bool hasWithdrawn;               // Full withdrawal status
    uint256 lastInteractionTime;    // Last deposit/withdrawal
}
```

## Fee Structure

### **Management Fees**

- **No management fees** during pool lifecycle
- **Gas optimization** through batch operations
- **Transparent costs** - only blockchain transaction fees

### **Performance Fees**

- **No performance fees** on returns
- **Direct pass-through** of instrument yields
- **Minimal protocol overhead**

### **Emergency Fees**

- **No penalty fees** for emergency withdrawals
- **Pro-rata distribution** of available funds
- **Fair treatment** of all pool participants

## Risk Management

### **Liquidity Risk Controls**

- **Target raise limits** prevent over-concentration
- **Minimum funding thresholds** ensure viable pool size
- **Emergency withdrawal** mechanisms for crisis situations
- **SPV diversification** across multiple instruments

### **Operational Risk Controls**

- **Immutable contracts** prevent malicious upgrades
- **Multi-signature** requirements for critical operations
- **Time-locked** administrative functions
- **Audit trails** for all fund movements

### **Market Risk Mitigation**

- **Instrument due diligence** by professional SPV managers
- **Credit rating requirements** for underlying assets
- **Diversification** across issuers and maturities
- **Regular monitoring** of instrument performance

## Benefits vs. Managed Pools

| Feature          | Single Asset Pools            | Managed Pools               |
| ---------------- | ----------------------------- | --------------------------- |
| **Simplicity**   | Simple, predictable structure | Complex tenor selection     |
| **Transparency** | Single instrument exposure    | Multi-asset portfolio       |
| **Risk Profile** | Concentrated, known risk      | Diversified, managed risk   |
| **Liquidity**    | No early exit                 | Early exit with penalties   |
| **Management**   | Passive investment            | Active management           |
| **Fees**         | No management fees            | Management and penalty fees |

## Getting Started

### **For Investors**

1. Connect wallet to Piron Finance platform
2. Browse available single asset pools
3. Review pool terms and instrument details
4. Deposit during funding period
5. Monitor pool status and maturity progress
6. Withdraw returns after instrument maturity

### **For Pool Creators**

1. Obtain POOL_CREATOR_ROLE permissions
2. Identify suitable financial instrument
3. Configure pool parameters via PoolFactory
4. Set up SPV integration and escrow
5. Launch funding period
6. Coordinate SPV investment execution

---

_Single Asset Pools provide a straightforward, transparent way to participate in institutional-grade fixed-income investments through blockchain technology._
