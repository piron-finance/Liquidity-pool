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
    using SafeERC20 for IERC20;

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STATE VARIABLES //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    AccessManager public accessManager;
    IPoolRegistry public registry;
    address public timelockController;
    address public managedPoolFactory;
    
    uint256 public version;

    uint256 public nextPositionId;

    uint8 public constant MAX_TIERS = 10;

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

    address public yieldReserve;
    
    mapping(address => ILockedPoolTypes.PoolProtocolAccounting) public poolAccounting;
    mapping(uint256 => ILockedPoolTypes.DebtPosition) public debtPositions;
    mapping(address => uint256[]) public poolDebtPositionIds;

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// MODIFIERS ///////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    modifier onlyRole(bytes32 role) {
        require(accessManager.hasRole(role, msg.sender), "LockedPoolManager/access denied");
        _;
    }

    modifier poolExists(address poolAddress) {
        require(poolConfigs[poolAddress].createdAt > 0, "LockedPoolManager/pool not found");
        _;
    }

    modifier activePool(address poolAddress) {
        require(poolConfigs[poolAddress].isActive, "LockedPoolManager/pool not active");
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

        require(accessManager_ != address(0), "LockedPoolManager/invalid access manager");
        require(registry_ != address(0), "LockedPoolManager/invalid registry");
        require(timelockController_ != address(0), "LockedPoolManager/invalid timelock");

        accessManager = AccessManager(accessManager_);
        registry = IPoolRegistry(registry_);
        timelockController = timelockController_;
        version = 1;
        nextPositionId = 1;
    }

    function _authorizeUpgrade(address newImplementation) internal override {
        require(msg.sender == timelockController, "LockedPoolManager/only timelock");
        require(newImplementation != address(0), "LockedPoolManager/invalid implementation");
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
        require(msg.sender == managedPoolFactory, "LockedPoolManager/only factory");
        require(poolAddress != address(0), "LockedPoolManager/invalid pool");
        require(escrowAddress != address(0), "LockedPoolManager/invalid escrow");
        require(asset != address(0), "LockedPoolManager/invalid asset");
        require(minInvestment > 0, "LockedPoolManager/invalid min investment");
        require(poolConfigs[poolAddress].createdAt == 0, "LockedPoolManager/pool exists");
        
        uint8 assetDecimals = IERC20Metadata(asset).decimals();
        require(assetDecimals == 6 || assetDecimals == 18, "LockedPoolManager/invalid decimals");
        require(registry.isApprovedAsset(asset), "LockedPoolManager/asset not approved");
        
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
        require(_factory != address(0), "LockedPoolManager/invalid factory");
        require(managedPoolFactory == address(0), "LockedPoolManager/factory already set");
        managedPoolFactory = _factory;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// TIER CONFIGURATION //////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Configure a lock tier for a pool
     */
    function configureLockTier(
        address poolAddress,
        uint8 tierIndex,
        ILockedPoolTypes.LockTier memory tier
    ) external override onlyRole(accessManager.OPERATOR_ROLE()) poolExists(poolAddress) {
        require(tierIndex < MAX_TIERS, "LockedPoolManager/invalid tier index");
        require(tier.durationDays > 0, "LockedPoolManager/invalid duration");
        require(tier.apyBps > 0 && tier.apyBps <= 5000, "LockedPoolManager/invalid apy");
        require(tier.earlyExitPenaltyBps <= 5000, "LockedPoolManager/invalid penalty");
        
        ILockedPoolTypes.LockTier[] storage tiers = poolTiers[poolAddress];
        
        while (tiers.length <= tierIndex) {
            tiers.push(ILockedPoolTypes.LockTier({
                durationDays: 0,
                apyBps: 0,
                earlyExitPenaltyBps: 0,
                minDeposit: 0,
                isActive: false
            }));
        }
        
        tiers[tierIndex] = tier;
        
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
        require(tierIndex < poolTiers[poolAddress].length, "LockedPoolManager/tier not found");
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
        require(tierIndex < poolTiers[poolAddress].length, "LockedPoolManager/tier not found");
        require(newApyBps > 0 && newApyBps <= 5000, "LockedPoolManager/invalid apy");
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
        require(msg.sender == poolAddress, "LockedPoolManager/only pool");
        require(depositor != address(0), "LockedPoolManager/invalid depositor");
        
        ILockedPoolTypes.PoolConfig storage config = poolConfigs[poolAddress];
        require(amount >= config.minInvestment, "LockedPoolManager/below minimum");
        
        ILockedPoolTypes.LockTier storage tier = poolTiers[poolAddress][tierIndex];
        require(tier.isActive, "LockedPoolManager/tier not active");
        require(amount >= tier.minDeposit, "LockedPoolManager/below tier minimum");
        
        uint256 interestAmount = LockedPoolLibrary.calculateInterest(
            amount,
            tier.apyBps,
            tier.durationDays
        );
        
        uint256 investedAmount = LockedPoolLibrary.calculateInvestedAmount(
            amount,
            interestAmount,
            paymentChoice
        );
        
        uint256 expectedPayout = LockedPoolLibrary.calculateExpectedMaturityPayout(
            amount,
            interestAmount,
            paymentChoice
        );
        
        LockedPoolEscrow escrow = LockedPoolEscrow(poolEscrows[poolAddress]);
        escrow.recordDeposit(amount);
        
        positionId = nextPositionId++;
        
        positions[positionId] = ILockedPoolTypes.UserPosition({
            positionId: positionId,
            user: depositor,
            poolAddress: poolAddress,
            principalDeposited: amount,
            fullInterestAmount: interestAmount,
            apyBpsAtDeposit: tier.apyBps,
            paymentChoice: paymentChoice,
            interestPaid: false,
            investedAmount: investedAmount,
            expectedMaturityPayout: expectedPayout,
            lockStart: block.timestamp,
            lockEnd: block.timestamp + (tier.durationDays * 1 days),
            tierIndex: tierIndex,
            status: ILockedPoolTypes.PositionStatus.ACTIVE,
            actualPayout: 0,
            penaltyPaid: 0,
            interestEarned: 0
        });
        
        userPositionIds[poolAddress][depositor].push(positionId);
        
        ILockedPoolTypes.PoolMetrics storage metrics = poolMetrics[poolAddress];
        metrics.totalPrincipalLocked += amount;
        metrics.totalInterestCommitted += interestAmount;
        metrics.totalInvestedAmount += investedAmount;
        metrics.totalExpectedMaturityPayout += expectedPayout;
        metrics.activePositions++;
        metrics.totalPositions++;
        
        if (paymentChoice == ILockedPoolTypes.InterestPayment.UPFRONT) {
            escrow.payInterest(depositor, interestAmount);
            positions[positionId].interestPaid = true;
            metrics.totalInterestPaidUpfront += interestAmount;
            
            emit InterestPaidUpfront(poolAddress, depositor, positionId, interestAmount);
        } else {
            metrics.totalInterestPendingMaturity += interestAmount;
        }
        
        shares = investedAmount;
        
        emit PositionCreated(
            poolAddress,
            depositor,
            positionId,
            amount,
            interestAmount,
            paymentChoice,
            positions[positionId].lockEnd
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
        require(msg.sender == poolAddress, "LockedPoolManager/only pool");
        
        ILockedPoolTypes.UserPosition storage position = positions[positionId];
        
        require(position.user == caller, "LockedPoolManager/not owner");
        require(
            position.status == ILockedPoolTypes.PositionStatus.ACTIVE ||
            position.status == ILockedPoolTypes.PositionStatus.MATURED,
            "LockedPoolManager/not redeemable"
        );
        require(block.timestamp >= position.lockEnd, "LockedPoolManager/not matured");
        
        payout = position.expectedMaturityPayout;
        
        position.status = ILockedPoolTypes.PositionStatus.REDEEMED;
        position.actualPayout = payout;
        position.interestEarned = position.fullInterestAmount;
        
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
        require(msg.sender == poolAddress, "LockedPoolManager/only pool");
        
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
        require(position.user == caller, "LockedPoolManager/not owner");
        require(position.status == ILockedPoolTypes.PositionStatus.ACTIVE, "LockedPoolManager/not active");
        require(block.timestamp < position.lockEnd, "LockedPoolManager/already matured");
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
        require(yieldReserve != address(0), "LockedPoolManager/no yield reserve");
        
        uint256 reserveLoan = payout - escrowAvailable;
        YieldReserveEscrow reserve = YieldReserveEscrow(yieldReserve);
        require(reserve.getAvailableBalance() >= reserveLoan, "LockedPoolManager/insufficient reserve");
        
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
        require(spvAddress != address(0), "LockedPoolManager/invalid SPV");
        require(amount > 0, "LockedPoolManager/invalid amount");
        
        LockedPoolEscrow escrow = LockedPoolEscrow(poolEscrows[poolAddress]);
        require(escrow.getPrincipalHeld() >= amount, "LockedPoolManager/insufficient funds");
        
        allocationId = keccak256(abi.encodePacked(
            poolAddress,
            spvAddress,
            amount,
            block.timestamp,
            nextPositionId
        ));
        
        require(spvAllocations[allocationId].createdAt == 0, "LockedPoolManager/allocation exists");
        
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
        require(allocation.createdAt > 0, "LockedPoolManager/allocation not found");
        require(
            allocation.status == ILockedPoolTypes.AllocationStatus.INVESTED ||
            allocation.status == ILockedPoolTypes.AllocationStatus.RETURNED,
            "LockedPoolManager/invalid status"
        );
        require(returnedAmount > 0, "LockedPoolManager/invalid amount");
        
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
        require(amount > 0, "LockedPoolManager/invalid amount");
        
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
        require(position.positionId == positionId, "LockedPoolManager/position not found");
        
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
        require(reserve_ != address(0), "LockedPoolManager/invalid reserve");
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
        require(position.poolAddress != address(0), "LockedPoolManager/invalid position");
        
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
        require(tierIndex < poolTiers[poolAddress].length, "LockedPoolManager/tier not found");
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

