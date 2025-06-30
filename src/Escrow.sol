// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import "./interfaces/IPoolEscrow.sol";

contract Escrow is IPoolEscrow {
    address public override pool;
    address public override manager;
    address public override spvAddress;
    uint256 public override requiredConfirmations;
    uint256 public override signerCount;
    
    mapping(address => bool) public signers;
    mapping(bytes32 => Transfer) public transfers;
    mapping(bytes32 => mapping(address => bool)) public transferApprovals;
    
    // Additional events not in interface
    event TransferRevoked(bytes32 indexed transferId, address indexed revoker);
    event FundsReleased(address indexed recipient, uint256 amount);
    event FundsLocked(uint256 amount);
    event FundsReceived(address indexed sender, uint256 amount);
    
    constructor(
        address _pool,
        address _manager,
        address _spvAddress,
        address[] memory _signers,
        uint256 _requiredConfirmations
    ) {
        pool = _pool;
        manager = _manager;
        spvAddress = _spvAddress;
        requiredConfirmations = _requiredConfirmations;
        signerCount = _signers.length;
        
        for (uint256 i = 0; i < _signers.length; i++) {
            signers[_signers[i]] = true;
        }
    }
    
    function isSigner(address account) external view override returns (bool) {
        return signers[account];
    }
    
    function getTransfer(bytes32 transferId) external view override returns (Transfer memory) {
        return transfers[transferId];
    }
    
    function isTransferApproved(bytes32 transferId, address signer) external view override returns (bool) {
        return transferApprovals[transferId][signer];
    }
    
    function proposeTransfer(
        TransferType transferType,
        address recipient,
        uint256 amount,
        bytes memory data
    ) external override returns (bytes32 transferId) {
        require(signers[msg.sender], "Escrow/not-authorized");
        require(recipient != address(0), "Escrow/invalid-recipient");
        require(amount > 0, "Escrow/invalid-amount");
        require(amount <= address(this).balance, "Escrow/insufficient-balance");
        
        transferId = keccak256(abi.encodePacked(
            transferType,
            recipient,
            amount,
            data,
            block.timestamp,
            msg.sender
        ));
        
        require(transfers[transferId].amount == 0, "Escrow/transfer-exists");
        
        transfers[transferId] = Transfer({
            transferType: transferType,
            recipient: recipient,
            amount: amount,
            data: data,
            confirmations: 1,
            executed: false,
            timestamp: block.timestamp
        });
        
        transferApprovals[transferId][msg.sender] = true;
        
        emit TransferProposed(transferId, transferType, recipient, amount, msg.sender);
        
        return transferId;
    }
    
    function approveTransfer(bytes32 transferId) external override {
        require(signers[msg.sender], "Escrow/not-authorized");
        require(transfers[transferId].amount > 0, "Escrow/transfer-not-found");
        require(!transfers[transferId].executed, "Escrow/already-executed");
        require(!transferApprovals[transferId][msg.sender], "Escrow/already-approved");
        
        transferApprovals[transferId][msg.sender] = true;
        transfers[transferId].confirmations++;
        
        emit TransferApproved(transferId, msg.sender, transfers[transferId].confirmations);
        
        // Auto-execute if enough approvals
        if (transfers[transferId].confirmations >= requiredConfirmations) {
            _executeTransfer(transferId);
        }
    }
    
    function executeTransfer(bytes32 transferId) external override {
        require(transfers[transferId].confirmations >= requiredConfirmations, "Escrow/insufficient-approvals");
        _executeTransfer(transferId);
    }
    
    function revokeTransfer(bytes32 transferId) external override {
        require(signers[msg.sender], "Escrow/not-authorized");
        require(transfers[transferId].amount > 0, "Escrow/transfer-not-found");
        require(!transfers[transferId].executed, "Escrow/already-executed");
        
        // Mark as executed to prevent execution (we don't have a revoked field in interface)
        transfers[transferId].executed = true;
        
        emit TransferRevoked(transferId, msg.sender);
    }
    
    function addSigner(address signer) external override {
        require(msg.sender == manager, "Escrow/only-manager");
        require(signer != address(0), "Escrow/invalid-signer");
        require(!signers[signer], "Escrow/already-signer");
        
        signers[signer] = true;
        signerCount++;
        
        emit SignerAdded(signer);
    }
    
    function removeSigner(address signer) external override {
        require(msg.sender == manager, "Escrow/only-manager");
        require(signers[signer], "Escrow/not-signer");
        require(signerCount > requiredConfirmations, "Escrow/too-few-signers");
        
        signers[signer] = false;
        signerCount--;
        
        emit SignerRemoved(signer);
    }
    
    function changeRequiredConfirmations(uint256 newRequired) external override {
        require(msg.sender == manager, "Escrow/only-manager");
        require(newRequired > 0, "Escrow/invalid-required");
        require(newRequired <= signerCount, "Escrow/exceeds-signer-count");
        
        uint256 oldRequired = requiredConfirmations;
        requiredConfirmations = newRequired;
        
        emit RequiredConfirmationsChanged(oldRequired, newRequired);
    }
    
    function releaseFunds(address recipient, uint256 amount) external override {
        require(msg.sender == manager, "Escrow/only-manager");
        require(recipient != address(0), "Escrow/invalid-recipient");
        require(amount > 0, "Escrow/invalid-amount");
        require(amount <= address(this).balance, "Escrow/insufficient-balance");
        
        payable(recipient).transfer(amount);
        
        emit FundsReleased(recipient, amount);
    }
    
    function lockFunds(uint256 amount) external override {
        require(msg.sender == manager, "Escrow/only-manager");
        require(amount > 0, "Escrow/invalid-amount");
        require(amount <= address(this).balance, "Escrow/insufficient-balance");
        
        emit FundsLocked(amount);
    }
    
    function getBalance() external view override returns (uint256) {
        return address(this).balance;
    }
    
    function _executeTransfer(bytes32 transferId) internal {
        Transfer storage transfer = transfers[transferId];
        require(!transfer.executed, "Escrow/already-executed");
        
        transfer.executed = true;
        
        if (transfer.transferType == TransferType.TO_SPV) {
            // Transfer to SPV for investment
            payable(spvAddress).transfer(transfer.amount);
        } else if (transfer.transferType == TransferType.FROM_SPV) {
            // Transfer from SPV (maturity/coupon)
            payable(pool).transfer(transfer.amount);
        } else if (transfer.transferType == TransferType.REFUND_USERS) {
            // Transfer refund to user
            payable(transfer.recipient).transfer(transfer.amount);
        } else if (transfer.transferType == TransferType.COUPON_PAYMENT) {
            // Transfer coupon payment to pool
            payable(pool).transfer(transfer.amount);
        } else if (transfer.transferType == TransferType.DISCOUNT_RELEASE) {
            // Transfer discount earnings to pool
            payable(pool).transfer(transfer.amount);
        }
        
        emit TransferExecuted(transferId, transfer.recipient, transfer.amount);
    }
    
    // Allow contract to receive ETH
    receive() external payable {
        emit FundsReceived(msg.sender, msg.value);
    }
    
    // Fallback function
    fallback() external payable {
        emit FundsReceived(msg.sender, msg.value);
    }
}