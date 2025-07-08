// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IPoolEscrow.sol";

/**
 * @title PoolEscrow
 * @dev Escrow contract for pool fund management
 * @notice This contract holds funds securely and releases them based on Manager instructions
 */
contract PoolEscrow is IPoolEscrow, ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;
    
    IERC20 public immutable asset;
    address public immutable override manager;
    address public immutable override pool;
    address public immutable override spvAddress;
    
    uint256 public override requiredConfirmations;
    uint256 public override signerCount;
    
    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");
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
    
    modifier onlySignerOrManager() {
        require(
            hasRole(SIGNER_ROLE, msg.sender) || msg.sender == manager,
            "PoolEscrow/unauthorized"
        );
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
    
    /**
     * @dev Initialize escrow with multisig configuration
     * @param _asset The ERC20 token to be held in escrow
     * @param _manager The manager contract address
     * @param _spvAddress The SPV address for this pool
     * @param _signers Array of authorized signers
     * @param _requiredConfirmations Number of confirmations required for transfers
     */
    constructor(
        address _asset,
        address _manager,
        address _spvAddress,
        address[] memory _signers,
        uint256 _requiredConfirmations
    ) {
        require(_asset != address(0), "PoolEscrow/invalid-asset");
        require(_manager != address(0), "PoolEscrow/invalid-manager");
        require(_spvAddress != address(0), "PoolEscrow/invalid-spv");
        require(_signers.length >= 2, "PoolEscrow/insufficient-signers");
        require(_requiredConfirmations >= 2, "PoolEscrow/insufficient-confirmations");
        require(_requiredConfirmations <= _signers.length, "PoolEscrow/too-many-confirmations");
        
        asset = IERC20(_asset);
        manager = _manager;
        pool = msg.sender;
        spvAddress = _spvAddress;
        requiredConfirmations = _requiredConfirmations;
        signerCount = _signers.length;
        
        _grantRole(DEFAULT_ADMIN_ROLE, _manager);
        _grantRole(EMERGENCY_ROLE, _manager);
        
        for (uint256 i = 0; i < _signers.length; i++) {
            require(_signers[i] != address(0), "PoolEscrow/invalid-signer");
            _grantRole(SIGNER_ROLE, _signers[i]);
        }
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
            confirmations: requiredConfirmations, 
            executed: true, 
            timestamp: block.timestamp
        });
        
        asset.safeTransfer(spvAddress, amount);
        
        if (amount > LARGE_TRANSFER_THRESHOLD) {
            emit LargeTransferDetected(transferId, amount, LARGE_TRANSFER_THRESHOLD);
        }
        
        emit TransferProposed(transferId, TransferType.TO_SPV, spvAddress, amount, msg.sender);
        emit TransferExecuted(transferId, spvAddress, amount);
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
    /////////////////////////////// MULTISIG WORKFLOW ///////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    // future consideration. in the future we want multiple signers for transactions
    function proposeTransfer(
        TransferType transferType,
        address recipient,
        uint256 amount,
        bytes memory data
    ) external override onlySignerOrManager notInEmergencyMode returns (bytes32 transferId) {
        require(recipient != address(0), "PoolEscrow/invalid-recipient");
        require(amount > 0, "PoolEscrow/invalid-amount");
        require(amount <= getAvailableBalance(), "PoolEscrow/insufficient-balance");
        
        transferId = keccak256(abi.encodePacked(
            transferType,
            recipient,
            amount,
            data,
            block.timestamp,
            msg.sender
        ));
        require(transfers[transferId].amount == 0, "PoolEscrow/transfer-exists");
        
        transfers[transferId] = Transfer({
            transferType: transferType,
            recipient: recipient,
            amount: amount,
            data: data,
            confirmations: 0,
            executed: false,
            timestamp: block.timestamp
        });
        
        transferCreationTime[transferId] = block.timestamp;
        
        if (amount > LARGE_TRANSFER_THRESHOLD) {
            emit LargeTransferDetected(transferId, amount, LARGE_TRANSFER_THRESHOLD);
        }
        
        emit TransferProposed(transferId, transferType, recipient, amount, msg.sender);
        
        return transferId;
    }
    
    function approveTransfer(bytes32 transferId) external override onlyRole(SIGNER_ROLE) validTransfer(transferId) {
        require(!transfers[transferId].executed, "PoolEscrow/already-executed");
        require(!transferApprovals[transferId][msg.sender], "PoolEscrow/already-approved");
        
        transferApprovals[transferId][msg.sender] = true;
        transfers[transferId].confirmations += 1;
        
        emit TransferApproved(transferId, msg.sender, transfers[transferId].confirmations);
    }
    
    function executeTransfer(bytes32 transferId) external override onlySignerOrManager validTransfer(transferId) nonReentrant {
        Transfer storage transfer = transfers[transferId];
        
        require(!transfer.executed, "PoolEscrow/already-executed");
        require(transfer.confirmations >= requiredConfirmations, "PoolEscrow/insufficient-confirmations");
        
        transfer.executed = true;
        
        asset.safeTransfer(transfer.recipient, transfer.amount);
        
        emit TransferExecuted(transferId, transfer.recipient, transfer.amount);
        emit FundsReleased(transfer.recipient, transfer.amount, transferId);
    }
    
    function revokeTransfer(bytes32 transferId) external override onlyRole(SIGNER_ROLE) validTransfer(transferId) {
        require(!transfers[transferId].executed, "PoolEscrow/already-executed");
        require(transfers[transferId].confirmations < requiredConfirmations, "PoolEscrow/cannot-revoke-approved");
        
        transfers[transferId].executed = true;
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// SIGNER MANAGEMENT ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function addSigner(address signer) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(signer != address(0), "PoolEscrow/invalid-signer");
        require(!hasRole(SIGNER_ROLE, signer), "PoolEscrow/already-signer");
        
        _grantRole(SIGNER_ROLE, signer);
        signerCount += 1;
        
        emit SignerAdded(signer);
    }
    
    function removeSigner(address signer) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(hasRole(SIGNER_ROLE, signer), "PoolEscrow/not-signer");
        require(signerCount > requiredConfirmations, "PoolEscrow/would-break-multisig");
        
        _revokeRole(SIGNER_ROLE, signer);
        signerCount -= 1;
        
        emit SignerRemoved(signer);
    }
    
    function changeRequiredConfirmations(uint256 newRequired) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRequired >= 2, "PoolEscrow/insufficient-confirmations");
        require(newRequired <= signerCount, "PoolEscrow/too-many-confirmations");
        
        uint256 oldRequired = requiredConfirmations;
        requiredConfirmations = newRequired;
        
        emit RequiredConfirmationsChanged(oldRequired, newRequired);
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
    
    function isSigner(address account) external view override returns (bool) {
        return hasRole(SIGNER_ROLE, account);
    }
    
    function getTransfer(bytes32 transferId) external view override returns (Transfer memory) {
        return transfers[transferId];
    }
    
    function isTransferApproved(bytes32 transferId, address signer) external view override returns (bool) {
        return transferApprovals[transferId][signer];
    }
    
    function canWithdrawForInvestment(uint256 amount) external view returns (bool) {
        return amount <= getAvailableBalance() && !emergencyMode;
    }
    
   
    
    receive() external payable {
        revert("PoolEscrow/eth-not-supported");
    }
} 