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
    error AllocationNotFound();
    error AllocationExpired();
    error AllocationNotPending();
    error AllocationMismatch();
    error ExceedsAllocation();
    error NotAllocationSPV();
    error InvalidStatus();
    error OnlyFactory();
    error PoolAlreadyRegistered();
    error InvalidDecimals();
    error AssetNotApproved();
    error OnlyPool();
    error BelowMinimum();
    error MaxAllocations();
    error InsufficientFunds();
    error AllocationExists();
    error InvalidInstrument();
    error InstrumentNotActive();
    error NotMaturedYet();
    error FeeTooHigh();
    error RatioTooHigh();
    error FactoryAlreadySet();
    error InsufficientLiquidity();
    error InvalidCouponFrequency();
    error InvalidCouponRate();

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
    uint256 public constant MAX_PENDING_ALLOCATIONS = 50;

    uint256 public defaultTransactionFeeBps; 

    uint256 public constant ALLOCATION_EXPIRY = 10 days;
    
    mapping(address => uint256) public poolTransactionFeeBps; 
    mapping(address => IStableYieldTypes.PoolData) public pools;
    
    mapping(address => IStableYieldTypes.InstrumentHolding[]) public poolInstruments;
    mapping(address => uint256) public poolInstrumentCount;
    
    mapping(address => IStableYieldTypes.WithdrawalQueue) public poolQueues;
    mapping(address => mapping(uint256 => IStableYieldTypes.WithdrawalRequest)) public withdrawalRequests;
    mapping(address => mapping(address => uint256[])) public userWithdrawalRequests;
    
    mapping(address => uint256) public totalSPVAllocations;
    mapping(address => mapping(address => uint256)) public poolToSPVAllocations;
    mapping(bytes32 => IStableYieldTypes.PendingAllocation) public pendingAllocations;
    mapping(address => bytes32[]) public poolPendingAllocationIds;
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
    
    event PoolDeactivated(address indexed poolAddress, uint256 timestamp);
    event DepositValidated( address indexed poolAddress, address indexed user, uint256 amount, uint256 shares );
    event InstrumentWrittenOff(address indexed poolAddress, uint256 indexed instrumentId, uint256 purchasePrice);
    event WithdrawalValidated( address indexed poolAddress, address indexed user, uint256 shares, uint256 value, bool immediate  ); 
    event WithdrawalQueued( address indexed poolAddress, address indexed user, uint256 indexed requestId, uint256 shares, uint256 estimatedValue);
    event WithdrawalProcessed( address indexed poolAddress, address indexed user, uint256 indexed requestId, uint256 actualValue, uint256 penaltyDeducted ); 
    
    event AllocationCreated(address indexed pool, address indexed spv, bytes32 indexed allocationId, uint256 amount, uint256 timestamp);
    event AllocationInvested(address indexed pool, bytes32 indexed allocationId, uint256 instrumentId, uint256 timestamp);
    event AllocationReturned(address indexed pool, bytes32 indexed allocationId, uint256 returnedAmount, uint256 timestamp);
    event AllocationMatured(address indexed pool, uint256 indexed instrumentId, bytes32 allocationId, uint256 maturedAmount, uint256 timestamp);
    event AllocationCancelled(address indexed pool, bytes32 indexed allocationId, uint256 amount, uint256 timestamp);
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
        if (!pools[poolAddress].isActive) revert InvalidStatus();
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
        if (!poolData.isActive) revert InvalidStatus();
        
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
        return _processQueue(poolAddress, maxRequests, type(uint256).max);
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
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        
        uint256 totalNeeded = 0;
        for (uint256 i = 0; i < requestIds.length; i++) {
            IStableYieldTypes.WithdrawalRequest storage request = withdrawalRequests[poolAddress][requestIds[i]];
            if (!request.processed) {
                totalNeeded += request.estimatedValue + request.feeAmount;
            }
        }
        
        uint256 available = escrow.getPoolReserves();
        if (available < totalNeeded) {
            uint256 shortfall = totalNeeded - available;
            uint256 deployed = _trySourceFromYieldReserve(poolAddress, shortfall);
            available += deployed;
            if (available < totalNeeded) revert InsufficientLiquidity();
        }
        
        for (uint256 i = 0; i < requestIds.length; i++) {
            IStableYieldTypes.WithdrawalRequest storage request = withdrawalRequests[poolAddress][requestIds[i]];
            if (!request.processed) {
                _processQueuedWithdrawal(poolAddress, requestIds[i]);
                processed++;
            }
        }
        
        return processed;
    }

    function _processQueue(
        address poolAddress, 
        uint256 maxRequests, 
        uint256 maxValue
    ) internal returns (uint256 processed) {
        IStableYieldTypes.WithdrawalQueue storage queue = poolQueues[poolAddress];
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        
        uint256 requestsProcessed = 0;
        uint256 valueProcessed = 0;
        uint256 currentHead = queue.head;
        
        while (requestsProcessed < maxRequests && 
               valueProcessed < maxValue && 
               currentHead < queue.tail) {
            
            IStableYieldTypes.WithdrawalRequest storage request = withdrawalRequests[poolAddress][currentHead];
            
            if (request.processed) {
                currentHead++;
                continue;
            }
            
            uint256 netValue = request.estimatedValue;
            uint256 totalRequired = netValue + request.feeAmount;
            
            if (valueProcessed + netValue > maxValue) {
                break;
            }
            
            uint256 available = escrow.getPoolReserves();
            
            if (available < totalRequired) {
                uint256 shortfall = totalRequired - available;
                uint256 deployed = _trySourceFromYieldReserve(poolAddress, shortfall);
                available += deployed;
                
                if (available < totalRequired) {
                    break;
                }
            }
            
            _processQueuedWithdrawal(poolAddress, currentHead);
            requestsProcessed++;
            valueProcessed += netValue;
            currentHead++;
        }
        
        queue.head = currentHead;
        return requestsProcessed;
    }

    function _trySourceFromYieldReserve(
        address poolAddress, 
        uint256 amount
    ) internal returns (uint256 deployed) {
        if (yieldReserve == address(0)) return 0;
        
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        YieldReserveEscrow reserve = YieldReserveEscrow(yieldReserve);
        uint256 reserveAvailable = reserve.getAvailableBalance();
        
        deployed = amount > reserveAvailable ? reserveAvailable : amount;
        
        if (deployed > 0) {
            reserve.deployToPool(poolAddress, poolData.escrowAddress, deployed);
            StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
            escrow.recordProtocolFundsFromReserve(deployed);
        }
    }

    function _processQueuedWithdrawal(address poolAddress, uint256 requestId) internal {
        IStableYieldTypes.WithdrawalRequest storage request = withdrawalRequests[poolAddress][requestId];
        
        uint256 netValue = request.estimatedValue;
        uint256 feeAmount = request.feeAmount;
        
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        
        request.processed = true;
        request.processedTime = block.timestamp;

        poolQueues[poolAddress].totalPendingValue -= request.estimatedValue;

        if (feeAmount > 0) {
            escrow.collectWithdrawalFee(feeAmount);
            emit TransactionFeeCollected(poolAddress, "withdrawal", netValue + feeAmount, feeAmount);
        }

        escrow.withdraw(request.user, netValue);
        
        emit WithdrawalProcessed(poolAddress, request.user, requestId, netValue, feeAmount);
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
        uint256 pendingValue = _getPendingAllocationsValue(poolAddress);
        return baseNAV + pendingValue;
    }
    
    function _getPendingAllocationsValue(address poolAddress) internal view returns (uint256 pendingValue) {
        bytes32[] storage allocationIds = poolPendingAllocationIds[poolAddress];
        uint256 length = allocationIds.length;
        
        for (uint256 i = 0; i < length; i++) {
            IStableYieldTypes.PendingAllocation storage allocation = pendingAllocations[allocationIds[i]];
            if (allocation.status == IStableYieldTypes.AllocationStatus.PENDING ||
                allocation.status == IStableYieldTypes.AllocationStatus.INVESTED) {
                uint256 outstanding = allocation.amount - allocation.usedAmount - allocation.returnedAmount;
                pendingValue += outstanding;
            }
        }
    }

    function _removeAllocationFromTracking(address poolAddress, bytes32 allocationId) internal {
        bytes32[] storage ids = poolPendingAllocationIds[poolAddress];
        uint256 length = ids.length;
        for (uint256 i = 0; i < length; i++) {
            if (ids[i] == allocationId) {
                ids[i] = ids[length - 1];
                ids.pop();
                return;
            }
        }
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
     * @dev Create a pending allocation for an SPV. Funds are reserved in escrow.
     *      Allocation expires after ALLOCATION_EXPIRY if not used.
     */
    function createPendingAllocation(
        address poolAddress,
        address spvAddress,
        uint256 amount
    ) external onlyRole(accessManager.OPERATOR_ROLE()) poolExists(poolAddress) nonReentrant returns (bytes32 allocationId) {
        if (spvAddress == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (poolPendingAllocationIds[poolAddress].length >= MAX_PENDING_ALLOCATIONS) revert MaxAllocations();
        
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        
        (bool ready, uint256 available) = isReadyForAllocation(poolAddress);
        if (!ready || available < amount) revert InsufficientFunds();
        
        allocationId = keccak256(abi.encodePacked(
            poolAddress,
            spvAddress,
            amount,
            block.timestamp,
            poolInstrumentCount[poolAddress]
        ));
        
        if (pendingAllocations[allocationId].createdAt != 0) revert AllocationExists();
        
        pendingAllocations[allocationId] = IStableYieldTypes.PendingAllocation({
            allocationId: allocationId,
            pool: poolAddress,
            spv: spvAddress,
            amount: amount,
            usedAmount: 0,
            returnedAmount: 0,
            createdAt: block.timestamp,
            expiresAt: block.timestamp + ALLOCATION_EXPIRY,
            status: IStableYieldTypes.AllocationStatus.PENDING
        });
        
        poolPendingAllocationIds[poolAddress].push(allocationId);
        
        totalSPVAllocations[spvAddress] += amount;
        poolToSPVAllocations[poolAddress][spvAddress] += amount;
        
        escrow.allocateToSPV(spvAddress, amount);
        
        emit AllocationCreated(poolAddress, spvAddress, allocationId, amount, block.timestamp);
        
        _triggerNAVUpdate(poolAddress, "spv_allocation");
        
        return allocationId;
    }

    // ==================== INSTRUMENT LIFECYCLE ====================

    /**
     * @dev SPV purchases an instrument using an existing allocation.
     *      Validates allocation ownership, expiry, and price bounds.
     */
    function addInstrument(
        address poolAddress,
        bytes32 allocationId,
        IStableYieldTypes.InstrumentType instrumentType,
        uint256 purchasePrice,
        uint256 faceValue,
        uint256 maturityDate,
        uint256 annualCouponRate,
        uint8 couponFrequency
    ) external onlyRole(accessManager.SPV_ROLE()) poolExists(poolAddress) nonReentrant {
        IStableYieldTypes.PendingAllocation storage allocation = pendingAllocations[allocationId];
        
        if (allocation.createdAt == 0) revert AllocationNotFound();
        if (allocation.pool != poolAddress) revert AllocationMismatch();
        if (allocation.spv != msg.sender) revert NotAllocationSPV();
        if (allocation.status != IStableYieldTypes.AllocationStatus.PENDING) revert AllocationNotPending();
        if (block.timestamp >= allocation.expiresAt) revert AllocationExpired();
        uint256 remainingAllocation = allocation.amount - allocation.usedAmount - allocation.returnedAmount;
        if (purchasePrice > remainingAllocation) revert ExceedsAllocation();
        
        _addInstrumentWithAllocation(
            poolAddress,
            allocationId,
            instrumentType,
            purchasePrice,
            faceValue,
            maturityDate,
            annualCouponRate,
            couponFrequency
        );
    }

    function _addInstrumentWithAllocation(
        address poolAddress,
        bytes32 allocationId,
        IStableYieldTypes.InstrumentType instrumentType,
        uint256 purchasePrice,
        uint256 faceValue,
        uint256 maturityDate,
        uint256 annualCouponRate,
        uint8 couponFrequency
    ) internal {
        if (poolInstrumentCount[poolAddress] >= MAX_INSTRUMENTS_PER_POOL) revert InvalidInstrument();
        
        IStableYieldTypes.PendingAllocation storage allocation = pendingAllocations[allocationId];
        
        if (maturityDate <= block.timestamp) revert InvalidMaturity();
        if (faceValue < purchasePrice) revert InvalidFaceValue();
        if (instrumentType == IStableYieldTypes.InstrumentType.INTEREST_BEARING) {
            if (couponFrequency == 0) revert InvalidCouponFrequency();
            if (annualCouponRate == 0) revert InvalidCouponRate();
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
            allocationId: allocationId
        }));
        
        allocation.usedAmount += purchasePrice;
        
        if (allocation.usedAmount + allocation.returnedAmount >= allocation.amount) {
            allocation.status = IStableYieldTypes.AllocationStatus.INVESTED;
            _removeAllocationFromTracking(poolAddress, allocationId);
        }
        
        poolInstrumentCount[poolAddress]++;
        
        emit InstrumentPurchased(poolAddress, instrumentId, instrumentType, purchasePrice, faceValue, maturityDate);
        emit AllocationInvested(poolAddress, allocationId, instrumentId, block.timestamp);
        
        _triggerNAVUpdate(poolAddress, "instrument_added");
    }

    /**
     * @dev SPV returns maturity proceeds. Updates allocation tracking and removes instrument.
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
        
        bytes32 allocationId = instrument.allocationId;
        if (allocationId != bytes32(0)) {
            IStableYieldTypes.PendingAllocation storage allocation = pendingAllocations[allocationId];
            if (allocation.createdAt > 0) {
                allocation.status = IStableYieldTypes.AllocationStatus.MATURED;
                _removeAllocationFromTracking(poolAddress, allocationId);
                
                uint256 usedFromAllocation = instrument.purchasePrice;
                if (totalSPVAllocations[allocation.spv] >= usedFromAllocation) {
                    totalSPVAllocations[allocation.spv] -= usedFromAllocation;
                }
                if (poolToSPVAllocations[poolAddress][allocation.spv] >= usedFromAllocation) {
                    poolToSPVAllocations[poolAddress][allocation.spv] -= usedFromAllocation;
                }
                
                emit AllocationMatured(poolAddress, instrumentId, allocationId, maturityAmount, block.timestamp);
            }
        }
        
        uint256 realizedYield = maturityAmount > instrument.purchasePrice ? maturityAmount - instrument.purchasePrice : 0;
        
        emit InstrumentMatured(poolAddress, instrumentId, instrument.faceValue, realizedYield);
        
        _removeInstrument(poolAddress, instrumentId, "matured");
        
        _triggerNAVUpdate(poolAddress, "instrument_matured");
    }

    /**
     * @dev SPV returns unused allocation funds back to the pool escrow.
     */
    function returnUnusedFunds(
        bytes32 allocationId,
        uint256 returnAmount
    ) external onlyRole(accessManager.SPV_ROLE()) nonReentrant {
        IStableYieldTypes.PendingAllocation storage allocation = pendingAllocations[allocationId];
        
        if (allocation.createdAt == 0) revert AllocationNotFound();
        if (allocation.spv != msg.sender) revert NotAllocationSPV();
        if (allocation.status != IStableYieldTypes.AllocationStatus.PENDING &&
            allocation.status != IStableYieldTypes.AllocationStatus.INVESTED) revert InvalidStatus();
        if (returnAmount == 0) revert InvalidAmount();
        
        uint256 maxReturnable = allocation.amount - allocation.usedAmount - allocation.returnedAmount;
        if (returnAmount > maxReturnable) revert ExceedsAllocation();
        
        IStableYieldTypes.PoolData storage poolData = pools[allocation.pool];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        
        IERC20 asset = IERC20(poolData.asset);
        asset.safeTransferFrom(msg.sender, address(escrow), returnAmount);
        escrow.recordReceivedLiquidity(returnAmount);
        
        allocation.returnedAmount += returnAmount;
        
        if (totalSPVAllocations[allocation.spv] >= returnAmount) {
            totalSPVAllocations[allocation.spv] -= returnAmount;
        }
        if (poolToSPVAllocations[allocation.pool][allocation.spv] >= returnAmount) {
            poolToSPVAllocations[allocation.pool][allocation.spv] -= returnAmount;
        }
        
        if (allocation.usedAmount + allocation.returnedAmount >= allocation.amount) {
            allocation.status = IStableYieldTypes.AllocationStatus.RETURNED;
            _removeAllocationFromTracking(allocation.pool, allocationId);
        }
        
        emit AllocationReturned(allocation.pool, allocationId, returnAmount, block.timestamp);
        
        _triggerNAVUpdate(allocation.pool, "funds_returned");
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

    // ==================== ADMIN CONFIG ====================

    /**
     * @dev Deactivate a pool, preventing new deposits and allocations.
     */
    /// @dev Removes a holding from NAV without requiring funds or its maturity date.
    ///
    ///      matureInstrumentWithFunds needs both, which is no use when the problem is the
    ///      instrument itself. Writes the holding to zero, so use it only where the
    ///      position is genuinely worthless or was recorded in error.
    function writeOffInstrument(address poolAddress, uint256 instrumentId)
        external
        onlyRole(accessManager.DEFAULT_ADMIN_ROLE())
        poolExists(poolAddress)
    {
        if (instrumentId >= poolInstruments[poolAddress].length) revert InvalidInstrument();
        IStableYieldTypes.InstrumentHolding storage instrument = poolInstruments[poolAddress][instrumentId];
        if (!instrument.isActive) revert InstrumentNotActive();

        instrument.isActive = false;

        emit InstrumentWrittenOff(poolAddress, instrumentId, instrument.purchasePrice);
    }

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

    function getPendingAllocation(bytes32 allocationId) external view returns (IStableYieldTypes.PendingAllocation memory) {
        return pendingAllocations[allocationId];
    }

    function getPoolPendingAllocations(address poolAddress) external view returns (bytes32[] memory) {
        return poolPendingAllocationIds[poolAddress];
    }

    function getTotalSPVAllocation(address spvAddress) external view returns (uint256) {
        return totalSPVAllocations[spvAddress];
    }

    function getPoolToSPVAllocation(address poolAddress, address spvAddress) external view returns (uint256) {
        return poolToSPVAllocations[poolAddress][spvAddress];
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
