// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IStableYieldTypes
 * @dev Type definitions for managed pools (Stable Yield Pools)
 * @notice This interface defines types used for managed pool operations, tenor-based investing, and multi-asset allocation
 */

interface IStableYieldTypes {

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ENUMS ////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    enum InstrumentType {
        DISCOUNTED,      // T-bills, commercial paper
        INTEREST_BEARING // Bonds with periodic coupons
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STRUCTS //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    struct PoolData {
        address poolAddress;
        address escrowAddress;
        address asset;
        bool isLocked;
        string name;
        string description;
        uint256[] supportedTenors; // Empty for flexible pools
        uint256 minInvestment;
        bool isActive;
        uint256 createdAt;
    }

    struct InstrumentHolding {
        InstrumentType instrumentType;   // T-bill or bond
        uint256 purchasePrice;           // Amount paid (in pool currency)
        uint256 faceValue;               // Maturity/principal value
        uint256 purchaseDate;            // When purchased
        uint256 maturityDate;            // When matures
        uint256 annualCouponRate;        // In basis points, 0 for T-bills
        uint8 couponFrequency;           // 0=T-bill, 2=semi-annual, 4=quarterly, 12=monthly
        uint256 nextCouponDueDate;       // For bonds, next coupon payment date
        uint8 couponsPaid;               // How many coupons actually paid
        bool isActive;                   // Still held by pool
    }

    struct WithdrawalQueue {
        uint256 head;
        uint256 tail;
        uint256 totalPendingValue;
    }
    
    struct WithdrawalRequest {
        address user;
        uint256 shares;
        uint256 requestTime;
        uint256 estimatedValue;
        bool isPenalized;
        uint256 penaltyAmount;
        bool processed;
        uint256 processedTime;
    }
    
    struct LockedPosition {
        uint256 shares;
        uint256 principal;
        uint256 tenorDays;
        uint256 depositTime;
        uint256 maturityTime;
        bool autoRollover;
        bool isActive;
    }
}

