// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract AccessManager is AccessControl, Pausable {

    bytes32 public constant SPV_ROLE = keccak256("SPV_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");
    bytes32 public constant POOL_CREATOR_ROLE = keccak256("POOL_CREATOR_ROLE");
    bytes32 public constant MULTISIG_ADMIN_ROLE = keccak256("MULTISIG_ADMIN_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant ASSET_MANAGER_ROLE = keccak256("ASSET_MANAGER_ROLE");
    
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
    
    uint256 public constant ROLE_DELAY = 24 hours;
    
    event EmergencyPause(address indexed pauser, uint256 timestamp);
    event EmergencyUnpause(address indexed unpauser, uint256 timestamp);
    event RoleProposed(bytes32 indexed proposalId, bytes32 indexed role, address indexed account, uint256 timestamp);
    event RoleProposalExecuted(bytes32 indexed proposalId, bytes32 indexed role, address indexed account);
    event RoleProposalCancelled(bytes32 indexed proposalId);
    
    modifier onlyRoleWithDelay(bytes32 role) {
        require(hasRole(role, msg.sender), "AccessManager: access denied");
        require(
            roleGrantTime[msg.sender] == 0 || roleGrantTime[msg.sender] + ROLE_DELAY <= block.timestamp, 
            "AccessManager: role delay not met" 
        );
        _;
    }
    
    bool public deploymentComplete;
    
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
        require(emergency != address(0), "AccessManager: invalid emergency");
        require(multisigAdmin != address(0), "AccessManager: invalid multisig admin");
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, admin);
        _grantRole(POOL_CREATOR_ROLE, admin);
        _grantRole(MULTISIG_ADMIN_ROLE, admin);
        _grantRole(ASSET_MANAGER_ROLE, admin);
        
        // Grant SPV_ROLE only to SPV address (not admin)
        _grantRole(SPV_ROLE, spv);
        
        if (operator != admin) _grantRole(OPERATOR_ROLE, operator);
        if (emergency != admin) _grantRole(EMERGENCY_ROLE, emergency);
        if (multisigAdmin != admin) _grantRole(MULTISIG_ADMIN_ROLE, multisigAdmin);
        
        roleGrantTime[admin] = 0;
        roleGrantTime[spv] = 0;
        if (operator != admin) roleGrantTime[operator] = 0;
        if (emergency != admin) roleGrantTime[emergency] = 0;
        if (multisigAdmin != admin) roleGrantTime[multisigAdmin] = 0;
        
        emergencyPausers[admin] = true; // Admin has emergency role
        if (emergency != admin) emergencyPausers[emergency] = true;
        
        deploymentComplete = false;
    }
    
    /**
     * @notice Grant FACTORY_ROLE to factory contracts during initial deployment
     * @dev Can only be called once by admin, immediately after deployment
     * @param factory Address of the factory contract
     */
    function grantFactoryRoleDuringDeployment(address factory) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!deploymentComplete, "AccessManager: deployment already complete");
        require(factory != address(0), "AccessManager: invalid factory");
        _grantRole(FACTORY_ROLE, factory);
        roleGrantTime[factory] = 0;
    }
    
    /**
     * @notice Grant any role during initial deployment (bypass timelock)
     * @dev Can only be called by admin before deployment is finalized
     * @param role Role to grant
     * @param account Address to receive the role
     */
    function grantRoleDuringDeployment(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!deploymentComplete, "AccessManager: deployment already complete");
        require(account != address(0), "AccessManager: invalid account");
        _grantRole(role, account);
        roleGrantTime[account] = 0;
    }
    
    /**
     * @notice Mark deployment as complete, preventing further immediate role grants
     * @dev Can only be called once by admin
     */
    function finalizeDeployment() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!deploymentComplete, "AccessManager: already finalized");
        deploymentComplete = true;
    }
    
    function grantRole(bytes32, address) public virtual override {
        revert("AccessManager: use proposeRoleGrant for all role grants");
    }
    
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
    
    function cancelRoleProposal(bytes32 proposalId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RoleProposal storage proposal = roleProposals[proposalId];
        
        require(proposal.proposedAt != 0, "AccessManager: proposal does not exist");
        require(!proposal.executed, "AccessManager: proposal already executed");
        require(!proposal.cancelled, "AccessManager: proposal already cancelled");
        
        proposal.cancelled = true;
        emit RoleProposalCancelled(proposalId);
    }
    
    function revokeRole(bytes32 role, address account) public virtual override {
        super.revokeRole(role, account);
        delete roleGrantTime[account];
        emergencyPausers[account] = false;
    }
    
    function renounceRole(bytes32 role, address account) public virtual override {
        super.renounceRole(role, account);
        delete roleGrantTime[account];
        emergencyPausers[account] = false;
    }
    
    
    function emergencyPause() external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || hasRole(EMERGENCY_ROLE, msg.sender), "AccessManager: not authorized");
        _pause();
        emit EmergencyPause(msg.sender, block.timestamp);
    }
    
    function emergencyUnpause() external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || hasRole(EMERGENCY_ROLE, msg.sender), "AccessManager: not authorized");
        _unpause();
        emit EmergencyUnpause(msg.sender, block.timestamp);
    }
    
    function addEmergencyPauser(address pauser) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(pauser != address(0), "AccessManager: invalid pauser");
        emergencyPausers[pauser] = true;
    }
    
    function removeEmergencyPauser(address pauser) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emergencyPausers[pauser] = false;
    }
    
    
    // Convenience functions for checking protocol-specific roles
    function isAdmin(address account) external view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, account);
    }
    
    function isSPV(address account) external view returns (bool) {
        return hasRole(SPV_ROLE, account);
    }
    
    function isOperator(address account) external view returns (bool) {
        return hasRole(OPERATOR_ROLE, account);
    }
    
    function isOracle(address account) external view returns (bool) {
        return hasRole(ORACLE_ROLE, account);
    }
    
    function isVerifier(address account) external view returns (bool) {
        return hasRole(VERIFIER_ROLE, account);
    }
    
    function isPoolCreator(address account) external view returns (bool) {
        return hasRole(POOL_CREATOR_ROLE, account);
    }
    
    function canActWithDelay(bytes32 role, address account) external view returns (bool) {
        return hasRole(role, account) && 
               (roleGrantTime[account] == 0 || roleGrantTime[account] + ROLE_DELAY <= block.timestamp);
    }
    
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