// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19; 

import "./interfaces/IManager.sol";
import "./interfaces/IPoolRegistry.sol";
import "./interfaces/IPoolEscrow.sol";
import "./interfaces/ILiquidityPool.sol";
import "./types/IPoolTypes.sol";
import "./AccessManager.sol";
import "./libraries/CalculationLibrary.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Manager is IPoolManager, ReentrancyGuard {
     
    IPoolRegistry public registry;
    AccessManager public accessManager;
    
    mapping(address => IPoolTypes.PoolData) public pools;
    mapping(address => mapping(address => IPoolTypes.UserPoolData)) public poolUsers;
    
    event PoolPaused(address indexed pool, uint256 timestamp);
    event PoolUnpaused(address indexed pool, uint256 timestamp);
    event AccessManagerUpdated(address oldManager, address newManager);
    event SlippageProtectionActivated(address indexed pool, uint256 expected, uint256 actual, uint256 tolerance);
    event SPVFundsWithdrawn(address indexed pool, uint256 amount, bytes32 transferId);
    event SPVFundsReturned(address indexed pool, uint256 amount);
    event CouponPaymentReceived(address indexed pool, uint256 amount);
    
    modifier onlyValidPool() {
        require(registry.isActivePool(msg.sender), CallerNotPool());
        _;
    }
    
    modifier onlyRegisteredPool() {
        require(registry.isRegisteredPool(msg.sender), InvalidPool());
        _;
    }
    
    modifier onlyFactory() {
        require(msg.sender == registry.factory(), OnlyFactory());
        _;
    }
    
    modifier onlyRole(bytes32 role) {
        require(accessManager.hasRole(role, msg.sender), AccessDenied());
        _;
    }
    
    modifier whenNotPaused() {
        require(!accessManager.paused(), Paused());
        _;
    }
    
    constructor(address _registry, address _accessManager) {
        require(_registry != address(0), InvalidRegistry());
        require(_accessManager != address(0), InvalidAccessManager());
        registry = IPoolRegistry(_registry);
        accessManager = AccessManager(_accessManager);
    }
    
    function setAccessManager(address newAccessManager) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(newAccessManager != address(0), InvalidAccessManager());
        address oldManager = address(accessManager);
        accessManager = AccessManager(newAccessManager);
        emit AccessManagerUpdated(oldManager, newAccessManager);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// POOL SETUP ///////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function initializePool(
        address pool,
        IPoolTypes.PoolConfig memory poolConfig
    ) external onlyFactory whenNotPaused {
        require(pools[pool].config.targetRaise == 0, AlreadyInitialized());
        require(registry.isRegisteredPool(pool), PoolNotRegistered());
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(pool);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.setPool(pool);
        pools[pool].config = poolConfig;
        pools[pool].status = IPoolTypes.PoolStatus.FUNDING;
        
        emit StatusChanged(IPoolTypes.PoolStatus(0), IPoolTypes.PoolStatus.FUNDING);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// DEPOSIT AND WITHDRAWAL FLOW /////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function handleDeposit(address liquidityPool, uint256 assets, address receiver, address sender) external override onlyValidPool whenNotPaused nonReentrant returns (uint256 shares) {  // maybe more access control here. 
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        require(poolInfo.createdAt != 0, InvalidPool());
        require(registry.isApprovedAsset(poolInfo.asset), AssetNotApproved());
        
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        IPoolTypes.PoolStatus currentStatus = pools[liquidityPool].status;
        
        require(currentStatus == IPoolTypes.PoolStatus.FUNDING, NotFundingPhase());
        require(poolData.totalRaised + assets <= poolData.config.targetRaise, ExceedsTarget());
        require(block.timestamp <= poolData.config.epochEndTime, FundingEnded());  // what happens if a deposit is made to a closed pool. yes we can handle it on the fe. but what if by anything we have fuinds in the pool contract. what to do to unclaimed funds. not important now anyway
        
        if (poolUsers[liquidityPool][receiver].depositTime == 0) {
            poolUsers[liquidityPool][receiver].depositTime = block.timestamp;
        }
        shares = assets;
        
        poolData.totalRaised += assets;
        
        
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.receiveDeposit(receiver, assets);
        
        emit Deposit(liquidityPool, sender, receiver, assets, shares);
        
        return shares;
    }

    function handleWithdraw(address liquidityPool, uint256 assets, address receiver, address owner, address sender) external override onlyRegisteredPool whenNotPaused nonReentrant returns (uint256 shares) {
        require(msg.sender == liquidityPool, CallerMustBePool());
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        require(poolInfo.createdAt != 0, InvalidPool());
       
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        IPoolTypes.PoolStatus currentStatus = pools[liquidityPool].status;
        
        require(receiver != address(0), InvalidReceiver());
        require(owner != address(0), InvalidOwner());
        require(sender != address(0), InvalidSender());
        require(assets != 0, InvalidAmount());
        
        if (sender != owner) {
            uint256 allowed = IERC20(liquidityPool).allowance(owner, sender);
            require(allowed >= assets, InsufficientAllowance());
        }
        
        if (currentStatus == IPoolTypes.PoolStatus.FUNDING) {
            return _handleFundingWithdrawal(liquidityPool, assets, receiver, owner, poolData.config);
        } else if (currentStatus == IPoolTypes.PoolStatus.INVESTED) {
            revert WithdrawalNotAllowed(); 
        } else if (currentStatus == IPoolTypes.PoolStatus.MATURED) {
            return _handleMaturedWithdrawal(liquidityPool, receiver, owner, poolData.config);
        } else if (currentStatus == IPoolTypes.PoolStatus.EMERGENCY) {
            return _handleEmergencyWithdrawal(liquidityPool, assets, receiver, owner);
        } else {
            revert WithdrawalNotAllowed();
        }
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EPOCH MANAGEMENT /////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function closeEpoch(address liquidityPool) external override onlyRole(accessManager.OPERATOR_ROLE()) whenNotPaused {
        require(registry.isRegisteredPool(liquidityPool), InvalidPool());
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        require(pools[liquidityPool].status == IPoolTypes.PoolStatus.FUNDING, NotInFunding());
        require(block.timestamp >= poolData.config.epochEndTime, EpochNotEnded());
        
        uint256 amountRaised = pools[liquidityPool].totalRaised;
        
        if (amountRaised >= poolData.config.targetRaise * 50 / 100) {
            if (poolData.config.instrumentType == IPoolTypes.InstrumentType.DISCOUNTED) {
                poolData.config.faceValue = _calculateFaceValue(amountRaised, poolData.config.discountRate);
            } else {
                poolData.config.faceValue = amountRaised;
            }
            
            _updateStatus(liquidityPool, IPoolTypes.PoolStatus.PENDING_INVESTMENT);
        } else {
            _updateStatus(liquidityPool, IPoolTypes.PoolStatus.EMERGENCY);
        }
    }

    function forceCloseEpoch(address liquidityPool) external onlyRole(accessManager.EMERGENCY_ROLE()) whenNotPaused {
        require(registry.isRegisteredPool(liquidityPool), InvalidPool());
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        require(pools[liquidityPool].status == IPoolTypes.PoolStatus.FUNDING, NotInFunding());
        
        uint256 raisedAmount = pools[liquidityPool].totalRaised;
        
        if (raisedAmount >= poolData.config.targetRaise * 50 / 100) {
            if (poolData.config.instrumentType == IPoolTypes.InstrumentType.DISCOUNTED) {
                poolData.config.faceValue = _calculateFaceValue(raisedAmount, poolData.config.discountRate);
            } else {
                poolData.config.faceValue = raisedAmount;
            }
            
            _updateStatus(liquidityPool, IPoolTypes.PoolStatus.PENDING_INVESTMENT);
        } else {
            _updateStatus(liquidityPool, IPoolTypes.PoolStatus.EMERGENCY);
        }
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INVESTMENT FLOW //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function withdrawFundsForInvestment(address liquidityPool, uint256 amount) external onlyRole(accessManager.SPV_ROLE()) whenNotPaused {
        require(registry.isRegisteredPool(liquidityPool), InvalidPool());
        require(pools[liquidityPool].status == IPoolTypes.PoolStatus.PENDING_INVESTMENT, NotPendingInvestment());
        require(amount != 0, InvalidAmount());
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        

        bytes32 transferId = escrowContract.withdrawForInvestment(amount);
        
        pools[liquidityPool].fundsWithdrawnBySPV += amount;
        
        emit SPVFundsWithdrawn(liquidityPool, amount, transferId);
    }

    function processInvestment(address liquidityPool, uint256 actualAmount, string memory proofHash) external onlyRole(accessManager.SPV_ROLE()) whenNotPaused {
        require(registry.isRegisteredPool(liquidityPool), InvalidPool());
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        require(pools[liquidityPool].status == IPoolTypes.PoolStatus.PENDING_INVESTMENT, NotPendingInvestment());
        
        uint256 expectedAmount = pools[liquidityPool].totalRaised;
        
        // Simple 5% slippage protection
        uint256 minAmount = (expectedAmount * 9500) / 10000; // 5% below expected
        uint256 maxAmount = (expectedAmount * 10500) / 10000; // 5% above expected
        if (actualAmount < minAmount || actualAmount > maxAmount) {
            emit SlippageProtectionActivated(liquidityPool, expectedAmount, actualAmount, 500);
            revert SlippageProtectionTriggered();
        }
        
        pools[liquidityPool].actualInvested = actualAmount;
        
        if (poolData.config.instrumentType == IPoolTypes.InstrumentType.DISCOUNTED) {
            uint256 totalDiscount = poolData.config.faceValue - actualAmount;
            pools[liquidityPool].totalDiscountEarned = totalDiscount;
        } else if (poolData.config.instrumentType == IPoolTypes.InstrumentType.INTEREST_BEARING) {
            if (poolData.config.couponDates.length > 0) {
                require(poolData.config.couponDates.length == poolData.config.couponRates.length, CouponConfigMismatch());
                require(poolData.config.couponDates[0] > block.timestamp, InvalidCouponDates());
            }
        }
        
        _updateStatus(liquidityPool, IPoolTypes.PoolStatus.INVESTED);
        
        emit InvestmentConfirmed(actualAmount, proofHash);
    }
    
    function processMaturity(address liquidityPool, uint256 finalAmount) external override onlyRole(accessManager.SPV_ROLE()) whenNotPaused {
        require(registry.isRegisteredPool(liquidityPool), InvalidPool());
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        
        require(pools[liquidityPool].status == IPoolTypes.PoolStatus.INVESTED, NotInvested());
        require(block.timestamp >= poolData.config.maturityDate, NotMatured());
        require(finalAmount != 0, InvalidAmount());
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        require(IERC20(poolInfo.asset).balanceOf(msg.sender) >= finalAmount, InsufficientSpvBalance());
        
        IERC20(poolInfo.asset).transferFrom(msg.sender, poolInfo.escrow, finalAmount);
        
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.trackMaturityReturn(finalAmount);
        
        pools[liquidityPool].fundsReturnedBySPV += finalAmount;
        
        _updateStatus(liquidityPool, IPoolTypes.PoolStatus.MATURED);
        
        emit MaturityProcessed(finalAmount);
        emit SPVFundsReturned(liquidityPool, finalAmount);
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// COUPON PAYMENT SYSTEM ////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function processCouponPayment(address liquidityPool, uint256 amount) external override onlyRole(accessManager.SPV_ROLE()) whenNotPaused {
        require(registry.isRegisteredPool(liquidityPool), InvalidPool());
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        
        require(pools[liquidityPool].status == IPoolTypes.PoolStatus.INVESTED, NotInvested());
        require(poolData.config.instrumentType == IPoolTypes.InstrumentType.INTEREST_BEARING, NotInterestBearing());
        require(amount != 0, InvalidAmount());
        
        require(_isValidCouponDate(poolData.config), InvalidCouponDate());
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        require(IERC20(poolInfo.asset).balanceOf(msg.sender) >= amount, InsufficientSpvBalance());
        
        IERC20(poolInfo.asset).transferFrom(msg.sender, poolInfo.escrow, amount);
        
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.trackCouponPayment(amount);
        
        pools[liquidityPool].totalCouponsReceived += amount;
        
        emit CouponReceived(amount, block.timestamp);
        emit CouponPaymentReceived(liquidityPool, amount);
    }

   // so we are marking as distributed to make it available to users to claim 
    function distributeCouponPayment(address liquidityPool) external onlyRole(accessManager.OPERATOR_ROLE()) whenNotPaused {
        require(registry.isRegisteredPool(liquidityPool), InvalidPool());
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        
        require(pools[liquidityPool].status == IPoolTypes.PoolStatus.INVESTED, NotInvested());
        require(poolData.config.instrumentType == IPoolTypes.InstrumentType.INTEREST_BEARING, NotInterestBearing());
        
        uint256 undistributedCoupons = pools[liquidityPool].totalCouponsReceived - pools[liquidityPool].totalCouponsDistributed;
        require(undistributedCoupons != 0, NoCouponsToDistribute());
        
        uint256 totalShares = IERC20(liquidityPool).totalSupply();
        require(totalShares != 0, NoSharesOutstanding());
        
        // Mark all received coupons as distributed and available for claiming
        pools[liquidityPool].totalCouponsDistributed = pools[liquidityPool].totalCouponsReceived;
        
        emit CouponDistributed(liquidityPool, undistributedCoupons, block.timestamp);
    }
    
    function claimUserCoupon(address liquidityPool, address user) external onlyRegisteredPool whenNotPaused returns (uint256) {
        require(msg.sender == liquidityPool, OnlyPool());
        require(user != address(0), InvalidUser());
        
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        require(poolData.config.instrumentType == IPoolTypes.InstrumentType.INTEREST_BEARING, NotInterestBearing());
        require(pools[liquidityPool].status == IPoolTypes.PoolStatus.INVESTED, NotInvested());
        
        uint256 userShares = IERC20(liquidityPool).balanceOf(user);
        require(userShares != 0, NoShares());
        
        uint256 totalShares = IERC20(liquidityPool).totalSupply();
        uint256 totalDistributedCoupons = pools[liquidityPool].totalCouponsDistributed;
        require(totalDistributedCoupons != 0, NoCouponsDistributed());
        
      
        uint256 userTotalEntitlement = (userShares * totalDistributedCoupons) / totalShares;
        
       
        uint256 userAlreadyClaimed = poolUsers[liquidityPool][user].couponsClaimed;
        
        require(userTotalEntitlement > userAlreadyClaimed, NoNewCoupons());
        uint256 claimableAmount = userTotalEntitlement - userAlreadyClaimed;
        
       
        poolUsers[liquidityPool][user].couponsClaimed = userTotalEntitlement;
        

        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.releaseFunds(user, claimableAmount);
        
        emit CouponClaimed(liquidityPool, user, claimableAmount);
        
        return claimableAmount;
    }
    
    function getUserAvailableCoupon(address liquidityPool, address user) external view returns (uint256) {
        if (user == address(0)) return 0;
        
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        if (poolData.config.instrumentType != IPoolTypes.InstrumentType.INTEREST_BEARING) return 0;
        if (pools[liquidityPool].status != IPoolTypes.PoolStatus.INVESTED) return 0;
        
        uint256 userShares = IERC20(liquidityPool).balanceOf(user);
        if (userShares == 0) return 0;
        
        uint256 totalShares = IERC20(liquidityPool).totalSupply();
        if (totalShares == 0) return 0;
        
        uint256 totalDistributedCoupons = pools[liquidityPool].totalCouponsDistributed;
        if (totalDistributedCoupons == 0) return 0;
        
        uint256 userTotalEntitlement = (userShares * totalDistributedCoupons) / totalShares;
        uint256 userAlreadyClaimed = poolUsers[liquidityPool][user].couponsClaimed;
        
        return userTotalEntitlement > userAlreadyClaimed ? userTotalEntitlement - userAlreadyClaimed : 0;
    }




    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INTERNAL HELPERS ///////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function _calculateFaceValue(uint256 actualRaised, uint256 discountRate) internal pure returns (uint256) {
        return CalculationLibrary.calculateFaceValue(actualRaised, discountRate);
    }
    
    function _handleFundingWithdrawal(
        address poolAddress, 
        uint256 assets, 
        address receiver, 
        address owner, 
        IPoolTypes.PoolConfig storage poolConfig
    ) internal returns (uint256 shares) {
        require(block.timestamp <= poolConfig.epochEndTime, FundingEnded());
        
        shares = assets;
        
        uint256 userShares = IERC20(poolAddress).balanceOf(owner);
        require(userShares >= shares, InsufficientShares());
        
        require(pools[poolAddress].totalRaised >= assets, InsufficientPoolBalance());
        pools[poolAddress].totalRaised -= assets;
        
        if (userShares <= shares) {
            poolUsers[poolAddress][owner].depositTime = 0;
        }
        
        ILiquidityPool(poolAddress).burnShares(owner, shares);
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(poolAddress);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.releaseFunds(receiver, assets);
        
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return shares;
    }
    
    function _handleMaturedWithdrawal(
        address poolAddress, 
        address receiver, 
        address owner, 
        IPoolTypes.PoolConfig storage poolConfig
    ) internal returns (uint256 shares) {
        require(block.timestamp >= poolConfig.maturityDate, NotMatured());
        
        uint256 userShares = IERC20(poolAddress).balanceOf(owner);
        require(userShares != 0, NoShares());
        
        uint256 totalReturns = _calculateTotalReturns(poolAddress);
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
        require(userShares != 0, NoShares());
        
        uint256 maxRefund = _getUserRefundInternal(poolAddress, owner);
        require(maxRefund != 0, NoRefundAvailable());
        require(assets <= maxRefund, ExceedsRefundAmount());
        
        shares = (assets * userShares) / maxRefund;
        
        ILiquidityPool(poolAddress).burnShares(owner, shares);
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(poolAddress);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.releaseFunds(receiver, assets);
        
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return shares;
    }
    
    function _getUserRefundInternal(address poolAddress, address user) internal view returns (uint256) {
        if (pools[poolAddress].status != IPoolTypes.PoolStatus.EMERGENCY) return 0;
        
        uint256 userShares = IERC20(poolAddress).balanceOf(user);
        if (userShares == 0) return 0;
        
        uint256 totalShares = IERC20(poolAddress).totalSupply();
        if (totalShares == 0) return 0;
        
        return (userShares * pools[poolAddress].totalRaised) / totalShares;
    }
    
    function _calculateCurrentPoolValue(address poolAddress) internal view returns (uint256) {
        require(poolAddress != address(0), "Manager/address cannot be null");
        require(registry.isRegisteredPool(poolAddress), InvalidPool());

        IPoolTypes.PoolData storage poolData = pools[poolAddress];

        return CalculationLibrary.calculateCurrentPoolValue(poolData);


    }
    
    function _calculateTotalReturns(address poolAddress) internal view returns (uint256) {
                require(poolAddress != address(0), "Manager/ address cannot be null");
        require(registry.isRegisteredPool(poolAddress), InvalidPool());

        IPoolTypes.PoolData storage poolData = pools[poolAddress];

        return CalculationLibrary.calculateTotalReturns(poolData);
    }
    
    function _isValidCouponDate(IPoolTypes.PoolConfig storage poolConfig) internal view returns (bool) {
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
    
    function _calculateExpectedCoupons(IPoolTypes.PoolData storage poolData) internal view returns (uint256) {

        return CalculationLibrary.calculateExpectedCoupons(poolData);
    }

    
    function _updateStatus(address poolAddress, IPoolTypes.PoolStatus newStatus) internal {
        IPoolTypes.PoolStatus oldStatus = pools[poolAddress].status;
        pools[poolAddress].status = newStatus;
        emit StatusChanged(oldStatus, newStatus);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// USER CALCULATIONS ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function calculateUserReturn(address user) external view override onlyRegisteredPool returns (uint256) {
        require (user != address(0), "Manager/user cannot be empty");
        address poolAddress = msg.sender;
        IPoolTypes.PoolData storage poolData = pools[poolAddress];

        return CalculationLibrary.calculateUserReturn(
            poolData,
            user,
            poolAddress
        );
      
    }
    
    function calculateUserDiscount(address user) external view override onlyRegisteredPool returns (uint256) {
        address poolAddress = msg.sender;
        IPoolTypes.PoolData storage poolData = pools[poolAddress];
        
        if (poolData.config.instrumentType != IPoolTypes.InstrumentType.DISCOUNTED) return 0;
        
        uint256 userShares = IERC20(poolAddress).balanceOf(user);
        if (userShares == 0) return 0;
        
        uint256 totalShares = IERC20(poolAddress).totalSupply();
        if (totalShares == 0) return 0;
        
        return (userShares * pools[poolAddress].totalDiscountEarned) / totalShares;
    }
    
    function calculateMaturityValue() external view override onlyRegisteredPool returns (uint256) {
        address poolAddress = msg.sender;
        IPoolTypes.PoolData storage poolData = pools[poolAddress];
        
        if (poolData.config.instrumentType == IPoolTypes.InstrumentType.DISCOUNTED) {
            if (poolData.config.faceValue > 0) {
                return poolData.config.faceValue;
            } else {
                // During funding phase, calculate estimated face value
                return _calculateFaceValue(poolData.config.targetRaise, poolData.config.discountRate);
            }
        } else {
            uint256 principal = pools[poolAddress].actualInvested;
            if (principal == 0) {
                // During funding phase, use target raise as estimated principal
                principal = poolData.config.targetRaise;
            }
            uint256 expectedCoupons = _calculateExpectedCoupons(poolData);
            return principal + expectedCoupons;
        }
    }

    function claimMaturityEntitlement(address user) external view override returns (uint256) {
        address poolAddress = msg.sender;
        IPoolTypes.PoolData storage poolData = pools[poolAddress];
        
        require(pools[poolAddress].status == IPoolTypes.PoolStatus.MATURED, NotMatured());
        require(block.timestamp >= poolData.config.maturityDate, NotMatured());
        
        uint256 userShares = IERC20(poolAddress).balanceOf(user);
        if (userShares == 0) return 0;
        
        uint256 totalReturns = _calculateTotalReturns(poolAddress);
        uint256 totalShares = IERC20(poolAddress).totalSupply();
        
        return (userShares * totalReturns) / totalShares;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EMERGENCY FUNCTIONS //////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function emergencyExit() external override onlyValidPool {
        address poolAddress = msg.sender;
        _updateStatus(poolAddress, IPoolTypes.PoolStatus.EMERGENCY);
        emit EmergencyExit(msg.sender, block.timestamp);
    }
    
    function cancelPool(address poolAddress) external  onlyRole(accessManager.EMERGENCY_ROLE()) {
        require(registry.isRegisteredPool(poolAddress), InvalidPool());
        require(pools[poolAddress].status == IPoolTypes.PoolStatus.FUNDING, NotInFunding());
        
        _updateStatus(poolAddress, IPoolTypes.PoolStatus.EMERGENCY);
        emit EmergencyExit(msg.sender, block.timestamp);
    }

   
    


    function getUserRefund(address user) external view override returns (uint256) {
        address poolAddress = msg.sender;
        
        if (pools[poolAddress].status != IPoolTypes.PoolStatus.EMERGENCY) return 0;
        
        uint256 userShares = IERC20(poolAddress).balanceOf(user);
        if (userShares == 0) return 0;
        
        uint256 totalShares = IERC20(poolAddress).totalSupply();
        if (totalShares == 0) return 0;
        
        return (userShares * pools[poolAddress].totalRaised) / totalShares;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ADMIN FUNCTIONS //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function pausePool(address poolAddress) external onlyRole(accessManager.OPERATOR_ROLE()) {
        require(registry.isRegisteredPool(poolAddress), InvalidPool());
        ILiquidityPool(poolAddress).pause();
        emit PoolPaused(poolAddress, block.timestamp);
    }
    
    function unpausePool(address poolAddress) external onlyRole(accessManager.OPERATOR_ROLE()) {
        require(registry.isRegisteredPool(poolAddress), InvalidPool());
        ILiquidityPool(poolAddress).unpause();
        emit PoolUnpaused(poolAddress, block.timestamp);
    }
    


    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// VIEW FUNCTIONS ///////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function escrow() external view override returns (address) {
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(msg.sender);
        return poolInfo.escrow;
    }
    
    function config() external view override returns (IPoolTypes.PoolConfig memory) {
        return pools[msg.sender].config;
    }
    
    function status() external view override returns (IPoolTypes.PoolStatus) {
        return pools[msg.sender].status;
    }
    
    function totalRaised() external view override returns (uint256) {
        return pools[msg.sender].totalRaised;
    }
    
    function actualInvested() external view override returns (uint256) {
        return pools[msg.sender].actualInvested;
    }
    
    function totalDiscountEarned() external view override returns (uint256) {
        return pools[msg.sender].totalDiscountEarned;
    }
    
    function totalCouponsReceived() external view override returns (uint256) {
        return pools[msg.sender].totalCouponsReceived;
    }
    
    function userDepositTime(address user) external view override returns (uint256) {
        return poolUsers[msg.sender][user].depositTime;
    }

 
    function poolTotalRaised(address pool) external view returns (uint256) {
        return pools[pool].totalRaised;
    }
    
    function poolActualInvested(address pool) external view returns (uint256) {
        return pools[pool].actualInvested;
    }
    
    function poolUserDepositTime(address pool, address user) external view returns (uint256) {
        return poolUsers[pool][user].depositTime;
    }
    
    function poolStatus(address pool) external view returns (IPoolTypes.PoolStatus) {
        return pools[pool].status;
    }
    
    function poolFundsWithdrawnBySPV(address pool) external view returns (uint256) {
        return pools[pool].fundsWithdrawnBySPV;
    }
    
    function poolFundsReturnedBySPV(address pool) external view returns (uint256) {
        return pools[pool].fundsReturnedBySPV;
    }
    
    function poolTotalCouponsReceived(address pool) external view returns (uint256) {
        return pools[pool].totalCouponsReceived;
    }
    
    function poolTotalCouponsDistributed(address pool) external view returns (uint256) {
        return pools[pool].totalCouponsDistributed;
    }
    
    function poolUserCouponsClaimed(address pool, address user) external view returns (uint256) {
        return poolUsers[pool][user].couponsClaimed;
    }

    function calculateTotalAssets() external view override onlyRegisteredPool returns (uint256) {
        return pools[msg.sender].totalRaised;
    }

    function isInFundingPeriod() external view override onlyRegisteredPool returns (bool) {
        return pools[msg.sender].status == IPoolTypes.PoolStatus.FUNDING && 
               block.timestamp <= pools[msg.sender].config.epochEndTime;
    }
    
    function isMatured() external view override onlyRegisteredPool returns (bool) {
        return block.timestamp >= pools[msg.sender].config.maturityDate;
    }
    
    function getTimeToMaturity() external view override onlyRegisteredPool returns (uint256) {
        uint256 maturityDate = pools[msg.sender].config.maturityDate;
        return block.timestamp >= maturityDate ? 0 : maturityDate - block.timestamp;
    }
    
    function getExpectedReturn() external view override onlyRegisteredPool returns (uint256) {
        address poolAddress = msg.sender;
        IPoolTypes.PoolData storage poolData = pools[poolAddress];
        
       return  CalculationLibrary.calculateExpectedReturn(poolData);
    }
} 