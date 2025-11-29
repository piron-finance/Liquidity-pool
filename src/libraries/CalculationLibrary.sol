// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../types/IPoolTypes.sol";
import "../interfaces/IPoolRegistry.sol";

/**
 * @title CalculationLibrary
 * @dev Library for performing financial calculations related to investment pools
 * @notice This library handles calculations for both discounted and interest-bearing instruments
 */
library CalculationLibrary {
    /// @dev Basis points constant for percentage calculations (10000 = 100%)
    uint256 constant BASIS_POINTS = 10000;
    

    /**
     * @dev Calculates the current value of the pool based on instrument type and status
     * @param poolData Storage reference to pool data
     * @return Current pool value in base currency units
     * @notice For discounted instruments: returns face value at maturity, time-based accrual before
     * @notice For interest-bearing instruments: returns invested amount plus received coupons
     */
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

    /**
     * @dev Calculates the return amount for a specific user based on their share ownership
     * @param poolData Storage reference to pool data
     * @param user Address of the user
     * @param poolAddress Address of the pool contract (ERC20 token)
     * @return User's proportional return amount based on their shares
     * @notice Return calculation varies by pool status:
     * @notice FUNDING: returns user's deposited amount
     * @notice INVESTED: returns proportional share of current pool value
     * @notice MATURED: returns proportional share of total returns
     * @notice EMERGENCY: returns proportional share of total raised funds
     */
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

    /**
     * @dev Calculates the expected return for the entire pool
     * @param poolData Storage reference to pool data
     * @return Expected total return amount for the pool
     * @notice For discounted instruments: returns discount earned (face value - invested amount)
     * @notice For interest-bearing instruments: returns expected coupon payments
     * @notice During funding phase, uses target raise for estimation
     */
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

    /**
     * @dev Calculates the face value of a discounted instrument
     * @param actualRaised Actual amount raised/invested
     * @param discountRate Discount rate in basis points
     * @return Face value of the instrument
     * @notice Face value = actualRaised / (1 - discountRate/10000)
     * @notice Example: $100k raised at 5% discount = $105,263 face value
     */
    function calculateFaceValue(uint256 actualRaised, uint256 discountRate) public pure returns (uint256) {
        require(discountRate < BASIS_POINTS, "Invalid discount rate");
        return (actualRaised * BASIS_POINTS) / (BASIS_POINTS - discountRate);
    }

    /**
     * @dev Calculates the total returns available for distribution to users
     * @param poolData Storage reference to pool data
     * @return Total returns amount available for withdrawal
     * @notice For discounted instruments: returns the full face value
     * @notice For interest-bearing instruments: returns maturity principal plus undistributed coupons
     * @notice Used when pool reaches MATURED status
     */
    function calculateTotalReturns(IPoolTypes.PoolData storage poolData) public view returns (uint256) {
        if (poolData.config.instrumentType == IPoolTypes.InstrumentType.DISCOUNTED) {
            return poolData.config.faceValue;
        } else {
           
            uint256 undistributedCoupons = poolData.totalCouponsReceived - poolData.totalCouponsDistributed;
            return poolData.fundsReturnedBySPV + undistributedCoupons;
        }
    }

    /**
     * @dev Calculates the total expected coupon payments for interest-bearing instruments
     * @param poolData Storage reference to pool data
     * @return Total expected coupon amount over the instrument's lifetime
     * @notice Sums all coupon payments based on coupon rates and principal amount
     * @notice Uses actual invested amount if available, otherwise uses target raise
     * @notice Returns 0 if no coupon rates are configured
     */
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

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// COUPON MANAGEMENT ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @dev Process coupon payment from SPV
     * @param poolData Storage reference to pool data
     * @param poolUsers Storage mapping of user pool data
     * @param poolRegistry Pool registry contract
     * @param liquidityPool Pool address
     * @param amount Coupon amount received
     */
    function processCouponPayment(
        IPoolTypes.PoolData storage poolData,
        mapping(address => mapping(address => IPoolTypes.UserPoolData)) storage poolUsers,
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

    /**
     * @dev Distribute coupon payment to make available for claims
     * @param poolData Storage reference to pool data
     * @param liquidityPool Pool address (for total shares check)
     * @return undistributedAmount Amount that was distributed
     */
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

    /**
     * @dev Calculate and process user coupon claim
     * @param poolData Storage reference to pool data
     * @param poolUsers Storage mapping of user pool data
     * @param liquidityPool Pool address
     * @param user User address
     * @return claimableAmount Amount user can claim
     */
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

    /**
     * @dev Get user's available coupon amount
     * @param poolData Storage reference to pool data
     * @param poolUsers Storage mapping of user pool data
     * @param liquidityPool Pool address
     * @param user User address
     * @return Available coupon amount
     */
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

    /**
     * @dev Get total unclaimed coupons for a pool
     * @param poolData Storage reference to pool data
     * @return Total unclaimed coupon amount
     */
    function getUnclaimedCoupons(
        IPoolTypes.PoolData storage poolData
    ) external view returns (uint256) {
        if (poolData.config.instrumentType != IPoolTypes.InstrumentType.INTEREST_BEARING) return 0;
        if (poolData.totalCouponsDistributed == 0) return 0;
        
        return poolData.totalCouponsDistributed - poolData.totalCouponsClaimed;
    }

    /**
     * @dev Get total undistributed coupons for a pool
     * @param poolData Storage reference to pool data
     * @return Total undistributed coupon amount
     */
    function getUndistributedCoupons(
        IPoolTypes.PoolData storage poolData
    ) external view returns (uint256) {
        if (poolData.config.instrumentType != IPoolTypes.InstrumentType.INTEREST_BEARING) return 0;
        if (poolData.totalCouponsReceived == 0) return 0;
        
        return poolData.totalCouponsReceived - poolData.totalCouponsDistributed;
    }

    /**
     * @notice Checks if current timestamp is within tolerance of a scheduled coupon date
     * @dev Allows 24-hour window around coupon date for flexibility
     */
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