// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../types/IStableYieldTypes.sol";
import "../escrows/StableYieldEscrow.sol";

/**
 * @title StableYieldNAVLibrary
 * @dev Library for calculating Net Asset Value (NAV) for stable yield pools
 * @notice Handles NAV calculation including instrument valuations and fee accruals
 */
library StableYieldNAVLibrary {
    
    uint256 constant SECONDS_PER_YEAR = 365 days;
    
    event NAVCalculated(address indexed poolAddress, uint256 totalNAV, uint256 navPerShare, uint256 totalShares, uint256 timestamp);
    event NAVUpdated(address indexed poolAddress, uint256 totalNAV, uint256 navPerShare, string reason, uint256 timestamp);
    
    /**
     * @notice Calculate pool NAV net of accrued fees
     * @param poolData Pool data storage
     * @param instruments Array of instrument holdings
     * @param deferredFees Deferred fees for the pool
     * @param lastFeeAccrual Last fee accrual timestamp
     * @param feeManager Fee manager address
     * @return totalNAV Current NAV net of accrued fees
     */
    function calculatePoolNAV(
        IStableYieldTypes.PoolData storage poolData,
        IStableYieldTypes.InstrumentHolding[] storage instruments,
        uint256 deferredFees,
        uint256 lastFeeAccrual,
        address feeManager
    ) public view returns (uint256 totalNAV) {
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        
        uint256 grossAssetValue = calculateGrossAssetValue(instruments);
        uint256 poolReserves = escrow.getPoolReserves();
        uint256 totalGrossValue = grossAssetValue + poolReserves;
        
        uint256 accruedFees = calculateCurrentAccruedFees(
            poolData,
            deferredFees,
            lastFeeAccrual,
            feeManager,
            totalGrossValue
        );
        
        totalNAV = totalGrossValue > accruedFees ? totalGrossValue - accruedFees : 0;
        
        return totalNAV;
    }
    
    /**
     * @notice Calculate NAV per share
     * @param poolAddress Pool address
     * @param poolData Pool data storage
     * @param instruments Array of instrument holdings
     * @param deferredFees Deferred fees for the pool
     * @param lastFeeAccrual Last fee accrual timestamp
     * @param feeManager Fee manager address
     * @return navPerShare NAV per share (normalized to 18 decimals)
     */
    function calculateNAVPerShare(
        address poolAddress,
        IStableYieldTypes.PoolData storage poolData,
        IStableYieldTypes.InstrumentHolding[] storage instruments,
        uint256 deferredFees,
        uint256 lastFeeAccrual,
        address feeManager
    ) public view returns (uint256 navPerShare) {
        uint256 totalNAV = calculatePoolNAV(poolData, instruments, deferredFees, lastFeeAccrual, feeManager);
        
        uint256 totalShares = IERC20(poolData.poolAddress).totalSupply();
        
        if (totalShares == 0) {
            return 1e18; 
        }
        
        // Calculate NAV per share: (totalNAV * 1e18) / totalShares
        // totalNAV is in asset decimals, totalShares is raw count
        // Result is normalized to 1e18 precision
        return (totalNAV * 1e18) / totalShares;
    }
    
    /**
     * @notice Calculate gross asset value from all instruments
     * @param instruments Array of instrument holdings
     * @return grossValue Total value of all instruments
     */
    function calculateGrossAssetValue(
        IStableYieldTypes.InstrumentHolding[] storage instruments
    ) public view returns (uint256 grossValue) {
        uint256 length = instruments.length;
        uint256 currentTime = block.timestamp;
        
        for (uint256 i; i < length;) {
            IStableYieldTypes.InstrumentHolding storage instrument = instruments[i];
            
            if (instrument.instrumentType == IStableYieldTypes.InstrumentType.DISCOUNTED) {
                grossValue += calculateDiscountedValue(instrument, currentTime);
            } else {
                grossValue += calculateInterestBearingValue(instrument, currentTime);
            }
            
            unchecked { ++i; }
        }

        return grossValue;
    }
    
    /**
     * @notice Calculate current accrued fees for NAV-neutral pricing
     * @param poolData Pool data storage
     * @param deferredFees Deferred fees
     * @param lastAccrual Last fee accrual timestamp
     * @param feeManager Fee manager address
     * @param totalGrossValue Total gross pool value
     * @return accruedFees Current accrued fees (including deferred)
     */
    function calculateCurrentAccruedFees(
        IStableYieldTypes.PoolData storage poolData,
        uint256 deferredFees,
        uint256 lastAccrual,
        address feeManager,
        uint256 totalGrossValue
    ) public view returns (uint256 accruedFees) {
        if (feeManager == address(0)) return deferredFees;
        
        // Dynamic call to fee manager
        (bool success, bytes memory data) = feeManager.staticcall(
            abi.encodeWithSignature("getPoolExpenseRatio(address)", poolData.poolAddress)
        );
        
        if (!success || data.length == 0) return deferredFees;
        
        uint256 expenseRatioBps = abi.decode(data, (uint256));
        if (expenseRatioBps == 0) return deferredFees;
        
        uint256 lastAccrualTime = lastAccrual == 0 ? poolData.createdAt : lastAccrual;
        
        uint256 timeElapsed = block.timestamp - lastAccrualTime;
        if (timeElapsed == 0) return deferredFees;

        uint256 annualFee = (totalGrossValue * expenseRatioBps) / 10000;
        uint256 currentAccrued = (annualFee * timeElapsed) / SECONDS_PER_YEAR;
        
        return deferredFees + currentAccrued;
    }
    
    /**
     * @notice Calculate discounted instrument value
     * @param instrument Instrument data
     * @param currentTime Current timestamp
     * @return value Current value of discounted instrument
     */
    function calculateDiscountedValue(
        IStableYieldTypes.InstrumentHolding storage instrument,
        uint256 currentTime
    ) public view returns (uint256 value) {
        uint256 timeElapsed = currentTime - instrument.purchaseDate;
        uint256 totalTime = instrument.maturityDate - instrument.purchaseDate;
        
        if (timeElapsed >= totalTime) {
            return instrument.faceValue;
        }
        
        return instrument.purchasePrice + ((instrument.faceValue - instrument.purchasePrice) * timeElapsed) / totalTime;
    }
    
    /**
     * @notice Calculate interest-bearing instrument value
     * @param instrument Instrument data
     * @param currentTime Current timestamp
     * @return value Current value including accrued interest
     */
    function calculateInterestBearingValue(
        IStableYieldTypes.InstrumentHolding storage instrument,
        uint256 currentTime
    ) public view returns (uint256 value) {
        uint256 couponPeriodSeconds = SECONDS_PER_YEAR / instrument.couponFrequency;
        uint256 lastCouponDate = instrument.couponsPaid == 0 ? 
            instrument.purchaseDate : 
            instrument.nextCouponDueDate - couponPeriodSeconds;
        
        uint256 timeSinceLastCoupon = currentTime - lastCouponDate;
        uint256 couponAmount = (instrument.faceValue * instrument.annualCouponRate) / (10000 * instrument.couponFrequency);
        
        // Accrued interest = (couponAmount * timeSinceLastCoupon) / couponPeriodSeconds
        uint256 accruedInterest = (couponAmount * timeSinceLastCoupon) / couponPeriodSeconds;
        
        return instrument.faceValue + accruedInterest;
    }
    
    /**
     * @notice Trigger NAV update and emit events
     * @param poolAddress Pool address
     * @param poolData Pool data storage
     * @param instruments Array of instrument holdings
     * @param deferredFees Deferred fees
     * @param lastFeeAccrual Last fee accrual timestamp
     * @param feeManager Fee manager address
     * @param reason Reason for update
     */
    function triggerNAVUpdate(
        address poolAddress,
        IStableYieldTypes.PoolData storage poolData,
        IStableYieldTypes.InstrumentHolding[] storage instruments,
        uint256 deferredFees,
        uint256 lastFeeAccrual,
        address feeManager,
        string memory reason
    ) external {
        uint256 totalNAV = calculatePoolNAV(poolData, instruments, deferredFees, lastFeeAccrual, feeManager);
        uint256 totalShares = IERC20(poolData.poolAddress).totalSupply();
        uint256 navPerShare = calculateNAVPerShare(poolAddress, poolData, instruments, deferredFees, lastFeeAccrual, feeManager);
        
        emit NAVUpdated(poolAddress, totalNAV, navPerShare, reason, block.timestamp);
        emit NAVCalculated(poolAddress, totalNAV, navPerShare, totalShares, block.timestamp);
    }
}

