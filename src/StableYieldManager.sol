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
import "./interfaces/IFeeManager.sol";
import "./escrows/StableYieldEscrow.sol";
import "./types/IStableYieldTypes.sol";

/**
 * @title StableYieldManager
 * @dev  manages all business logic for managed pools
 * @notice Handles NAV calculation, deposit/withdrawal validation, queue management, and pool coordination
 */
contract StableYieldManager is 
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STATE VARIABLES //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    AccessManager public accessManager;
    IPoolRegistry public registry;
    address public timelockController;
    address public feeManager;
    
    uint256 public version;
    
    

    mapping(address => IStableYieldTypes.PoolData) public pools;
    
    mapping(address => IStableYieldTypes.InstrumentHolding[]) public poolInstruments;
    mapping(address => uint256) public poolInstrumentCount;
    mapping(address => uint256) public deferredFees;
    mapping(address => uint256) public lastFeeAccrual;
    
    mapping(address => IStableYieldTypes.WithdrawalQueue) public poolQueues;
    mapping(address => mapping(uint256 => IStableYieldTypes.WithdrawalRequest)) public withdrawalRequests;
    mapping(address => mapping(address => uint256[])) public userWithdrawalRequests;
    
    uint256 public constant MAX_APY = 5000; // 50% max APY
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant RESERVE_RATIO = 1000; // 10%
    

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EVENTS //////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    event PoolRegistered( address indexed poolAddress, address indexed escrowAddress, address indexed asset, string name );
    event FeeManagerUpdated(address oldFeeManager, address newFeeManager);
    event TransactionFeeCollected(address indexed poolAddress, string feeType, uint256 transactionAmount, uint256 feeAmount);
    event FeeSweptComplete(address indexed poolAddress, uint256 feeAmount, uint256 remainingAccrued);
    event FeeSweptPartial(address indexed poolAddress, uint256 paidAmount, uint256 deferredAmount);
    event FeeSweptDeferred(address indexed poolAddress, uint256 deferredAmount);
    
    event InstrumentPurchased(
        address indexed poolAddress,
        uint256 indexed instrumentId,
        IStableYieldTypes.InstrumentType instrumentType,
        uint256 purchasePrice,
        uint256 faceValue,
        uint256 maturityDate
    );
    
    event InstrumentMatured(
        address indexed poolAddress,
        uint256 indexed instrumentId,
        uint256 faceValue,
        uint256 realizedYield
    );
    
    event CouponPaymentReceived(
        address indexed poolAddress,
        uint256 indexed instrumentId,
        uint256 couponAmount,
        uint256 couponNumber
    );
    
    event NAVCalculated(
        address indexed poolAddress,
        uint256 totalNAV,
        uint256 navPerShare,
        uint256 totalShares,
        uint256 timestamp
    );
    
    event NAVUpdated(
        address indexed poolAddress,
        uint256 totalNAV,
        uint256 navPerShare,
        string reason,
        uint256 timestamp
    );
    
    event InstrumentRemoved( address indexed poolAddress,
        uint256 indexed instrumentId,
        uint256 finalValue,
        string reason
    );
    
    event PoolDeactivated(address indexed poolAddress, uint256 timestamp);
    
    event DepositValidated( address indexed poolAddress, address indexed user, uint256 amount, uint256 shares );
    
    event WithdrawalValidated( address indexed poolAddress, address indexed user, uint256 shares, uint256 value, bool immediate  );
    
    event WithdrawalQueued( address indexed poolAddress, address indexed user, uint256 indexed requestId, uint256 shares, uint256 estimatedValue);
    
    event WithdrawalProcessed( address indexed poolAddress, address indexed user, uint256 indexed requestId, uint256 actualValue, uint256 penaltyDeducted );
    
    
    event ReservesRebalanced( address indexed poolAddress, uint256 newReserve, uint256 totalAUM);
    
    event UserPositionsCleanedUp( address indexed poolAddress, address indexed user, uint256 removedCount );

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
     * @param feeManager_ FeeManager contract address
     */
    function initialize(
        address accessManager_,
        address registry_,
        address timelockController_,
        address feeManager_
    ) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        require(accessManager_ != address(0), "PoolManager/invalid access manager");
        require(registry_ != address(0), "PoolManager/invalid registry");
        require(timelockController_ != address(0), "PoolManager/invalid timelock");
        require(feeManager_ != address(0), "StableYieldManager/invalid fee manager");

        accessManager = AccessManager(accessManager_);
        registry = IPoolRegistry(registry_);
        timelockController = timelockController_;
        feeManager = feeManager_;
        version = 1;
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
    ) external onlyRole(accessManager.POOL_CREATOR_ROLE()) nonReentrant {
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
        deferredFees[poolAddress] = 0;
        lastFeeAccrual[poolAddress] = block.timestamp;

        registry.registerStableYieldPool(pools[poolAddress]); 

        if (feeManager != address(0)) {
          IFeeManager(feeManager).setDefaultExpenseRatio(poolAddress); 
        }
        
        emit PoolRegistered(poolAddress, escrowAddress, asset, name);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ADMIN FUNCTIONS //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////


    /**
     * @notice Update fee manager contract (admin only)
     * @param newFeeManager New fee manager address
     */
    function setFeeManager(address newFeeManager) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(newFeeManager != address(0), "StableYieldManager/invalid fee manager");
        
        address oldFeeManager = feeManager;
        feeManager = newFeeManager;
        
        emit FeeManagerUpdated(oldFeeManager, newFeeManager);
    }


    /**
     * @notice Collect monthly accrued fees with reserve safety ratios
     * @dev Uses cumulative deferred fee approach with liquidity-aware collection
     * @param poolAddress Pool address
     */
    function collectMonthlyFees(address poolAddress) external onlyRole(accessManager.OPERATOR_ROLE()) poolExists(poolAddress) {
        require(feeManager != address(0), "StableYieldManager/fee manager not set");
        
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        
        uint256 grossAssetValue = _calculateGrossAssetValue(poolAddress);
        uint256 poolReserves = escrow.getPoolReserves();
        uint256 cashBuffer = escrow.getCashBuffer();
        uint256 totalGrossValue = grossAssetValue + poolReserves;
        
        uint256 currentAccrued = _calculateCurrentAccruedFees(poolAddress, totalGrossValue) - deferredFees[poolAddress];
        uint256 totalOwed = deferredFees[poolAddress] + currentAccrued;
        
        if (totalOwed == 0) return;
        
        uint256 liquidityFloor = (totalGrossValue * 500) / 10000; // 5% 
        
        uint256 collectionAmount = _determineCollectionAmount(cashBuffer, poolReserves, liquidityFloor, totalOwed);
        
        if (collectionAmount > 0) {
            escrow.collectExpenseRatioFees(collectionAmount);
            
            deferredFees[poolAddress] = totalOwed - collectionAmount;
            lastFeeAccrual[poolAddress] = block.timestamp;
            
            if (collectionAmount == totalOwed) {
                emit FeeSweptComplete(poolAddress, collectionAmount, 0);
            } else {
                emit FeeSweptPartial(poolAddress, collectionAmount, deferredFees[poolAddress]);
            }
        } else {
            deferredFees[poolAddress] = totalOwed;
            lastFeeAccrual[poolAddress] = block.timestamp;
            emit FeeSweptDeferred(poolAddress, totalOwed);
        }
    }

    /**
     * @notice Determine collection amount based on liquidity safety constraints
     * @param cashBuffer Total cash available in escrow
     * @param poolReserves Available pool reserves (excludes allocated fees)
     * @param liquidityFloor Minimum liquidity buffer to maintain
     * @param totalOwed Total owed fees
     * @return collectionAmount Amount safe to collect
     */
    function _determineCollectionAmount(
        uint256 cashBuffer,
        uint256 poolReserves,
        uint256 liquidityFloor,
        uint256 totalOwed
    ) internal pure returns (uint256 collectionAmount) {
        if (totalOwed == 0) return 0;
        if (cashBuffer <= liquidityFloor) return 0; 

        uint256 availableLiquidity = cashBuffer - liquidityFloor;

        uint256 minRedemptionBuffer = (poolReserves * 1000) / 10000; // 10% 
        if (availableLiquidity <= minRedemptionBuffer) return 0;

        if (availableLiquidity >= totalOwed) {
            return totalOwed;
        }

        return (availableLiquidity * 8000) / 10000; // 80% 
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
        
        uint256 transactionFee = IFeeManager(feeManager).calculateProtocolFee(poolAddress, amount);
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
     * @return actualShares Shares actually processed (0 if queued)
     */
    function validateWithdrawal(
        address poolAddress,
        uint256 shares,
        address receiver,
        address owner
    ) external  poolExists(poolAddress) ActivePool(poolAddress) nonReentrant returns (uint256 actualShares, uint256 withdrawalValue) {
        require(msg.sender == poolAddress, "StableYieldManager/invalid caller");
         require(registry.isManagedPool(poolAddress), "StableYieldManager/invalid pool"); // check if duplicate with modifier
        require(shares > 0, "StableYieldManager/invalid shares");
        require(receiver != address(0), "StableYieldManager/invalid receiver");
        require(owner != address(0), "StableYieldManager/invalid owner");
        
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        require(poolData.isActive, "StableYieldManager/pool not active");
        
        uint256 navPerShare = calculateNAVPerShare(poolAddress);
        uint256 grossWithdrawalValue = (shares * navPerShare) / 1e18;
        
        uint256 transactionFee = IFeeManager(feeManager).calculateProtocolFee(poolAddress, grossWithdrawalValue);
        withdrawalValue = grossWithdrawalValue - transactionFee;
        
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        
        if (escrow.getPoolReserves() >= grossWithdrawalValue) {
            if (transactionFee > 0) {
                escrow.allocateWithdrawalFee(transactionFee);
                emit TransactionFeeCollected(poolAddress, "withdrawal", grossWithdrawalValue, transactionFee);
            }
            
            emit WithdrawalValidated(poolAddress, owner, shares, withdrawalValue, true);
            return (shares, withdrawalValue);
        } else {
            _queueWithdrawal(poolAddress, owner, shares, withdrawalValue);
            
            emit WithdrawalValidated(poolAddress, owner, shares, withdrawalValue, false);
            return (0, withdrawalValue); 
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
     * @notice Calculate pool NAV net of accrued fees
     * @dev Returns NAV that already accounts for time-based accrued fees
     * @param poolAddress Pool address
     * @return totalNAV Current NAV net of accrued fees
     */
    function calculatePoolNAV(address poolAddress) public view poolExists(poolAddress) returns (uint256 totalNAV) {
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        
        uint256 grossAssetValue = _calculateGrossAssetValue(poolAddress);
        uint256 poolReserves = escrow.getPoolReserves();
        uint256 totalGrossValue = grossAssetValue + poolReserves;
        
        uint256 accruedFees = _calculateCurrentAccruedFees(poolAddress, totalGrossValue);
        
        totalNAV = totalGrossValue > accruedFees ? totalGrossValue - accruedFees : 0;
        
        return totalNAV;
    }

    /**
     * @notice Calculate NAV per share
     * @param poolAddress Pool address
     * @return navPerShare NAV per share (normalized to 18 decimals)
     */
    function calculateNAVPerShare(address poolAddress) public view ActivePool(poolAddress) returns (uint256 navPerShare) {
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        uint256 totalNAV = calculatePoolNAV(poolAddress);
        
        uint256 totalShares = IERC20(poolData.poolAddress).totalSupply();
        
        uint8 assetDecimals = IERC20Metadata(poolData.asset).decimals();
        require(assetDecimals == 6 || assetDecimals == 18, "StableYieldManager/only 6 or 18 decimal stablecoins supported");
        
        if (totalShares == 0) {
            return 1e18; 
        }      
        // Normalize totalNAV from stablecoin decimals to 18 decimals
        // CNGN/USDT (6 decimals) -> multiply by 10^12, DAI (18 decimals) -> multiply by 1
        uint256 normalizedNAV = totalNAV * (10**(18 - assetDecimals));
        
        return normalizedNAV / totalShares;
    }

                                                                                                                                                                                            
    
    /**
     * @notice  gross asset value calculation
     * @param poolAddress Pool address                                                                                                                 
     * @return grossValue Total value of all instruments
     */
    function _calculateGrossAssetValue(address poolAddress) internal view returns (uint256 grossValue) {
        IStableYieldTypes.InstrumentHolding[] storage instruments = poolInstruments[poolAddress];
        uint256 length = instruments.length;
        
        uint256 currentTime = block.timestamp;
        
        for (uint256 i; i < length;) {
            IStableYieldTypes.InstrumentHolding storage instrument = instruments[i];
            
            if (instrument.instrumentType == IStableYieldTypes.InstrumentType.DISCOUNTED) {
                grossValue += _calculateDiscountedValue(instrument, currentTime);
            } else {
                grossValue += _calculateInterestBearingValue(instrument, currentTime);
            }
            
            unchecked { ++i; }
        }

        return grossValue;
    }
    
    /**
     * @notice Calculate current accrued fees for NAV-neutral pricing
     * @param poolAddress Pool address
     * @param totalGrossValue Total gross pool value
     * @return accruedFees Current accrued fees (including deferred)
     */
    function _calculateCurrentAccruedFees(address poolAddress, uint256 totalGrossValue) internal view returns (uint256 accruedFees) {
        if (feeManager == address(0)) return deferredFees[poolAddress];
        
        uint256 expenseRatioBps = IFeeManager(feeManager).getPoolExpenseRatio(poolAddress);
        if (expenseRatioBps == 0) return deferredFees[poolAddress];
        
        uint256 lastAccrual = lastFeeAccrual[poolAddress];
        if (lastAccrual == 0) lastAccrual = pools[poolAddress].createdAt;
        
        uint256 timeElapsed = block.timestamp - lastAccrual;
        if (timeElapsed == 0) return deferredFees[poolAddress];

        uint256 annualFee = (totalGrossValue * expenseRatioBps) / 10000;
        uint256 currentAccrued = (annualFee * timeElapsed) / SECONDS_PER_YEAR;
        
        return deferredFees[poolAddress] + currentAccrued;
    }

    /**
     * @notice  discounted instrument value calculation
     * @param instrument Instrument data
     * @param currentTime Current timestamp
     * @return value Current value of discounted instrument
     */
    function _calculateDiscountedValue(IStableYieldTypes.InstrumentHolding storage instrument, uint256 currentTime) internal view returns (uint256 value) {
        uint256 timeElapsed = currentTime - instrument.purchaseDate;
        uint256 totalTime = instrument.maturityDate - instrument.purchaseDate;
        
        if (timeElapsed >= totalTime) {
            return instrument.faceValue;
        }
        
        return instrument.purchasePrice + ((instrument.faceValue - instrument.purchasePrice) * timeElapsed) / totalTime;
    }
    
    /**
     * @notice interest-bearing instrument value calculation
     * @param instrument Instrument data
     * @param currentTime Current timestamp
     * @return value Current value including accrued interest
     */
    function _calculateInterestBearingValue(IStableYieldTypes.InstrumentHolding storage instrument, uint256 currentTime) internal view returns (uint256 value) {
        uint256 couponPeriodSeconds = SECONDS_PER_YEAR / instrument.couponFrequency;
        uint256 lastCouponDate = instrument.couponsPaid == 0 ? 
            instrument.purchaseDate : 
            instrument.nextCouponDueDate - couponPeriodSeconds;
        
        uint256 timeSinceLastCoupon = currentTime - lastCouponDate;
        uint256 couponAmount = (instrument.faceValue * instrument.annualCouponRate) / (10000 * instrument.couponFrequency);
        
        // Accrued interest = (couponAmount * timeSinceLastCoupon) / couponPeriodSeconds
        uint256 accruedInterest = (couponAmount * timeSinceLastCoupon) / couponPeriodSeconds;
        
        return instrument.faceValue + accruedInterest;
    }


     ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// SPV FUNCTIONS ///////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Add new instrument to pool (SPV attestation)
     * @param poolAddress Pool address
     * @param instrumentType Type of instrument (DISCOUNTED or INTEREST_BEARING)
     * @param purchasePrice Amount paid for instrument
     * @param faceValue Maturity value
     * @param maturityDate When instrument matures
     * @param annualCouponRate Annual coupon rate in basis points (0 for T-bills)
     * @param couponFrequency Coupon frequency (0 for T-bills)
     */
    function addInstrument(
        address poolAddress,
        IStableYieldTypes.InstrumentType instrumentType,
        uint256 purchasePrice,
        uint256 faceValue,
        uint256 maturityDate,
        uint256 annualCouponRate,
        uint8 couponFrequency // 0=T-bill, 2=semi-annual, 4=quarterly, 12=monthly
    ) external onlyRole(accessManager.SPV_ROLE()) poolExists(poolAddress) nonReentrant {
        require(purchasePrice > 0, "StableYieldManager/invalid purchase price");
        require(faceValue > 0, "StableYieldManager/invalid face value");
        require(maturityDate > block.timestamp, "StableYieldManager/invalid maturity date");
        
        if (instrumentType == IStableYieldTypes.InstrumentType.DISCOUNTED) {
            require(purchasePrice < faceValue, "StableYieldManager/discounted must be below face");
            require(annualCouponRate == 0, "StableYieldManager/discounted has no coupons");
            require(couponFrequency == 0, "StableYieldManager/discounted has no coupons");
        } else {
            require(annualCouponRate > 0, "StableYieldManager/interest bearing needs coupon rate");
            require(couponFrequency > 0, "StableYieldManager/interest bearing needs frequency");
        }

        uint256 nextCouponDate = 0;
        if (instrumentType == IStableYieldTypes.InstrumentType.INTEREST_BEARING) {
            uint256 couponPeriodSeconds = (365 days) / couponFrequency;
            nextCouponDate = block.timestamp + couponPeriodSeconds; // are we insinuating coupon frequency is in seconds?
        }
        
        poolInstruments[poolAddress].push(IStableYieldTypes.InstrumentHolding({
            instrumentType: instrumentType,
            purchasePrice: purchasePrice,
            faceValue: faceValue,
            purchaseDate: block.timestamp,
            maturityDate: maturityDate,
            annualCouponRate: annualCouponRate,
            couponFrequency: couponFrequency,
            nextCouponDueDate: nextCouponDate,
            couponsPaid: 0,
            isActive: true
        }));
        
        uint256 instrumentId = poolInstruments[poolAddress].length - 1;
        poolInstrumentCount[poolAddress]++;
        
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        require(escrow.getPoolReserves() >= purchasePrice, "StableYieldManager/insufficient cash");
        
        emit InstrumentPurchased(poolAddress, instrumentId, instrumentType, purchasePrice, faceValue, maturityDate);
        
        _triggerNAVUpdate(poolAddress, "instrument_added");
    }

    /**
     * @notice Process matured instrument and remove from active tracking
     * @param poolAddress Pool address
     * @param instrumentId Instrument ID
     */
    function matureInstrument(
        address poolAddress,
        uint256 instrumentId
    ) external onlyRole(accessManager.SPV_ROLE()) poolExists(poolAddress) nonReentrant {
        IStableYieldTypes.InstrumentHolding[] storage instruments = poolInstruments[poolAddress];
        require(instrumentId < instruments.length, "StableYieldManager/invalid instrument");
        
        IStableYieldTypes.InstrumentHolding storage instrument = instruments[instrumentId];
        require(instrument.isActive, "StableYieldManager/instrument not active");
        require(block.timestamp >= instrument.maturityDate, "StableYieldManager/not matured");
        
        uint256 realizedYield = instrument.faceValue - instrument.purchasePrice;
        uint256 finalValue = instrument.faceValue;
        
        _removeInstrument(poolAddress, instrumentId, "matured");
        
        emit InstrumentMatured(poolAddress, instrumentId, finalValue, realizedYield);

        _triggerNAVUpdate(poolAddress, "instrument_matured");
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
        require(instrumentId < poolInstruments[poolAddress].length, "StableYieldManager/invalid instrument");
        
        IStableYieldTypes.InstrumentHolding storage instrument = poolInstruments[poolAddress][instrumentId];
        require(instrument.isActive, "StableYieldManager/instrument not active");
        require(instrument.instrumentType == IStableYieldTypes.InstrumentType.INTEREST_BEARING, "StableYieldManager/not interest bearing");
        require(block.timestamp >= instrument.nextCouponDueDate, "StableYieldManager/coupon not due");

        
        instrument.couponsPaid++;
        
        if (block.timestamp < instrument.maturityDate) {
            uint256 couponPeriodSeconds = (365 days) / instrument.couponFrequency;
            instrument.nextCouponDueDate += couponPeriodSeconds;
        }
        
        emit CouponPaymentReceived(poolAddress, instrumentId, couponAmount, instrument.couponsPaid);
        
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
        uint256 totalNAV = calculatePoolNAV(poolAddress);
        uint256 totalShares = IERC20(pools[poolAddress].poolAddress).totalSupply();
        uint256 navPerShare = calculateNAVPerShare(poolAddress);
        
        emit NAVUpdated(poolAddress, totalNAV, navPerShare, reason, block.timestamp);
        emit NAVCalculated(poolAddress, totalNAV, navPerShare, totalShares, block.timestamp);
    }

     /**
     * @notice Batch remove multiple matured instruments (SPV )
     * @param poolAddress Pool address
     * @param instrumentIds Array of instrument IDs to remove
     */
    function batchMatureInstruments(
        address poolAddress,
        uint256[] calldata instrumentIds
    ) external onlyRole(accessManager.SPV_ROLE()) poolExists(poolAddress) nonReentrant {
        require(instrumentIds.length > 0, "StableYieldManager/empty batch");
        require(instrumentIds.length <= 50, "StableYieldManager/batch too large"); 
        
        uint256 totalMaturedValue = 0;
        
        for (uint256 i = instrumentIds.length; i > 0;) {
            unchecked { --i; }
            
            uint256 instrumentId = instrumentIds[i];
            IStableYieldTypes.InstrumentHolding[] storage instruments = poolInstruments[poolAddress];
            require(instrumentId < instruments.length, "StableYieldManager/invalid instrument");
            
            IStableYieldTypes.InstrumentHolding storage instrument = instruments[instrumentId];
            require(instrument.isActive, "StableYieldManager/instrument not active");
            require(block.timestamp >= instrument.maturityDate, "StableYieldManager/not matured");
            
            uint256 realizedValue = instrument.faceValue;
            totalMaturedValue += realizedValue;
            
            emit InstrumentMatured(poolAddress, instrumentId, realizedValue, realizedValue - instrument.purchasePrice);

            _removeInstrument(poolAddress, instrumentId, "batch_matured");
        }
        
        _triggerNAVUpdate(poolAddress, "batch_instrument_matured");
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

    /**
     * @notice Allocate funds to SPV for instrument purchases (Operator only)
     * @param poolAddress Pool address
     * @param spvAddress SPV address
     * @param amount Amount to allocate
     */
    function allocateToSPV(
        address poolAddress,
        address spvAddress,
        uint256 amount
    ) external onlyRole(accessManager.OPERATOR_ROLE()) poolExists(poolAddress) nonReentrant {
        require(spvAddress != address(0), "StableYieldManager/invalid SPV");
        require(amount > 0, "StableYieldManager/invalid amount");
        
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        
        require(escrow.getCashBuffer() >= amount, "StableYieldManager/insufficient cash buffer");
        
        escrow.allocateToSPV(spvAddress, amount);
        
        _triggerNAVUpdate(poolAddress, "spv_allocation");
    }

    /**
     * @notice Receive matured instrument proceeds from SPV
     * @param poolAddress Pool address
     * @param amount Amount received from matured instruments
     */
    function receiveSPVMaturity(
        address poolAddress,
        uint256 amount
    ) external onlyRole(accessManager.SPV_ROLE()) poolExists(poolAddress) nonReentrant {
        require(amount > 0, "StableYieldManager/invalid amount");
        
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        
        // SPV transfers funds back to escrow
        escrow.receiveSPVLiquidity(amount);
        
        _triggerNAVUpdate(poolAddress, "spv_maturity_received");
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
     * @notice Rebalance pool reserves to maintain target ratio(note: this function will be used for porion v1.2)
     * @dev Coordinates with SPV to liquidate instruments or invest excess cash
     * @param poolAddress Pool to rebalance
     * @param action 0 = liquidate instruments (need more cash), 1 = invest excess cash
     * @param amount Amount to liquidate or invest
     */
    function rebalancePoolReserves(
        address poolAddress, 
        uint8 action,
        uint256 amount
    ) external onlyRole(accessManager.OPERATOR_ROLE()) poolExists(poolAddress) nonReentrant {
        require(action <= 1, "StableYieldManager/invalid action");
        require(amount > 0, "StableYieldManager/invalid amount");
        
        uint256 totalNAV = calculatePoolNAV(poolAddress);
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        
        uint256 targetReserve = (totalNAV * RESERVE_RATIO) / 10000;
        uint256 currentReserve = escrow.getPoolReserves();
        
        if (action == 0) {
            require(currentReserve < targetReserve, "StableYieldManager/reserves already sufficient");
            require(amount <= (targetReserve - currentReserve), "StableYieldManager/excessive liquidation");
            
            
        } else {
            require(currentReserve > targetReserve, "StableYieldManager/no excess reserves");
            require(amount <= (currentReserve - targetReserve), "StableYieldManager/excessive investment");
            require(escrow.getPoolReserves() >= amount, "StableYieldManager/insufficient cash");
        }
        
        emit ReservesRebalanced(poolAddress, escrow.getPoolReserves(), totalNAV);

        _triggerNAVUpdate(poolAddress, action == 0 ? "reserves_liquidated" : "reserves_invested");
    }
    
    /**
     * @notice Get current reserve status for a pool
     * @param poolAddress Pool address
     * @return currentReserve Current cash reserves
     * @return targetReserve Target cash reserves (10% of NAV)
     * @return reserveRatio Current reserve ratio in basis points
     * @return rebalanceNeeded Whether rebalancing is needed
     */
    function getReserveStatus(address poolAddress) 
        external 
        view
        poolExists(poolAddress) 
        returns (
            uint256 currentReserve,
            uint256 targetReserve, 
            uint256 reserveRatio,
            bool rebalanceNeeded
        ) 
    {
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
        
        uint256 totalNAV = calculatePoolNAV(poolAddress);
        currentReserve = escrow.getPoolReserves();
        targetReserve = (totalNAV * RESERVE_RATIO) / 10000;
        
        if (totalNAV > 0) {
            reserveRatio = (currentReserve * 10000) / totalNAV;
                } else {
            reserveRatio = 0;
        }
        
        // Need rebalancing if reserves are off by more than 2%
        uint256 tolerance = 200; // 2% in basis points
        rebalanceNeeded = reserveRatio < (RESERVE_RATIO - tolerance) || 
                         reserveRatio > (RESERVE_RATIO + tolerance);
    }





    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// VIEW FUNCTIONS ///////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

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
        
        uint8 assetDecimals = IERC20Metadata(poolData.asset).decimals();
        require(assetDecimals == 6 || assetDecimals == 18, "StableYieldManager/only 6 or 18 decimal stablecoins supported");
        
        if (totalShares == 0) {
            return 1e18; 
        }      
        // Normalize totalNAV from stablecoin decimals to 18 decimals
        uint256 normalizedNAV = totalNAV * (10**(18 - assetDecimals));
        
        return normalizedNAV / totalShares;
    }
        
    
}