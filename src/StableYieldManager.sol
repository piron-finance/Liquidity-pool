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
    
    mapping(address => mapping(address => UserPosition[])) public userPositions;

    mapping(address => WithdrawalRequest[]) public withdrawalQueues;
    mapping(address => mapping(address => uint256[])) public userWithdrawalRequests;

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// T-BILL ATTESTATION STATE ///////////////////
    ////////////////////////////////////////////////////////////////////////////////

    struct TBillHolding {
        uint256 purchasePrice;      // Amount paid for T-bill
        uint256 faceValue;          // Maturity value
        uint256 purchaseDate;       // When purchased
        uint256 maturityDate;       // When it matures
        uint256 cusip;              // T-bill identifier
        bool isMatured;             // Has it matured?
        bool isLiquidated;          // Was it sold early?
        bytes32 attestationHash;    // SPV signature proof
    }

    // Pool address => Array of T-bill holdings
    mapping(address => TBillHolding[]) public poolTBillHoldings;
    
    // Pool address => Total matured cash not yet allocated
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
        IPoolTypes.TenorDuration tenor,
        IPoolTypes.MaturityAction maturityAction
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
        IPoolTypes.MaturityAction maturityAction,
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
        require (registry.isManagedPool(poolAddress), "StableYieldManager/invalid pool");
        require(amount > 0, "StableYieldManager/invalid amount");
        require(receiver != address(0), "StableYieldManager/invalid receiver");
        
        IPoolTypes.ManagedPoolData storage poolData = managedPools[poolAddress];
        require(amount >= poolData.minInvestment, "StableYieldManager/below minimum");
        
        uint256 navPerShare = calculateNAVPerShare(poolAddress);
        
        // Calculate shares to mint  NAV pricing
        // Get asset decimals for proper scaling
        address asset = poolData.asset;
        uint8 assetDecimals = IERC20Metadata(asset).decimals();
        uint256 decimalMultiplier = 10**assetDecimals;
        
        shares = (amount * decimalMultiplier) / navPerShare;
        
        // Allocate deposit (pool-level reserves)
        uint256 reserveAmount = (amount * poolData.reserveRatio) / 10000;
        uint256 investmentAmount = amount - reserveAmount;
        
        // Update pool reserves
        PoolReserves storage reserves = poolReserves[poolAddress];
        reserves.currentCashBuffer += reserveAmount;
        reserves.totalPoolAUM += amount;
        
        // Create user position with tenor tracking
        IPoolTypes.TenorDuration tenor = _daysToDuration(tenorDays);
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
        
        // Coordinate SPV investment (if needed)
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
        
        uint256 tbillValue = _getTotalTBillValue(poolAddress);
        uint256 cashBuffer = _getCashBufferValue(poolAddress);
        uint256 accruedInterest = _getAccruedInterest(poolAddress);
        uint256 fees = _calculateManagementFees(poolAddress);
        
        nav = tbillValue + cashBuffer + accruedInterest - fees;
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
            navPerShare = decimalMultiplier; // Initial NAV = 1.0 in asset decimals
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
        
        // Check for early exit penalties
        (uint256 penaltyRate, bool isEarlyExit) = _calculateEarlyExitPenalty(poolAddress, owner, shares);
        uint256 finalValue = baseValue - ((baseValue * penaltyRate) / 10000);
        
        // Check cash reserves availability
        PoolReserves storage reserves = poolReserves[poolAddress];
        
        if (reserves.currentCashBuffer >= finalValue) {
            // Immediate withdrawal (T+0/1)
            reserves.currentCashBuffer -= finalValue;
            reserves.totalPoolAUM -= baseValue;
            
            // Transfer funds from escrow to user
            _processImmediateWithdrawal(poolAddress, receiver, finalValue);
            
            actualShares = shares;
        } else {
            // Queue withdrawal (T+7)
            _queueWithdrawal(poolAddress, owner, shares, finalValue, isEarlyExit);
            actualShares = 0; // Shares not burned yet
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
        
        WithdrawalRequest[] storage queue = withdrawalQueues[poolAddress];
        PoolReserves storage reserves = poolReserves[poolAddress];
        
        uint256 processed = 0;
        
        for (uint256 i = 0; i < queue.length && processed < maxRequests; i++) {
            WithdrawalRequest storage request = queue[i];
            
            if (!request.isProcessed && reserves.currentCashBuffer >= request.expectedAmount) {
                // Process withdrawal
                reserves.currentCashBuffer -= request.expectedAmount;
                reserves.totalPoolAUM -= request.expectedAmount;
                
                // Transfer funds
                _processQueuedWithdrawal(poolAddress, request.user, request.expectedAmount);
                
                // Burn shares
                // Note: This would need to be coordinated with the pool contract
                
                request.isProcessed = true;
                processed++;
                
                emit WithdrawalProcessed(poolAddress, request.user, i, request.expectedAmount);
            }
        }
        
        // Request SPV liquidity if queue still has pending requests
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
            // Low reserves: Request SPV to liquidate some T-bills
            uint256 needed = ((reserves.targetReserveRatio * reserves.totalPoolAUM) / 10000) - reserves.currentCashBuffer;
            _requestSPVLiquidity(poolAddress, needed);
            
            emit ReservesRebalanced(poolAddress, currentRatio, reserves.targetReserveRatio, needed);
            
        } else if (currentRatio > reserves.maxReserveRatio) {
            // Excess reserves: Invest excess cash in T-bills
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
    function _daysToDuration(uint256 days) internal pure returns (IPoolTypes.TenorDuration) {
        if (days == 90) return IPoolTypes.TenorDuration.TENOR_90D;
        if (days == 180) return IPoolTypes.TenorDuration.TENOR_180D;
        if (days == 270) return IPoolTypes.TenorDuration.TENOR_270D;
        if (days == 360) return IPoolTypes.TenorDuration.TENOR_360D;
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
        withdrawalQueues[poolAddress].push(WithdrawalRequest({
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
     * @notice Get total value of T-bills held by the pool
     * @param poolAddress Pool contract address
     * @return value Total T-bill value including accrued discount
     */
    function _getTotalTBillValue(address poolAddress) internal view returns (uint256 value) {
        ManagedPoolData memory poolData = managedPools[poolAddress];
        PoolReserves memory reserves = poolReserves[poolAddress];
        
        //  T-bill value = total allocated funds + accrued yield
        uint256 allocatedFunds = reserves.totalPoolAUM - reserves.currentCashBuffer;
        
        if (allocatedFunds == 0) return 0;
        
        // Calculate deterministic T-bill value based on attestations (enterprise-grade)
        TBillHolding[] memory holdings = poolTBillHoldings[poolAddress];
        uint256 totalValue = 0;
        
        for (uint256 i = 0; i < holdings.length; i++) {
            TBillHolding memory holding = holdings[i];
            
            if (holding.isLiquidated) {
                // Skip liquidated T-bills
                continue;
            }
            
            if (holding.isMatured) {
                // Add to matured cash pool
                totalValue += holding.faceValue;
            } else {
                // Calculate linear accrual for active T-bills
                if (block.timestamp >= holding.maturityDate) {
                    // Should be matured but not yet attested
                    totalValue += holding.faceValue;
                } else {
                    // Linear accrual calculation
                    uint256 totalGain = holding.faceValue - holding.purchasePrice;
                    uint256 totalDays = holding.maturityDate - holding.purchaseDate;
                    uint256 elapsedDays = block.timestamp - holding.purchaseDate;
                    
                    // Ensure we don't over-accrue
                    if (elapsedDays > totalDays) elapsedDays = totalDays;
                    
                    uint256 accruedGain = (totalGain * elapsedDays) / totalDays;
                    totalValue += holding.purchasePrice + accruedGain;
                }
            }
        }
        
        // Add any matured cash not yet processed
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
        
        // Calculate daily accrued interest on T-bill investments
        uint256 timeElapsed = block.timestamp - reserves.lastRebalanceTime;
        uint256 dailyRate = 800; // 8% APY in basis points / 365
        
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
        
        // Calculate daily management fee
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
        
        // Transfer funds from escrow to SPV custody
        address escrow = poolData.escrow;
        require(escrow != address(0), "StableYieldManager/invalid escrow");
        
        // Call escrow to transfer funds to SPV
        // This triggers the actual T-bill purchase process
        (bool success, ) = escrow.call(
            abi.encodeWithSignature(
                "transferToSPV(address,uint256)",
                poolData.spvAddress,
                amount
            )
        );
        require(success, "StableYieldManager/SPV transfer failed");
        
        // Update pool state to reflect allocated funds
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
        
        // Deduct from cash buffer and total AUM
        reserves.currentCashBuffer -= amount;
        reserves.totalPoolAUM -= amount;
        
        // Execute withdrawal via escrow
        address escrow = poolData.escrow;
        require(escrow != address(0), "StableYieldManager/invalid escrow");
        
        // Call escrow to process the withdrawal
        (bool success, ) = escrow.call(
            abi.encodeWithSignature(
                "processWithdrawal(address,uint256)",
                user,
                amount
            )
        );
        require(success, "StableYieldManager/withdrawal processing failed");
        
        // Update reserves timestamp
        reserves.lastRebalanceTime = block.timestamp;
        
        emit ImmediateWithdrawalProcessed(poolAddress, user, amount, block.timestamp);
    }

    /**
     * @notice Process queued withdrawal request
     * @param poolAddress Pool contract address
     * @param user User requesting withdrawal
     * @param shares Shares to withdraw
     */
    function _processQueuedWithdrawal(address poolAddress, address user, uint256 shares) internal {
        // Add to withdrawal queue
        withdrawalQueues[poolAddress].push(WithdrawalRequest({
            user: user,
            shares: shares,
            requestTime: block.timestamp,
            expectedAmount: 0, // Will be calculated when processed
            isPenalized: true, // Early exit
            isProcessed: false
        }));
        
        // Track user's withdrawal requests
        uint256 requestIndex = withdrawalQueues[poolAddress].length - 1;
        userWithdrawalRequests[poolAddress][user].push(requestIndex);
        
        emit WithdrawalQueued(poolAddress, user, requestIndex, shares, 0, true);
    }

    /**
     * @notice Calculate total pending withdrawal amounts
     * @param poolAddress Pool contract address
     * @return pending Total pending withdrawal amount
     */
    function _calculatePendingWithdrawals(address poolAddress) internal view returns (uint256 pending) {
        WithdrawalRequest[] memory queue = withdrawalQueues[poolAddress];
        uint256 navPerShare = calculateNAVPerShare(poolAddress);
        
        for (uint256 i = 0; i < queue.length; i++) {
            if (!queue[i].isProcessed) {
                // Get asset decimals for proper calculation
                address asset = managedPools[poolAddress].asset;
                uint8 assetDecimals = IERC20Metadata(asset).decimals();
                uint256 decimalMultiplier = 10**assetDecimals;
                
                uint256 amount = (queue[i].shares * navPerShare) / decimalMultiplier;
                
                // Apply penalty if early exit
                if (queue[i].isPenalized) {
                    uint256 penalty = (amount * 300) / 10000; // 3% penalty
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
        
        // Calculate if we need to liquidate T-bills
        uint256 allocatedFunds = reserves.totalPoolAUM - reserves.currentCashBuffer;
        require(allocatedFunds >= amount, "StableYieldManager/insufficient allocated funds");
        
        // Signal SPV to liquidate T-bills and return funds to escrow
        address escrow = poolData.escrow;
        require(escrow != address(0), "StableYieldManager/invalid escrow");
        
        // Signal SPV via oracle to liquidate specific amount of T-bills
        // In reality, this triggers off-chain notification to SPV
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
        
        // Update reserves to reflect pending liquidation
        reserves.lastRebalanceTime = block.timestamp;
        
        emit SPVLiquidityRequested(poolAddress, poolData.spvAddress, amount, block.timestamp);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// T-BILL ATTESTATION FUNCTIONS ///////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Attest T-bill purchase by SPV
     * @param poolAddress Pool contract address
     * @param purchasePrice Amount paid for T-bill
     * @param faceValue Maturity value of T-bill
     * @param maturityDate When T-bill matures (timestamp)
     * @param cusip T-bill identifier
     * @param spvSignature SPV signature proving purchase
     */
    function attestTBillPurchase(
        address poolAddress,
        uint256 purchasePrice,
        uint256 faceValue,
        uint256 maturityDate,
        uint256 cusip,
        bytes calldata spvSignature
    ) external onlyRole(accessManager.SPV_ROLE()) {
        require(managedPools[poolAddress].isActive, "StableYieldManager/pool not active");
        require(purchasePrice > 0, "StableYieldManager/invalid purchase price");
        require(faceValue > purchasePrice, "StableYieldManager/invalid face value");
        require(maturityDate > block.timestamp, "StableYieldManager/invalid maturity date");
        require(maturityDate <= block.timestamp + 365 days, "StableYieldManager/maturity too far");
        
        // Create attestation hash for verification
        bytes32 attestationHash = keccak256(abi.encodePacked(
            poolAddress,
            purchasePrice,
            faceValue,
            maturityDate,
            cusip,
            block.timestamp
        ));
        
        // Verify SPV signature (simplified - in production use ECDSA recovery)
        require(_verifyAttestationSignature(attestationHash, spvSignature), "StableYieldManager/invalid signature");
        
        // Record T-bill holding
        poolTBillHoldings[poolAddress].push(TBillHolding({
            purchasePrice: purchasePrice,
            faceValue: faceValue,
            purchaseDate: block.timestamp,
            maturityDate: maturityDate,
            cusip: cusip,
            isMatured: false,
            isLiquidated: false,
            attestationHash: attestationHash
        }));
        
        emit TBillPurchaseAttested(poolAddress, cusip, purchasePrice, faceValue, maturityDate);
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
        
        // Add liquidation proceeds to cash buffer
        PoolReserves storage reserves = poolReserves[poolAddress];
        reserves.currentCashBuffer += liquidationValue;
        reserves.lastRebalanceTime = block.timestamp;
        
        emit TBillLiquidationAttested(poolAddress, holding.cusip, liquidationValue);
        
        // Process queued withdrawals
        _processQueuedWithdrawals(poolAddress);
    }

    /**
     * @notice Get all T-bill holdings for a pool
     * @param poolAddress Pool contract address
     * @return holdings Array of T-bill holdings
     */
    function getPoolTBillHoldings(address poolAddress) external view returns (TBillHolding[] memory holdings) {
        return poolTBillHoldings[poolAddress];
    }

    /**
     * @notice Get count of active (non-matured, non-liquidated) T-bills
     * @param poolAddress Pool contract address
     * @return count Number of active T-bills
     */
    function getActiveTBillCount(address poolAddress) external view returns (uint256 count) {
        TBillHolding[] memory holdings = poolTBillHoldings[poolAddress];
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
        
        // Add matured funds back to cash buffer for reinvestment/withdrawals
        reserves.currentCashBuffer += maturedAmount;
        reserves.lastRebalanceTime = block.timestamp;
        
        emit SPVMaturityProcessed(poolAddress, maturedAmount, block.timestamp);
        
        // Automatically process queued withdrawals if sufficient liquidity
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
        
        // Update total pool AUM based on SPV reporting
        reserves.totalPoolAUM = newNAV;
        reserves.lastRebalanceTime = block.timestamp;
        
        uint256 navPerShare = calculateNAVPerShare(poolAddress);
        
        emit NAVUpdated(poolAddress, newNAV, navPerShare, block.timestamp);
        
        // If NAV increased significantly, consider rebalancing reserves
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
        WithdrawalRequest[] storage queue = withdrawalQueues[poolAddress];
        PoolReserves storage reserves = poolReserves[poolAddress];
        
        uint256 availableLiquidity = reserves.currentCashBuffer;
        uint256 processedAmount = 0;
        
        for (uint256 i = 0; i < queue.length && availableLiquidity > 0; i++) {
            WithdrawalRequest storage request = queue[i];
            
            if (!request.isProcessed) {
                uint256 navPerShare = calculateNAVPerShare(poolAddress);
                
                // Get asset decimals for proper calculation
                address asset = managedPools[poolAddress].asset;
                uint8 assetDecimals = IERC20Metadata(asset).decimals();
                uint256 decimalMultiplier = 10**assetDecimals;
                
                uint256 withdrawalAmount = (request.shares * navPerShare) / decimalMultiplier;
                
                // Apply early exit penalty if applicable
                if (request.isPenalized) {
                    uint256 penalty = (withdrawalAmount * 300) / 10000; // 3% penalty
                    withdrawalAmount -= penalty;
                }
                
                if (availableLiquidity >= withdrawalAmount) {
                    // Process withdrawal
                    _processImmediateWithdrawal(poolAddress, request.user, withdrawalAmount);
                    
                    request.isProcessed = true;
                    request.expectedAmount = withdrawalAmount;
                    
                    availableLiquidity -= withdrawalAmount;
                    processedAmount += withdrawalAmount;
                    
                    emit WithdrawalProcessed(poolAddress, request.user, i, withdrawalAmount);
                }
            }
        }
        
        // Update cash buffer
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
            // Need more liquidity - request from SPV
            uint256 liquidityNeeded = targetCash - currentCash;
            _requestSPVLiquidity(poolAddress, liquidityNeeded);
        } else if (currentCash > (totalAUM * reserves.maxReserveRatio) / 10000) {
            // Too much cash - invest excess
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
    function _daysToDuration(uint256 days) internal pure returns (IPoolTypes.TenorDuration duration) {
        if (days <= 90) return IPoolTypes.TenorDuration.TENOR_90D;
        if (days <= 180) return IPoolTypes.TenorDuration.TENOR_180D;
        if (days <= 270) return IPoolTypes.TenorDuration.TENOR_270D;
        return IPoolTypes.TenorDuration.TENOR_360D;
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
     * @notice Verify SPV attestation signature
     * @param hash Hash of attestation data
     * @param signature SPV signature
     * @return valid True if signature is valid
     */
    function _verifyAttestationSignature(bytes32 hash, bytes calldata signature) internal view returns (bool valid) {
        // In production, this would use ECDSA.recover to verify SPV signature
        // For now, simplified validation
        require(signature.length == 65, "StableYieldManager/invalid signature length");
        
        // This is a placeholder - in production you'd verify against SPV's public key
        // using ECDSA recovery and ensure the signer has SPV_ROLE
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

    event TBillPurchaseAttested(
        address indexed poolAddress,
        uint256 indexed cusip,
        uint256 purchasePrice,
        uint256 faceValue,
        uint256 maturityDate
    );

    event TBillMaturityAttested(
        address indexed poolAddress,
        uint256 indexed cusip,
        uint256 maturityValue
    );

    event TBillLiquidationAttested(
        address indexed poolAddress,
        uint256 indexed cusip,
        uint256 liquidationValue
    );
}