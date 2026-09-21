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
import "./interfaces/IFeeManager.sol";
import "./types/IPoolTypes.sol";
import "./AccessManager.sol";
import "./libraries/CalculationLibrary.sol";
import "./libraries/ValidationLibrary.sol";
import "./libraries/PoolLifecycleLibrary.sol";
import "./libraries/DepositWithdrawalLibrary.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Manager
 * @dev Business logic for Single Asset (deal) pools. Manages lifecycle from funding
 *      through investment, coupon payments, maturity, and withdrawal. All fund movements
 *      go through PoolEscrow. Upgradeable via TimelockController.
 */
contract Manager is Initializable, UUPSUpgradeable, IPoolManager, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // ==================== ERRORS ====================

    error InvalidAddress();
    error Unauthorized();
    error ContractPaused();
    error OnlyTimelock();
    error InvalidConfig();
    error FeeTooHigh();
    error InvalidStatus();
    error InvalidExtension();

    // ==================== STATE ====================

    IPoolRegistry public registry;
    AccessManager public accessManager;
    
    address public timelockController;
    address public treasury;
    uint256 public version;
    
    uint256 public constant MAX_EXTENSION_DAYS = 90;
    uint256 public constant MAX_WITHDRAWAL_FEE = 500;
    uint256 public constant MAX_DEPOSIT_FEE = 500;
    uint256 public constant BPS = 10000;
    
    address public feeManager;
    uint256 public defaultDepositFeeBps;
    mapping(address => uint256) public poolDepositFeeBps;
    
    mapping(address => IPoolTypes.PoolData) public pools;
    mapping(address => mapping(address => IPoolTypes.UserPoolData)) public poolUsers;
    mapping(address => IPoolTypes.InvestmentProof) public investmentProofs;
    
    // ==================== EVENTS ====================

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
    event MaturityExtended(address indexed pool, uint256 oldDate, uint256 newDate, address indexed extendedBy);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event WithdrawalFeeCollected(address indexed pool, address indexed user, uint256 feeAmount, uint256 netAmount);
    event InvestmentProofRecorded(address indexed pool, string documentHash, address indexed confirmedBy);
    event MaturityShortfall(address indexed pool, uint256 expected, uint256 actual, uint256 shortfall);
    event MaturityOverage(address indexed pool, uint256 expected, uint256 actual);
    event DepositFeeCollected(address indexed pool, address indexed depositor, uint256 amount, uint256 fee);
    event FeeManagerUpdated(address indexed feeManager);
    event DefaultDepositFeeUpdated(uint256 feeBps);
    event PoolDepositFeeUpdated(address indexed pool, uint256 feeBps);
    
    // ==================== MODIFIERS ====================

    modifier onlyValidPool() {
        if (!registry.isActivePool(msg.sender)) revert InvalidPool();
        _;
    }
    
    modifier onlyRegisteredPool() {
        if (!registry.isRegisteredPool(msg.sender)) revert InvalidPool();
        _;
    }
    
    modifier onlyFactory() {
        if (msg.sender != registry.factory()) revert OnlyFactory();
        _;
    }
    
    modifier onlyRole(bytes32 role) {
        if (!accessManager.hasRole(role, msg.sender)) revert Unauthorized();
        _;
    }
    
    modifier whenNotPaused {
        if (accessManager.paused()) revert ContractPaused();
        _;
    }
    
    // ==================== INITIALIZATION ====================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the manager with registry, access control, and treasury.
     * @param _registry PoolRegistry proxy
     * @param _accessManager AccessManager contract
     * @param _timelockController TimelockController for upgrades
     * @param _treasury Protocol treasury wallet
     */
    function initialize(
        address _registry,
        address _accessManager,
        address _timelockController,
        address _treasury
    ) public initializer {
        if (_registry == address(0)) revert InvalidAddress();
        if (_accessManager == address(0)) revert InvalidAddress();
        if (_timelockController == address(0)) revert InvalidAddress();
        if (_treasury == address(0)) revert InvalidAddress();
        
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        registry = IPoolRegistry(_registry);
        accessManager = AccessManager(_accessManager);
        timelockController = _timelockController;
        treasury = _treasury;
        version = 1;
    }

    function setAccessManager(address newAccessManager) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        if (newAccessManager == address(0)) revert InvalidAddress();
        address oldManager = address(accessManager);
        accessManager = AccessManager(newAccessManager);
        emit AccessManagerUpdated(oldManager, newAccessManager);
    }
    
    function _authorizeUpgrade(address newImplementation) internal override {
        if (msg.sender != timelockController) revert OnlyTimelock();
        if (newImplementation == address(0)) revert InvalidAddress();
        
        version += 1;
        emit ManagerUpgraded(address(this), newImplementation, version);
    }
    
    function setTimelockController(address newTimelockController) external override {
        if (msg.sender != timelockController) revert OnlyTimelock();
        if (newTimelockController == address(0)) revert InvalidAddress();
        
        address oldController = timelockController;
        timelockController = newTimelockController;
        emit TimelockControllerUpdated(oldController, newTimelockController);
    }

    // ==================== POOL INITIALIZATION ====================

    /**
     * @dev Set up pool configuration. Called by PoolFactory after proxy deployment.
     */
    function initializePool(
        address pool,
        IPoolTypes.PoolConfig memory poolConfig
    ) external override onlyFactory whenNotPaused {
        if (pools[pool].config.targetRaise != 0) revert AlreadyInitialized();
        if (!registry.isRegisteredPool(pool)) revert PoolNotRegistered();
        if (poolConfig.minimumFundingThreshold == 0 || poolConfig.minimumFundingThreshold > 10000) revert InvalidConfig();
        if (poolConfig.withdrawalFeeBps > MAX_WITHDRAWAL_FEE) revert FeeTooHigh();
        if (poolConfig.minInvestment == 0) revert InvalidConfig();
        
        // PoolFactory is the only caller and already enforces a non-zero targetRaise, a
        // non-zero epochDuration, and a maturity past the epoch. What it does not check is
        // everything below, each of which strands deposits: a discount rate at or above 100%
        // reverts face-value derivation at epoch close so the pool can never leave FUNDING;
        // a minimum above the target makes the pool undepositable; and mismatched coupon
        // arrays revert at investment confirmation. Funding-phase withdrawal closes at
        // epochEndTime, so in every case the money is already locked in by then.
        if (poolConfig.minInvestment > poolConfig.targetRaise) revert InvalidConfig();
        if (poolConfig.instrumentType == IPoolTypes.InstrumentType.DISCOUNTED) {
            if (poolConfig.discountRate == 0 || poolConfig.discountRate >= 10000) revert InvalidConfig();
        } else {
            if (poolConfig.couponDates.length != poolConfig.couponRates.length) revert InvalidConfig();
        }
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(pool);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.setPool(pool);
        pools[pool].config = poolConfig;
        pools[pool].status = IPoolTypes.PoolStatus.FUNDING;
        
        emit StatusChanged(IPoolTypes.PoolStatus(0), IPoolTypes.PoolStatus.FUNDING);
    }

    // ==================== DEPOSIT & WITHDRAWAL ====================

    /**
     * @dev Process a user deposit: deduct fee, transfer to escrow, mint shares.
     */
    function handleDeposit(address liquidityPool, uint256 assets, address receiver, address sender) external override onlyValidPool whenNotPaused nonReentrant returns (uint256 shares) {
        uint256 feeBps = poolDepositFeeBps[liquidityPool];
        if (feeBps == 0) feeBps = defaultDepositFeeBps;
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        (uint256 netAssets, uint256 depositFee) = escrowContract.processDeposit(receiver, assets, feeBps);
        
        if (depositFee > 0) {
            emit DepositFeeCollected(liquidityPool, sender, assets, depositFee);
        }
        
        return DepositWithdrawalLibrary.handleDeposit(pools, poolUsers, registry, liquidityPool, netAssets, receiver, sender);
    }

    function handleWithdraw(address liquidityPool, uint256 assets, address receiver, address owner, address sender) external override onlyRegisteredPool whenNotPaused nonReentrant returns (uint256 shares) {
        return DepositWithdrawalLibrary.handleWithdraw(pools, poolUsers, registry, liquidityPool, assets, receiver, owner, sender, treasury);
    }

    // ==================== LIFECYCLE ====================

    /**
     * @dev Mark a pool as fully funded. Transitions to FILLED status.
     */
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

    function withdrawFundsForInvestment(address liquidityPool, uint256 amount) external onlyRole(accessManager.SPV_ROLE()) whenNotPaused {
        PoolLifecycleLibrary.withdrawFundsForInvestment(pools, registry, liquidityPool, amount);
    }

    function processInvestment(address liquidityPool, uint256 actualAmount, string memory proofHash) external override onlyRole(accessManager.SPV_ROLE()) whenNotPaused {
        PoolLifecycleLibrary.processInvestment(pools, registry, liquidityPool, actualAmount, proofHash);
        
        investmentProofs[liquidityPool] = IPoolTypes.InvestmentProof({
            documentHash: proofHash,
            confirmedAt: block.timestamp,
            confirmedBy: msg.sender
        });
        
        _updateStatus(liquidityPool, IPoolTypes.PoolStatus.INVESTED);
        emit InvestmentProofRecorded(liquidityPool, proofHash, msg.sender);
    }
    
    function processMaturity(address liquidityPool, uint256 finalAmount) external override onlyRole(accessManager.SPV_ROLE()) whenNotPaused {
        PoolLifecycleLibrary.processMaturity(pools, registry, liquidityPool, finalAmount);
        _updateStatus(liquidityPool, IPoolTypes.PoolStatus.MATURED);
    }

    function markPoolWithdrawn(address pool) external onlyRole(accessManager.OPERATOR_ROLE()) { 
        PoolLifecycleLibrary.markPoolWithdrawn(pools, pool);
    }
    
    // ==================== COUPON PAYMENTS ====================

    /**
     * @dev SPV sends a coupon payment to the pool escrow. Validates against coupon schedule.
     */
    function processCouponPayment(address liquidityPool, uint256 amount) external override onlyRole(accessManager.SPV_ROLE()) whenNotPaused {
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        if (!_isValidCouponDate(poolData.config)) revert InvalidCouponDate();
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        if (IERC20(poolInfo.asset).balanceOf(msg.sender) < amount) revert InsufficientSpvBalance();
        
        IERC20(poolInfo.asset).safeTransferFrom(msg.sender, poolInfo.escrow, amount);
        
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.trackCouponPayment(amount);
        
        CalculationLibrary.processCouponPayment(poolData, poolUsers, registry, liquidityPool, amount);
        
        emit CouponReceived(amount, block.timestamp);
        emit CouponPaymentReceived(liquidityPool, amount);
    }

    function distributeCouponPayment(address liquidityPool) external onlyRole(accessManager.OPERATOR_ROLE()) whenNotPaused {
        if (!registry.isRegisteredPool(liquidityPool)) revert InvalidPool();
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

    function getUnclaimedCoupons(address liquidityPool) external view override  returns (uint256) {
        if (!registry.isRegisteredPool(liquidityPool)) revert InvalidPool();
        return CalculationLibrary.getUnclaimedCoupons(pools[liquidityPool]);
    }

    function getUndistributedCoupons(address liquidityPool) external view onlyRole(accessManager.OPERATOR_ROLE()) returns (uint256) {
        if (!registry.isRegisteredPool(liquidityPool)) revert InvalidPool();
        return CalculationLibrary.getUndistributedCoupons(pools[liquidityPool]);
    }

    function calculateUserReturn(address user) external view override onlyRegisteredPool returns (uint256) {
        if (user == address(0)) revert InvalidAddress();
        address poolAddress = msg.sender;
        IPoolTypes.PoolData storage poolData = pools[poolAddress];

        return CalculationLibrary.calculateUserReturn(
            poolData,
            user,
            poolAddress
        );
      
    }
    
    function calculateUserDiscount(address user) external view override onlyRegisteredPool returns (uint256) {
        if (user == address(0)) revert InvalidAddress();
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
        if (user == address(0)) revert InvalidAddress();
        address poolAddress = msg.sender;
        IPoolTypes.PoolData storage poolData = pools[poolAddress];
        
        if (poolData.status != IPoolTypes.PoolStatus.MATURED) revert NotMatured();
        if (block.timestamp < poolData.config.maturityDate) revert NotMatured();
        
        uint256 userShares = IERC20(poolAddress).balanceOf(user);
        if (userShares == 0) return 0;
        
        uint256 totalReturns = _calculateTotalReturns(poolAddress);
        uint256 totalShares = IERC20(poolAddress).totalSupply();
        
        return (userShares * totalReturns) / totalShares;
    }

    // ==================== INTERNAL HELPERS ====================
    
    function _calculateTotalReturns(address poolAddress) internal view returns (uint256) {
        if (poolAddress == address(0)) revert InvalidAddress();
        if (!registry.isRegisteredPool(poolAddress)) revert InvalidPool();

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
                return CalculationLibrary.calculateFaceValue(poolData.config.targetRaise, poolData.config.discountRate);
            }
        } else {
            uint256 principal = pools[poolAddress].actualInvested;
            if (principal == 0) {
                principal = poolData.config.targetRaise;
            }
            uint256 expectedCoupons = CalculationLibrary.calculateExpectedCoupons(
                poolData
            );
            
            return principal + expectedCoupons;
        }
    }

    // ==================== EMERGENCY ====================

    /**
     * @dev Pool self-reports an emergency, entering EMERGENCY status.
     *
     *      Only while the escrow is still whole. Emergency refunds pay one unit per share,
     *      which is exactly right when nothing has been invested and wrong the moment it
     *      has: against an escrow already drawn down by the SPV, the first holders out
     *      take par and the rest find nothing left. `fundsWithdrawnBySPV` is the precise
     *      test — it covers a pool sitting in PENDING_INVESTMENT that has not yet
     *      transferred, which a status check would refuse for no reason.
     *
     *      Handling a mid-deal SPV default needs refunds pro-rated against what the escrow
     *      actually holds, which is a different mechanism than this one.
     */
    function emergencyExit() external override onlyValidPool {
        address poolAddress = msg.sender;
        if (pools[poolAddress].fundsWithdrawnBySPV != 0) revert InvalidStatus();
        
        _updateStatus(poolAddress, IPoolTypes.PoolStatus.EMERGENCY);
        _emitEmergencyMetrics(poolAddress, "POOL_SELF_REPORT");
        
        emit EmergencyExit(poolAddress, block.timestamp);
    }
    
    function cancelPool(address poolAddress) external onlyRole(accessManager.EMERGENCY_ROLE()) {
        ValidationLibrary.validatePoolCancellation(pools[poolAddress], registry, poolAddress);
        
        _updateStatus(poolAddress, IPoolTypes.PoolStatus.EMERGENCY);
        _emitEmergencyMetrics(poolAddress, "ADMIN_CANCELLATION");
        
        emit PoolCancelled(poolAddress, msg.sender, block.timestamp);
    }

    function _emitEmergencyMetrics(address poolAddress, string memory trigger) internal {
        uint256 totalRefundable = pools[poolAddress].totalRaised;
        uint256 totalShares = IERC20(poolAddress).totalSupply();
        emit EmergencyStateChanged(poolAddress, trigger, totalRefundable, totalShares, block.timestamp);
    }

    // ==================== ADMIN CONFIG ====================

    function pausePool(address poolAddress) external override onlyRole(accessManager.OPERATOR_ROLE()) {
        if (!registry.isRegisteredPool(poolAddress)) revert InvalidPool();
        ILiquidityPool(poolAddress).pause();
        emit PoolPaused(poolAddress, block.timestamp);
    }
    
    function unpausePool(address poolAddress) external override onlyRole(accessManager.OPERATOR_ROLE()) {
        if (!registry.isRegisteredPool(poolAddress)) revert InvalidPool();
        ILiquidityPool(poolAddress).unpause();
        emit PoolUnpaused(poolAddress, block.timestamp);
    }

    function setTreasury(address newTreasury) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        if (newTreasury == address(0)) revert InvalidAddress();
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    function setFeeManager(address feeManager_) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        if (feeManager_ == address(0)) revert InvalidAddress();
        feeManager = feeManager_;
        emit FeeManagerUpdated(feeManager_);
    }

    function setDefaultDepositFee(uint256 feeBps) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        if (feeBps > MAX_DEPOSIT_FEE) revert FeeTooHigh();
        defaultDepositFeeBps = feeBps;
        emit DefaultDepositFeeUpdated(feeBps);
    }

    function setPoolDepositFee(
        address poolAddress,
        uint256 feeBps
    ) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        if (!registry.isRegisteredPool(poolAddress)) revert InvalidPool();
        if (feeBps > MAX_DEPOSIT_FEE) revert FeeTooHigh();
        poolDepositFeeBps[poolAddress] = feeBps;
        emit PoolDepositFeeUpdated(poolAddress, feeBps);
    }

    function getEffectiveDepositFee(address poolAddress) external view returns (uint256) {
        uint256 poolFee = poolDepositFeeBps[poolAddress];
        return poolFee > 0 ? poolFee : defaultDepositFeeBps;
    }

    function extendMaturity(
        address poolAddress,
        uint256 newMaturityDate
    ) external onlyRole(accessManager.MULTISIG_ADMIN_ROLE()) {
        if (!registry.isRegisteredPool(poolAddress)) revert InvalidPool();
        
        IPoolTypes.PoolData storage poolData = pools[poolAddress];
        if (poolData.status != IPoolTypes.PoolStatus.INVESTED) revert InvalidStatus();
        
        uint256 oldDate = poolData.config.maturityDate;
        if (newMaturityDate <= oldDate) revert InvalidExtension();
        if (newMaturityDate > oldDate + (MAX_EXTENSION_DAYS * 1 days)) revert InvalidExtension();
        
        poolData.config.maturityDate = newMaturityDate;
        
        emit MaturityExtended(poolAddress, oldDate, newMaturityDate, msg.sender);
    }

    function getInvestmentProof(address poolAddress) external view returns (IPoolTypes.InvestmentProof memory) {
        return investmentProofs[poolAddress];
    }

    function getPoolFeesCollected(address poolAddress) external view returns (uint256) {
        return pools[poolAddress].totalFeesCollected;
    }

    // ==================== VIEW ====================

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
