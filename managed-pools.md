# Managed Pools (Stable Yield Pools)

## Overview

Managed Pools, also known as **Stable Yield Pools**, represent Piron Finance's v1.1 architecture - sophisticated, currency-agnostic investment products that provide professional NAV-based pricing, flexible tenor selection, early exit capabilities, and direct SPV integration for seamless Treasury bill portfolio management.

## Key Features

### 🎯 **Flexible Tenor Selection**

- **90 days**: Short-term exposure with quarterly liquidity
- **180 days**: Semi-annual investment horizon
- **270 days**: Extended yield optimization
- **360 days**: Full-year commitment with maximum returns

### 📊 **Professional NAV Pricing**

- Daily Net Asset Value (NAV) updates
- Floating share prices based on real-time portfolio performance
- ERC4626 vault compliance with enhanced functionality

### 🚪 **Early Exit Capability**

- Available after **30-day minimum hold period**
- **3-5% penalty fees** applied to early withdrawals
- Immediate liquidity through cash reserves when available

### 💰 **Cash Reserve Management**

- **10% default cash buffer** for immediate withdrawals
- Dynamic reserve ratios:
  - **Target**: 10% (1000 basis points)
  - **Minimum**: 5% (500 basis points)
  - **Maximum**: 20% (2000 basis points)
- Automatic rebalancing based on withdrawal demand

## How Managed Pools Work

### Investment Flow

```
1. User deposits stablecoin (USDC, CNGN, etc.)
   ↓
2. User selects tenor (90d-360d) and maturity action
   ↓
3. Funds allocated to professional T-bill portfolio via SPV
   ↓
4. Daily NAV updates reflect portfolio performance
   ↓
5. Early exit available after 30 days (with penalties)
   ↓
6. At maturity: automatic compound or withdrawal
```

### Architecture Components

#### **StableYieldPool Contract**

- **Type**: ERC4626 vault with enhanced functionality
- **Purpose**: User-facing interface for deposits and withdrawals
- **Key Methods**:
  - `depositWithTenor()` - Deposit with tenor selection
  - `requestEarlyExit()` - Early withdrawal with penalties
  - `getNAVPerShare()` - Current share value

#### **StableYieldManager Contract**

- **Purpose**: Advanced business logic and NAV calculations
- **Responsibilities**:
  - Tenor-based deposit processing
  - Yield calculations and penalty management
  - Portfolio rebalancing and reserve management
  - Professional NAV pricing

#### **ManagedPoolEscrow Contract**

- **Purpose**: Simplified custody with direct SPV integration
- **Features**:
  - Secure asset custody
  - Direct SPV fund transfers
  - Automated reserve management

## Pool Types & Examples

### **Geographic Pools**

- **Piron USDC Stable Yield Pool**: US Treasury Bills, Dollar-denominated returns
- **Piron CNGN Stable Yield Pool**: Nigerian Treasury Bills, Naira-denominated returns

### **Diversified Pools**

- **Piron Emerging Markets Pool**: Multi-currency T-bill diversification
- **Piron Bond Pool**: Longer-term sovereign bond exposure

## User Experience

### **Deposit Process**

1. **Asset Selection**: Choose approved stablecoin (USDC, CNGN, etc.)
2. **Tenor Selection**: Pick investment duration (90d-360d)
3. **Maturity Action**: Choose compound or withdraw at maturity
4. **Minimum Investment**: Varies by pool (typically $100-1000 equivalent)

### **Position Management**

- **Real-time NAV**: Track daily portfolio value
- **Multiple Positions**: Hold different tenors simultaneously
- **Automatic Compounding**: Reinvest at maturity if selected
- **Early Exit**: Request withdrawal after 30-day minimum hold

### **Fee Structure**

- **Management Fee**: Typically 0.5-2% annually (expense ratio)
- **Early Exit Penalty**: 3-5% of withdrawn amount
- **No Deposit Fees**: Direct investment with no upfront costs

## Technical Specifications

### **Supported Assets**

- Any approved stablecoin registered in PoolRegistry
- Multi-currency support (USD, NGN, KES, etc.)
- ERC20 compliant tokens only

### **Reserve Management**

```solidity
struct PoolReserves {
    uint256 targetReserveRatio;    // 1000 = 10%
    uint256 minReserveRatio;       // 500 = 5%
    uint256 maxReserveRatio;       // 2000 = 20%
    uint256 currentCashBuffer;     // Current cash held
    uint256 totalPoolAUM;          // Total assets under management
    uint256 lastRebalanceTime;     // Last reserve rebalancing
}
```

### **User Position Tracking**

```solidity
struct UserPosition {
    uint256 principal;             // Original deposit amount
    uint256 shares;               // Current share balance
    uint256 tenorDays;            // Selected investment period
    uint256 depositTime;          // Deposit timestamp
    uint256 maturityTime;         // Position maturity
    MaturityAction maturityAction; // Compound or withdraw
    bool isActive;                // Position status
}
```

## Risk Management

### **Liquidity Risk Mitigation**

- **Cash Reserves**: 10% buffer for immediate withdrawals
- **Staggered Maturities**: Continuous liquidity from maturing positions
- **Early Exit Penalties**: Discourage unnecessary early withdrawals

### **Operational Risk Controls**

- **SPV Integration**: Professional treasury management
- **Daily NAV Updates**: Real-time portfolio valuation
- **Access Controls**: Role-based permissions for all operations
- **Emergency Pause**: Admin controls for crisis management

## Benefits Over Single Asset Pools

| Feature             | Managed Pools                     | Single Asset Pools      |
| ------------------- | --------------------------------- | ----------------------- |
| **Flexibility**     | Multiple tenors, early exit       | Fixed maturity only     |
| **Pricing**         | Daily NAV updates                 | Static until maturity   |
| **Liquidity**       | Early exit after 30 days          | No early exit           |
| **Management**      | Professional portfolio management | Single instrument focus |
| **Diversification** | Multi-asset T-bill portfolios     | Single asset exposure   |
| **User Experience** | Choose-your-own tenor             | Pre-defined terms       |

## Getting Started

### **For Investors**

1. Connect wallet to Piron Finance platform
2. Browse available managed pools
3. Select pool matching your currency preference
4. Choose tenor and deposit amount
5. Confirm maturity action preference
6. Monitor NAV and position performance

### **For Pool Creators**

1. Obtain POOL_CREATOR_ROLE permissions
2. Deploy via ManagedPoolFactory
3. Configure supported tenors and minimum investment
4. Set up SPV integration and escrow
5. Register with PoolRegistry
6. Begin accepting user deposits

---

_Managed Pools represent the future of tokenized fixed-income investing, combining traditional finance professionalism with DeFi accessibility and transparency._
