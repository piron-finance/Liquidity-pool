// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../types/IPoolTypes.sol";
import "../interfaces/IPoolRegistry.sol";

/**
 * @title CalculationLibrary
 * @dev Handles pool value calculations, user return projections, coupon processing,
 *      coupon distribution, and per-user coupon claims for Single-Asset (deal) pools.
 */
library CalculationLibrary {
    uint256 constant BASIS_POINTS = 10000;

    // ==================== POOL VALUE ====================
    
    /// @dev Calculates current mark-to-market value of a pool (accrued discount or coupons).
    function calculateCurrentPoolValue(
        IPoolTypes.PoolData storage poolData
    ) internal view returns (uint256) {
        uint256 baseValue = poolData.actualInvested;

        if (poolData.config.instrumentType == IPoolTypes.InstrumentType.DISCOUNTED) {
            if (block.timestamp >= poolData.config.maturityDate) {
                return poolData.config.faceValue;
            } else {
                uint256 timeElapsed = block.timestamp - poolData.config.epochEndTime;
                uint256 totalTime = poolData.config.maturityDate - poolData.config.epochEndTime;

                if (totalTime > 0) {
                    uint256 cappedTimeElapsed = timeElapsed > totalTime ? totalTime : timeElapsed;
                    uint256 accruedReturns = (poolData.totalDiscountEarned * cappedTimeElapsed) / totalTime;
                    return baseValue + accruedReturns;
                }
            }
        } else {
            return baseValue + poolData.totalCouponsReceived;
        }

        return baseValue;
    }

    // ==================== USER RETURNS ====================

    /// @dev Calculates a user's return based on shares, pool status, and instrument type.
    function calculateUserReturn(
        IPoolTypes.PoolData storage poolData,
        address user,
        address poolAddress
    ) external view returns (uint256) {
        uint256 userShares = IERC20(poolAddress).balanceOf(user);
        if (userShares == 0) return 0;

        uint256 totalShares = IERC20(poolAddress).totalSupply();
        if (totalShares == 0) return 0;

        if (poolData.status == IPoolTypes.PoolStatus.FUNDING) {
            return userShares;
        } else if (poolData.status == IPoolTypes.PoolStatus.INVESTED) {
            uint256 totalValue = calculateCurrentPoolValue(poolData);
            return (userShares * totalValue) / totalShares;
        } else if (poolData.status == IPoolTypes.PoolStatus.MATURED) {
            uint256 totalReturns = calculateTotalReturns(poolData);
            return (userShares * totalReturns) / totalShares;
        } else if (poolData.status == IPoolTypes.PoolStatus.EMERGENCY) {
            return (userShares * poolData.totalRaised) / totalShares;
        }

        return 0;
    }

    /// @dev Calculates the expected return for a pool at maturity.
    function calculateExpectedReturn(
        IPoolTypes.PoolData storage poolData
    ) external view returns (uint256) {
        if (poolData.config.instrumentType == IPoolTypes.InstrumentType.DISCOUNTED) {
            if (poolData.status == IPoolTypes.PoolStatus.INVESTED || poolData.status == IPoolTypes.PoolStatus.MATURED) {
                return poolData.config.faceValue - poolData.actualInvested;
            } else {
                uint256 estimatedFaceValue = calculateFaceValue(
                    poolData.config.targetRaise,
                    poolData.config.discountRate
                );
                return estimatedFaceValue - poolData.config.targetRaise;
            }
        } else {
            return calculateExpectedCoupons(poolData);
        }
    }

    // ==================== FACE VALUE / DISCOUNT ====================

    /// @dev Derives face value from the raised amount and discount rate (in BPS).
    function calculateFaceValue(uint256 actualRaised, uint256 discountRate) public pure returns (uint256) {
        require(discountRate < BASIS_POINTS, "Invalid discount rate");
        return (actualRaised * BASIS_POINTS) / (BASIS_POINTS - discountRate);
    }

    /// @dev Total distributable to holders after settlement. The single definition of the
    ///      redemption pot for both instrument types.
    ///
    ///      Based on what the SPV actually returned, never on what it promised. The
    ///      promise lives in `config.faceValue` and is a quote (see calculateExpectedReturn);
    ///      paying from it means a pool that settles short still tries to pay full face and
    ///      drains its escrow, leaving late redeemers with nothing.
    ///
    ///      Coupons already marked distributed are excluded: those are claimable separately
    ///      through claimUserCoupon and have already left the escrow, so counting them here
    ///      would pay them twice.
    function calculateTotalReturns(IPoolTypes.PoolData storage poolData) public view returns (uint256) {
        uint256 undistributedCoupons = poolData.totalCouponsReceived - poolData.totalCouponsDistributed;
        return poolData.fundsReturnedBySPV + undistributedCoupons;
    }

    function calculateExpectedCoupons(IPoolTypes.PoolData storage poolData) public view returns (uint256) {
        if (poolData.config.couponRates.length == 0) return 0;

        uint256 totalExpectedCoupons = 0;
        uint256 principal = poolData.actualInvested > 0 ? poolData.actualInvested : poolData.config.targetRaise;

        for (uint256 i = 0; i < poolData.config.couponRates.length; i++) {
            uint256 couponAmount = (principal * poolData.config.couponRates[i]) / BASIS_POINTS;
            totalExpectedCoupons += couponAmount;
        }

        return totalExpectedCoupons;
    }

    // ==================== COUPON PROCESSING ====================

    /// @dev Records an incoming coupon payment for an interest-bearing pool.
    function processCouponPayment(
        IPoolTypes.PoolData storage poolData,
        mapping(address => mapping(address => IPoolTypes.UserPoolData)) storage /* poolUsers - unused but kept for interface compatibility */,
        IPoolRegistry poolRegistry,
        address liquidityPool,
        uint256 amount
    ) external {
        require(poolRegistry.isRegisteredPool(liquidityPool), "CalculationLib/invalid pool");
        require(poolData.status == IPoolTypes.PoolStatus.INVESTED, "CalculationLib/not invested");
        require(poolData.config.instrumentType == IPoolTypes.InstrumentType.INTEREST_BEARING, "CalculationLib/not interest bearing");
        require(amount != 0, "CalculationLib/invalid amount");
        
        poolData.totalCouponsReceived += amount;
    }

    /// @dev Marks coupons as distributed and returns the undistributed amount.
    function distributeCouponPayment(
        IPoolTypes.PoolData storage poolData,
        address liquidityPool
    ) external returns (uint256 undistributedAmount) {
        require(poolData.status == IPoolTypes.PoolStatus.INVESTED, "CalculationLib/not invested");
        require(poolData.config.instrumentType == IPoolTypes.InstrumentType.INTEREST_BEARING, "CalculationLib/not interest bearing");
        
        undistributedAmount = poolData.totalCouponsReceived - poolData.totalCouponsDistributed;
        require(undistributedAmount != 0, "CalculationLib/no coupons to distribute");
        
        uint256 totalShares = IERC20(liquidityPool).totalSupply();
        require(totalShares != 0, "CalculationLib/no shares outstanding");
        
        poolData.totalCouponsDistributed = poolData.totalCouponsReceived;
        
        return undistributedAmount;
    }

    // ==================== COUPON CLAIMS ====================

    /// @dev Claims a user's pro-rata share of distributed coupons.
    function claimUserCoupon(
        IPoolTypes.PoolData storage poolData,
        mapping(address => mapping(address => IPoolTypes.UserPoolData)) storage poolUsers,
        address liquidityPool,
        address user
    ) external returns (uint256 claimableAmount) {
        require(user != address(0), "CalculationLib/invalid user");
        require(poolData.config.instrumentType == IPoolTypes.InstrumentType.INTEREST_BEARING, "CalculationLib/not interest bearing");
        require(poolData.status == IPoolTypes.PoolStatus.INVESTED, "CalculationLib/not invested");
        
        uint256 userShares = IERC20(liquidityPool).balanceOf(user);
        require(userShares != 0, "CalculationLib/no shares");
        
        uint256 totalShares = IERC20(liquidityPool).totalSupply();
        uint256 totalDistributedCoupons = poolData.totalCouponsDistributed;
        require(totalDistributedCoupons != 0, "CalculationLib/no coupons distributed");
        
        uint256 userTotalEntitlement = (userShares * totalDistributedCoupons) / totalShares;
        uint256 userAlreadyClaimed = poolUsers[liquidityPool][user].couponsClaimed;
        
        require(userTotalEntitlement > userAlreadyClaimed, "CalculationLib/no new coupons");
        claimableAmount = userTotalEntitlement - userAlreadyClaimed;
        
        poolUsers[liquidityPool][user].couponsClaimed = userTotalEntitlement;
        poolData.totalCouponsClaimed += claimableAmount;
        
        return claimableAmount;
    }

    // ==================== COUPON VIEW HELPERS ====================

    /// @dev Returns the claimable coupon amount for a user without modifying state.
    function getUserAvailableCoupon(
        IPoolTypes.PoolData storage poolData,
        mapping(address => mapping(address => IPoolTypes.UserPoolData)) storage poolUsers,
        address liquidityPool,
        address user
    ) external view returns (uint256) {
        if (user == address(0)) return 0;
        if (poolData.config.instrumentType != IPoolTypes.InstrumentType.INTEREST_BEARING) return 0;
        if (poolData.status != IPoolTypes.PoolStatus.INVESTED) return 0;
        
        uint256 userShares = IERC20(liquidityPool).balanceOf(user);
        if (userShares == 0) return 0;
        
        uint256 totalShares = IERC20(liquidityPool).totalSupply();
        if (totalShares == 0) return 0;
        
        uint256 totalDistributedCoupons = poolData.totalCouponsDistributed;
        if (totalDistributedCoupons == 0) return 0;
        
        uint256 userTotalEntitlement = (userShares * totalDistributedCoupons) / totalShares;
        uint256 userAlreadyClaimed = poolUsers[liquidityPool][user].couponsClaimed;
        
        return userTotalEntitlement > userAlreadyClaimed ? userTotalEntitlement - userAlreadyClaimed : 0;
    }

    function getUnclaimedCoupons(
        IPoolTypes.PoolData storage poolData
    ) external view returns (uint256) {
        if (poolData.config.instrumentType != IPoolTypes.InstrumentType.INTEREST_BEARING) return 0;
        if (poolData.totalCouponsDistributed == 0) return 0;
        
        return poolData.totalCouponsDistributed - poolData.totalCouponsClaimed;
    }

    function getUndistributedCoupons(
        IPoolTypes.PoolData storage poolData
    ) external view returns (uint256) {
        if (poolData.config.instrumentType != IPoolTypes.InstrumentType.INTEREST_BEARING) return 0;
        if (poolData.totalCouponsReceived == 0) return 0;
        
        return poolData.totalCouponsReceived - poolData.totalCouponsDistributed;
    }

    // ==================== COUPON DATE VALIDATION ====================

    /// @dev Checks whether the current timestamp falls within a 24-hour window of any scheduled coupon date.
    function isValidCouponDate(
        IPoolTypes.PoolConfig storage poolConfig
    ) internal view returns (bool) {
        if (poolConfig.couponDates.length == 0) return false;
        
        uint256 tolerance = 24 hours;
        
        for (uint256 i = 0; i < poolConfig.couponDates.length; i++) {
            uint256 couponDate = poolConfig.couponDates[i];
            if (block.timestamp >= couponDate - tolerance && 
                block.timestamp <= couponDate + tolerance) {
                return true;
            }
        }
        
        return false;
    }
}
