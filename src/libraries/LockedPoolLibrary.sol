// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../types/ILockedPoolTypes.sol";

/**
 * @title LockedPoolLibrary
 * @dev Library for locked pool calculations
 * @notice Handles interest calculations, early exit payouts, and position management
 */
library LockedPoolLibrary {

    uint256 public constant DAYS_PER_YEAR = 365;
    uint256 public constant BPS_DENOMINATOR = 10000;

    /**
     * @notice Calculate interest for a locked position
     * @param principal Principal amount
     * @param apyBps Annual percentage yield in basis points
     * @param durationDays Lock duration in days
     * @return interest Calculated interest amount
     */
    function calculateInterest(
        uint256 principal,
        uint256 apyBps,
        uint256 durationDays
    ) public pure returns (uint256 interest) {
        return (principal * apyBps * durationDays) / (BPS_DENOMINATOR * DAYS_PER_YEAR);
    }

    /**
     * @notice Calculate pro-rata interest based on time elapsed
     * @param fullInterest Full interest for complete term
     * @param timeElapsed Time elapsed since lock start
     * @param totalDuration Total lock duration
     * @return earnedInterest Pro-rata interest earned
     */
    function calculateProRataInterest(
        uint256 fullInterest,
        uint256 timeElapsed,
        uint256 totalDuration
    ) public pure returns (uint256 earnedInterest) {
        if (totalDuration == 0) return 0;
        if (timeElapsed >= totalDuration) return fullInterest;
        
        return (fullInterest * timeElapsed) / totalDuration;
    }

    /**
     * @notice Calculate early exit payout for upfront interest position
     * @param position User position
     * @param tier Lock tier configuration
     * @return result Early exit calculation result
     */
    function calculateEarlyExitUpfront(
        ILockedPoolTypes.UserPosition memory position,
        ILockedPoolTypes.LockTier memory tier
    ) public pure returns (ILockedPoolTypes.EarlyExitCalculation memory result) {
        uint256 valueAtExit = position.investedAmount;  // exit here refers to time of exit not maturity
        
        uint256 penalty = (valueAtExit * tier.earlyExitPenaltyBps) / BPS_DENOMINATOR;
        uint256 payout = valueAtExit - penalty;
        
        result = ILockedPoolTypes.EarlyExitCalculation({
            payout: payout,
            penalty: penalty,
            interestEarned: position.fullInterestAmount,
            valueAtExit: valueAtExit
        });
        
        return result;
    }

    /**
     * @notice Calculate early exit payout for maturity interest position
     * @param position User position
     * @param tier Lock tier configuration
     * @param currentTime Current timestamp
     * @return result Early exit calculation result
     */
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

    /**
     * @notice Calculate invested amount based on interest payment choice
     * @param principal Principal deposited
     * @param interestAmount Calculated interest
     * @param paymentChoice Upfront or maturity
     * @return investedAmount Amount to send to SPV
     */
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

    /**
     * @notice Calculate expected maturity payout
     * @param principal Principal deposited
     * @param interestAmount Calculated interest
     * @param paymentChoice Upfront or maturity
     * @return expectedPayout Amount user receives at maturity
     */
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

    /**
     * @notice Check if position can be redeemed
     * @param position User position
     * @param currentTime Current timestamp
     * @return canRedeem True if matured and not yet redeemed
     */
    function canRedeem(
        ILockedPoolTypes.UserPosition memory position,
        uint256 currentTime
    ) public pure returns (bool) {
        return currentTime >= position.lockEnd && 
               position.status == ILockedPoolTypes.PositionStatus.ACTIVE;
    }

    /**
     * @notice Check if position can early exit
     * @param position User position
     * @param currentTime Current timestamp
     * @return canExit True if active and before maturity
     */
    function canEarlyExit(
        ILockedPoolTypes.UserPosition memory position,
        uint256 currentTime
    ) public pure returns (bool) {
        return currentTime < position.lockEnd && 
               position.status == ILockedPoolTypes.PositionStatus.ACTIVE;
    }

    /**
     * @notice Calculate days remaining until maturity
     * @param lockEnd Lock end timestamp
     * @param currentTime Current timestamp
     * @return daysRemaining Days until maturity (0 if matured)
     */
    function calculateDaysRemaining(
        uint256 lockEnd,
        uint256 currentTime
    ) public pure returns (uint256 daysRemaining) {
        if (currentTime >= lockEnd) return 0;
        return (lockEnd - currentTime) / 1 days;
    }

    /**
     * @notice Build position summary
     * @param position User position
     * @param currentTime Current timestamp
     * @return summary Position summary struct
     */
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
}

