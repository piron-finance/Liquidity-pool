// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../types/IStableYieldTypes.sol";
import "../escrows/StableYieldEscrow.sol";

/**
 * @title StableYieldInstrumentLibrary
 * @dev Library for managing financial instruments in stable yield pools
 * @notice Handles instrument additions, maturities, and coupon payments
 */
library StableYieldInstrumentLibrary {
    
    event InstrumentPurchased(
        address indexed poolAddress,
        uint256 indexed instrumentId,
        IStableYieldTypes.InstrumentType instrumentType,
        uint256 purchasePrice,
        uint256 faceValue,
        uint256 maturityDate
    );
    
    event InstrumentMatured(
        address indexed poolAddress,
        uint256 indexed instrumentId,
        uint256 faceValue,
        uint256 realizedYield
    );
    
    event CouponPaymentReceived(
        address indexed poolAddress,
        uint256 indexed instrumentId,
        uint256 couponAmount,
        uint256 couponNumber
    );
    
    event InstrumentRemoved(
        address indexed poolAddress,
        uint256 indexed instrumentId,
        string reason
    );
    
    /**
     * @notice Add new instrument to pool
     * @param poolData Pool data storage
     * @param instruments Array of instrument holdings
     * @param instrumentCount Current instrument count
     * @param instrumentType Type of instrument (DISCOUNTED or INTEREST_BEARING)
     * @param purchasePrice Amount paid for instrument
     * @param faceValue Maturity value
     * @param maturityDate When instrument matures
     * @param annualCouponRate Annual coupon rate in basis points (0 for T-bills)
     * @param couponFrequency Coupon frequency (0 for T-bills)
     * @return instrumentId ID of the newly added instrument
     */
    function addInstrument(
        IStableYieldTypes.PoolData storage poolData,
        IStableYieldTypes.InstrumentHolding[] storage instruments,
        uint256 instrumentCount,
        IStableYieldTypes.InstrumentType instrumentType,
        uint256 purchasePrice,
        uint256 faceValue,
        uint256 maturityDate,
        uint256 annualCouponRate,
        uint8 couponFrequency
    ) external returns (uint256 instrumentId) {
        require(purchasePrice > 0, "InstrumentLib/invalid purchase price");
        require(faceValue > 0, "InstrumentLib/invalid face value");
        require(maturityDate > block.timestamp, "InstrumentLib/invalid maturity date");
        
        if (instrumentType == IStableYieldTypes.InstrumentType.DISCOUNTED) {
            require(purchasePrice < faceValue, "InstrumentLib/discounted must be below face");
            require(annualCouponRate == 0, "InstrumentLib/discounted has no coupons");
            require(couponFrequency == 0, "InstrumentLib/discounted has no coupons");
        } else {
            require(annualCouponRate > 0, "InstrumentLib/interest bearing needs coupon rate");
            require(couponFrequency > 0, "InstrumentLib/interest bearing needs frequency");
        }

        uint256 nextCouponDate = 0;
        if (instrumentType == IStableYieldTypes.InstrumentType.INTEREST_BEARING) {
            uint256 couponPeriodSeconds = (365 days) / couponFrequency;
            nextCouponDate = block.timestamp + couponPeriodSeconds;
        }
        
        instruments.push(IStableYieldTypes.InstrumentHolding({
            instrumentType: instrumentType,
            purchasePrice: purchasePrice,
            faceValue: faceValue,
            purchaseDate: block.timestamp,
            maturityDate: maturityDate,
            annualCouponRate: annualCouponRate,
            couponFrequency: couponFrequency,
            nextCouponDueDate: nextCouponDate,
            couponsPaid: 0,
            isActive: true
        }));
        
        instrumentId = instruments.length - 1;
        
        // Note: SPV must allocate funds via allocateToSPV() before purchasing instruments
        // This function is called AFTER the instrument has been purchased with allocated funds
        // No validation against poolReserves needed as SPV is a trusted role
        
        emit InstrumentPurchased(
            poolData.poolAddress,
            instrumentId,
            instrumentType,
            purchasePrice,
            faceValue,
            maturityDate
        );
        
        return instrumentId;
    }
    
    /**
     * @notice Process matured instrument
     * @param poolData Pool data storage
     * @param instruments Array of instrument holdings
     * @param instrumentId Instrument ID
     */
    function matureInstrument(
        IStableYieldTypes.PoolData storage poolData,
        IStableYieldTypes.InstrumentHolding[] storage instruments,
        uint256 instrumentId
    ) external {
        require(instrumentId < instruments.length, "InstrumentLib/invalid instrument");
        
        IStableYieldTypes.InstrumentHolding storage instrument = instruments[instrumentId];
        require(instrument.isActive, "InstrumentLib/instrument not active");
        require(block.timestamp >= instrument.maturityDate, "InstrumentLib/not matured");
        
        uint256 realizedYield = instrument.faceValue - instrument.purchasePrice;
        uint256 finalValue = instrument.faceValue;
        
        instrument.isActive = false;
        
        emit InstrumentMatured(poolData.poolAddress, instrumentId, finalValue, realizedYield);
        emit InstrumentRemoved(poolData.poolAddress, instrumentId, "matured");
    }
    
    /**
     * @notice Record coupon payment for interest-bearing instrument
     * @param poolData Pool data storage
     * @param instruments Array of instrument holdings
     * @param instrumentId Instrument ID
     * @param couponAmount Amount of coupon received
     */
    function recordCouponPayment(
        IStableYieldTypes.PoolData storage poolData,
        IStableYieldTypes.InstrumentHolding[] storage instruments,
        uint256 instrumentId,
        uint256 couponAmount
    ) external {
        require(instrumentId < instruments.length, "InstrumentLib/invalid instrument");
        
        IStableYieldTypes.InstrumentHolding storage instrument = instruments[instrumentId];
        require(instrument.isActive, "InstrumentLib/instrument not active");
        require(
            instrument.instrumentType == IStableYieldTypes.InstrumentType.INTEREST_BEARING,
            "InstrumentLib/not interest bearing"
        );
        require(block.timestamp >= instrument.nextCouponDueDate, "InstrumentLib/coupon not due");

        instrument.couponsPaid++;
        
        if (block.timestamp < instrument.maturityDate) {
            uint256 couponPeriodSeconds = (365 days) / instrument.couponFrequency;
            instrument.nextCouponDueDate += couponPeriodSeconds;
        }
        
        emit CouponPaymentReceived(
            poolData.poolAddress,
            instrumentId,
            couponAmount,
            instrument.couponsPaid
        );
    }
    
    /**
     * @notice Sell/liquidate instrument early
     * @param poolData Pool data storage
     * @param instruments Array of instrument holdings
     * @param instrumentId Instrument ID
     * @param salePrice Price received from sale
     * @return realizedValue Realized value from sale
     */
    function sellInstrument(
        IStableYieldTypes.PoolData storage poolData,
        IStableYieldTypes.InstrumentHolding[] storage instruments,
        uint256 instrumentId,
        uint256 salePrice
    ) external returns (uint256 realizedValue) {
        require(instrumentId < instruments.length, "InstrumentLib/invalid instrument");
        
        IStableYieldTypes.InstrumentHolding storage instrument = instruments[instrumentId];
        require(instrument.isActive, "InstrumentLib/instrument not active");
        require(salePrice > 0, "InstrumentLib/invalid sale price");
        
        instrument.isActive = false;
        
        emit InstrumentRemoved(poolData.poolAddress, instrumentId, "sold");
        
        return salePrice;
    }
    
    /**
     * @notice Batch remove multiple matured instruments
     * @param poolData Pool data storage
     * @param instruments Array of instrument holdings
     * @param instrumentIds Array of instrument IDs to remove
     * @return removedCount Number of instruments removed
     */
    function batchRemoveInstruments(
        IStableYieldTypes.PoolData storage poolData,
        IStableYieldTypes.InstrumentHolding[] storage instruments,
        uint256[] memory instrumentIds
    ) external returns (uint256 removedCount) {
        uint256 removed = 0;
        
        for (uint256 i = 0; i < instrumentIds.length; i++) {
            uint256 instrumentId = instrumentIds[i];
            
            if (instrumentId < instruments.length) {
                IStableYieldTypes.InstrumentHolding storage instrument = instruments[instrumentId];
                
                if (instrument.isActive && block.timestamp >= instrument.maturityDate) {
                    instrument.isActive = false;
                    removed++;
                    
                    emit InstrumentRemoved(poolData.poolAddress, instrumentId, "batch_matured");
                }
            }
        }
        
        return removed;
    }
    
    /**
     * @notice Get count of active instruments
     * @param instruments Array of instrument holdings
     * @return count Number of active instruments
     */
    function getActiveInstrumentCount(
        IStableYieldTypes.InstrumentHolding[] storage instruments
    ) external view returns (uint256 count) {
        uint256 activeCount = 0;
        
        for (uint256 i = 0; i < instruments.length; i++) {
            if (instruments[i].isActive) {
                activeCount++;
            }
        }
        
        return activeCount;
    }
    
    /**
     * @notice Check if instrument is due for coupon payment
     * @param instrument Instrument data
     * @return isDue True if coupon is due
     */
    function isCouponDue(
        IStableYieldTypes.InstrumentHolding storage instrument
    ) external view returns (bool isDue) {
        if (instrument.instrumentType != IStableYieldTypes.InstrumentType.INTEREST_BEARING) {
            return false;
        }
        
        if (!instrument.isActive) {
            return false;
        }
        
        return block.timestamp >= instrument.nextCouponDueDate && block.timestamp < instrument.maturityDate;
    }
}

