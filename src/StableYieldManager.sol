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
    address public treasury;
    
    uint256 public version;
    

    mapping(address => IStableYieldTypes.PoolData) public pools;
    mapping(address => bool) public isRegisteredPool; // we handle this in registry
    
    mapping(address => IStableYieldTypes.InstrumentHolding[]) public poolInstruments;
    mapping(address => uint256) public poolInstrumentCount;
    mapping(address => uint256) public poolCashReserve;
    
    mapping(address => IStableYieldTypes.WithdrawalQueue) public poolQueues;
    mapping(address => mapping(uint256 => IStableYieldTypes.WithdrawalRequest)) public withdrawalRequests;
    mapping(address => mapping(address => uint256[])) public userWithdrawalRequests;
    
    mapping(address => mapping(address => IStableYieldTypes.LockedPosition[])) public userLockedPositions;
    
    uint256 public constant MINIMUM_LOCK_DAYS = 30;
    uint256 public constant EARLY_EXIT_PENALTY_BPS = 500; // 5%
    uint256 public constant MAX_APY = 5000; // 50% max APY
    uint256 public constant MANAGEMENT_FEE_BPS = 200; // 2% annual management fee
    uint256 public constant PERFORMANCE_FEE_BPS = 1000; // 10% performance fee
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant RESERVE_RATIO = 1000; // 10%
    

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EVENTS //////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    event PoolRegistered( address indexed poolAddress, address indexed escrowAddress, address indexed asset, bool isLocked, string name );
    
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
    
    event InstrumentRemoved(
        address indexed poolAddress,
        uint256 indexed instrumentId,
        uint256 finalValue,
        string reason
    );
    
    event PoolDeactivated(address indexed poolAddress, uint256 timestamp);
    
    event DepositValidated( address indexed poolAddress, address indexed user, uint256 amount, uint256 shares, uint256 tenorDays );
    
    event WithdrawalValidated( address indexed poolAddress, address indexed user, uint256 shares, uint256 value, bool immediate  );
    
    event WithdrawalQueued( address indexed poolAddress, address indexed user, uint256 indexed requestId, uint256 shares, uint256 estimatedValue);
    
    event WithdrawalProcessed( address indexed poolAddress, address indexed user, uint256 indexed requestId, uint256 actualValue, uint256 penaltyDeducted );
    
    event LockedPositionCreated( address indexed poolAddress, address indexed user, uint256 positionIndex, uint256 shares, uint256 tenorDays, uint256 maturityTime );
    
    event LockedPositionMatured( address indexed poolAddress, address indexed user, uint256 positionIndex, uint256 finalValue, bool autoRollover  );
    
    event PenaltyCollected( address indexed poolAddress, address indexed user, uint256 penaltyAmount, uint256 totalCollected );
    
    event ReservesRebalanced( address indexed poolAddress, uint256 newReserve, uint256 totalAUM);

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// MODIFIERS ///////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    modifier onlyRegisteredPool() {
        require(isRegisteredPool[msg.sender], "PoolManager/not registered pool");  // refactor to use registry check when weve refactored registry
        _;
    }
    
    
    
    modifier poolExists(address poolAddress) { //repititive
        require(isRegisteredPool[poolAddress], "PoolManager/pool not found");
        _;
    }

     modifier ActivePool (address poolAddress) { // replace pool exist with this maybe
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
     * @param treasury_ Treasury address for fees and penalties
     */
    function initialize(
        address accessManager_,
        address registry_,
        address timelockController_,
        address treasury_
    ) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        require(accessManager_ != address(0), "PoolManager/invalid access manager");
        require(registry_ != address(0), "PoolManager/invalid registry");
        require(timelockController_ != address(0), "PoolManager/invalid timelock");
        require(treasury_ != address(0), "PoolManager/invalid treasury");

        accessManager = AccessManager(accessManager_);
        registry = IPoolRegistry(registry_);
        timelockController = timelockController_;
        treasury = treasury_;
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
     * @notice Register a new managed pool
     * @param poolAddress Pool contract address
     * @param escrowAddress Escrow contract address
     * @param asset Underlying asset address
     * @param isLocked Whether this is a locked pool
     * @param name Pool name
     * @param description Pool description
     * @param supportedTenors Supported tenors (empty for flexible/non locked pools)
     */
    function registerPool(
        address poolAddress,
        address escrowAddress,
        address asset,
        bool isLocked,
        string memory name,
        string memory description,
        uint256[] memory supportedTenors,
        uint256 minInvestment
    ) external onlyRole(accessManager.POOL_CREATOR_ROLE()) nonReentrant {
        require(poolAddress != address(0), "PoolManager/invalid pool");
        require(escrowAddress != address(0), "PoolManager/invalid escrow");
        require(asset != address(0), "PoolManager/invalid asset");
        require(!isRegisteredPool[poolAddress], "PoolManager/pool already registered"); // fix
        require(minInvestment > 0, "PoolManager/invalid min investment");
        
        // Validate stablecoin decimals
        uint8 assetDecimals = IERC20Metadata(asset).decimals();
        require(assetDecimals == 6 || assetDecimals == 18, "PoolManager/only 6 or 18 decimal stablecoins supported");
        
        require(registry.isApprovedAsset(asset), "PoolManager/asset not approved"); // errounous because we have not refactored our registry to work with this new version
        
        if (isLocked) {
            require(supportedTenors.length > 0, "PoolManager/locked pool needs tenors");
            for (uint256 i = 0; i < supportedTenors.length; i++) {
                require(_isValidTenor(supportedTenors[i]), "PoolManager/invalid tenor");
            }
        }
        
        pools[poolAddress] = IStableYieldTypes.PoolData({
            poolAddress: poolAddress,
            escrowAddress: escrowAddress,
            asset: asset,
            isLocked: isLocked,
            name: name,
            description: description,
            supportedTenors: supportedTenors,
            minInvestment: minInvestment,
            isActive: true,
            createdAt: block.timestamp
        });
        
        poolQueues[poolAddress] = IStableYieldTypes.WithdrawalQueue({
            head: 0,
            tail: 0,
            totalPendingValue: 0
        });
        
        isRegisteredPool[poolAddress] = true; // revise to remove when registry is ready
        
        emit PoolRegistered(poolAddress, escrowAddress, asset, isLocked, name);
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
    ) external onlyRegisteredPool poolExists(poolAddress) nonReentrant returns (uint256 shares) { // add a modifier for active pools
        require(msg.sender == poolAddress, "StableYieldManager/invalid caller"); // fix after updating the registry
        
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        require(!poolData.isLocked, "StableYieldManager/use validateLockedDeposit");
        require(amount >= poolData.minInvestment, "StableYieldManager/below minimum");
        require(receiver != address(0), "StableYieldManager/invalid receiver");
        
        uint256 navPerShare = calculateNAVPerShare(poolAddress);
        shares = (amount * 1e18) / navPerShare;
        
        poolCashReserve[poolAddress] += amount;
        
        emit DepositValidated(poolAddress, receiver, amount, shares, 0);
        
        return shares;
    }

    /**
     * @notice Validate and process deposit for locked pool
     * @param poolAddress Pool receiving deposit
     * @param amount Amount being deposited
     * @param tenorDays Lock period in days
     * @param autoRollover Whether to auto-rollover at maturity
     * @param receiver Share recipient
     * @return shares Number of shares to mint
     */
    function validateLockedDeposit(
        address poolAddress,
        uint256 amount,
        uint256 tenorDays,
        bool autoRollover,
        address receiver
    ) external onlyRegisteredPool poolExists(poolAddress) nonReentrant returns (uint256 shares) {
        require(msg.sender == poolAddress, "StableYieldManager/invalid caller");
        
        IStableYieldTypes.PoolData storage pool = pools[poolAddress];
        require(pool.isActive, "StableYieldManager/pool not active");
        require(pool.isLocked, "StableYieldManager/use validateDeposit");
        require(amount >= pool.minInvestment, "StableYieldManager/below minimum");
        require(receiver != address(0), "StableYieldManager/invalid receiver");
        require(_isValidTenorForPool(poolAddress, tenorDays), "StableYieldManager/invalid tenor");
        
        // Calculate shares based on current NAV
        uint256 navPerShare = calculateNAVPerShare(poolAddress);
        shares = (amount * 1e18) / navPerShare;
        
        // Create locked position
        uint256 maturityTime = block.timestamp + (tenorDays * 1 days);
        userLockedPositions[poolAddress][receiver].push(IStableYieldTypes.LockedPosition({
            shares: shares,
            principal: amount,
            tenorDays: tenorDays,
            depositTime: block.timestamp,
            maturityTime: maturityTime,
            autoRollover: autoRollover,
            isActive: true
        }));
        
        uint256 positionIndex = userLockedPositions[poolAddress][receiver].length - 1;
        
        // Note: Pool contract (ERC20) handles totalSupply when minting shares
        poolCashReserve[poolAddress] += amount;
        
        emit DepositValidated(poolAddress, receiver, amount, shares, tenorDays);
        emit LockedPositionCreated(poolAddress, receiver, positionIndex, shares, tenorDays, maturityTime);
        
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
    ) external onlyRegisteredPool poolExists(poolAddress) nonReentrant returns (uint256 actualShares) {
        require(msg.sender == poolAddress, "StableYieldManager/invalid caller");
        require(shares > 0, "StableYieldManager/invalid shares");
        require(receiver != address(0), "StableYieldManager/invalid receiver");
        require(owner != address(0), "StableYieldManager/invalid owner");
        
        IStableYieldTypes.PoolData storage pool = pools[poolAddress];
        require(pool.isActive, "StableYieldManager/pool not active");
        
        // Calculate withdrawal value based on current NAV
        uint256 navPerShare = calculateNAVPerShare(poolAddress);
        uint256 withdrawalValue = (shares * navPerShare) / 1e18;
        
        // Check if withdrawal can be processed immediately
        if (poolCashReserve[poolAddress] >= withdrawalValue) {
            // Note: Pool contract (ERC20) handles totalSupply when burning shares
            poolCashReserve[poolAddress] -= withdrawalValue;
            
            emit WithdrawalValidated(poolAddress, owner, shares, withdrawalValue, true);
            return shares;
        } else {
            // Queue withdrawal
            _queueWithdrawal(poolAddress, owner, receiver, shares, withdrawalValue, false, 0);
            
            emit WithdrawalValidated(poolAddress, owner, shares, withdrawalValue, false);
            return 0; // Queued, no immediate processing
        }
    }

    /**
     * @notice Process early exit from locked position
     * @param poolAddress Pool processing withdrawal
     * @param shares Number of shares to redeem
     * @param receiver Recipient of assets
     * @param owner Share owner
     * @return actualShares Shares actually processed (0 if queued)
     */
    function validateEarlyExit(
        address poolAddress,
        uint256 shares,
        address receiver,
        address owner
    ) external onlyRegisteredPool poolExists(poolAddress) nonReentrant returns (uint256 actualShares) {
        require(msg.sender == poolAddress, "PoolManager/invalid caller");
        require(shares > 0, "PoolManager/invalid shares");
        
        IStableYieldTypes.PoolData storage pool = pools[poolAddress];
        require(pool.isActive, "PoolManager/pool not active");
        require(pool.isLocked, "PoolManager/not a locked pool");
        
        // Find eligible positions (past minimum lock period)
        uint256 eligibleShares = _getEligibleShares(poolAddress, owner);
        require(shares <= eligibleShares, "PoolManager/exceeds eligible shares");
        
        // NAV is calculated dynamically, no need to update
        
        // Calculate withdrawal value and penalty
        uint256 navPerShare = calculateNAVPerShare(poolAddress);
        uint256 withdrawalValue = (shares * navPerShare) / 1e18;
        uint256 penaltyAmount = (withdrawalValue * EARLY_EXIT_PENALTY_BPS) / 10000;
        uint256 netValue = withdrawalValue - penaltyAmount;
        
        // Check if withdrawal can be processed immediately
        if (poolCashReserve[poolAddress] >= netValue) {
            // Process immediately
            _processEarlyExit(poolAddress, owner, shares, withdrawalValue, penaltyAmount);
            
            emit WithdrawalValidated(poolAddress, owner, shares, netValue, true);
            return shares;
        } else {
            // Queue withdrawal with penalty
            _queueWithdrawal(poolAddress, owner, receiver, shares, withdrawalValue, true, penaltyAmount);
            
            emit WithdrawalValidated(poolAddress, owner, shares, netValue, false);
            return 0; // Queued
        }
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// QUEUE MANAGEMENT //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Process queued withdrawals for a pool
     * @param poolAddress Pool to process withdrawals for
     * @param maxRequests Maximum number of requests to process
     * @return processed Number of requests processed
     */
    function processWithdrawalQueue(address poolAddress, uint256 maxRequests) 
        external 
        onlyRole(accessManager.OPERATOR_ROLE()) 
        poolExists(poolAddress) 
        nonReentrant 
        returns (uint256 processed) 
    {
        IStableYieldTypes.WithdrawalQueue storage queue = poolQueues[poolAddress];
        
        uint256 requestsProcessed = 0;
        uint256 currentHead = queue.head;
        
        while (requestsProcessed < maxRequests && currentHead < queue.tail && poolCashReserve[poolAddress] > 0) {
            IStableYieldTypes.WithdrawalRequest storage request = withdrawalRequests[poolAddress][currentHead];
            
            if (!request.processed) {
                uint256 netValue = request.estimatedValue - request.penaltyAmount;
                
                if (poolCashReserve[poolAddress] >= netValue) {
                    // Process this request
                    _processQueuedWithdrawal(poolAddress, currentHead);
                    requestsProcessed++;
                }
            }
            
            currentHead++;
        }
        
        // Update queue head
        queue.head = currentHead;
        
        return requestsProcessed;
    }


    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// NAV CALCULATION //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Calculate current NAV for a pool 
     * @param poolAddress Pool address
     * @return totalNAV Total NAV of the pool after fees
     */
    function calculatePoolNAV(address poolAddress) public view poolExists(poolAddress) returns (uint256 totalNAV) {

        uint256 timeElapsed = block.timestamp - pools[poolAddress].createdAt;
        
        uint256 grossAssetValue = _calculateGrossAssetValue(poolAddress);
    
        uint256 totalGrossValue = grossAssetValue + poolCashReserve[poolAddress];
        
        uint256 managementFees = _calculateAccruedManagementFees(totalGrossValue, timeElapsed);
        
        totalNAV = totalGrossValue > managementFees ? totalGrossValue - managementFees : 0;
        
        return totalNAV;
    }

    /**
     * @notice Calculate NAV per share
     * @param poolAddress Pool address
     * @return navPerShare NAV per share (normalized to 18 decimals)
     */
    function calculateNAVPerShare(address poolAddress) public view poolExists(poolAddress) returns (uint256 navPerShare) {
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
     * @notice Update and emit NAV calculation
     * @param poolAddress Pool address
     */
    function updateNAVCalculation(address poolAddress) external onlyRole(accessManager.OPERATOR_ROLE()) poolExists(poolAddress) {
        uint256 totalNAV = calculatePoolNAV(poolAddress);
        uint256 totalShares = IERC20(pools[poolAddress].poolAddress).totalSupply();
        uint256 navPerShare = calculateNAVPerShare(poolAddress);
        
        emit NAVCalculated(poolAddress, totalNAV, navPerShare, totalShares, block.timestamp);
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
     * @notice Calculate accrued management fees
     * @param totalValue Total pool value
     * @param poolAge Pool age in seconds
     * @return fees Accrued management fees
     */
    function _calculateAccruedManagementFees(uint256 totalValue, uint256 poolAge) internal pure returns (uint256 fees) {
        // Management fee = (totalValue * MANAGEMENT_FEE_BPS * poolAge) / (10000 * SECONDS_PER_YEAR)
        return (totalValue * MANAGEMENT_FEE_BPS * poolAge) / (10000 * SECONDS_PER_YEAR);
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
    /////////////////////////////// INSTRUMENT MANAGEMENT ///////////////////////
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
        uint8 couponFrequency
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
        
        // Calculate next coupon date for interest-bearing instruments
        uint256 nextCouponDate = 0;
        if (instrumentType == IStableYieldTypes.InstrumentType.INTEREST_BEARING) {
            uint256 couponPeriodSeconds = (365 days) / couponFrequency;
            nextCouponDate = block.timestamp + couponPeriodSeconds;
        }
        
        // Add instrument
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
        
        // Update cash reserve (reduce by purchase amount)
        require(poolCashReserve[poolAddress] >= purchasePrice, "StableYieldManager/insufficient cash");
        poolCashReserve[poolAddress] -= purchasePrice;
        
        emit InstrumentPurchased(poolAddress, instrumentId, instrumentType, purchasePrice, faceValue, maturityDate);
        
        // Trigger NAV update after new instrument
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
        
        // Add face value back to cash reserve
        poolCashReserve[poolAddress] += finalValue;
        
        // Remove instrument from array (gas-efficient removal)
        _removeInstrument(poolAddress, instrumentId, "matured");
        
        emit InstrumentMatured(poolAddress, instrumentId, finalValue, realizedYield);
        
        // Trigger NAV update after maturity
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
        
        // Add coupon to cash reserve
        poolCashReserve[poolAddress] += couponAmount;
        
        // Update coupon tracking
        instrument.couponsPaid++;
        
        // Calculate next coupon date
        if (block.timestamp < instrument.maturityDate) {
            uint256 couponPeriodSeconds = (365 days) / instrument.couponFrequency;
            instrument.nextCouponDueDate += couponPeriodSeconds;
        }
        
        emit CouponPaymentReceived(poolAddress, instrumentId, couponAmount, instrument.couponsPaid);
        
        // Trigger NAV update after coupon payment
        _triggerNAVUpdate(poolAddress, "coupon_received");
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
     * @notice Get user locked positions
     */
    function getUserLockedPositions(address poolAddress, address user) 
        external 
        view 
        poolExists(poolAddress) 
        returns (IStableYieldTypes.LockedPosition[] memory) 
    {
        return userLockedPositions[poolAddress][user];
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

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INTERNAL FUNCTIONS ///////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Calculate current value of an instrument
     * @param instrument Instrument data
     * @return currentValue Current accrued value
     */
    // Old _calculateInstrumentCurrentValue and _calculateAccruedInterest functions removed
    // Logic integrated into gas-optimized _calculateDiscountedValue and _calculateInterestBearingValue

    /**
     * @notice Queue a withdrawal request
     */
    function _queueWithdrawal(
        address poolAddress,
        address user,
        address /* receiver */,
        uint256 shares,
        uint256 estimatedValue,
        bool isPenalized,
        uint256 penaltyAmount
    ) internal {
        IStableYieldTypes.WithdrawalQueue storage queue = poolQueues[poolAddress];
        
        uint256 requestId = queue.tail++;
        withdrawalRequests[poolAddress][requestId] = IStableYieldTypes.WithdrawalRequest({
            user: user,
            shares: shares,
            requestTime: block.timestamp,
            estimatedValue: estimatedValue,
            isPenalized: isPenalized,
            penaltyAmount: penaltyAmount,
            processed: false,
            processedTime: 0
        });
        
        userWithdrawalRequests[poolAddress][user].push(requestId);
        queue.totalPendingValue += estimatedValue;
        
        emit WithdrawalQueued(poolAddress, user, requestId, shares, estimatedValue);
    }

    /**
     * @notice Process a queued withdrawal
     */
    function _processQueuedWithdrawal(address poolAddress, uint256 requestId) internal {
        IStableYieldTypes.WithdrawalRequest storage request = withdrawalRequests[poolAddress][requestId];
        
        uint256 netValue = request.estimatedValue - request.penaltyAmount;
        
        // Note: Pool contract (ERC20) handles totalSupply when burning shares
        // totalAUM is calculated dynamically from instruments
        poolCashReserve[poolAddress] -= netValue;
        
        // Handle penalty
        if (request.penaltyAmount > 0) {
            // Penalty stays in pool as protocol revenue
            emit PenaltyCollected(poolAddress, request.user, request.penaltyAmount, request.penaltyAmount);
        }
        
        // Mark as processed
        request.processed = true;
        request.processedTime = block.timestamp;
        
        // Update queue
        poolQueues[poolAddress].totalPendingValue -= request.estimatedValue;
        
        emit WithdrawalProcessed(poolAddress, request.user, requestId, netValue, request.penaltyAmount);
    }

    /**
     * @notice Process early exit immediately
     */
    function _processEarlyExit(
        address poolAddress,
        address user,
        uint256 shares,
        uint256 withdrawalValue,
        uint256 penaltyAmount
    ) internal {
        uint256 netValue = withdrawalValue - penaltyAmount;
        
        // Note: Pool contract (ERC20) handles totalSupply when burning shares
        // totalAUM is calculated dynamically from instruments
        poolCashReserve[poolAddress] -= netValue;
        
        // Deactivate locked positions
        _deactivateLockedShares(poolAddress, user, shares);
        
        // Handle penalty
        if (penaltyAmount > 0) {
            emit PenaltyCollected(poolAddress, user, penaltyAmount, penaltyAmount);
        }
    }

    /**
     * @notice Get eligible shares for early exit
     */
    function _getEligibleShares(address poolAddress, address user) internal view returns (uint256) {
        IStableYieldTypes.LockedPosition[] storage positions = userLockedPositions[poolAddress][user];
        uint256 eligible = 0;
        
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].isActive && 
                block.timestamp >= positions[i].depositTime + (MINIMUM_LOCK_DAYS * 1 days)) {
                eligible += positions[i].shares;
            }
        }
        
        return eligible;
    }

    /**
     * @notice Deactivate locked shares for withdrawal
     */
    function _deactivateLockedShares(address poolAddress, address user, uint256 sharesToDeactivate) internal {
        IStableYieldTypes.LockedPosition[] storage positions = userLockedPositions[poolAddress][user];
        uint256 remaining = sharesToDeactivate;
        
        for (uint256 i = 0; i < positions.length && remaining > 0; i++) {
            if (positions[i].isActive && 
                block.timestamp >= positions[i].depositTime + (MINIMUM_LOCK_DAYS * 1 days)) {
                
                if (positions[i].shares <= remaining) {
                    remaining -= positions[i].shares;
                    positions[i].isActive = false;
                } else {
                    positions[i].shares -= remaining;
                    remaining = 0;
                }
            }
        }
    }

    /**
     * @notice Check if tenor is valid
     */
    function _isValidTenor(uint256 tenorDays) internal pure returns (bool) {
        return tenorDays == 90 || tenorDays == 180 || tenorDays == 270 || tenorDays == 360;
    }

    /**
     * @notice Check if tenor is supported by pool
     */
    function _isValidTenorForPool(address poolAddress, uint256 tenorDays) internal view returns (bool) {
        uint256[] storage supportedTenors = pools[poolAddress].supportedTenors;
        
        for (uint256 i = 0; i < supportedTenors.length; i++) {
            if (supportedTenors[i] == tenorDays) {
                return true;
            }
        }
        return false;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ADMIN FUNCTIONS ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    // updatePoolYield function removed - yield is now calculated dynamically from instruments

    /**
     * @notice Deactivate a pool
     */
    function deactivatePool(address poolAddress) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) poolExists(poolAddress) {
        pools[poolAddress].isActive = false;
        emit PoolDeactivated(poolAddress, block.timestamp);
    }

    /**
     * @notice Emergency rebalance pool reserves
     */
    function rebalancePoolReserves(address poolAddress) 
        external 
        onlyRole(accessManager.OPERATOR_ROLE()) 
        poolExists(poolAddress) 
    {
        uint256 totalNAV = calculatePoolNAV(poolAddress);
        uint256 targetReserve = (totalNAV * RESERVE_RATIO) / 10000;
        
        // In practice, this would coordinate with SPV to liquidate/invest
        // For now, we just emit the event
        emit ReservesRebalanced(poolAddress, targetReserve, totalNAV);
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// SPV NAV MANAGEMENT ///////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
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
        // Recalculate NAV
        uint256 totalNAV = calculatePoolNAV(poolAddress);
        uint256 totalShares = IERC20(pools[poolAddress].poolAddress).totalSupply();
        uint256 navPerShare = calculateNAVPerShare(poolAddress);
        
        // Emit events
        emit NAVUpdated(poolAddress, totalNAV, navPerShare, reason, block.timestamp);
        emit NAVCalculated(poolAddress, totalNAV, navPerShare, totalShares, block.timestamp);
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INSTRUMENT OPTIMIZATION ////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    /**
     * @notice Gas-efficient instrument removal from array
     * @param poolAddress Pool address
     * @param instrumentId Index of instrument to remove
     * @param reason Reason for removal
     */
    function _removeInstrument(address poolAddress, uint256 instrumentId, string memory reason) internal {
        IStableYieldTypes.InstrumentHolding[] storage instruments = poolInstruments[poolAddress];
        require(instrumentId < instruments.length, "StableYieldManager/invalid instrument index");
        
        // Store final value for event
        uint256 finalValue = instruments[instrumentId].faceValue;
        
        // Gas-efficient removal: move last element to deleted spot and pop
        if (instrumentId != instruments.length - 1) {
            instruments[instrumentId] = instruments[instruments.length - 1];
        }
        instruments.pop();
        
        // Update instrument count
        poolInstrumentCount[poolAddress]--;
        
        emit InstrumentRemoved(poolAddress, instrumentId, finalValue, reason);
    }
    
    /**
     * @notice Batch remove multiple matured instruments (SPV optimization)
     * @param poolAddress Pool address
     * @param instrumentIds Array of instrument IDs to remove
     */
    function batchMatureInstruments(
        address poolAddress,
        uint256[] calldata instrumentIds
    ) external onlyRole(accessManager.SPV_ROLE()) poolExists(poolAddress) nonReentrant {
        require(instrumentIds.length > 0, "StableYieldManager/empty batch");
        require(instrumentIds.length <= 50, "StableYieldManager/batch too large"); // Gas limit protection
        
        uint256 totalMaturedValue = 0;
        
        // Process instruments in reverse order to avoid index shifting issues
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
            
            // Remove instrument
            _removeInstrument(poolAddress, instrumentId, "batch_matured");
        }
        
        // Add total face value back to cash reserve
        poolCashReserve[poolAddress] += totalMaturedValue;
        
        // Single NAV update for entire batch
        _triggerNAVUpdate(poolAddress, "batch_instrument_matured");
    }
}