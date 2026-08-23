// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../types/IStableYieldTypes.sol";
import "../escrows/StableYieldEscrow.sol";

/**
 * @title StableYieldNAVLibrary
 * @dev Asset valuation for StableYieldPools: mark-to-market of discounted and
 *      interest-bearing instruments, plus escrow reserves.
 *
 *      This is the base NAV only. Capital drawn by an SPV and not yet placed is held by
 *      StableYieldManager and added there, so StableYieldManager.calculatePoolNAV is the
 *      authoritative figure.
 */
library StableYieldNAVLibrary {
    
    uint256 constant SECONDS_PER_YEAR = 365 days;

    // ==================== NAV CALCULATION ====================
    
    /// @dev Base NAV = gross asset value (instruments) + pool reserves (escrow balance).
    function calculatePoolNAV(
        IStableYieldTypes.PoolData storage poolData,
        IStableYieldTypes.InstrumentHolding[] storage instruments
    ) public view returns (uint256 totalNAV) {
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        
        uint256 grossAssetValue = calculateGrossAssetValue(instruments);
        uint256 poolReserves = escrow.getPoolReserves();
        
        return grossAssetValue + poolReserves;
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
        // Interest stops accruing at maturity. Without this an instrument the SPV never
        // settles keeps inflating NAV forever, and holders redeem against value that
        // does not exist.
        if (currentTime > instrument.maturityDate) {
            currentTime = instrument.maturityDate;
        }
        
        uint256 couponPeriodSeconds = SECONDS_PER_YEAR / instrument.couponFrequency;
        uint256 lastCouponDate = instrument.couponsPaid == 0 ? 
            instrument.purchaseDate : 
            instrument.nextCouponDueDate - couponPeriodSeconds;
        
        uint256 timeSinceLastCoupon = currentTime - lastCouponDate;
        uint256 couponAmount = (instrument.faceValue * instrument.annualCouponRate) / (10000 * instrument.couponFrequency);
        uint256 accruedInterest = (couponAmount * timeSinceLastCoupon) / couponPeriodSeconds;
        
        return instrument.faceValue + accruedInterest;
    }
}
