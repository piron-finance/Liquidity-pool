// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../types/ILockedPoolTypes.sol";

/**
 * @title LockedPoolLibrary
 * @dev Pure helpers for locked pool math: interest calculations, early-exit penalties,
 *      position building, tier validation, and redemption checks.
 */
library LockedPoolLibrary {

    uint256 public constant DAYS_PER_YEAR = 365;
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ==================== INTEREST ====================

    /// @dev Simple interest = (principal * apyBps * durationDays) / (BPS * 365).
    function calculateInterest(
        uint256 principal,
        uint256 apyBps,
        uint256 durationDays
    ) public pure returns (uint256 interest) {
        return (principal * apyBps * durationDays) / (BPS_DENOMINATOR * DAYS_PER_YEAR);
    }

    /// @dev Returns the linearly accrued portion of fullInterest based on elapsed time.
    function calculateProRataInterest(
        uint256 fullInterest,
        uint256 timeElapsed,
        uint256 totalDuration
    ) public pure returns (uint256 earnedInterest) {
        if (totalDuration == 0) return 0;
        if (timeElapsed >= totalDuration) return fullInterest;
        
        return (fullInterest * timeElapsed) / totalDuration;
    }

    // ==================== EARLY EXIT ====================

    /// @dev Early-exit for upfront-interest positions: penalty applied to total value received.
    function calculateEarlyExitUpfront(
        ILockedPoolTypes.UserPosition memory position,
        ILockedPoolTypes.LockTier memory tier
    ) public pure returns (ILockedPoolTypes.EarlyExitCalculation memory result) {
        uint256 totalValueReceived = position.investedAmount + position.fullInterestAmount;
        uint256 penalty = (totalValueReceived * tier.earlyExitPenaltyBps) / BPS_DENOMINATOR;
        
        uint256 payout;
        if (penalty >= position.investedAmount) {
            payout = 0;
            penalty = position.investedAmount;
        } else {
            payout = position.investedAmount - penalty;
        }
        
        result = ILockedPoolTypes.EarlyExitCalculation({
            payout: payout,
            penalty: penalty,
            interestEarned: position.fullInterestAmount,
            valueAtExit: totalValueReceived
        });
        
        return result;
    }

    /// @dev Early-exit for at-maturity-interest positions: pro-rata interest + penalty.
    function calculateEarlyExitMaturity(
        ILockedPoolTypes.UserPosition memory position,
        ILockedPoolTypes.LockTier memory tier,
        uint256 currentTime
    ) public pure returns (ILockedPoolTypes.EarlyExitCalculation memory result) {
        uint256 timeElapsed = currentTime - position.lockStart;
        uint256 totalDuration = position.lockEnd - position.lockStart;
        
        uint256 earnedInterest = calculateProRataInterest(
            position.fullInterestAmount,
            timeElapsed,
            totalDuration
        );
        
        uint256 valueAtExit = position.principalDeposited + earnedInterest;
        
        uint256 penalty = (valueAtExit * tier.earlyExitPenaltyBps) / BPS_DENOMINATOR;
        uint256 payout = valueAtExit - penalty;
        
        result = ILockedPoolTypes.EarlyExitCalculation({
            payout: payout,
            penalty: penalty,
            interestEarned: earnedInterest,
            valueAtExit: valueAtExit
        });
        
        return result;
    }

    // ==================== INVESTED AMOUNT / PAYOUT ====================

    /// @dev For upfront interest, investedAmount = principal - interest (interest paid immediately).
    function calculateInvestedAmount(
        uint256 principal,
        uint256 interestAmount,
        ILockedPoolTypes.InterestPayment paymentChoice
    ) public pure returns (uint256 investedAmount) {
        if (paymentChoice == ILockedPoolTypes.InterestPayment.UPFRONT) {
            return principal - interestAmount;
        }
        return principal; 
    }

    function calculateExpectedMaturityPayout(
        uint256 principal,
        uint256 interestAmount,
        ILockedPoolTypes.InterestPayment paymentChoice
    ) public pure returns (uint256 expectedPayout) {
        if (paymentChoice == ILockedPoolTypes.InterestPayment.UPFRONT) {
            return principal;
        }
        return principal + interestAmount;
    }

    // ==================== STATUS CHECKS ====================

    function canRedeem(
        ILockedPoolTypes.UserPosition memory position,
        uint256 currentTime
    ) public pure returns (bool) {
        return currentTime >= position.lockEnd && 
               position.status == ILockedPoolTypes.PositionStatus.ACTIVE;
    }

    function canEarlyExit(
        ILockedPoolTypes.UserPosition memory position,
        uint256 currentTime
    ) public pure returns (bool) {
        return currentTime < position.lockEnd && 
               position.status == ILockedPoolTypes.PositionStatus.ACTIVE;
    }

    function calculateDaysRemaining(
        uint256 lockEnd,
        uint256 currentTime
    ) public pure returns (uint256 daysRemaining) {
        if (currentTime >= lockEnd) return 0;
        return (lockEnd - currentTime) / 1 days;
    }

    // ==================== POSITION SUMMARY ====================

    /// @dev Builds a read-only summary struct for front-end display.
    function buildPositionSummary(
        ILockedPoolTypes.UserPosition memory position,
        uint256 currentTime
    ) public pure returns (ILockedPoolTypes.PositionSummary memory summary) {
        uint256 interestToShow = position.fullInterestAmount;
        
        if (position.paymentChoice == ILockedPoolTypes.InterestPayment.AT_MATURITY &&
            currentTime < position.lockEnd) {
            uint256 timeElapsed = currentTime - position.lockStart;
            uint256 totalDuration = position.lockEnd - position.lockStart;
            interestToShow = calculateProRataInterest(
                position.fullInterestAmount,
                timeElapsed,
                totalDuration
            );
        }
        
        summary = ILockedPoolTypes.PositionSummary({
            principalDeposited: position.principalDeposited,
            interestAmount: interestToShow,
            apyBps: position.apyBpsAtDeposit,
            interestPaidUpfront: position.interestPaid,
            expectedMaturityPayout: position.expectedMaturityPayout,
            daysRemaining: calculateDaysRemaining(position.lockEnd, currentTime),
            canRedeem: canRedeem(position, currentTime),
            canEarlyExit: canEarlyExit(position, currentTime)
        });
        
        return summary;
    }

    // ==================== VALIDATION ====================

    /// @dev Validates a lock tier: duration > 0, APY <= 50%, penalty <= 50%.
    function validateTier(
        ILockedPoolTypes.LockTier memory tier
    ) public pure returns (bool isValid) {
        if (tier.durationDays == 0) return false;
        if (tier.apyBps > 5000) return false;
        if (tier.earlyExitPenaltyBps > 5000) return false;
        return true;
    }

    function validateDeposit(
        uint256 amount,
        uint256 tierIndex,
        ILockedPoolTypes.LockTier memory tier,
        uint256 tierCount
    ) public pure returns (bool isValid, string memory errorMsg) {
        if (amount == 0) return (false, "zero amount");
        if (tierIndex >= tierCount) return (false, "invalid tier");
        if (!tier.isActive) return (false, "tier inactive");
        if (amount < tier.minDeposit) return (false, "below minimum");
        return (true, "");
    }

    // ==================== POSITION BUILDING ====================

    /// @dev Constructs a complete UserPosition struct from deposit parameters.
    function buildPosition(
        uint256 positionId,
        address user,
        address poolAddress,
        uint256 principal,
        ILockedPoolTypes.LockTier memory tier,
        uint8 tierIndex,
        ILockedPoolTypes.InterestPayment paymentChoice,
        uint256 currentTime
    ) public pure returns (ILockedPoolTypes.UserPosition memory position) {
        uint256 interest = calculateInterest(principal, tier.apyBps, tier.durationDays);
        uint256 lockEnd = currentTime + (tier.durationDays * 1 days);
        
        uint256 investedAmount = calculateInvestedAmount(principal, interest, paymentChoice);
        uint256 expectedPayout = calculateExpectedMaturityPayout(principal, interest, paymentChoice);
        bool paid = paymentChoice == ILockedPoolTypes.InterestPayment.UPFRONT;
        
        position = ILockedPoolTypes.UserPosition({
            positionId: positionId,
            user: user,
            poolAddress: poolAddress,
            principalDeposited: principal,
            fullInterestAmount: interest,
            apyBpsAtDeposit: tier.apyBps,
            paymentChoice: paymentChoice,
            interestPaid: paid,
            investedAmount: investedAmount,
            expectedMaturityPayout: expectedPayout,
            lockStart: currentTime,
            lockEnd: lockEnd,
            tierIndex: tierIndex,
            status: ILockedPoolTypes.PositionStatus.ACTIVE,
            actualPayout: 0,
            penaltyPaid: 0,
            interestEarned: paid ? interest : 0,
            autoRollover: false,
            rolledFromPositionId: 0
        });
        
        return position;
    }

    /// @dev Routes early-exit calculation to the correct handler based on interest payment type.
    function calculateEarlyExit(
        ILockedPoolTypes.UserPosition memory position,
        ILockedPoolTypes.LockTier memory tier,
        uint256 currentTime
    ) public pure returns (ILockedPoolTypes.EarlyExitCalculation memory result) {
        if (position.paymentChoice == ILockedPoolTypes.InterestPayment.UPFRONT) {
            return calculateEarlyExitUpfront(position, tier);
        } else {
            return calculateEarlyExitMaturity(position, tier, currentTime);
        }
    }

    function generatePositionId(
        address pool,
        address user,
        uint256 nonce,
        uint256 timestamp
    ) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(pool, user, nonce, timestamp)));
    }

    function calculateShares(uint256 principal) public pure returns (uint256) {
        return principal;
    }

    function validateRedemption(
        ILockedPoolTypes.UserPosition memory position,
        address caller,
        uint256 currentTime
    ) public pure returns (bool isValid, string memory errorMsg) {
        if (position.user != caller) return (false, "not owner");
        if (position.status == ILockedPoolTypes.PositionStatus.REDEEMED) return (false, "already redeemed");
        if (position.status == ILockedPoolTypes.PositionStatus.EARLY_EXIT) return (false, "already exited");
        if (currentTime < position.lockEnd) return (false, "not matured");
        if (position.status != ILockedPoolTypes.PositionStatus.ACTIVE && 
            position.status != ILockedPoolTypes.PositionStatus.MATURED) return (false, "not redeemable");
        return (true, "");
    }

    function validateEarlyExit(
        ILockedPoolTypes.UserPosition memory position,
        address caller,
        uint256 currentTime
    ) public pure returns (bool isValid, string memory errorMsg) {
        if (position.user != caller) return (false, "not owner");
        if (position.status == ILockedPoolTypes.PositionStatus.REDEEMED) return (false, "already redeemed");
        if (position.status == ILockedPoolTypes.PositionStatus.EARLY_EXIT) return (false, "already exited");
        if (currentTime >= position.lockEnd) return (false, "already matured");
        if (position.status != ILockedPoolTypes.PositionStatus.ACTIVE) return (false, "not active");
        return (true, "");
    }
}
