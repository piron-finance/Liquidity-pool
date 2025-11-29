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
import "./types/IManagedPoolTypes.sol";
import "./AccessManager.sol";
import "./libraries/CalculationLibrary.sol";
import "./libraries/ValidationLibrary.sol";
import "./libraries/PoolLifecycleLibrary.sol";
import "./libraries/DepositWithdrawalLibrary.sol";


contract Manager is Initializable, UUPSUpgradeable, IPoolManager, ReentrancyGuardUpgradeable {


    IPoolRegistry public registry;
    AccessManager public accessManager;
    
    address public timelockController;
    uint256 public version;
    
    mapping(address => IPoolTypes.PoolData) public pools;
    mapping(address => mapping(address => IPoolTypes.UserPoolData)) public poolUsers;

    mapping(address => IManagedPoolTypes.ManagedPoolConfig) public managedPoolConfigs;
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

    event ManagedPoolInitialized(address indexed managedPool, IManagedPoolTypes.ManagedPoolType poolType, uint256 underlyingPoolsCount);
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

    
    /**
     * @notice Update access manager
     * @param newAccessManager New access manager address
     */
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
        IManagedPoolTypes.ManagedPoolConfig memory poolConfig
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
        return DepositWithdrawalLibrary.handleDeposit(pools, poolUsers, registry, liquidityPool, assets, receiver, sender);
    }

    function handleWithdraw(address liquidityPool, uint256 assets, address receiver, address owner, address sender) external override onlyRegisteredPool whenNotPaused nonReentrant returns (uint256 shares) {
        return DepositWithdrawalLibrary.handleWithdraw(pools, poolUsers, registry, liquidityPool, assets, receiver, owner, sender);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EPOCH MANAGEMENT /////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function handlePoolFilled(address liquidityPool) external whenNotPaused onlyRole(accessManager.OPERATOR_ROLE()) {
        PoolLifecycleLibrary.handlePoolFilled(pools, registry, liquidityPool);
    }

    function closeEpoch(address liquidityPool) external override onlyRole(accessManager.OPERATOR_ROLE()) whenNotPaused {
        IPoolTypes.PoolStatus newStatus = PoolLifecycleLibrary.closeEpoch(pools, registry, liquidityPool);
        _updateStatus(liquidityPool, newStatus);
        
        if (newStatus == IPoolTypes.PoolStatus.EMERGENCY) {
            _emitEmergencyMetrics(liquidityPool, "UNDERFUNDED_EPOCH");
        }
    }

    function forceCloseEpoch(address liquidityPool) external onlyRole(accessManager.EMERGENCY_ROLE()) whenNotPaused {
        IPoolTypes.PoolStatus newStatus = PoolLifecycleLibrary.forceCloseEpoch(pools, registry, liquidityPool);
        _updateStatus(liquidityPool, newStatus);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INVESTMENT FLOW //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function withdrawFundsForInvestment(address liquidityPool, uint256 amount) external onlyRole(accessManager.SPV_ROLE()) whenNotPaused {
        PoolLifecycleLibrary.withdrawFundsForInvestment(pools, registry, liquidityPool, amount);
    }


    function processInvestment(address liquidityPool, uint256 actualAmount, string memory proofHash) external override onlyRole(accessManager.SPV_ROLE()) whenNotPaused {
        PoolLifecycleLibrary.processInvestment(pools, registry, liquidityPool, actualAmount, proofHash);
        _updateStatus(liquidityPool, IPoolTypes.PoolStatus.INVESTED);
    }
    
    function processMaturity(address liquidityPool, uint256 finalAmount) external override onlyRole(accessManager.SPV_ROLE()) whenNotPaused {
        PoolLifecycleLibrary.processMaturity(pools, registry, liquidityPool, finalAmount);
        _updateStatus(liquidityPool, IPoolTypes.PoolStatus.MATURED);
    }

    function markPoolWithdrawn(address pool) external onlyRole(accessManager.OPERATOR_ROLE()) { 
        PoolLifecycleLibrary.markPoolWithdrawn(pools, pool);
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// COUPON PAYMENT SYSTEM ////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function processCouponPayment(address liquidityPool, uint256 amount) external override onlyRole(accessManager.SPV_ROLE()) whenNotPaused {
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        require(_isValidCouponDate(poolData.config), "Manager/invalid coupon date");
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        require(IERC20(poolInfo.asset).balanceOf(msg.sender) >= amount, "Manager/insufficient spv balance");
        
        IERC20(poolInfo.asset).transferFrom(msg.sender, poolInfo.escrow, amount);
        
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.trackCouponPayment(amount);
        
        CalculationLibrary.processCouponPayment(poolData, poolUsers, registry, liquidityPool, amount);
        
        emit CouponReceived(amount, block.timestamp);
        emit CouponPaymentReceived(liquidityPool, amount);
    }

   // so we are marking as distributed to make it available to users to claim 
    function distributeCouponPayment(address liquidityPool) external onlyRole(accessManager.OPERATOR_ROLE()) whenNotPaused {
        require(registry.isRegisteredPool(liquidityPool), "Manager/invalid pool");
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        
        uint256 undistributedCoupons = CalculationLibrary.distributeCouponPayment(poolData, liquidityPool);
        
        emit CouponDistributed(liquidityPool, undistributedCoupons, block.timestamp);
    }
    
    function claimUserCoupon(address liquidityPool, address user) external override onlyRegisteredPool whenNotPaused returns (uint256) {
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        
        uint256 claimableAmount = CalculationLibrary.claimUserCoupon(poolData, poolUsers, liquidityPool, user);
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.releaseFunds(user, claimableAmount);
        
        emit CouponClaimed(liquidityPool, user, claimableAmount);
        
        return claimableAmount;
    }
    
    function getUserAvailableCoupon(address liquidityPool, address user) external onlyRegisteredPool view override returns (uint256) {
        return CalculationLibrary.getUserAvailableCoupon(pools[liquidityPool], poolUsers, liquidityPool, user);
    }

    /**
     * @dev Get the total amount of distributed but unclaimed coupons for a pool
     * @param liquidityPool The address of the liquidity pool
     * @return Total unclaimed coupon amount
     */
    function getUnclaimedCoupons(address liquidityPool) external view override  returns (uint256) {
        require(registry.isRegisteredPool(liquidityPool), "Manager/invalid pool");
        return CalculationLibrary.getUnclaimedCoupons(pools[liquidityPool]);
    }

    /**
     * @dev Get the total amount of received but undistributed coupons for a pool
     * @param liquidityPool The address of the liquidity pool
     * @return Total undistributed coupon amount
     * @notice Restricted to operators - contains sensitive operational timing data
     */
    function getUndistributedCoupons(address liquidityPool) external view onlyRole(accessManager.OPERATOR_ROLE()) returns (uint256) {
        require(registry.isRegisteredPool(liquidityPool), "Manager/invalid pool");
        return CalculationLibrary.getUndistributedCoupons(pools[liquidityPool]);
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
    /////////////////////////////// INTERNAL HELPERS ///////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    
    function _handleFundingWithdrawal(
        address poolAddress, 
        uint256 assets, 
        address receiver, 
        address owner, 
        IPoolTypes.PoolConfig storage poolConfig
    ) internal returns (uint256 shares) {
        return ValidationLibrary.handleFundingWithdrawal(
            pools,
            poolUsers,
            registry,
            poolAddress,
            assets,
            receiver,
            owner,
            poolConfig
        );
    }
    
    function _handleMaturedWithdrawal(
        address poolAddress, 
        address receiver, 
        address owner, 
        IPoolTypes.PoolConfig storage poolConfig
    ) internal returns (uint256 shares) {
        uint256 totalReturns = _calculateTotalReturns(poolAddress);
        return ValidationLibrary.handleMaturedWithdrawal(
            pools,
            poolUsers,
            registry,
            poolAddress,
            receiver,
            owner,
            poolConfig,
            totalReturns
        );
    }
    
    function _handleEmergencyWithdrawal(
        address poolAddress, 
        uint256 assets, 
        address receiver, 
        address owner
    ) internal returns (uint256 shares) {
        return ValidationLibrary.handleEmergencyWithdrawal(
            poolUsers,
            registry,
            poolAddress,
            assets,
            receiver,
            owner
        );
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
        return CalculationLibrary.isValidCouponDate(poolConfig);
    }
    

    
    function _updateStatus(address poolAddress, IPoolTypes.PoolStatus newStatus) internal {
        IPoolTypes.PoolStatus oldStatus = pools[poolAddress].status;
        pools[poolAddress].status = newStatus;
        emit StatusChanged(oldStatus, newStatus);
    }



    
    function calculateMaturityValue() external view onlyRegisteredPool returns (uint256) {
        address poolAddress = msg.sender;
        IPoolTypes.PoolData storage poolData = pools[poolAddress];
        
        if (poolData.config.instrumentType == IPoolTypes.InstrumentType.DISCOUNTED) {
            if (poolData.config.faceValue > 0) {
                return poolData.config.faceValue;
            } else {
                // During funding phase, calculate estimated face value
                return CalculationLibrary.calculateFaceValue(poolData.config.targetRaise, poolData.config.discountRate);
            }
        } else {
            uint256 principal = pools[poolAddress].actualInvested;
            if (principal == 0) {
                // During funding phase, use target raise as estimated principal
                principal = poolData.config.targetRaise;
            }
            uint256 expectedCoupons = CalculationLibrary.calculateExpectedCoupons(
                poolData
            );
            
            return principal + expectedCoupons;
        }
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

 
    function poolStatus(address pool) external view returns (IPoolTypes.PoolStatus) {
        return pools[pool].status;
    }
    
    function poolTotalRaised(address pool) external view returns (uint256) {
        return pools[pool].totalRaised;
    }
    
    function poolActualInvested(address pool) external view returns (uint256) {
        return pools[pool].actualInvested;
    }
    
    function poolTotalDiscountEarned(address pool) external view returns (uint256) {
        return pools[pool].totalDiscountEarned;
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