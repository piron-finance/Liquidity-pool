// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract AccessManager is AccessControl, Pausable {
    // Custom role definitions for the protocol
    bytes32 public constant SPV_ROLE = keccak256("SPV_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");
    
    mapping(address => bool) public emergencyPausers;
    mapping(address => uint256) public roleGrantTime;
    
    uint256 public constant ROLE_DELAY = 24 hours;
    
    event EmergencyPause(address indexed pauser, uint256 timestamp);
    event EmergencyUnpause(address indexed unpauser, uint256 timestamp);
    
    modifier onlyRoleWithDelay(bytes32 role) {
        require(hasRole(role, msg.sender), "AccessManager: access denied");
        require(
            roleGrantTime[msg.sender] + ROLE_DELAY <= block.timestamp, 
            "AccessManager: role delay not met"
        );
        _;
    }
    
    constructor(address admin) {
        require(admin != address(0), "AccessManager: invalid admin");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        roleGrantTime[admin] = block.timestamp;
    }
    
    function setupInitialRoles(
        address admin,
        address spv,
        address operator,
        address emergency
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(admin != address(0), "AccessManager: invalid admin");
        require(spv != address(0), "AccessManager: invalid spv");
        require(operator != address(0), "AccessManager: invalid operator");
        require(emergency != address(0), "AccessManager: invalid emergency");
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SPV_ROLE, spv);
        _grantRole(OPERATOR_ROLE, operator);
        _grantRole(EMERGENCY_ROLE, emergency);
        
        roleGrantTime[admin] = block.timestamp;
        roleGrantTime[spv] = block.timestamp;
        roleGrantTime[operator] = block.timestamp;
        roleGrantTime[emergency] = block.timestamp;
        
        emergencyPausers[emergency] = true;
    }
    
    function setupRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(role, account);
        roleGrantTime[account] = block.timestamp;
    }
    
    function grantRole(bytes32 role, address account) public virtual override {
        super.grantRole(role, account);
        roleGrantTime[account] = block.timestamp;
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
    
    function setRoleAdmin(bytes32 role, bytes32 adminRole) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRoleAdmin(role, adminRole);
    }
    
    function emergencyPause() external {
        require(emergencyPausers[msg.sender] || hasRole(EMERGENCY_ROLE, msg.sender), "AccessManager: not authorized");
        _pause();
        emit EmergencyPause(msg.sender, block.timestamp);
    }
    
    function emergencyUnpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
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
    
    function canActWithDelay(bytes32 role, address account) external view returns (bool) {
        return hasRole(role, account) && 
               (roleGrantTime[account] + ROLE_DELAY <= block.timestamp);
    }
} 