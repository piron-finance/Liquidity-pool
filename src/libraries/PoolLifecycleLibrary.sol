// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../types/IPoolTypes.sol";
import "../interfaces/IPoolRegistry.sol";
import "../interfaces/IPoolEscrow.sol";
import "./CalculationLibrary.sol";
import "./ValidationLibrary.sol";

/**
 * @title PoolLifecycleLibrary
 * @dev Library for managing pool lifecycle state transitions and investment processing
 * @notice Handles epoch closing, investment processing, and pool maturity
 */
library PoolLifecycleLibrary {
    
    event PoolFilled(address indexed pool, uint256 totalRaised, uint256 timestamp);
    event InvestmentConfirmed(uint256 actualAmount, string proofHash);
    event MaturityProcessed(uint256 finalAmount);
    event SPVFundsWithdrawn(address indexed pool, uint256 amount, bytes32 transferId);
    event SPVFundsReturned(address indexed pool, uint256 amount);
    event PoolFullyWithdrawn(address indexed pool, uint256 timestamp);
    event EmergencyStateChanged(address indexed poolAddress, string trigger, uint256 totalAmount, uint256 totalShares, uint256 timestamp);
    
    /**
     * @notice Handle when pool reaches target raise amount
     * @param pools Storage mapping of pool data
     * @param registry Pool registry contract
     * @param liquidityPool Pool address
     */
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
    
    /**
     * @notice Close epoch and transition to investment phase
     * @param pools Storage mapping of pool data
     * @param registry Pool registry contract
     * @param liquidityPool Pool address
     * @return newStatus New pool status after closing
     */
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
    
    /**
     * @notice Force close epoch (emergency)
     * @param pools Storage mapping of pool data
     * @param registry Pool registry contract
     * @param liquidityPool Pool address
     * @return newStatus New pool status after force closing
     */
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
    
    /**
     * @notice SPV withdraws funds from escrow for investment
     * @param pools Storage mapping of pool data
     * @param registry Pool registry contract
     * @param liquidityPool Pool address
     * @param amount Amount to withdraw
     * @return transferId Unique transfer identifier
     */
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
    
    /**
     * @notice Process SPV investment confirmation
     * @param pools Storage mapping of pool data
     * @param registry Pool registry contract
     * @param liquidityPool Pool address
     * @param actualAmount Actual amount invested
     * @param proofHash Proof of investment
     */
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
    
    /**
     * @notice Process pool maturity
     * @param pools Storage mapping of pool data
     * @param registry Pool registry contract
     * @param liquidityPool Pool address
     * @param finalAmount Final maturity amount
     */
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
        
        IERC20(poolInfo.asset).transferFrom(msg.sender, poolInfo.escrow, finalAmount);
        
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.trackMaturityReturn(finalAmount);
        
        poolData.fundsReturnedBySPV += finalAmount;
        poolData.status = IPoolTypes.PoolStatus.MATURED;
        
        emit MaturityProcessed(finalAmount);
        emit SPVFundsReturned(liquidityPool, finalAmount);
    }
    
    /**
     * @notice Mark pool as fully withdrawn
     * @param pools Storage mapping of pool data
     * @param pool Pool address
     */
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

