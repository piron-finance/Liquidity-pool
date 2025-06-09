// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IFeeManager {
    struct FeeConfig {
        uint256 protocolFee;      // Protocol fee in basis points
        uint256 spvFee;           // SPV management fee in basis points
        uint256 performanceFee;   // Performance fee in basis points
        uint256 earlyWithdrawalFee; // Early withdrawal penalty in basis points
        uint256 refundGasFee;     // Gas fee for refunds in basis points
        bool isActive;
    }
    
    struct FeeDistribution {
        address protocolTreasury;
        address spvAddress;
        uint256 protocolShare;    // Share of fees to protocol (basis points)
        uint256 spvShare;         // Share of fees to SPV (basis points)
    }
    
    event FeeConfigUpdated(
        address indexed pool,
        uint256 protocolFee,
        uint256 spvFee,
        uint256 performanceFee
    );
    
    event FeeCollected(
        address indexed pool,
        address indexed payer,
        uint256 amount,
        string feeType
    );
    
    event FeeDistributed(
        address indexed pool,
        address indexed recipient,
        uint256 amount,
        string feeType
    );
    
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    
    function protocolTreasury() external view returns (address);
    function defaultFeeConfig() external view returns (FeeConfig memory);
    function getPoolFeeConfig(address pool) external view returns (FeeConfig memory);
    function getFeeDistribution(address pool) external view returns (FeeDistribution memory);
    
    function calculateProtocolFee(address pool, uint256 amount) external view returns (uint256);
    function calculateSpvFee(address pool, uint256 amount) external view returns (uint256);
    function calculatePerformanceFee(address pool, uint256 profit) external view returns (uint256);
    function calculateEarlyWithdrawalFee(address pool, uint256 amount) external view returns (uint256);
    function calculateRefundGasFee(address pool, uint256 refundAmount) external view returns (uint256);
    
    function setPoolFeeConfig(address pool, FeeConfig memory config) external;
    function setDefaultFeeConfig(FeeConfig memory config) external;
    function setFeeDistribution(address pool, FeeDistribution memory distribution) external;
    function setProtocolTreasury(address treasury) external;
    
    function collectFee(address pool, address payer, uint256 amount, string memory feeType) external;
    function distributeFees(address pool) external;
    function getAccumulatedFees(address pool) external view returns (uint256);
    
    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);
} 