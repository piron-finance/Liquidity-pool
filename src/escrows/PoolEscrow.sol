// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/IPoolEscrow.sol";
import "../interfaces/IFeeManager.sol";
import "../interfaces/IYieldReserveEscrow.sol";

/**
 * @title PoolEscrow
 * @dev Secure custody for Single Asset (deal) pools. Tracks deposits, coupons,
 *      maturity returns, large transfer detection, and emergency mode.
 */
contract PoolEscrow is Initializable, UUPSUpgradeable, IPoolEscrow, ReentrancyGuardUpgradeable, AccessControlUpgradeable {
    // ==================== STATE ====================

    using SafeERC20 for IERC20;
    
    IERC20 public asset;
    address public manager;
    address public override pool;
    address public override spvAddress;

    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    
    mapping(address => uint256) public deposits;
    uint256 public totalDeposits;
    uint256 public totalLocked;
    
    uint256 public totalCouponPool;
    uint256 public totalCouponsClaimed;
    
    mapping(address => uint256) public userDepositHistory;
    mapping(address => uint256) public userWithdrawalHistory;
    mapping(address => uint256) public userCouponHistory;
    
    uint256 public totalCouponPaymentsReceived;
    uint256 public totalCouponPaymentsDistributed;
    
    uint256 public totalMaturityReturns;
    
    mapping(bytes32 => Transfer) private transfers;
    mapping(bytes32 => mapping(address => bool)) private transferApprovals;
    mapping(bytes32 => uint256) private transferCreationTime;
    
    uint256 public constant LARGE_TRANSFER_THRESHOLD = 100000e6; 
    
    bool public emergencyMode = false;
    uint256 public emergencyModeActivated;

    uint256 public protocolFundsFromReserve;
    uint256 public protocolFundsDirectDeposit;
    
    address public feeManager;
    address public yieldReserve;

    uint256 public depositFeesCollected;
    uint256 public withdrawalFeesCollected;
    
    // ==================== EVENTS ====================

    event Deposit(address indexed user, uint256 amount, uint256 timestamp);
    event FundsReleased(address indexed recipient, uint256 amount, bytes32 indexed transferId);
    event FundsLocked(uint256 amount, string reason);
    event LargeTransferDetected(bytes32 indexed transferId, uint256 amount, uint256 threshold);
    event CouponPaymentTracked(uint256 amount, uint256 totalCoupons, uint256 timestamp);
    event MaturityReturnTracked(uint256 amount, uint256 totalReturns, uint256 timestamp);
    event CouponClaimed(address indexed user, uint256 amount, uint256 timestamp);
    
    event ProtocolFundsReceived(address indexed from, uint256 amount);
    event ProtocolFundsReleased(address indexed to, uint256 amount);
    event DustSwept(address indexed feeManager, uint256 amount);
    event DepositFeeCollected(uint256 amount);
    event WithdrawalFeeCollected(uint256 amount);
    event FeeManagerUpdated(address indexed feeManager);
    event YieldReserveUpdated(address indexed yieldReserve);
    
    // ==================== MODIFIERS ====================

    modifier onlyManager() {
        require(msg.sender == manager, "PoolEscrow/only-manager");
        _;
    }
    
    modifier notInEmergencyMode() {
        require(!emergencyMode, "PoolEscrow/emergency-mode-active");
        _;
    }
    
    modifier validTransfer(bytes32 transferId) {
        require(transfers[transferId].amount > 0, "PoolEscrow/transfer-not-found");
        _;
    }
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    function initialize(
        address _asset,
        address _manager,
        address _spvAddress
    ) public initializer {
        require(_asset != address(0), "PoolEscrow/invalid-asset");
        require(_manager != address(0), "PoolEscrow/invalid-manager");
        require(_spvAddress != address(0), "PoolEscrow/invalid-spv");
        
        __ReentrancyGuard_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        
        asset = IERC20(_asset);
        manager = _manager;
        spvAddress = _spvAddress;
        pool = address(0);
        
        _grantRole(DEFAULT_ADMIN_ROLE, manager);
        _grantRole(EMERGENCY_ROLE, manager);
    }
    
    function _authorizeUpgrade(address) internal pure override {
        revert("Escrow upgrades disabled for security");
    }

    function setPool(address _pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_pool != address(0), "PoolEscrow/invalid-pool");
        require(pool == address(0), "PoolEscrow/pool-already-set"); 
        pool = _pool;
    }

    function setFeeManager(address _feeManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_feeManager != address(0), "PoolEscrow/invalid-fee-manager");
        feeManager = _feeManager;
        emit FeeManagerUpdated(_feeManager);
    }

    function setYieldReserve(address _yieldReserve) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_yieldReserve != address(0), "PoolEscrow/invalid-yield-reserve");
        yieldReserve = _yieldReserve;
        emit YieldReserveUpdated(_yieldReserve);
    }

    function grantOperatorRole(address operator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(OPERATOR_ROLE, operator);
    }
    
    function processDeposit(address user, uint256 amount, uint256 feeBps) external override onlyManager nonReentrant returns (uint256 netAmount, uint256 fee) {
        require(user != address(0), "PoolEscrow/invalid-user");
        require(amount > 0, "PoolEscrow/invalid-amount");
        
        fee = (feeBps > 0 && feeManager != address(0)) ? (amount * feeBps) / 10000 : 0;
        netAmount = amount - fee;
        
        deposits[user] += netAmount;
        totalDeposits += netAmount;
        userDepositHistory[user] += netAmount;
        
        if (fee > 0) {
            depositFeesCollected += fee;
            asset.safeTransfer(feeManager, fee);
            IFeeManager(feeManager).recordFeeOnly(
                pool,
                address(asset),
                fee,
                IFeeManager.FeeType.DEPOSIT_FEE
            );
            emit DepositFeeCollected(fee);
        }
        
        emit Deposit(user, netAmount, block.timestamp);
    }
    
    function lockFunds(uint256 amount) external override onlyManager {
        require(amount > 0, "PoolEscrow/invalid-amount");
        require(amount <= getAvailableBalance(), "PoolEscrow/insufficient-balance");
        
        totalLocked += amount;
        
        emit FundsLocked(amount, "Manager lock");
    }
    
    function releaseFunds(address recipient, uint256 amount) external override onlyManager nonReentrant {
        require(recipient != address(0), "PoolEscrow/invalid-recipient");
        require(amount > 0, "PoolEscrow/invalid-amount");
        require(amount <= getAvailableBalance(), "PoolEscrow/insufficient-balance");
        
        userWithdrawalHistory[recipient] += amount;
        
        asset.safeTransfer(recipient, amount);
        
        if (amount > LARGE_TRANSFER_THRESHOLD) {
            bytes32 transferId = keccak256(abi.encodePacked(
                TransferType.REFUND_USERS,
                recipient,
                amount,
                "Manager release",
                block.timestamp,
                msg.sender
            ));
            emit LargeTransferDetected(transferId, amount, LARGE_TRANSFER_THRESHOLD);
        }
        
        emit FundsReleased(recipient, amount, bytes32(0));
    }
    
    function withdrawForInvestment(uint256 amount) external onlyManager notInEmergencyMode returns (bytes32 transferId) {
        require(amount > 0, "PoolEscrow/invalid-amount");
        require(amount <= getAvailableBalance(), "PoolEscrow/insufficient-balance");
        
        transferId = keccak256(abi.encodePacked(
            TransferType.TO_SPV,
            spvAddress,
            amount,
            "Investment withdrawal",
            block.timestamp,
            msg.sender
        ));
        
        transfers[transferId] = Transfer({
            transferType: TransferType.TO_SPV,
            recipient: spvAddress,
            amount: amount,
            data: "Investment withdrawal",
            confirmations: 1,
            executed: true, 
            timestamp: block.timestamp
        });
        
        asset.safeTransfer(spvAddress, amount);
        
        if (amount > LARGE_TRANSFER_THRESHOLD) {
            emit LargeTransferDetected(transferId, amount, LARGE_TRANSFER_THRESHOLD);
        }
        
        emit FundsReleased(spvAddress, amount, transferId);
        
        return transferId;
    }

    function collectWithdrawalFee(uint256 amount) external override onlyManager nonReentrant {
        require(feeManager != address(0), "PoolEscrow/fee-manager-not-set");
        require(amount > 0, "PoolEscrow/invalid-fee-amount");
        require(totalDeposits >= amount, "PoolEscrow/fee-exceeds-deposits");
        
        totalDeposits -= amount;
        withdrawalFeesCollected += amount;
        
        asset.safeTransfer(feeManager, amount);
        IFeeManager(feeManager).recordFeeOnly(
            pool,
            address(asset),
            amount,
            IFeeManager.FeeType.WITHDRAWAL_FEE
        );
        
        emit WithdrawalFeeCollected(amount);
    }
    
    function trackCouponPayment(uint256 amount) external onlyManager {
        require(amount > 0, "PoolEscrow/invalid-amount");
        
        totalCouponPaymentsReceived += amount;
        totalCouponPool += amount;
        
        emit CouponPaymentTracked(amount, totalCouponPaymentsReceived, block.timestamp);
    }
    
    function trackMaturityReturn(uint256 amount) external onlyManager {
        require(amount > 0, "PoolEscrow/invalid-amount");
        
        totalMaturityReturns += amount;
        
        emit MaturityReturnTracked(amount, totalMaturityReturns, block.timestamp);
    }
    
    function claimCoupon(address user, uint256 amount) external onlyManager nonReentrant {
        require(user != address(0), "PoolEscrow/invalid-user");
        require(amount > 0, "PoolEscrow/invalid-amount");
        require(amount <= getAvailableBalance(), "PoolEscrow/insufficient-balance");
        
        totalCouponsClaimed += amount;
        userCouponHistory[user] += amount;
        
        asset.safeTransfer(user, amount);
        
        emit CouponClaimed(user, amount, block.timestamp);
    }

    function receiveProtocolFundsFromAdmin(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(amount > 0, "PoolEscrow/invalid-amount");
        
        asset.safeTransferFrom(msg.sender, address(this), amount);
        protocolFundsDirectDeposit += amount;
        
        if (yieldReserve != address(0)) {
            IYieldReserveEscrow(yieldReserve).recordDirectDeposit(pool, amount);
        }
        
        emit ProtocolFundsReceived(msg.sender, amount);
    }

    function recordProtocolFundsFromReserve(uint256 amount) external {
        require(
            msg.sender == yieldReserve || 
            hasRole(OPERATOR_ROLE, msg.sender),
            "PoolEscrow/unauthorized"
        );
        require(amount > 0, "PoolEscrow/invalid-amount");
        
        protocolFundsFromReserve += amount;
        
        emit ProtocolFundsReceived(msg.sender, amount);
    }

    function returnProtocolFundsToReserve(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(yieldReserve != address(0), "PoolEscrow/yield-reserve-not-set");
        require(amount > 0, "PoolEscrow/invalid-amount");
        require(protocolFundsFromReserve >= amount, "PoolEscrow/exceeds-reserve-funds");
        
        protocolFundsFromReserve -= amount;
        
        asset.forceApprove(yieldReserve, amount);
        IYieldReserveEscrow(yieldReserve).receiveRecalledFunds(pool, amount);
        
        emit ProtocolFundsReleased(yieldReserve, amount);
    }

    function releaseDirectDepositFunds(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(to != address(0), "PoolEscrow/invalid-recipient");
        require(amount > 0, "PoolEscrow/invalid-amount");
        require(protocolFundsDirectDeposit >= amount, "PoolEscrow/exceeds-direct-deposits");
        
        protocolFundsDirectDeposit -= amount;
        
        asset.safeTransfer(to, amount);
        
        if (yieldReserve != address(0)) {
            IYieldReserveEscrow(yieldReserve).recordDirectDepositWithdrawn(pool, amount);
        }
        
        emit ProtocolFundsReleased(to, amount);
    }

    function getProtocolFundsHeld() external view returns (uint256) {
        return protocolFundsFromReserve + protocolFundsDirectDeposit;
    }

    function sweepDust() external onlyRole(OPERATOR_ROLE) nonReentrant {
        require(feeManager != address(0), "PoolEscrow/fee-manager-not-set");
        
        uint256 actualBalance = asset.balanceOf(address(this));
        uint256 expectedBalance = totalDeposits + totalLocked + protocolFundsFromReserve + protocolFundsDirectDeposit + totalCouponPool;
        
        require(actualBalance > expectedBalance, "PoolEscrow/no-dust-to-sweep");
        
        uint256 dust = actualBalance - expectedBalance;
        
        uint256 minThreshold = IFeeManager(feeManager).getMinSweepThreshold();
        require(dust >= minThreshold, "PoolEscrow/dust-below-threshold");
        
        asset.safeTransfer(feeManager, dust);
        IFeeManager(feeManager).recordFeeOnly(
            pool,
            address(asset),
            dust,
            IFeeManager.FeeType.OTHER
        );
        
        emit DustSwept(feeManager, dust);
    }

    function getSweepableDust() external view returns (uint256 dust) {
        uint256 actualBalance = asset.balanceOf(address(this));
        uint256 expectedBalance = totalDeposits + totalLocked + protocolFundsFromReserve + protocolFundsDirectDeposit + totalCouponPool;
        
        if (actualBalance > expectedBalance) {
            return actualBalance - expectedBalance;
        }
        return 0;
    }
    
    function getBalance() external view override returns (uint256) {
        return asset.balanceOf(address(this));
    }
    
    function getAvailableBalance() public view returns (uint256) {
        uint256 totalBalance = asset.balanceOf(address(this));
        return totalBalance > totalLocked ? totalBalance - totalLocked : 0;
    }
    
    function getTransfer(bytes32 transferId) external view override returns (Transfer memory) {
        return transfers[transferId];
    }
    
    function canWithdrawForInvestment(uint256 amount) external view returns (bool) {
        return amount <= getAvailableBalance() && !emergencyMode;
    }

    function getProtocolFundsFromReserve() external view returns (uint256) {
        return protocolFundsFromReserve;
    }

    function getProtocolFundsDirectDeposit() external view returns (uint256) {
        return protocolFundsDirectDeposit;
    }

    function getExpectedBalance() external view returns (uint256) {
        return totalDeposits + totalLocked + protocolFundsFromReserve + protocolFundsDirectDeposit + totalCouponPool;
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
    
    receive() external payable {
        revert("PoolEscrow/eth-not-supported");
    }
} 
