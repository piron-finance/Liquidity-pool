# Stable Yield Pool Lifecycle

This document details the complete lifecycle of a Stable Yield Pool from creation through maturity and withdrawals.

## Table of Contents

1. [Pool Creation](#1-pool-creation)
2. [User Deposits](#2-user-deposits)
3. [Fee Collection](#3-fee-collection)
4. [SPV Capital Allocation](#4-spv-capital-allocation)
5. [Adding Instruments](#5-adding-instruments)
6. [Coupon Payments](#6-coupon-payments)
7. [Instrument Maturity](#7-instrument-maturity)
8. [User Withdrawals](#8-user-withdrawals)
9. [Monthly Fee Collection](#9-monthly-fee-collection)
10. [State Variables & Accounting](#10-state-variables--accounting)

---

## 1. Pool Creation

### Actors

- **Pool Creator** (with `POOL_CREATOR_ROLE`)
- **ManagedPoolFactory** contract
- **StableYieldManager** contract
- **StableYieldEscrow** contract

### Process

#### Step 1.1: Factory Deployment

```solidity
ManagedPoolFactory.createStableYieldPool(PoolDeploymentConfig memory config)
```

**Configuration Parameters:**

- `asset`: Underlying stablecoin (USDC, USDT, cNGN, etc.)
- `poolName`: Pool name (e.g., "Piron Nigeria Treasury Pool")
- `poolSymbol`: ERC20 symbol (e.g., "pCNGN-TREAS")
- `spvAddress`: SPV address for this pool
- `supportedTenors`: Optional array of supported tenors [90, 180, 270, 360] days
- `minInvestment`: Minimum deposit amount
- `expenseRatio`: Annual expense ratio in basis points (max 1000 = 10%)
- `underlyingPools`: Optional array of existing pools to aggregate

**Validations:**

- Asset must be approved in `PoolRegistry`
- SPV address must be non-zero
- Pool name and symbol must be non-empty
- Min investment must be > 0
- Expense ratio must be ≤ 1000 basis points (10%)
- Tenors must be valid (90, 180, 270, or 360 days)

#### Step 1.2: Escrow Deployment

```solidity
_deployManagedPoolEscrow(config)
```

**Actions:**

- Clones `StableYieldEscrow` implementation using deterministic salt
- Initializes escrow with:
  - Asset address
  - AccessManager address
  - Pool name

**State After Escrow Creation:**

- `cashBuffer = 0`
- `poolReserves = 0`
- `transactionFees = 0`
- `expenseRatioFees = 0`
- `stableYieldPool = address(0)` (set later)
- `stableYieldManager = address(0)` (set later)

#### Step 1.3: Pool Deployment

```solidity
_deployStableYieldPool(config, escrowAddress)
```

**Actions:**

- Clones `StableYieldPool` implementation using deterministic salt
- Initializes pool with:
  - Asset address
  - Pool name and symbol
  - Escrow address
  - StableYieldManager address
  - AccessManager address

**State After Pool Creation:**

- ERC4626 vault initialized
- `totalSupply = 0` (no shares minted yet)
- `lastDepositTime[user] = 0` for all users

#### Step 1.4: Linking Contracts

```solidity
StableYieldEscrow(escrowAddress).setStableYieldPool(poolAddress);
StableYieldEscrow(escrowAddress).setStableYieldManager(managerAddress);
```

**Actions:**

- Links escrow to pool (one-time, immutable)
- Links escrow to manager (one-time, immutable)

#### Step 1.5: Pool Registration

```solidity
stableYieldManager.registerPool(poolAddress, escrowAddress, asset, name, minInvestment)
```

**Actions:**

- Creates `PoolData` struct in `StableYieldManager`
- Initializes withdrawal queue (head=0, tail=0, totalPendingValue=0)
- Sets `poolInstrumentCount = 0`
- Sets `deferredFees = 0`
- Sets `lastFeeAccrual = block.timestamp`
- Registers pool in `PoolRegistry`
- Sets default expense ratio via `FeeManager`

**State After Registration:**

```solidity
pools[poolAddress] = {
    poolAddress: poolAddress,
    escrowAddress: escrowAddress,
    asset: asset,
    name: name,
    minInvestment: minInvestment,
    isActive: true,
    createdAt: block.timestamp
}
```

**Events Emitted:**

- `PoolRegistered(poolAddress, escrowAddress, asset, name)`
- `StableYieldPoolCreated(poolAddress, escrowAddress, asset, poolName, spvAddress)`

---

## 2. User Deposits

### Actors

- **User** (depositor)
- **StableYieldPool** contract
- **StableYieldManager** contract
- **StableYieldEscrow** contract
- **FeeManager** contract

### Process

#### Step 2.1: User Initiates Deposit

```solidity
StableYieldPool.deposit(uint256 assets, address receiver)
```

**Prerequisites:**

- Pool must not be paused
- User must have approved pool to spend `assets` amount
- `assets > 0`
- `receiver != address(0)`

**Actions:**

1. Transfers assets from user to escrow:
   ```solidity
   IERC20(asset()).safeTransferFrom(msg.sender, address(escrow), assets);
   ```

#### Step 2.2: Manager Validates Deposit

```solidity
StableYieldManager.validateDeposit(poolAddress, amount, receiver)
```

**Validations:**

- Caller must be the pool contract
- Pool must be registered and active
- `amount >= minInvestment`
- `receiver != address(0)`

**Fee Calculation:**

```solidity
uint256 transactionFee = IFeeManager(feeManager).calculateProtocolFee(poolAddress, amount);
uint256 netDepositAmount = amount - transactionFee;
```

**Share Calculation:**

```solidity
uint256 navPerShare = calculateNAVPerShare(poolAddress);
shares = (netDepositAmount * 1e18) / navPerShare;
```

**Note:** For first deposit, NAV per share = 1e18 (1:1), so shares = netDepositAmount.

#### Step 2.3: Escrow Allocates Funds

```solidity
StableYieldEscrow.allocateDeposit(totalAmount, reserveAmount, transactionFee)
```

**Actions:**

- Updates `cashBuffer += totalAmount`
- Updates `poolReserves += reserveAmount` (net deposit)
- Updates `transactionFees += transactionFee`

**Accounting:**

```
cashBuffer = poolReserves + transactionFees + expenseRatioFees
```

#### Step 2.4: Shares Minted

```solidity
StableYieldPool._mint(receiver, shares)
```

**Actions:**

- Mints ERC20 shares to receiver
- Updates `lastDepositTime[receiver] = block.timestamp` (for 30-day holding period)

**Events Emitted:**

- `Deposit(msg.sender, receiver, assets, shares)`
- `DepositValidated(poolAddress, receiver, amount, shares)`
- `TransactionFeeCollected(poolAddress, "deposit", amount, transactionFee)` (if fee > 0)
- `FundsAllocated(reserveAmount, transactionFee)`

### State After Deposit

**Pool:**

- `totalSupply += shares`
- `lastDepositTime[receiver] = block.timestamp`

**Escrow:**

- `cashBuffer += totalAmount`
- `poolReserves += netDepositAmount`
- `transactionFees += transactionFee`

**Manager:**

- NAV recalculated (if instruments exist)
- NAV per share updated

---

## 3. Fee Collection

### Transaction Fees (Deposit/Withdrawal)

**When:** Immediately during deposit/withdrawal

**Where:** Fees are allocated to `StableYieldEscrow.transactionFees` bucket

**Transfer to Treasury:** Manual operator action required

```solidity
StableYieldEscrow.transferFeesToTreasury(address treasury)
```

**Note:** Transaction fees accumulate in escrow until manually swept. They are NOT automatically transferred to treasury.

### Expense Ratio Fees (Management Fees)

**When:** Accrued continuously, collected monthly

**Calculation:** Based on total gross asset value (instruments + reserves)

**Collection:** Via `StableYieldManager.collectMonthlyFees()`

**Process:**

1. Calculate total gross value: `instruments value + poolReserves`
2. Calculate accrued fees: `(totalGrossValue * expenseRatio * timeElapsed) / (10000 * SECONDS_PER_YEAR)`
3. Move fees from `poolReserves` to `expenseRatioFees` bucket (respecting liquidity constraints)
4. Fees can be deferred if insufficient liquidity

---

## 4. SPV Capital Allocation

### Actors

- **Operator** (with `OPERATOR_ROLE`)
- **SPV** (with `SPV_ROLE`)
- **StableYieldManager** contract
- **StableYieldEscrow** contract

### Process

#### Step 4.1: Operator Allocates Funds to SPV

```solidity
StableYieldManager.allocateToSPV(poolAddress, spvAddress, amount)
```

**Prerequisites:**

- Operator must have `OPERATOR_ROLE`
- Pool must exist and be active
- `spvAddress != address(0)`
- `amount > 0`
- `escrow.getCashBuffer() >= amount`
- `escrow.getPoolReserves() >= amount`

**Actions:**

1. Calls `escrow.allocateToSPV(spvAddress, amount)`
2. Escrow reduces `cashBuffer` and `poolReserves` by `amount`
3. Escrow increases `spvAllocations[spvAddress] += amount`
4. Transfers assets to SPV address:
   ```solidity
   asset.safeTransfer(spvAddress, amount);
   ```

**State Changes:**

- `cashBuffer -= amount`
- `poolReserves -= amount`
- `spvAllocations[spvAddress] += amount`

**Events Emitted:**

- `SPVAllocation(spvAddress, amount, remainingCashBuffer)`
- `NAVUpdated(poolAddress, totalNAV, navPerShare, "spv_allocation", timestamp)`

**Note:** After allocation, SPV has custody of funds off-chain. The pool's NAV reflects reduced cash reserves.

---

## 5. Adding Instruments

### Actors

- **SPV** (with `SPV_ROLE`)
- **StableYieldManager** contract

### Process

#### Step 5.1: SPV Purchases Instruments Off-Chain

- SPV uses allocated funds to purchase T-bills, bonds, or other instruments
- This happens entirely off-chain

#### Step 5.2: SPV Attests to Holdings On-Chain

```solidity
StableYieldManager.addInstrument(
    poolAddress,
    instrumentType,      // DISCOUNTED or INTEREST_BEARING
    purchasePrice,       // Amount paid
    faceValue,           // Maturity value
    maturityDate,        // When instrument matures
    annualCouponRate,    // In basis points (0 for T-bills)
    couponFrequency      // 0=T-bill, 2=semi-annual, 4=quarterly, 12=monthly
)
```

**Prerequisites:**

- SPV must have `SPV_ROLE`
- Pool must exist
- `purchasePrice > 0`
- `faceValue > 0`
- `maturityDate > block.timestamp`
- For DISCOUNTED: `purchasePrice < faceValue`, `annualCouponRate == 0`, `couponFrequency == 0`
- For INTEREST_BEARING: `annualCouponRate > 0`, `couponFrequency > 0`

**Actions:**

1. Creates new `InstrumentHolding` struct:
   ```solidity
   InstrumentHolding({
       instrumentType: instrumentType,
       purchasePrice: purchasePrice,
       faceValue: faceValue,
       purchaseDate: block.timestamp,
       maturityDate: maturityDate,
       annualCouponRate: annualCouponRate,
       couponFrequency: couponFrequency,
       nextCouponDueDate: nextCouponDate,  // Calculated for interest-bearing
       couponsPaid: 0,
       isActive: true
   })
   ```
2. Pushes to `poolInstruments[poolAddress]` array
3. Increments `poolInstrumentCount[poolAddress]++`
4. Triggers NAV update

**State Changes:**

- `poolInstruments[poolAddress].push(newInstrument)`
- `poolInstrumentCount[poolAddress]++`

**Events Emitted:**

- `InstrumentPurchased(poolAddress, instrumentId, instrumentType, purchasePrice, faceValue, maturityDate)`
- `NAVUpdated(poolAddress, totalNAV, navPerShare, "instrument_added", timestamp)`
- `NAVCalculated(poolAddress, totalNAV, navPerShare, totalShares, timestamp)`

### Instrument Valuation

**Discounted Instruments (T-bills):**

- Value accretes linearly from `purchasePrice` to `faceValue` over time
- Formula: `purchasePrice + ((faceValue - purchasePrice) * timeElapsed) / totalTime`
- At maturity: `value = faceValue`

**Interest-Bearing Instruments (Bonds):**

- Value = `faceValue + accruedInterest`
- Accrued interest calculated based on:
  - Coupon amount per period
  - Time since last coupon payment
  - Coupon frequency

---

## 6. Coupon Payments

### Actors

- **SPV** (with `SPV_ROLE`)
- **StableYieldManager** contract
- **StableYieldEscrow** contract

### Process

#### Step 6.1: SPV Receives Coupon Off-Chain

- SPV receives coupon payment from bond issuer
- This happens entirely off-chain

#### Step 6.2: SPV Records Coupon On-Chain

```solidity
StableYieldManager.recordCouponPayment(poolAddress, instrumentId, couponAmount)
```

**Prerequisites:**

- SPV must have `SPV_ROLE`
- Pool must exist
- Instrument must exist and be active
- Instrument must be `INTEREST_BEARING` type
- `block.timestamp >= instrument.nextCouponDueDate`

**Actions:**

1. Updates instrument:
   - `couponsPaid++`
   - If not matured: `nextCouponDueDate += couponPeriodSeconds`
2. Triggers NAV update

**State Changes:**

- `poolInstruments[poolAddress][instrumentId].couponsPaid++`
- `poolInstruments[poolAddress][instrumentId].nextCouponDueDate` updated

**Events Emitted:**

- `CouponPaymentReceived(poolAddress, instrumentId, couponAmount, couponNumber)`
- `NAVUpdated(poolAddress, totalNAV, navPerShare, "coupon_received", timestamp)`

**Note:** The coupon amount is NOT automatically transferred to escrow. SPV must manually transfer proceeds via `receiveSPVLiquidity()` if needed.

---

## 7. Instrument Maturity

### Actors

- **SPV** (with `SPV_ROLE`)
- **StableYieldManager** contract
- **StableYieldEscrow** contract

### Process

#### Step 7.1: Instrument Matures

- Instrument reaches `maturityDate`
- SPV receives face value payment off-chain

#### Step 7.2: SPV Marks Instrument as Matured

```solidity
StableYieldManager.matureInstrument(poolAddress, instrumentId)
```

**Prerequisites:**

- SPV must have `SPV_ROLE`
- Pool must exist
- Instrument must exist and be active
- `block.timestamp >= instrument.maturityDate`

**Actions:**

1. Marks instrument as inactive: `instrument.isActive = false`
2. Calculates realized yield: `faceValue - purchasePrice`
3. Triggers NAV update

**State Changes:**

- `poolInstruments[poolAddress][instrumentId].isActive = false`

**Events Emitted:**

- `InstrumentMatured(poolAddress, instrumentId, faceValue, realizedYield)`
- `InstrumentRemoved(poolAddress, instrumentId, finalValue, "matured")`
- `NAVUpdated(poolAddress, totalNAV, navPerShare, "instrument_matured", timestamp)`

**Note:** Instrument remains in array but marked inactive. It can be removed later via batch operations.

#### Step 7.3: SPV Returns Proceeds to Escrow

```solidity
StableYieldManager.receiveSPVMaturity(poolAddress, amount)
```

**Prerequisites:**

- SPV must have `SPV_ROLE`
- Pool must exist
- `amount > 0`

**Actions:**

1. Calls `escrow.receiveSPVLiquidity(amount)`
2. Escrow receives assets from SPV (SPV must transfer first)
3. Escrow updates:
   - `cashBuffer += amount`
   - `poolReserves += amount`
4. Triggers NAV update

**State Changes:**

- `cashBuffer += amount`
- `poolReserves += amount`

**Events Emitted:**

- `SPVLiquidityReceived(spvAddress, amount, newCashBuffer)`
- `NAVUpdated(poolAddress, totalNAV, navPerShare, "spv_maturity_received", timestamp)`

#### Step 7.4: Batch Maturity Processing (Optional)

```solidity
StableYieldManager.batchMatureInstruments(poolAddress, instrumentIds[])
```

**Actions:**

- Processes up to 50 instruments at once
- Removes matured instruments from array (swaps with last element, then pops)
- Decrements `poolInstrumentCount`

---

## 8. User Withdrawals

### Actors

- **User** (withdrawer)
- **StableYieldPool** contract
- **StableYieldManager** contract
- **StableYieldEscrow** contract

### Process

#### Step 8.1: User Initiates Withdrawal

```solidity
StableYieldPool.redeem(uint256 shares, address receiver, address owner)
// OR
StableYieldPool.withdraw(uint256 assets, address receiver, address owner)
```

**Prerequisites:**

- Pool must not be paused
- `shares > 0` or `assets > 0`
- `receiver != address(0)`
- `owner != address(0)`
- **30-day holding period must be satisfied**: `block.timestamp >= lastDepositTime[owner] + 30 days`
- If `msg.sender != owner`, must have allowance

#### Step 8.2: Manager Validates Withdrawal

```solidity
StableYieldManager.validateWithdrawal(poolAddress, shares, receiver, owner)
```

**Validations:**

- Caller must be the pool contract
- Pool must be registered and active
- `shares > 0`
- `receiver != address(0)`
- `owner != address(0)`

**Fee Calculation:**

```solidity
uint256 navPerShare = calculateNAVPerShare(poolAddress);
uint256 grossWithdrawalValue = (shares * navPerShare) / 1e18;
uint256 transactionFee = IFeeManager(feeManager).calculateProtocolFee(poolAddress, grossWithdrawalValue);
uint256 withdrawalValue = grossWithdrawalValue - transactionFee;
```

#### Step 8.3: Liquidity Check

**If `escrow.getPoolReserves() >= grossWithdrawalValue` (Immediate Withdrawal):**

**Actions:**

1. Allocates withdrawal fee:
   ```solidity
   escrow.allocateWithdrawalFee(transactionFee);
   ```
   - `poolReserves -= transactionFee`
   - `transactionFees += transactionFee`
2. Burns shares: `_burn(owner, shares)`
3. Withdraws assets: `escrow.withdraw(receiver, withdrawalValue)`
   - `poolReserves -= withdrawalValue`
   - `cashBuffer -= withdrawalValue`
   - Transfers assets to receiver
4. Returns `(shares, withdrawalValue)`

**Events Emitted:**

- `Withdraw(msg.sender, receiver, owner, withdrawalValue, shares)`
- `WithdrawalValidated(poolAddress, owner, shares, withdrawalValue, true)`
- `TransactionFeeCollected(poolAddress, "withdrawal", grossWithdrawalValue, transactionFee)` (if fee > 0)

**If `escrow.getPoolReserves() < grossWithdrawalValue` (Queued Withdrawal):**

**Actions:**

1. Queues withdrawal request:
   ```solidity
   _queueWithdrawal(poolAddress, owner, shares, withdrawalValue);
   ```
   - Creates `WithdrawalRequest` struct
   - Adds to `withdrawalRequests[poolAddress][requestId]`
   - Adds requestId to `userWithdrawalRequests[poolAddress][owner]`
   - Updates queue: `tail++`, `totalPendingValue += withdrawalValue`
2. Returns `(0, withdrawalValue)` (no shares burned yet)

**Events Emitted:**

- `WithdrawalQueued(poolAddress, owner, requestId, shares, withdrawalValue)`
- `WithdrawalValidated(poolAddress, owner, shares, withdrawalValue, false)`

#### Step 8.4: Processing Queued Withdrawals

```solidity
StableYieldManager.processWithdrawalQueue(poolAddress, maxRequests)
```

**Prerequisites:**

- Operator must have `OPERATOR_ROLE`
- Pool must be active

**Process:**

1. Iterates through queue from `head` to `tail`
2. For each unprocessed request:
   - If `escrow.getPoolReserves() >= request.estimatedValue`:
     - Processes withdrawal
     - Burns shares
     - Withdraws assets
     - Marks request as processed
     - Updates `totalPendingValue`
3. Updates `queue.head` to new position

**Events Emitted:**

- `WithdrawalProcessed(poolAddress, user, requestId, actualValue, penaltyDeducted)`

---

## 9. Monthly Fee Collection

### Actors

- **Operator** (with `OPERATOR_ROLE`)
- **StableYieldManager** contract
- **StableYieldEscrow** contract
- **FeeManager** contract

### Process

#### Step 9.1: Operator Triggers Monthly Fee Collection

```solidity
StableYieldManager.collectMonthlyFees(poolAddress)
```

**Prerequisites:**

- Operator must have `OPERATOR_ROLE`
- Pool must exist
- `feeManager != address(0)`

**Calculation:**

1. Gets total gross value: `instruments value + poolReserves`
2. Calculates current accrued fees:
   ```solidity
   annualFee = (totalGrossValue * expenseRatioBps) / 10000
   currentAccrued = (annualFee * timeElapsed) / SECONDS_PER_YEAR
   totalOwed = deferredFees + currentAccrued
   ```
3. Determines collection amount based on liquidity constraints:
   - Maintains 5% liquidity floor
   - Maintains 10% redemption buffer
   - Collects up to 80% of available liquidity above floors

#### Step 9.2: Fee Sweep Processing

```solidity
_processFeeSweep(poolAddress, escrow, totalGrossValue, totalOwed)
```

**Actions:**

1. Calculates safe collection amount:
   ```solidity
   availableLiquidity = cashBuffer - liquidityFloor - minRedemptionBuffer
   collectionAmount = min(totalOwed, availableLiquidity * 0.8)
   ```
2. If `collectionAmount > 0`:
   - Calls `escrow.collectExpenseRatioFees(collectionAmount)`
   - Escrow moves funds: `poolReserves -= amount`, `expenseRatioFees += amount`
   - Updates `deferredFees = totalOwed - collectionAmount`
   - Updates `lastFeeAccrual = block.timestamp`
3. If `collectionAmount == 0`:
   - Defers all fees: `deferredFees = totalOwed`

**State Changes:**

- `deferredFees[poolAddress]` updated
- `lastFeeAccrual[poolAddress] = block.timestamp`
- `expenseRatioFees` in escrow increased
- `poolReserves` in escrow decreased

**Events Emitted:**

- `FeeSweptComplete(poolAddress, collectionAmount, 0)` (if fully collected)
- `FeeSweptPartial(poolAddress, collectionAmount, deferredAmount)` (if partially collected)
- `FeeSweptDeferred(poolAddress, totalOwed)` (if none collected)

**Note:** Expense ratio fees remain in escrow until manually transferred to treasury via `transferFeesToTreasury()`.

---

## 10. State Variables & Accounting

### StableYieldPool State

```solidity
mapping(address => uint256) public lastDepositTime;  // 30-day holding period tracking
uint256 public totalSupply;                          // Total shares outstanding
```

### StableYieldEscrow State

```solidity
uint256 public cashBuffer;          // Total cash in escrow
uint256 public poolReserves;        // Available for investing/withdrawals
uint256 public transactionFees;      // Accumulated deposit/withdrawal fees
uint256 public expenseRatioFees;    // Accumulated management fees
mapping(address => uint256) public spvAllocations;  // Funds allocated to SPV
```

**Accounting Relationship:**

```
cashBuffer = poolReserves + transactionFees + expenseRatioFees
```

### StableYieldManager State

```solidity
mapping(address => PoolData) public pools;                    // Pool configurations
mapping(address => InstrumentHolding[]) public poolInstruments;  // Active instruments
mapping(address => uint256) public poolInstrumentCount;      // Instrument count
mapping(address => uint256) public deferredFees;            // Deferred expense ratio fees
mapping(address => uint256) public lastFeeAccrual;           // Last fee accrual timestamp
mapping(address => WithdrawalQueue) public poolQueues;       // Withdrawal queues
mapping(address => mapping(uint256 => WithdrawalRequest)) public withdrawalRequests;  // Individual requests
```

### NAV Calculation

**Gross Asset Value (GAV):**

```
GAV = sum(instrumentValues) + poolReserves
```

**Net Asset Value (NAV):**

```
NAV = GAV - accruedFees - deferredFees
```

**NAV Per Share:**

```
navPerShare = (NAV * 1e18) / totalShares
```

**Instrument Valuation:**

- **Discounted (T-bills):** Linear accretion from purchase price to face value
- **Interest-Bearing (Bonds):** Face value + accrued interest since last coupon

### Fee Accounting

**Transaction Fees:**

- Calculated: `amount * protocolFeeRate / 10000`
- Allocated immediately during deposit/withdrawal
- Accumulated in `escrow.transactionFees`
- Transferred to treasury manually via `transferFeesToTreasury()`

**Expense Ratio Fees:**

- Accrued continuously: `(totalGrossValue * expenseRatio * timeElapsed) / (10000 * SECONDS_PER_YEAR)`
- Collected monthly via `collectMonthlyFees()`
- Can be deferred if insufficient liquidity
- Accumulated in `escrow.expenseRatioFees`
- Transferred to treasury manually via `transferFeesToTreasury()`

---

## Key Design Principles

1. **Separation of Concerns:**

   - Pool: ERC4626 vault interface, user interactions
   - Manager: Business logic, NAV calculation, instrument management
   - Escrow: Asset custody, fee tracking, SPV coordination

2. **NAV-Based Pricing:**

   - All deposits/withdrawals priced at current NAV
   - NAV includes instrument valuations + cash reserves - accrued fees
   - Shares represent proportional ownership of NAV

3. **Liquidity Management:**

   - 10% reserve ratio target (configurable)
   - Withdrawal queue for insufficient liquidity
   - Fee collection respects liquidity constraints

4. **SPV Trust Model:**

   - SPV has `SPV_ROLE` to attest to holdings
   - SPV allocates capital off-chain
   - SPV must attest to purchases via `addInstrument()`
   - SPV must return proceeds via `receiveSPVMaturity()`

5. **Fee Collection:**
   - Transaction fees: Immediate allocation, manual sweep
   - Expense ratio fees: Continuous accrual, monthly collection with deferral
   - Both accumulate in escrow until manually transferred to treasury

---

## Event Summary

### Pool Lifecycle Events

- `PoolRegistered` - Pool registered in manager
- `StableYieldPoolCreated` - Pool deployed by factory
- `Deposit` - User deposits assets
- `DepositValidated` - Manager validates deposit
- `Withdraw` - User withdraws assets
- `WithdrawalValidated` - Manager validates withdrawal
- `WithdrawalQueued` - Withdrawal queued due to insufficient liquidity
- `WithdrawalProcessed` - Queued withdrawal processed

### Instrument Events

- `InstrumentPurchased` - SPV adds new instrument
- `InstrumentMatured` - Instrument reaches maturity
- `CouponPaymentReceived` - SPV records coupon payment
- `InstrumentRemoved` - Instrument removed from tracking

### SPV Events

- `SPVAllocation` - Funds allocated to SPV
- `SPVLiquidityReceived` - SPV returns proceeds to escrow

### NAV Events

- `NAVCalculated` - NAV calculation completed
- `NAVUpdated` - NAV updated due to state change

### Fee Events

- `TransactionFeeCollected` - Transaction fee allocated
- `FeeSweptComplete` - Monthly fees fully collected
- `FeeSweptPartial` - Monthly fees partially collected
- `FeeSweptDeferred` - Monthly fees deferred
- `FeesCollected` - Fees transferred to treasury

---

## Security Considerations

1. **Access Control:**

   - Pool creation: `POOL_CREATOR_ROLE`
   - SPV operations: `SPV_ROLE`
   - Operator functions: `OPERATOR_ROLE`
   - Admin functions: `DEFAULT_ADMIN_ROLE`

2. **Holding Period:**

   - 30-day minimum holding period enforced
   - Prevents immediate withdrawals after deposit
   - Emergency bypass available to operators

3. **Reentrancy Protection:**

   - `nonReentrant` modifier on critical functions
   - Checks-Effects-Interactions pattern

4. **Liquidity Safety:**

   - Reserve ratio maintenance
   - Withdrawal queue for insufficient liquidity
   - Fee collection respects liquidity constraints

5. **NAV Integrity:**
   - NAV calculated from on-chain instrument data
   - SPV must attest to all holdings
   - Fees properly deducted from NAV

---

## Conclusion

The Stable Yield Pool lifecycle is designed to provide a transparent, secure, and efficient mechanism for managing yield-generating instruments while maintaining proper accounting, liquidity management, and fee collection. The separation of concerns between Pool, Manager, and Escrow ensures clear responsibilities and auditability.
