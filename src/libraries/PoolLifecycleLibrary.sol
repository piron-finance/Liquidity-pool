// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../types/IPoolTypes.sol";
import "../interfaces/IPoolRegistry.sol";
import "../interfaces/IPoolEscrow.sol";
import "./CalculationLibrary.sol";
import "./ValidationLibrary.sol";

/**
 * @title PoolLifecycleLibrary
 * @dev State machine for Single-Asset (deal) pools: FUNDING → FILLED → PENDING_INVESTMENT →
 *      INVESTED → MATURED → WITHDRAWN (or EMERGENCY at any point).
 *      Handles epoch closing, SPV fund transfers, investment confirmation, and maturity processing.
 */
library PoolLifecycleLibrary {
    using SafeERC20 for IERC20;

    // ==================== EVENTS ====================
    
    event PoolFilled(address indexed pool, uint256 totalRaised, uint256 timestamp);
    event InvestmentConfirmed(uint256 actualAmount, string proofHash);
    event MaturityProcessed(uint256 finalAmount);
    event SPVFundsWithdrawn(address indexed pool, uint256 amount, bytes32 transferId);
    event SPVFundsReturned(address indexed pool, uint256 amount);
    event PoolFullyWithdrawn(address indexed pool, uint256 timestamp);
    event EmergencyStateChanged(address indexed poolAddress, string trigger, uint256 totalAmount, uint256 totalShares, uint256 timestamp);
    event MaturityShortfall(address indexed pool, uint256 expected, uint256 actual, uint256 shortfall);
    event MaturityOverage(address indexed pool, uint256 expected, uint256 actual);

    // ==================== POOL FILLED ====================
    
    /// @dev Transitions pool from FUNDING to FILLED when target raise is met.
    function handlePoolFilled(
        mapping(address => IPoolTypes.PoolData) storage pools,
        IPoolRegistry registry,
        address liquidityPool
    ) external {
        require(registry.isRegisteredPool(liquidityPool), "PoolLifecycle/invalid pool");
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        require(poolData.status == IPoolTypes.PoolStatus.FUNDING, "Not in funding");
        require(poolData.totalRaised >= poolData.config.targetRaise, "Not filled");

        poolData.status = IPoolTypes.PoolStatus.FILLED;

        emit PoolFilled(liquidityPool, poolData.totalRaised, block.timestamp);
    }
    
    // ==================== EPOCH CLOSE ====================

    /// @dev Closes the epoch: transitions to PENDING_INVESTMENT if funded, EMERGENCY otherwise.
    function closeEpoch(
        mapping(address => IPoolTypes.PoolData) storage pools,
        IPoolRegistry registry,
        address liquidityPool
    ) external returns (IPoolTypes.PoolStatus newStatus) {
        require(registry.isRegisteredPool(liquidityPool), "PoolLifecycle/invalid pool");
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        require(
            poolData.status == IPoolTypes.PoolStatus.FUNDING || 
            poolData.status == IPoolTypes.PoolStatus.FILLED, 
            "PoolLifecycle/not in funding"
        );

        if (poolData.status == IPoolTypes.PoolStatus.FUNDING) {
            require(block.timestamp >= poolData.config.epochEndTime, "PoolLifecycle/epoch not ended");
        }
        
        uint256 amountRaised = poolData.totalRaised;
        uint256 minimumRequired = poolData.config.targetRaise * poolData.config.minimumFundingThreshold / 10000;
        
        if (amountRaised >= minimumRequired) {
            if (poolData.config.instrumentType == IPoolTypes.InstrumentType.DISCOUNTED) {
                poolData.config.faceValue = CalculationLibrary.calculateFaceValue(amountRaised, poolData.config.discountRate);
            } else {
                poolData.config.faceValue = 0;
            }
            
            poolData.status = IPoolTypes.PoolStatus.PENDING_INVESTMENT;
            return IPoolTypes.PoolStatus.PENDING_INVESTMENT;
        } else {
            poolData.status = IPoolTypes.PoolStatus.EMERGENCY;
            
            emit EmergencyStateChanged(
                liquidityPool,
                "UNDERFUNDED_EPOCH",
                amountRaised,
                IERC20(liquidityPool).totalSupply(),
                block.timestamp
            );
            return IPoolTypes.PoolStatus.EMERGENCY;
        }
    }
    
    /// @dev Admin force-close: same logic as closeEpoch but skips the epochEndTime check.
    function forceCloseEpoch(
        mapping(address => IPoolTypes.PoolData) storage pools,
        IPoolRegistry registry,
        address liquidityPool
    ) external returns (IPoolTypes.PoolStatus newStatus) {
        require(registry.isRegisteredPool(liquidityPool), "PoolLifecycle/invalid pool");
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        require(poolData.status == IPoolTypes.PoolStatus.FUNDING, "PoolLifecycle/not in funding");
        
        uint256 raisedAmount = poolData.totalRaised;
        uint256 minimumRequired = poolData.config.targetRaise * poolData.config.minimumFundingThreshold / 10000;
        
        if (raisedAmount >= minimumRequired) {
            if (poolData.config.instrumentType == IPoolTypes.InstrumentType.DISCOUNTED) {
                poolData.config.faceValue = CalculationLibrary.calculateFaceValue(raisedAmount, poolData.config.discountRate);
            } else {
                poolData.config.faceValue = 0;
            }
            
            poolData.status = IPoolTypes.PoolStatus.PENDING_INVESTMENT;
            return IPoolTypes.PoolStatus.PENDING_INVESTMENT;
        } else {
            poolData.status = IPoolTypes.PoolStatus.EMERGENCY;
            return IPoolTypes.PoolStatus.EMERGENCY;
        }
    }
    
    // ==================== SPV FUND TRANSFER ====================

    /// @dev Withdraws funds from escrow for the SPV to invest in the underlying instrument.
    function withdrawFundsForInvestment(
        mapping(address => IPoolTypes.PoolData) storage pools,
        IPoolRegistry registry,
        address liquidityPool,
        uint256 amount
    ) external returns (bytes32 transferId) {
        require(registry.isRegisteredPool(liquidityPool), "PoolLifecycle/invalid pool");
        require(pools[liquidityPool].status == IPoolTypes.PoolStatus.PENDING_INVESTMENT, "PoolLifecycle/not pending investment");
        require(amount != 0, "PoolLifecycle/invalid amount");

        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        
        transferId = escrowContract.withdrawForInvestment(amount);
        
        pools[liquidityPool].fundsWithdrawnBySPV += amount;
        
        emit SPVFundsWithdrawn(liquidityPool, amount, transferId);
        
        return transferId;
    }
    
    // ==================== INVESTMENT CONFIRMATION ====================

    /// @dev Confirms the SPV investment: records actual amount and transitions to INVESTED.
    function processInvestment(
        mapping(address => IPoolTypes.PoolData) storage pools,
        IPoolRegistry registry,
        address liquidityPool,
        uint256 actualAmount,
        string memory proofHash
    ) external {
        require(registry.isRegisteredPool(liquidityPool), "PoolLifecycle/invalid pool");
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        require(poolData.status == IPoolTypes.PoolStatus.PENDING_INVESTMENT, "PoolLifecycle/not pending investment");
        
        require(actualAmount <= poolData.totalRaised, "PoolLifecycle/Cannot invest more than raised");
        require(actualAmount > 0, "PoolLifecycle/invalid amount");
        
        poolData.actualInvested = actualAmount;
        
        if (poolData.config.instrumentType == IPoolTypes.InstrumentType.DISCOUNTED) {
            poolData.config.faceValue = CalculationLibrary.calculateFaceValue(actualAmount, poolData.config.discountRate);
            uint256 totalDiscount = poolData.config.faceValue - actualAmount;
            poolData.totalDiscountEarned = totalDiscount;
        } else if (poolData.config.instrumentType == IPoolTypes.InstrumentType.INTEREST_BEARING) {
            poolData.config.faceValue = 0;
            if (poolData.config.couponDates.length > 0) {
                require(poolData.config.couponDates.length == poolData.config.couponRates.length, "PoolLifecycle/coupon config mismatch");
                require(poolData.config.couponDates[0] > block.timestamp, "PoolLifecycle/invalid coupon dates");
            }
        }
        
        poolData.status = IPoolTypes.PoolStatus.INVESTED;
        
        emit InvestmentConfirmed(actualAmount, proofHash);
    }
    
    // ==================== MATURITY ====================

    /// @dev Processes maturity: SPV returns funds to escrow, pool transitions to MATURED.
    function processMaturity(
        mapping(address => IPoolTypes.PoolData) storage pools,
        IPoolRegistry registry,
        address liquidityPool,
        uint256 finalAmount
    ) external {
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        ValidationLibrary.validateMaturityProcessing(poolData, registry, liquidityPool, finalAmount);
       
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        require(IERC20(poolInfo.asset).balanceOf(msg.sender) >= finalAmount, "PoolLifecycle/insufficient spv balance");
        
        uint256 expectedReturn = _calculateExpectedReturn(poolData);
        if (finalAmount < expectedReturn) {
            emit MaturityShortfall(liquidityPool, expectedReturn, finalAmount, expectedReturn - finalAmount);
        } else if (finalAmount > expectedReturn * 120 / 100) {
            emit MaturityOverage(liquidityPool, expectedReturn, finalAmount);
        }
        
        IERC20(poolInfo.asset).safeTransferFrom(msg.sender, poolInfo.escrow, finalAmount);
        
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.trackMaturityReturn(finalAmount);
        
        poolData.fundsReturnedBySPV += finalAmount;
        poolData.sharesAtMaturity = IERC20(liquidityPool).totalSupply();
        poolData.status = IPoolTypes.PoolStatus.MATURED;
        
        emit MaturityProcessed(finalAmount);
        emit SPVFundsReturned(liquidityPool, finalAmount);
    }
    
    function _calculateExpectedReturn(IPoolTypes.PoolData storage poolData) internal view returns (uint256) {
        if (poolData.config.instrumentType == IPoolTypes.InstrumentType.DISCOUNTED) {
            return poolData.config.faceValue;
        } else {
            return poolData.actualInvested;
        }
    }
    
    // ==================== POOL WITHDRAWN ====================

    /// @dev Marks a matured pool as WITHDRAWN once all shares have been redeemed.
    function markPoolWithdrawn(
        mapping(address => IPoolTypes.PoolData) storage pools,
        address pool
    ) external {
        IPoolTypes.PoolData storage poolData = pools[pool];
        require(poolData.status == IPoolTypes.PoolStatus.MATURED, "Pool not matured");

        uint256 remainingShares = IERC20(pool).totalSupply();
        require(remainingShares == 0, "PoolLifecycle/Shares still outstanding");

        poolData.status = IPoolTypes.PoolStatus.WITHDRAWN;

        emit PoolFullyWithdrawn(pool, block.timestamp);
    }
}
