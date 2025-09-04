// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IPoolTypes
 * @dev Shared type definitions for the pool system
 * @notice This interface defines all common types used across Manager, Library, and other contracts
 */
interface IPoolTypes {
    /**
     * @dev Types of financial instruments supported by the protocol
     * @param DISCOUNTED Instruments purchased at discount, mature at face value
     * @param INTEREST_BEARING Instruments that pay periodic coupon payments
     */
    enum InstrumentType {
        DISCOUNTED,
        INTEREST_BEARING
    }
    
    /**
     * @dev Status of a pool throughout its lifecycle
     * @param FUNDING Pool is accepting deposits from users
     * @param PENDING_INVESTMENT Pool funding complete, waiting for SPV investment
     * @param INVESTED SPV has invested funds, instrument is active
     * @param MATURED Instrument has reached maturity, returns available
     * @param EMERGENCY Emergency state, funds can be withdrawn
     */
    enum PoolStatus {
        FUNDING,
        PENDING_INVESTMENT,
        INVESTED,
        MATURED,
        EMERGENCY
    }
    
    /**
     * @dev Configuration parameters for a pool
     * @param instrumentType Type of financial instrument (DISCOUNTED or INTEREST_BEARING)
     * @param faceValue Face value of the instrument (for discounted instruments)
     * @param purchasePrice Purchase price per unit
     * @param targetRaise Target amount to raise during funding phase
     * @param epochEndTime End time of the funding epoch
     * @param maturityDate Maturity date of the instrument
     * @param couponDates Array of coupon payment dates
     * @param couponRates Array of coupon rates in basis points
     * @param refundGasFee Gas fee for refunds
     * @param discountRate Discount rate in basis points for discounted instruments
     */
    struct PoolConfig {
        InstrumentType instrumentType;
        uint256 faceValue;
        uint256 purchasePrice;
        uint256 targetRaise;
        uint256 epochEndTime;
        uint256 maturityDate;
        uint256[] couponDates;
        uint256[] couponRates;
        uint256 refundGasFee;
        uint256 discountRate; // (basis points)
    }
    
    /**
     * @dev Main data structure containing all pool information
     * @param config Pool configuration parameters
     * @param status Current status of the pool
     * @param totalRaised Total amount raised during funding phase
     * @param actualInvested Actual amount invested by SPV
     * @param totalDiscountEarned Total discount earned for discounted instruments
     * @param totalCouponsReceived Total coupon payments received from SPV
     * @param totalCouponsDistributed Total coupons distributed to users
     * @param fundsWithdrawnBySPV Total funds withdrawn by SPV for investment
     * @param fundsReturnedBySPV Total funds returned by SPV
     */
    struct PoolData {
        PoolConfig config;
        PoolStatus status;
        uint256 totalRaised;
        uint256 actualInvested;
        uint256 totalDiscountEarned;
        uint256 totalCouponsReceived;
        uint256 totalCouponsDistributed;
        uint256 fundsWithdrawnBySPV;
        uint256 fundsReturnedBySPV;
    }
    
    /**
     * @dev User-specific data for a pool
     * @param depositTime Timestamp when user first deposited
     * @param couponsClaimed Number of coupon payments claimed by user
     */
    struct UserPoolData {
        uint256 depositTime;
        uint256 couponsClaimed;
    }
}