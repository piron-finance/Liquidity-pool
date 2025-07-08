// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./interfaces/IManager.sol";
import "./interfaces/IPoolRegistry.sol";
import "./interfaces/IPoolEscrow.sol";
import "./interfaces/ILiquidityPool.sol";
import "./AccessManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Manager is IPoolManager, ReentrancyGuard {
    IPoolRegistry public registry;
    AccessManager public accessManager;
    
    mapping(address => PoolConfig) private poolConfigs;
    mapping(address => PoolStatus) public poolStatus;
    mapping(address => uint256) public poolTotalRaised;
    mapping(address => uint256) public poolActualInvested;
    mapping(address => uint256) public poolTotalDiscountEarned;
    mapping(address => uint256) public poolTotalCouponsReceived;
    mapping(address => uint256) public poolTotalCouponsDistributed;
    mapping(address => mapping(address => uint256)) public poolUserDepositTime;
    
    // Add user coupon balances mapping
    mapping(address => mapping(address => uint256)) public poolUserCouponBalances;
    
    // Track user coupon claims to prevent double claiming
    mapping(address => mapping(address => uint256)) public poolUserCouponsClaimed;
    
    // Add slippage protection constants
    uint256 public constant DEFAULT_SLIPPAGE_TOLERANCE = 500; // 5%
    uint256 public constant MAX_SLIPPAGE_TOLERANCE = 1000; // 10%
    
    // Add slippage protection mapping
    mapping(address => uint256) public poolSlippageTolerance;
    
    // Track SPV fund transfers
    mapping(address => uint256) public poolFundsWithdrawnBySPV;
    mapping(address => uint256) public poolFundsReturnedBySPV;
    
    event PoolPaused(address indexed pool, uint256 timestamp);
    event PoolUnpaused(address indexed pool, uint256 timestamp);
    event AccessManagerUpdated(address oldManager, address newManager);
    event SlippageToleranceUpdated(address indexed pool, uint256 oldTolerance, uint256 newTolerance);
    event SlippageProtectionTriggered(address indexed pool, uint256 expected, uint256 actual, uint256 tolerance);
    event SPVFundsWithdrawn(address indexed pool, uint256 amount, bytes32 transferId);
    event SPVFundsReturned(address indexed pool, uint256 amount);
    event CouponPaymentReceived(address indexed pool, uint256 amount);
    
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
    
    modifier onlyRole(bytes32 role) {
        require(accessManager.hasRole(role, msg.sender), "Manager/access-denied");
        _;
    }
    
    modifier onlyRoleWithDelay(bytes32 role) {
        require(accessManager.canActWithDelay(role, msg.sender), "Manager/role-delay-not-met");
        _;
    }
    
    modifier whenNotPaused() {
        require(!accessManager.paused(), "Manager/paused");
        _;
    }
    
    constructor(address _registry, address _accessManager) {
        require(_registry != address(0), "Manager/invalid-registry");
        require(_accessManager != address(0), "Manager/invalid-access-manager");
        registry = IPoolRegistry(_registry);
        accessManager = AccessManager(_accessManager);
    }
    
    function setAccessManager(address newAccessManager) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(newAccessManager != address(0), "Manager/invalid-access-manager");
        address oldManager = address(accessManager);
        accessManager = AccessManager(newAccessManager);
        emit AccessManagerUpdated(oldManager, newAccessManager);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// POOL SETUP ///////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function initializePool(
        address pool,
        PoolConfig memory poolConfig
    ) external onlyFactory whenNotPaused {
        require(poolConfigs[pool].targetRaise == 0, "Manager/already-initialized");
        require(registry.isRegisteredPool(pool), "Manager/pool-not-registered");
        
        poolConfigs[pool] = poolConfig;
        poolStatus[pool] = PoolStatus.FUNDING;
        
        emit StatusChanged(PoolStatus(0), PoolStatus.FUNDING);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// DEPOSIT AND WITHDRAWAL FLOW /////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function handleDeposit(address liquidityPool, uint256 assets, address receiver, address sender) external override onlyValidPool whenNotPaused nonReentrant returns (uint256 shares) {  // don we not need access control here. 
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        require(poolInfo.createdAt != 0, "Manager/invalid-pool");
        require(registry.isApprovedAsset(poolInfo.asset), "Manager/asset-not-approved");
        
        PoolConfig storage poolConfig = poolConfigs[liquidityPool];
        PoolStatus currentStatus = poolStatus[liquidityPool];
        
        require(currentStatus == PoolStatus.FUNDING, "Manager/not-funding-phase");
        require(poolTotalRaised[liquidityPool] + assets <= poolConfig.targetRaise, "Manager/exceeds-target");
        require(block.timestamp <= poolConfig.epochEndTime, "Manager/funding-ended");  // wheat happens if a deposit is made to a closed pool. yes we can handle it on the fe. but what if by anything we have fuinds in the pool contract. what to do to unclkaimed funds. mot im,portant now anyway
        
        if (poolUserDepositTime[liquidityPool][receiver] == 0) {
            poolUserDepositTime[liquidityPool][receiver] = block.timestamp;
        }
        shares = assets;
        
        poolTotalRaised[liquidityPool] += assets;
        
        
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.receiveDeposit(receiver, assets);
        
        emit Deposit(liquidityPool, sender, receiver, assets, shares);
        
        return shares;
    }

    function handleWithdraw(address liquidityPool, uint256 assets, address receiver, address owner, address sender) external override onlyRegisteredPool whenNotPaused nonReentrant returns (uint256 shares) {
        require(msg.sender == liquidityPool, "Manager/caller-must-be-pool");
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        require(poolInfo.createdAt != 0, "Manager/invalid-pool");
       
        PoolConfig storage poolConfig = poolConfigs[liquidityPool];
        PoolStatus currentStatus = poolStatus[liquidityPool];
        
        require(receiver != address(0), "Manager/invalid-receiver");
        require(owner != address(0), "Manager/invalid-owner");
        require(assets > 0, "Manager/invalid-amount");
        
        if (sender != owner) {
            uint256 allowed = IERC20(liquidityPool).allowance(owner, sender);
            require(allowed >= assets, "Manager/insufficient-allowance");
        }
        
        if (currentStatus == PoolStatus.FUNDING) {
            return _handleFundingWithdrawal(liquidityPool, assets, receiver, owner, poolConfig);
        } else if (currentStatus == PoolStatus.INVESTED) {
            return _handleInvestedWithdrawal(liquidityPool, assets, receiver, owner, poolConfig);
        } else if (currentStatus == PoolStatus.MATURED) {
            return _handleMaturedWithdrawal(liquidityPool, receiver, owner, poolConfig);
        } else if (currentStatus == PoolStatus.EMERGENCY) {
            return _handleEmergencyWithdrawal(liquidityPool, assets, receiver, owner);
        } else {
            revert("Manager/withdrawal-not-allowed");
        }
    }

    function handleRedeem(uint256 shares, address receiver, address owner, address sender) external override onlyRegisteredPool whenNotPaused nonReentrant returns (uint256 assets) {
        address poolAddress = msg.sender;
        PoolConfig storage poolConfig = poolConfigs[poolAddress];
        PoolStatus currentStatus = poolStatus[poolAddress];
        
        require(receiver != address(0), "Manager/invalid-receiver");
        require(owner != address(0), "Manager/invalid-owner");
        require(shares > 0, "Manager/invalid-shares");
        
        uint256 userShares = IERC20(poolAddress).balanceOf(owner);
        require(userShares >= shares, "Manager/insufficient-shares");
        
        if (sender != owner) {
            uint256 allowed = IERC20(poolAddress).allowance(owner, sender);
            require(allowed >= shares, "Manager/insufficient-allowance");
        }
        
        if (currentStatus == PoolStatus.FUNDING) {
            return _handleFundingRedeem(poolAddress, shares, receiver, owner, poolConfig);
        } else if (currentStatus == PoolStatus.INVESTED) {
            return _handleInvestedRedeem(poolAddress, shares, receiver, owner, poolConfig);
        } else if (currentStatus == PoolStatus.MATURED) {
            return _handleMaturedRedeem(poolAddress,  receiver, owner, poolConfig);
        } else if (currentStatus == PoolStatus.EMERGENCY) {
            return _handleEmergencyRedeem(poolAddress, shares, receiver, owner);
        } else {
            revert("Manager/redemption-not-allowed");
        }
    }


    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EPOCH MANAGEMENT /////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function closeEpoch(address liquidityPool) external override onlyRole(accessManager.OPERATOR_ROLE()) whenNotPaused {
        require(registry.isRegisteredPool(liquidityPool), "Manager/invalid-pool");
        PoolConfig storage poolConfig = poolConfigs[liquidityPool];
        require(poolStatus[liquidityPool] == PoolStatus.FUNDING, "Manager/not-in-funding");
        require(block.timestamp >= poolConfig.epochEndTime, "Manager/epoch-not-ended");
        
        uint256 amountRaised = poolTotalRaised[liquidityPool];
        
        uint256 minimumRaise = poolConfig.targetRaise * 50 / 100;
        
        if (amountRaised >= minimumRaise) {
            if (poolConfig.instrumentType == InstrumentType.DISCOUNTED) {
                poolConfig.faceValue = _calculateFaceValue(amountRaised, poolConfig.discountRate);
            } else {
                poolConfig.faceValue = amountRaised;
            }
            
            _updateStatus(liquidityPool, PoolStatus.PENDING_INVESTMENT);
        } else {
            _updateStatus(liquidityPool, PoolStatus.EMERGENCY);
        }
    }

    function forceCloseEpoch(address liquidityPool) external onlyRole(accessManager.EMERGENCY_ROLE()) whenNotPaused {
        require(registry.isRegisteredPool(liquidityPool), "Manager/invalid-pool");
        PoolConfig storage poolConfig = poolConfigs[liquidityPool];
        require(poolStatus[liquidityPool] == PoolStatus.FUNDING, "Manager/not-in-funding");
        
        uint256 raisedAmount = poolTotalRaised[liquidityPool];
        uint256 minimumRaise = poolConfig.targetRaise * 50 / 100;
        
        if (raisedAmount >= minimumRaise) {
            if (poolConfig.instrumentType == InstrumentType.DISCOUNTED) {
                poolConfig.faceValue = _calculateFaceValue(raisedAmount, poolConfig.discountRate);
            } else {
                poolConfig.faceValue = raisedAmount;
            }
            
            _updateStatus(liquidityPool, PoolStatus.PENDING_INVESTMENT);
        } else {
            _updateStatus(liquidityPool, PoolStatus.EMERGENCY);
        }
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INVESTMENT FLOW //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function withdrawFundsForInvestment(address liquidityPool, uint256 amount) external onlyRole(accessManager.SPV_ROLE()) whenNotPaused {
        require(registry.isRegisteredPool(liquidityPool), "Manager/invalid-pool");
        require(poolStatus[liquidityPool] == PoolStatus.PENDING_INVESTMENT, "Manager/not-pending-investment");
        require(amount > 0, "Manager/invalid-amount");
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        

        bytes32 transferId = escrowContract.withdrawForInvestment(amount);
        
        poolFundsWithdrawnBySPV[liquidityPool] += amount;
        
        emit SPVFundsWithdrawn(liquidityPool, amount, transferId);
    }

    function processInvestment(address liquidityPool, uint256 actualAmount, string memory proofHash) external onlyRole(accessManager.SPV_ROLE()) whenNotPaused {
        require(registry.isRegisteredPool(liquidityPool), "Manager/invalid-pool");
        PoolConfig storage poolConfig = poolConfigs[liquidityPool];
        require(poolStatus[liquidityPool] == PoolStatus.PENDING_INVESTMENT, "Manager/not-pending-investment");
        
        uint256 expectedAmount = poolTotalRaised[liquidityPool];
        
        checkSlippageProtection(liquidityPool, expectedAmount, actualAmount);
        
        poolActualInvested[liquidityPool] = actualAmount;
        
        if (poolConfig.instrumentType == InstrumentType.DISCOUNTED) {
            uint256 totalDiscount = poolConfig.faceValue - actualAmount;
            poolTotalDiscountEarned[liquidityPool] = totalDiscount;
        } else {
            if (poolConfig.couponDates.length > 0) {
                require(poolConfig.couponDates.length == poolConfig.couponRates.length, "Manager/coupon-config-mismatch");
                require(poolConfig.couponDates[0] > block.timestamp, "Manager/invalid-coupon-dates");
            }
        }
        
        _updateStatus(liquidityPool, PoolStatus.INVESTED);
        emit InvestmentConfirmed(actualAmount, proofHash);
    }
    
    function processMaturity(address liquidityPool, uint256 finalAmount) external override onlyRole(accessManager.SPV_ROLE()) whenNotPaused {
        require(registry.isRegisteredPool(liquidityPool), "Manager/invalid-pool");
        PoolConfig storage poolConfig = poolConfigs[liquidityPool];
        
        require(poolStatus[liquidityPool] == PoolStatus.INVESTED, "Manager/not-invested");
        require(block.timestamp >= poolConfig.maturityDate, "Manager/not-matured");
        require(finalAmount > 0, "Manager/invalid-amount");
        
        if (poolConfig.instrumentType == InstrumentType.DISCOUNTED) {
            checkSlippageProtection(liquidityPool, poolConfig.faceValue, finalAmount);
        }
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        require(IERC20(poolInfo.asset).balanceOf(msg.sender) >= finalAmount, "Manager/insufficient-spv-balance");
        
        IERC20(poolInfo.asset).transferFrom(msg.sender, poolInfo.escrow, finalAmount);
        
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.trackMaturityReturn(finalAmount);
        
        poolFundsReturnedBySPV[liquidityPool] += finalAmount;
        
        _updateStatus(liquidityPool, PoolStatus.MATURED);
        
        emit MaturityProcessed(finalAmount);
        emit SPVFundsReturned(liquidityPool, finalAmount);
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// COUPON PAYMENT SYSTEM ////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function processCouponPayment(address liquidityPool, uint256 amount) external override onlyRole(accessManager.SPV_ROLE()) whenNotPaused {
        require(registry.isRegisteredPool(liquidityPool), "Manager/invalid-pool");
        PoolConfig storage poolConfig = poolConfigs[liquidityPool];
        
        require(poolStatus[liquidityPool] == PoolStatus.INVESTED, "Manager/not-invested");
        require(poolConfig.instrumentType == InstrumentType.INTEREST_BEARING, "Manager/not-interest-bearing");
        require(amount > 0, "Manager/invalid-amount");
        
        require(_isValidCouponDate(poolConfig), "Manager/invalid-coupon-date");
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        require(IERC20(poolInfo.asset).balanceOf(msg.sender) >= amount, "Manager/insufficient-spv-balance");
        
        IERC20(poolInfo.asset).transferFrom(msg.sender, poolInfo.escrow, amount);
        
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.trackCouponPayment(amount);
        
        poolTotalCouponsReceived[liquidityPool] += amount;
        
        emit CouponReceived(amount, block.timestamp);
        emit CouponPaymentReceived(liquidityPool, amount);
    }

   // so we are marking as distributed to make it available to users to claim 
    function distributeCouponPayment(address liquidityPool) external onlyRole(accessManager.OPERATOR_ROLE()) whenNotPaused {
        require(registry.isRegisteredPool(liquidityPool), "Manager/invalid-pool");
        PoolConfig storage poolConfig = poolConfigs[liquidityPool];
        
        require(poolStatus[liquidityPool] == PoolStatus.INVESTED, "Manager/not-invested");
        require(poolConfig.instrumentType == InstrumentType.INTEREST_BEARING, "Manager/not-interest-bearing");
        
        uint256 undistributedCoupons = poolTotalCouponsReceived[liquidityPool] - poolTotalCouponsDistributed[liquidityPool];
        require(undistributedCoupons > 0, "Manager/no-coupons-to-distribute");
        
        uint256 totalShares = IERC20(liquidityPool).totalSupply();
        require(totalShares > 0, "Manager/no-shares-outstanding");
        
        // Mark all received coupons as distributed and available for claiming
        poolTotalCouponsDistributed[liquidityPool] = poolTotalCouponsReceived[liquidityPool];
        
        emit CouponDistributed(liquidityPool, undistributedCoupons, block.timestamp);
    }
    
    function claimUserCoupon(address liquidityPool, address user) external onlyRegisteredPool whenNotPaused returns (uint256) {
        require(msg.sender == liquidityPool, "Manager/only-pool");
        require(user != address(0), "Manager/invalid-user");
        
        PoolConfig storage poolConfig = poolConfigs[liquidityPool];
        require(poolConfig.instrumentType == InstrumentType.INTEREST_BEARING, "Manager/not-interest-bearing");
        require(poolStatus[liquidityPool] == PoolStatus.INVESTED, "Manager/not-invested");
        
        uint256 userShares = IERC20(liquidityPool).balanceOf(user);
        require(userShares > 0, "Manager/no-shares");
        
        uint256 totalShares = IERC20(liquidityPool).totalSupply();
        uint256 totalDistributedCoupons = poolTotalCouponsDistributed[liquidityPool];
        require(totalDistributedCoupons > 0, "Manager/no-coupons-distributed");
        
      
        uint256 userTotalEntitlement = (userShares * totalDistributedCoupons) / totalShares;
        
       
        uint256 userAlreadyClaimed = poolUserCouponsClaimed[liquidityPool][user];
        
        require(userTotalEntitlement > userAlreadyClaimed, "Manager/no-new-coupons");
        uint256 claimableAmount = userTotalEntitlement - userAlreadyClaimed;
        
       
        poolUserCouponsClaimed[liquidityPool][user] = userTotalEntitlement;
        

        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.releaseFunds(user, claimableAmount);
        
        emit CouponClaimed(liquidityPool, user, claimableAmount);
        
        return claimableAmount;
    }
    
    function getUserAvailableCoupon(address liquidityPool, address user) external view returns (uint256) {
        if (user == address(0)) return 0;
        
        PoolConfig storage poolConfig = poolConfigs[liquidityPool];
        if (poolConfig.instrumentType != InstrumentType.INTEREST_BEARING) return 0;
        if (poolStatus[liquidityPool] != PoolStatus.INVESTED) return 0;
        
        uint256 userShares = IERC20(liquidityPool).balanceOf(user);
        if (userShares == 0) return 0;
        
        uint256 totalShares = IERC20(liquidityPool).totalSupply();
        if (totalShares == 0) return 0;
        
        uint256 totalDistributedCoupons = poolTotalCouponsDistributed[liquidityPool];
        if (totalDistributedCoupons == 0) return 0;
        
        uint256 userTotalEntitlement = (userShares * totalDistributedCoupons) / totalShares;
        uint256 userAlreadyClaimed = poolUserCouponsClaimed[liquidityPool][user];
        
        return userTotalEntitlement > userAlreadyClaimed ? userTotalEntitlement - userAlreadyClaimed : 0;
    }




    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INTERNAL HELPERS ///////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function _calculateFaceValue(uint256 actualRaised, uint256 discountRate) internal pure returns (uint256) {
        require(discountRate < 10000, "Manager/discount-rate-too-high");
        
        uint256 discountFactor = 10000 - discountRate;
        return (actualRaised * 10000) / discountFactor;
    }
    
    function _handleFundingWithdrawal(
        address poolAddress, 
        uint256 assets, 
        address receiver, 
        address owner, 
        PoolConfig storage poolConfig
    ) internal returns (uint256 shares) {
        require(block.timestamp <= poolConfig.epochEndTime, "Manager/funding-ended");
        
        shares = assets;
        
        uint256 userShares = IERC20(poolAddress).balanceOf(owner);
        require(userShares >= shares, "Manager/insufficient-shares");
        
        require(poolTotalRaised[poolAddress] >= assets, "Manager/insufficient-pool-balance");
        poolTotalRaised[poolAddress] -= assets;
        
        if (userShares <= shares) {
            poolUserDepositTime[poolAddress][owner] = 0;
        }
        
        ILiquidityPool(poolAddress).burnShares(owner, shares);
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(poolAddress);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.releaseFunds(receiver, assets);
        
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return shares;
    }
    
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
        
        uint256 penalty = _calculateDynamicPenalty(poolAddress, assets, owner);
        uint256 netAssets = assets - penalty;
        
        require(netAssets <= _getAvailableLiquidity(poolAddress), "Manager/insufficient-liquidity");
        
        ILiquidityPool(poolAddress).burnShares(owner, shares);
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(poolAddress);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.releaseFunds(receiver, netAssets);
        
        emit Withdraw(msg.sender, receiver, owner, netAssets, shares);
        return shares;
    }
    
    function _handleMaturedWithdrawal(
        address poolAddress, 
        address receiver, 
        address owner, 
        PoolConfig storage poolConfig
    ) internal returns (uint256 shares) {
        require(block.timestamp >= poolConfig.maturityDate, "Manager/not-matured");
        
        uint256 userShares = IERC20(poolAddress).balanceOf(owner);
        require(userShares > 0, "Manager/no-shares");
        
        uint256 totalReturns = _calculateTotalReturns(poolAddress, poolConfig);
        uint256 totalShares = IERC20(poolAddress).totalSupply();
        
        uint256 userEntitlement = (userShares * totalReturns) / totalShares;
        
        shares = userShares;
        ILiquidityPool(poolAddress).burnShares(owner, shares);
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(poolAddress);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.releaseFunds(receiver, userEntitlement);
        
        emit Withdraw(msg.sender, receiver, owner, userEntitlement, shares);
        return shares;
    }
    
    function _handleEmergencyWithdrawal(
        address poolAddress, 
        uint256 assets, 
        address receiver, 
        address owner
    ) internal returns (uint256 shares) {
        uint256 userShares = IERC20(poolAddress).balanceOf(owner);
        require(userShares > 0, "Manager/no-shares");
        
        uint256 maxRefund = _getUserRefundInternal(poolAddress, owner);
        require(maxRefund > 0, "Manager/no-refund-available");
        require(assets <= maxRefund, "Manager/exceeds-refund-amount");
        
        shares = (assets * userShares) / maxRefund;
        
        ILiquidityPool(poolAddress).burnShares(owner, shares);
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(poolAddress);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.releaseFunds(receiver, assets);
        
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return shares;
    }

    function _handleFundingRedeem(
        address poolAddress, 
        uint256 shares, 
        address receiver, 
        address owner, 
        PoolConfig storage poolConfig
    ) internal returns (uint256 assets) {
        require(block.timestamp <= poolConfig.epochEndTime, "Manager/funding-ended");
        
        assets = shares;
        
        require(poolTotalRaised[poolAddress] >= assets, "Manager/insufficient-pool-balance");
        poolTotalRaised[poolAddress] -= assets;
        
        uint256 userShares = IERC20(poolAddress).balanceOf(owner);
        if (userShares <= shares) {
            poolUserDepositTime[poolAddress][owner] = 0;
        }
        
        ILiquidityPool(poolAddress).burnShares(owner, shares);
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(poolAddress);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.releaseFunds(receiver, assets);
        
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return assets;
    }
    
    function _handleInvestedRedeem(
        address poolAddress, 
        uint256 shares, 
        address receiver, 
        address owner, 
        PoolConfig storage poolConfig
    ) internal returns (uint256 assets) {
        uint256 totalValue = _calculateCurrentPoolValue(poolAddress, poolConfig);
        uint256 totalShares = IERC20(poolAddress).totalSupply();
        
        assets = (shares * totalValue) / totalShares;
        
        uint256 penalty = _calculateDynamicPenalty(poolAddress, assets, owner);
        uint256 netAssets = assets - penalty;
        
        require(netAssets <= _getAvailableLiquidity(poolAddress), "Manager/insufficient-liquidity");
        
        ILiquidityPool(poolAddress).burnShares(owner, shares);
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(poolAddress);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.releaseFunds(receiver, netAssets);
        
        emit Withdraw(msg.sender, receiver, owner, netAssets, shares);
        return netAssets;
    }
    
    function _handleMaturedRedeem(
        address poolAddress, 
        address receiver, 
        address owner, 
        PoolConfig storage poolConfig
    ) internal returns (uint256 assets) {
        require(block.timestamp >= poolConfig.maturityDate, "Manager/not-matured");
        
        uint256 userShares = IERC20(poolAddress).balanceOf(owner);
        require(userShares > 0, "Manager/no-shares");
        
        uint256 totalReturns = _calculateTotalReturns(poolAddress, poolConfig);
        uint256 totalShares = IERC20(poolAddress).totalSupply();
        
        assets = (userShares * totalReturns) / totalShares;
        
        ILiquidityPool(poolAddress).burnShares(owner, userShares);
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(poolAddress);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.releaseFunds(receiver, assets);
        
        emit Withdraw(msg.sender, receiver, owner, assets, userShares);
        return assets;
    }
    
    function _handleEmergencyRedeem(
        address poolAddress, 
        uint256 shares, 
        address receiver, 
        address owner
    ) internal returns (uint256 assets) {
        uint256 totalShares = IERC20(poolAddress).totalSupply();
        
        assets = (shares * poolTotalRaised[poolAddress]) / totalShares;
        
        ILiquidityPool(poolAddress).burnShares(owner, shares);
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(poolAddress);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.releaseFunds(receiver, assets);
        
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return assets;
    }
    
    function _calculateDynamicPenalty(address poolAddress, uint256 assets, address owner) internal view returns (uint256) {
        uint256 depositTime = poolUserDepositTime[poolAddress][owner];
        if (depositTime == 0) return 0;
        
        uint256 timeHeld = block.timestamp - depositTime;
        uint256 basePenalty = 200; // 2% base penalty
        
        if (timeHeld < 7 days) {
            return (assets * 500) / 10000; // 5% penalty for < 1 week
        } else if (timeHeld < 30 days) {
            return (assets * 300) / 10000; // 3% penalty for < 1 month
        } else if (timeHeld < 90 days) {
            return (assets * basePenalty) / 10000; // 2% penalty for < 3 months
        } else {
            return (assets * 100) / 10000; // 1% penalty for > 3 months
        }
    }
    
    function _getUserRefundInternal(address poolAddress, address user) internal view returns (uint256) {
        if (poolStatus[poolAddress] != PoolStatus.EMERGENCY) return 0;
        
        uint256 userShares = IERC20(poolAddress).balanceOf(user);
        if (userShares == 0) return 0;
        
        uint256 totalShares = IERC20(poolAddress).totalSupply();
        if (totalShares == 0) return 0;
        
        return (userShares * poolTotalRaised[poolAddress]) / totalShares;
    }
    
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
    
    function _getAvailableLiquidity(address poolAddress) internal view returns (uint256) {
        return poolActualInvested[poolAddress] / 10;
    }
    
    function _calculateTotalReturns(address poolAddress, PoolConfig storage poolConfig) internal view returns (uint256) {
        if (poolConfig.instrumentType == InstrumentType.DISCOUNTED) {
            return poolConfig.faceValue;
        } else {
            uint256 undistributedCoupons = poolTotalCouponsReceived[poolAddress] - poolTotalCouponsDistributed[poolAddress];
            return poolActualInvested[poolAddress] + undistributedCoupons;
        }
    }
    
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

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// USER CALCULATIONS ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

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

    function claimMaturityEntitlement(address user) external view override returns (uint256) {
        address poolAddress = msg.sender;
        PoolConfig storage poolConfig = poolConfigs[poolAddress];
        
        require(poolStatus[poolAddress] == PoolStatus.MATURED, "Manager/not-matured");
        require(block.timestamp >= poolConfig.maturityDate, "Manager/not-matured");
        
        uint256 userShares = IERC20(poolAddress).balanceOf(user);
        if (userShares == 0) return 0;
        
        uint256 totalReturns = _calculateTotalReturns(poolAddress, poolConfig);
        uint256 totalShares = IERC20(poolAddress).totalSupply();
        
        return (userShares * totalReturns) / totalShares;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EMERGENCY FUNCTIONS //////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function emergencyExit() external override onlyValidPool {
        address poolAddress = msg.sender;
        _updateStatus(poolAddress, PoolStatus.EMERGENCY);
        emit EmergencyExit(msg.sender, block.timestamp);
    }
    
    function cancelPool() external onlyValidPool onlyRole(accessManager.EMERGENCY_ROLE()) {
        address poolAddress = msg.sender;
        require(poolStatus[poolAddress] == PoolStatus.FUNDING, "Manager/not-in-funding");
        
        _updateStatus(poolAddress, PoolStatus.EMERGENCY);
        emit EmergencyExit(msg.sender, block.timestamp);
    }

    function claimRefund() external view override {
        address poolAddress = msg.sender;
        require(poolStatus[poolAddress] == PoolStatus.EMERGENCY, "Manager/not-emergency-status");
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

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ADMIN FUNCTIONS //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function pausePool() external override onlyValidPool onlyRole(accessManager.OPERATOR_ROLE()) {
        address poolAddress = msg.sender;
        ILiquidityPool(poolAddress).pause();
        emit PoolPaused(poolAddress, block.timestamp);
    }
    
    function unpausePool() external override onlyValidPool onlyRole(accessManager.OPERATOR_ROLE()) {
        address poolAddress = msg.sender;
        ILiquidityPool(poolAddress).unpause();
        emit PoolUnpaused(poolAddress, block.timestamp);
    }
    
    function updateStatus(PoolStatus newStatus) external override onlyValidPool onlyRole(accessManager.OPERATOR_ROLE()) {
        _updateStatus(msg.sender, newStatus);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// SLIPPAGE PROTECTION ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function setSlippageTolerance(address pool, uint256 tolerance) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(registry.isRegisteredPool(pool), "Manager/invalid-pool");
        require(tolerance <= MAX_SLIPPAGE_TOLERANCE, "Manager/tolerance-too-high");
        
        uint256 oldTolerance = poolSlippageTolerance[pool];
        poolSlippageTolerance[pool] = tolerance;
        
        emit SlippageToleranceUpdated(pool, oldTolerance, tolerance);
    }
    
    function getSlippageTolerance(address pool) public view returns (uint256) {
        uint256 tolerance = poolSlippageTolerance[pool];
        return tolerance == 0 ? DEFAULT_SLIPPAGE_TOLERANCE : tolerance;
    }
    
    function validateSlippage(address pool, uint256 expected, uint256 actual) public view returns (bool) {
        uint256 tolerance = getSlippageTolerance(pool);
        uint256 minAmount = (expected * (10000 - tolerance)) / 10000;
        uint256 maxAmount = (expected * (10000 + tolerance)) / 10000;
        
        return actual >= minAmount && actual <= maxAmount;
    }
    
    function checkSlippageProtection(address pool, uint256 expected, uint256 actual) internal {
        if (!validateSlippage(pool, expected, actual)) {
            uint256 tolerance = getSlippageTolerance(pool);
            emit SlippageProtectionTriggered(pool, expected, actual, tolerance);
            revert("Manager/slippage-protection-triggered");
        }
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// VIEW FUNCTIONS ///////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function escrow() external view override returns (address) {
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(msg.sender);
        return poolInfo.escrow;
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

    function calculateTotalAssets() external view override onlyRegisteredPool returns (uint256) {
        return poolTotalRaised[msg.sender];
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
} 