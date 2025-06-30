// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./interfaces/IManager.sol";
import "./interfaces/IPoolRegistry.sol";
import "./interfaces/IPoolEscrow.sol";
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
    mapping(address => uint256) public poolTotalCouponsDistributed;
    mapping(address => mapping(address => uint256)) public poolUserDepositTime;
    
    // Additional events not in interface
    event PoolPaused(address indexed pool, uint256 timestamp);
    event PoolUnpaused(address indexed pool, uint256 timestamp);
    
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
        require(registry.isApprovedAsset(poolInfo.asset), "Manager/asset-not-approved"); // shouldnt we also check that the depoosit the user makes is for an approved asset or can we conclusively solve it on the fe
        
        PoolConfig storage poolConfig = poolConfigs[liquidityPool];
        PoolStatus currentStatus = poolStatus[liquidityPool];
        
        require(currentStatus == PoolStatus.FUNDING, "Manager/not-funding-phase");
        require(poolTotalRaised[liquidityPool] + assets <= poolConfig.targetRaise, "Manager/exceeds-target");
        require(block.timestamp <= poolConfig.epochEndTime, "Manager/funding-ended");
        
        if (poolUserDepositTime[liquidityPool][receiver] == 0) {
            poolUserDepositTime[liquidityPool][receiver] = block.timestamp;
        }
            shares = assets;
    
        
        poolTotalRaised[liquidityPool] += assets;
        
        emit Deposit(liquidityPool, sender, receiver, assets, shares);
        
        return shares;
    }
    
    function handleWithdraw(uint256 assets, address receiver, address owner, address sender) external override onlyRegisteredPool returns (uint256 shares) {
        address poolAddress = msg.sender; //maybe additional checks
        PoolConfig storage poolConfig = poolConfigs[poolAddress];
        PoolStatus currentStatus = poolStatus[poolAddress];
        
        require(receiver != address(0), "Manager/invalid-receiver");
        require(owner != address(0), "Manager/invalid-owner");
        require(assets > 0, "Manager/invalid-amount");
        
    
        if (sender != owner) {
            uint256 allowed = IERC20(poolAddress).allowance(owner, sender);
            require(allowed >= assets, "Manager/insufficient-allowance");
        }
        
        // Different withdrawal logic based on pool status
        if (currentStatus == PoolStatus.FUNDING) {
            return _handleFundingWithdrawal(poolAddress, assets, receiver, owner, poolConfig);
        } else if (currentStatus == PoolStatus.INVESTED) {
            return _handleInvestedWithdrawal(poolAddress, assets, receiver, owner, poolConfig);
        } else if (currentStatus == PoolStatus.MATURED) {
            return _handleMaturedWithdrawal(poolAddress, assets, receiver, owner, poolConfig);
        } else if (currentStatus == PoolStatus.EMERGENCY) {
            return _handleEmergencyWithdrawal(poolAddress, assets, receiver, owner, poolConfig);
        } else {
            revert("Manager/withdrawal-not-allowed");
        }
    }
    
    function calculateTotalAssets() external view override onlyRegisteredPool returns (uint256) {
        return poolTotalRaised[msg.sender];
    }
    
    function processInvestment(address liquidityPool, uint256 actualAmount, string memory proofHash) external onlyValidPool {
        PoolConfig storage poolConfig = poolConfigs[liquidityPool];
        require(poolStatus[liquidityPool] == PoolStatus.PENDING_INVESTMENT, "Manager/not-pending-investment");
        
        poolActualInvested[liquidityPool] = actualAmount;
        
        if (poolConfig.instrumentType == InstrumentType.DISCOUNTED) {
            // Verify we spent approximately what we raised (with some tolerance for fees/slippage)
            uint256 expectedSpend = poolTotalRaised[liquidityPool];
            require(
                actualAmount >= expectedSpend * 95 / 100 && actualAmount <= expectedSpend * 105 / 100,
                "Manager/investment-amount-mismatch"
            );
            
            uint256 totalDiscount = poolConfig.faceValue - actualAmount;
            poolTotalDiscountEarned[liquidityPool] = totalDiscount;
        } else {
           
            uint256 expectedSpend = poolTotalRaised[liquidityPool];
            require(
                actualAmount >= expectedSpend * 95 / 100 && actualAmount <= expectedSpend * 105 / 100,
                "Manager/investment-amount-mismatch"
            );
            
           
            if (poolConfig.couponDates.length > 0) {
                require(poolConfig.couponDates.length == poolConfig.couponRates.length, "Manager/coupon-config-mismatch");
                require(poolConfig.couponDates[0] > block.timestamp, "Manager/invalid-coupon-dates");
            }
            

        }
        
        _updateStatus(liquidityPool, PoolStatus.INVESTED);
        emit InvestmentConfirmed(actualAmount, proofHash);
    }
    
    function processCouponPayment(uint256 amount) external override onlyValidPool { // shouldnt the pool be passed?
        address poolAddress = msg.sender;
        PoolConfig storage poolConfig = poolConfigs[poolAddress];
        
        require(poolStatus[poolAddress] == PoolStatus.INVESTED, "Manager/not-invested");
        require(poolConfig.instrumentType == InstrumentType.INTEREST_BEARING, "Manager/not-interest-bearing");
        require(amount > 0, "Manager/invalid-amount");
        
      
        require(_isValidCouponDate(poolConfig), "Manager/invalid-coupon-date");
        
      
        poolTotalCouponsReceived[poolAddress] += amount;
        
        emit CouponReceived(amount, block.timestamp);
    }
    
    function processMaturity(uint256 finalAmount) external override onlyValidPool { // AGAIN POOL FOR CONTEXT?? MSG SENDER WONT WORK BECAUSE THIS MIGHT BE CALLED BY PROXY OR ADMIN 
        address poolAddress = msg.sender;
        PoolConfig storage poolConfig = poolConfigs[poolAddress];
        
        require(poolStatus[poolAddress] == PoolStatus.INVESTED, "Manager/not-invested");
        require(block.timestamp >= poolConfig.maturityDate, "Manager/not-matured");
        require(finalAmount > 0, "Manager/invalid-amount");
        
       
        if (poolConfig.instrumentType == InstrumentType.DISCOUNTED) {
            require(
                finalAmount >= poolConfig.faceValue * 95 / 100 && 
                finalAmount <= poolConfig.faceValue * 105 / 100,
                "Manager/unexpected-maturity-amount"
            );
        }
        
  
        _updateStatus(poolAddress, PoolStatus.MATURED);
        
        emit MaturityProcessed(finalAmount);
    }
    
    function calculateUserReturn(address user) external view override onlyRegisteredPool returns (uint256) {
        address poolAddress = msg.sender;
        PoolConfig storage poolConfig = poolConfigs[poolAddress];
        PoolStatus currentStatus = poolStatus[poolAddress];
        
        uint256 userShares = IERC20(poolAddress).balanceOf(user);
        if (userShares == 0) return 0;
        
        uint256 totalShares = IERC20(poolAddress).totalSupply();
        if (totalShares == 0) return 0;
        
        if (currentStatus == PoolStatus.FUNDING) {
           
            return userShares;
        } else if (currentStatus == PoolStatus.INVESTED) {
    
            uint256 totalValue = _calculateCurrentPoolValue(poolAddress, poolConfig);
            return (userShares * totalValue) / totalShares;
        } else if (currentStatus == PoolStatus.MATURED) {
       
            uint256 totalReturns = _calculateTotalReturns(poolAddress, poolConfig);
            return (userShares * totalReturns) / totalShares;
        } else if (currentStatus == PoolStatus.EMERGENCY) {
       
            return _getUserRefundInternal(poolAddress, user);
        }
        
        return 0;
    }
    
    function calculateUserDiscount(address user) external view override onlyRegisteredPool returns (uint256) {
        address poolAddress = msg.sender;
        PoolConfig storage poolConfig = poolConfigs[poolAddress];
        
      
        if (poolConfig.instrumentType != InstrumentType.DISCOUNTED) return 0;
        
        uint256 userShares = IERC20(poolAddress).balanceOf(user);
        if (userShares == 0) return 0;
        
        uint256 totalShares = IERC20(poolAddress).totalSupply();
        if (totalShares == 0) return 0;
        
       
        return (userShares * poolTotalDiscountEarned[poolAddress]) / totalShares;
    }
    
    function calculateMaturityValue() external view override onlyRegisteredPool returns (uint256) {
        address poolAddress = msg.sender;
        PoolConfig storage poolConfig = poolConfigs[poolAddress];
        
        if (poolConfig.instrumentType == InstrumentType.DISCOUNTED) {
            return poolConfig.faceValue;
        } else {
           
            uint256 principal = poolActualInvested[poolAddress];
            uint256 expectedCoupons = _calculateExpectedCoupons(poolConfig);
            return principal + expectedCoupons;
        }
    }
    
    function claimRefund() external override {
        // This should be called by the pool, not directly by users
        address poolAddress = msg.sender;
        require(poolStatus[poolAddress] == PoolStatus.EMERGENCY, "Manager/not-emergency-status");
        
        // The actual refund logic should be handled by the LiquidityPool contract
        // This function validates the state and authorizes the refund
    }
    
    function getUserRefund(address user) external view override returns (uint256) {
        address poolAddress = msg.sender;
        
  
        if (poolStatus[poolAddress] != PoolStatus.EMERGENCY) return 0;
        
        uint256 userShares = IERC20(poolAddress).balanceOf(user);
        if (userShares == 0) return 0;
        
        uint256 totalShares = IERC20(poolAddress).totalSupply();
        if (totalShares == 0) return 0;
        
        return (userShares * poolTotalRaised[poolAddress]) / totalShares;
    }
    
    function emergencyExit() external override onlyValidPool {
        address poolAddress = msg.sender;
        _updateStatus(poolAddress, PoolStatus.EMERGENCY);
        emit EmergencyExit(msg.sender, block.timestamp);
    }
    
    function cancelPool() external onlyValidPool {
        address poolAddress = msg.sender;
        require(poolStatus[poolAddress] == PoolStatus.FUNDING, "Manager/not-in-funding");
        
        _updateStatus(poolAddress, PoolStatus.EMERGENCY);
        emit EmergencyExit(msg.sender, block.timestamp);
    }
    
    function forceCloseEpoch() external {
        address poolAddress = msg.sender;
        PoolConfig storage poolConfig = poolConfigs[poolAddress];
        require(poolStatus[poolAddress] == PoolStatus.FUNDING, "Manager/not-in-funding");
        
        // Force close regardless of time - for emergency situations
        uint256 raisedAmount = poolTotalRaised[poolAddress];
        uint256 minimumRaise = poolConfig.targetRaise * 50 / 100;
        
        if (raisedAmount >= minimumRaise) {
   
            if (poolConfig.instrumentType == InstrumentType.DISCOUNTED) {
                poolConfig.faceValue = _calculateFaceValue(raisedAmount, poolConfig.discountRate);
            } else {
            
                poolConfig.faceValue = raisedAmount;
            }
            
            _updateStatus(poolAddress, PoolStatus.PENDING_INVESTMENT);
        } else {
            _updateStatus(poolAddress, PoolStatus.EMERGENCY);
        }
    }
    
    function pausePool() external override onlyValidPool {
        address poolAddress = msg.sender;
        LiquidityPool(poolAddress).pause();
        emit PoolPaused(poolAddress, block.timestamp);
    }
    
    function unpausePool() external override onlyValidPool {
        address poolAddress = msg.sender;
        LiquidityPool(poolAddress).unpause();
        emit PoolUnpaused(poolAddress, block.timestamp);
    }
    
    function updateStatus(PoolStatus newStatus) external override onlyValidPool {
        _updateStatus(msg.sender, newStatus);
    }
    
    function closeEpoch() external override onlyValidPool {
        address poolAddress = msg.sender;
        PoolConfig storage poolConfig = poolConfigs[poolAddress];
        require(poolStatus[poolAddress] == PoolStatus.FUNDING, "Manager/not-in-funding");
        require(block.timestamp >= poolConfig.epochEndTime, "Manager/epoch-not-ended");
        
        uint256 amountRaised = poolTotalRaised[poolAddress];
        
        // Check if minimum viable amount was raised (e.g., 50% of target)
        uint256 minimumRaise = poolConfig.targetRaise * 50 / 100;
        
        if (amountRaised >= minimumRaise) {
    
            if (poolConfig.instrumentType == InstrumentType.DISCOUNTED) {
                poolConfig.faceValue = _calculateFaceValue(amountRaised, poolConfig.discountRate);
            } else {
             
                poolConfig.faceValue = amountRaised;
            }
            
            _updateStatus(poolAddress, PoolStatus.PENDING_INVESTMENT);
        } else {
            _updateStatus(poolAddress, PoolStatus.EMERGENCY);
        }
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
        address poolAddress = msg.sender;
        PoolConfig storage poolConfig = poolConfigs[poolAddress];
        
        if (poolConfig.instrumentType == InstrumentType.DISCOUNTED) {
      
            if (poolConfig.faceValue > 0 && poolActualInvested[poolAddress] > 0) {
                return poolConfig.faceValue - poolActualInvested[poolAddress];
            } else {
      
                uint256 estimatedFaceValue = _calculateFaceValue(poolConfig.targetRaise, poolConfig.discountRate);
                return estimatedFaceValue - poolConfig.targetRaise;
            }
        } else {
           
            return _calculateExpectedCoupons(poolConfig);
        }
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
    
    /**
     * @dev Calculate face value for discounted instruments
     * @param actualRaised Actual amount raised from investors
     * @param discountRate Discount rate in basis points (e.g., 1800 = 18%)
     * @return faceValue The face value at maturity
     */
    function _calculateFaceValue(uint256 actualRaised, uint256 discountRate) internal pure returns (uint256) {
        // Face Value = Actual Raised / (1 - discount rate)
        // For 18% discount with $95,000 raised: Face Value = 95,000 / (1 - 0.18) = 95,000 / 0.82 = 115,854
        require(discountRate < 10000, "Discount rate must be less than 100%");
        
        uint256 discountFactor = 10000 - discountRate; // e.g., 10000 - 1800 = 8200
        return (actualRaised * 10000) / discountFactor;
    }
    
    /**
     * @dev Handle withdrawal during funding period - allows penalty-free exit
     */
    function _handleFundingWithdrawal(
        address poolAddress, 
        uint256 assets, 
        address receiver, 
        address owner, 
        PoolConfig storage poolConfig
    ) internal returns (uint256 shares) {
        require(block.timestamp <= poolConfig.epochEndTime, "Manager/funding-ended");
        
        shares = assets;
        
        require(poolTotalRaised[poolAddress] >= assets, "Manager/insufficient-pool-balance");
        poolTotalRaised[poolAddress] -= assets;
        
        uint256 userShares = IERC20(poolAddress).balanceOf(owner);
        if (userShares <= shares) {
            poolUserDepositTime[poolAddress][owner] = 0;
        }
        
        LiquidityPool(poolAddress).burnShares(owner, shares);
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(poolAddress);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.releaseFunds(receiver, assets);
        
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return shares;
    }
    
    /**
     * @dev Handle withdrawal after investment but before maturity - early exit with penalty
     */
    function _handleInvestedWithdrawal(
        address poolAddress, 
        uint256 assets, 
        address receiver, 
        address owner, 
        PoolConfig storage poolConfig
    ) internal returns (uint256 shares) {
        uint256 totalValue = _calculateCurrentPoolValue(poolAddress, poolConfig);
        uint256 totalShares = IERC20(poolAddress).totalSupply();
        
        shares = (assets * totalShares) / totalValue;
        
        uint256 penaltyRate = 200;
        uint256 penalty = (assets * penaltyRate) / 10000;
        uint256 netAssets = assets - penalty;
        
        require(netAssets <= _getAvailableLiquidity(poolAddress), "Manager/insufficient-liquidity");
        
        LiquidityPool(poolAddress).burnShares(owner, shares);
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(poolAddress);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.releaseFunds(receiver, netAssets);
        
        emit Withdraw(msg.sender, receiver, owner, netAssets, shares);
        return shares;
    }
    
    /**
     * @dev Handle withdrawal after maturity - full return calculation
     */
    function _handleMaturedWithdrawal(
        address poolAddress, 
        uint256 assets, 
        address receiver, 
        address owner, 
        PoolConfig storage poolConfig
    ) internal returns (uint256 shares) {
        require(block.timestamp >= poolConfig.maturityDate, "Manager/not-matured");
        
        uint256 totalReturns = _calculateTotalReturns(poolAddress, poolConfig);
        uint256 totalShares = IERC20(poolAddress).totalSupply();
        
        shares = (assets * totalShares) / totalReturns;
        
        LiquidityPool(poolAddress).burnShares(owner, shares);
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(poolAddress);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.releaseFunds(receiver, assets);
        
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return shares;
    }
    
    /**
     * @dev Handle withdrawal during emergency - refund processing
     */
    function _handleEmergencyWithdrawal(
        address poolAddress, 
        uint256 assets, 
        address receiver, 
        address owner, 
        PoolConfig storage poolConfig
    ) internal returns (uint256 shares) {
        uint256 userRefund = _getUserRefundInternal(poolAddress, owner);
        require(userRefund > 0, "Manager/no-refund-available");
        require(assets <= userRefund, "Manager/exceeds-refund-amount");
        
        shares = assets;
        
        LiquidityPool(poolAddress).burnShares(owner, shares);
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(poolAddress);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.releaseFunds(receiver, assets);
        
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return shares;
    }
    
    /**
     * @dev Internal helper for getUserRefund to avoid visibility issues
     */
    function _getUserRefundInternal(address poolAddress, address user) internal view returns (uint256) {

        if (poolStatus[poolAddress] != PoolStatus.EMERGENCY) return 0;
        
        uint256 userShares = IERC20(poolAddress).balanceOf(user);
        if (userShares == 0) return 0;
        
        uint256 totalShares = IERC20(poolAddress).totalSupply();
        if (totalShares == 0) return 0;
        
        // Proportional refund based on total raised
        return (userShares * poolTotalRaised[poolAddress]) / totalShares;
    }
    
    /**
     * @dev Calculate current pool value including accrued returns
     */
    function _calculateCurrentPoolValue(address poolAddress, PoolConfig storage poolConfig) internal view returns (uint256) {
        uint256 baseValue = poolActualInvested[poolAddress];
        uint256 accruedReturns = 0;
        
        if (poolConfig.instrumentType == InstrumentType.DISCOUNTED) {
            uint256 timeElapsed = block.timestamp - poolConfig.epochEndTime;
            uint256 totalTime = poolConfig.maturityDate - poolConfig.epochEndTime;
            
            if (totalTime > 0) {
                accruedReturns = (poolTotalDiscountEarned[poolAddress] * timeElapsed) / totalTime;
            }
        } else {
            accruedReturns = poolTotalCouponsReceived[poolAddress];
        }
        
        return baseValue + accruedReturns;
    }
    
    /**
     * @dev Get available liquidity for early withdrawals
     */
    function _getAvailableLiquidity(address poolAddress) internal view returns (uint256) {
        // For now, assume 10% of invested amount is kept as liquidity buffer
        return poolActualInvested[poolAddress] / 10;
    }
    
    /**
     * @dev Calculate total returns at maturity
     */
    function _calculateTotalReturns(address poolAddress, PoolConfig storage poolConfig) internal view returns (uint256) {
        if (poolConfig.instrumentType == InstrumentType.DISCOUNTED) {
            return poolConfig.faceValue;
        } else {
            uint256 undistributedCoupons = poolTotalCouponsReceived[poolAddress] - poolTotalCouponsDistributed[poolAddress];
            return poolActualInvested[poolAddress] + undistributedCoupons;
        }
    }
    
    /**
     * @dev Validate if current timestamp matches a scheduled coupon date
     */
    function _isValidCouponDate(PoolConfig storage poolConfig) internal view returns (bool) {
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
    
    /**
     * @dev Calculate expected total coupon payments
     */
    function _calculateExpectedCoupons(PoolConfig storage poolConfig) internal view returns (uint256) {
        if (poolConfig.couponRates.length == 0) return 0;
        
        uint256 totalExpectedCoupons = 0;
        uint256 principal = poolActualInvested[msg.sender];
        
        for (uint256 i = 0; i < poolConfig.couponRates.length; i++) {
            uint256 couponAmount = (principal * poolConfig.couponRates[i]) / 10000;
            totalExpectedCoupons += couponAmount;
        }
        
        return totalExpectedCoupons;
    }
} 