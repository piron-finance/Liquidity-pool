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
 * @dev Holds protocol yield from locked pool operations
 * @notice Manages yield reserve, loans to pools for early exits, and treasury distributions
 */
contract YieldReserveEscrow is 
    Initializable, 
    UUPSUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    using SafeERC20 for IERC20;

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STATE VARIABLES //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    IERC20 public asset;
    AccessManager public accessManager;
    address public lockedPoolManager;
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

    struct ReserveInvestment {
        address pool;
        uint256 positionId;
        uint256 amount;
        uint256 expectedReturn;
        uint256 investedAt;
        bool active;
    }
    
    mapping(uint256 => ReserveInvestment) public reserveInvestments;
    uint256 public nextInvestmentId;
    uint256 public totalInvested;

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EVENTS //////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

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

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// MODIFIERS ///////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    modifier onlyLockedPoolManager() {
        require(msg.sender == lockedPoolManager, "YieldReserveEscrow/only manager");
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

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INITIALIZATION /////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the YieldReserveEscrow
     * @param asset_ Underlying stablecoin asset
     * @param accessManager_ Access manager address
     * @param treasury_ Treasury address for profit distribution
     * @param treasuryBps_ Percentage to treasury in basis points (6000 = 60%)
     * @param minReserveFloor_ Minimum reserve balance before treasury sweep
     */
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

    /**
     * @notice Set the locked pool manager address (one-time only)
     * @param manager_ The locked pool manager address
     */
    function setLockedPoolManager(address manager_) external onlyAdmin {
        require(manager_ != address(0), "YieldReserveEscrow/invalid manager");
        require(lockedPoolManager == address(0), "YieldReserveEscrow/manager already set");
        lockedPoolManager = manager_;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyAdmin {
        require(newImplementation != address(0), "YieldReserveEscrow/invalid implementation");
        version += 1;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// YIELD DISTRIBUTION ///////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Receive yield and split between treasury and reserve
     * @dev Called by LockedPoolManager when SPV returns funds
     * @param amount Yield amount to distribute
     */
    function receiveYield(uint256 amount) external onlyLockedPoolManager nonReentrant {
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

    /**
     * @notice Receive yield directly (when funds transferred separately)
     * @param amount Amount to record
     */
    function recordYield(uint256 amount) external onlyLockedPoolManager {
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

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// POOL LOANS //////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Loan funds to a pool for early exit payout
     * @param pool Pool address
     * @param positionId Position being exited
     * @param amount Loan amount
     */
    function loanToPool(
        address pool,
        uint256 positionId,
        uint256 amount
    ) external onlyLockedPoolManager nonReentrant {
        require(pool != address(0), "YieldReserveEscrow/invalid pool");
        require(amount > 0, "YieldReserveEscrow/invalid amount");
        require(totalBalance >= amount, "YieldReserveEscrow/insufficient balance");
        
        totalBalance -= amount;
        totalLoanedOut += amount;
        poolLoans[pool] += amount;
        positionLoans[positionId] = amount;
        
        asset.safeTransfer(pool, amount);
        
        emit LoanToPool(pool, positionId, amount);
    }

    /**
     * @notice Pay user directly from reserve (for early exit)
     * @param user User to pay
     * @param amount Amount to pay
     */
    function payUser(address user, uint256 amount) external onlyLockedPoolManager nonReentrant {
        require(user != address(0), "YieldReserveEscrow/invalid user");
        require(amount > 0, "YieldReserveEscrow/invalid amount");
        require(totalBalance >= amount, "YieldReserveEscrow/insufficient balance");
        
        totalBalance -= amount;
        totalLoanedOut += amount;
        
        asset.safeTransfer(user, amount);
    }

    /**
     * @notice Repay loan when SPV returns funds
     * @param pool Pool address
     * @param positionId Position that was exited
     * @param amount Repayment amount
     */
    function repayLoan(
        address pool,
        uint256 positionId,
        uint256 amount
    ) external onlyLockedPoolManager nonReentrant {
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

    /**
     * @notice Record loan repayment (when funds transferred separately)
     * @param pool Pool address
     * @param positionId Position ID
     * @param amount Amount repaid
     */
    function recordLoanRepayment(
        address pool,
        uint256 positionId,
        uint256 amount
    ) external onlyLockedPoolManager {
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

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// SHORTFALL COVERAGE //////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Cover shortfall when SPV underperforms
     * @param pool Pool needing coverage
     * @param amount Shortfall amount
     */
    function coverShortfall(
        address pool,
        uint256 amount
    ) external onlyLockedPoolManager nonReentrant {
        require(amount > 0, "YieldReserveEscrow/invalid amount");
        require(totalBalance >= amount, "YieldReserveEscrow/insufficient balance");
        
        totalBalance -= amount;
        totalLossesAbsorbed += amount;
        
        asset.safeTransfer(pool, amount);
        
        emit ShortfallCovered(pool, amount);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// RESERVE REINVESTMENT ////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Invest reserve funds in a locked pool position
     * @dev Only when reserve balance exceeds floor. Funds sent to escrow.
     * @param pool Pool to invest in (for tracking)
     * @param escrow Pool's escrow to receive funds
     * @param amount Amount to invest
     * @param expectedReturn Expected return at maturity
     * @return investmentId ID of the reserve investment
     */
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

    /**
     * @notice Record position ID for reserve investment
     * @param investmentId Reserve investment ID
     * @param positionId Pool position ID
     */
    function linkInvestmentToPosition(
        uint256 investmentId,
        uint256 positionId
    ) external onlyOperator {
        require(reserveInvestments[investmentId].active, "YieldReserveEscrow/investment not active");
        reserveInvestments[investmentId].positionId = positionId;
    }

    /**
     * @notice Record matured reserve investment return
     * @param investmentId Investment that matured
     * @param returnedAmount Amount returned
     */
    function recordInvestmentMaturity(
        uint256 investmentId,
        uint256 returnedAmount
    ) external onlyLockedPoolManager {
        ReserveInvestment storage investment = reserveInvestments[investmentId];
        require(investment.active, "YieldReserveEscrow/investment not active");
        
        investment.active = false;
        totalInvested -= investment.amount;
        totalBalance += returnedAmount;
        
        emit ReserveInvestmentMatured(investmentId, returnedAmount);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ADMIN FUNCTIONS //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Update treasury/reserve split
     * @param newTreasuryBps New treasury percentage in basis points
     */
    function setSplitConfig(uint256 newTreasuryBps) external onlyAdmin {
        require(newTreasuryBps <= 10000, "YieldReserveEscrow/invalid bps");
        treasuryBps = newTreasuryBps;
        reserveBps = 10000 - newTreasuryBps;
        emit SplitConfigUpdated(newTreasuryBps, reserveBps);
    }

    /**
     * @notice Update minimum reserve floor
     * @param newFloor New minimum balance
     */
    function setMinReserveFloor(uint256 newFloor) external onlyAdmin {
        minReserveFloor = newFloor;
        emit MinReserveFloorUpdated(newFloor);
    }

    /**
     * @notice Update treasury address
     * @param newTreasury New treasury address
     */
    function setTreasury(address newTreasury) external onlyAdmin {
        require(newTreasury != address(0), "YieldReserveEscrow/invalid treasury");
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    /**
     * @notice Sweep excess balance to treasury
     * @dev Only allows sweep above min floor
     */
    function sweepToTreasury() external onlyOperator nonReentrant {
        require(totalBalance > minReserveFloor, "YieldReserveEscrow/below floor");
        
        uint256 sweepAmount = totalBalance - minReserveFloor;
        totalBalance = minReserveFloor;
        totalSentToTreasury += sweepAmount;
        
        asset.safeTransfer(treasury, sweepAmount);
        
        emit TreasuryTransfer(treasury, sweepAmount);
    }

    /**
     * @notice Emergency withdraw (admin only)
     * @param to Recipient
     * @param amount Amount to withdraw
     */
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

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// VIEW FUNCTIONS ///////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

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
}

