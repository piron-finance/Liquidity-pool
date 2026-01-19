// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title AllocationLibrary
 * @notice Shared library for SPV allocation tracking across pool managers
 * @dev Provides pure functions for allocation calculations and ID generation
 */
library AllocationLibrary {
    
    uint256 public constant BPS_DENOMINATOR = 10000;

    /**
     * @notice Generate unique allocation ID
     * @param pool Pool address
     * @param spv SPV address
     * @param amount Allocation amount
     * @param timestamp Creation timestamp
     * @param nonce Unique nonce
     * @return Unique allocation ID
     */
    function generateAllocationId(
        address pool,
        address spv,
        uint256 amount,
        uint256 timestamp,
        uint256 nonce
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(pool, spv, amount, timestamp, nonce));
    }

    /**
     * @notice Check if pool meets minimum reserve threshold
     * @param poolReserves Current pool reserves
     * @param totalDeposits Total deposits in pool
     * @param minAbsoluteReserve Minimum absolute reserve required
     * @param reserveRatioBps Minimum reserve ratio in basis points
     * @return meetsThreshold True if reserves meet threshold
     * @return availableForAllocation Amount available for SPV allocation
     */
    function checkReserveThreshold(
        uint256 poolReserves,
        uint256 totalDeposits,
        uint256 minAbsoluteReserve,
        uint256 reserveRatioBps
    ) external pure returns (bool meetsThreshold, uint256 availableForAllocation) {
        uint256 requiredReserve = (totalDeposits * reserveRatioBps) / BPS_DENOMINATOR;
        
        if (requiredReserve < minAbsoluteReserve) {
            requiredReserve = minAbsoluteReserve;
        }
        
        meetsThreshold = poolReserves >= requiredReserve;
        
        if (poolReserves > requiredReserve) {
            availableForAllocation = poolReserves - requiredReserve;
        } else {
            availableForAllocation = 0;
        }
        
        return (meetsThreshold, availableForAllocation);
    }

    /**
     * @notice Calculate allocation expiry timestamp
     * @param createdAt Creation timestamp
     * @param expiryDays Days until expiry
     * @return expiresAt Expiry timestamp
     */
    function calculateExpiry(
        uint256 createdAt,
        uint256 expiryDays
    ) external pure returns (uint256 expiresAt) {
        return createdAt + (expiryDays * 1 days);
    }

    /**
     * @notice Check if allocation is expired
     * @param expiresAt Expiry timestamp
     * @param currentTime Current timestamp
     * @return isExpired True if expired
     */
    function isExpired(
        uint256 expiresAt,
        uint256 currentTime
    ) external pure returns (bool) {
        return currentTime >= expiresAt;
    }

    /**
     * @notice Calculate remaining allocatable amount
     * @param totalAmount Total allocation amount
     * @param usedAmount Amount already used
     * @param returnedAmount Amount already returned
     * @return remaining Remaining amount
     */
    function calculateRemainingAllocatable(
        uint256 totalAmount,
        uint256 usedAmount,
        uint256 returnedAmount
    ) external pure returns (uint256 remaining) {
        uint256 consumed = usedAmount + returnedAmount;
        if (consumed >= totalAmount) return 0;
        return totalAmount - consumed;
    }

    /**
     * @notice Validate allocation can be used for investment
     * @param purchasePrice Amount to invest
     * @param allocationAmount Total allocation amount
     * @param usedAmount Already used amount
     * @return isValid True if investment is within allocation limits
     */
    function validateInvestmentAmount(
        uint256 purchasePrice,
        uint256 allocationAmount,
        uint256 usedAmount
    ) external pure returns (bool isValid) {
        return purchasePrice <= (allocationAmount - usedAmount);
    }

    /**
     * @notice Calculate yield from SPV return
     * @param returnedAmount Amount returned by SPV
     * @param originalAmount Original allocation amount
     * @return yield Yield earned (0 if loss)
     * @return loss Loss amount (0 if gain)
     */
    function calculateYieldOrLoss(
        uint256 returnedAmount,
        uint256 originalAmount
    ) external pure returns (uint256 yield, uint256 loss) {
        if (returnedAmount > originalAmount) {
            yield = returnedAmount - originalAmount;
            loss = 0;
        } else {
            yield = 0;
            loss = originalAmount - returnedAmount;
        }
        return (yield, loss);
    }

    /**
     * @notice Split yield between treasury and reserve
     * @param totalYield Total yield to split
     * @param treasuryBps Treasury percentage in basis points
     * @return toTreasury Amount for treasury
     * @return toReserve Amount for reserve
     */
    function splitYield(
        uint256 totalYield,
        uint256 treasuryBps
    ) external pure returns (uint256 toTreasury, uint256 toReserve) {
        toTreasury = (totalYield * treasuryBps) / BPS_DENOMINATOR;
        toReserve = totalYield - toTreasury;
        return (toTreasury, toReserve);
    }
}
