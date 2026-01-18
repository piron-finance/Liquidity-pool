// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title IPoolTypes
 * @dev Type definitions for single-asset pools (Deal Pools)
 * @notice This interface defines types used for non-revolving deal pool operations
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
     * @param FILLED Pool reached target raise amount
     * @param PENDING_INVESTMENT Pool funding complete, waiting for SPV investment
     * @param INVESTED SPV has invested funds, instrument is active
     * @param MATURED Instrument has reached maturity, returns available
     * @param WITHDRAWN All users have withdrawn, pool is closed
     * @param EMERGENCY Emergency state, funds can be withdrawn
     */
    enum PoolStatus {
        FUNDING,
        FILLED,
        PENDING_INVESTMENT,
        INVESTED,
        MATURED,
        WITHDRAWN,
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
     * @param discountRate Discount rate in basis points for discounted instruments
     * @param minimumFundingThreshold Minimum percentage of targetRaise required to proceed (basis points)
     * @param minInvestment Minimum investment amount per deposit
     * @param withdrawalFeeBps Withdrawal fee in basis points (e.g., 100 = 1%)
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
        uint256 discountRate;            // basis points
        uint256 minimumFundingThreshold; // basis points
        uint256 minInvestment;           // minimum deposit amount
        uint256 withdrawalFeeBps;        // withdrawal fee in basis points
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
     * @param totalCouponsClaimed Total coupons actually claimed by users
     * @param fundsWithdrawnBySPV Total funds withdrawn by SPV for investment
     * @param fundsReturnedBySPV Total funds returned by SPV
     * @param totalFeesCollected Total withdrawal fees collected
     */
    struct PoolData {
        PoolConfig config;
        PoolStatus status;
        uint256 totalRaised;
        uint256 actualInvested;
        uint256 totalDiscountEarned;
        uint256 totalCouponsReceived;
        uint256 totalCouponsDistributed;
        uint256 totalCouponsClaimed;
        uint256 fundsWithdrawnBySPV;
        uint256 fundsReturnedBySPV;
        uint256 totalFeesCollected;
    }
    
    /**
     * @dev User-specific data for a pool
     * @param depositTime Timestamp when user first deposited
     * @param couponsClaimed Total coupon payments claimed by user
     */
    struct UserPoolData {
        uint256 depositTime;
        uint256 couponsClaimed;
    }

    /**
     * @dev Proof of investment for audit trail
     * @param documentHash IPFS or other hash of signed investment agreement
     * @param confirmedAt Timestamp when investment was confirmed
     * @param confirmedBy Address (SPV) that confirmed the investment
     */
    struct InvestmentProof {
        string documentHash;
        uint256 confirmedAt;
        address confirmedBy;
    }

    /**
     * @dev Transfer types for clear event categorization
     */
    enum TransferType {
        DEPOSIT,
        WITHDRAWAL,
        INVESTMENT_TO_SPV,
        MATURITY_RETURN,
        COUPON_PAYMENT,
        FEE_COLLECTION,
        EMERGENCY_REFUND
    }
}
