// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./interfaces/IManager.sol";
import "./interfaces/IPoolRegistry.sol";
import "./LiquidityPool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Manager is IPoolManager {
    IPoolRegistry public registry;
    
    mapping(address => PoolConfig) private poolConfigs;
    mapping(address => PoolStatus) public poolStatus;
    mapping(address => uint256) public poolTotalRaised;
    mapping(address => uint256) public poolActualInvested;
    mapping(address => uint256) public poolTotalDiscountEarned;
    mapping(address => uint256) public poolTotalCouponsReceived;
    mapping(address => mapping(address => uint256)) public poolUserDepositTime;
    
    modifier onlyValidPool() {
        require(registry.isActivePool(msg.sender), "Manager/inactive-pool");
        _;
    }
    
    modifier onlyRegisteredPool() {
        require(registry.isRegisteredPool(msg.sender), "Manager/invalid-pool");
        _;
    }
    
    modifier onlyFactory() {
        require(msg.sender == registry.factory(), "Manager/only-factory");
        _;
    }
    
    constructor(address _registry) {
        require(_registry != address(0), "Invalid registry");
        registry = IPoolRegistry(_registry);
    }
    

    function escrow() external view override returns (address) {
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(msg.sender);
        return poolInfo.manager;
    }
    
    function config() external view override returns (PoolConfig memory) {
        return poolConfigs[msg.sender];
    }
    
    function status() external view override returns (PoolStatus) {
        return poolStatus[msg.sender];
    }
    
    function totalRaised() external view override returns (uint256) {
        return poolTotalRaised[msg.sender];
    }
    
    function actualInvested() external view override returns (uint256) {
        return poolActualInvested[msg.sender];
    }
    
    function totalDiscountEarned() external view override returns (uint256) {
        return poolTotalDiscountEarned[msg.sender];
    }
    
    function totalCouponsReceived() external view override returns (uint256) {
        return poolTotalCouponsReceived[msg.sender];
    }
    
    function userDepositTime(address user) external view override returns (uint256) {
        return poolUserDepositTime[msg.sender][user];
    }
    
    function handleDeposit(address liquidityPool, uint256 assets, address receiver, address sender) external override onlyValidPool returns (uint256 shares) {
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        require(poolInfo.createdAt != 0, "Manager/invalid-pool");
        require(registry.isApprovedAsset(poolInfo.asset), "Manager/asset-not-approved");
        
        PoolConfig storage poolConfig = poolConfigs[liquidityPool];
        PoolStatus currentStatus = poolStatus[liquidityPool];
        
        require(currentStatus == PoolStatus.FUNDING, "Manager/not-funding-phase");
        require(poolTotalRaised[liquidityPool] + assets <= poolConfig.targetRaise, "Manager/exceeds-target");
        require(block.timestamp <= poolConfig.epochEndTime, "Manager/funding-ended");
        
        if (poolUserDepositTime[liquidityPool][receiver] == 0) {
            poolUserDepositTime[liquidityPool][receiver] = block.timestamp;
        }
        
        if (poolConfig.instrumentType == InstrumentType.DISCOUNTED) {
            shares = assets;
            poolTotalDiscountEarned[liquidityPool] += (poolConfig.faceValue - poolConfig.purchasePrice) * assets / poolConfig.faceValue;
        } else {
            shares = poolTotalRaised[liquidityPool] == 0 ? assets : (assets * _getTotalSupply(liquidityPool)) / _getTotalAssets(liquidityPool);
        }
        
        poolTotalRaised[liquidityPool] += assets;
        
        emit Deposit(liquidityPool, sender, receiver, assets, shares);
        
        if (poolTotalRaised[liquidityPool] >= poolConfig.targetRaise) {
            _updateStatus(liquidityPool, PoolStatus.PENDING_INVESTMENT);
        }
        
        return shares;
    }
    
    function handleWithdraw(uint256 assets, address receiver, address owner, address sender) external override onlyRegisteredPool returns (uint256 shares) {
        return 0;
    }
    
    function calculateTotalAssets() external view override onlyRegisteredPool returns (uint256) {
        return poolTotalRaised[msg.sender];
    }
    
    function processInvestment(uint256 actualAmount, string memory proofHash) external override onlyValidPool {
        
    }
    
    function processCouponPayment(uint256 amount) external override onlyValidPool {
        
    }
    
    function processMaturity(uint256 finalAmount) external override onlyValidPool {
        
    }
    
    function calculateUserReturn(address user) external view override onlyRegisteredPool returns (uint256) {
        return 0;
    }
    
    function calculateUserDiscount(address user) external view override onlyRegisteredPool returns (uint256) {
        return 0;
    }
    
    function calculateMaturityValue() external view override onlyRegisteredPool returns (uint256) {
        return 0;
    }
    
    function claimRefund() external override {
        
    }
    
    function getUserRefund(address user) external view override returns (uint256) {
        return 0;
    }
    
    function emergencyExit() external override onlyValidPool {
        
    }
    
    function pausePool() external override onlyValidPool {
        
    }
    
    function unpausePool() external override onlyValidPool {
        
    }
    
    function updateStatus(PoolStatus newStatus) external override onlyValidPool {
        _updateStatus(msg.sender, newStatus);
    }
    
    function closeEpoch() external override onlyValidPool {
        
    }
    
    function isInFundingPeriod() external view override onlyRegisteredPool returns (bool) {
        return poolStatus[msg.sender] == PoolStatus.FUNDING && 
               block.timestamp <= poolConfigs[msg.sender].epochEndTime;
    }
    
    function isMatured() external view override onlyRegisteredPool returns (bool) {
        return block.timestamp >= poolConfigs[msg.sender].maturityDate;
    }
    
    function getTimeToMaturity() external view override onlyRegisteredPool returns (uint256) {
        uint256 maturityDate = poolConfigs[msg.sender].maturityDate;
        return block.timestamp >= maturityDate ? 0 : maturityDate - block.timestamp;
    }
    
    function getExpectedReturn() external view override onlyRegisteredPool returns (uint256) {
        return 0;
    }
    
    function _getTotalSupply(address poolAddress) internal view returns (uint256) {
        return IERC20(poolAddress).totalSupply();
    }
    
    function _getTotalAssets(address poolAddress) internal view returns (uint256) {
        return poolTotalRaised[poolAddress];
    }
    
    function _updateStatus(address poolAddress, PoolStatus newStatus) internal {
        PoolStatus oldStatus = poolStatus[poolAddress];
        poolStatus[poolAddress] = newStatus;
        emit StatusChanged(oldStatus, newStatus);
    }
    
    function initializePool(
        address pool,
        PoolConfig memory poolConfig
    ) external onlyFactory {
        require(poolConfigs[pool].targetRaise == 0, "Manager/already-initialized");
        require(registry.isRegisteredPool(pool), "Manager/pool-not-registered");
        
        poolConfigs[pool] = poolConfig;
        poolStatus[pool] = PoolStatus.FUNDING;
        
        emit StatusChanged(PoolStatus(0), PoolStatus.FUNDING);
    }
} 