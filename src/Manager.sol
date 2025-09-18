// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22; 

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IManager.sol";
import "./interfaces/IPoolRegistry.sol";
import "./interfaces/IPoolEscrow.sol";
import "./interfaces/ILiquidityPool.sol";
import "./types/IPoolTypes.sol";
import "./AccessManager.sol";
import "./libraries/CalculationLibrary.sol";
import "./libraries/ValidationLibrary.sol";


contract Manager is Initializable, UUPSUpgradeable, IPoolManager, ReentrancyGuardUpgradeable {

    IPoolRegistry public registry;
    AccessManager public accessManager;
    
    address public timelockController;
    uint256 public version;
    
    mapping(address => IPoolTypes.PoolData) public pools;
    mapping(address => mapping(address => IPoolTypes.UserPoolData)) public poolUsers;

    mapping(address => IPoolTypes.ManagedPoolConfig) public managedPoolConfigs;
    mapping(address => bool) public isManagedPool;
    
    event PoolPaused(address indexed pool, uint256 timestamp);
    event PoolUnpaused(address indexed pool, uint256 timestamp);
    event AccessManagerUpdated(address oldManager, address newManager);
    event SlippageProtectionActivated(address indexed pool, uint256 expected, uint256 actual, uint256 tolerance);
    event SPVFundsWithdrawn(address indexed pool, uint256 amount, bytes32 transferId);
    event SPVFundsReturned(address indexed pool, uint256 amount);
    event CouponPaymentReceived(address indexed pool, uint256 amount);
    event PoolFilled(address indexed pool, uint256 totalRaised, uint256 timestamp);
    event PoolFullyWithdrawn(address indexed pool, uint256 timestamp);
    event EmergencyStateChanged(address indexed poolAddress, string trigger, uint256 totalAmount, uint256 totalShares, uint256 timestamp);
    event PoolCancelled(address indexed poolAddress, address indexed cancelledBy, uint256 timestamp);
    event DiscountsDistributed(address indexed poolAddress, uint256 totalDiscount, uint256 totalShares);

    event ManagedPoolInitialized(address indexed managedPool, IPoolTypes.ManagedPoolType poolType, uint256 underlyingPoolsCount);
    event ManagedPoolRebalanced(address indexed managedPool, uint256 timestamp);

    
    modifier onlyValidPool() {
        require(registry.isActivePool(msg.sender), "Manager/caller not active pool");
        _;
    }
    
    modifier onlyRegisteredPool() {
        require(registry.isRegisteredPool(msg.sender), "Manager/invalid pool");
        _;
    }
    
    modifier onlyFactory() {
        require(msg.sender == registry.factory(), "Manager/only factory");
        _;
    }
    
    modifier onlyRole(bytes32 role) {
        require(accessManager.hasRole(role, msg.sender), "Manager/access denied");
        _;
    }
    
    modifier onlyRoleWithDelay(bytes32 role) {
        require(accessManager.hasRole(role, msg.sender), "Manager/access denied");
        require(accessManager.canActWithDelay(role, msg.sender), "Manager/role delay not met");
        _;
    }
    
    modifier whenNotPaused {
        require(!accessManager.paused(), "Manager/paused");
        _;
    }
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the Manager contract
     * @param _registry PoolRegistry contract address
     * @param _accessManager AccessManager contract address
     * @param _timelockController TimelockController contract address
     */
    function initialize(
        address _registry,
        address _accessManager,
        address _timelockController
    ) public initializer {
        require(_registry != address(0), "Manager/invalid registry");
        require(_accessManager != address(0), "Manager/invalid access manager");
        require(_timelockController != address(0), "Invalid timelock controller");
        
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        registry = IPoolRegistry(_registry);
        accessManager = AccessManager(_accessManager);
        timelockController = _timelockController;
        version = 1;
    }
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ACCESS CONTROL ///////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    
    function setAccessManager(address newAccessManager) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(newAccessManager != address(0), "Manager/invalid access manager");
        address oldManager = address(accessManager);
        accessManager = AccessManager(newAccessManager);
        emit AccessManagerUpdated(oldManager, newAccessManager);
    }

    /**
     * @notice Authorize contract upgrades
     * @param newImplementation New implementation contract address
     * @dev Can only be called by timelock controller after delay
     */

    function _authorizeUpgrade(address newImplementation) internal override {
        require(msg.sender == timelockController, "Only timelock can upgrade");
        require(newImplementation != address(0), "Invalid implementation");
        
        version += 1;
        emit ManagerUpgraded(address(this), newImplementation, version);
    }
    
    /**
     * @notice Update timelock controller
     * @param newTimelockController New timelock controller address
     * @dev Can only be called by current timelock controller
     */

    function setTimelockController(address newTimelockController) external override {
        require(msg.sender == timelockController, "Only current timelock can update");
        require(newTimelockController != address(0), "Invalid timelock controller");
        
        address oldController = timelockController;
        timelockController = newTimelockController;
        emit TimelockControllerUpdated(oldController, newTimelockController);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// POOL SETUP ///////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function initializePool(
        address pool,
        IPoolTypes.PoolConfig memory poolConfig
    ) external override onlyFactory whenNotPaused {
        require(pools[pool].config.targetRaise == 0, "Manager/already initialized");
        require(registry.isRegisteredPool(pool), "Manager/pool not registered");
        require(
            poolConfig.minimumFundingThreshold > 0 && 
            poolConfig.minimumFundingThreshold <= 10000,
            "Invalid minimum funding threshold"
        );
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(pool);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.setPool(pool);
        pools[pool].config = poolConfig;
        pools[pool].status = IPoolTypes.PoolStatus.FUNDING;
        
        emit StatusChanged(IPoolTypes.PoolStatus(0), IPoolTypes.PoolStatus.FUNDING);
    }


    /**
     * @notice Initialize a managed pool configuration
     * @param managedPool Address of the managed pool
     * @param poolConfig Configuration for the managed pool
     */
    function initializeManagedPool(  // refactor again as multiple loops are expensive
        address managedPool,
        IPoolTypes.ManagedPoolConfig memory poolConfig
    ) external onlyRole(accessManager.POOL_CREATOR_ROLE()) {
        require(managedPool != address(0), "Manager/invalid managed pool");
        require(poolConfig.underlyingPools.length > 0, "Manager/no underlying pools");
        require(poolConfig.underlyingPools.length == poolConfig.allocationWeights.length, "Manager/length mismatch");
        
        for (uint256 i = 0; i < poolConfig.underlyingPools.length; i++) {
            require(registry.isRegisteredPool(poolConfig.underlyingPools[i]), "Manager/underlying pool not registered");
        }
        
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < poolConfig.allocationWeights.length; i++) {
            totalWeight += poolConfig.allocationWeights[i];
        }
        require(totalWeight == 10000, "Manager/weights must equal 100%");
        
        managedPoolConfigs[managedPool] = poolConfig;
        isManagedPool[managedPool] = true;
        
        emit ManagedPoolInitialized(managedPool, poolConfig.poolType, poolConfig.underlyingPools.length);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// DEPOSIT AND WITHDRAWAL FLOW /////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function handleDeposit(address liquidityPool, uint256 assets, address receiver, address sender) external override onlyValidPool whenNotPaused nonReentrant returns (uint256 shares) {   
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        ValidationLibrary.validateDeposit(poolData, registry, liquidityPool, assets, receiver);
        ValidationLibrary.validateAddress(sender, false);     
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        
        
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
         IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        IPoolTypes.PoolStatus currentStatus = poolData.status;

        ValidationLibrary.validateWithdrawal(poolData, registry, liquidityPool, owner);
        ValidationLibrary.validateAddress(receiver, true);
        ValidationLibrary.validateAddress(sender, false);
        ValidationLibrary.validateAmount(assets);
        
        
        if (sender != owner) {
            uint256 allowed = IERC20(liquidityPool).allowance(owner, sender);
            require(allowed >= assets, "Manager/insufficient allowance");
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

    function handlePoolFilled(address liquidityPool) external whenNotPaused onlyRole(accessManager.OPERATOR_ROLE()) {
        require(registry.isRegisteredPool(liquidityPool), "Manager/invalid pool");
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        require(poolData.status == IPoolTypes.PoolStatus.FUNDING, "Not in funding");
        require(poolData.totalRaised >= poolData.config.targetRaise, "Not filled");

        poolData.status = IPoolTypes.PoolStatus.FILLED;

        emit PoolFilled(liquidityPool, poolData.totalRaised, block.timestamp);
    }

    function closeEpoch(address liquidityPool) external override onlyRole(accessManager.OPERATOR_ROLE()) whenNotPaused {
        require(registry.isRegisteredPool(liquidityPool), "Manager/invalid pool");
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        require(poolData.status == IPoolTypes.PoolStatus.FUNDING || 
               poolData.status == IPoolTypes.PoolStatus.FILLED, 
               "Manager/not in funding");

        if (poolData.status == IPoolTypes.PoolStatus.FUNDING ) {
        require(block.timestamp >= poolData.config.epochEndTime, "Manager/epoch not ended");
        }
        
        uint256 amountRaised = poolData.totalRaised;
        
        if (amountRaised >= poolData.config.targetRaise * poolData.config.minimumFundingThreshold / 10000) {
            if (poolData.config.instrumentType == IPoolTypes.InstrumentType.DISCOUNTED) {
                poolData.config.faceValue = CalculationLibrary.calculateFaceValue(amountRaised, poolData.config.discountRate);
            } else {
                // For interest-bearing instruments, faceValue is not applicable
                // Amount raised is tracked separately in poolData.totalRaised
                poolData.config.faceValue = 0;
            }
            
            _updateStatus(liquidityPool, IPoolTypes.PoolStatus.PENDING_INVESTMENT);
        } else {
            _updateStatus(liquidityPool, IPoolTypes.PoolStatus.EMERGENCY);
            _emitEmergencyMetrics(liquidityPool, "UNDERFUNDED_EPOCH");
        }
    }

    function forceCloseEpoch(address liquidityPool) external onlyRole(accessManager.EMERGENCY_ROLE()) whenNotPaused {
        require(registry.isRegisteredPool(liquidityPool), "Manager/invalid pool");
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        require(poolData.status == IPoolTypes.PoolStatus.FUNDING, "Manager/not in funding");
        
        uint256 raisedAmount = poolData.totalRaised;
        
        if (raisedAmount >= poolData.config.targetRaise * poolData.config.minimumFundingThreshold / 10000) {
            if (poolData.config.instrumentType == IPoolTypes.InstrumentType.DISCOUNTED) {
                poolData.config.faceValue = CalculationLibrary.calculateFaceValue(raisedAmount, poolData.config.discountRate);
            } else {
                poolData.config.faceValue = 0;
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
        require(registry.isRegisteredPool(liquidityPool), "Manager/invalid pool");
        require(pools[liquidityPool].status == IPoolTypes.PoolStatus.PENDING_INVESTMENT, "Manager/not pending investment");
        require(amount != 0, "Manager/invalid amount");
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        

        bytes32 transferId = escrowContract.withdrawForInvestment(amount);
        
        pools[liquidityPool].fundsWithdrawnBySPV += amount;
        
        emit SPVFundsWithdrawn(liquidityPool, amount, transferId);
    }

    function processInvestment(address liquidityPool, uint256 actualAmount, string memory proofHash) external override onlyRole(accessManager.SPV_ROLE()) whenNotPaused {
        require(registry.isRegisteredPool(liquidityPool), "Manager/invalid pool");
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        require(poolData.status == IPoolTypes.PoolStatus.PENDING_INVESTMENT, "Manager/not pending investment");
        
        require(actualAmount <= poolData.totalRaised, "Manager/Cannot invest more than raised");
        require(actualAmount > 0, "Manager/invalid amount");
        
        poolData.actualInvested = actualAmount;
        
        if (poolData.config.instrumentType == IPoolTypes.InstrumentType.DISCOUNTED) {
            poolData.config.faceValue = CalculationLibrary.calculateFaceValue(actualAmount, poolData.config.discountRate);
            uint256 totalDiscount = poolData.config.faceValue - actualAmount;
            poolData.totalDiscountEarned = totalDiscount;
        } else if (poolData.config.instrumentType == IPoolTypes.InstrumentType.INTEREST_BEARING) {

            poolData.config.faceValue = 0;
            if (poolData.config.couponDates.length > 0) {
                require(poolData.config.couponDates.length == poolData.config.couponRates.length, "Manager/coupon config mismatch");
                require(poolData.config.couponDates[0] > block.timestamp, "Manager/invalid coupon dates");
            }
        }
        
        _updateStatus(liquidityPool, IPoolTypes.PoolStatus.INVESTED);
        
        emit InvestmentConfirmed(actualAmount, proofHash);
    }
    
    function processMaturity(address liquidityPool, uint256 finalAmount) external override onlyRole(accessManager.SPV_ROLE()) whenNotPaused {
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        ValidationLibrary.validateMaturityProcessing(poolData, registry, liquidityPool, finalAmount);
       
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        require(IERC20(poolInfo.asset).balanceOf(msg.sender) >= finalAmount, "Manager/insufficient spv balance");
        
        IERC20(poolInfo.asset).transferFrom(msg.sender, poolInfo.escrow, finalAmount);
        
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.trackMaturityReturn(finalAmount);
        
        poolData.fundsReturnedBySPV += finalAmount;
        
        _updateStatus(liquidityPool, IPoolTypes.PoolStatus.MATURED);
        
        
        emit MaturityProcessed(finalAmount);
        emit SPVFundsReturned(liquidityPool, finalAmount);
    }

    function markPoolWithdrawn(address pool) external onlyRole(accessManager.OPERATOR_ROLE()) { 
         IPoolTypes.PoolData storage poolData = pools[pool];
        require(poolData.status ==  IPoolTypes.PoolStatus.MATURED, "Pool not matured");

        uint256 remainingShares = IERC20(pool).totalSupply();
        require(remainingShares == 0, "Manager/Shares still outstanding");

        poolData.status =  IPoolTypes.PoolStatus.WITHDRAWN;

        emit PoolFullyWithdrawn(pool, block.timestamp);
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// COUPON PAYMENT SYSTEM ////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function processCouponPayment(address liquidityPool, uint256 amount) external override onlyRole(accessManager.SPV_ROLE()) whenNotPaused {
        require(registry.isRegisteredPool(liquidityPool), "Manager/invalid pool");
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        
        require(poolData.status == IPoolTypes.PoolStatus.INVESTED, "Manager/not invested");
        require(poolData.config.instrumentType == IPoolTypes.InstrumentType.INTEREST_BEARING, "Manager/not interest bearing");
        require(amount != 0, "Manager/invalid amount");
        
        require(_isValidCouponDate(poolData.config), "Manager/invalid coupon date"); //note to self: we might need to revise this
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        require(IERC20(poolInfo.asset).balanceOf(msg.sender) >= amount, "Manager/insufficient spv balance");
        
        IERC20(poolInfo.asset).transferFrom(msg.sender, poolInfo.escrow, amount);
        
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.trackCouponPayment(amount);
        
        poolData.totalCouponsReceived += amount;
        
        emit CouponReceived(amount, block.timestamp);
        emit CouponPaymentReceived(liquidityPool, amount);
    }

   // so we are marking as distributed to make it available to users to claim 
    function distributeCouponPayment(address liquidityPool) external onlyRole(accessManager.OPERATOR_ROLE()) whenNotPaused {
        require(registry.isRegisteredPool(liquidityPool), "Manager/invalid pool");
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        
        require(poolData.status == IPoolTypes.PoolStatus.INVESTED, "Manager/not invested");
        require(poolData.config.instrumentType == IPoolTypes.InstrumentType.INTEREST_BEARING, "Manager/not interest bearing");
        
        uint256 undistributedCoupons = poolData.totalCouponsReceived - poolData.totalCouponsDistributed;
        require(undistributedCoupons != 0, "Manager/no coupons to distribute");
        
        uint256 totalShares = IERC20(liquidityPool).totalSupply();
        require(totalShares != 0, "Manager/no shares outstanding");
        
        // Mark all received coupons as distributed and available for claiming
        poolData.totalCouponsDistributed = poolData.totalCouponsReceived;
        
        emit CouponDistributed(liquidityPool, undistributedCoupons, block.timestamp);
    }
    
    function claimUserCoupon(address liquidityPool, address user) external override onlyRegisteredPool whenNotPaused returns (uint256) {
        require(user != address(0), "Manager/invalid user");
        
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        require(poolData.config.instrumentType == IPoolTypes.InstrumentType.INTEREST_BEARING, "Manager/not interest bearing");
        require(pools[liquidityPool].status == IPoolTypes.PoolStatus.INVESTED, "Manager/not invested");
        
        uint256 userShares = IERC20(liquidityPool).balanceOf(user);
        require(userShares != 0, "Manager/no shares");
        
        uint256 totalShares = IERC20(liquidityPool).totalSupply();
        uint256 totalDistributedCoupons = poolData.totalCouponsDistributed;
        require(totalDistributedCoupons != 0, "Manager/no coupons distributed");
        
      
        uint256 userTotalEntitlement = (userShares * totalDistributedCoupons) / totalShares;
        
       
        uint256 userAlreadyClaimed = poolUsers[liquidityPool][user].couponsClaimed;
        
        require(userTotalEntitlement > userAlreadyClaimed, "Manager/no new coupons");
        uint256 claimableAmount = userTotalEntitlement - userAlreadyClaimed;
        
        poolUsers[liquidityPool][user].couponsClaimed = userTotalEntitlement;
        
        poolData.totalCouponsClaimed += claimableAmount;
        

        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.releaseFunds(user, claimableAmount);
        
        emit CouponClaimed(liquidityPool, user, claimableAmount);
        
        return claimableAmount;
    }
    
    function getUserAvailableCoupon(address liquidityPool, address user) external onlyRegisteredPool view override returns (uint256) {
        if (user == address(0)) return 0;
        
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        if (poolData.config.instrumentType != IPoolTypes.InstrumentType.INTEREST_BEARING) return 0;
        if (pools[liquidityPool].status != IPoolTypes.PoolStatus.INVESTED) return 0;
        
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
     * @dev Get the total amount of distributed but unclaimed coupons for a pool
     * @param liquidityPool The address of the liquidity pool
     * @return Total unclaimed coupon amount
     */
    function getUnclaimedCoupons(address liquidityPool) external view override  returns (uint256) {
        require(registry.isRegisteredPool(liquidityPool), "Manager/invalid pool");
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        
        if (poolData.config.instrumentType != IPoolTypes.InstrumentType.INTEREST_BEARING) return 0;
        if (poolData.totalCouponsDistributed == 0) return 0;
        
        return poolData.totalCouponsDistributed - poolData.totalCouponsClaimed;
    }

    /**
     * @dev Get the total amount of received but undistributed coupons for a pool
     * @param liquidityPool The address of the liquidity pool
     * @return Total undistributed coupon amount
     * @notice Restricted to operators - contains sensitive operational timing data
     */
    function getUndistributedCoupons(address liquidityPool) external view onlyRole(accessManager.OPERATOR_ROLE()) returns (uint256) {
        require(registry.isRegisteredPool(liquidityPool), "Manager/invalid pool");
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        
        if (poolData.config.instrumentType != IPoolTypes.InstrumentType.INTEREST_BEARING) return 0;
        if (poolData.totalCouponsReceived == 0) return 0;
        
        return poolData.totalCouponsReceived - poolData.totalCouponsDistributed;
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
        require(user != address(0), "Manager/user cannot be empty");
        address poolAddress = msg.sender;
        IPoolTypes.PoolData storage poolData = pools[poolAddress];
        
        if (poolData.config.instrumentType != IPoolTypes.InstrumentType.DISCOUNTED) return 0;
        
        uint256 userShares = IERC20(poolAddress).balanceOf(user);
        if (userShares == 0) return 0;
        
        uint256 totalShares = IERC20(poolAddress).totalSupply();
        if (totalShares == 0) return 0;
        
        return (userShares * poolData.totalDiscountEarned) / totalShares;
    }
    

    function claimMaturityEntitlement(address user) external view override onlyRegisteredPool returns (uint256) {
        require(user != address(0), "Manager/user cannot be empty");
        address poolAddress = msg.sender;
        IPoolTypes.PoolData storage poolData = pools[poolAddress];
        
        require(poolData.status == IPoolTypes.PoolStatus.MATURED, "Manager/not matured");
        require(block.timestamp >= poolData.config.maturityDate, "Manager/not matured");
        
        uint256 userShares = IERC20(poolAddress).balanceOf(user);
        if (userShares == 0) return 0;
        
        uint256 totalReturns = _calculateTotalReturns(poolAddress);
        uint256 totalShares = IERC20(poolAddress).totalSupply();
        
        return (userShares * totalReturns) / totalShares;
    }


  ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// MANAGED POOL FUNCTIONS ////////////////////
    ////////////////////////////////////////////////////////////////////////////////



    /**
     * @notice Rebalance a managed pool to target allocations
     * @param managedPool Address of the managed pool to rebalance
     */
    function rebalanceManagedPool(address managedPool) external onlyRole(accessManager.OPERATOR_ROLE()) {
        require(isManagedPool[managedPool], "Manager/not a managed pool");
        
        ManagedPoolConfig memory poolConfig = managedPoolConfigs[managedPool];
        
        // Calculate current vs target allocations
        // Execute rebalancing across underlying pools
        // This is simplified - full implementation would calculate deviations
        
        emit ManagedPoolRebalanced(managedPool, block.timestamp);
    }

    /**
     * @notice Get managed pool configuration
     * @param managedPool Address of the managed pool
     * @return Configuration of the managed pool
     */
    function getManagedPoolConfig(address managedPool) external view returns (ManagedPoolConfig memory) {
        require(isManagedPool[managedPool], "Manager/not a managed pool");
        return managedPoolConfigs[managedPool];
    }

    /**
     * @notice Check if a pool is a managed pool
     * @param pool Address to check
     * @return True if the pool is a managed pool
     */
    function isPoolManaged(address pool) external view returns (bool) {
        return isManagedPool[pool];
    }


    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INTERNAL HELPERS ///////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    
    function _handleFundingWithdrawal(
        address poolAddress, 
        uint256 assets, 
        address receiver, 
        address owner, 
        IPoolTypes.PoolConfig storage poolConfig
    ) internal returns (uint256 shares) {
        require(block.timestamp <= poolConfig.epochEndTime, "Manager/funding ended");
        
        shares = assets;
        
        uint256 userShares = IERC20(poolAddress).balanceOf(owner);
        require(userShares >= shares, "Manager/insufficient shares");
        
        require(pools[poolAddress].totalRaised >= assets, "Manager/insufficient pool balance");
        pools[poolAddress].totalRaised -= assets;
        
        
        ILiquidityPool(poolAddress).burnShares(owner, shares);

        uint256 remainingShares = IERC20(poolAddress).balanceOf(owner);

        if (remainingShares == 0 ) {
            poolUsers[poolAddress][owner].depositTime = 0;
        }
        
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
        require(block.timestamp >= poolConfig.maturityDate, "Manager/not matured");
        
        uint256 userShares = IERC20(poolAddress).balanceOf(owner);
        require(userShares != 0, "Manager/no shares");
        
        uint256 totalReturns = _calculateTotalReturns(poolAddress);
        uint256 totalShares = IERC20(poolAddress).totalSupply();
        
        uint256 userEntitlement = (userShares * totalReturns) / totalShares;
        
        shares = userShares;
        ILiquidityPool(poolAddress).burnShares(owner, shares);
        
        poolUsers[poolAddress][owner].depositTime = 0;
        
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
    require(userShares != 0, "Manager/no shares");
    
    
    require(assets <= userShares, "Manager/exceeds refund amount");
    

    shares = assets;
    
    ILiquidityPool(poolAddress).burnShares(owner, shares);

    uint256 remainingShares = IERC20(poolAddress).balanceOf(owner);
    if (remainingShares == 0) {
        poolUsers[poolAddress][owner].depositTime = 0;
    }
    
    IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(poolAddress);
    IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
    escrowContract.releaseFunds(receiver, assets);
    
    emit Withdraw(msg.sender, receiver, owner, assets, shares);
    return shares;
}
    
    
    function _calculateCurrentPoolValue(address poolAddress) internal view returns (uint256) {
        require(poolAddress != address(0), "Manager/address cannot be null");
        require(registry.isRegisteredPool(poolAddress), "Manager/invalid pool");

        IPoolTypes.PoolData storage poolData = pools[poolAddress];

        return CalculationLibrary.calculateCurrentPoolValue(poolData);


    }
    
    function _calculateTotalReturns(address poolAddress) internal view returns (uint256) {
        require(poolAddress != address(0), "Manager/ address cannot be null");
        require(registry.isRegisteredPool(poolAddress), "Manager/invalid pool");

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
    

    
    function _updateStatus(address poolAddress, IPoolTypes.PoolStatus newStatus) internal {
        IPoolTypes.PoolStatus oldStatus = pools[poolAddress].status;
        pools[poolAddress].status = newStatus;
        emit StatusChanged(oldStatus, newStatus);
    }



    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EMERGENCY FUNCTIONS //////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Pool self-reports emergency situation
     * @dev Called by pool contract when it detects issues requiring emergency status
     */
    function emergencyExit() external override onlyValidPool {
        address poolAddress = msg.sender;
        
        _updateStatus(poolAddress, IPoolTypes.PoolStatus.EMERGENCY);
        _emitEmergencyMetrics(poolAddress, "POOL_SELF_REPORT");
        
        emit EmergencyExit(poolAddress, block.timestamp);
    }
    
    /**
     * @notice Admin cancels a pool and puts it in emergency state
     * @dev Called by emergency role for governance/regulatory cancellations
     * @param poolAddress Pool to cancel
     */
    function cancelPool(address poolAddress) external onlyRole(accessManager.EMERGENCY_ROLE()) {
        ValidationLibrary.validatePoolCancellation(pools[poolAddress], registry, poolAddress);
        
        _updateStatus(poolAddress, IPoolTypes.PoolStatus.EMERGENCY);
        _emitEmergencyMetrics(poolAddress, "ADMIN_CANCELLATION");
        
        emit PoolCancelled(poolAddress, msg.sender, block.timestamp);
    }




    /**
     * @notice Internal helper to emit emergency state change metrics
     * @param poolAddress Pool entering emergency state
     * @param trigger Source of emergency (self-report, admin cancel, etc.)
     */
    function _emitEmergencyMetrics(address poolAddress, string memory trigger) internal {
        uint256 totalRefundable = pools[poolAddress].totalRaised;
        uint256 totalShares = IERC20(poolAddress).totalSupply();
        emit EmergencyStateChanged(poolAddress, trigger, totalRefundable, totalShares, block.timestamp);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ADMIN FUNCTIONS //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function pausePool(address poolAddress) external override onlyRole(accessManager.OPERATOR_ROLE()) {
        require(registry.isRegisteredPool(poolAddress), "Manager/invalid pool");
        ILiquidityPool(poolAddress).pause();
        emit PoolPaused(poolAddress, block.timestamp);
    }
    
    function unpausePool(address poolAddress) external override onlyRole(accessManager.OPERATOR_ROLE()) {
        require(registry.isRegisteredPool(poolAddress), "Manager/invalid pool");
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

    function getPoolStatus() external view override onlyRegisteredPool returns (uint8) {
        return uint8(pools[msg.sender].status);
    }


} 