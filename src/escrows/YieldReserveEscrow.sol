// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../AccessManager.sol";

/**
 * @title YieldReserveEscrow
 * @dev Protocol-level reserve for yield, liquidity backstop, and early-exit loans.
 *      Receives yield from escrows, splits to treasury/reserve, deploys capital to
 *      pools, lends to users during early exit, and absorbs shortfalls.
 */
contract YieldReserveEscrow is 
    Initializable, 
    UUPSUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    // ==================== STRUCTS ====================

    using SafeERC20 for IERC20;

    struct ReserveInvestment {
        address pool;
        uint256 positionId;
        uint256 amount;
        uint256 expectedReturn;
        uint256 investedAt;
        bool active;
    }

    struct ProtocolFundsSnapshot {
        uint256 reserveBalance;
        uint256 totalDeployedViaReserve;
        uint256 totalDirectDeposits;
        uint256 totalEarlyExitLoans;
        uint256 grandTotal;
        uint256 poolCount;
    }

    struct PoolProtocolFunds {
        uint256 fromReserve;
        uint256 directDeposit;
        uint256 earlyExitLoan;
        uint256 total;
    }

    // ==================== STATE ====================

    IERC20 public asset;
    AccessManager public accessManager;
    address public lockedPoolManager;
    address public stableYieldManager;
    address public treasury;
    
    uint256 public version;

    uint256 public totalBalance;
    uint256 public totalLoanedOut;
    
    uint256 public treasuryBps;
    uint256 public reserveBps;
    uint256 public minReserveFloor;
    
    uint256 public totalYieldReceived;
    uint256 public totalSentToTreasury;
    uint256 public totalLossesAbsorbed;
    
    mapping(address => uint256) public poolLoans;
    mapping(uint256 => uint256) public positionLoans;

    mapping(uint256 => ReserveInvestment) public reserveInvestments;
    uint256 public nextInvestmentId;
    uint256 public totalInvested;

    uint256 public totalDeployedToEscrows;
    mapping(address => uint256) public deployedToPool;
    
    uint256 public totalDirectDepositsReported;
    mapping(address => uint256) public directDepositsToPool;
    
    address[] public trackedPools;
    mapping(address => bool) public isTrackedPool;

    mapping(address => bool) public authorizedEscrows;

    // ==================== EVENTS ====================

    event YieldReceived(uint256 amount, uint256 toTreasury, uint256 toReserve);
    event LoanToPool(address indexed pool, uint256 positionId, uint256 amount);
    event LoanRepaid(address indexed pool, uint256 positionId, uint256 amount);
    event ShortfallCovered(address indexed pool, uint256 amount);
    event TreasuryTransfer(address indexed treasury, uint256 amount);
    event SplitConfigUpdated(uint256 treasuryBps, uint256 reserveBps);
    event MinReserveFloorUpdated(uint256 newFloor);
    event TreasuryUpdated(address newTreasury);
    event ReserveInvested(uint256 indexed investmentId, address indexed pool, uint256 amount);
    event ReserveInvestmentMatured(uint256 indexed investmentId, uint256 returned);
    
    event ProtocolFundsDeployed(address indexed pool, address indexed escrow, uint256 amount);
    event ProtocolFundsRecalled(address indexed pool, uint256 amount);
    event DirectDepositRecorded(address indexed pool, address indexed escrow, uint256 amount);
    event DirectDepositWithdrawnRecorded(address indexed pool, uint256 amount);
    event EscrowAuthorized(address indexed escrow, bool authorized);
    event StableYieldManagerUpdated(address indexed manager);

    // ==================== MODIFIERS ====================

    modifier onlyAuthorizedManager() {
        require(
            msg.sender == lockedPoolManager || msg.sender == stableYieldManager,
            "YieldReserveEscrow/unauthorized manager"
        );
        _;
    }

    modifier onlyAuthorizedManagerOrEscrow() {
        require(
            msg.sender == lockedPoolManager || 
            msg.sender == stableYieldManager || 
            authorizedEscrows[msg.sender],
            "YieldReserveEscrow/unauthorized"
        );
        _;
    }

    modifier onlyLockedPoolManager() {
        require(msg.sender == lockedPoolManager, "YieldReserveEscrow/only locked manager");
        _;
    }

    modifier onlyAuthorizedEscrow() {
        require(authorizedEscrows[msg.sender], "YieldReserveEscrow/unauthorized escrow");
        _;
    }

    modifier onlyOperator() {
        require(
            accessManager.hasRole(accessManager.OPERATOR_ROLE(), msg.sender),
            "YieldReserveEscrow/not operator"
        );
        _;
    }

    modifier onlyAdmin() {
        require(
            accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), msg.sender),
            "YieldReserveEscrow/not admin"
        );
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address asset_,
        address accessManager_,
        address treasury_,
        uint256 treasuryBps_,
        uint256 minReserveFloor_
    ) public initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        require(asset_ != address(0), "YieldReserveEscrow/invalid asset");
        require(accessManager_ != address(0), "YieldReserveEscrow/invalid access manager");
        require(treasury_ != address(0), "YieldReserveEscrow/invalid treasury");
        require(treasuryBps_ <= 10000, "YieldReserveEscrow/invalid treasury bps");

        asset = IERC20(asset_);
        accessManager = AccessManager(accessManager_);
        treasury = treasury_;
        treasuryBps = treasuryBps_;
        reserveBps = 10000 - treasuryBps_;
        minReserveFloor = minReserveFloor_;
        version = 1;
        nextInvestmentId = 1;
    }

    function setLockedPoolManager(address manager_) external onlyAdmin {
        require(manager_ != address(0), "YieldReserveEscrow/invalid manager");
        require(lockedPoolManager == address(0), "YieldReserveEscrow/manager already set");
        lockedPoolManager = manager_;
    }

    function setStableYieldManager(address manager_) external onlyAdmin {
        require(manager_ != address(0), "YieldReserveEscrow/invalid manager");
        require(stableYieldManager == address(0), "YieldReserveEscrow/manager already set");
        stableYieldManager = manager_;
        emit StableYieldManagerUpdated(manager_);
    }

    function authorizeEscrow(address escrow_, bool authorized_) external {
        require(
            accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), msg.sender) ||
            accessManager.hasRole(accessManager.FACTORY_ROLE(), msg.sender),
            "YieldReserveEscrow/not admin or factory"
        );
        require(escrow_ != address(0), "YieldReserveEscrow/invalid escrow");
        authorizedEscrows[escrow_] = authorized_;
        emit EscrowAuthorized(escrow_, authorized_);
    }

    function _authorizeUpgrade(address newImplementation) internal override {
        require(
            accessManager.hasRole(accessManager.MULTISIG_ADMIN_ROLE(), msg.sender),
            "YieldReserveEscrow/only multisig"
        );
        require(newImplementation != address(0), "YieldReserveEscrow/invalid implementation");
        version += 1;
    }

    function _trackPool(address pool) internal {
        if (!isTrackedPool[pool]) {
            trackedPools.push(pool);
            isTrackedPool[pool] = true;
        }
    }

    function receiveYield(uint256 amount) external onlyAuthorizedManagerOrEscrow nonReentrant {
        require(amount > 0, "YieldReserveEscrow/invalid amount");
        
        asset.safeTransferFrom(msg.sender, address(this), amount);
        
        uint256 toTreasury = (amount * treasuryBps) / 10000;
        uint256 toReserve = amount - toTreasury;
        
        totalBalance += toReserve;
        totalYieldReceived += amount;
        
        if (toTreasury > 0) {
            asset.safeTransfer(treasury, toTreasury);
            totalSentToTreasury += toTreasury;
        }
        
        emit YieldReceived(amount, toTreasury, toReserve);
    }

    function recordYield(uint256 amount) external onlyAuthorizedManager {
        require(amount > 0, "YieldReserveEscrow/invalid amount");
        
        uint256 toTreasury = (amount * treasuryBps) / 10000;
        uint256 toReserve = amount - toTreasury;
        
        totalBalance += toReserve;
        totalYieldReceived += amount;
        
        if (toTreasury > 0 && asset.balanceOf(address(this)) >= toTreasury) {
            asset.safeTransfer(treasury, toTreasury);
            totalSentToTreasury += toTreasury;
        }
        
        emit YieldReceived(amount, toTreasury, toReserve);
    }

    function deployToPool(
        address pool,
        address escrow,
        uint256 amount
    ) external nonReentrant {
        require(
            msg.sender == lockedPoolManager || 
            msg.sender == stableYieldManager ||
            accessManager.hasRole(accessManager.OPERATOR_ROLE(), msg.sender),
            "YieldReserveEscrow/unauthorized"
        );
        require(pool != address(0), "YieldReserveEscrow/invalid pool");
        require(escrow != address(0), "YieldReserveEscrow/invalid escrow");
        require(amount > 0, "YieldReserveEscrow/invalid amount");
        require(totalBalance >= amount, "YieldReserveEscrow/insufficient balance");
        
        _trackPool(pool);
        
        totalBalance -= amount;
        totalDeployedToEscrows += amount;
        deployedToPool[pool] += amount;
        
        asset.safeTransfer(escrow, amount);
        
        emit ProtocolFundsDeployed(pool, escrow, amount);
    }

    function receiveRecalledFunds(
        address pool,
        uint256 amount
    ) external onlyAuthorizedEscrow nonReentrant {
        require(pool != address(0), "YieldReserveEscrow/invalid pool");
        require(amount > 0, "YieldReserveEscrow/invalid amount");
        require(deployedToPool[pool] >= amount, "YieldReserveEscrow/exceeds deployed");
        
        asset.safeTransferFrom(msg.sender, address(this), amount);
        
        totalDeployedToEscrows -= amount;
        deployedToPool[pool] -= amount;
        totalBalance += amount;
        
        emit ProtocolFundsRecalled(pool, amount);
    }

    function recallFromPool(
        address pool,
        address escrow,
        uint256 amount
    ) external onlyOperator nonReentrant {
        require(pool != address(0), "YieldReserveEscrow/invalid pool");
        require(escrow != address(0), "YieldReserveEscrow/invalid escrow");
        require(amount > 0, "YieldReserveEscrow/invalid amount");
        require(deployedToPool[pool] >= amount, "YieldReserveEscrow/exceeds deployed");
        
        asset.safeTransferFrom(escrow, address(this), amount);
        
        totalDeployedToEscrows -= amount;
        deployedToPool[pool] -= amount;
        totalBalance += amount;
        
        emit ProtocolFundsRecalled(pool, amount);
    }

    function recordDirectDeposit(
        address pool,
        uint256 amount
    ) external onlyAuthorizedEscrow {
        require(pool != address(0), "YieldReserveEscrow/invalid pool");
        require(amount > 0, "YieldReserveEscrow/invalid amount");
        
        _trackPool(pool);
        
        totalDirectDepositsReported += amount;
        directDepositsToPool[pool] += amount;
        
        emit DirectDepositRecorded(pool, msg.sender, amount);
    }

    function recordDirectDepositWithdrawn(
        address pool,
        uint256 amount
    ) external onlyAuthorizedEscrow {
        require(pool != address(0), "YieldReserveEscrow/invalid pool");
        require(amount > 0, "YieldReserveEscrow/invalid amount");
        require(directDepositsToPool[pool] >= amount, "YieldReserveEscrow/exceeds direct deposits");
        
        totalDirectDepositsReported -= amount;
        directDepositsToPool[pool] -= amount;
        
        emit DirectDepositWithdrawnRecorded(pool, amount);
    }

    function loanToPool(
        address pool,
        uint256 positionId,
        uint256 amount,
        address recipient
    ) external onlyAuthorizedManager nonReentrant {
        require(pool != address(0), "YieldReserveEscrow/invalid pool");
        require(amount > 0, "YieldReserveEscrow/invalid amount");
        require(totalBalance >= amount, "YieldReserveEscrow/insufficient balance");
        require(recipient != address(0), "YieldReserveEscrow/invalid recipient");
        
        _trackPool(pool);
        
        totalBalance -= amount;
        totalLoanedOut += amount;
        poolLoans[pool] += amount;
        positionLoans[positionId] = amount;
        
        asset.safeTransfer(recipient, amount);
        
        emit LoanToPool(pool, positionId, amount);
    }

    function payUser(address user, uint256 amount) external onlyAuthorizedManager nonReentrant {
        require(user != address(0), "YieldReserveEscrow/invalid user");
        require(amount > 0, "YieldReserveEscrow/invalid amount");
        require(totalBalance >= amount, "YieldReserveEscrow/insufficient balance");
        
        totalBalance -= amount;
        totalLoanedOut += amount;
        
        asset.safeTransfer(user, amount);
    }

    function repayLoan(
        address pool,
        uint256 positionId,
        uint256 amount
    ) external onlyAuthorizedManager nonReentrant {
        require(amount > 0, "YieldReserveEscrow/invalid amount");
        
        uint256 loanOwed = positionLoans[positionId];
        uint256 repayAmount = amount > loanOwed ? loanOwed : amount;
        
        asset.safeTransferFrom(msg.sender, address(this), amount);
        
        if (repayAmount > 0) {
            totalLoanedOut -= repayAmount;
            poolLoans[pool] -= repayAmount;
            positionLoans[positionId] = 0;
            totalBalance += repayAmount;
        }
        
        uint256 excess = amount - repayAmount;
        if (excess > 0) {
            totalBalance += excess;
        }
        
        emit LoanRepaid(pool, positionId, repayAmount);
    }

    function recordLoanRepayment(
        address pool,
        uint256 positionId,
        uint256 amount
    ) external onlyAuthorizedManager {
        require(amount > 0, "YieldReserveEscrow/invalid amount");
        
        uint256 loanOwed = positionLoans[positionId];
        uint256 repayAmount = amount > loanOwed ? loanOwed : amount;
        
        if (repayAmount > 0) {
            totalLoanedOut -= repayAmount;
            poolLoans[pool] -= repayAmount;
            positionLoans[positionId] = 0;
            totalBalance += repayAmount;
        }
        
        uint256 excess = amount - repayAmount;
        if (excess > 0) {
            totalBalance += excess;
        }
        
        emit LoanRepaid(pool, positionId, repayAmount);
    }

    function coverShortfall(
        address pool,
        uint256 amount
    ) external onlyAuthorizedManager nonReentrant {
        require(amount > 0, "YieldReserveEscrow/invalid amount");
        require(totalBalance >= amount, "YieldReserveEscrow/insufficient balance");
        
        _trackPool(pool);
        
        totalBalance -= amount;
        totalLossesAbsorbed += amount;
        
        asset.safeTransfer(pool, amount);
        
        emit ShortfallCovered(pool, amount);
    }

    function investReserve(
        address pool,
        address escrow,
        uint256 amount,
        uint256 expectedReturn
    ) external onlyOperator nonReentrant returns (uint256 investmentId) {
        require(pool != address(0), "YieldReserveEscrow/invalid pool");
        require(escrow != address(0), "YieldReserveEscrow/invalid escrow");
        require(amount > 0, "YieldReserveEscrow/invalid amount");
        require(totalBalance > minReserveFloor + amount, "YieldReserveEscrow/below floor");
        
        _trackPool(pool);
        
        investmentId = nextInvestmentId++;
        
        reserveInvestments[investmentId] = ReserveInvestment({
            pool: pool,
            positionId: 0,
            amount: amount,
            expectedReturn: expectedReturn,
            investedAt: block.timestamp,
            active: true
        });
        
        totalBalance -= amount;
        totalInvested += amount;
        
        asset.safeTransfer(escrow, amount);
        
        emit ReserveInvested(investmentId, pool, amount);
        
        return investmentId;
    }

    function linkInvestmentToPosition(
        uint256 investmentId,
        uint256 positionId
    ) external onlyOperator {
        require(reserveInvestments[investmentId].active, "YieldReserveEscrow/investment not active");
        reserveInvestments[investmentId].positionId = positionId;
    }

    function recordInvestmentMaturity(
        uint256 investmentId,
        uint256 returnedAmount
    ) external onlyAuthorizedManager {
        ReserveInvestment storage investment = reserveInvestments[investmentId];
        require(investment.active, "YieldReserveEscrow/investment not active");
        
        investment.active = false;
        totalInvested -= investment.amount;
        totalBalance += returnedAmount;
        
        emit ReserveInvestmentMatured(investmentId, returnedAmount);
    }

    function setSplitConfig(uint256 newTreasuryBps) external onlyAdmin {
        require(newTreasuryBps <= 10000, "YieldReserveEscrow/invalid bps");
        treasuryBps = newTreasuryBps;
        reserveBps = 10000 - newTreasuryBps;
        emit SplitConfigUpdated(newTreasuryBps, reserveBps);
    }

    function setMinReserveFloor(uint256 newFloor) external onlyAdmin {
        minReserveFloor = newFloor;
        emit MinReserveFloorUpdated(newFloor);
    }

    function setTreasury(address newTreasury) external onlyAdmin {
        require(newTreasury != address(0), "YieldReserveEscrow/invalid treasury");
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function sweepToTreasury() external onlyOperator nonReentrant {
        require(totalBalance > minReserveFloor, "YieldReserveEscrow/below floor");
        
        uint256 sweepAmount = totalBalance - minReserveFloor;
        totalBalance = minReserveFloor;
        totalSentToTreasury += sweepAmount;
        
        asset.safeTransfer(treasury, sweepAmount);
        
        emit TreasuryTransfer(treasury, sweepAmount);
    }

    function emergencyWithdraw(address to, uint256 amount) external onlyAdmin nonReentrant {
        require(to != address(0), "YieldReserveEscrow/invalid recipient");
        require(amount > 0, "YieldReserveEscrow/invalid amount");
        require(asset.balanceOf(address(this)) >= amount, "YieldReserveEscrow/insufficient balance");
        
        if (amount <= totalBalance) {
            totalBalance -= amount;
        } else {
            totalBalance = 0;
        }
        
        asset.safeTransfer(to, amount);
    }

    function getAvailableBalance() external view returns (uint256) {
        return totalBalance;
    }

    function getAvailableForLoan() external view returns (uint256) {
        if (totalBalance > minReserveFloor) {
            return totalBalance - minReserveFloor;
        }
        return 0;
    }

    function getTotalLoaned() external view returns (uint256) {
        return totalLoanedOut;
    }

    function getPoolLoan(address pool) external view returns (uint256) {
        return poolLoans[pool];
    }

    function getPositionLoan(uint256 positionId) external view returns (uint256) {
        return positionLoans[positionId];
    }

    function getSplitConfig() external view returns (uint256 treasuryPct, uint256 reservePct) {
        return (treasuryBps, reserveBps);
    }

    function getReserveStats() external view returns (
        uint256 balance,
        uint256 loaned,
        uint256 invested,
        uint256 yieldReceived,
        uint256 sentToTreasury,
        uint256 lossesAbsorbed
    ) {
        return (
            totalBalance,
            totalLoanedOut,
            totalInvested,
            totalYieldReceived,
            totalSentToTreasury,
            totalLossesAbsorbed
        );
    }

    function getInvestment(uint256 investmentId) external view returns (ReserveInvestment memory) {
        return reserveInvestments[investmentId];
    }

    function getVersion() external view returns (uint256) {
        return version;
    }

    function getProtocolFundsSnapshot() external view returns (ProtocolFundsSnapshot memory snapshot) {
        return ProtocolFundsSnapshot({
            reserveBalance: totalBalance,
            totalDeployedViaReserve: totalDeployedToEscrows,
            totalDirectDeposits: totalDirectDepositsReported,
            totalEarlyExitLoans: totalLoanedOut,
            grandTotal: totalBalance + totalDeployedToEscrows + totalDirectDepositsReported + totalLoanedOut,
            poolCount: trackedPools.length
        });
    }

    function getPoolProtocolFunds(address pool) external view returns (PoolProtocolFunds memory funds) {
        return PoolProtocolFunds({
            fromReserve: deployedToPool[pool],
            directDeposit: directDepositsToPool[pool],
            earlyExitLoan: poolLoans[pool],
            total: deployedToPool[pool] + directDepositsToPool[pool] + poolLoans[pool]
        });
    }

    function getAllPoolsProtocolFunds() external view returns (
        address[] memory pools,
        uint256[] memory fromReserve,
        uint256[] memory directDeposits,
        uint256[] memory earlyExitLoans,
        uint256[] memory totals
    ) {
        uint256 len = trackedPools.length;
        pools = new address[](len);
        fromReserve = new uint256[](len);
        directDeposits = new uint256[](len);
        earlyExitLoans = new uint256[](len);
        totals = new uint256[](len);
        
        for (uint256 i = 0; i < len; i++) {
            address pool = trackedPools[i];
            pools[i] = pool;
            fromReserve[i] = deployedToPool[pool];
            directDeposits[i] = directDepositsToPool[pool];
            earlyExitLoans[i] = poolLoans[pool];
            totals[i] = fromReserve[i] + directDeposits[i] + earlyExitLoans[i];
        }
        
        return (pools, fromReserve, directDeposits, earlyExitLoans, totals);
    }

    function getTrackedPools() external view returns (address[] memory) {
        return trackedPools;
    }

    function getTrackedPoolCount() external view returns (uint256) {
        return trackedPools.length;
    }

    function isEscrowAuthorized(address escrow) external view returns (bool) {
        return authorizedEscrows[escrow];
    }
}
