// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IAccessControl {
    event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRenounced(bytes32 indexed role, address indexed account);
    
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function SPV_ROLE() external view returns (bytes32);
    function OPERATOR_ROLE() external view returns (bytes32);
    function EMERGENCY_ROLE() external view returns (bytes32);
    function ORACLE_ROLE() external view returns (bytes32);
    function VERIFIER_ROLE() external view returns (bytes32);
    function FACTORY_ROLE() external view returns (bytes32);
    
    function hasRole(bytes32 role, address account) external view returns (bool);
    function getRoleAdmin(bytes32 role) external view returns (bytes32);
    function getRoleMemberCount(bytes32 role) external view returns (uint256);
    function getRoleMember(bytes32 role, uint256 index) external view returns (address);
    
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function renounceRole(bytes32 role, address account) external;
    function setRoleAdmin(bytes32 role, bytes32 adminRole) external;
    
    function setupRole(bytes32 role, address account) external;
    function setupInitialRoles(
        address admin,
        address spv,
        address operator,
        address emergency
    ) external;
} 