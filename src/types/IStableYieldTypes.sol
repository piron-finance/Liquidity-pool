// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title IStableYieldTypes
/// @dev Shared type definitions for Stable Yield pools: instrument types, allocation statuses,
///      pool data, instrument holdings, withdrawal queues, and reserve configuration.
interface IStableYieldTypes {

    // ==================== ENUMS ====================

    enum InstrumentType {
        DISCOUNTED,
        INTEREST_BEARING
    }

    enum AllocationStatus {
        PENDING,
        INVESTED,
        RETURNED,
        MATURED,
        CANCELLED
    }

    // ==================== STRUCTS ====================

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
        InstrumentType instrumentType;
        uint256 purchasePrice;
        uint256 faceValue;
        uint256 purchaseDate;
        uint256 maturityDate;
        uint256 annualCouponRate;
        uint8 couponFrequency;
        uint256 nextCouponDueDate;
        uint8 couponsPaid;
        bool isActive;
        bytes32 allocationId;
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
        uint256 deadline;
        uint256 estimatedValue;
        uint256 feeAmount;
        bool processed;
        uint256 processedTime;
    }

    struct PendingAllocation {
        bytes32 allocationId;
        address pool;
        address spv;
        uint256 amount;
        uint256 usedAmount;
        uint256 returnedAmount;
        uint256 createdAt;
        uint256 expiresAt;
        AllocationStatus status;
    }

    struct ReserveConfig {
        uint256 minAbsoluteReserve;
        uint256 reserveRatioBps;
    }
}
