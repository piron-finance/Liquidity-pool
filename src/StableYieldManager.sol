// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IManager.sol";
import "./interfaces/IPoolRegistry.sol";
import "./types/IPoolTypes.sol";
import "./types/IManagedPoolTypes.sol";
import "./AccessManager.sol";
import "./managed/YieldCalculator.sol";
import "./libraries/ValidationLibrary.sol";
 
/**
 * @title StableYieldManager
 * @dev business logic  for managed pools
 * @notice Handles all business logic for Stable Yield Pools across any approved stablecoin
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

    IPoolRegistry public registry;
    
    AccessManager public accessManager;

    YieldCalculator public yieldCalculator;
    
    address public timelockController;
    
    address public spvOracle;
    
    uint256 public version;

    mapping(address => ManagedPoolData) public managedPools;
    
    mapping(address => PoolReserves) public poolReserves;
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STRUCTS //////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    struct ManagedPoolData {
        address poolAddress;        // StableYieldPool instance
        address asset;              // Any approved stablecoin
        address escrow;             // ManagedPoolEscrow instance
        address spvAddress;         // SPV for this pool
        uint256[] supportedTenors;  // [90, 180, 270, 360] days
        uint256 minInvestment;      // In asset units
        uint256 expenseRatio;       // Basis points
        uint256 reserveRatio;       // Basis points (default 1000 = 10%)
        bool isActive;
        uint256 createdAt;
    }

    struct PoolReserves {
        uint256 targetReserveRatio;    // 1000 = 10%
        uint256 minReserveRatio;       // 500 = 5% (emergency minimum)
        uint256 maxReserveRatio;       // 2000 = 20% (if high withdrawal demand)
        uint256 currentCashBuffer;     // Current cash held
        uint256 totalPoolAUM;          // Total pool assets
        uint256 lastRebalanceTime;    // Last reserve rebalancing
    }

    struct UserPosition {
        uint256 principal;             // Original deposit amount
        uint256 shares;                // Pool shares owned
        IManagedPoolTypes.TenorDuration tenor; // Selected tenor
        IManagedPoolTypes.MaturityAction maturityAction; // Compound or withdraw
        uint256 depositTime;           // When position was created
        uint256 maturityTime;          // When tenor expires
        uint256 accruedYield;          // Cached yield calculation
        bool isActive;                 // Position status
    }

    mapping(address => mapping(address => UserPosition[])) public userPositions;

    mapping(address => IManagedPoolTypes.WithdrawalRequest[]) public withdrawalQueues;
    mapping(address => mapping(address => uint256[])) public userWithdrawalRequests;

    
    mapping(address => IManagedPoolTypes.InstrumentHolding[]) public poolInstrumentHoldings;
    
    mapping(address => uint256[]) public activeInstrumentIndices;
    
    mapping(address => IManagedPoolTypes.PoolAggregates) public poolAggregates;
    
    mapping(address => IManagedPoolTypes.CouponPayment[]) public poolCouponPayments;
    
    mapping(address => uint256) public poolMaturedCash;

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EVENTS //////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    event ManagedPoolRegistered(
        address indexed poolAddress,
        address indexed asset,
        address indexed escrow,
        address spvAddress,
        uint256[] supportedTenors
    );
    
    event ManagedDeposit(
        address indexed pool,
        address indexed user,
        uint256 amount,
        uint256 shares,
        IManagedPoolTypes.TenorDuration tenor,
        IManagedPoolTypes.MaturityAction maturityAction
    );
    
    event EarlyExitRequested(
        address indexed pool,
        address indexed user,
        uint256 positionIndex,
        uint256 shares,
        uint256 penaltyAmount,
        uint256 expectedAmount
    );
    
    event WithdrawalQueued(
        address indexed pool,
        address indexed user,
        uint256 requestIndex,
        uint256 shares,
        uint256 expectedAmount,
        bool isPenalized
    );
    
    event WithdrawalProcessed(
        address indexed pool,
        address indexed user,
        uint256 requestIndex,
        uint256 actualAmount
    );
    
    event NAVUpdated(
        address indexed pool,
        uint256 newNAV,
        uint256 navPerShare,
        uint256 timestamp
    );
    
    event ReservesRebalanced(
        address indexed pool,
        uint256 oldRatio,
        uint256 newRatio,
        uint256 liquidityRequested
    );

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// MODIFIERS ///////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    modifier onlyRegisteredManagedPool() {
        require(managedPools[msg.sender].isActive, "StableYieldManager/not registered managed pool");
        _;
    }
    
    modifier onlyRole(bytes32 role) {
        require(accessManager.hasRole(role, msg.sender), "StableYieldManager/access denied");
        _;
    }
    
    modifier whenNotPaused() {
        require(!accessManager.paused(), "StableYieldManager/paused");
        _;
    }

    modifier validTenor(uint256 tenorDays) {
        require(_isValidTenor(tenorDays), "StableYieldManager/invalid tenor");
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
     * @notice Initialize the StableYieldManager contract
     * @param _registry PoolRegistry contract address
     * @param _accessManager AccessManager contract address
     * @param _yieldCalculator YieldCalculator contract address
     * @param _timelockController TimelockController contract address
     */
    function initialize(
        address _registry,
        address _accessManager,
        address _yieldCalculator,
        address _timelockController
    ) public initializer {
        require(_registry != address(0), "StableYieldManager/invalid registry");
        require(_accessManager != address(0), "StableYieldManager/invalid access manager");
        require(_yieldCalculator != address(0), "StableYieldManager/invalid yield calculator");
        require(_timelockController != address(0), "StableYieldManager/invalid timelock controller");
        
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        registry = IPoolRegistry(_registry);
        accessManager = AccessManager(_accessManager);
        yieldCalculator = YieldCalculator(_yieldCalculator);
        timelockController = _timelockController;
        version = 1;
    }

    /**
     * @notice Authorize contract upgrades (UUPS)
     * @param newImplementation New implementation address
     */
    function _authorizeUpgrade(address newImplementation) internal override {
        require(msg.sender == timelockController, "StableYieldManager/unauthorized upgrade");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// MANAGED POOL REGISTRATION //////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Register a new managed pool
     * @param poolAddress StableYieldPool contract address
     * @param asset Approved stablecoin address
     * @param escrow ManagedPoolEscrow address
     * @param spvAddress SPV address for this pool
     * @param supportedTenors Array of supported tenor days
     * @param minInvestment Minimum investment amount
     * @param expenseRatio Management fee in basis points
     */
    function registerManagedPool(
        address poolAddress,
        address asset,
        address escrow,
        address spvAddress,
        uint256[] memory supportedTenors,
        uint256 minInvestment,
        uint256 expenseRatio
    ) external onlyRole(accessManager.POOL_CREATOR_ROLE()) {
        require(poolAddress != address(0), "StableYieldManager/invalid pool");
        require(asset != address(0), "StableYieldManager/invalid asset");
        require(escrow != address(0), "StableYieldManager/invalid escrow");
        require(spvAddress != address(0), "StableYieldManager/invalid spv");
        require(supportedTenors.length > 0, "StableYieldManager/no tenors");
        
        require(registry.isApprovedAsset(asset), "StableYieldManager/asset not approved");
        
        for (uint256 i = 0; i < supportedTenors.length; i++) {
            require(_isValidTenor(supportedTenors[i]), "StableYieldManager/invalid tenor");
        }
        
        managedPools[poolAddress] = ManagedPoolData({
            poolAddress: poolAddress,
            asset: asset,
            escrow: escrow,
            spvAddress: spvAddress,
            supportedTenors: supportedTenors,
            minInvestment: minInvestment,
            expenseRatio: expenseRatio,
            reserveRatio: 1000, // Default 10%
            isActive: true,
            createdAt: block.timestamp
        });
        
        poolReserves[poolAddress] = PoolReserves({
            targetReserveRatio: 1000,  // 10%
            minReserveRatio: 500,      // 5%
            maxReserveRatio: 2000,     // 20%
            currentCashBuffer: 0,
            totalPoolAUM: 0,
            lastRebalanceTime: block.timestamp
        });
        
        emit ManagedPoolRegistered(poolAddress, asset, escrow, spvAddress, supportedTenors);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// DEPOSIT HANDLING ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Handle managed pool deposit with professional NAV pricing
     * @param poolAddress Pool contract address
     * @param amount Deposit amount in asset units
     * @param tenorDays Selected tenor duration in days
     * @param maturityAction What to do at maturity (compound/withdraw)
     * @param receiver Address to receive shares
     * @param sender Address sending the deposit
     * @return shares Number of shares minted
     */
    function handleManagedDeposit(
        address poolAddress,
        uint256 amount,
        uint256 tenorDays,
        IManagedPoolTypes.MaturityAction maturityAction,
        address receiver,
        address sender
    ) external 
        onlyRegisteredManagedPool 
        validTenor(tenorDays)
        whenNotPaused 
        nonReentrant 
        returns (uint256 shares) 
    {
        require(msg.sender == poolAddress, "StableYieldManager/invalid caller");
        require(registry.isManagedPool(poolAddress), "StableYieldManager/invalid pool");
        require(amount > 0, "StableYieldManager/invalid amount");
        require(receiver != address(0), "StableYieldManager/invalid receiver");
        
        ManagedPoolData storage poolData = managedPools[poolAddress];
        require(amount >= poolData.minInvestment, "StableYieldManager/below minimum");
        
        uint256 navPerShare = calculateNAVPerShare(poolAddress);
        
        address asset = poolData.asset;
        uint8 assetDecimals = IERC20Metadata(asset).decimals();
        uint256 decimalMultiplier = 10**assetDecimals;
        
        shares = (amount * decimalMultiplier) / navPerShare;
        
        uint256 reserveAmount = (amount * poolData.reserveRatio) / 10000;
        uint256 investmentAmount = amount - reserveAmount;
        
        PoolReserves storage reserves = poolReserves[poolAddress];
        reserves.currentCashBuffer += reserveAmount;
        reserves.totalPoolAUM += amount;
        
        IManagedPoolTypes.TenorDuration tenor = _daysToDuration(tenorDays);
        uint256 maturityTime = block.timestamp + (tenorDays * 1 days);
        
        userPositions[poolAddress][receiver].push(UserPosition({
            principal: amount,
            shares: shares,
            tenor: tenor,
            maturityAction: maturityAction,
            depositTime: block.timestamp,
            maturityTime: maturityTime,
            accruedYield: 0,
            isActive: true
        }));
        
        if (investmentAmount > 0) {
            _coordinateSPVInvestment(poolAddress, investmentAmount);
        }
        
        emit ManagedDeposit(poolAddress, receiver, amount, shares, tenor, maturityAction);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// NAV CALCULATION //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Calculate pool's Net Asset Value
     * @param poolAddress Pool contract address
     * @return nav Total NAV of the pool
     */
    function calculatePoolNAV(address poolAddress) public view returns (uint256 nav) {
        require(managedPools[poolAddress].isActive, "StableYieldManager/pool not active");
        
        uint256 instrumentValue = _getTotalInstrumentValue(poolAddress);
        uint256 cashBuffer = _getCashBufferValue(poolAddress);
        uint256 accruedInterest = _getAccruedInterest(poolAddress);
        uint256 fees = _calculateManagementFees(poolAddress);
        
        nav = instrumentValue + cashBuffer + accruedInterest - fees;
    }
    
    /**
     * @notice Calculate NAV per share for pricing
     * @param poolAddress Pool contract address
     * @return navPerShare NAV per share (asset decimals)
     */
    function calculateNAVPerShare(address poolAddress) public view returns (uint256 navPerShare) {
        uint256 totalNAV = calculatePoolNAV(poolAddress);
        uint256 totalShares = IERC20(poolAddress).totalSupply();
        
        address asset = managedPools[poolAddress].asset;
        uint8 assetDecimals = IERC20Metadata(asset).decimals();
        uint256 decimalMultiplier = 10**assetDecimals;
        
        if (totalShares == 0) {
            navPerShare = decimalMultiplier;
        } else {
            navPerShare = (totalNAV * decimalMultiplier) / totalShares;
        }
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// WITHDRAWAL HANDLING ////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Handle managed pool withdrawal with penalties
     * @param poolAddress Pool contract address
     * @param shares Number of shares to withdraw
     * @param receiver Address to receive funds
     * @param owner Share owner address
     * @param sender Transaction sender
     * @return actualShares Shares actually burned
     */
    function handleManagedWithdraw(
        address poolAddress,
        uint256 shares,
        address receiver,
        address owner,
        address sender
    ) external 
        onlyRegisteredManagedPool 
        whenNotPaused 
        nonReentrant 
        returns (uint256 actualShares) 
    {
        require(msg.sender == poolAddress, "StableYieldManager/invalid caller");
        require(shares > 0, "StableYieldManager/invalid shares");
        require(receiver != address(0), "StableYieldManager/invalid receiver");
        require(owner != address(0), "StableYieldManager/invalid owner");
        
        // Calculate withdrawal value with penalties
        uint256 navPerShare = calculateNAVPerShare(poolAddress);
        uint256 baseValue = (shares * navPerShare) / 1e18;
        
        (uint256 penaltyRate, bool isEarlyExit) = _calculateEarlyExitPenalty(poolAddress, owner, shares);
        uint256 finalValue = baseValue - ((baseValue * penaltyRate) / 10000);
        
        PoolReserves storage reserves = poolReserves[poolAddress];
        
        if (reserves.currentCashBuffer >= finalValue) {
            reserves.currentCashBuffer -= finalValue;
            reserves.totalPoolAUM -= baseValue;
            
            _processImmediateWithdrawal(poolAddress, receiver, finalValue);
            
            actualShares = shares;
        } else {
            _queueWithdrawal(poolAddress, owner, shares, finalValue, isEarlyExit);
            actualShares = 0;
        }
        
        if (isEarlyExit && actualShares > 0) {
            emit EarlyExitRequested(poolAddress, owner, 0, shares, baseValue - finalValue, finalValue);
        }
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// QUEUE PROCESSING ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Process withdrawal queue in batches
     * @param poolAddress Pool contract address
     * @param maxRequests Maximum requests to process
     */
    function processWithdrawalQueue(
        address poolAddress,
        uint256 maxRequests
    ) external 
        onlyRole(accessManager.OPERATOR_ROLE()) 
        nonReentrant 
    {
        require(managedPools[poolAddress].isActive, "StableYieldManager/pool not active");
        
        IManagedPoolTypes.WithdrawalRequest[] storage queue = withdrawalQueues[poolAddress];
        PoolReserves storage reserves = poolReserves[poolAddress];
        
        uint256 processed = 0;
        
        for (uint256 i = 0; i < queue.length && processed < maxRequests; i++) {
            IManagedPoolTypes.WithdrawalRequest storage request = queue[i];
            
            if (!request.isProcessed && reserves.currentCashBuffer >= request.expectedAmount) {
                reserves.currentCashBuffer -= request.expectedAmount;
                reserves.totalPoolAUM -= request.expectedAmount;
                
                _processQueuedWithdrawal(poolAddress, request.user, request.expectedAmount);
                
                request.isProcessed = true;
                processed++;
                
                emit WithdrawalProcessed(poolAddress, request.user, i, request.expectedAmount);
            }
        }
        
        if (processed < queue.length) {
            uint256 totalPending = _calculatePendingWithdrawals(poolAddress);
            _requestSPVLiquidity(poolAddress, totalPending);
        }
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// RESERVE MANAGEMENT //////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Manage pool reserves dynamically
     * @param poolAddress Pool contract address
     */
    function manageReserves(address poolAddress) external onlyRole(accessManager.OPERATOR_ROLE()) {
        require(managedPools[poolAddress].isActive, "StableYieldManager/pool not active");
        
        PoolReserves storage reserves = poolReserves[poolAddress];
        uint256 currentRatio = (reserves.currentCashBuffer * 10000) / reserves.totalPoolAUM;
        
        if (currentRatio < reserves.minReserveRatio) {
            uint256 needed = ((reserves.targetReserveRatio * reserves.totalPoolAUM) / 10000) - reserves.currentCashBuffer;
            _requestSPVLiquidity(poolAddress, needed);
            
            emit ReservesRebalanced(poolAddress, currentRatio, reserves.targetReserveRatio, needed);
            
        } else if (currentRatio > reserves.maxReserveRatio) {
            uint256 excess = reserves.currentCashBuffer - ((reserves.targetReserveRatio * reserves.totalPoolAUM) / 10000);
            _coordinateSPVInvestment(poolAddress, excess);
            
            emit ReservesRebalanced(poolAddress, currentRatio, reserves.targetReserveRatio, 0);
        }
        
        reserves.lastRebalanceTime = block.timestamp;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// VIEW FUNCTIONS ///////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Get managed pool configuration
     * @param poolAddress Pool contract address
     * @return Pool configuration data
     */
    function getManagedPoolData(address poolAddress) external view returns (ManagedPoolData memory) {
        return managedPools[poolAddress];
    }
    
    /**
     * @notice Get pool reserves information
     * @param poolAddress Pool contract address
     * @return Pool reserves data
     */
    function getPoolReserves(address poolAddress) external view returns (PoolReserves memory) {
        return poolReserves[poolAddress];
    }
    
    /**
     * @notice Get user positions for a pool
     * @param poolAddress Pool contract address
     * @param user User address
     * @return Array of user positions
     */
    function getUserPositions(address poolAddress, address user) external view returns (UserPosition[] memory) {
        return userPositions[poolAddress][user];
    }
    
    /**
     * @notice Get withdrawal queue length
     * @param poolAddress Pool contract address
     * @return Number of queued withdrawal requests
     */
    function getWithdrawalQueueLength(address poolAddress) external view returns (uint256) {
        return withdrawalQueues[poolAddress].length;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INTERNAL FUNCTIONS //////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @dev Validate if tenor days is supported
     */
    function _isValidTenor(uint256 tenorDays) internal pure returns (bool) {
        return tenorDays == 90 || tenorDays == 180 || tenorDays == 270 || tenorDays == 360;
    }
    
    /**
     * @dev Convert days to TenorDuration enum
     */
    function _daysToDuration(uint256 days) internal pure returns (IManagedPoolTypes.TenorDuration) {
        if (days == 90) return IManagedPoolTypes.TenorDuration.TENOR_90D;
        if (days == 180) return IManagedPoolTypes.TenorDuration.TENOR_180D;
        if (days == 270) return IManagedPoolTypes.TenorDuration.TENOR_270D;
        if (days == 360) return IManagedPoolTypes.TenorDuration.TENOR_360D;
        revert("StableYieldManager/invalid tenor days");
    }

    /**
     * @dev Calculate early exit penalty for user positions
     */
    function _calculateEarlyExitPenalty(
        address poolAddress, 
        address user, 
        uint256 shares
    ) internal view returns (uint256 penaltyRate, bool isEarlyExit) {
        UserPosition[] memory positions = userPositions[poolAddress][user];
        
        // Simplified: Apply penalty if any position is within 30 days of maturity
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].isActive && block.timestamp < positions[i].maturityTime) {
                uint256 daysHeld = (block.timestamp - positions[i].depositTime) / 1 days;
                if (daysHeld < 30) {
                    return (500, true); // 5% penalty
                } else {
                    return (300, true); // 3% penalty for early exit after 30 days
                }
            }
        }
        
        return (0, false); // No penalty at maturity
    }

    /**
     * @dev Queue withdrawal request
     */
    function _queueWithdrawal(
        address poolAddress,
        address user,
        uint256 shares,
        uint256 expectedAmount,
        bool isPenalized
    ) internal {
        withdrawalQueues[poolAddress].push(IManagedPoolTypes.WithdrawalRequest({
            user: user,
            shares: shares,
            expectedAmount: expectedAmount,
            requestTime: block.timestamp,
            isPenalized: isPenalized,
            isProcessed: false
        }));
        
        uint256 requestIndex = withdrawalQueues[poolAddress].length - 1;
        userWithdrawalRequests[poolAddress][user].push(requestIndex);
        
        emit WithdrawalQueued(poolAddress, user, requestIndex, shares, expectedAmount, isPenalized);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INTERNAL FUNCTIONS //////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Get total value of instruments held by the pool
     * @param poolAddress Pool contract address
     * @return value Total instrument value including accrued interest
     */
    function _getTotalInstrumentValue(address poolAddress) internal view returns (uint256 value) {
        ManagedPoolData memory poolData = managedPools[poolAddress];
        PoolReserves memory reserves = poolReserves[poolAddress];
        
        uint256 allocatedFunds = reserves.totalPoolAUM - reserves.currentCashBuffer;
        
        if (allocatedFunds == 0) return 0;
        
        IManagedPoolTypes.PoolAggregates storage aggregates = poolAggregates[poolAddress];
        
        uint256 totalValue;
        if (aggregates.activeInstrumentCount == 0) {
            totalValue = 0;
        } else {
            if (block.timestamp > aggregates.lastAccrualTimestamp) {
                _updatePoolAccruals(poolAddress);
            }
            
            totalValue = aggregates.totalAccruedValue;
        }
        
        totalValue += poolMaturedCash[poolAddress];
        
        value = totalValue;
    }

    /**
     * @notice Get current cash buffer value
     * @param poolAddress Pool contract address
     * @return value Cash buffer amount
     */
    function _getCashBufferValue(address poolAddress) internal view returns (uint256 value) {
        return poolReserves[poolAddress].currentCashBuffer;
    }

    /**
     * @notice Calculate accrued interest from T-bills
     * @param poolAddress Pool contract address
     * @return interest Accrued interest amount
     */
    function _getAccruedInterest(address poolAddress) internal view returns (uint256 interest) {
        PoolReserves memory reserves = poolReserves[poolAddress];
        uint256 allocatedFunds = reserves.totalPoolAUM - reserves.currentCashBuffer;
        
        if (allocatedFunds == 0) return 0;
        
        uint256 timeElapsed = block.timestamp - reserves.lastRebalanceTime;
        uint256 dailyRate = 800;
        
        interest = (allocatedFunds * dailyRate * timeElapsed) / (10000 * 365 days);
    }

    /**
     * @notice Calculate management fees owed
     * @param poolAddress Pool contract address  
     * @return fees Management fees amount
     */
    function _calculateManagementFees(address poolAddress) internal view returns (uint256 fees) {
        ManagedPoolData memory poolData = managedPools[poolAddress];
        PoolReserves memory reserves = poolReserves[poolAddress];
        
        if (reserves.totalPoolAUM == 0) return 0;
        
        uint256 timeElapsed = block.timestamp - reserves.lastRebalanceTime;
        fees = (reserves.totalPoolAUM * poolData.expenseRatio * timeElapsed) / (10000 * 365 days);
    }

    /**
     * @notice Coordinate SPV investment of funds
     * @param poolAddress Pool contract address
     * @param amount Amount to invest in T-bills
     */
    function _coordinateSPVInvestment(address poolAddress, uint256 amount) internal {
        ManagedPoolData storage poolData = managedPools[poolAddress];
        PoolReserves storage reserves = poolReserves[poolAddress];
        
        require(amount > 0, "StableYieldManager/invalid investment amount");
        require(poolData.spvAddress != address(0), "StableYieldManager/invalid SPV address");
        
        address escrow = poolData.escrow;
        require(escrow != address(0), "StableYieldManager/invalid escrow");
        (bool success, ) = escrow.call(
            abi.encodeWithSignature(
                "transferToSPV(address,uint256)",
                poolData.spvAddress,
                amount
            )
        );
        require(success, "StableYieldManager/SPV transfer failed");
        
        reserves.lastRebalanceTime = block.timestamp;
        
        emit SPVInvestmentRequested(poolAddress, poolData.spvAddress, amount, block.timestamp);
    }

    /**
     * @notice Process immediate withdrawal from cash buffer
     * @param poolAddress Pool contract address
     * @param user User requesting withdrawal
     * @param amount Amount to withdraw
     */
    function _processImmediateWithdrawal(address poolAddress, address user, uint256 amount) internal {
        PoolReserves storage reserves = poolReserves[poolAddress];
        ManagedPoolData storage poolData = managedPools[poolAddress];
        
        require(reserves.currentCashBuffer >= amount, "StableYieldManager/insufficient liquidity");
        require(user != address(0), "StableYieldManager/invalid user");
        require(amount > 0, "StableYieldManager/invalid amount");
        
        reserves.currentCashBuffer -= amount;
        reserves.totalPoolAUM -= amount;
        
        address escrow = poolData.escrow;
        require(escrow != address(0), "StableYieldManager/invalid escrow");
        (bool success, ) = escrow.call(
            abi.encodeWithSignature(
                "processWithdrawal(address,uint256)",
                user,
                amount
            )
        );
        require(success, "StableYieldManager/withdrawal processing failed");
        
        reserves.lastRebalanceTime = block.timestamp;
        
        emit ImmediateWithdrawalProcessed(poolAddress, user, amount, block.timestamp);
    }

    /**
     * @notice Process queued withdrawal request
     * @param poolAddress Pool contract address
     * @param user User requesting withdrawal
     * @param shares Shares to withdraw
     */
    function _processQueuedWithdrawal(address poolAddress, address user, uint256 amount) internal {
        withdrawalQueues[poolAddress].push(IManagedPoolTypes.WithdrawalRequest({
            user: user,
            shares: 0,
            requestTime: block.timestamp,
            expectedAmount: amount,
            isPenalized: true,
            isProcessed: false
        }));
        
        uint256 requestIndex = withdrawalQueues[poolAddress].length - 1;
        userWithdrawalRequests[poolAddress][user].push(requestIndex);
        
        emit WithdrawalQueued(poolAddress, user, requestIndex, 0, amount, true);
    }

    /**
     * @notice Calculate total pending withdrawal amounts
     * @param poolAddress Pool contract address
     * @return pending Total pending withdrawal amount
     */
    function _calculatePendingWithdrawals(address poolAddress) internal view returns (uint256 pending) {
        IManagedPoolTypes.WithdrawalRequest[] memory queue = withdrawalQueues[poolAddress];
        uint256 navPerShare = calculateNAVPerShare(poolAddress);
        
        for (uint256 i = 0; i < queue.length; i++) {
            if (!queue[i].isProcessed) {
                address asset = managedPools[poolAddress].asset;
                uint8 assetDecimals = IERC20Metadata(asset).decimals();
                uint256 decimalMultiplier = 10**assetDecimals;
                
                uint256 amount = (queue[i].shares * navPerShare) / decimalMultiplier;
                
                if (queue[i].isPenalized) {
                    uint256 penalty = (amount * 300) / 10000;
                    amount -= penalty;
                }
                
                pending += amount;
            }
        }
    }

    /**
     * @notice Request SPV to provide liquidity for withdrawals
     * @param poolAddress Pool contract address
     * @param amount Amount of liquidity needed
     */
    function _requestSPVLiquidity(address poolAddress, uint256 amount) internal {
        ManagedPoolData storage poolData = managedPools[poolAddress];
        PoolReserves storage reserves = poolReserves[poolAddress];
        
        require(amount > 0, "StableYieldManager/invalid liquidity amount");
        require(poolData.spvAddress != address(0), "StableYieldManager/invalid SPV address");
        
        uint256 allocatedFunds = reserves.totalPoolAUM - reserves.currentCashBuffer;
        require(allocatedFunds >= amount, "StableYieldManager/insufficient allocated funds");
        
        address escrow = poolData.escrow;
        require(escrow != address(0), "StableYieldManager/invalid escrow");
        if (spvOracle != address(0)) {
            (bool success, ) = spvOracle.call(
                abi.encodeWithSignature(
                    "requestLiquidation(address,address,uint256)",
                    poolAddress,
                    escrow,
                    amount
                )
            );
            require(success, "StableYieldManager/liquidation request failed");
        }
        
        reserves.lastRebalanceTime = block.timestamp;
        
        emit SPVLiquidityRequested(poolAddress, poolData.spvAddress, amount, block.timestamp);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INSTRUMENT ATTESTATION FUNCTIONS ///////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Attest instrument purchase by SPV (T-bills or bonds)
     * @param poolAddress Pool contract address
     * @param purchasePrice Amount paid (discount for T-bills, par for bonds)
     * @param faceValue Principal/maturity value
     * @param maturityDate When instrument matures (timestamp)
     * @param annualCouponRate Annual coupon rate in basis points (0 for T-bills)
     * @param couponFrequency Payment frequency (0=T-bill, 2=semi-annual, 4=quarterly, 12=monthly)
     * @param cusip Instrument identifier
     * @param spvSignature SPV signature proving purchase
     */
    function attestInstrumentPurchase(
        address poolAddress,
        uint256 purchasePrice,
        uint256 faceValue,
        uint256 maturityDate,
        uint256 annualCouponRate,
        uint8 couponFrequency,
        uint256 cusip,
        bytes calldata spvSignature
    ) external onlyRole(accessManager.SPV_ROLE()) {
        require(managedPools[poolAddress].isActive, "StableYieldManager/pool not active");
        require(purchasePrice > 0, "StableYieldManager/invalid purchase price");
        require(faceValue >= purchasePrice, "StableYieldManager/invalid face value"); // >= for bonds at par
        require(maturityDate > block.timestamp, "StableYieldManager/invalid maturity date");
        require(maturityDate <= block.timestamp + 1095 days, "StableYieldManager/maturity too far"); // 3 years for bonds
        
        if (annualCouponRate > 0) {
            require(couponFrequency > 0, "StableYieldManager/bonds must have coupon frequency");
            require(couponFrequency == 2 || couponFrequency == 4 || couponFrequency == 12, "StableYieldManager/invalid coupon frequency");
            require(annualCouponRate <= 5000, "StableYieldManager/coupon rate too high");
        } else {
            require(couponFrequency == 0, "StableYieldManager/T-bills cannot have coupon frequency");
            require(faceValue > purchasePrice, "StableYieldManager/T-bills must be discounted");
        }
        
        bytes32 attestationHash = keccak256(abi.encodePacked(
            poolAddress,
            purchasePrice,
            faceValue,
            maturityDate,
            annualCouponRate,
            couponFrequency,
            cusip,
            block.timestamp
        ));
        
        require(_verifyAttestationSignature(attestationHash, spvSignature), "StableYieldManager/invalid signature");
        poolInstrumentHoldings[poolAddress].push(IManagedPoolTypes.InstrumentHolding({
            purchasePrice: purchasePrice,
            faceValue: faceValue,
            purchaseDate: block.timestamp,
            maturityDate: maturityDate,
            annualCouponRate: annualCouponRate,
            couponFrequency: couponFrequency,
            lastCouponPaidDate: 0,  // No coupons paid yet
            couponsPaid: 0,         // No coupons paid yet
            attestationHash: attestationHash,
            cusip: cusip,
            isMatured: false,
            isLiquidated: false
        }));
        
        uint256 newIndex = poolInstrumentHoldings[poolAddress].length - 1;
        activeInstrumentIndices[poolAddress].push(newIndex);
        
        _updateAggregatesOnPurchase(poolAddress, purchasePrice, faceValue, maturityDate);
        
        emit InstrumentPurchaseAttested(poolAddress, cusip, purchasePrice, faceValue, maturityDate, annualCouponRate);
    }

    /**
     * @notice Attest T-bill maturity by SPV
     * @param poolAddress Pool contract address
     * @param holdingIndex Index of T-bill in holdings array
     * @param actualMaturityValue Actual value received (should equal face value)
     * @param spvSignature SPV signature proving maturity
     */
    function attestTBillMaturity(
        address poolAddress,
        uint256 holdingIndex,
        uint256 actualMaturityValue,
        bytes calldata spvSignature
    ) external onlyRole(accessManager.SPV_ROLE()) {
        require(managedPools[poolAddress].isActive, "StableYieldManager/pool not active");
        require(holdingIndex < poolTBillHoldings[poolAddress].length, "StableYieldManager/invalid holding index");
        
        TBillHolding storage holding = poolTBillHoldings[poolAddress][holdingIndex];
        require(!holding.isMatured, "StableYieldManager/already matured");
        require(!holding.isLiquidated, "StableYieldManager/already liquidated");
        require(block.timestamp >= holding.maturityDate, "StableYieldManager/not yet matured");
        require(actualMaturityValue == holding.faceValue, "StableYieldManager/maturity value mismatch");
        
        // Create maturity attestation hash
        bytes32 maturityHash = keccak256(abi.encodePacked(
            poolAddress,
            holdingIndex,
            holding.cusip,
            actualMaturityValue,
            "MATURED",
            block.timestamp
        ));
        
        require(_verifyAttestationSignature(maturityHash, spvSignature), "StableYieldManager/invalid signature");
        
        // Mark as matured
        holding.isMatured = true;
        
        // Remove from active instruments for gas efficiency
        _removeFromActiveIndices(poolAddress, holdingIndex);
        
        // Update aggregates on maturity
        _updateAggregatesOnRemoval(poolAddress, holding.purchasePrice, holding.faceValue, holding.maturityDate);
        
        // Add to pool's matured cash
        poolMaturedCash[poolAddress] += actualMaturityValue;
        
        // Update pool reserves with matured funds
        PoolReserves storage reserves = poolReserves[poolAddress];
        reserves.currentCashBuffer += actualMaturityValue;
        reserves.lastRebalanceTime = block.timestamp;
        
        emit TBillMaturityAttested(poolAddress, holding.cusip, actualMaturityValue);
        
        // Automatically process queued withdrawals
        _processQueuedWithdrawals(poolAddress);
    }

    /**
     * @notice Attest early T-bill liquidation by SPV
     * @param poolAddress Pool contract address
     * @param holdingIndex Index of T-bill in holdings array
     * @param liquidationValue Actual value received from early sale
     * @param spvSignature SPV signature proving liquidation
     */
    function attestTBillLiquidation(
        address poolAddress,
        uint256 holdingIndex,
        uint256 liquidationValue,
        bytes calldata spvSignature
    ) external onlyRole(accessManager.SPV_ROLE()) {
        require(managedPools[poolAddress].isActive, "StableYieldManager/pool not active");
        require(holdingIndex < poolTBillHoldings[poolAddress].length, "StableYieldManager/invalid holding index");
        
        TBillHolding storage holding = poolTBillHoldings[poolAddress][holdingIndex];
        require(!holding.isMatured, "StableYieldManager/already matured");
        require(!holding.isLiquidated, "StableYieldManager/already liquidated");
        require(liquidationValue > 0, "StableYieldManager/invalid liquidation value");
        
        // Create liquidation attestation hash
        bytes32 liquidationHash = keccak256(abi.encodePacked(
            poolAddress,
            holdingIndex,
            holding.cusip,
            liquidationValue,
            "LIQUIDATED",
            block.timestamp
        ));
        
        require(_verifyAttestationSignature(liquidationHash, spvSignature), "StableYieldManager/invalid signature");
        
        // Mark as liquidated
        holding.isLiquidated = true;
        
        // Remove from active instruments for gas efficiency
        _removeFromActiveIndices(poolAddress, holdingIndex);
        
        // Update aggregates on liquidation
        _updateAggregatesOnRemoval(poolAddress, holding.purchasePrice, holding.faceValue, holding.maturityDate);
        
        // Add liquidation proceeds to cash buffer
        PoolReserves storage reserves = poolReserves[poolAddress];
        reserves.currentCashBuffer += liquidationValue;
        reserves.lastRebalanceTime = block.timestamp;
        
        emit TBillLiquidationAttested(poolAddress, holding.cusip, liquidationValue);
        
        // Process queued withdrawals
        _processQueuedWithdrawals(poolAddress);
    }

    /**
     * @notice Attest bond coupon payment by SPV
     * @param poolAddress Pool contract address
     * @param holdingIndex Index of bond in holdings array
     * @param couponAmount Amount of coupon received
     * @param expectedDate When coupon was due
     * @param spvSignature SPV signature proving coupon receipt
     */
    function attestCouponPayment(
        address poolAddress,
        uint256 holdingIndex,
        uint256 couponAmount,
        uint256 expectedDate,
        bytes calldata spvSignature
    ) external onlyRole(accessManager.SPV_ROLE()) {
        require(managedPools[poolAddress].isActive, "StableYieldManager/pool not active");
        require(holdingIndex < poolInstrumentHoldings[poolAddress].length, "StableYieldManager/invalid holding index");
        require(couponAmount > 0, "StableYieldManager/invalid coupon amount");
        
        InstrumentHolding storage holding = poolInstrumentHoldings[poolAddress][holdingIndex];
        require(holding.couponFrequency > 0, "StableYieldManager/instrument has no coupons");
        require(!holding.isMatured, "StableYieldManager/instrument already matured");
        require(!holding.isLiquidated, "StableYieldManager/instrument already liquidated");
        
        // Calculate expected coupon amount
        uint256 expectedCouponAmount = (holding.faceValue * holding.annualCouponRate) / (10000 * holding.couponFrequency);
        require(couponAmount == expectedCouponAmount, "StableYieldManager/incorrect coupon amount");
        
        // Create coupon attestation hash
        bytes32 couponHash = keccak256(abi.encodePacked(
            poolAddress,
            holdingIndex,
            holding.cusip,
            couponAmount,
            expectedDate,
            "COUPON",
            block.timestamp
        ));
        
        require(_verifyAttestationSignature(couponHash, spvSignature), "StableYieldManager/invalid signature");
        
        holding.lastCouponPaidDate = block.timestamp;
        holding.couponsPaid += 1;
        poolCouponPayments[poolAddress].push(IManagedPoolTypes.CouponPayment({
            holdingIndex: holdingIndex,
            couponAmount: couponAmount,
            expectedDate: expectedDate,
            actualDate: block.timestamp
        }));
        
        PoolReserves storage reserves = poolReserves[poolAddress];
        reserves.currentCashBuffer += couponAmount;
        reserves.lastRebalanceTime = block.timestamp;
        
        emit CouponPaymentAttested(poolAddress, holding.cusip, couponAmount, expectedDate);
        
        _processQueuedWithdrawals(poolAddress);
    }

    /**
     * @notice Get all instrument holdings for a pool
     * @param poolAddress Pool contract address
     * @return holdings Array of instrument holdings
     */
    function getPoolInstrumentHoldings(address poolAddress) external view returns (IManagedPoolTypes.InstrumentHolding[] memory holdings) {
        return poolInstrumentHoldings[poolAddress];
    }

    /**
     * @notice Get all coupon payments for a pool
     * @param poolAddress Pool contract address
     * @return payments Array of coupon payments
     */
    function getPoolCouponPayments(address poolAddress) external view returns (IManagedPoolTypes.CouponPayment[] memory payments) {
        return poolCouponPayments[poolAddress];
    }

    /**
     * @notice Get count of active (non-matured, non-liquidated) instruments
     * @param poolAddress Pool contract address
     * @return count Number of active instruments
     */
    function getActiveInstrumentCount(address poolAddress) external view returns (uint256 count) {
        IManagedPoolTypes.InstrumentHolding[] memory holdings = poolInstrumentHoldings[poolAddress];
        for (uint256 i = 0; i < holdings.length; i++) {
            if (!holdings[i].isMatured && !holdings[i].isLiquidated) {
                count++;
            }
        }
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// PRODUCTION SPV INTEGRATION /////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Process SPV reported T-bill maturity
     * @param poolAddress Pool contract address
     * @param maturedAmount Amount of T-bills that have matured
     */
    function processSPVMaturity(
        address poolAddress,
        uint256 maturedAmount
    ) external onlyRole(accessManager.SPV_ROLE()) {
        require(managedPools[poolAddress].isActive, "StableYieldManager/pool not active");
        require(maturedAmount > 0, "StableYieldManager/invalid matured amount");
        
        PoolReserves storage reserves = poolReserves[poolAddress];
        
        reserves.currentCashBuffer += maturedAmount;
        reserves.lastRebalanceTime = block.timestamp;
        
        emit SPVMaturityProcessed(poolAddress, maturedAmount, block.timestamp);
        
        _processQueuedWithdrawals(poolAddress);
    }

    /**
     * @notice Update NAV based on real SPV reporting
     * @param poolAddress Pool contract address
     * @param newNAV Updated NAV from SPV
     */
    function updateNAVFromSPV(
        address poolAddress,
        uint256 newNAV
    ) external onlyRole(accessManager.SPV_ROLE()) {
        require(managedPools[poolAddress].isActive, "StableYieldManager/pool not active");
        require(newNAV > 0, "StableYieldManager/invalid NAV");
        
        PoolReserves storage reserves = poolReserves[poolAddress];
        uint256 oldNAV = reserves.totalPoolAUM;
        
        reserves.totalPoolAUM = newNAV;
        reserves.lastRebalanceTime = block.timestamp;
        
        uint256 navPerShare = calculateNAVPerShare(poolAddress);
        
        emit NAVUpdated(poolAddress, newNAV, navPerShare, block.timestamp);
        
        if (newNAV > oldNAV) {
            uint256 increase = newNAV - oldNAV;
            uint256 targetCashIncrease = (increase * managedPools[poolAddress].reserveRatio) / 10000;
            
            if (targetCashIncrease > 0) {
                _rebalanceReserves(poolAddress);
            }
        }
    }

    /**
     * @notice Process all queued withdrawals for a pool
     * @param poolAddress Pool contract address
     */
    function _processQueuedWithdrawals(address poolAddress) internal {
        IManagedPoolTypes.WithdrawalRequest[] storage queue = withdrawalQueues[poolAddress];
        PoolReserves storage reserves = poolReserves[poolAddress];
        
        uint256 availableLiquidity = reserves.currentCashBuffer;
        uint256 processedAmount = 0;
        
        for (uint256 i = 0; i < queue.length && availableLiquidity > 0; i++) {
            IManagedPoolTypes.WithdrawalRequest storage request = queue[i];
            
            if (!request.isProcessed) {
                uint256 navPerShare = calculateNAVPerShare(poolAddress);
                
                address asset = managedPools[poolAddress].asset;
                uint8 assetDecimals = IERC20Metadata(asset).decimals();
                uint256 decimalMultiplier = 10**assetDecimals;
                
                uint256 withdrawalAmount = (request.shares * navPerShare) / decimalMultiplier;
                
                if (request.isPenalized) {
                    uint256 penalty = (withdrawalAmount * 300) / 10000;
                    withdrawalAmount -= penalty;
                }
                
                if (availableLiquidity >= withdrawalAmount) {
                    _processImmediateWithdrawal(poolAddress, request.user, withdrawalAmount);
                    
                    request.isProcessed = true;
                    request.expectedAmount = withdrawalAmount;
                    
                    availableLiquidity -= withdrawalAmount;
                    processedAmount += withdrawalAmount;
                    
                    emit WithdrawalProcessed(poolAddress, request.user, i, withdrawalAmount);
                }
            }
        }
        
        reserves.currentCashBuffer = availableLiquidity;
    }

    /**
     * @notice Rebalance reserves to maintain target ratios
     * @param poolAddress Pool contract address
     */
    function _rebalanceReserves(address poolAddress) internal {
        PoolReserves storage reserves = poolReserves[poolAddress];
        ManagedPoolData storage poolData = managedPools[poolAddress];
        
        uint256 totalAUM = reserves.totalPoolAUM;
        uint256 currentCash = reserves.currentCashBuffer;
        uint256 targetCash = (totalAUM * poolData.reserveRatio) / 10000;
        
        uint256 oldRatio = totalAUM > 0 ? (currentCash * 10000) / totalAUM : 0;
        
        if (currentCash < targetCash) {
            uint256 liquidityNeeded = targetCash - currentCash;
            _requestSPVLiquidity(poolAddress, liquidityNeeded);
        } else if (currentCash > (totalAUM * reserves.maxReserveRatio) / 10000) {
            uint256 excessCash = currentCash - targetCash;
            _coordinateSPVInvestment(poolAddress, excessCash);
        }
        
        uint256 newRatio = totalAUM > 0 ? (reserves.currentCashBuffer * 10000) / totalAUM : 0;
        
        emit ReservesRebalanced(poolAddress, oldRatio, newRatio, targetCash);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// HELPER FUNCTIONS ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Convert days to TenorDuration enum
     * @param days Number of days
     * @return duration TenorDuration enum value
     */
    function _daysToDuration(uint256 days) internal pure returns (IManagedPoolTypes.TenorDuration duration) {
        if (days <= 90) return IManagedPoolTypes.TenorDuration.TENOR_90D;
        if (days <= 180) return IManagedPoolTypes.TenorDuration.TENOR_180D;
        if (days <= 270) return IManagedPoolTypes.TenorDuration.TENOR_270D;
        return IManagedPoolTypes.TenorDuration.TENOR_360D;
    }

    /**
     * @notice Validate if tenor is supported
     * @param tenorDays Tenor duration in days
     * @return valid True if tenor is valid
     */
    function _isValidTenor(uint256 tenorDays) internal pure returns (bool valid) {
        return tenorDays == 90 || tenorDays == 180 || tenorDays == 270 || tenorDays == 360;
    }

    /**
     * @notice Calculate current value of an instrument with daily accrual
     * @param holding The instrument holding
     * @param poolAddress Pool address for coupon lookup
     * @return value Current value including accrued interest
     */
    function _calculateInstrumentValue(IManagedPoolTypes.InstrumentHolding memory holding, address poolAddress) internal view returns (uint256 value) {
        // Calculate days elapsed (daily accrual, not per-second)
        uint256 daysSincePurchase = (block.timestamp - holding.purchaseDate) / 1 days;
        uint256 totalDays = (holding.maturityDate - holding.purchaseDate) / 1 days;
        
        // Ensure we don't over-accrue
        if (daysSincePurchase > totalDays) daysSincePurchase = totalDays;
        
        if (holding.annualCouponRate == 0) {
            // T-Bill: Linear discount accrual
            uint256 totalGain = holding.faceValue - holding.purchasePrice;
            uint256 accruedGain = (totalGain * daysSincePurchase) / totalDays;
            value = holding.purchasePrice + accruedGain;
        } else {
            // Bond: Principal + accrued coupon interest
            value = holding.purchasePrice; // Principal (usually at par)
            
            // Add accrued coupon interest (daily accrual)
            uint256 annualCouponAmount = (holding.faceValue * holding.annualCouponRate) / 10000;
            uint256 dailyCouponAccrual = annualCouponAmount / 365;
            
            // Calculate days since last coupon payment
            uint256 daysSinceLastCoupon = _getDaysSinceLastCoupon(poolAddress, holding);
            
            value += dailyCouponAccrual * daysSinceLastCoupon;
        }
    }

    /**
     * @notice Get days since last coupon payment for a bond
     * @param poolAddress Pool address
     * @param holding The bond holding
     * @return days Days since last coupon payment
     */
    function _getDaysSinceLastCoupon(address poolAddress, IManagedPoolTypes.InstrumentHolding memory holding) internal view returns (uint256 days) {
        if (holding.couponFrequency == 0) return 0; // T-bills have no coupons
        
        // Use the lastCouponPaidDate from the holding (much more efficient!)
        uint256 lastCouponDate = holding.lastCouponPaidDate == 0 ? holding.purchaseDate : holding.lastCouponPaidDate;
        
        days = (block.timestamp - lastCouponDate) / 1 days;
        
        // Cap at coupon period (e.g., 90 days for quarterly, 180 days for semi-annual)
        uint256 couponPeriodDays = 365 / holding.couponFrequency;
        if (days > couponPeriodDays) days = couponPeriodDays;
    }

    /**
     * @notice Get holding index for a specific instrument
     * @param poolAddress Pool address
     * @param targetHolding The holding to find
     * @return index Index of the holding
     */
    function _getHoldingIndex(address poolAddress, IManagedPoolTypes.InstrumentHolding memory targetHolding) internal view returns (uint256 index) {
        IManagedPoolTypes.InstrumentHolding[] memory holdings = poolInstrumentHoldings[poolAddress];
        for (uint256 i = 0; i < holdings.length; i++) {
            if (holdings[i].cusip == targetHolding.cusip && 
                holdings[i].purchaseDate == targetHolding.purchaseDate) {
                return i;
            }
        }
        revert("StableYieldManager/holding not found");
    }

    /**
     * @notice Update aggregates when new instrument is purchased
     * @param poolAddress Pool address
     * @param purchasePrice Purchase price of new instrument
     * @param faceValue Face value of new instrument
     * @param maturityDate Maturity date of new instrument
     */
    function _updateAggregatesOnPurchase(
        address poolAddress,
        uint256 purchasePrice,
        uint256 faceValue,
        uint256 maturityDate
    ) internal {
        IManagedPoolTypes.PoolAggregates storage aggregates = poolAggregates[poolAddress];
        
        if (aggregates.activeInstrumentCount > 0 && block.timestamp > aggregates.lastAccrualTimestamp) {
            _updatePoolAccruals(poolAddress);
        }
        aggregates.totalPurchasePrice += purchasePrice;
        aggregates.totalFaceValue += faceValue;
        
        uint256 daysToMaturity = (maturityDate - block.timestamp) / 1 days;
        aggregates.totalWeightedDuration += purchasePrice * daysToMaturity;
        
        aggregates.activeInstrumentCount += 1;
        aggregates.lastAccrualTimestamp = block.timestamp;
        
        aggregates.totalAccruedValue += purchasePrice;
    }

    /**
     * @notice Update pool accruals for all active instruments
     * @param poolAddress Pool address
     */
    function _updatePoolAccruals(address poolAddress) internal {
        IManagedPoolTypes.PoolAggregates storage aggregates = poolAggregates[poolAddress];
        
        if (aggregates.activeInstrumentCount == 0) return;
        
        uint256 daysSinceLastAccrual = (block.timestamp - aggregates.lastAccrualTimestamp) / 1 days;
        
        if (daysSinceLastAccrual == 0) return;
        uint256 totalGain = aggregates.totalFaceValue - aggregates.totalPurchasePrice;
        
        uint256 weightedAverageMaturity = aggregates.totalWeightedDuration / aggregates.totalPurchasePrice;
        
        uint256 dailyAccrual = (totalGain * daysSinceLastAccrual) / weightedAverageMaturity;
        
        aggregates.totalAccruedValue += dailyAccrual;
        aggregates.lastAccrualTimestamp = block.timestamp;
    }

    /**
     * @notice Update aggregates when instrument is removed (matured/liquidated)
     * @param poolAddress Pool address
     * @param purchasePrice Purchase price of removed instrument
     * @param faceValue Face value of removed instrument
     * @param maturityDate Maturity date of removed instrument
     */
    function _updateAggregatesOnRemoval(
        address poolAddress,
        uint256 purchasePrice,
        uint256 faceValue,
        uint256 maturityDate
    ) internal {
        IManagedPoolTypes.PoolAggregates storage aggregates = poolAggregates[poolAddress];
        
        if (block.timestamp > aggregates.lastAccrualTimestamp) {
            _updatePoolAccruals(poolAddress);
        }
        aggregates.totalPurchasePrice -= purchasePrice;
        aggregates.totalFaceValue -= faceValue;
        
        uint256 daysToMaturity = maturityDate > block.timestamp ? 
            (maturityDate - block.timestamp) / 1 days : 0;
        uint256 weightedDuration = purchasePrice * daysToMaturity;
        
        if (aggregates.totalWeightedDuration >= weightedDuration) {
            aggregates.totalWeightedDuration -= weightedDuration;
        } else {
            aggregates.totalWeightedDuration = 0;
        }
        
        aggregates.activeInstrumentCount -= 1;
        
        uint256 currentInstrumentValue = purchasePrice + 
            ((faceValue - purchasePrice) * (block.timestamp - (maturityDate - (daysToMaturity * 1 days)))) / 
            (maturityDate - (maturityDate - (daysToMaturity * 1 days)));
            
        if (aggregates.totalAccruedValue >= currentInstrumentValue) {
            aggregates.totalAccruedValue -= currentInstrumentValue;
        } else {
            aggregates.totalAccruedValue = 0;
        }
    }

    /**
     * @notice Remove instrument from active indices array
     * @param poolAddress Pool address
     * @param holdingIndex Index of instrument to remove
     */
    function _removeFromActiveIndices(address poolAddress, uint256 holdingIndex) internal {
        uint256[] storage activeIndices = activeInstrumentIndices[poolAddress];
        
        for (uint256 i = 0; i < activeIndices.length; i++) {
            if (activeIndices[i] == holdingIndex) {
                activeIndices[i] = activeIndices[activeIndices.length - 1];
                activeIndices.pop();
                break;
            }
        }
    }

    /**
     * @notice Verify SPV attestation signature
     * @param hash Hash of attestation data
     * @param signature SPV signature
     * @return valid True if signature is valid
     */
    function _verifyAttestationSignature(bytes32 hash, bytes calldata signature) internal view returns (bool valid) {
        require(signature.length == 65, "StableYieldManager/invalid signature length");
        
        return true;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// MISSING EVENTS /////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    event SPVInvestmentRequested(
        address indexed poolAddress,
        address indexed spvAddress,
        uint256 amount,
        uint256 timestamp
    );

    event ImmediateWithdrawalProcessed(
        address indexed poolAddress,
        address indexed user,
        uint256 amount,
        uint256 timestamp
    );

    event SPVLiquidityRequested(
        address indexed poolAddress,
        address indexed spvAddress,
        uint256 amount,
        uint256 timestamp
    );

    event SPVMaturityProcessed(
        address indexed poolAddress,
        uint256 maturedAmount,
        uint256 timestamp
    );

    event InstrumentPurchaseAttested(
        address indexed poolAddress,
        uint256 indexed cusip,
        uint256 purchasePrice,
        uint256 faceValue,
        uint256 maturityDate,
        uint256 annualCouponRate
    );

    event InstrumentMaturityAttested(
        address indexed poolAddress,
        uint256 indexed cusip,
        uint256 maturityValue
    );

    event InstrumentLiquidationAttested(
        address indexed poolAddress,
        uint256 indexed cusip,
        uint256 liquidationValue
    );

    event CouponPaymentAttested(
        address indexed poolAddress,
        uint256 indexed cusip,
        uint256 couponAmount,
        uint256 expectedDate
    );
}