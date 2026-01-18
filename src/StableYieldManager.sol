// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./AccessManager.sol";
import "./interfaces/IPoolRegistry.sol";
import "./escrows/StableYieldEscrow.sol"; 
import "./types/IStableYieldTypes.sol";
import "./libraries/StableYieldNAVLibrary.sol";


/**
 * @title StableYieldManager
 * @dev  manages all business logic for managed pools
 * @notice Handles NAV calculation, deposit/withdrawal validation, queue management, and pool coordination
 */
contract StableYieldManager is 
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STATE VARIABLES //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    AccessManager public accessManager;
    IPoolRegistry public registry;
    address public timelockController;
    address public managedPoolFactory;

    uint256 public defaultMinAbsoluteReserve;
    uint256 public defaultReserveRatioBps;

    uint256 public version;
    
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_TRANSACTION_FEE = 500; // 5% max

    // @notice Default fee in basis points for deposit and withdrawals
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


    

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EVENTS //////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

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

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// MODIFIERS ///////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    modifier onlyRegisteredPool() {
        require(registry.isManagedPool(msg.sender), "StableYieldManager/not registered pool");
        _;
    }
    
    modifier poolExists(address poolAddress) {
        require(registry.isManagedPool(poolAddress), "StableYieldManager/pool not found");
        _;
    }

     modifier ActivePool (address poolAddress) {
        require(pools[poolAddress].isActive, "PoolManager/pool not active");
        _;
    }

    modifier onlyRole(bytes32 role) {
        require(accessManager.hasRole(role, msg.sender), "Access Denied");

        _;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INITIALIZATION /////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the PoolManager
     * @param accessManager_ AccessManager contract address
     * @param registry_ PoolRegistry contract address
     * @param timelockController_ Timelock controller address
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

        require(accessManager_ != address(0), "PoolManager/invalid access manager");
        require(registry_ != address(0), "PoolManager/invalid registry");
        require(timelockController_ != address(0), "PoolManager/invalid timelock");
        require(defaultFeeBps_ <= MAX_TRANSACTION_FEE, "StableYieldManager/fee too high");

        accessManager = AccessManager(accessManager_);
        registry = IPoolRegistry(registry_);
        timelockController = timelockController_;
        defaultTransactionFeeBps = defaultFeeBps_;
        version = 1;
        
        defaultMinAbsoluteReserve = 0;
        defaultReserveRatioBps = 1000;
    }

    /**
     * @notice Authorize contract upgrades (timelock only)
     */
    function _authorizeUpgrade(address newImplementation) internal override {
        require(msg.sender == timelockController, "PoolManager/only timelock");
        require(newImplementation != address(0), "PoolManager/invalid implementation");
        version += 1;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// POOL REGISTRATION ///////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Register a new stable yield pool
     * @param poolAddress Pool contract address
     * @param escrowAddress Escrow contract address
     * @param asset Underlying asset address
     * @param name Pool name
     */
    function registerPool(
        address poolAddress,
        address escrowAddress,
        address asset,
        string memory name,
        uint256 minInvestment
    ) external nonReentrant {
        require(msg.sender == managedPoolFactory, "StableYieldManager/only factory");
        require(poolAddress != address(0), "PoolManager/invalid pool");
        require(escrowAddress != address(0), "PoolManager/invalid escrow");
        require(asset != address(0), "PoolManager/invalid asset");
        require(!registry.isManagedPool(poolAddress), "StableYieldManager/pool already registered");
        require(minInvestment > 0, "PoolManager/invalid min investment");
        
        uint8 assetDecimals = IERC20Metadata(asset).decimals();
        require(assetDecimals == 6 || assetDecimals == 18, "PoolManager/only 6 or 18 decimal stablecoins supported");
        
        require(registry.isApprovedAsset(asset), "PoolManager/asset not approved");
        
        
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


   

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// DEPOSIT HANDLING /////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Validate and process deposit for flexible pool
     * @param poolAddress Pool receiving deposit
     * @param amount Amount being deposited
     * @param receiver Share recipient
     * @return shares Number of shares to mint
     */
    function validateDeposit(
        address poolAddress,
        uint256 amount,
        address receiver
    ) external onlyRegisteredPool poolExists(poolAddress) ActivePool(poolAddress) nonReentrant returns (uint256 shares) { 
        require(msg.sender == poolAddress, "StableYieldManager/invalid caller");
        require(registry.isManagedPool(poolAddress), "StableYieldManager/invalid pool"); 
        
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        require(amount >= poolData.minInvestment, "StableYieldManager/below minimum");
        require(receiver != address(0), "StableYieldManager/invalid receiver");
         
        uint256 transactionFee = calculateTransactionFee(poolAddress, amount);
        uint256 netDepositAmount = amount - transactionFee;
        
        uint256 navPerShare = calculateNAVPerShare(poolAddress);
        shares = (netDepositAmount * 1e18) / navPerShare;
        
 
        StableYieldEscrow(poolData.escrowAddress).allocateDeposit(amount, netDepositAmount, transactionFee);
        
        if (transactionFee > 0) {
            emit TransactionFeeCollected(poolAddress, "deposit", amount, transactionFee);
        }
        
        emit DepositValidated(poolAddress, receiver, amount, shares);
        
        return shares;
    }


    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// WITHDRAWAL HANDLING //////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Validate and process withdrawal request
     * @param poolAddress Pool processing withdrawal
     * @param shares Number of shares to redeem
     * @param receiver Recipient of assets
     * @param owner Share owner
     * @return actualShares Shares to burn (always equals input shares)
     * @return withdrawalValue Net value after fees
     * @return immediate True if funds transferred immediately, false if queued
     */
    function validateWithdrawal(
        address poolAddress,
        uint256 shares,
        address receiver,
        address owner
    ) external poolExists(poolAddress) ActivePool(poolAddress) nonReentrant returns (uint256 actualShares, uint256 withdrawalValue, bool immediate) {
        require(msg.sender == poolAddress, "StableYieldManager/invalid caller");
        require(registry.isManagedPool(poolAddress), "StableYieldManager/invalid pool");
        require(shares > 0, "StableYieldManager/invalid shares");
        require(receiver != address(0), "StableYieldManager/invalid receiver");
        require(owner != address(0), "StableYieldManager/invalid owner");
        
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        require(poolData.isActive, "StableYieldManager/pool not active");
        
        uint256 navPerShare = calculateNAVPerShare(poolAddress);
        uint256 grossWithdrawalValue = (shares * navPerShare) / 1e18;
        
        uint256 transactionFee = calculateTransactionFee(poolAddress, grossWithdrawalValue);
        withdrawalValue = grossWithdrawalValue - transactionFee;
        
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        
        if (escrow.getPoolReserves() >= grossWithdrawalValue) {
            if (transactionFee > 0) {
                escrow.allocateWithdrawalFee(transactionFee);
                emit TransactionFeeCollected(poolAddress, "withdrawal", grossWithdrawalValue, transactionFee);
            }
            
            emit WithdrawalValidated(poolAddress, owner, shares, withdrawalValue, true);
            return (shares, withdrawalValue, true);
        } else {
            _queueWithdrawal(poolAddress, owner, shares, withdrawalValue);
            
            emit WithdrawalValidated(poolAddress, owner, shares, withdrawalValue, false);
            return (shares, withdrawalValue, false);
        }
    }


    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// QUEUE MANAGEMENT //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////


     /**
     * @notice Queue a withdrawal request
     */

    function _queueWithdrawal(
        address poolAddress,
        address user,
        uint256 shares,
        uint256 estimatedValue
    ) internal {
        IStableYieldTypes.WithdrawalQueue storage queue = poolQueues[poolAddress];
        
        uint256 requestId = queue.tail++;
        withdrawalRequests[poolAddress][requestId] = IStableYieldTypes.WithdrawalRequest({
            user: user,
            shares: shares,
            requestTime: block.timestamp,
            estimatedValue: estimatedValue,
            processed: false,
            processedTime: 0
        });
        
        userWithdrawalRequests[poolAddress][user].push(requestId);
        queue.totalPendingValue += estimatedValue;
        
        emit WithdrawalQueued(poolAddress, user, requestId, shares, estimatedValue);
    }

    /**
     * @notice Process queued withdrawals for a pool
     * @param poolAddress Pool to process withdrawals for
     * @param maxRequests Maximum number of requests to process
     * @return processed Number of requests processed
     */
    function processWithdrawalQueue(address poolAddress, uint256 maxRequests) 
        external 
        onlyRole(accessManager.OPERATOR_ROLE()) 
        ActivePool(poolAddress) 
        nonReentrant 
        returns (uint256 processed) 
    {
        IStableYieldTypes.WithdrawalQueue storage queue = poolQueues[poolAddress];
        
        uint256 requestsProcessed = 0;
        uint256 currentHead = queue.head;
        
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        
        while (requestsProcessed < maxRequests && currentHead < queue.tail && escrow.getPoolReserves() > 0) {
            IStableYieldTypes.WithdrawalRequest storage request = withdrawalRequests[poolAddress][currentHead];
            
            if (!request.processed) {
                uint256 netValue = request.estimatedValue;
                
                if (escrow.getPoolReserves() >= netValue) {
                    _processQueuedWithdrawal(poolAddress, currentHead);
                    requestsProcessed++;
                }
            }
            
            currentHead++;
        }
        
        queue.head = currentHead;
        
        return requestsProcessed;
    }

        /**
     * @notice Process a queued withdrawal
     */
    function _processQueuedWithdrawal(address poolAddress, uint256 requestId) internal {
        IStableYieldTypes.WithdrawalRequest storage request = withdrawalRequests[poolAddress][requestId];
        
        uint256 netValue = request.estimatedValue;
        
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
      
        
        request.processed = true;
        request.processedTime = block.timestamp;

        poolQueues[poolAddress].totalPendingValue -= request.estimatedValue;

        escrow.withdraw(request.user, netValue);
        
       
        
        emit WithdrawalProcessed(poolAddress, request.user, requestId, netValue, 0);
    }


    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// NAV CALCULATION //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Calculate pool NAV
     * @dev NAV = Gross Asset Value + Pool Reserves
     *      Transaction fees are NOT deducted (already extracted at transaction time)
     * @param poolAddress Pool address
     * @return totalNAV Current NAV
     */
    function calculatePoolNAV(address poolAddress) public view poolExists(poolAddress) returns (uint256 totalNAV) {
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        return StableYieldNAVLibrary.calculatePoolNAV(
            poolData,
            poolInstruments[poolAddress]
        );
    }

    /**
     * @notice Calculate NAV per share
     * @param poolAddress Pool address
     * @return navPerShare NAV per share (normalized to 18 decimals)
     */
    function calculateNAVPerShare(address poolAddress) public view ActivePool(poolAddress) returns (uint256 navPerShare) {
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        return StableYieldNAVLibrary.calculateNAVPerShare(
            poolData,
            poolInstruments[poolAddress]
        );
    }

                                                                                                                                                                                            
    
    /**
     * @notice  gross asset value calculation
     * @param poolAddress Pool address                                                                                                                 
     * @return grossValue Total value of all instruments
     */
    function _calculateGrossAssetValue(address poolAddress) internal view returns (uint256 grossValue) {
        return StableYieldNAVLibrary.calculateGrossAssetValue(poolInstruments[poolAddress]);
    }

    /**
     * @notice Discounted instrument value calculation
     * @param instrument Instrument data
     * @param currentTime Current timestamp
     * @return value Current value of discounted instrument
     */
    function _calculateDiscountedValue(IStableYieldTypes.InstrumentHolding storage instrument, uint256 currentTime) internal view returns (uint256 value) {
        return StableYieldNAVLibrary.calculateDiscountedValue(instrument, currentTime);
    }
    
    /**
     * @notice interest-bearing instrument value calculation
     * @param instrument Instrument data
     * @param currentTime Current timestamp
     * @return value Current value including accrued interest
     */
    function _calculateInterestBearingValue(IStableYieldTypes.InstrumentHolding storage instrument, uint256 currentTime) internal view returns (uint256 value) {
        return StableYieldNAVLibrary.calculateInterestBearingValue(instrument, currentTime);
    }



    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// OPERATOR FUNCTIONS //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////



    /**
     * @notice Create pending allocation for SPV (Operator only)
     * @dev SPV must call addInstrument with returned allocationId to complete
     * @param poolAddress Pool address
     * @param spvAddress SPV address
     * @param amount Amount to allocate
     * @return allocationId Unique identifier for this allocation
     */
    function createPendingAllocation(
        address poolAddress,
        address spvAddress,
        uint256 amount
    ) external onlyRole(accessManager.OPERATOR_ROLE()) poolExists(poolAddress) nonReentrant returns (bytes32 allocationId) {
        require(spvAddress != address(0), "StableYieldManager/invalid SPV");
        require(amount > 0, "StableYieldManager/invalid amount");
        
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        
        (bool ready, uint256 available) = isReadyForAllocation(poolAddress);
        require(ready && available >= amount, "StableYieldManager/insufficient allocatable funds");
        
        allocationId = keccak256(abi.encodePacked(
            poolAddress,
            spvAddress,
            amount,
            block.timestamp,
            poolInstrumentCount[poolAddress]
        ));
        
        require(pendingAllocations[allocationId].createdAt == 0, "StableYieldManager/allocation exists");
        
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

    /**
     * @notice Cancel expired or unused pending allocation
     * @dev SPV must return funds before calling this
     * @param allocationId Allocation to cancel
     */
    function cancelPendingAllocation(
        bytes32 allocationId
    ) external onlyRole(accessManager.OPERATOR_ROLE()) nonReentrant {
        IStableYieldTypes.PendingAllocation storage allocation = pendingAllocations[allocationId];
        
        require(allocation.createdAt > 0, "StableYieldManager/allocation not found");
        require(allocation.status == IStableYieldTypes.AllocationStatus.PENDING, "StableYieldManager/not pending");
        require(block.timestamp >= allocation.expiresAt, "StableYieldManager/not expired");
        
        allocation.status = IStableYieldTypes.AllocationStatus.CANCELLED;
        
        totalSPVAllocations[allocation.spv] -= allocation.amount;
        poolToSPVAllocations[allocation.pool][allocation.spv] -= allocation.amount;
        
        emit AllocationCancelled(allocation.pool, allocationId, allocation.amount, block.timestamp);
    }


     ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// SPV FUNCTIONS ///////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Add new instrument to pool with allocation linkage (SPV attestation)
     * @dev Requires a pending allocation created via createPendingAllocation
     * @param poolAddress Pool address
     * @param allocationId Pending allocation to link
     * @param instrumentType Type of instrument (DISCOUNTED or INTEREST_BEARING)
     * @param purchasePrice Amount paid for instrument
     * @param faceValue Maturity value
     * @param maturityDate When instrument matures
     * @param annualCouponRate Annual coupon rate in basis points (0 for T-bills)
     * @param couponFrequency Coupon frequency (0 for T-bills)
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
        
        require(allocation.createdAt > 0, "StableYieldManager/allocation not found");
        require(allocation.pool == poolAddress, "StableYieldManager/pool mismatch");
        require(allocation.spv == msg.sender, "StableYieldManager/not allocation SPV");
        require(allocation.status == IStableYieldTypes.AllocationStatus.PENDING, "StableYieldManager/not pending");
        require(block.timestamp < allocation.expiresAt, "StableYieldManager/allocation expired");
        require(purchasePrice <= allocation.amount, "StableYieldManager/exceeds allocation");
        
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
        IStableYieldTypes.PendingAllocation storage allocation = pendingAllocations[allocationId];
        
        require(maturityDate > block.timestamp, "StableYieldManager/invalid maturity");
        require(faceValue >= purchasePrice, "StableYieldManager/invalid face value");
        
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
        allocation.status = IStableYieldTypes.AllocationStatus.INVESTED;
        
        poolInstrumentCount[poolAddress]++;
        
        emit InstrumentPurchased(poolAddress, instrumentId, instrumentType, purchasePrice, faceValue, maturityDate);
        emit AllocationInvested(poolAddress, allocationId, instrumentId, block.timestamp);
        
        _triggerNAVUpdate(poolAddress, "instrument_added");
    }

    /**
     * @notice Process matured instrument with fund return
     * @dev SPV transfers maturity proceeds which are pulled via safeTransferFrom
     * @param poolAddress Pool address
     * @param instrumentId Instrument ID
     * @param maturityAmount Amount received at maturity
     */
    function matureInstrumentWithFunds(
        address poolAddress,
        uint256 instrumentId,
        uint256 maturityAmount
    ) external onlyRole(accessManager.SPV_ROLE()) poolExists(poolAddress) nonReentrant {
        require(instrumentId < poolInstruments[poolAddress].length, "StableYieldManager/invalid instrument");
        
        IStableYieldTypes.InstrumentHolding storage instrument = poolInstruments[poolAddress][instrumentId];
        require(instrument.isActive, "StableYieldManager/instrument not active");
        require(block.timestamp >= instrument.maturityDate, "StableYieldManager/not matured");
        require(maturityAmount > 0, "StableYieldManager/invalid amount");
        
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
     * @notice Return unused funds from a pending allocation
     * @dev SPV must approve manager before calling. Can be called multiple times for partial returns.
     * @param allocationId Allocation to return funds for
     * @param returnAmount Amount being returned
     */
    function returnUnusedFunds(
        bytes32 allocationId,
        uint256 returnAmount
    ) external onlyRole(accessManager.SPV_ROLE()) nonReentrant {
        IStableYieldTypes.PendingAllocation storage allocation = pendingAllocations[allocationId];
        
        require(allocation.createdAt > 0, "StableYieldManager/allocation not found");
        require(allocation.spv == msg.sender, "StableYieldManager/not allocation SPV");
        require(
            allocation.status == IStableYieldTypes.AllocationStatus.PENDING ||
            allocation.status == IStableYieldTypes.AllocationStatus.INVESTED,
            "StableYieldManager/invalid status"
        );
        require(returnAmount > 0, "StableYieldManager/invalid amount");
        
        // Ensure SPV doesn't return more than remaining (amount - usedAmount - alreadyReturned)
        uint256 maxReturnable = allocation.amount - allocation.usedAmount - allocation.returnedAmount;
        require(returnAmount <= maxReturnable, "StableYieldManager/exceeds returnable amount");
        
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
        
        // Mark as RETURNED if all unused funds are returned (usedAmount + returnedAmount == amount)
        if (allocation.usedAmount + allocation.returnedAmount >= allocation.amount) {
            allocation.status = IStableYieldTypes.AllocationStatus.RETURNED;
        }
        
        emit AllocationReturned(allocation.pool, allocationId, returnAmount, block.timestamp);
        
        _triggerNAVUpdate(allocation.pool, "funds_returned");
    }

    /**
     * @notice Record coupon payment for interest-bearing instrument
     * @param poolAddress Pool address
     * @param instrumentId Instrument ID
     * @param couponAmount Amount of coupon received
     */
    function recordCouponPayment(
        address poolAddress,
        uint256 instrumentId,
        uint256 couponAmount
    ) external onlyRole(accessManager.SPV_ROLE()) poolExists(poolAddress) nonReentrant {

        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        IStableYieldTypes.InstrumentHolding[] storage instruments =  poolInstruments[poolAddress];
        
        require(instrumentId < instruments.length, "InstrumentLib/invalid instrument");
        
        IStableYieldTypes.InstrumentHolding storage instrument = instruments[instrumentId];
        require(instrument.isActive, "InstrumentLib/instrument not active");
        require(
            instrument.instrumentType == IStableYieldTypes.InstrumentType.INTEREST_BEARING,
            "InstrumentLib/not interest bearing"
        );
        require(block.timestamp >= instrument.nextCouponDueDate, "InstrumentLib/coupon not due");

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

      /**
     * @notice SPV can trigger NAV recalculation after instrument changes
     * @param poolAddress Pool that had instrument changes
     * @param reason Reason for NAV update (new instrument, maturity, coupon, etc.)
     */
    function triggerNAVUpdate(address poolAddress, string memory reason) 
        external 
        onlyRole(accessManager.SPV_ROLE()) 
        poolExists(poolAddress) 
    {
        _triggerNAVUpdate(poolAddress, reason);
    }
    
    /**
     * @notice Internal function to trigger NAV update and emit events
     * @param poolAddress Pool address
     * @param reason Reason for update
     */
    function _triggerNAVUpdate(address poolAddress, string memory reason) internal {
        StableYieldNAVLibrary.triggerNAVUpdate(
            poolAddress,
            pools[poolAddress],
            poolInstruments[poolAddress],
            reason
        );
    }



     /**
     * @notice  instrument removal from array
     * @param poolAddress Pool address
     * @param instrumentId Index of instrument to remove
     * @param reason Reason for removal
     */
    function _removeInstrument(address poolAddress, uint256 instrumentId, string memory reason) internal {
        IStableYieldTypes.InstrumentHolding[] storage instruments = poolInstruments[poolAddress];
        require(instrumentId < instruments.length, "StableYieldManager/invalid instrument index");
        
        uint256 finalValue = instruments[instrumentId].faceValue;
        
        if (instrumentId != instruments.length - 1) {
            instruments[instrumentId] = instruments[instruments.length - 1];
        }
        instruments.pop();
        
        poolInstrumentCount[poolAddress]--;
        
        emit InstrumentRemoved(poolAddress, instrumentId, finalValue, reason);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ADMIN FUNCTIONS ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////


    /**
     * @notice Deactivate a pool
     */
    function deactivatePool(address poolAddress) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) poolExists(poolAddress) {
        pools[poolAddress].isActive = false;
        emit PoolDeactivated(poolAddress, block.timestamp);
    }

    /**
     * @notice Set the ManagedPoolFactory address
     * @dev Only callable by admin during initial setup
     */
    function setManagedPoolFactory(address _factory) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(_factory != address(0), "StableYieldManager/invalid factory");
        require(managedPoolFactory == address(0), "StableYieldManager/factory already set");
        managedPoolFactory = _factory;
    }

    /**
     * @notice Set default transaction fee (admin only)
     * @param feeBps Fee in basis points (e.g., 300 = 3%)
     */
    function setDefaultTransactionFee(uint256 feeBps) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(feeBps <= MAX_TRANSACTION_FEE, "StableYieldManager/fee too high");
        
        uint256 oldFee = defaultTransactionFeeBps;
        defaultTransactionFeeBps = feeBps;
        
        emit TransactionFeeConfigUpdated(oldFee, feeBps);
    }

    /**
     * @notice Set transaction fee for a specific pool (admin only)
     * @param poolAddress Pool address
     * @param feeBps Fee in basis points (0 = use default)
     */
    function setPoolTransactionFee(address poolAddress, uint256 feeBps) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) poolExists(poolAddress) {
        require(feeBps <= MAX_TRANSACTION_FEE, "StableYieldManager/fee too high");
        
        poolTransactionFeeBps[poolAddress] = feeBps;
        
        emit PoolTransactionFeeUpdated(poolAddress, feeBps);
    }


    /**
     * @notice Set default reserve configuration for new pools
     * @param minAbsoluteReserve Minimum reserve floor
     * @param reserveRatioBps Reserve ratio in basis points
     */
    function setDefaultReserveConfig(
        uint256 minAbsoluteReserve,
        uint256 reserveRatioBps
    ) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(reserveRatioBps <= 5000, "StableYieldManager/ratio too high");
        
        defaultMinAbsoluteReserve = minAbsoluteReserve;
        defaultReserveRatioBps = reserveRatioBps;
    }

    /**
     * @notice Set reserve configuration for a specific pool
     * @param poolAddress Pool to configure
     * @param minAbsoluteReserve Minimum reserve floor in pool asset decimals
     * @param reserveRatioBps Reserve ratio in basis points
     */
    function setPoolReserveConfig(
        address poolAddress,
        uint256 minAbsoluteReserve,
        uint256 reserveRatioBps
    ) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) poolExists(poolAddress) {
        require(reserveRatioBps <= 5000, "StableYieldManager/ratio too high");
        
        poolReserveConfigs[poolAddress] = IStableYieldTypes.ReserveConfig({
            minAbsoluteReserve: minAbsoluteReserve,
            reserveRatioBps: reserveRatioBps
        });
        
        emit ReserveConfigUpdated(poolAddress, minAbsoluteReserve, reserveRatioBps);
    }

 




    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// VIEW FUNCTIONS ///////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Check if pool is ready for SPV allocation
     * @param poolAddress Pool to check
     * @return ready True if pool has sufficient reserves above threshold
     * @return availableAmount Amount available for allocation
     */
    function isReadyForAllocation(address poolAddress) public view poolExists(poolAddress) returns (bool ready, uint256 availableAmount) {
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        
        uint256 currentReserves = escrow.getPoolReserves();
        uint256 totalNAV = calculatePoolNAV(poolAddress);
        
        IStableYieldTypes.ReserveConfig storage config = poolReserveConfigs[poolAddress];
        uint256 minReserve = config.minAbsoluteReserve;
        uint256 ratioBps = config.reserveRatioBps;
        
        if (minReserve == 0 && ratioBps == 0) {
            minReserve = defaultMinAbsoluteReserve;
            ratioBps = defaultReserveRatioBps;
        }
        
        uint256 ratioBasedReserve = (totalNAV * ratioBps) / 10000;
        uint256 requiredReserve = minReserve > ratioBasedReserve ? minReserve : ratioBasedReserve;
        
        if (currentReserves > requiredReserve) {
            availableAmount = currentReserves - requiredReserve;
            ready = true;
        } else {
            availableAmount = 0;
            ready = false;
        }
        
        return (ready, availableAmount);
    }

        



    /**
     * @notice Get transaction fee for a pool (returns pool-specific or default)
     * @param poolAddress Pool address
     * @return feeBps Fee in basis points
     */
    function getPoolTransactionFee(address poolAddress) public view returns (uint256 feeBps) {
        feeBps = poolTransactionFeeBps[poolAddress];
        if (feeBps == 0) {
            feeBps = defaultTransactionFeeBps;
        }
        return feeBps;
    }

    /**
     * @notice Calculate transaction fee for an amount
     * @param poolAddress Pool address
     * @param amount Amount to calculate fee on
     * @return fee Fee amount
     */
    function calculateTransactionFee(address poolAddress, uint256 amount) public view returns (uint256 fee) {
        if (amount == 0) return 0;
        uint256 feeBps = getPoolTransactionFee(poolAddress);
        return (amount * feeBps) / BASIS_POINTS;
    }

    /**
     * @notice Get pool data
     */
    function getPoolData(address poolAddress) external view poolExists(poolAddress) returns (IStableYieldTypes.PoolData memory) {
        return pools[poolAddress];
    }


    /**
     * @notice Get withdrawal queue status
     */
    function getWithdrawalQueueStatus(address poolAddress) 
        external 
        view 
        poolExists(poolAddress) 
        returns (uint256 head, uint256 tail, uint256 pending, uint256 totalPendingValue) 
    {
        IStableYieldTypes.WithdrawalQueue storage queue = poolQueues[poolAddress];
        return (queue.head, queue.tail, queue.tail - queue.head, queue.totalPendingValue);
    }

    /**
     * @notice Get user withdrawal requests
     */
    function getUserWithdrawalRequests(address poolAddress, address user) 
        external 
        view 
        returns (uint256[] memory) 
    {
        return userWithdrawalRequests[poolAddress][user];
    }

    /**
     * @notice Get all instruments for a pool
     */
    function getPoolInstruments(address poolAddress) external view poolExists(poolAddress) returns (IStableYieldTypes.InstrumentHolding[] memory) {
        return poolInstruments[poolAddress];
    }

    /**
     * @notice Get specific instrument
     */
    function getInstrument(address poolAddress, uint256 instrumentId) external view returns (IStableYieldTypes.InstrumentHolding memory) {
        require(instrumentId < poolInstruments[poolAddress].length, "StableYieldManager/invalid instrument");
        return poolInstruments[poolAddress][instrumentId];
    }

    /**
     * @notice Calculate shares for amount at current NAV
     */
    function calculateShares(address poolAddress, uint256 amount) 
        external 
        view
        poolExists(poolAddress) 
        returns (uint256) 
    {
        uint256 navPerShare = calculateNAVPerShare(poolAddress);
        return (amount * 1e18) / navPerShare;
    }

    /**
     * @notice Calculate asset value for shares at current NAV
     */
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
     * @notice Calculate shares for amount at current NAV (view-only)
     * @dev Uses cached NAV calculation for ERC4626 internal functions
     */
    function calculateSharesView(address poolAddress, uint256 amount) 
        external 
        view
        poolExists(poolAddress) 
        returns (uint256) 
    {
        uint256 navPerShare = _calculateNAVPerShareView(poolAddress);
        return (amount * 1e18) / navPerShare;
    }

    /**
     * @notice Calculate asset value for shares at current NAV (view-only)
     * @dev Uses cached NAV calculation for ERC4626 internal functions
     */
    function calculateAssetValueView(address poolAddress, uint256 shares) 
        external 
        view
        poolExists(poolAddress) 
        returns (uint256) 
    {
        uint256 navPerShare = _calculateNAVPerShareView(poolAddress);
        return (shares * navPerShare) / 1e18;
    }

    /**
     * @notice Calculate NAV per share (view-only, no state updates)
     * @dev Internal helper for ERC4626 conversion functions
     */
    function _calculateNAVPerShareView(address poolAddress) internal view returns (uint256 navPerShare) {
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        uint256 totalNAV = calculatePoolNAV(poolAddress);
        
        uint256 totalShares = IERC20(poolData.poolAddress).totalSupply();
        
        if (totalShares == 0) {
            return 1e18; 
        }      
        
        return (totalNAV * 1e18) / totalShares;
    }

    /**
     * @notice Get pending allocation details
     */
    function getPendingAllocation(bytes32 allocationId) external view returns (IStableYieldTypes.PendingAllocation memory) {
        return pendingAllocations[allocationId];
    }

    /**
     * @notice Get all pending allocation IDs for a pool
     */
    function getPoolPendingAllocations(address poolAddress) external view returns (bytes32[] memory) {
        return poolPendingAllocationIds[poolAddress];
    }

    /**
     * @notice Get total allocation to SPV across all pools
     */
    function getTotalSPVAllocation(address spvAddress) external view returns (uint256) {
        return totalSPVAllocations[spvAddress];
    }

    /**
     * @notice Get allocation from specific pool to SPV
     */
    function getPoolToSPVAllocation(address poolAddress, address spvAddress) external view returns (uint256) {
        return poolToSPVAllocations[poolAddress][spvAddress];
    }

    /**
     * @notice Get reserve configuration for a pool
     */
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

    /**
     * @notice Check pool allocation readiness and emit event if ready
     * @dev Can be called by anyone to signal pool readiness
     */
    function checkAndEmitPoolReadiness(address poolAddress) external poolExists(poolAddress) {
        (bool ready, uint256 available) = isReadyForAllocation(poolAddress);
        
        if (ready && available > 0) {
            emit PoolReadyForAllocation(poolAddress, available, block.timestamp);
        }
    }
}
