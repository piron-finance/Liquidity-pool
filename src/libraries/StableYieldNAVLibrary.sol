// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../types/IStableYieldTypes.sol";
import "../escrows/StableYieldEscrow.sol";

/**
 * @title StableYieldNAVLibrary
 * @dev Net Asset Value calculations for StableYieldPools: gross asset value (discounted +
 *      interest-bearing instruments), pool reserves, NAV per share, and NAV event triggers.
 */
library StableYieldNAVLibrary {
    
    uint256 constant SECONDS_PER_YEAR = 365 days;

    // ==================== EVENTS ====================
    
    event NAVCalculated(address indexed poolAddress, uint256 totalNAV, uint256 navPerShare, uint256 totalShares, uint256 timestamp);
    event NAVUpdated(address indexed poolAddress, uint256 totalNAV, uint256 navPerShare, string reason, uint256 timestamp);

    // ==================== NAV CALCULATION ====================
    
    /// @dev Total NAV = gross asset value (instruments) + pool reserves (escrow balance).
    function calculatePoolNAV(
        IStableYieldTypes.PoolData storage poolData,
        IStableYieldTypes.InstrumentHolding[] storage instruments
    ) public view returns (uint256 totalNAV) {
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        
        uint256 grossAssetValue = calculateGrossAssetValue(instruments);
        uint256 poolReserves = escrow.getPoolReserves();
        
        return grossAssetValue + poolReserves;
    }
    
    /// @dev NAV per share in 1e18 precision. Returns 1e18 when no shares exist.
    function calculateNAVPerShare(
        IStableYieldTypes.PoolData storage poolData,
        IStableYieldTypes.InstrumentHolding[] storage instruments
    ) public view returns (uint256 navPerShare) {
        uint256 totalNAV = calculatePoolNAV(poolData, instruments);
        
        uint256 totalShares = IERC20(poolData.poolAddress).totalSupply();
        
        if (totalShares == 0) {
            return 1e18; 
        }
        
        return (totalNAV * 1e18) / totalShares;
    }
    
    // ==================== GROSS ASSET VALUE ====================

    /// @dev Sums mark-to-market values of all active instrument holdings.
    function calculateGrossAssetValue(
        IStableYieldTypes.InstrumentHolding[] storage instruments
    ) public view returns (uint256 grossValue) {
        uint256 length = instruments.length;
        uint256 currentTime = block.timestamp;
        
        for (uint256 i; i < length;) {
            IStableYieldTypes.InstrumentHolding storage instrument = instruments[i];
            
            if (instrument.isActive) {
                if (instrument.instrumentType == IStableYieldTypes.InstrumentType.DISCOUNTED) {
                    grossValue += calculateDiscountedValue(instrument, currentTime);
                } else {
                    grossValue += calculateInterestBearingValue(instrument, currentTime);
                }
            }
            
            unchecked { ++i; }
        }

        return grossValue;
    }
    
    // ==================== INSTRUMENT VALUATION ====================

    /// @dev Linear accrual from purchasePrice to faceValue over the instrument lifetime.
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
    
    /// @dev Face value + accrued interest since the last coupon date.
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
        uint256 accruedInterest = (couponAmount * timeSinceLastCoupon) / couponPeriodSeconds;
        
        return instrument.faceValue + accruedInterest;
    }
    
    // ==================== NAV UPDATE TRIGGER ====================

    /// @dev Emits NAVUpdated and NAVCalculated events for off-chain indexing.
    function triggerNAVUpdate(
        address poolAddress,
        IStableYieldTypes.PoolData storage poolData,
        IStableYieldTypes.InstrumentHolding[] storage instruments,
        string memory reason
    ) external {
        uint256 totalNAV = calculatePoolNAV(poolData, instruments);
        uint256 totalShares = IERC20(poolData.poolAddress).totalSupply();
        uint256 navPerShare = calculateNAVPerShare( poolData, instruments);
        
        emit NAVUpdated(poolAddress, totalNAV, navPerShare, reason, block.timestamp);
        emit NAVCalculated(poolAddress, totalNAV, navPerShare, totalShares, block.timestamp);
    }
}
