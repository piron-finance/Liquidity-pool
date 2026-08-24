// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../AccessManager.sol";
import "../interfaces/IFeeManager.sol";
import "../interfaces/IYieldReserveEscrow.sol";
import "./YieldReserveEscrow.sol";

/**
 * @title LockedPoolEscrow
 * @dev Secure custody for a single LockedPool. Holds principal deposits, pays
 *      interest (upfront or at maturity), processes early-exit penalties, manages
 *      SPV allocations, and routes yield to YieldReserveEscrow.
 */
contract LockedPoolEscrow is 
    Initializable, 
    UUPSUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    // ==================== STATE ====================

    using SafeERC20 for IERC20; 

    IERC20 public asset;

    address public lockedPool;
    address public lockedPoolManager;

    AccessManager public accessManager;
    
    uint256 public version;

    string public poolName;
 
    uint256 public principalHeld;
    uint256 public interestPaidOut;
    uint256 public penaltiesCollected;
   
    /// @dev Cumulative capital ever sent to an SPV. Never decreases; not a live exposure figure.
    mapping(address => uint256) public lifetimeAllocatedToSPV;

    uint256 public protocolFundsFromReserve;  
    uint256 public protocolFundsDirectDeposit;
    
    address public feeManager;
    address public yieldReserve;

    uint256 public depositFeesCollected;
    uint256 public withdrawalFeesCollected;

    // ==================== EVENTS ====================

    event FundsDeposited(address indexed from, uint256 amount);
    event FundsWithdrawn(address indexed to, uint256 amount);
    event InterestPaid(address indexed to, uint256 amount);
    event PenaltyCollected(uint256 amount);
    event SPVAllocation(address indexed spv, uint256 amount);
    event SPVReturn(address indexed spv, uint256 amount);
    event PoolLinked(address indexed lockedPool);
    
    event ProtocolFundsReceived(address indexed from, uint256 amount);
    event ProtocolFundsReleased(address indexed to, uint256 amount);
    event DustSwept(address indexed feeManager, uint256 amount);
    event PenaltiesSentToFeeManager(uint256 amount);
    event PenaltiesSentToReserve(uint256 amount);
    event DepositFeeCollected(uint256 amount);
    event WithdrawalFeeCollected(uint256 amount);
    event FeeManagerUpdated(address indexed feeManager);
    event YieldReserveUpdated(address indexed yieldReserve);
    event YieldSentToReserve(uint256 amount);

    // ==================== MODIFIERS ====================

    modifier onlyLockedPool() {
        require(msg.sender == lockedPool, "LockedPoolEscrow/only pool");
        _;
    }

    modifier onlyLockedPoolOrManager() {
        require(
            msg.sender == lockedPool || 
            msg.sender == lockedPoolManager ||
            accessManager.hasRole(accessManager.OPERATOR_ROLE(), msg.sender), 
            "LockedPoolEscrow/only pool or manager"
        );
        _;
    }

    modifier onlyOperator() {
        require(
            accessManager.hasRole(accessManager.OPERATOR_ROLE(), msg.sender),
            "LockedPoolEscrow/not operator"
        );
        _;
    }

    modifier onlyFactory() {
        require(
            accessManager.hasRole(accessManager.FACTORY_ROLE(), msg.sender),
            "LockedPoolEscrow/not factory"
        );
        _;
    }

    modifier onlyAdmin() {
        require(
            accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), msg.sender),
            "LockedPoolEscrow/not admin"
        );
        _;
    }


    // ==================== MODIFIERS ====================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address asset_,
        address accessManager_,
        string memory poolName_
    ) public initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        require(asset_ != address(0), "LockedPoolEscrow/invalid asset");
        require(accessManager_ != address(0), "LockedPoolEscrow/invalid access manager");
        require(bytes(poolName_).length > 0, "LockedPoolEscrow/invalid pool name");

        asset = IERC20(asset_);
        lockedPool = address(0); 
        accessManager = AccessManager(accessManager_);
        poolName = poolName_;
        version = 1;
    }

    function setLockedPool(address pool_) external onlyFactory {
        require(lockedPool == address(0), "LockedPoolEscrow/pool already set");
        require(pool_ != address(0), "LockedPoolEscrow/invalid pool");
        lockedPool = pool_;
        emit PoolLinked(pool_);
    }
    
    function setLockedPoolManager(address manager_) external onlyFactory {
        require(manager_ != address(0), "LockedPoolEscrow/invalid manager");
        require(lockedPoolManager == address(0), "LockedPoolEscrow/manager already set");
        lockedPoolManager = manager_;
    }

    function setFeeManager(address feeManager_) external onlyFactory {
        require(feeManager_ != address(0), "LockedPoolEscrow/invalid fee manager");
        feeManager = feeManager_;
        emit FeeManagerUpdated(feeManager_);
    }

    function setYieldReserve(address yieldReserve_) external onlyFactory {
        require(yieldReserve_ != address(0), "LockedPoolEscrow/invalid yield reserve");
        yieldReserve = yieldReserve_;
        emit YieldReserveUpdated(yieldReserve_);
    }

    function _authorizeUpgrade(address) internal pure override {
        revert("LockedPoolEscrow/upgrades disabled");
    }

 // ==================== Deposit & Withdrawal ====================

    function processDeposit(uint256 amount, uint256 feeBps) external onlyLockedPoolOrManager nonReentrant returns (uint256 netAmount, uint256 fee) {
        require(amount > 0, "LockedPoolEscrow/invalid amount");
        
        uint256 currentBalance = asset.balanceOf(address(this));
        require(currentBalance >= principalHeld + amount, "LockedPoolEscrow/insufficient balance");

        fee = (feeBps > 0 && feeManager != address(0)) ? (amount * feeBps) / 10000 : 0;
        netAmount = amount - fee;
        
        principalHeld += netAmount;
        
        if (fee > 0) {
            depositFeesCollected += fee;
            asset.safeTransfer(feeManager, fee);
            IFeeManager(feeManager).recordFeeOnly(
                lockedPool,
                address(asset),
                fee,
                IFeeManager.FeeType.DEPOSIT_FEE
            );
            emit DepositFeeCollected(fee);
        }
        
        emit FundsDeposited(msg.sender, netAmount);
    }

    /**
     * @dev Draws `amount` from the escrow's tracked balances: pool cash first, then the
     *      protocol capital that funds yield. Reverts when the tracked balances do not
     *      cover it, rather than zeroing a counter and transferring anyway.
     */
    function _drawFunds(uint256 amount) internal returns (uint256 fromProtocol) {
        uint256 fromPrincipal = amount > principalHeld ? principalHeld : amount;
        fromProtocol = amount - fromPrincipal;
        
        uint256 fromReserve = fromProtocol > protocolFundsFromReserve ? protocolFundsFromReserve : fromProtocol;
        uint256 fromDirect = fromProtocol - fromReserve;
        require(protocolFundsDirectDeposit >= fromDirect, "LockedPoolEscrow/insufficient funds");
        
        principalHeld -= fromPrincipal;
        protocolFundsFromReserve -= fromReserve;
        protocolFundsDirectDeposit -= fromDirect;
    }

    function payInterest(address to, uint256 amount) external onlyLockedPoolOrManager nonReentrant {
        require(to != address(0), "LockedPoolEscrow/invalid recipient");
        require(amount > 0, "LockedPoolEscrow/invalid amount");
        _drawFunds(amount);
        interestPaidOut += amount;
        
        asset.safeTransfer(to, amount);
        
        emit InterestPaid(to, amount);
    }

    function withdraw(address to, uint256 amount) external onlyLockedPoolOrManager nonReentrant {
        require(to != address(0), "LockedPoolEscrow/invalid recipient");
        require(amount > 0, "LockedPoolEscrow/invalid amount");
        require(asset.balanceOf(address(this)) >= amount, "LockedPoolEscrow/insufficient balance");
        
        // A maturity payout is principal plus interest. Only the principal is in principalHeld;
        // the interest is funded from protocol capital, so it must be debited there.
        uint256 interestPortion = _drawFunds(amount);
        interestPaidOut += interestPortion;
        
        asset.safeTransfer(to, amount);
        
        emit FundsWithdrawn(to, amount);
    }


 // ==================== PENALTIES ====================

    function recordPenalty(uint256 amount) external onlyLockedPoolOrManager {
        require(principalHeld >= amount, "LockedPoolEscrow/penalty exceeds principal");
        principalHeld -= amount;
        penaltiesCollected += amount;
        emit PenaltyCollected(amount);
    }

    function transferPenaltiesToFeeManager() external onlyOperator nonReentrant {
        require(feeManager != address(0), "LockedPoolEscrow/fee manager not set");
        require(penaltiesCollected > 0, "LockedPoolEscrow/no penalties");
        
        uint256 amount = penaltiesCollected;
        penaltiesCollected = 0;
        
        asset.forceApprove(feeManager, amount);
        IFeeManager(feeManager).collectFee(
            lockedPool,
            address(asset),
            amount,
            IFeeManager.FeeType.EARLY_EXIT_PENALTY
        );
        
        emit PenaltiesSentToFeeManager(amount);
    }

    function transferPenaltiesToReserve() external onlyOperator nonReentrant {
        require(yieldReserve != address(0), "LockedPoolEscrow/yield reserve not set");
        require(penaltiesCollected > 0, "LockedPoolEscrow/no penalties");
        
        uint256 amount = penaltiesCollected;
        penaltiesCollected = 0;
        
        asset.forceApprove(yieldReserve, amount);
        YieldReserveEscrow(yieldReserve).receiveYield(amount);
        
        emit PenaltiesSentToReserve(amount);
    }

    function sendYieldToReserve(uint256 amount) external onlyLockedPoolOrManager nonReentrant {
        require(yieldReserve != address(0), "LockedPoolEscrow/yield reserve not set");
        require(amount > 0, "LockedPoolEscrow/invalid amount");
        require(principalHeld >= amount, "LockedPoolEscrow/insufficient funds");
        
        principalHeld -= amount;
        
        asset.forceApprove(yieldReserve, amount);
        YieldReserveEscrow(yieldReserve).receiveYield(amount);
        
        emit YieldSentToReserve(amount);
    }

    function collectWithdrawalFee(uint256 amount) external onlyLockedPoolOrManager nonReentrant {
        require(feeManager != address(0), "LockedPoolEscrow/fee manager not set");
        require(amount > 0, "LockedPoolEscrow/invalid fee amount");
        require(principalHeld >= amount, "LockedPoolEscrow/fee exceeds principal");
        
        principalHeld -= amount;
        withdrawalFeesCollected += amount;
        
        asset.safeTransfer(feeManager, amount);
        IFeeManager(feeManager).recordFeeOnly(
            lockedPool,
            address(asset),
            amount,
            IFeeManager.FeeType.WITHDRAWAL_FEE
        );
        
        emit WithdrawalFeeCollected(amount);
    }

    function receiveProtocolFundsFromAdmin(uint256 amount) external onlyAdmin nonReentrant {
        require(amount > 0, "LockedPoolEscrow/invalid amount");
        
        asset.safeTransferFrom(msg.sender, address(this), amount);
        protocolFundsDirectDeposit += amount;
        
        if (yieldReserve != address(0)) {
            IYieldReserveEscrow(yieldReserve).recordDirectDeposit(lockedPool, amount);
        }
        
        emit ProtocolFundsReceived(msg.sender, amount);
    }

    function recordProtocolFundsFromReserve(uint256 amount) external {
        require(
            msg.sender == yieldReserve || 
            accessManager.hasRole(accessManager.OPERATOR_ROLE(), msg.sender),
            "LockedPoolEscrow/unauthorized"
        );
        require(amount > 0, "LockedPoolEscrow/invalid amount");
        
        protocolFundsFromReserve += amount;
        
        emit ProtocolFundsReceived(msg.sender, amount);
    }

    function returnProtocolFundsToReserve(uint256 amount) external nonReentrant {
        require(
            msg.sender == lockedPoolManager ||
            accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), msg.sender),
            "LockedPoolEscrow/unauthorized"
        );
        require(yieldReserve != address(0), "LockedPoolEscrow/yield reserve not set");
        require(amount > 0, "LockedPoolEscrow/invalid amount");
        require(protocolFundsFromReserve >= amount, "LockedPoolEscrow/exceeds reserve funds");
        
        protocolFundsFromReserve -= amount;
        
        asset.forceApprove(yieldReserve, amount);
        IYieldReserveEscrow(yieldReserve).receiveRecalledFunds(lockedPool, amount);
        
        emit ProtocolFundsReleased(yieldReserve, amount);
    }

    function releaseDirectDepositFunds(address to, uint256 amount) external onlyAdmin nonReentrant {
        require(to != address(0), "LockedPoolEscrow/invalid recipient");
        require(amount > 0, "LockedPoolEscrow/invalid amount");
        require(protocolFundsDirectDeposit >= amount, "LockedPoolEscrow/exceeds direct deposits");
        
        protocolFundsDirectDeposit -= amount;
        
        asset.safeTransfer(to, amount);
        
        if (yieldReserve != address(0)) {
            IYieldReserveEscrow(yieldReserve).recordDirectDepositWithdrawn(lockedPool, amount);
        }
        
        emit ProtocolFundsReleased(to, amount);
    }

    function getProtocolFundsHeld() external view returns (uint256) {
        return protocolFundsFromReserve + protocolFundsDirectDeposit;
    }

    function sweepDust() external onlyOperator nonReentrant {
        require(feeManager != address(0), "LockedPoolEscrow/fee manager not set");
        
        uint256 actualBalance = asset.balanceOf(address(this));
        uint256 expectedBalance = principalHeld + penaltiesCollected + protocolFundsFromReserve + protocolFundsDirectDeposit;
        
        require(actualBalance > expectedBalance, "LockedPoolEscrow/no dust to sweep");
        
        uint256 dust = actualBalance - expectedBalance;
        
        uint256 minThreshold = IFeeManager(feeManager).getMinSweepThreshold();
        require(dust >= minThreshold, "LockedPoolEscrow/dust below threshold");
        
        asset.safeTransfer(feeManager, dust);
        IFeeManager(feeManager).recordFeeOnly(
            lockedPool,
            address(asset),
            dust,
            IFeeManager.FeeType.OTHER
        );
        
        emit DustSwept(feeManager, dust);
    }

    function getSweepableDust() external view returns (uint256 dust) {
        uint256 actualBalance = asset.balanceOf(address(this));
        uint256 expectedBalance = principalHeld + penaltiesCollected + protocolFundsFromReserve + protocolFundsDirectDeposit;
        
        if (actualBalance > expectedBalance) {
            return actualBalance - expectedBalance;
        }
        return 0;
    }

    function allocateToSPV(address spvAddress, uint256 amount) external onlyOperator nonReentrant {
        require(spvAddress != address(0), "LockedPoolEscrow/invalid SPV");
        require(amount > 0, "LockedPoolEscrow/invalid amount");
        require(principalHeld >= amount, "LockedPoolEscrow/insufficient principal");
        
        principalHeld -= amount;
        lifetimeAllocatedToSPV[spvAddress] += amount;
        
        asset.safeTransfer(spvAddress, amount);
        
        emit SPVAllocation(spvAddress, amount);
    }
    
    function receiveSPVReturn(uint256 amount) external nonReentrant {
        require(
            msg.sender == lockedPoolManager ||
            accessManager.hasRole(accessManager.OPERATOR_ROLE(), msg.sender) ||
            accessManager.hasRole(accessManager.SPV_ROLE(), msg.sender),
            "LockedPoolEscrow/not authorized"
        );
        require(amount > 0, "LockedPoolEscrow/invalid amount");
        
        asset.safeTransferFrom(msg.sender, address(this), amount);
        principalHeld += amount;
        
        emit SPVReturn(msg.sender, amount);
    }

    function recordReceivedFunds(uint256 amount) external {
        require(msg.sender == lockedPoolManager, "LockedPoolEscrow/only manager");
        require(amount > 0, "LockedPoolEscrow/invalid amount");
        
        principalHeld += amount;
        
        emit SPVReturn(msg.sender, amount);
    }

    function getPrincipalHeld() external view returns (uint256) {
        return principalHeld;
    }

    function getInterestPaidOut() external view returns (uint256) {
        return interestPaidOut;
    }

    function getPenaltiesCollected() external view returns (uint256) {
        return penaltiesCollected;
    }

    function getProtocolFundsFromReserve() external view returns (uint256) {
        return protocolFundsFromReserve;
    }

    function getProtocolFundsDirectDeposit() external view returns (uint256) {
        return protocolFundsDirectDeposit;
    }

    function getLifetimeAllocatedToSPV(address spvAddress) external view returns (uint256) {
        return lifetimeAllocatedToSPV[spvAddress];
    }

    function getTotalBalance() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function getExpectedBalance() external view returns (uint256) {
        return principalHeld + penaltiesCollected + protocolFundsFromReserve + protocolFundsDirectDeposit;
    }

    function getDepositFeesCollected() external view returns (uint256) {
        return depositFeesCollected;
    }

    function getWithdrawalFeesCollected() external view returns (uint256) {
        return withdrawalFeesCollected;
    }

    function getTotalFeesCollected() external view returns (uint256) {
        return depositFeesCollected + withdrawalFeesCollected;
    }

    function getVersion() external view returns (uint256) {
        return version;
    }

    function updatePoolName(string memory newPoolName) external onlyAdmin {
        require(bytes(newPoolName).length > 0, "LockedPoolEscrow/invalid pool name");
        poolName = newPoolName;
    }
}
