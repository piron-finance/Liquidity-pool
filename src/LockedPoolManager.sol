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
import "./interfaces/IFeeManager.sol";
import "./escrows/LockedPoolEscrow.sol";
import "./escrows/YieldReserveEscrow.sol";
import "./types/ILockedPoolTypes.sol";
import "./libraries/LockedPoolLibrary.sol";
import "./libraries/LockedPoolManagerLib.sol";
import "./managed/LockedPool.sol";

/**
 * @title LockedPoolManager
 * @dev Manages fixed-term locked pools with tiered APY, lock periods, auto-rollover,
 *      early exit penalties, SPV allocations, and protocol capital deployment.
 *      Each deposit creates a discrete UserPosition with its own maturity schedule.
 */
contract LockedPoolManager is 
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    ILockedPoolManager
{
    // ==================== ERRORS ====================

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
    error NotAllocationSPV();
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

    // ==================== STATE ====================

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

    address public feeManager;
    uint256 public defaultDepositFeeBps;
    mapping(address => uint256) public poolDepositFeeBps;  
    uint256 public constant MAX_DEPOSIT_FEE = 500;  
    uint256 public constant BPS = 10000;

    // ==================== MODIFIERS ====================

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

    // ==================== INITIALIZATION ====================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize with access manager, registry, and timelock controller.
     * @param accessManager_ AccessManager contract
     * @param registry_ PoolRegistry proxy
     * @param timelockController_ TimelockController for upgrades
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

    // ==================== POOL REGISTRATION ====================

    /**
     * @dev Register a new locked pool. Only callable by ManagedPoolFactory.
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

    function setManagedPoolFactory(address _factory) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        if (_factory == address(0)) revert InvalidAddress();
        if (managedPoolFactory != address(0)) revert FactoryAlreadySet();
        managedPoolFactory = _factory;
    }

    // ==================== TIER CONFIGURATION ====================

    /**
     * @dev Configure or add a lock tier for a pool (duration, APY, penalty).
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

    function setTierActive(
        address poolAddress,
        uint8 tierIndex,
        bool isActive
    ) external override onlyRole(accessManager.OPERATOR_ROLE()) poolExists(poolAddress) {
        if (tierIndex >= poolTiers[poolAddress].length) revert InvalidTier();
        poolTiers[poolAddress][tierIndex].isActive = isActive;
    }

    function updateTierAPY(
        address poolAddress,
        uint8 tierIndex,
        uint256 newApyBps
    ) external override onlyRole(accessManager.OPERATOR_ROLE()) poolExists(poolAddress) {
        if (tierIndex >= poolTiers[poolAddress].length) revert InvalidTier();
        if (newApyBps == 0 || newApyBps > 5000) revert InvalidAPY();
        poolTiers[poolAddress][tierIndex].apyBps = newApyBps;
    }

    // ==================== DEPOSIT ====================

    /**
     * @dev Process a locked deposit: deduct fee, create a UserPosition with computed
     *      interest, optionally pay interest upfront.
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
        
        uint256 feeBps = poolDepositFeeBps[poolAddress];
        if (feeBps == 0) feeBps = defaultDepositFeeBps;
        
        (uint256 netAmount, uint256 depositFee) = escrow.processDeposit(amount, feeBps);
        
        if (depositFee > 0) {
            emit DepositFeeCollected(poolAddress, depositor, amount, depositFee);
        }
        
        positionId = nextPositionId++;
        
        ILockedPoolTypes.LockTier memory tierMem = tier;
        positions[positionId] = LockedPoolLibrary.buildPosition(
            positionId,
            depositor,
            poolAddress,
            netAmount,
            tierMem,
            tierIndex,
            paymentChoice,
            block.timestamp
        );
        
        userPositionIds[poolAddress][depositor].push(positionId);
        
        ILockedPoolTypes.UserPosition storage pos = positions[positionId];
        ILockedPoolTypes.PoolMetrics storage metrics = poolMetrics[poolAddress];
        metrics.totalPrincipalLocked += netAmount;
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
            netAmount,
            pos.fullInterestAmount,
            paymentChoice,
            pos.lockEnd
        );
        
        return (positionId, shares);
    }

// ==================== REDEMPTION ====================

    /**
     * @dev Redeem a matured position. Pays principal + interest (if AT_MATURITY).
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

    function batchMaturePositions(
        uint256[] calldata positionIds
    ) external onlyRole(accessManager.OPERATOR_ROLE()) returns (uint256 maturedCount) {
        for (uint256 i = 0; i < positionIds.length; i++) {
            ILockedPoolTypes.UserPosition storage position = positions[positionIds[i]];
            
            if (position.status != ILockedPoolTypes.PositionStatus.ACTIVE) continue;
            if (block.timestamp < position.lockEnd) continue;
            
            position.status = ILockedPoolTypes.PositionStatus.MATURED;
            maturedCount++;
            
            emit PositionMatured(position.poolAddress, position.user, positionIds[i], position.lockEnd);
        }
        
        return maturedCount;
    }

    function canMaturePosition(uint256 positionId) external view returns (bool canMature) {
        ILockedPoolTypes.UserPosition storage position = positions[positionId];
        return position.status == ILockedPoolTypes.PositionStatus.ACTIVE && 
               block.timestamp >= position.lockEnd;
    }

    // ==================== ROLLOVER ====================

    /**
     * @dev Toggle auto-rollover for a position. Position owner only.
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
    
    function transferPositionOwnership(
        uint256 positionId,
        address newOwner,
        address caller
    ) external {
        ILockedPoolTypes.UserPosition storage position = positions[positionId];
        
        if (msg.sender != position.poolAddress) revert OnlyPool();
        if (position.user != caller) revert NotOwner();
        if (newOwner == address(0)) revert InvalidAddress();
        if (position.status != ILockedPoolTypes.PositionStatus.ACTIVE && 
            position.status != ILockedPoolTypes.PositionStatus.MATURED) revert InvalidStatus();
        
        address oldOwner = position.user;
        LockedPoolManagerLib.transferPositionOwnership(positions, userPositionIds, positionId, newOwner);
        
        emit PositionOwnershipTransferred(positionId, oldOwner, newOwner);
    }

    function executeRollover(
        uint256 positionId
    ) external override onlyRole(accessManager.OPERATOR_ROLE()) returns (uint256 newPositionId) {
        ILockedPoolTypes.UserPosition storage position = positions[positionId];
        
        if (position.status != ILockedPoolTypes.PositionStatus.ACTIVE && 
            position.status != ILockedPoolTypes.PositionStatus.MATURED) revert InvalidStatus();
        if (block.timestamp < position.lockEnd) revert NotMatured();
        if (!position.autoRollover) revert RolloverNotEnabled();
        
        ILockedPoolTypes.LockTier storage tier = poolTiers[position.poolAddress][position.tierIndex];
        if (!tier.isActive) revert TierNotActive();
        
        return _executeRolloverInternal(positionId);
    }

    function batchExecuteRollovers(
        uint256[] calldata positionIds
    ) external override onlyRole(accessManager.OPERATOR_ROLE()) returns (uint256[] memory newPositionIds) {
        newPositionIds = new uint256[](positionIds.length);
        
        for (uint256 i = 0; i < positionIds.length; i++) {
            ILockedPoolTypes.UserPosition storage position = positions[positionIds[i]];
            
            if (position.status != ILockedPoolTypes.PositionStatus.ACTIVE &&
                position.status != ILockedPoolTypes.PositionStatus.MATURED) {
                continue;
            }
            if (block.timestamp < position.lockEnd) continue;
            if (!position.autoRollover) continue;
            
            ILockedPoolTypes.LockTier storage tier = poolTiers[position.poolAddress][position.tierIndex];
            if (!tier.isActive) continue;
            
            newPositionIds[i] = _executeRolloverInternal(positionIds[i]);
        }
        
        return newPositionIds;
    }

    function _executeRolloverInternal(
        uint256 positionId
    ) internal returns (uint256 newPositionId) {
        newPositionId = nextPositionId++;
        LockedPoolManagerLib.executeRollover(
            positions, userPositionIds, poolTiers, poolMetrics, poolEscrows,
            positionId, newPositionId
        );
        return newPositionId;
    }

    // ==================== EARLY EXIT ====================

    /**
     * @dev Process early withdrawal with penalty. If escrow lacks funds,
     *      borrows from YieldReserveEscrow and creates a DebtPosition.
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
        LockedPoolManagerLib.processEarlyExitPayment(
            poolEscrows, poolAccounting, debtPositions, poolDebtPositionIds,
            yieldReserve, poolAddress, positionId, user, payout, penalty
        );
    }

    // ==================== SPV ALLOCATION ====================

    /**
     * @dev Create SPV allocation from pool escrow funds.
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
     * @dev SPV returns matured allocation funds. Excess yield sent to reserve.
     */
    function matureAllocation(
        bytes32 allocationId,
        uint256 returnedAmount
    ) external override onlyRole(accessManager.SPV_ROLE()) nonReentrant {
        ILockedPoolTypes.SPVAllocation storage allocation = spvAllocations[allocationId];
        if (allocation.createdAt == 0) revert AllocationNotFound();
        if (allocation.spvAddress != msg.sender) revert NotAllocationSPV();
        if (allocation.status != ILockedPoolTypes.AllocationStatus.INVESTED && 
            allocation.status != ILockedPoolTypes.AllocationStatus.RETURNED) revert InvalidStatus();
        if (returnedAmount == 0) revert InvalidAmount();
        
        address poolAddress = allocation.poolAddress;
        address spv = allocation.spvAddress;
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
                escrow.sendYieldToReserve(yield);
                poolAccounting[poolAddress].totalYieldEarned += yield;
            }
        } else {
            allocation.status = ILockedPoolTypes.AllocationStatus.RETURNED;
        }
        
        if (totalSPVAllocations[spv] >= returnedAmount) {
            totalSPVAllocations[spv] -= returnedAmount;
        }
        if (poolToSPVAllocations[poolAddress][spv] >= returnedAmount) {
            poolToSPVAllocations[poolAddress][spv] -= returnedAmount;
        }
        
        emit AllocationMatured(poolAddress, allocationId, returnedAmount);
    }

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

    // ==================== ADMIN CONFIG ====================

    function setYieldReserve(address reserve_) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        if (reserve_ == address(0)) revert InvalidAddress();
        yieldReserve = reserve_;
    }

    function deactivatePool(address poolAddress) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) poolExists(poolAddress) {
        poolConfigs[poolAddress].isActive = false;
    }

    function activatePool(address poolAddress) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) poolExists(poolAddress) {
        poolConfigs[poolAddress].isActive = true;
    }

    function setFeeManager(address feeManager_) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        if (feeManager_ == address(0)) revert InvalidAddress();
        feeManager = feeManager_;
        emit FeeManagerUpdated(feeManager_);
    }

    function setDefaultDepositFee(uint256 feeBps) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        if (feeBps > MAX_DEPOSIT_FEE) revert InvalidAmount();
        defaultDepositFeeBps = feeBps;
        emit DefaultDepositFeeUpdated(feeBps);
    }

    function setPoolDepositFee(
        address poolAddress,
        uint256 feeBps
    ) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) poolExists(poolAddress) {
        if (feeBps > MAX_DEPOSIT_FEE) revert InvalidAmount();
        poolDepositFeeBps[poolAddress] = feeBps;
        emit PoolDepositFeeUpdated(poolAddress, feeBps);
    }

    function getEffectiveDepositFee(address poolAddress) external view returns (uint256) {
        uint256 poolFee = poolDepositFeeBps[poolAddress];
        return poolFee > 0 ? poolFee : defaultDepositFeeBps;
    }

    // ==================== PROTOCOL CAPITAL ====================

    /**
     * @dev Deploy protocol capital from YieldReserveEscrow into a pool.
     */
    function deployProtocolCapital(
        address poolAddress,
        uint256 amount
    ) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) poolExists(poolAddress) nonReentrant {
        if (yieldReserve == address(0)) revert NoYieldReserve();
        if (amount == 0) revert InvalidAmount();
        
        LockedPoolEscrow escrow = LockedPoolEscrow(poolEscrows[poolAddress]);
        
        YieldReserveEscrow(yieldReserve).deployToPool(poolAddress, address(escrow), amount);
        escrow.recordProtocolFundsFromReserve(amount);
        
        emit ProtocolCapitalDeployed(poolAddress, amount);
    }

    function recallProtocolCapital(
        address poolAddress,
        uint256 amount
    ) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) poolExists(poolAddress) nonReentrant {
        if (yieldReserve == address(0)) revert NoYieldReserve();
        if (amount == 0) revert InvalidAmount();
        
        LockedPoolEscrow escrow = LockedPoolEscrow(poolEscrows[poolAddress]);
        escrow.returnProtocolFundsToReserve(amount);
        
        emit ProtocolCapitalRecalled(poolAddress, amount);
    }

    function getAvailableProtocolCapital(address poolAddress) external view poolExists(poolAddress) returns (uint256) {
        LockedPoolEscrow escrow = LockedPoolEscrow(poolEscrows[poolAddress]);
        return escrow.protocolFundsFromReserve();
    }

    function getPoolProtocolFunds(address poolAddress) external view poolExists(poolAddress) returns (
        uint256 fromReserve,
        uint256 directDeposit
    ) {
        LockedPoolEscrow escrow = LockedPoolEscrow(poolEscrows[poolAddress]);
        return (escrow.protocolFundsFromReserve(), escrow.protocolFundsDirectDeposit());
    }

    event ProtocolCapitalDeployed(address indexed pool, uint256 amount);
    event ProtocolCapitalRecalled(address indexed pool, uint256 amount);
    event PositionOwnershipTransferred(uint256 indexed positionId, address indexed from, address indexed to);
    event DebtSettled(address indexed pool, uint256 indexed positionId, uint256 reserveLoanRepaid, uint256 penaltyRecorded);

    // ==================== VIEW ====================

    function getPosition(uint256 positionId) external view override returns (ILockedPoolTypes.UserPosition memory) {
        return positions[positionId];
    }

    function getUserPositions(
        address poolAddress,
        address user
    ) external view override returns (uint256[] memory positionIds) {
        return userPositionIds[poolAddress][user];
    }

    function getPositionSummary(uint256 positionId) external view override returns (ILockedPoolTypes.PositionSummary memory) {
        return LockedPoolLibrary.buildPositionSummary(positions[positionId], block.timestamp);
    }

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

    function getLockTier(
        address poolAddress,
        uint8 tierIndex
    ) external view override returns (ILockedPoolTypes.LockTier memory) {
        if (tierIndex >= poolTiers[poolAddress].length) revert InvalidTier();
        return poolTiers[poolAddress][tierIndex];
    }

    function getPoolTiers(address poolAddress) external view returns (ILockedPoolTypes.LockTier[] memory) {
        return poolTiers[poolAddress];
    }

    function getPoolMetrics(address poolAddress) external view override returns (ILockedPoolTypes.PoolMetrics memory) {
        return poolMetrics[poolAddress];
    }

    function getPoolConfig(address poolAddress) external view returns (ILockedPoolTypes.PoolConfig memory) {
        return poolConfigs[poolAddress];
    }

    function calculateInterest(
        uint256 principal,
        uint256 apyBps,
        uint256 durationDays
    ) external pure override returns (uint256) {
        return LockedPoolLibrary.calculateInterest(principal, apyBps, durationDays);
    }

    function getTotalSPVAllocation(address spvAddress) external view returns (uint256) {
        return totalSPVAllocations[spvAddress];
    }

    function getPoolToSPVAllocation(address poolAddress, address spvAddress) external view returns (uint256) {
        return poolToSPVAllocations[poolAddress][spvAddress];
    }

    function getPoolAccounting(address poolAddress) external view returns (ILockedPoolTypes.PoolProtocolAccounting memory) {
        return poolAccounting[poolAddress];
    }

    function getDebtPosition(uint256 positionId) external view returns (ILockedPoolTypes.DebtPosition memory) {
        return debtPositions[positionId];
    }

    function getPoolDebtPositions(address poolAddress) external view returns (uint256[] memory) {
        return poolDebtPositionIds[poolAddress];
    }

    function getYieldReserve() external view returns (address) {
        return yieldReserve;
    }

    // ==================== DEBT SETTLEMENT ====================

    function settlePoolDebt(
        address poolAddress,
        uint256[] calldata positionIds
    ) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) poolExists(poolAddress) nonReentrant {
        if (yieldReserve == address(0)) revert NoYieldReserve();
        LockedPoolManagerLib.settlePoolDebt(
            poolEscrows, poolAccounting, debtPositions,
            yieldReserve, poolAddress, positionIds
        );
    }

    function getSettleableDebt(address poolAddress) external view returns (
        uint256[] memory positionIds,
        uint256[] memory loanAmounts,
        uint256[] memory penaltyAmounts,
        uint256 totalLoanSettleable,
        uint256 totalPenaltySettleable,
        uint256 escrowAvailable
    ) {
        return LockedPoolManagerLib.getSettleableDebt(
            poolEscrows, debtPositions, poolDebtPositionIds[poolAddress], poolAddress
        );
    }
}
