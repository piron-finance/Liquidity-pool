// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IPoolManager {
    enum PoolStatus {
        FUNDING,
        PENDING_INVESTMENT,
        INVESTED,
        MATURED,
        EMERGENCY
    }
    
    enum InstrumentType {
        DISCOUNTED,
        INTEREST_BEARING
    }
    
    struct PoolConfig {
        InstrumentType instrumentType;
        uint256 faceValue;
        uint256 purchasePrice;
        uint256 targetRaise;
        uint256 epochEndTime;
        uint256 maturityDate;
        uint256[] couponDates;
        uint256[] couponRates;
        uint256 refundGasFee;
        uint256 discountRate; // (basis points)
    }
    
    event Deposit(address liquidityPool, address indexed sender, address indexed receiver, uint256 assets, uint256 shares);
    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event InvestmentConfirmed(uint256 actualAmount, string proofHash);
    event CouponReceived(uint256 amount, uint256 timestamp);
    event CouponDistributed(address indexed liquidityPool, uint256 amount, uint256 timestamp);
    event MaturityProcessed(uint256 finalAmount);  
    event RefundClaimed(address indexed user, uint256 amount);
    event StatusChanged(PoolStatus oldStatus, PoolStatus newStatus);
    event EmergencyExit(address indexed caller, uint256 timestamp);
    event CouponClaimed(address indexed pool, address indexed user, uint256 amount);
    
    function escrow() external view returns (address);
    function config() external view returns (PoolConfig memory);
    function status() external view returns (PoolStatus);
    function totalRaised() external view returns (uint256);
    function actualInvested() external view returns (uint256);
    function totalDiscountEarned() external view returns (uint256);
    function totalCouponsReceived() external view returns (uint256);
    function userDepositTime(address user) external view returns (uint256);
    
    function handleDeposit(address liquidityPool, uint256 assets, address receiver, address sender) external returns (uint256 shares);
    function handleWithdraw(address liquidityPool, uint256 assets, address receiver, address owner, address sender) external returns (uint256 shares);
    function handleRedeem(uint256 shares, address receiver, address owner, address sender) external returns (uint256 assets);
    function calculateTotalAssets() external view returns (uint256);
    
    function processInvestment(address liquidityPool, uint256 actualAmount, string memory proofHash) external;
    function processCouponPayment(address poolAddress, uint256 amount) external;
    function processMaturity(address poolAddress, uint256 finalAmount) external;
    
    function claimUserCoupon(address liquidityPool, address user) external returns (uint256);
    
    function calculateUserReturn(address user) external view returns (uint256);
    function calculateUserDiscount(address user) external view returns (uint256);
    function calculateMaturityValue() external view returns (uint256);
    function getUserAvailableCoupon(address liquidityPool, address user) external view returns (uint256);
    function claimMaturityEntitlement(address user) external view returns (uint256);
    
    function claimRefund() external;
    function getUserRefund(address user) external view returns (uint256);
    
    function emergencyExit() external;
    function pausePool() external;
    function unpausePool() external;
    
    function updateStatus(PoolStatus newStatus) external;
    function closeEpoch(address liquidityPool) external;
    
    function initializePool(address pool, PoolConfig memory poolConfig) external;
    
    function isInFundingPeriod() external view returns (bool);
    function isMatured() external view returns (bool);
    function getTimeToMaturity() external view returns (uint256);
    function getExpectedReturn() external view returns (uint256);
}
