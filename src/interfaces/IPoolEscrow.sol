// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IPoolEscrow {
    enum TransferType {
        TO_SPV,
        FROM_SPV,
        REFUND_USERS,
        COUPON_PAYMENT,
        DISCOUNT_RELEASE
    }
    
    struct Transfer {
        TransferType transferType;
        address recipient;
        uint256 amount;
        bytes data;
        uint256 confirmations;
        bool executed;
        uint256 timestamp;
    }
    
    event TransferProposed(
        bytes32 indexed transferId,
        TransferType transferType,
        address indexed recipient,
        uint256 amount,
        address proposer
    );
    
    event TransferApproved(
        bytes32 indexed transferId,
        address indexed approver,
        uint256 confirmations
    );
    
    event TransferExecuted(
        bytes32 indexed transferId,
        address indexed recipient,
        uint256 amount
    );
    
    event SignerAdded(address indexed signer);
    event SignerRemoved(address indexed signer);
    event RequiredConfirmationsChanged(uint256 oldRequired, uint256 newRequired);
    
    function pool() external view returns (address);
    function manager() external view returns (address);
    function spvAddress() external view returns (address);
    function requiredConfirmations() external view returns (uint256);
    function signerCount() external view returns (uint256);
    
    function isSigner(address account) external view returns (bool);
    function getTransfer(bytes32 transferId) external view returns (Transfer memory);
    function isTransferApproved(bytes32 transferId, address signer) external view returns (bool);
    
    function proposeTransfer(
        TransferType transferType,
        address recipient,
        uint256 amount,
        bytes memory data
    ) external returns (bytes32 transferId);
    
    function setPool(address pool) external;
    function approveTransfer(bytes32 transferId) external;
    function executeTransfer(bytes32 transferId) external;
    function revokeTransfer(bytes32 transferId) external;
    
    function addSigner(address signer) external;
    function removeSigner(address signer) external;
    function changeRequiredConfirmations(uint256 newRequired) external;
    
    function lockFunds(uint256 amount) external;
    function releaseFunds(address recipient, uint256 amount) external;
    function getBalance() external view returns (uint256);

    
    function receiveDeposit(address user, uint256 amount) external;

    function trackCouponPayment(uint256 amount) external;

    function trackMaturityReturn(uint256 amount) external;

    function claimCoupon(address user, uint256 amount) external;
    

    function withdrawForInvestment(uint256 amount) external returns (bytes32 transferId);
    function canWithdrawForInvestment(uint256 amount) external view returns (bool);
} 