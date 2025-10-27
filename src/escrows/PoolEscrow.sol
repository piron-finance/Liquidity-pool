// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/IPoolEscrow.sol";
/**
 * @title PoolEscrow
 * @dev Escrow contract for pool fund management
 * @notice This contract holds funds securely and releases them based on Manager instructions
 */
contract PoolEscrow is Initializable, UUPSUpgradeable, IPoolEscrow, ReentrancyGuardUpgradeable, AccessControlUpgradeable {
    using SafeERC20 for IERC20;
    
    IERC20 public asset;
    address public manager;
    address public override pool;
    address public override spvAddress;

    
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    // Fund tracking
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
    
    // Multisig transfer tracking (future consideration)
    mapping(bytes32 => Transfer) private transfers;
    mapping(bytes32 => mapping(address => bool)) private transferApprovals;
    mapping(bytes32 => uint256) private transferCreationTime;
    
    uint256 public constant LARGE_TRANSFER_THRESHOLD = 100000e6; 
    
    bool public emergencyMode = false;
    uint256 public emergencyModeActivated;
    
    event Deposit(address indexed user, uint256 amount, uint256 timestamp);
    event FundsReleased(address indexed recipient, uint256 amount, bytes32 indexed transferId);
    event FundsLocked(uint256 amount, string reason);
    event LargeTransferDetected(bytes32 indexed transferId, uint256 amount, uint256 threshold);
    
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
    
    /**
     * @notice Initialize the PoolEscrow contract
     * @param _asset The ERC20 token to be held in escrow
     * @param _manager The manager contract address
     * @param _spvAddress The SPV address for this pool
     */
    function initialize(
        address _asset,
        address _manager,
        address _spvAddress,
        address /* _timelock */
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
    
    /**
     * @notice Disable upgrades for live escrows
     * @dev Escrows should never be upgraded once deployed with user funds
     */
    function _authorizeUpgrade(address) internal pure override {
        revert("Escrow upgrades disabled for security");
    }

     function setPool(address _pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_pool != address(0), "PoolEscrow/invalid-pool");
        require(pool == address(0), "PoolEscrow/pool-already-set"); 
        pool = _pool;
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// DEPOSIT FUNCTIONS ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function receiveDeposit(address user, uint256 amount) external onlyManager {
        require(user != address(0), "PoolEscrow/invalid-user");
        require(amount > 0, "PoolEscrow/invalid-amount");
        
        deposits[user] += amount;
        totalDeposits += amount;
        userDepositHistory[user] += amount;
        
        emit Deposit(user, amount, block.timestamp);
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// FUND MANAGEMENT //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
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
            confirmations: 1, // Single confirmation from manager
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
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// COUPON PAYMENT SYSTEM ////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function trackCouponPayment(uint256 amount) external onlyManager {
        require(amount > 0, "PoolEscrow/invalid-amount");
        
        totalCouponPaymentsReceived += amount;
        totalCouponPool += amount;
        
        emit FundsReleased(address(this), amount, bytes32(uint256(0xcafe)));
    }
    
    function trackMaturityReturn(uint256 amount) external onlyManager {
        require(amount > 0, "PoolEscrow/invalid-amount");
        
        totalMaturityReturns += amount;
        
        emit FundsReleased(address(this), amount, bytes32(uint256(0xfeed)));
    }
    
    function claimCoupon(address user, uint256 amount) external onlyManager nonReentrant {
        require(user != address(0), "PoolEscrow/invalid-user");
        require(amount > 0, "PoolEscrow/invalid-amount");
        require(amount <= getAvailableBalance(), "PoolEscrow/insufficient-balance");
        
        totalCouponsClaimed += amount;
        userCouponHistory[user] += amount;
        
        asset.safeTransfer(user, amount);
        
        emit FundsReleased(user, amount, bytes32(uint256(0xc0ff)));
    }
    

    

    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// VIEW FUNCTIONS ///////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
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
    
   
    
    receive() external payable {
        revert("PoolEscrow/eth-not-supported");
    }
} 