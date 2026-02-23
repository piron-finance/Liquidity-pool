// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title ILockedPoolTypes
/// @dev Shared type definitions for Locked (fixed-term) pools: interest payment modes,
///      position lifecycle, tiers, allocations, metrics, and debt positions.
interface ILockedPoolTypes {

    // ==================== ENUMS ====================

    enum InterestPayment {
        UPFRONT,
        AT_MATURITY
    }

    enum PositionStatus {
        ACTIVE,
        MATURED,
        REDEEMED,
        EARLY_EXIT,
        ROLLED_OVER
    }

    enum AllocationStatus {
        PENDING,
        INVESTED,
        RETURNED,
        MATURED,
        CANCELLED
    }

    // ==================== STRUCTS ====================

    struct SPVAllocation {
        address poolAddress;
        address spvAddress;
        uint256 amount;
        uint256 returnedAmount;
        uint256 createdAt;
        AllocationStatus status; 
    }

    struct LockTier {
        uint256 durationDays;
        uint256 apyBps;
        uint256 earlyExitPenaltyBps;
        uint256 minDeposit;
        bool isActive;
    }

    struct UserPosition {
        uint256 positionId;
        address user;
        address poolAddress;
        uint256 principalDeposited;
        uint256 fullInterestAmount;
        uint256 apyBpsAtDeposit;
        InterestPayment paymentChoice;
        bool interestPaid;
        uint256 investedAmount;
        uint256 expectedMaturityPayout;
        uint256 lockStart;
        uint256 lockEnd;
        uint8 tierIndex;
        PositionStatus status;
        uint256 actualPayout;
        uint256 penaltyPaid;
        uint256 interestEarned;
        bool autoRollover;
        uint256 rolledFromPositionId;
    }

    struct PoolConfig {
        address asset;
        string name;
        uint256 minInvestment;
        bool isActive;
        uint256 createdAt;
    }

    struct PoolMetrics {
        uint256 totalPrincipalLocked;
        uint256 totalInterestCommitted;
        uint256 totalInterestPaidUpfront;
        uint256 totalInterestPendingMaturity;
        uint256 totalInvestedAmount;
        uint256 totalExpectedMaturityPayout;
        uint256 activePositions;
        uint256 totalPositions;
    }

    struct EarlyExitCalculation {
        uint256 payout;
        uint256 penalty;
        uint256 interestEarned;
        uint256 valueAtExit;
    }

    struct PositionSummary {
        uint256 principalDeposited;
        uint256 interestAmount;
        uint256 apyBps;
        bool interestPaidUpfront;
        uint256 expectedMaturityPayout;
        uint256 daysRemaining;
        bool canRedeem;
        bool canEarlyExit;
    }

    struct PoolProtocolAccounting {
        uint256 totalYieldEarned;
        uint256 totalPenaltiesEarned;
        uint256 totalLossesAbsorbed;
        uint256 reserveLoansOutstanding;
    }

    struct DebtPosition {
        uint256 positionId;
        address user;
        uint256 amountOwed;
        uint256 reserveLoan;
        uint256 pendingPenalty;
        uint256 exitTime;
        bool settled;
    }

}
