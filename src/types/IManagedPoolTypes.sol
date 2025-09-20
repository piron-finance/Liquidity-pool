// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IManagedPoolTypes
 * @dev Type definitions for managed pools (Stable Yield Pools)
 * @notice This interface defines types used for managed pool operations, tenor-based investing, and multi-asset allocation
 */

interface IManagedPoolTypes {


        ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STRUCTS //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////



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

     /**
     * @dev Country-specific configuration for managed pools
     */
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

    /**
     * @dev Withdrawal request for managed pools
     */
    struct WithdrawalRequest {
        address user;                 // User requesting withdrawal
        uint256 shares;              // Shares to withdraw
        uint256 requestTime;         // Timestamp of request
        uint256 expectedAmount;      // Expected withdrawal amount (with penalty if early)
        bool isPenalized;            // Whether this is an early exit (penalized)
        bool isProcessed;            // Whether request has been processed
    }

    /**
     * @dev Laddered allocation strategy for managed pools
     */
    struct LadderedAllocation {
        uint256 shortTermAllocation;  // 30-90 days (50%)
        uint256 mediumTermAllocation; // 90-180 days (30%)
        uint256 longTermAllocation;   // 180-365 days (20%)
        uint256 cashBuffer;           // Emergency liquidity buffer
        uint256 totalAllocated;       // Sum of all allocations
        uint256 lastRebalanceTime;    // Last rebalancing timestamp
    }

    /**
     * @dev Instrument holding for T-bills and bonds
     */
    struct InstrumentHolding {
        uint256 purchasePrice;        // Amount paid
        uint256 faceValue;            // Principal/maturity value
        uint256 purchaseDate;         
        uint256 maturityDate;         
        uint256 annualCouponRate;     // bps (0 for T-bills)
        uint8 couponFrequency;        // 0 = T-bill, 2 = semi-annual, 4 = quarterly, 12 = monthly
        uint256 lastCouponPaidDate;   // timestamp of last coupon payment
        uint8 couponsPaid;            // how many coupons already paid
        bytes32 attestationHash;      // off-chain proof
        uint256 cusip;                // identifier
        bool isMatured;               
        bool isLiquidated;            
    }

    /**
     * @dev Coupon payment record for audit trail
     */
    struct CouponPayment {
        uint256 holdingIndex;       // Which instrument (for audit trail)
        uint256 couponAmount;       // Actual amount received
        uint256 expectedDate;       // When coupon was due
        uint256 actualDate;         // When actually received
    }

    /**
     * @dev Aggregate data for gas-efficient calculations
     */
    struct PoolAggregates {
        uint256 totalPurchasePrice;      // Sum of purchasePrice for all active holdings
        uint256 totalFaceValue;          // Sum of faceValue for active holdings
        uint256 totalWeightedDuration;   // Sum of (purchasePrice * daysToMaturity) for WAM
        uint256 activeInstrumentCount;   // Count of active instruments
        uint256 lastAccrualTimestamp;    // Last time accrual was calculated
        uint256 totalAccruedValue;       // Cached total accrued value
    }


    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ENUMS //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

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



}