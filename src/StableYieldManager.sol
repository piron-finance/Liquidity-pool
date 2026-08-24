// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./AccessManager.sol";
import "./interfaces/IPoolRegistry.sol";
import "./escrows/StableYieldEscrow.sol"; 
import "./escrows/YieldReserveEscrow.sol";
import "./types/IStableYieldTypes.sol";
import "./libraries/StableYieldNAVLibrary.sol";
import "./libraries/StableYieldManagerLib.sol";

/**
 * @title StableYieldManager
 * @dev Manages flexible Stable Yield pools: deposit/withdrawal validation, NAV computation,
 *      instrument lifecycle (T-bills, bonds), SPV allocations, withdrawal queues,
 *      and protocol capital deployment from YieldReserveEscrow.
 */
contract StableYieldManager is 
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    // ==================== ERRORS ====================

    error Unauthorized();
    error PoolNotFound();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidMaturity();
    error InvalidFaceValue();
    error ExceedsUndeployedCapital();
    error InvalidCouponRate();
    error PoolNotActive();
    error OnlyFactory();
    error PoolAlreadyRegistered();
    error InvalidDecimals();
    error AssetNotApproved();
    error OnlyPool();
    error BelowMinimum();
    error InsufficientFunds();
    error InvalidInstrument();
    error InstrumentNotActive();
    error NotMaturedYet();
    error FeeTooHigh();
    error RatioTooHigh();
    error FactoryAlreadySet();
    error InsufficientLiquidity();
    error InvalidCouponFrequency();

    // ==================== STATE ====================

    using SafeERC20 for IERC20;

    AccessManager public accessManager;
    IPoolRegistry public registry;
    address public timelockController;
    address public managedPoolFactory;
    address public yieldReserve;

    uint256 public defaultMinAbsoluteReserve;
    uint256 public defaultReserveRatioBps;

    uint256 public version;
    
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_TRANSACTION_FEE = 500;
    uint256 public constant MAX_INSTRUMENTS_PER_POOL = 100;
    uint256 public constant MAX_ANNUAL_COUPON_RATE = 5000;
    uint8 public constant MAX_COUPON_FREQUENCY = 12;

    uint256 public defaultTransactionFeeBps; 
    
    mapping(address => uint256) public poolTransactionFeeBps; 
    mapping(address => IStableYieldTypes.PoolData) public pools;
    
    mapping(address => IStableYieldTypes.InstrumentHolding[]) public poolInstruments;
    mapping(address => uint256) public poolInstrumentCount;
    
    mapping(address => IStableYieldTypes.WithdrawalQueue) public poolQueues;
    mapping(address => mapping(uint256 => IStableYieldTypes.WithdrawalRequest)) public withdrawalRequests;
    mapping(address => mapping(address => uint256[])) public userWithdrawalRequests;
    
    /// @dev Capital drawn by an SPV and not yet placed into an instrument, keyed by SPV across all pools.
    mapping(address => uint256) public spvUndeployedCapital;
    /// @dev Capital drawn and not yet placed, keyed by pool and SPV.
    mapping(address => mapping(address => uint256)) public poolSpvUndeployedCapital;
    /// @dev Capital drawn and not yet placed, keyed by pool. Sum of poolSpvUndeployedCapital across SPVs.
    mapping(address => uint256) public poolUndeployedCapital;
    mapping(address => IStableYieldTypes.ReserveConfig) public poolReserveConfigs;

    // ==================== EVENTS ====================

    event PoolRegistered( address indexed poolAddress, address indexed escrowAddress, address indexed asset, string name );
    event TransactionFeeConfigUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event PoolTransactionFeeUpdated(address indexed pool, uint256 feeBps);
    event TransactionFeeCollected(address indexed poolAddress, string feeType, uint256 transactionAmount, uint256 feeAmount);
    
    event InstrumentPurchased( address indexed poolAddress, uint256 indexed instrumentId, IStableYieldTypes.InstrumentType instrumentType, uint256 purchasePrice, uint256 faceValue, uint256 maturityDate );
    event InstrumentMatured( address indexed poolAddress, uint256 indexed instrumentId, uint256 faceValue, uint256 realizedYield );  
    event CouponPaymentReceived( address indexed poolAddress, uint256 indexed instrumentId, uint256 couponAmount, uint256 couponNumber );
    event NAVCalculated( address indexed poolAddress, uint256 totalNAV, uint256 navPerShare, uint256 totalShares, uint256 timestamp); 
    event NAVUpdated( address indexed poolAddress, uint256 totalNAV, uint256 navPerShare, string reason, uint256 timestamp );   
    event InstrumentRemoved( address indexed poolAddress, uint256 indexed instrumentId, uint256 finalValue, string reason);
    event InstrumentWrittenOff(address indexed poolAddress, uint256 indexed instrumentId, uint256 writtenOffValue, string reason);
    
    event PoolDeactivated(address indexed poolAddress, uint256 timestamp);
    event DepositValidated( address indexed poolAddress, address indexed user, uint256 amount, uint256 shares );
    event WithdrawalValidated( address indexed poolAddress, address indexed user, uint256 shares, uint256 value, bool immediate  ); 
    event WithdrawalQueued( address indexed poolAddress, address indexed user, uint256 indexed requestId, uint256 shares, uint256 estimatedValue);
    event WithdrawalProcessed( address indexed poolAddress, address indexed user, uint256 indexed requestId, uint256 actualValue, uint256 penaltyDeducted ); 
    
    event CapitalAllocated(address indexed pool, address indexed spv, uint256 amount, uint256 undeployedAfter, uint256 timestamp);
    event CapitalDeployed(address indexed pool, address indexed spv, uint256 indexed instrumentId, uint256 amount, uint256 undeployedAfter);
    event CapitalReturned(address indexed pool, address indexed spv, uint256 amount, uint256 undeployedAfter, uint256 timestamp);
    event ReserveConfigUpdated(address indexed pool, uint256 minAbsoluteReserve, uint256 reserveRatioBps);
    event PoolReadyForAllocation(address indexed pool, uint256 availableAmount, uint256 timestamp);

    // ==================== MODIFIERS ====================

    modifier onlyRegisteredPool() {
        _checkRegisteredPool();
        _;
    }

    modifier poolExists(address poolAddress) {
        _checkPoolExists(poolAddress);
        _;
    }

    modifier ActivePool(address poolAddress) {
        _checkActivePool(poolAddress);
        _;
    }

    modifier onlyRole(bytes32 role) {
        _checkRole(role);
        _;
    }

    function _checkRegisteredPool() internal view {
        if (!registry.isManagedPool(msg.sender)) revert PoolNotFound();
    }

    function _checkPoolExists(address poolAddress) internal view {
        if (!registry.isManagedPool(poolAddress)) revert PoolNotFound();
    }

    function _checkActivePool(address poolAddress) internal view {
        if (!pools[poolAddress].isActive) revert PoolNotActive();
    }

    function _checkRole(bytes32 role) internal view {
        if (!accessManager.hasRole(role, msg.sender)) revert Unauthorized();
    }

    // ==================== INITIALIZATION ====================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize with access manager, registry, timelock, and default fee.
     * @param accessManager_ AccessManager contract
     * @param registry_ PoolRegistry proxy
     * @param timelockController_ TimelockController for upgrades
     * @param defaultFeeBps_ Default transaction fee in basis points
     */
    function initialize(
        address accessManager_,
        address registry_,
        address timelockController_,
        uint256 defaultFeeBps_
    ) public virtual initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        if (accessManager_ == address(0)) revert InvalidAddress();
        if (registry_ == address(0)) revert InvalidAddress();
        if (timelockController_ == address(0)) revert InvalidAddress();
        if (defaultFeeBps_ > MAX_TRANSACTION_FEE) revert FeeTooHigh();

        accessManager = AccessManager(accessManager_);
        registry = IPoolRegistry(registry_);
        timelockController = timelockController_;
        defaultTransactionFeeBps = defaultFeeBps_;
        version = 1;
        
        defaultMinAbsoluteReserve = 0;
        defaultReserveRatioBps = 1000;
    }

    function _authorizeUpgrade(address newImplementation) internal override {
        if (msg.sender != timelockController) revert Unauthorized();
        if (newImplementation == address(0)) revert InvalidAddress();
        version += 1;
    }

    // ==================== POOL REGISTRATION ====================

    /**
     * @dev Register a new Stable Yield pool. Only callable by ManagedPoolFactory.
     * @param poolAddress Pool proxy address
     * @param escrowAddress StableYieldEscrow proxy
     * @param asset Underlying stablecoin (6 or 18 decimals)
     * @param name Human-readable pool name
     * @param minInvestment Minimum deposit amount
     */
    function registerPool(
        address poolAddress,
        address escrowAddress,
        address asset,
        string memory name,
        uint256 minInvestment
    ) external nonReentrant {
        if (msg.sender != managedPoolFactory) revert OnlyFactory();
        if (poolAddress == address(0)) revert InvalidAddress();
        if (escrowAddress == address(0)) revert InvalidAddress();
        if (asset == address(0)) revert InvalidAddress();
        if (registry.isManagedPool(poolAddress)) revert PoolAlreadyRegistered();
        if (minInvestment == 0) revert InvalidAmount();
        
        uint8 assetDecimals = IERC20Metadata(asset).decimals();
        if (assetDecimals != 6 && assetDecimals != 18) revert InvalidDecimals();
        if (!registry.isApprovedAsset(asset)) revert AssetNotApproved();
        
        pools[poolAddress] = IStableYieldTypes.PoolData({
            poolAddress: poolAddress,
            escrowAddress: escrowAddress,
            asset: asset,
            name: name,
            minInvestment: minInvestment,
            isActive: true,
            createdAt: block.timestamp
        });
        
        poolQueues[poolAddress] = IStableYieldTypes.WithdrawalQueue({
            head: 0,
            tail: 0,
            totalPendingValue: 0
        });
        
        poolInstrumentCount[poolAddress] = 0;

        registry.registerStableYieldPool(pools[poolAddress]);
        
        emit PoolRegistered(poolAddress, escrowAddress, asset, name);
    }

    // ==================== DEPOSIT ====================

    /**
     * @dev Validate a deposit: enforce minimum, deduct transaction fee via escrow,
     *      compute shares based on NAV per share.
     */
    function validateDeposit(
        address poolAddress,
        uint256 amount,
        address receiver
    ) external onlyRegisteredPool poolExists(poolAddress) ActivePool(poolAddress) nonReentrant returns (uint256 shares) { 
        if (msg.sender != poolAddress) revert OnlyPool();
        if (!registry.isManagedPool(poolAddress)) revert PoolNotFound();
        
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        if (amount < poolData.minInvestment) revert BelowMinimum();
        if (receiver == address(0)) revert InvalidAddress();
        
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        uint256 feeBps = getPoolTransactionFee(poolAddress);
        (uint256 netDepositAmount, uint256 transactionFee) = escrow.processDeposit(amount, feeBps);
        
        uint256 navPerShare = calculateNAVPerShare(poolAddress);
        shares = (netDepositAmount * 1e18) / navPerShare;
        
        if (transactionFee > 0) {
            emit TransactionFeeCollected(poolAddress, "deposit", amount, transactionFee);
        }
        
        emit DepositValidated(poolAddress, receiver, amount, shares);
        
        return shares;
    }

    // ==================== WITHDRAWAL ====================

    /**
     * @dev Validate a withdrawal: compute value from NAV, deduct fee.
     *      If pool has sufficient reserves, process immediately; otherwise queue.
     */
    function validateWithdrawal(
        address poolAddress,
        uint256 shares,
        address receiver,
        address owner
    ) external poolExists(poolAddress) ActivePool(poolAddress) nonReentrant returns (uint256 actualShares, uint256 withdrawalValue, bool immediate) {
        if (msg.sender != poolAddress) revert OnlyPool();
        if (!registry.isManagedPool(poolAddress)) revert PoolNotFound();
        if (shares == 0) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidAddress();
        if (owner == address(0)) revert InvalidAddress();
        
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        if (!poolData.isActive) revert PoolNotActive();
        
        uint256 navPerShare = calculateNAVPerShare(poolAddress);
        uint256 grossWithdrawalValue = (shares * navPerShare) / 1e18;
        
        uint256 transactionFee = calculateTransactionFee(poolAddress, grossWithdrawalValue);
        withdrawalValue = grossWithdrawalValue - transactionFee;
        
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        
        if (escrow.getPoolReserves() >= grossWithdrawalValue) {
            if (transactionFee > 0) {
                escrow.collectWithdrawalFee(transactionFee);
                emit TransactionFeeCollected(poolAddress, "withdrawal", grossWithdrawalValue, transactionFee);
            }
            
            emit WithdrawalValidated(poolAddress, owner, shares, withdrawalValue, true);
            return (shares, withdrawalValue, true);
        } else {
            _queueWithdrawal(poolAddress, owner, shares, withdrawalValue, transactionFee);
            
            emit WithdrawalValidated(poolAddress, owner, shares, withdrawalValue, false);
            return (shares, withdrawalValue, false);
        }
    }

    function _queueWithdrawal(
        address poolAddress,
        address user,
        uint256 shares,
        uint256 estimatedValue,
        uint256 feeAmount
    ) internal {
        IStableYieldTypes.WithdrawalQueue storage queue = poolQueues[poolAddress];
        
        uint256 requestId = queue.tail++;
        withdrawalRequests[poolAddress][requestId] = IStableYieldTypes.WithdrawalRequest({
            user: user,
            shares: shares,
            requestTime: block.timestamp,
            deadline: block.timestamp + 2 days,
            estimatedValue: estimatedValue,
            feeAmount: feeAmount,
            processed: false,
            processedTime: 0
        });
        
        userWithdrawalRequests[poolAddress][user].push(requestId);
        queue.totalPendingValue += estimatedValue;
        
        emit WithdrawalQueued(poolAddress, user, requestId, shares, estimatedValue);
    }

    // ==================== WITHDRAWAL QUEUE ====================

    /**
     * @dev Process queued withdrawals in FIFO order, up to maxRequests.
     */
    function processWithdrawalQueue(address poolAddress, uint256 maxRequests) 
        external 
        onlyRole(accessManager.OPERATOR_ROLE()) 
        ActivePool(poolAddress) 
        nonReentrant 
        returns (uint256 processed) 
    {
        return StableYieldManagerLib.processQueue(
            poolQueues, withdrawalRequests, pools,
            yieldReserve, poolAddress, maxRequests, type(uint256).max
        );
    }

    /**
     * @dev Settle specific withdrawal requests by ID. Sources from yield reserve if needed.
     */
    function settleWithdrawals(address poolAddress, uint256[] calldata requestIds) 
        external 
        onlyRole(accessManager.OPERATOR_ROLE()) 
        ActivePool(poolAddress) 
        nonReentrant 
        returns (uint256 processed) 
    {
        return StableYieldManagerLib.settleWithdrawals(
            poolQueues, withdrawalRequests, pools,
            yieldReserve, poolAddress, requestIds
        );
    }

    // ==================== NAV ====================

    /**
     * @dev Calculate total pool NAV = base NAV from instruments + pending allocation value.
     */
    function calculatePoolNAV(address poolAddress) public view poolExists(poolAddress) returns (uint256 totalNAV) {
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        uint256 baseNAV = StableYieldNAVLibrary.calculatePoolNAV(
            poolData,
            poolInstruments[poolAddress]
        );
        return baseNAV + poolUndeployedCapital[poolAddress];
    }

    function calculateNAVPerShare(address poolAddress) public view ActivePool(poolAddress) returns (uint256 navPerShare) {
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        uint256 totalNAV = calculatePoolNAV(poolAddress);
        uint256 totalShares = IERC20(poolData.poolAddress).totalSupply();

        if (totalShares == 0) {
            return 1e18;
        }

        return (totalNAV * 1e18) / totalShares;
    }

    // ==================== SPV ALLOCATION ====================

    /**
     * @dev Draw capital from pool reserves for an SPV to invest. The cash leaves escrow
     *      immediately and is tracked as undeployed capital until it is placed into an
     *      instrument or returned. Undeployed capital remains part of pool NAV throughout,
     *      so a pool holding cash at the SPV is valued identically to one holding it in escrow.
     *
     *      There is no deadline. The SPV places capital on its own schedule, and holding
     *      cash while waiting for an instrument worth buying is expected behaviour.
     */
    function allocateCapital(
        address poolAddress,
        address spvAddress,
        uint256 amount
    ) external onlyRole(accessManager.OPERATOR_ROLE()) poolExists(poolAddress) nonReentrant {
        if (spvAddress == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        (bool ready, uint256 available) = isReadyForAllocation(poolAddress);
        if (!ready || available < amount) revert InsufficientFunds();

        spvUndeployedCapital[spvAddress] += amount;
        poolSpvUndeployedCapital[poolAddress][spvAddress] += amount;
        poolUndeployedCapital[poolAddress] += amount;

        StableYieldEscrow(pools[poolAddress].escrowAddress).allocateToSPV(spvAddress, amount);

        emit CapitalAllocated(
            poolAddress,
            spvAddress,
            amount,
            poolSpvUndeployedCapital[poolAddress][spvAddress],
            block.timestamp
        );

        _triggerNAVUpdate(poolAddress, "capital_allocated");
    }

    // ==================== INSTRUMENT LIFECYCLE ====================

    /**
     * @dev SPV places undeployed capital into an instrument. The purchase price is debited
     *      from the SPV's undeployed balance for this pool; pool NAV is unchanged by the
     *      placement itself, since the capital simply moves from cash to a marked holding.
     */
    function addInstrument(
        address poolAddress,
        IStableYieldTypes.InstrumentType instrumentType,
        uint256 purchasePrice,
        uint256 faceValue,
        uint256 maturityDate,
        uint256 annualCouponRate,
        uint8 couponFrequency
    ) external onlyRole(accessManager.SPV_ROLE()) poolExists(poolAddress) nonReentrant {
        if (poolInstrumentCount[poolAddress] >= MAX_INSTRUMENTS_PER_POOL) revert InvalidInstrument();
        if (purchasePrice == 0) revert InvalidAmount();
        if (purchasePrice > poolSpvUndeployedCapital[poolAddress][msg.sender]) revert ExceedsUndeployedCapital();

        if (maturityDate <= block.timestamp) revert InvalidMaturity();
        if (faceValue < purchasePrice) revert InvalidFaceValue();
        if (instrumentType == IStableYieldTypes.InstrumentType.INTEREST_BEARING) {
            if (couponFrequency == 0 || couponFrequency > MAX_COUPON_FREQUENCY) revert InvalidCouponFrequency();
            if (annualCouponRate == 0 || annualCouponRate > MAX_ANNUAL_COUPON_RATE) revert InvalidCouponRate();
        }
        
        uint256 instrumentId = poolInstrumentCount[poolAddress];
        
        poolInstruments[poolAddress].push(IStableYieldTypes.InstrumentHolding({
            instrumentType: instrumentType,
            purchasePrice: purchasePrice,
            faceValue: faceValue,
            purchaseDate: block.timestamp,
            maturityDate: maturityDate,
            annualCouponRate: annualCouponRate,
            couponFrequency: couponFrequency,
            nextCouponDueDate: couponFrequency > 0 ? block.timestamp + (365 days / couponFrequency) : 0,
            couponsPaid: 0,
            isActive: true,
            spv: msg.sender
        }));

        spvUndeployedCapital[msg.sender] -= purchasePrice;
        poolSpvUndeployedCapital[poolAddress][msg.sender] -= purchasePrice;
        poolUndeployedCapital[poolAddress] -= purchasePrice;

        poolInstrumentCount[poolAddress]++;

        emit InstrumentPurchased(poolAddress, instrumentId, instrumentType, purchasePrice, faceValue, maturityDate);
        emit CapitalDeployed(
            poolAddress,
            msg.sender,
            instrumentId,
            purchasePrice,
            poolSpvUndeployedCapital[poolAddress][msg.sender]
        );

        _triggerNAVUpdate(poolAddress, "instrument_added");
    }

    /**
     * @dev SPV returns maturity proceeds to escrow and the instrument is retired.
     *      Capital moves from a marked holding back into pool reserves; undeployed
     *      capital is untouched, because none of it was involved in this instrument.
     */
    function matureInstrumentWithFunds(
        address poolAddress,
        uint256 instrumentId,
        uint256 maturityAmount
    ) external onlyRole(accessManager.SPV_ROLE()) poolExists(poolAddress) nonReentrant {
        if (instrumentId >= poolInstruments[poolAddress].length) revert InvalidInstrument();
        
        IStableYieldTypes.InstrumentHolding storage instrument = poolInstruments[poolAddress][instrumentId];
        if (!instrument.isActive) revert InstrumentNotActive();
        if (block.timestamp < instrument.maturityDate) revert NotMaturedYet();
        if (maturityAmount == 0) revert InvalidAmount();
        
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        
        IERC20 asset = IERC20(poolData.asset);
        asset.safeTransferFrom(msg.sender, address(escrow), maturityAmount);
        escrow.recordReceivedLiquidity(maturityAmount);
        
        uint256 realizedYield = maturityAmount > instrument.purchasePrice ? maturityAmount - instrument.purchasePrice : 0;
        
        emit InstrumentMatured(poolAddress, instrumentId, instrument.faceValue, realizedYield);
        
        _removeInstrument(poolAddress, instrumentId, "matured");
        
        _triggerNAVUpdate(poolAddress, "instrument_matured");
    }

    /**
     * @dev SPV returns undeployed capital to pool reserves. Always available, in any
     *      amount up to the SPV's undeployed balance for the pool.
     */
    function returnCapital(
        address poolAddress,
        uint256 returnAmount
    ) external onlyRole(accessManager.SPV_ROLE()) poolExists(poolAddress) nonReentrant {
        if (returnAmount == 0) revert InvalidAmount();
        if (returnAmount > poolSpvUndeployedCapital[poolAddress][msg.sender]) revert ExceedsUndeployedCapital();

        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);

        IERC20(poolData.asset).safeTransferFrom(msg.sender, address(escrow), returnAmount);
        escrow.recordReceivedLiquidity(returnAmount);

        spvUndeployedCapital[msg.sender] -= returnAmount;
        poolSpvUndeployedCapital[poolAddress][msg.sender] -= returnAmount;
        poolUndeployedCapital[poolAddress] -= returnAmount;

        emit CapitalReturned(
            poolAddress,
            msg.sender,
            returnAmount,
            poolSpvUndeployedCapital[poolAddress][msg.sender],
            block.timestamp
        );

        _triggerNAVUpdate(poolAddress, "capital_returned");
    }

    // ==================== COUPON PAYMENTS ====================

    /**
     * @dev SPV pays a coupon for an interest-bearing instrument. Validates due date
     *      and advances the next coupon schedule.
     */
    function recordCouponPayment(
        address poolAddress,
        uint256 instrumentId,
        uint256 couponAmount
    ) external onlyRole(accessManager.SPV_ROLE()) poolExists(poolAddress) nonReentrant {
        if (couponAmount == 0) revert InvalidAmount();

        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        IStableYieldTypes.InstrumentHolding[] storage instruments = poolInstruments[poolAddress];
        
        if (instrumentId >= instruments.length) revert InvalidInstrument();
        
        IStableYieldTypes.InstrumentHolding storage instrument = instruments[instrumentId];
        if (!instrument.isActive) revert InstrumentNotActive();
        if (instrument.instrumentType != IStableYieldTypes.InstrumentType.INTEREST_BEARING) revert InvalidInstrument();
        if (block.timestamp < instrument.nextCouponDueDate) revert NotMaturedYet();

        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        IERC20 asset = IERC20(poolData.asset);
        asset.safeTransferFrom(msg.sender, address(escrow), couponAmount);
        escrow.recordReceivedLiquidity(couponAmount);

        instrument.couponsPaid++;
        
        if (block.timestamp < instrument.maturityDate) {
            uint256 couponPeriodSeconds = (365 days) / instrument.couponFrequency;
            instrument.nextCouponDueDate += couponPeriodSeconds;
        }
        
        emit CouponPaymentReceived(
            poolData.poolAddress,
            instrumentId,
            couponAmount,
            instrument.couponsPaid
        );
        
        _triggerNAVUpdate(poolAddress, "coupon_received");
    }

    function triggerNAVUpdate(address poolAddress, string memory reason) 
        external 
        onlyRole(accessManager.SPV_ROLE()) 
        poolExists(poolAddress) 
    {
        _triggerNAVUpdate(poolAddress, reason);
    }
    
    function _triggerNAVUpdate(address poolAddress, string memory reason) internal {
        uint256 totalNAV = calculatePoolNAV(poolAddress);
        uint256 totalShares = IERC20(pools[poolAddress].poolAddress).totalSupply();
        uint256 navPerShare = totalShares == 0 ? 1e18 : (totalNAV * 1e18) / totalShares;
        
        emit NAVUpdated(poolAddress, totalNAV, navPerShare, reason, block.timestamp);
        emit NAVCalculated(poolAddress, totalNAV, navPerShare, totalShares, block.timestamp);
    }

    function _removeInstrument(address poolAddress, uint256 instrumentId, string memory reason) internal {
        IStableYieldTypes.InstrumentHolding[] storage instruments = poolInstruments[poolAddress];
        if (instrumentId >= instruments.length) revert InvalidInstrument();
        
        uint256 finalValue = instruments[instrumentId].faceValue;
        
        if (instrumentId != instruments.length - 1) {
            instruments[instrumentId] = instruments[instruments.length - 1];
        }
        instruments.pop();
        
        poolInstrumentCount[poolAddress]--;
        
        emit InstrumentRemoved(poolAddress, instrumentId, finalValue, reason);
    }

    /**
     * @dev Write an instrument off the book. Its marked value leaves NAV immediately.
     *
     *      Needed when an instrument defaults or is otherwise not going to settle: a holding
     *      that is never matured keeps carrying value, and holders would redeem against a NAV
     *      that includes an asset the pool will not receive. Any amount later recovered comes
     *      back through returnCapital.
     */
    function writeOffInstrument(
        address poolAddress,
        uint256 instrumentId,
        string calldata reason
    ) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) poolExists(poolAddress) nonReentrant {
        IStableYieldTypes.InstrumentHolding[] storage instruments = poolInstruments[poolAddress];
        if (instrumentId >= instruments.length) revert InvalidInstrument();
        if (!instruments[instrumentId].isActive) revert InstrumentNotActive();
        
        uint256 writtenOffValue = instruments[instrumentId].instrumentType == IStableYieldTypes.InstrumentType.DISCOUNTED
            ? StableYieldNAVLibrary.calculateDiscountedValue(instruments[instrumentId], block.timestamp)
            : StableYieldNAVLibrary.calculateInterestBearingValue(instruments[instrumentId], block.timestamp);
        
        emit InstrumentWrittenOff(poolAddress, instrumentId, writtenOffValue, reason);
        
        _removeInstrument(poolAddress, instrumentId, "written_off");
        
        _triggerNAVUpdate(poolAddress, "instrument_written_off");
    }

    // ==================== ADMIN CONFIG ====================

    /**
     * @dev Deactivate a pool, preventing new deposits and allocations.
     */
    function deactivatePool(address poolAddress) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) poolExists(poolAddress) {
        pools[poolAddress].isActive = false;
        emit PoolDeactivated(poolAddress, block.timestamp);
    }

    function setManagedPoolFactory(address _factory) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        if (_factory == address(0)) revert InvalidAddress();
        if (managedPoolFactory != address(0)) revert FactoryAlreadySet();
        managedPoolFactory = _factory;
    }

    function setDefaultTransactionFee(uint256 feeBps) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        if (feeBps > MAX_TRANSACTION_FEE) revert FeeTooHigh();
        
        uint256 oldFee = defaultTransactionFeeBps;
        defaultTransactionFeeBps = feeBps;
        
        emit TransactionFeeConfigUpdated(oldFee, feeBps);
    }

    function setPoolTransactionFee(address poolAddress, uint256 feeBps) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) poolExists(poolAddress) {
        if (feeBps > MAX_TRANSACTION_FEE) revert FeeTooHigh();
        
        poolTransactionFeeBps[poolAddress] = feeBps;
        
        emit PoolTransactionFeeUpdated(poolAddress, feeBps);
    }

    function setDefaultReserveConfig(
        uint256 minAbsoluteReserve,
        uint256 reserveRatioBps
    ) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        if (reserveRatioBps > 5000) revert RatioTooHigh();
        
        defaultMinAbsoluteReserve = minAbsoluteReserve;
        defaultReserveRatioBps = reserveRatioBps;
    }

    function setPoolReserveConfig(
        address poolAddress,
        uint256 minAbsoluteReserve,
        uint256 reserveRatioBps
    ) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) poolExists(poolAddress) {
        if (reserveRatioBps > 5000) revert RatioTooHigh();
        
        poolReserveConfigs[poolAddress] = IStableYieldTypes.ReserveConfig({
            minAbsoluteReserve: minAbsoluteReserve,
            reserveRatioBps: reserveRatioBps
        });
        
        emit ReserveConfigUpdated(poolAddress, minAbsoluteReserve, reserveRatioBps);
    }

    function setYieldReserve(address yieldReserve_) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        if (yieldReserve_ == address(0)) revert InvalidAddress();
        yieldReserve = yieldReserve_;
        emit YieldReserveUpdated(yieldReserve_);
    }

    // ==================== PROTOCOL CAPITAL ====================

    /**
     * @dev Deploy protocol capital from YieldReserveEscrow into a pool for liquidity.
     */
    function deployProtocolCapital(
        address poolAddress,
        uint256 amount
    ) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) poolExists(poolAddress) nonReentrant {
        if (yieldReserve == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        
        YieldReserveEscrow(yieldReserve).deployToPool(poolAddress, address(escrow), amount);
        escrow.recordProtocolFundsFromReserve(amount);
        
        emit ProtocolCapitalDeployed(poolAddress, amount);
    }

    /**
     * @dev Recall protocol capital from a pool back to YieldReserveEscrow.
     */
    function recallProtocolCapital(
        address poolAddress,
        uint256 amount
    ) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) poolExists(poolAddress) nonReentrant {
        if (yieldReserve == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        escrow.returnProtocolFundsToReserve(amount);
        
        emit ProtocolCapitalRecalled(poolAddress, amount);
    }

    function getAvailableProtocolCapital(address poolAddress) external view poolExists(poolAddress) returns (uint256) {
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        return escrow.protocolFundsFromReserve();
    }

    function getPoolProtocolFunds(address poolAddress) external view poolExists(poolAddress) returns (
        uint256 fromReserve,
        uint256 directDeposit
    ) {
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        return (escrow.protocolFundsFromReserve(), escrow.protocolFundsDirectDeposit());
    }

    event YieldReserveUpdated(address indexed yieldReserve);
    event ProtocolCapitalDeployed(address indexed pool, uint256 amount);
    event ProtocolCapitalRecalled(address indexed pool, uint256 amount);

    // ==================== ALLOCATION READINESS ====================

    /**
     * @dev Check if a pool has surplus reserves available for SPV allocation,
     *      after accounting for pending withdrawals, fees, and reserve requirements.
     */
    function isReadyForAllocation(address poolAddress) public view poolExists(poolAddress) returns (bool ready, uint256 availableAmount) {
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        
        uint256 currentReserves = escrow.getPoolReserves();
        uint256 totalNAV = calculatePoolNAV(poolAddress);
        
        uint256 pendingWithdrawals = poolQueues[poolAddress].totalPendingValue;
        uint256 pendingFees = _calculatePendingFees(poolAddress);
        uint256 effectiveReserves = currentReserves > (pendingWithdrawals + pendingFees) 
            ? currentReserves - pendingWithdrawals - pendingFees 
            : 0;
        
        IStableYieldTypes.ReserveConfig storage config = poolReserveConfigs[poolAddress];
        uint256 minReserve = config.minAbsoluteReserve;
        uint256 ratioBps = config.reserveRatioBps;
        
        if (minReserve == 0 && ratioBps == 0) {
            minReserve = defaultMinAbsoluteReserve;
            ratioBps = defaultReserveRatioBps;
        }
        
        uint256 ratioBasedReserve = (totalNAV * ratioBps) / 10000;
        uint256 requiredReserve = minReserve > ratioBasedReserve ? minReserve : ratioBasedReserve;
        
        if (effectiveReserves > requiredReserve) {
            availableAmount = effectiveReserves - requiredReserve;
            ready = true;
        } else {
            availableAmount = 0;
            ready = false;
        }
        
        return (ready, availableAmount);
    }
    
    function _calculatePendingFees(address poolAddress) internal view returns (uint256 totalFees) {
        IStableYieldTypes.WithdrawalQueue storage queue = poolQueues[poolAddress];
        for (uint256 i = queue.head; i < queue.tail; i++) {
            IStableYieldTypes.WithdrawalRequest storage req = withdrawalRequests[poolAddress][i];
            if (!req.processed) {
                totalFees += req.feeAmount;
            }
        }
    }

    // ==================== VIEW ====================

    function getPoolTransactionFee(address poolAddress) public view returns (uint256 feeBps) {
        feeBps = poolTransactionFeeBps[poolAddress];
        if (feeBps == 0) {
            feeBps = defaultTransactionFeeBps;
        }
        return feeBps;
    }

    function calculateTransactionFee(address poolAddress, uint256 amount) public view returns (uint256 fee) {
        if (amount == 0) return 0;
        uint256 feeBps = getPoolTransactionFee(poolAddress);
        return (amount * feeBps) / BASIS_POINTS;
    }

    function getPoolData(address poolAddress) external view poolExists(poolAddress) returns (IStableYieldTypes.PoolData memory) {
        return pools[poolAddress];
    }

    function getWithdrawalQueueStatus(address poolAddress) 
        external 
        view 
        poolExists(poolAddress) 
        returns (uint256 head, uint256 tail, uint256 pending, uint256 totalPendingValue) 
    {
        IStableYieldTypes.WithdrawalQueue storage queue = poolQueues[poolAddress];
        return (queue.head, queue.tail, queue.tail - queue.head, queue.totalPendingValue);
    }

    function getQueueProcessingInfo(address poolAddress) 
        external 
        view 
        poolExists(poolAddress) 
        returns (
            uint256 pendingCount,
            uint256 totalPendingValue,
            uint256 nextDeadline,
            uint256 availableLiquidity,
            uint256 canProcessNow
        ) 
    {
        IStableYieldTypes.WithdrawalQueue storage queue = poolQueues[poolAddress];
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        
        pendingCount = queue.tail - queue.head;
        totalPendingValue = queue.totalPendingValue;
        availableLiquidity = escrow.getPoolReserves();
        
        uint256 remaining = availableLiquidity;
        for (uint256 i = queue.head; i < queue.tail; i++) {
            IStableYieldTypes.WithdrawalRequest storage req = withdrawalRequests[poolAddress][i];
            if (req.processed) continue;
            
            if (nextDeadline == 0 || req.deadline < nextDeadline) {
                nextDeadline = req.deadline;
            }
            
            if (remaining >= req.estimatedValue) {
                canProcessNow += req.estimatedValue;
                remaining -= req.estimatedValue;
            }
        }
    }

    function getWithdrawalRequest(address poolAddress, uint256 requestId) 
        external 
        view 
        returns (IStableYieldTypes.WithdrawalRequest memory) 
    {
        return withdrawalRequests[poolAddress][requestId];
    }

    function getUserWithdrawalRequests(address poolAddress, address user) 
        external 
        view 
        returns (uint256[] memory) 
    {
        return userWithdrawalRequests[poolAddress][user];
    }

    function getPoolInstruments(address poolAddress) external view poolExists(poolAddress) returns (IStableYieldTypes.InstrumentHolding[] memory) {
        return poolInstruments[poolAddress];
    }

    function getInstrument(address poolAddress, uint256 instrumentId) external view returns (IStableYieldTypes.InstrumentHolding memory) {
        if (instrumentId >= poolInstruments[poolAddress].length) revert InvalidInstrument();
        return poolInstruments[poolAddress][instrumentId];
    }

    function calculateShares(address poolAddress, uint256 amount) 
        external 
        view
        poolExists(poolAddress) 
        returns (uint256) 
    {
        uint256 navPerShare = calculateNAVPerShare(poolAddress);
        return (amount * 1e18) / navPerShare;
    }

    function calculateAssetValue(address poolAddress, uint256 shares) 
        external 
        view
        poolExists(poolAddress) 
        returns (uint256) 
    {
        uint256 navPerShare = calculateNAVPerShare(poolAddress);
        return (shares * navPerShare) / 1e18;
    }

    /**
     * @dev Where a pool's capital currently sits. The three figures sum to pool NAV:
     *      `deployed` is marked instrument value, `reserves` is cash in escrow, and
     *      `undeployed` is cash drawn by SPVs and not yet placed.
     */
    function getPoolCapital(address poolAddress)
        external
        view
        poolExists(poolAddress)
        returns (uint256 deployed, uint256 reserves, uint256 undeployed)
    {
        deployed = StableYieldNAVLibrary.calculateGrossAssetValue(poolInstruments[poolAddress]);
        reserves = StableYieldEscrow(pools[poolAddress].escrowAddress).getPoolReserves();
        undeployed = poolUndeployedCapital[poolAddress];
    }

    function getUndeployedCapital(address poolAddress, address spvAddress) external view returns (uint256) {
        return poolSpvUndeployedCapital[poolAddress][spvAddress];
    }

    function getPoolReserveConfig(address poolAddress) external view returns (IStableYieldTypes.ReserveConfig memory) {
        IStableYieldTypes.ReserveConfig storage config = poolReserveConfigs[poolAddress];
        
        if (config.minAbsoluteReserve == 0 && config.reserveRatioBps == 0) {
            return IStableYieldTypes.ReserveConfig({
                minAbsoluteReserve: defaultMinAbsoluteReserve,
                reserveRatioBps: defaultReserveRatioBps
            });
        }
        
        return config;
    }

    function checkAndEmitPoolReadiness(address poolAddress) external poolExists(poolAddress) {
        (bool ready, uint256 available) = isReadyForAllocation(poolAddress);
        
        if (ready && available > 0) {
            emit PoolReadyForAllocation(poolAddress, available, block.timestamp);
        }
    }
}
