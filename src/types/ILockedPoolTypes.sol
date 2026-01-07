// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title ILockedPoolTypes
 * @dev Type definitions for locked pools with fixed tenors
 * @notice Defines types for locked deposit pools with upfront or maturity interest payment
 */
interface ILockedPoolTypes {

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ENUMS ////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    enum InterestPayment {
        UPFRONT,        // Interest paid immediately at deposit
        AT_MATURITY     // Interest paid at lock end
    }

    enum PositionStatus {
        ACTIVE,         // Position is locked
        MATURED,        // Lock period ended, can redeem
        REDEEMED,       // Principal returned to user
        EARLY_EXIT      // User exited before maturity with penalty
    }

    enum AllocationStatus {
        PENDING,        // Created but not yet invested
        INVESTED,       // Funds sent to SPV
        RETURNED,       // Partial return received
        MATURED,        // Full return received
        CANCELLED       // Allocation cancelled
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STRUCTS //////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @dev SPV allocation tracking
     * @param poolAddress Pool the allocation is from
     * @param spvAddress SPV receiving funds
     * @param amount Amount allocated
     * @param returnedAmount Amount returned so far
     * @param createdAt Creation timestamp
     * @param status Current status
     */
    struct SPVAllocation {
        address poolAddress;
        address spvAddress;
        uint256 amount;
        uint256 returnedAmount;
        uint256 createdAt;
        AllocationStatus status;
    }

    /**
     * @dev Lock tier configuration
     * @param durationDays Lock duration in days (90, 180, 365)
     * @param apyBps Annual percentage yield in basis points (500 = 5%)
     * @param earlyExitPenaltyBps Penalty on exit value in basis points
     * @param minDeposit Minimum deposit amount for this tier
     * @param isActive Whether tier accepts new deposits
     */
    struct LockTier {
        uint256 durationDays;
        uint256 apyBps;
        uint256 earlyExitPenaltyBps;
        uint256 minDeposit;
        bool isActive;
    }

    /**
     * @dev User's locked position
     * @param positionId Unique identifier
     * @param user Position owner
     * @param poolAddress Pool this position belongs to
     * @param principalDeposited Original deposit amount
     * @param fullInterestAmount Calculated interest for full term
     * @param apyBpsAtDeposit APY snapshot at deposit time
     * @param paymentChoice Upfront or maturity interest
     * @param interestPaid Whether upfront interest was sent
     * @param investedAmount Amount sent to SPV (principal - upfront interest, or full principal)
     * @param expectedMaturityPayout What user receives at maturity
     * @param lockStart Lock start timestamp
     * @param lockEnd Lock end timestamp
     * @param tierIndex Which lock tier
     * @param status Current position status
     * @param actualPayout Amount actually paid out
     * @param penaltyPaid Penalty amount if early exit
     * @param interestEarned Interest actually earned (pro-rata if early)
     */
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
    }

    /**
     * @dev Pool-level configuration
     * @param asset Underlying stablecoin
     * @param name Pool name
     * @param minInvestment Global minimum investment
     * @param isActive Pool accepting deposits
     * @param createdAt Creation timestamp
     */
    struct PoolConfig {
        address asset;
        string name;
        uint256 minInvestment;
        bool isActive;
        uint256 createdAt;
    }

    /**
     * @dev Pool metrics for tracking
     * @param totalPrincipalLocked Sum of all locked principal
     * @param totalInterestCommitted Sum of all interest owed
     * @param totalInterestPaidUpfront Interest already distributed
     * @param totalInterestPendingMaturity Interest to be paid at maturity
     * @param totalInvestedAmount Capital currently with SPV
     * @param totalExpectedMaturityPayout Sum of all expected payouts
     * @param activePositions Count of active positions
     * @param totalPositions Total positions ever created
     */
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

    /**
     * @dev Early exit calculation result
     * @param payout Amount user receives
     * @param penalty Penalty deducted
     * @param interestEarned Pro-rata interest earned
     * @param valueAtExit Total value before penalty
     */
    struct EarlyExitCalculation {
        uint256 payout;
        uint256 penalty;
        uint256 interestEarned;
        uint256 valueAtExit;
    }

    /**
     * @dev Position summary for views
     * @param principalDeposited Original deposit
     * @param interestAmount Interest (full or earned)
     * @param apyBps Rate applied
     * @param interestPaidUpfront Whether interest was paid upfront
     * @param expectedMaturityPayout Expected at maturity
     * @param daysRemaining Days until maturity
     * @param canRedeem Whether position can be redeemed
     * @param canEarlyExit Whether early exit is available
     */
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

    /**
     * @dev Protocol accounting per pool
     * @param totalYieldEarned Yield from spread (SPV return - user payout)
     * @param totalPenaltiesEarned From early exit forfeitures
     * @param totalLossesAbsorbed When SPV underperforms
     * @param reserveLoansOutstanding Current loans from yield reserve
     */
    struct PoolProtocolAccounting {
        uint256 totalYieldEarned;
        uint256 totalPenaltiesEarned;
        uint256 totalLossesAbsorbed;
        uint256 reserveLoansOutstanding;
    }

    /**
     * @dev Debt position tracking for early exits
     * @param positionId Original position ID
     * @param user User who early exited
     * @param amountOwed Amount paid to user
     * @param reserveLoan Amount loaned from reserve
     * @param exitTime When early exit occurred
     * @param settled Whether SPV has returned and debt settled
     */
    struct DebtPosition {
        uint256 positionId;
        address user;
        uint256 amountOwed;
        uint256 reserveLoan;
        uint256 exitTime;
        bool settled;
    }

    /**
     * @dev SPV return settlement info
     * @param positionId Position the return is for
     * @param returnedAmount Amount returned by SPV
     * @param userPayout Amount that was/will be paid to user
     * @param protocolYield Yield going to protocol
     * @param loanRepayment Amount repaying reserve loan
     */
    struct SPVSettlement {
        uint256 positionId;
        uint256 returnedAmount;
        uint256 userPayout;
        uint256 protocolYield;
        uint256 loanRepayment;
    }
}

