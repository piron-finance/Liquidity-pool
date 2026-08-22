// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title IPoolTypes
/// @dev Shared type definitions for Single-Asset (deal) pools: instrument types,
///      pool lifecycle statuses, configuration, data, and user accounting.
interface IPoolTypes {

    // ==================== ENUMS ====================

    enum InstrumentType {
        DISCOUNTED,
        INTEREST_BEARING
    }
    
    enum PoolStatus {
        FUNDING,
        FILLED,
        PENDING_INVESTMENT,
        INVESTED,
        MATURED,
        WITHDRAWN,
        EMERGENCY
    }
    
    // ==================== STRUCTS ====================

    struct PoolConfig {
        InstrumentType instrumentType;
        uint256 faceValue;
        uint256 purchasePrice;
        uint256 targetRaise;
        uint256 epochEndTime;
        uint256 maturityDate;
        uint256[] couponDates;
        uint256[] couponRates;
        uint256 discountRate;
        uint256 minimumFundingThreshold;
        uint256 minInvestment;
        uint256 withdrawalFeeBps;
    }
    
    struct PoolData {
        PoolConfig config;
        PoolStatus status;
        uint256 totalRaised;
        uint256 actualInvested;
        uint256 totalDiscountEarned;
        uint256 totalCouponsReceived;
        uint256 totalCouponsDistributed;
        uint256 totalCouponsClaimed;
        uint256 fundsWithdrawnBySPV;
        uint256 fundsReturnedBySPV;
        uint256 totalFeesCollected;
        /// @dev Share supply as it stood at settlement.
        ///
        ///      A Single-Asset pool mints nothing after funding closes, so each holder's
        ///      fraction of the settlement is a constant of the deal. Reading the live
        ///      totalSupply() at redemption reads a number that moves because other
        ///      holders left, which has nothing to do with what anyone is owed.
        uint256 sharesAtMaturity;
    }
    
    struct UserPoolData {
        uint256 depositTime;
        uint256 couponsClaimed;
    }

    struct InvestmentProof {
        string documentHash;
        uint256 confirmedAt;
        address confirmedBy;
    }

    enum TransferType {
        DEPOSIT,
        WITHDRAWAL,
        INVESTMENT_TO_SPV,
        MATURITY_RETURN,
        COUPON_PAYMENT,
        FEE_COLLECTION,
        EMERGENCY_REFUND
    }
}
