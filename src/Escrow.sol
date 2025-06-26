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
        
    }
    
    function approveTransfer(bytes32 transferId) external override {
        
    }
    
    function executeTransfer(bytes32 transferId) external override {
        
    }
    
    function revokeTransfer(bytes32 transferId) external override {
        
    }
    
    function addSigner(address signer) external override {
        
    }
    
    function removeSigner(address signer) external override {
        
    }
    
    function changeRequiredConfirmations(uint256 newRequired) external override {
        
    }
    
    function releaseFunds(address recipient, uint256 amount) external override {
        
    }
    
    function lockFunds(uint256 amount) external override {
        
    }
    
    function getBalance() external view override returns (uint256) {
        return address(this).balance;
    }
}