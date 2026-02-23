// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title AccessManager
 * @dev Role-based access control with timelocked role grants and emergency pause.
 *      After deployment is finalized, all new role grants require a 24h proposal
 *      period followed by multisig execution. renounceRole is permanently disabled.
 */
contract AccessManager is AccessControl, Pausable {

    // ==================== STATE ====================

    bytes32 public constant SPV_ROLE = keccak256("SPV_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");
    bytes32 public constant POOL_CREATOR_ROLE = keccak256("POOL_CREATOR_ROLE");
    bytes32 public constant MULTISIG_ADMIN_ROLE = keccak256("MULTISIG_ADMIN_ROLE");

    uint256 public constant ROLE_DELAY = 24 hours;
    bool public deploymentComplete;

    struct RoleProposal {
        bytes32 role;
        address account;
        uint256 proposedAt;
        bool executed;
        bool cancelled;
    }
    
    mapping(address => bool) public emergencyPausers; 
    mapping(address => uint256) public roleGrantTime;
    mapping(bytes32 => RoleProposal) public roleProposals;

    // ==================== EVENTS ====================

    event EmergencyPause(address indexed pauser, uint256 timestamp);
    event EmergencyUnpause(address indexed unpauser, uint256 timestamp);
    event RoleProposed(bytes32 indexed proposalId, bytes32 indexed role, address indexed account, uint256 timestamp);
    event RoleProposalExecuted(bytes32 indexed proposalId, bytes32 indexed role, address indexed account);
    event RoleProposalCancelled(bytes32 indexed proposalId);

    // ==================== CONSTRUCTOR ====================

    /**
     * @dev Bootstraps roles for admin, spv, operator, emergency, and multisig.
     * @param admin Default admin address (receives DEFAULT_ADMIN_ROLE, OPERATOR_ROLE, POOL_CREATOR_ROLE)
     * @param spv SPV wallet (receives SPV_ROLE)
     * @param operator Operator wallet (receives OPERATOR_ROLE)
     * @param emergency Emergency wallet (receives EMERGENCY_ROLE, must differ from admin)
     * @param multisigAdmin Multisig wallet (receives MULTISIG_ADMIN_ROLE, must differ from admin)
     */
    constructor(
        address admin,
        address spv,
        address operator,
        address emergency,
        address multisigAdmin
    ) {
        require(admin != address(0), "AccessManager: invalid admin");
        require(spv != address(0), "AccessManager: invalid spv");
        require(operator != address(0), "AccessManager: invalid operator");
        require(emergency != address(0) && emergency != admin, "AccessManager: invalid emergency");
        require(multisigAdmin != address(0) && multisigAdmin != admin, "AccessManager: invalid multisig admin");
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, emergency);
        _grantRole(POOL_CREATOR_ROLE, admin);
        _grantRole(MULTISIG_ADMIN_ROLE, multisigAdmin);
        
        _grantRole(SPV_ROLE, spv);
        
        if (operator != admin) _grantRole(OPERATOR_ROLE, operator);
        
        roleGrantTime[admin] = 0;
        roleGrantTime[spv] = 0;
        roleGrantTime[emergency] = 0;
        roleGrantTime[multisigAdmin] = 0;

        if (operator != admin) roleGrantTime[operator] = 0;
        
        emergencyPausers[admin] = true; 
        emergencyPausers[emergency] = true;
        
        deploymentComplete = false;
    }

    // ==================== DEPLOYMENT SETUP ====================

    /**
     * @dev Grant FACTORY_ROLE to a factory contract before deployment is finalized.
     * @param factory Address of the factory contract
     */
    function grantFactoryRoleDuringDeployment(address factory) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!deploymentComplete, "AccessManager: deployment already complete");
        require(factory != address(0), "AccessManager: invalid factory");
        _grantRole(FACTORY_ROLE, factory);
        roleGrantTime[factory] = 0;
    }
    
    /**
     * @dev Grant any role before deployment is finalized (bypasses timelock).
     * @param role Role identifier to grant
     * @param account Recipient address
     */
    function grantRoleDuringDeployment(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!deploymentComplete, "AccessManager: deployment already complete");
        require(account != address(0), "AccessManager: invalid account");
        _grantRole(role, account);
        roleGrantTime[account] = 0;
    }
    
    /**
     * @dev Permanently locks immediate role grants. All future grants go through proposeRoleGrant.
     */
    function finalizeDeployment() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!deploymentComplete, "AccessManager: already finalized");
        deploymentComplete = true;
    }

    // ==================== ROLE MANAGEMENT ====================

    /**
     * @dev Overridden to block direct grantRole calls. Use proposeRoleGrant instead.
     */
    function grantRole(bytes32, address) public virtual override {
        revert("AccessManager: use proposeRoleGrant for all role grants");
    }
    
    /**
     * @dev Propose a new role grant. Must wait ROLE_DELAY before execution by multisig.
     * @param role Role to grant
     * @param account Recipient address
     * @return proposalId Unique identifier for the proposal
     */
    function proposeRoleGrant(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) returns (bytes32 proposalId) {
        require(account != address(0), "AccessManager: invalid account");
        require(!hasRole(role, account), "AccessManager: account already has role");
        
        proposalId = keccak256(abi.encodePacked(role, account, block.timestamp, block.number));
        require(roleProposals[proposalId].proposedAt == 0, "AccessManager: proposal already exists");
        
        roleProposals[proposalId] = RoleProposal({
            role: role,
            account: account,
            proposedAt: block.timestamp,
            executed: false,
            cancelled: false
        });
        
        emit RoleProposed(proposalId, role, account, block.timestamp);
        return proposalId;
    }
    
    /**
     * @dev Execute a pending role proposal after the delay period. Requires MULTISIG_ADMIN_ROLE.
     * @param proposalId The proposal to execute
     */
    function executeRoleGrant(bytes32 proposalId) external onlyRole(MULTISIG_ADMIN_ROLE) {
        RoleProposal storage proposal = roleProposals[proposalId];
        
        require(proposal.proposedAt != 0, "AccessManager: proposal does not exist");
        require(!proposal.executed, "AccessManager: proposal already executed");
        require(!proposal.cancelled, "AccessManager: proposal cancelled");
        require(proposal.proposedAt + ROLE_DELAY <= block.timestamp, "AccessManager: delay period not met");
        
        proposal.executed = true;
        super.grantRole(proposal.role, proposal.account);
        roleGrantTime[proposal.account] = block.timestamp;
        
        emit RoleProposalExecuted(proposalId, proposal.role, proposal.account);
    }
    
    /**
     * @dev Cancel a pending role proposal.
     * @param proposalId The proposal to cancel
     */
    function cancelRoleProposal(bytes32 proposalId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RoleProposal storage proposal = roleProposals[proposalId];
        
        require(proposal.proposedAt != 0, "AccessManager: proposal does not exist");
        require(!proposal.executed, "AccessManager: proposal already executed");
        require(!proposal.cancelled, "AccessManager: proposal already cancelled");
        
        proposal.cancelled = true;
        emit RoleProposalCancelled(proposalId);
    }
    
    /**
     * @dev Revoke a role. Only callable by MULTISIG_ADMIN_ROLE.
     * @param role Role to revoke
     * @param account Address to revoke from
     */
    function revokeRole(bytes32 role, address account) public virtual onlyRole(MULTISIG_ADMIN_ROLE) override {
        super.revokeRole(role, account);
        delete roleGrantTime[account];

        if (role == EMERGENCY_ROLE) {
        emergencyPausers[account] = false;
         }

    }
    
    /**
     * @dev Permanently disabled to prevent accidental role loss.
     */
    function renounceRole(bytes32, address) public virtual override {
        revert("AccessManager: renouncing roles is disabled");
    }

    // ==================== EMERGENCY ====================

    /**
     * @dev Pause the protocol. Callable by admin or emergency role.
     */
    function emergencyPause() external { 
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || hasRole(EMERGENCY_ROLE, msg.sender), "AccessManager: not authorized");
        _pause();
        emit EmergencyPause(msg.sender, block.timestamp);
    }
    
    /**
     * @dev Unpause the protocol. Only callable by admin (not emergency).
     */
    function emergencyUnpause() external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "AccessManager: only admin can unpause");
        _unpause();
        emit EmergencyUnpause(msg.sender, block.timestamp);
    }

    // ==================== VIEW ====================

    function isAdmin(address account) external view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, account);
    }
    
    function isSPV(address account) external view returns (bool) {
        return hasRole(SPV_ROLE, account);
    }
    
    function isOperator(address account) external view returns (bool) {
        return hasRole(OPERATOR_ROLE, account);
    }
    
    function isPoolCreator(address account) external view returns (bool) {
        return hasRole(POOL_CREATOR_ROLE, account);
    }
    
    /**
     * @dev Returns full proposal details including whether it can be executed now.
     * @param proposalId The proposal to query
     */
    function getProposal(bytes32 proposalId) external view returns (
        bytes32 role,
        address account,
        uint256 proposedAt,
        bool executed,
        bool cancelled,
        bool canExecute
    ) {
        RoleProposal storage proposal = roleProposals[proposalId];
        canExecute = proposal.proposedAt != 0 && 
                    !proposal.executed && 
                    !proposal.cancelled &&
                    proposal.proposedAt + ROLE_DELAY <= block.timestamp;
        
        return (
            proposal.role,
            proposal.account,
            proposal.proposedAt,
            proposal.executed,
            proposal.cancelled,
            canExecute
        );
    }
    
    function isMultisigAdmin(address account) external view returns (bool) {
        return hasRole(MULTISIG_ADMIN_ROLE, account);
    }
} 
