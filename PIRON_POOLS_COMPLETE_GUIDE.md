# Piron Pools Complete Guide

## Overview

Piron Pools is a comprehensive DeFi protocol for tokenizing and managing real-world assets (RWAs) through structured investment pools. The protocol enables the creation of liquidity pools backed by various financial instruments including discounted bills, interest-bearing notes, and other structured products.

## Core Architecture

### Smart Contracts

1. **Manager.sol** - Central pool management and lifecycle control
2. **LiquidityPool.sol** - ERC4626-compliant vault for user deposits
3. **PoolEscrow.sol** - Secure asset custody and fund management
4. **PoolRegistry.sol** - Pool registration and discovery
5. **AccessManager.sol** - Role-based access control with time delays
6. **FeeManager.sol** - Fee calculation and distribution
7. **PoolOracle.sol** - Investment proof verification and asset valuation
8. **PoolFactory.sol** - Pool creation and deployment

### Key Features

- **Multi-Asset Support**: Supports various ERC20 tokens as underlying assets
- **Flexible Instruments**: Handles discounted bills and interest-bearing instruments
- **Dynamic Fee Structure**: Configurable fees with time-based penalties
- **Slippage Protection**: Built-in protection against investment slippage
- **Oracle Integration**: Decentralized verification of off-chain investments
- **Emergency Controls**: Comprehensive emergency mechanisms and fund recovery

## Access Control & Roles

The protocol uses a sophisticated role-based access control system with mandatory time delays for security:

### Core Roles

1. **DEFAULT_ADMIN_ROLE** - System administrator with full control
2. **SPV_ROLE** - Special Purpose Vehicle for investment execution
3. **OPERATOR_ROLE** - Pool operations and status management
4. **EMERGENCY_ROLE** - Emergency pause and recovery functions
5. **ORACLE_ROLE** - Investment proof verification
6. **VERIFIER_ROLE** - Additional verification layer
7. **FACTORY_ROLE** - Pool creation permissions
8. **POOL_CREATOR_ROLE** - Pool creation in factory

### Security Features

- **24-hour time delay** for all role-based actions
- **Emergency pause** capability for critical situations
- **Role revocation** with automatic cleanup
- **Multi-signature support** for pool creation

## Pool Lifecycle

### 1. Pool Creation

```solidity
struct PoolConfig {
    address asset;
    IPoolManager.InstrumentType instrumentType;
    string instrumentName;
    uint256 targetRaise;
    uint256 epochDuration;
    uint256 maturityDate;
    uint256 discountRate;
    address spvAddress;
    address[] multisigSigners;
}
```

**Requirements:**

- Minimum 2 multisig signers
- Valid asset address (must be approved)
- Maturity date > epoch end time
- Valid SPV address
- Target raise > 0

### 2. Pool States

1. **FUNDING** - Accepting investor deposits
2. **PENDING_INVESTMENT** - Awaiting off-chain investment
3. **INVESTED** - Funds deployed, earning returns
4. **MATURED** - Investment completed, returns available
5. **EMERGENCY** - Emergency state for fund recovery

### 3. Funding Phase

- **Minimum Raise**: 50% of target raise required for success
- **Epoch Duration**: Configurable funding period
- **Deposit Limits**: Cannot exceed target raise
- **Early Withdrawal**: Penalty-free during funding phase

### 4. Investment Execution

- **Slippage Protection**: Default 5% tolerance, max 10%
- **Oracle Verification**: Minimum 2 verifiers required
- **24-hour Timelock**: For investment proof verification
- **Automatic Status Update**: Upon successful investment

## Fee Structure

### Default Fee Configuration

```solidity
FeeConfig({
    protocolFee: 50,      // 0.5%
    spvFee: 100,          // 1%
    performanceFee: 200,  // 2%
    earlyWithdrawalFee: 100, // 1%
    refundGasFee: 10,     // 0.1%
    isActive: true
});
```

### Dynamic Early Withdrawal Penalties

The protocol implements time-based penalty structure:

- **< 7 days**: 5% penalty
- **7-30 days**: 3% penalty
- **30-90 days**: 2% penalty
- **> 90 days**: 1% penalty

### Fee Distribution

- **Protocol Treasury**: Configurable share of collected fees
- **SPV Address**: Remaining share after protocol fees
- **Minimum Distribution Interval**: 24 hours

## Investment Instruments

### 1. Discounted Bills

- **Face Value Calculation**: `faceValue = targetRaise / (1 - discountRate)`
- **Discount Earning**: Difference between face value and purchase price
- **Maturity Return**: Full face value at maturity

### 2. Interest-Bearing Notes

- **Coupon Payments**: Periodic interest payments
- **Flexible Schedule**: Configurable coupon dates and rates
- **Distribution**: Automatic coupon distribution to investors

## Slippage Protection

### Configuration

- **Default Tolerance**: 5% (500 basis points)
- **Maximum Tolerance**: 10% (1000 basis points)
- **Per-Pool Settings**: Configurable by admin

### Validation

```solidity
function validateSlippage(address pool, uint256 expected, uint256 actual) public view returns (bool) {
    uint256 tolerance = getSlippageTolerance(pool);
    uint256 minAmount = (expected * (10000 - tolerance)) / 10000;
    uint256 maxAmount = (expected * (10000 + tolerance)) / 10000;

    return actual >= minAmount && actual <= maxAmount;
}
```

## Oracle System

### Investment Proof Verification

1. **Proof Submission**: SPV submits investment proof with hash and amount
2. **Verification Period**: 24-hour timelock before verification can begin
3. **Multi-Verifier**: Minimum 2 oracle verifiers required
4. **Reputation System**: Oracles earn reputation points for accurate verification

### Valuation Updates

- **Maximum Age**: 7 days for asset valuations
- **Confidence Scoring**: Oracle confidence levels for valuations
- **Data Source Tracking**: IPFS hash storage for proof documents

## Emergency Mechanisms

### Emergency States

1. **Pool Cancellation**: During funding phase only
2. **Emergency Exit**: Can be triggered by pools
3. **System Pause**: Global pause capability
4. **Fund Recovery**: Proportional refund mechanism

### Refund Calculation

```solidity
function getUserRefund(address user) external view returns (uint256) {
    uint256 userShares = IERC20(poolAddress).balanceOf(user);
    uint256 totalShares = IERC20(poolAddress).totalSupply();

    return (userShares * poolTotalRaised[poolAddress]) / totalShares;
}
```

## Fund Flow Architecture

### Enterprise-Grade Fund Custody Model

**CRITICAL**: The Manager contract **NEVER** holds funds. All funds are held in the Escrow contract with enterprise-grade multisig security.

### Complete Fund Flow

#### 1. User Deposits

```
User → LiquidityPool.deposit() → DIRECT TRANSFER → Escrow
                ↓
Manager.handleDeposit() → Escrow.receiveDeposit() (accounting only)
```

#### 2. SPV Investment Withdrawal

```
SPV → Manager.withdrawFundsForInvestment() → Escrow.withdrawForInvestment() → SPV
```

#### 3. Coupon Payments

```
SPV → Manager.processCouponPayment() → DIRECT TRANSFER → Escrow
                ↓
Escrow.trackCouponPayment() (accounting only)
```

#### 4. Maturity Returns

```
SPV → Manager.processMaturity() → DIRECT TRANSFER → Escrow
                ↓
Pool Status → MATURED
```

#### 5. User Withdrawals/Redemptions

```
User → LiquidityPool.withdraw() → Manager.handleWithdraw() → Escrow.releaseFunds() → User
```

#### 6. User Coupon Claims

```
User → LiquidityPool.claimCoupon() → Manager.claimUserCoupon() → Escrow.releaseFunds() → User
```

### Fund Security Model

- **Escrow Contract**: Holds ALL funds with enterprise-grade multisig security
- **Manager Contract**: Pure business logic controller, never holds funds
- **LiquidityPool Contract**: User interface, facilitates direct transfers to/from escrow
- **SPV**: Off-chain investment entity, transfers directly to/from escrow

### Key Security Features

1. **No Fund Custody in Manager**: Manager only validates and controls, never holds funds
2. **Direct Transfers**: All fund movements go directly between User/SPV and Escrow
3. **Multisig Protection**: Escrow requires multiple signatures for large transfers
4. **Accounting Separation**: Fund custody (Escrow) separate from business logic (Manager)
5. **Audit Trail**: All fund movements tracked with comprehensive events

### Deprecated Functions

- `PoolEscrow.deposit()`: **DEPRECATED** - Manager never holds funds to transfer
- Use `PoolEscrow.receiveDeposit()` for accounting when funds arrive directly

This architecture ensures enterprise-grade security where:

- Funds are never at risk in business logic contracts
- All fund movements require proper authorization
- Complete audit trail for compliance
- Separation of concerns between custody and control

## Integration Guide

### For Pool Creators

1. **Asset Approval**: Ensure asset is approved in registry
2. **Role Assignment**: Obtain POOL_CREATOR_ROLE
3. **Configuration**: Set up pool parameters
4. **Deployment**: Call `PoolFactory.createPool()`

### For Investors

1. **Asset Approval**: Approve spending for pool's asset
2. **Deposit**: Call `LiquidityPool.deposit()`
3. **Monitoring**: Track pool status and returns
4. **Withdrawal**: Available based on pool state

### For SPVs

1. **Investment Execution**: Deploy funds off-chain
2. **Proof Submission**: Submit investment proof to oracle
3. **Status Management**: Update pool status as needed
4. **Return Processing**: Process maturity and coupon payments

## Security Considerations

### Access Control

- All sensitive operations require appropriate roles
- 24-hour time delay prevents immediate role abuse
- Emergency roles can pause system instantly

### Fund Security

- Escrow contracts hold all user funds
- Manager contract controls fund release
- Multi-signature requirements for pool creation

### Oracle Security

- Multiple verifiers required for investment proofs
- Reputation system incentivizes honest behavior
- Timelock prevents immediate verification

## Gas Optimization

### Batch Operations

- **Batch Fee Distribution**: Process multiple pools in single transaction
- **Efficient Storage**: Optimized storage layout for gas efficiency
- **Event Logging**: Comprehensive event emission for off-chain tracking

### Best Practices

1. **Approve Once**: Set maximum allowance to minimize approval transactions
2. **Batch Deposits**: Combine multiple deposits where possible
3. **Monitor Gas**: Use gas estimation for complex operations

## Monitoring & Analytics

### Key Metrics

- **Total Value Locked (TVL)**: Across all active pools
- **Pool Performance**: Individual pool returns and metrics
- **Fee Collection**: Protocol and SPV fee accumulation
- **User Activity**: Deposit/withdrawal patterns

### Event Tracking

All major operations emit events for comprehensive monitoring:

- Pool creation and status changes
- Deposits and withdrawals
- Fee collection and distribution
- Investment confirmation and maturity processing

## Upgrade Path

The protocol is designed with upgradeability in mind:

### Proxy Pattern

- Manager contracts can be upgraded through registry
- Access control can be migrated to new implementations
- Fee structures can be updated without disrupting existing pools

### Migration Strategy

1. **Gradual Migration**: New pools use updated contracts
2. **Backward Compatibility**: Existing pools continue with current implementation
3. **Emergency Upgrades**: Critical fixes can be deployed immediately

## Conclusion

Piron Pools provides a robust, secure, and flexible infrastructure for tokenizing real-world assets. The protocol's comprehensive feature set, strong security model, and extensive customization options make it suitable for a wide range of structured investment products.

For technical implementation details, refer to the individual contract documentation and the test suite for usage examples.
