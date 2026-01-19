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
import "./interfaces/ILockedPoolManager.sol";
import "./escrows/LockedPoolEscrow.sol";
import "./escrows/YieldReserveEscrow.sol";
import "./types/ILockedPoolTypes.sol";
import "./libraries/LockedPoolLibrary.sol";

/**
 * @title LockedPoolManager
 * @dev Manages locked pool business logic
 * @notice Handles deposits, redemptions, early exits, and SPV coordination
 */

contract LockedPoolManager is 
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    ILockedPoolManager
{
    error Unauthorized();
    error PoolNotFound();
    error PoolNotActive();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidTier();
    error InvalidAPY();
    error InvalidPenalty();
    error InvalidDuration();
    error TierNotActive();
    error BelowMinimum();
    error NotOwner();
    error NotMatured();
    error AlreadyMatured();
    error AlreadyRedeemed();
    error AlreadyExited();
    error InvalidStatus();
    error InsufficientFunds();
    error InsufficientReserve();
    error AllocationNotFound();
    error AllocationExists();
    error OnlyPool();
    error OnlyTimelock();
    error OnlyFactory();
    error FactoryAlreadySet();
    error PoolAlreadyExists();
    error InvalidDecimals();
    error AssetNotApproved();
    error RolloverNotEnabled();
    error InvalidPosition();
    error NoYieldReserve();

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STATE VARIABLES //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    using SafeERC20 for IERC20;
    AccessManager public accessManager;
    IPoolRegistry public registry;
    
    address public timelockController;
    address public managedPoolFactory;
    
    uint256 public version;

    uint256 public nextPositionId;
    address public yieldReserve;

    uint8 public constant MAX_TIERS = 5;

    mapping(address => ILockedPoolTypes.PoolConfig) public poolConfigs;
    mapping(address => address) public poolEscrows;
    mapping(address => ILockedPoolTypes.LockTier[]) public poolTiers;
    mapping(address => ILockedPoolTypes.PoolMetrics) public poolMetrics;

    mapping(uint256 => ILockedPoolTypes.UserPosition) public positions;
    mapping(address => mapping(address => uint256[])) public userPositionIds;

    mapping(address => uint256) public totalSPVAllocations;
    mapping(address => mapping(address => uint256)) public poolToSPVAllocations;
    mapping(bytes32 => ILockedPoolTypes.SPVAllocation) public spvAllocations;
    mapping(address => bytes32[]) public poolAllocationIds;


    
    mapping(address => ILockedPoolTypes.PoolProtocolAccounting) public poolAccounting;
    mapping(uint256 => ILockedPoolTypes.DebtPosition) public debtPositions;
    mapping(address => uint256[]) public poolDebtPositionIds;

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// MODIFIERS ///////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    modifier onlyRole(bytes32 role) {
        _checkRole(role);
        _;
    }

    modifier poolExists(address poolAddress) {
        _checkPoolExists(poolAddress);
        _;
    }

    modifier activePool(address poolAddress) {
        _checkActivePool(poolAddress);
        _;
    }

    function _checkRole(bytes32 role) internal view {
        if (!accessManager.hasRole(role, msg.sender)) revert Unauthorized();
    }

    function _checkPoolExists(address poolAddress) internal view {
        if (poolConfigs[poolAddress].createdAt == 0) revert PoolNotFound();
    }

    function _checkActivePool(address poolAddress) internal view {
        if (!poolConfigs[poolAddress].isActive) revert PoolNotActive();
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INITIALIZATION /////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the LockedPoolManager
     * @param accessManager_ AccessManager contract address
     * @param registry_ PoolRegistry contract address
     * @param timelockController_ Timelock controller address
     */
    function initialize(
        address accessManager_,
        address registry_,
        address timelockController_
    ) public initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        if (accessManager_ == address(0)) revert InvalidAddress();
        if (registry_ == address(0)) revert InvalidAddress();
        if (timelockController_ == address(0)) revert InvalidAddress();

        accessManager = AccessManager(accessManager_);
        registry = IPoolRegistry(registry_);
        timelockController = timelockController_;
        version = 1;
        nextPositionId = 1;
    }

    function _authorizeUpgrade(address newImplementation) internal override {
        if (msg.sender != timelockController) revert OnlyTimelock();
        if (newImplementation == address(0)) revert InvalidAddress();
        version += 1;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// POOL REGISTRATION ///////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Register a new locked pool
     */
    function registerPool(
        address poolAddress,
        address escrowAddress,
        address asset,
        string memory name,
        uint256 minInvestment
    ) external override nonReentrant {
        if (msg.sender != managedPoolFactory) revert OnlyFactory();
        if (poolAddress == address(0)) revert InvalidAddress();
        if (escrowAddress == address(0)) revert InvalidAddress();
        if (asset == address(0)) revert InvalidAddress();
        if (minInvestment == 0) revert InvalidAmount();
        if (poolConfigs[poolAddress].createdAt != 0) revert PoolAlreadyExists();
        
        uint8 assetDecimals = IERC20Metadata(asset).decimals();
        if (assetDecimals != 6 && assetDecimals != 18) revert InvalidDecimals();
        if (!registry.isApprovedAsset(asset)) revert AssetNotApproved();
        
        poolConfigs[poolAddress] = ILockedPoolTypes.PoolConfig({
            asset: asset,
            name: name,
            minInvestment: minInvestment,
            isActive: true,
            createdAt: block.timestamp
        });
        
        poolEscrows[poolAddress] = escrowAddress;
        
        emit PoolRegistered(poolAddress, escrowAddress, asset, name);
    }

    /**
     * @notice Set the ManagedPoolFactory address
     */
    function setManagedPoolFactory(address _factory) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        if (_factory == address(0)) revert InvalidAddress();
        if (managedPoolFactory != address(0)) revert FactoryAlreadySet();
        managedPoolFactory = _factory;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// TIER CONFIGURATION //////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Configure a lock tier for a pool
     * @dev Callable by operator or factory (during pool creation)
     */
    function configureLockTier(
        address poolAddress,
        uint8 tierIndex,
        ILockedPoolTypes.LockTier memory tier
    ) external override poolExists(poolAddress) {
        if (!accessManager.hasRole(accessManager.OPERATOR_ROLE(), msg.sender) && msg.sender != managedPoolFactory) {
            revert Unauthorized();
        }
        if (tierIndex >= MAX_TIERS) revert InvalidTier();
        if (tier.durationDays == 0) revert InvalidDuration();
        if (tier.apyBps == 0 || tier.apyBps > 5000) revert InvalidAPY();
        if (tier.earlyExitPenaltyBps > 5000) revert InvalidPenalty();
        
        ILockedPoolTypes.LockTier[] storage tiers = poolTiers[poolAddress];
        
        if (tierIndex < tiers.length) {
            tiers[tierIndex] = tier;
        } else if (tierIndex == tiers.length) {
            tiers.push(tier);
        } else {
            revert InvalidTier();
        }
        
        emit LockTierConfigured(
            poolAddress,
            tierIndex,
            tier.durationDays,
            tier.apyBps,
            tier.earlyExitPenaltyBps
        );
    }

    /**
     * @notice Set tier active status
     */
    function setTierActive(
        address poolAddress,
        uint8 tierIndex,
        bool isActive
    ) external override onlyRole(accessManager.OPERATOR_ROLE()) poolExists(poolAddress) {
        if (tierIndex >= poolTiers[poolAddress].length) revert InvalidTier();
        poolTiers[poolAddress][tierIndex].isActive = isActive;
    }

    /**
     * @notice Update tier APY for new deposits
     */
    function updateTierAPY(
        address poolAddress,
        uint8 tierIndex,
        uint256 newApyBps
    ) external override onlyRole(accessManager.OPERATOR_ROLE()) poolExists(poolAddress) {
        if (tierIndex >= poolTiers[poolAddress].length) revert InvalidTier();
        if (newApyBps == 0 || newApyBps > 5000) revert InvalidAPY();
        poolTiers[poolAddress][tierIndex].apyBps = newApyBps;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// USER FUNCTIONS ///////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Process deposit and create locked position
     * @dev Called by LockedPool after transferring funds to escrow
     */
    function processDeposit(
        address poolAddress,
        address depositor,
        uint256 amount,
        uint8 tierIndex,
        ILockedPoolTypes.InterestPayment paymentChoice
    ) external override poolExists(poolAddress) activePool(poolAddress) nonReentrant returns (uint256 positionId, uint256 shares) {
        if (msg.sender != poolAddress) revert OnlyPool();
        if (depositor == address(0)) revert InvalidAddress();
        
        ILockedPoolTypes.PoolConfig storage config = poolConfigs[poolAddress];
        if (amount < config.minInvestment) revert BelowMinimum();
        
        ILockedPoolTypes.LockTier storage tier = poolTiers[poolAddress][tierIndex];
        if (!tier.isActive) revert TierNotActive();
        if (amount < tier.minDeposit) revert BelowMinimum();
        
        LockedPoolEscrow escrow = LockedPoolEscrow(poolEscrows[poolAddress]);
        escrow.recordDeposit(amount);
        
        positionId = nextPositionId++;
        
        ILockedPoolTypes.LockTier memory tierMem = tier;
        positions[positionId] = LockedPoolLibrary.buildPosition(
            positionId,
            depositor,
            poolAddress,
            amount,
            tierMem,
            tierIndex,
            paymentChoice,
            block.timestamp
        );
        
        userPositionIds[poolAddress][depositor].push(positionId);
        
        ILockedPoolTypes.UserPosition storage pos = positions[positionId];
        ILockedPoolTypes.PoolMetrics storage metrics = poolMetrics[poolAddress];
        metrics.totalPrincipalLocked += amount;
        metrics.totalInterestCommitted += pos.fullInterestAmount;
        metrics.totalInvestedAmount += pos.investedAmount;
        metrics.totalExpectedMaturityPayout += pos.expectedMaturityPayout;
        metrics.activePositions++;
        metrics.totalPositions++;
        
        if (paymentChoice == ILockedPoolTypes.InterestPayment.UPFRONT) {
            escrow.payInterest(depositor, pos.fullInterestAmount);
            metrics.totalInterestPaidUpfront += pos.fullInterestAmount;
            emit InterestPaidUpfront(poolAddress, depositor, positionId, pos.fullInterestAmount);
        } else {
            metrics.totalInterestPendingMaturity += pos.fullInterestAmount;
        }
        
        shares = pos.investedAmount;
        
        emit PositionCreated(
            poolAddress,
            depositor,
            positionId,
            amount,
            pos.fullInterestAmount,
            paymentChoice,
            pos.lockEnd
        );
        
        return (positionId, shares);
    }

    /**
     * @notice Redeem position at maturity
     * @param poolAddress Pool address
     * @param positionId Position to redeem
     * @param caller Actual user requesting redemption (passed by Pool)
     */
    function redeem(
        address poolAddress,
        uint256 positionId,
        address caller
    ) external override poolExists(poolAddress) nonReentrant returns (uint256 payout) {
        if (msg.sender != poolAddress) revert OnlyPool();
        
        ILockedPoolTypes.UserPosition storage position = positions[positionId];
        
        if (position.user != caller) revert NotOwner();
        if (position.status != ILockedPoolTypes.PositionStatus.ACTIVE && 
            position.status != ILockedPoolTypes.PositionStatus.MATURED) revert InvalidStatus();
        if (block.timestamp < position.lockEnd) revert NotMatured();
        
        payout = position.expectedMaturityPayout;
        
        position.status = ILockedPoolTypes.PositionStatus.REDEEMED;
        position.actualPayout = payout;
        
        // Set interestEarned for AT_MATURITY positions (UPFRONT already set at deposit)
        if (position.paymentChoice == ILockedPoolTypes.InterestPayment.AT_MATURITY) {
            position.interestEarned = position.fullInterestAmount;
        }
        
        ILockedPoolTypes.PoolMetrics storage metrics = poolMetrics[poolAddress];
        metrics.activePositions--;
        metrics.totalPrincipalLocked -= position.principalDeposited;
        metrics.totalExpectedMaturityPayout -= position.expectedMaturityPayout;
        
        if (position.paymentChoice == ILockedPoolTypes.InterestPayment.AT_MATURITY) {
            metrics.totalInterestPendingMaturity -= position.fullInterestAmount;
        }
        
        LockedPoolEscrow escrow = LockedPoolEscrow(poolEscrows[poolAddress]);
        escrow.withdraw(caller, payout);
        
        emit PositionRedeemed(poolAddress, caller, positionId, payout);
        
        return payout;
    }

    /**
     * @notice Mark positions as matured (batch operation)
     * @dev Allows operators to mark matured positions for reporting/tracking
     * @param positionIds Array of position IDs to mature
     * @return maturedCount Number of positions successfully matured
     */
    function batchMaturePositions(
        uint256[] calldata positionIds
    ) external onlyRole(accessManager.OPERATOR_ROLE()) returns (uint256 maturedCount) {
        for (uint256 i = 0; i < positionIds.length; i++) {
            ILockedPoolTypes.UserPosition storage position = positions[positionIds[i]];
            
            // Skip if not eligible for maturation
            if (position.status != ILockedPoolTypes.PositionStatus.ACTIVE) continue;
            if (block.timestamp < position.lockEnd) continue;
            
            position.status = ILockedPoolTypes.PositionStatus.MATURED;
            maturedCount++;
            
            emit PositionMatured(position.poolAddress, position.user, positionIds[i], position.lockEnd);
        }
        
        return maturedCount;
    }

    /**
     * @notice Check if a position can be matured
     * @param positionId Position to check
     * @return canMature Whether position is eligible for maturation
     */
    function canMaturePosition(uint256 positionId) external view returns (bool canMature) {
        ILockedPoolTypes.UserPosition storage position = positions[positionId];
        return position.status == ILockedPoolTypes.PositionStatus.ACTIVE && 
               block.timestamp >= position.lockEnd;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// AUTO-ROLLOVER /////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Set auto-rollover preference for a position
     * @param positionId Position to configure
     * @param enabled Whether to enable auto-rollover
     * @param caller User setting the preference (passed by Pool)
     */
    function setAutoRollover(
        uint256 positionId,
        bool enabled,
        address caller
    ) external override {
        ILockedPoolTypes.UserPosition storage position = positions[positionId];
        
        if (msg.sender != position.poolAddress) revert OnlyPool();
        if (position.user != caller) revert NotOwner();
        if (position.status != ILockedPoolTypes.PositionStatus.ACTIVE && 
            position.status != ILockedPoolTypes.PositionStatus.MATURED) revert InvalidStatus();
        
        position.autoRollover = enabled;
        
        emit AutoRolloverSet(positionId, caller, enabled);
    }

    /**
     * @notice Execute rollover for a matured position with auto-rollover enabled
     * @dev For UPFRONT: principal rolls, new interest paid upfront
     *      For AT_MATURITY: principal + interest compounds
     * @param positionId Position to rollover
     * @return newPositionId ID of the new position created
     */
    function executeRollover(
        uint256 positionId
    ) external override onlyRole(accessManager.OPERATOR_ROLE()) returns (uint256 newPositionId) {
        ILockedPoolTypes.UserPosition storage position = positions[positionId];
        
        if (position.status != ILockedPoolTypes.PositionStatus.ACTIVE && 
            position.status != ILockedPoolTypes.PositionStatus.MATURED) revert InvalidStatus();
        if (block.timestamp < position.lockEnd) revert NotMatured();
        if (!position.autoRollover) revert RolloverNotEnabled();
        
        address poolAddress = position.poolAddress;
        ILockedPoolTypes.LockTier storage tier = poolTiers[poolAddress][position.tierIndex];
        if (!tier.isActive) revert TierNotActive();
        
        // Calculate rollover amounts based on interest payment choice
        uint256 principalToRoll;
        uint256 interestHandled;
        
        if (position.paymentChoice == ILockedPoolTypes.InterestPayment.UPFRONT) {
            // UPFRONT: Only principal rolls, interest already paid
            principalToRoll = position.principalDeposited;
            interestHandled = position.fullInterestAmount; // Already paid at original deposit
        } else {
            // AT_MATURITY: Principal + interest compounds
            principalToRoll = position.principalDeposited + position.fullInterestAmount;
            interestHandled = position.fullInterestAmount; // Compounded into new principal
            position.interestEarned = position.fullInterestAmount;
        }
        
        // Mark old position as rolled over
        position.status = ILockedPoolTypes.PositionStatus.ROLLED_OVER;
        position.actualPayout = 0; // No payout, funds rolled
        
        // Update metrics for old position closure
        ILockedPoolTypes.PoolMetrics storage metrics = poolMetrics[poolAddress];
        metrics.activePositions--;
        metrics.totalPrincipalLocked -= position.principalDeposited;
        metrics.totalExpectedMaturityPayout -= position.expectedMaturityPayout;
        
        if (position.paymentChoice == ILockedPoolTypes.InterestPayment.AT_MATURITY) {
            metrics.totalInterestPendingMaturity -= position.fullInterestAmount;
        }
        
        // Create new position (reuses existing deposit logic path)
        newPositionId = _createRolloverPosition(
            poolAddress,
            position.user,
            principalToRoll,
            position.tierIndex,
            position.paymentChoice,
            positionId
        );
        
        emit PositionRolledOver(
            poolAddress,
            position.user,
            positionId,
            newPositionId,
            principalToRoll,
            interestHandled
        );
        
        return newPositionId;
    }

    /**
     * @notice Batch execute rollovers for multiple positions
     * @param positionIds Array of position IDs to rollover
     * @return newPositionIds Array of new position IDs created
     */
    function batchExecuteRollovers(
        uint256[] calldata positionIds
    ) external override onlyRole(accessManager.OPERATOR_ROLE()) returns (uint256[] memory newPositionIds) {
        newPositionIds = new uint256[](positionIds.length);
        
        for (uint256 i = 0; i < positionIds.length; i++) {
            ILockedPoolTypes.UserPosition storage position = positions[positionIds[i]];
            
            // Skip positions that can't be rolled over
            if (position.status != ILockedPoolTypes.PositionStatus.ACTIVE &&
                position.status != ILockedPoolTypes.PositionStatus.MATURED) {
                continue;
            }
            if (block.timestamp < position.lockEnd) continue;
            if (!position.autoRollover) continue;
            
            ILockedPoolTypes.LockTier storage tier = poolTiers[position.poolAddress][position.tierIndex];
            if (!tier.isActive) continue;
            
            // Execute individual rollover (inline for gas efficiency)
            newPositionIds[i] = _executeRolloverInternal(positionIds[i], position);
        }
        
        return newPositionIds;
    }

    /**
     * @dev Internal function to create a new position from rollover
     */
    function _createRolloverPosition(
        address poolAddress,
        address user,
        uint256 principal,
        uint8 tierIndex,
        ILockedPoolTypes.InterestPayment paymentChoice,
        uint256 rolledFromId
    ) internal returns (uint256 newPositionId) {
        ILockedPoolTypes.LockTier storage tier = poolTiers[poolAddress][tierIndex];
        
        newPositionId = nextPositionId++;
        
        ILockedPoolTypes.LockTier memory tierMem = tier;
        positions[newPositionId] = LockedPoolLibrary.buildPosition(
            newPositionId, user, poolAddress, principal,
            tierMem, tierIndex, paymentChoice, block.timestamp
        );
        positions[newPositionId].autoRollover = true;
        positions[newPositionId].rolledFromPositionId = rolledFromId;
        
        userPositionIds[poolAddress][user].push(newPositionId);
        
        ILockedPoolTypes.UserPosition storage pos = positions[newPositionId];
        ILockedPoolTypes.PoolMetrics storage metrics = poolMetrics[poolAddress];
        metrics.totalPrincipalLocked += principal;
        metrics.totalInterestCommitted += pos.fullInterestAmount;
        metrics.totalInvestedAmount += pos.investedAmount;
        metrics.totalExpectedMaturityPayout += pos.expectedMaturityPayout;
        metrics.activePositions++;
        metrics.totalPositions++;
        
        if (paymentChoice == ILockedPoolTypes.InterestPayment.UPFRONT) {
            LockedPoolEscrow escrow = LockedPoolEscrow(poolEscrows[poolAddress]);
            escrow.payInterest(user, pos.fullInterestAmount);
            metrics.totalInterestPaidUpfront += pos.fullInterestAmount;
            emit InterestPaidUpfront(poolAddress, user, newPositionId, pos.fullInterestAmount);
        } else {
            metrics.totalInterestPendingMaturity += pos.fullInterestAmount;
        }
        
        emit PositionCreated(
            poolAddress, user, newPositionId, principal,
            pos.fullInterestAmount, paymentChoice, pos.lockEnd
        );
        
        return newPositionId;
    }

    /**
     * @dev Internal rollover execution for batch operations
     */
    function _executeRolloverInternal(
        uint256 positionId,
        ILockedPoolTypes.UserPosition storage position
    ) internal returns (uint256 newPositionId) {
        address poolAddress = position.poolAddress;
        
        uint256 principalToRoll;
        uint256 interestHandled;
        
        if (position.paymentChoice == ILockedPoolTypes.InterestPayment.UPFRONT) {
            principalToRoll = position.principalDeposited;
            interestHandled = position.fullInterestAmount;
        } else {
            principalToRoll = position.principalDeposited + position.fullInterestAmount;
            interestHandled = position.fullInterestAmount;
            position.interestEarned = position.fullInterestAmount;
        }
        
        position.status = ILockedPoolTypes.PositionStatus.ROLLED_OVER;
        position.actualPayout = 0;
        
        ILockedPoolTypes.PoolMetrics storage metrics = poolMetrics[poolAddress];
        metrics.activePositions--;
        metrics.totalPrincipalLocked -= position.principalDeposited;
        metrics.totalExpectedMaturityPayout -= position.expectedMaturityPayout;
        
        if (position.paymentChoice == ILockedPoolTypes.InterestPayment.AT_MATURITY) {
            metrics.totalInterestPendingMaturity -= position.fullInterestAmount;
        }
        
        newPositionId = _createRolloverPosition(
            poolAddress,
            position.user,
            principalToRoll,
            position.tierIndex,
            position.paymentChoice,
            positionId
        );
        
        emit PositionRolledOver(
            poolAddress,
            position.user,
            positionId,
            newPositionId,
            principalToRoll,
            interestHandled
        );
        
        return newPositionId;
    }

    /**
     * @notice Early withdrawal with penalty
     * @dev Uses yield reserve loan if escrow has insufficient funds
     * @param poolAddress Pool address
     * @param positionId Position to exit
     * @param caller Actual user requesting early exit (passed by Pool)
     */
    function earlyWithdraw(
        address poolAddress,
        uint256 positionId,
        address caller
    ) external override poolExists(poolAddress) nonReentrant returns (uint256 payout, uint256 penalty) {
        if (msg.sender != poolAddress) revert OnlyPool();
        
        ILockedPoolTypes.UserPosition storage position = positions[positionId];
        _validateEarlyExit(position, caller);
        
        ILockedPoolTypes.LockTier storage tier = poolTiers[poolAddress][position.tierIndex];
        ILockedPoolTypes.EarlyExitCalculation memory calc = _calculateEarlyExit(position, tier);
        
        payout = calc.payout;
        penalty = calc.penalty;
        
        _updatePositionForEarlyExit(position, calc);
        _updateMetricsForEarlyExit(poolAddress, position);
        _processEarlyExitPayment(poolAddress, positionId, position.user, payout, penalty);
        
        emit EarlyExitProcessed(poolAddress, position.user, positionId, payout, penalty, calc.interestEarned);
        
        return (payout, penalty);
    }

    function _validateEarlyExit(
        ILockedPoolTypes.UserPosition storage position,
        address caller
    ) internal view {
        if (position.user != caller) revert NotOwner();
        if (position.status != ILockedPoolTypes.PositionStatus.ACTIVE) revert InvalidStatus();
        if (block.timestamp >= position.lockEnd) revert AlreadyMatured();
    }

    function _calculateEarlyExit(
        ILockedPoolTypes.UserPosition storage position,
        ILockedPoolTypes.LockTier storage tier
    ) internal view returns (ILockedPoolTypes.EarlyExitCalculation memory) {
        if (position.paymentChoice == ILockedPoolTypes.InterestPayment.UPFRONT) {
            return LockedPoolLibrary.calculateEarlyExitUpfront(position, tier);
        }
        return LockedPoolLibrary.calculateEarlyExitMaturity(position, tier, block.timestamp);
    }

    function _updatePositionForEarlyExit(
        ILockedPoolTypes.UserPosition storage position,
        ILockedPoolTypes.EarlyExitCalculation memory calc
    ) internal {
        position.status = ILockedPoolTypes.PositionStatus.EARLY_EXIT;
        position.actualPayout = calc.payout;
        position.penaltyPaid = calc.penalty;
        position.interestEarned = calc.interestEarned;
    }

    function _updateMetricsForEarlyExit(
        address poolAddress,
        ILockedPoolTypes.UserPosition storage position
    ) internal {
        ILockedPoolTypes.PoolMetrics storage metrics = poolMetrics[poolAddress];
        metrics.activePositions--;
        metrics.totalPrincipalLocked -= position.principalDeposited;
        metrics.totalExpectedMaturityPayout -= position.expectedMaturityPayout;
        
        if (position.paymentChoice == ILockedPoolTypes.InterestPayment.AT_MATURITY) {
            metrics.totalInterestPendingMaturity -= position.fullInterestAmount;
        }
    }

    function _processEarlyExitPayment(
        address poolAddress,
        uint256 positionId,
        address user,
        uint256 payout,
        uint256 penalty
    ) internal {
        LockedPoolEscrow escrow = LockedPoolEscrow(poolEscrows[poolAddress]);
        uint256 available = escrow.getPrincipalHeld();
        
        if (available >= payout + penalty) {
            escrow.withdraw(user, payout);
            if (penalty > 0) {
                escrow.recordPenalty(penalty);
            }
        } else if (available >= payout) {
            escrow.withdraw(user, payout);
            uint256 penaltyInEscrow = available - payout;
            if (penaltyInEscrow > 0) {
                escrow.recordPenalty(penaltyInEscrow);
            }
        } else {
            _processPaymentWithReserveLoan(poolAddress, positionId, user, payout, available, penalty);
        }
        
        if (penalty > 0) {
            poolAccounting[poolAddress].totalPenaltiesEarned += penalty;
        }
    }

    function _processPaymentWithReserveLoan(
        address poolAddress,
        uint256 positionId,
        address user,
        uint256 payout,
        uint256 escrowAvailable,
        uint256 penalty
    ) internal {
        if (yieldReserve == address(0)) revert NoYieldReserve();
        
        uint256 reserveLoan = payout - escrowAvailable;
        YieldReserveEscrow reserve = YieldReserveEscrow(yieldReserve);
        if (reserve.getAvailableBalance() < reserveLoan) revert InsufficientReserve();
        
        LockedPoolEscrow escrow = LockedPoolEscrow(poolEscrows[poolAddress]);
        if (escrowAvailable > 0) {
            escrow.withdraw(user, escrowAvailable);
        }
        reserve.payUser(user, reserveLoan);
        
        if (penalty > 0) {
            escrow.recordPenalty(penalty);
        }
        
        debtPositions[positionId] = ILockedPoolTypes.DebtPosition({
            positionId: positionId,
            user: user,
            amountOwed: payout,
            reserveLoan: reserveLoan,
            exitTime: block.timestamp,
            settled: false
        });
        poolDebtPositionIds[poolAddress].push(positionId);
        poolAccounting[poolAddress].reserveLoansOutstanding += reserveLoan;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// SPV FUNCTIONS ////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Create pending allocation for SPV
     */
    function createPendingAllocation(
        address poolAddress,
        address spvAddress,
        uint256 amount
    ) external override onlyRole(accessManager.OPERATOR_ROLE()) poolExists(poolAddress) nonReentrant returns (bytes32 allocationId) {
        if (spvAddress == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        
        LockedPoolEscrow escrow = LockedPoolEscrow(poolEscrows[poolAddress]);
        if (escrow.getPrincipalHeld() < amount) revert InsufficientFunds();
        
        allocationId = keccak256(abi.encodePacked(
            poolAddress,
            spvAddress,
            amount,
            block.timestamp,
            nextPositionId
        ));
        
        if (spvAllocations[allocationId].createdAt != 0) revert AllocationExists();
        
        spvAllocations[allocationId] = ILockedPoolTypes.SPVAllocation({
            poolAddress: poolAddress,
            spvAddress: spvAddress,
            amount: amount,
            returnedAmount: 0,
            createdAt: block.timestamp,
            status: ILockedPoolTypes.AllocationStatus.INVESTED
        });
        
        poolAllocationIds[poolAddress].push(allocationId);
        totalSPVAllocations[spvAddress] += amount;
        poolToSPVAllocations[poolAddress][spvAddress] += amount;
        
        escrow.allocateToSPV(spvAddress, amount);
        
        emit AllocationCreated(poolAddress, spvAddress, allocationId, amount);
        
        return allocationId;
    }

    /**
     * @notice Process matured allocation return
     * @dev SPV calls this when returning funds for an allocation
     * @param allocationId ID of the allocation being settled
     * @param returnedAmount Amount being returned
     */
    function matureAllocation(
        bytes32 allocationId,
        uint256 returnedAmount
    ) external override onlyRole(accessManager.SPV_ROLE()) nonReentrant {
        ILockedPoolTypes.SPVAllocation storage allocation = spvAllocations[allocationId];
        if (allocation.createdAt == 0) revert AllocationNotFound();
        if (allocation.status != ILockedPoolTypes.AllocationStatus.INVESTED && 
            allocation.status != ILockedPoolTypes.AllocationStatus.RETURNED) revert InvalidStatus();
        if (returnedAmount == 0) revert InvalidAmount();
        
        address poolAddress = allocation.poolAddress;
        LockedPoolEscrow escrow = LockedPoolEscrow(poolEscrows[poolAddress]);
        
        IERC20(poolConfigs[poolAddress].asset).safeTransferFrom(msg.sender, address(escrow), returnedAmount);
        escrow.recordReceivedFunds(returnedAmount);
        
        allocation.returnedAmount += returnedAmount;
        
        if (allocation.returnedAmount >= allocation.amount) {
            allocation.status = ILockedPoolTypes.AllocationStatus.MATURED;
            
            uint256 yield = allocation.returnedAmount > allocation.amount 
                ? allocation.returnedAmount - allocation.amount 
                : 0;
            
            if (yield > 0 && yieldReserve != address(0)) {
                escrow.withdraw(address(this), yield);
                IERC20 assetToken = IERC20(poolConfigs[poolAddress].asset);
                assetToken.forceApprove(yieldReserve, yield);
                YieldReserveEscrow(yieldReserve).receiveYield(yield);
                poolAccounting[poolAddress].totalYieldEarned += yield;
            }
        } else {
            allocation.status = ILockedPoolTypes.AllocationStatus.RETURNED;
        }
        
        if (totalSPVAllocations[msg.sender] >= returnedAmount) {
            totalSPVAllocations[msg.sender] -= returnedAmount;
        }
        if (poolToSPVAllocations[poolAddress][msg.sender] >= returnedAmount) {
            poolToSPVAllocations[poolAddress][msg.sender] -= returnedAmount;
        }
        
        emit AllocationMatured(poolAddress, allocationId, returnedAmount);
    }

    /**
     * @notice Receive funds from SPV maturity
     */
    function receiveSPVMaturity(
        address poolAddress,
        uint256 amount
    ) external onlyRole(accessManager.SPV_ROLE()) poolExists(poolAddress) nonReentrant {
        if (amount == 0) revert InvalidAmount();
        
        LockedPoolEscrow escrow = LockedPoolEscrow(poolEscrows[poolAddress]);
        
        IERC20(poolConfigs[poolAddress].asset).safeTransferFrom(msg.sender, address(escrow), amount);
        escrow.recordReceivedFunds(amount);
        
        if (totalSPVAllocations[msg.sender] >= amount) {
            totalSPVAllocations[msg.sender] -= amount;
        }
        if (poolToSPVAllocations[poolAddress][msg.sender] >= amount) {
            poolToSPVAllocations[poolAddress][msg.sender] -= amount;
        }
    }

    /**
     * @notice Settle SPV return for a specific position
     * @dev Handles loan repayment and yield distribution
     * @param positionId Position being settled
     * @param returnedAmount Amount returned by SPV
     */
    function settleSPVReturn(
        uint256 positionId,
        uint256 returnedAmount
    ) external onlyRole(accessManager.SPV_ROLE()) nonReentrant returns (ILockedPoolTypes.SPVSettlement memory settlement) {
        ILockedPoolTypes.UserPosition storage position = positions[positionId];
        if (position.positionId != positionId) revert InvalidPosition();
        
        address poolAddress = position.poolAddress;
        LockedPoolEscrow escrow = LockedPoolEscrow(poolEscrows[poolAddress]);
        ILockedPoolTypes.PoolConfig storage config = poolConfigs[poolAddress];
        
        IERC20(config.asset).safeTransferFrom(msg.sender, address(this), returnedAmount);
        
        settlement.positionId = positionId;
        settlement.returnedAmount = returnedAmount;
        
        if (position.status == ILockedPoolTypes.PositionStatus.EARLY_EXIT) {
            ILockedPoolTypes.DebtPosition storage debt = debtPositions[positionId];
            
            if (debt.reserveLoan > 0 && !debt.settled) {
                settlement.loanRepayment = debt.reserveLoan;
                settlement.userPayout = 0;
                
                uint256 protocolGain = returnedAmount > debt.reserveLoan 
                    ? returnedAmount - debt.reserveLoan 
                    : 0;
                settlement.protocolYield = protocolGain;
                
                YieldReserveEscrow reserve = YieldReserveEscrow(yieldReserve);
                IERC20 assetToken = IERC20(config.asset);
                
                assetToken.forceApprove(yieldReserve, returnedAmount);
                
                if (protocolGain > 0) {
                    reserve.repayLoan(poolAddress, positionId, debt.reserveLoan);
                    reserve.receiveYield(protocolGain);
                    poolAccounting[poolAddress].totalYieldEarned += protocolGain;
                } else {
                    reserve.repayLoan(poolAddress, positionId, returnedAmount);
                    uint256 shortfall = debt.reserveLoan - returnedAmount;
                    poolAccounting[poolAddress].totalLossesAbsorbed += shortfall;
                }
                
                debt.settled = true;
                poolAccounting[poolAddress].reserveLoansOutstanding -= debt.reserveLoan;
            } else {
                settlement.protocolYield = returnedAmount;
                if (yieldReserve != address(0)) {
                    IERC20 assetToken = IERC20(config.asset);
                    assetToken.forceApprove(yieldReserve, returnedAmount);
                    YieldReserveEscrow(yieldReserve).receiveYield(returnedAmount);
                    poolAccounting[poolAddress].totalYieldEarned += returnedAmount;
                } else {
                    IERC20(config.asset).safeTransfer(address(escrow), returnedAmount);
                    escrow.recordReceivedFunds(returnedAmount);
                }
            }
            
        } else if (position.status == ILockedPoolTypes.PositionStatus.ACTIVE) {
            settlement.userPayout = position.expectedMaturityPayout;
            
            if (returnedAmount >= position.expectedMaturityPayout) {
                uint256 yield = returnedAmount - position.expectedMaturityPayout;
                settlement.protocolYield = yield;
                
                IERC20(config.asset).safeTransfer(address(escrow), position.expectedMaturityPayout);
                escrow.recordReceivedFunds(position.expectedMaturityPayout);
                
                if (yield > 0 && yieldReserve != address(0)) {
                    IERC20 assetToken = IERC20(config.asset);
                    assetToken.forceApprove(yieldReserve, yield);
                    YieldReserveEscrow(yieldReserve).receiveYield(yield);
                    poolAccounting[poolAddress].totalYieldEarned += yield;
                }
                
            } else {
                IERC20(config.asset).safeTransfer(address(escrow), returnedAmount);
                escrow.recordReceivedFunds(returnedAmount);
                
                uint256 shortfall = position.expectedMaturityPayout - returnedAmount;
                
                if (yieldReserve != address(0)) {
                    YieldReserveEscrow reserve = YieldReserveEscrow(yieldReserve);
                    if (reserve.getAvailableBalance() >= shortfall) {
                        reserve.coverShortfall(address(escrow), shortfall);
                        poolAccounting[poolAddress].totalLossesAbsorbed += shortfall;
                    }
                }
            }
            
            position.status = ILockedPoolTypes.PositionStatus.MATURED;
        }
        
        if (totalSPVAllocations[msg.sender] >= position.investedAmount) {
            totalSPVAllocations[msg.sender] -= position.investedAmount;
        }
        if (poolToSPVAllocations[poolAddress][msg.sender] >= position.investedAmount) {
            poolToSPVAllocations[poolAddress][msg.sender] -= position.investedAmount;
        }
        
        return settlement;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ADMIN FUNCTIONS //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Set the yield reserve escrow address
     * @param reserve_ Yield reserve escrow address
     */
    function setYieldReserve(address reserve_) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        if (reserve_ == address(0)) revert InvalidAddress();
        yieldReserve = reserve_;
    }

    /**
     * @notice Deactivate a pool
     */
    function deactivatePool(address poolAddress) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) poolExists(poolAddress) {
        poolConfigs[poolAddress].isActive = false;
    }

    /**
     * @notice Activate a pool
     */
    function activatePool(address poolAddress) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) poolExists(poolAddress) {
        poolConfigs[poolAddress].isActive = true;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// VIEW FUNCTIONS ///////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Get position details
     */
    function getPosition(uint256 positionId) external view override returns (ILockedPoolTypes.UserPosition memory) {
        return positions[positionId];
    }

    /**
     * @notice Get user's position IDs for a pool
     */
    function getUserPositions(
        address poolAddress,
        address user
    ) external view override returns (uint256[] memory positionIds) {
        return userPositionIds[poolAddress][user];
    }

    /**
     * @notice Get position summary
     */
    function getPositionSummary(uint256 positionId) external view override returns (ILockedPoolTypes.PositionSummary memory) {
        return LockedPoolLibrary.buildPositionSummary(positions[positionId], block.timestamp);
    }

    /**
     * @notice Calculate early exit payout
     */
    function calculateEarlyExitPayout(uint256 positionId) external view override returns (ILockedPoolTypes.EarlyExitCalculation memory) {
        ILockedPoolTypes.UserPosition storage position = positions[positionId];
        if (position.poolAddress == address(0)) revert InvalidPosition();
        
        ILockedPoolTypes.LockTier storage tier = poolTiers[position.poolAddress][position.tierIndex];
        
        if (position.paymentChoice == ILockedPoolTypes.InterestPayment.UPFRONT) {
            return LockedPoolLibrary.calculateEarlyExitUpfront(position, tier);
        } else {
            return LockedPoolLibrary.calculateEarlyExitMaturity(position, tier, block.timestamp);
        }
    }

    /**
     * @notice Get lock tier configuration
     */
    function getLockTier(
        address poolAddress,
        uint8 tierIndex
    ) external view override returns (ILockedPoolTypes.LockTier memory) {
        if (tierIndex >= poolTiers[poolAddress].length) revert InvalidTier();
        return poolTiers[poolAddress][tierIndex];
    }

    /**
     * @notice Get all tiers for a pool
     */
    function getPoolTiers(address poolAddress) external view returns (ILockedPoolTypes.LockTier[] memory) {
        return poolTiers[poolAddress];
    }

    /**
     * @notice Get pool metrics
     */
    function getPoolMetrics(address poolAddress) external view override returns (ILockedPoolTypes.PoolMetrics memory) {
        return poolMetrics[poolAddress];
    }

    /**
     * @notice Get pool configuration
     */
    function getPoolConfig(address poolAddress) external view returns (ILockedPoolTypes.PoolConfig memory) {
        return poolConfigs[poolAddress];
    }

    /**
     * @notice Calculate interest for given parameters
     */
    function calculateInterest(
        uint256 principal,
        uint256 apyBps,
        uint256 durationDays
    ) external pure override returns (uint256) {
        return LockedPoolLibrary.calculateInterest(principal, apyBps, durationDays);
    }

    /**
     * @notice Get total SPV allocation
     */
    function getTotalSPVAllocation(address spvAddress) external view returns (uint256) {
        return totalSPVAllocations[spvAddress];
    }

    /**
     * @notice Get pool to SPV allocation
     */
    function getPoolToSPVAllocation(address poolAddress, address spvAddress) external view returns (uint256) {
        return poolToSPVAllocations[poolAddress][spvAddress];
    }

    /**
     * @notice Get protocol accounting for a pool
     */
    function getPoolAccounting(address poolAddress) external view returns (ILockedPoolTypes.PoolProtocolAccounting memory) {
        return poolAccounting[poolAddress];
    }

    /**
     * @notice Get debt position details
     */
    function getDebtPosition(uint256 positionId) external view returns (ILockedPoolTypes.DebtPosition memory) {
        return debtPositions[positionId];
    }

    /**
     * @notice Get all debt position IDs for a pool
     */
    function getPoolDebtPositions(address poolAddress) external view returns (uint256[] memory) {
        return poolDebtPositionIds[poolAddress];
    }

    /**
     * @notice Get yield reserve address
     */
    function getYieldReserve() external view returns (address) {
        return yieldReserve;
    }
}

