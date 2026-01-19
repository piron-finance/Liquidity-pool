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

    /**
     * @notice Validate tier configuration
     * @param tier Lock tier to validate
     * @return isValid True if tier is valid
     */
    function validateTier(
        ILockedPoolTypes.LockTier memory tier
    ) public pure returns (bool isValid) {
        if (tier.durationDays == 0) return false;
        if (tier.apyBps > 5000) return false;
        if (tier.earlyExitPenaltyBps > 5000) return false;
        return true;
    }

    /**
     * @notice Validate deposit parameters
     * @param amount Deposit amount
     * @param tierIndex Tier index
     * @param tier Lock tier
     * @param tierCount Total tiers configured
     * @return isValid True if deposit is valid
     * @return errorMsg Error message if invalid
     */
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

    /**
     * @notice Build new position struct
     * @param positionId Position ID
     * @param user User address
     * @param poolAddress Pool address
     * @param principal Principal amount
     * @param tier Lock tier
     * @param tierIndex Tier index
     * @param paymentChoice Interest payment choice
     * @param currentTime Current timestamp
     * @return position New position struct
     */
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

    /**
     * @notice Calculate early exit result
     * @param position User position
     * @param tier Lock tier
     * @param currentTime Current timestamp
     * @return result Early exit calculation
     */
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

    /**
     * @notice Generate position ID
     * @param pool Pool address
     * @param user User address
     * @param nonce Nonce value
     * @param timestamp Current timestamp
     * @return positionId Unique position ID
     */
    function generatePositionId(
        address pool,
        address user,
        uint256 nonce,
        uint256 timestamp
    ) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(pool, user, nonce, timestamp)));
    }

    /**
     * @notice Calculate shares to mint for deposit
     * @param principal Principal deposited
     * @return shares Shares to mint (1:1 with principal)
     */
    function calculateShares(uint256 principal) public pure returns (uint256) {
        return principal;
    }

    /**
     * @notice Check if position is in valid state for redemption
     * @param position Position to check
     * @param caller Caller address
     * @param currentTime Current timestamp
     * @return isValid True if can redeem
     * @return errorMsg Error message if invalid
     */
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

    /**
     * @notice Check if position is in valid state for early exit
     * @param position Position to check
     * @param caller Caller address
     * @param currentTime Current timestamp
     * @return isValid True if can early exit
     * @return errorMsg Error message if invalid
     */
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

