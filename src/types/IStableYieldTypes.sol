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

    enum AllocationStatus {
        PENDING,    // Funds allocated to SPV, awaiting instrument creation
        INVESTED,   // Linked to an instrument
        RETURNED,   // Excess funds returned by SPV
        MATURED,    // Instrument matured, funds returned
        CANCELLED   // Allocation cancelled before investment
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STRUCTS //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    struct PoolData {
        address poolAddress;
        address escrowAddress;
        address asset;
        string name;
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
        bytes32 allocationId;            // Links instrument to its allocation
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
        bool processed;
        uint256 processedTime;
    }

    struct PendingAllocation {
        bytes32 allocationId;
        address pool;
        address spv;
        uint256 amount;
        uint256 createdAt;
        uint256 expiresAt;
        AllocationStatus status;
    }

    struct ReserveConfig {
        uint256 minAbsoluteReserve;  // Minimum reserve floor in asset decimals
        uint256 reserveRatioBps;     // Reserve ratio in basis points (e.g., 1000 = 10%)
    }
}

