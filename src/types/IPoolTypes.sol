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
     * @param refundGasFee Gas fee for refunds
     * @param discountRate Discount rate in basis points for discounted instruments
     * @param minimumFundingThreshold Minimum percentage of targetRaise required to proceed (basis points)
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
        uint256 minimumFundingThreshold; // (basis points) 
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


    // enum ManagedPoolType {
    //     STABLE_YIELD,
    //     LOCKED_YIELD,
    //     INDEX_POOL,
    //     TRANCHED_POOL
    // }

    //   struct ManagedPoolConfig {
    //     ManagedPoolType poolType;
    //     address[] underlyingPools;
    //     uint256[] allocationWeights;
    //     uint256 withdrawalFrequency;
    //     uint256 rebalanceThreshold; // Basis points deviation trigger
    //     bool autoReinvest;
    // }


     struct ManagedPoolData {
        address poolAddress;        // StableYieldPool instance
        address asset;              // Any approved stablecoin
        address escrow;             // ManagedPoolEscrow instance
        address spvAddress;         // SPV for this pool
        uint256[] supportedTenors;  // [90, 180, 270, 360] days
        uint256 minInvestment;      // In asset units
        uint256 expenseRatio;       // Basis points
        uint256 reserveRatio;       // Basis points (default 1000 = 10%)
        bool isActive;
        uint256 createdAt;
    }

      struct PoolReserves {
        uint256 targetReserveRatio;    // 1000 = 10%
        uint256 minReserveRatio;       // 500 = 5% (emergency minimum)
        uint256 maxReserveRatio;       // 2000 = 20% (if high withdrawal demand)
        uint256 currentCashBuffer;     // Current cash held
        uint256 totalPoolAUM;          // Total pool assets
        uint256 lastRebalanceTime;    // Last reserve rebalancing
    }

     struct UserPosition {
        uint256 principal;             // Original deposit amount
        uint256 shares;                // Pool shares owned
        TenorDuration tenor; // Selected tenor
        MaturityAction maturityAction; // Compound or withdraw
        uint256 depositTime;           // When position was created
        uint256 maturityTime;          // When tenor expires
        uint256 accruedYield;          // Cached yield calculation
        bool isActive;                 // Position status
    }


    enum TenorDuration {
        TENOR_90D,   // 3 months
        TENOR_180D,  // 6 months  
        TENOR_270D,  // 9 months
        TENOR_360D   // 12 months
    }

    enum MaturityAction {
        COMPOUND,    // Auto-reinvest at maturity
        WITHDRAW     // Withdraw principal + yield
    }

    struct CountryPoolConfig {
        string countryCode;           // "NG", "US", "TR", "KE", etc.
        string countryName;           // "Nigeria", "United States", "Turkey", etc.
        address stablecoin;           // CNGN, USDT, USDC, etc. (flexible per country)
        string stablecoinSymbol;      // "CNGN", "USDT", "USDC", etc.
        uint256 penaltyRate;          // Early exit penalty (basis points, e.g., 300 = 3%)
        uint256 minimumHoldPeriod;    // Minimum hold period in days (e.g., 30)
        uint256 maxQueueTime;         // Maximum withdrawal queue time in days (e.g., 7)
        bool isActive;                // Whether this country pool is active
    }

    struct TenorPosition {
        uint256 principal;            // Original deposit amount
        TenorDuration tenor;          // Selected tenor duration
        MaturityAction maturityAction; // What to do at maturity
        uint256 depositTime;          // Timestamp of deposit
        uint256 maturityTime;         // Calculated maturity timestamp
        uint256 accruedYield;         // Current accrued yield
        bool isActive;                // Whether position is active
    }

    struct WithdrawalRequest {
        address user;                 // User requesting withdrawal
        uint256 shares;              // Shares to withdraw
        uint256 requestTime;         // Timestamp of request
        uint256 expectedAmount;      // Expected withdrawal amount (with penalty if early)
        bool isPenalized;            // Whether this is an early exit (penalized)
        bool isProcessed;            // Whether request has been processed
    }

    struct LadderedAllocation {
        uint256 shortTermAllocation;  // 30-90 days (50%)
        uint256 mediumTermAllocation; // 90-180 days (30%)
        uint256 longTermAllocation;   // 180-365 days (20%)
        uint256 cashBuffer;           // Emergency liquidity buffer
        uint256 totalAllocated;       // Sum of all allocations
        uint256 lastRebalanceTime;    // Last rebalancing timestamp
    }

}