// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../PoolRegistry.sol";

abstract contract AccessControl {
    mapping(bytes32 => mapping(address => bool)) private _roles;
    
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    
    modifier onlyRole(bytes32 role) {
        require(hasRole(role, msg.sender), "AccessControl: access denied");
        _;
    }
    
    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role][account];
    }
    
    function _grantRole(bytes32 role, address account) internal {
        if (!hasRole(role, account)) {
            _roles[role][account] = true;
        }
    }
}

contract RegistryFactory is AccessControl {
    bytes32 public constant REGISTRY_ADMIN_ROLE = keccak256("REGISTRY_ADMIN_ROLE");
    
    mapping(string => address) public namedRegistries;
    mapping(address => bool) public validRegistries;
    address[] public allRegistries;
    
    event RegistryCreated(
        address indexed registry,
        string name,
        address indexed admin,
        address indexed factory
    );
    
    constructor(address _admin) {
        require(_admin != address(0), "Invalid admin");
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(REGISTRY_ADMIN_ROLE, _admin);
    }
    
    function createRegistry(
        string memory name,
        address admin,
        address factory
    ) external onlyRole(REGISTRY_ADMIN_ROLE) returns (address registry) {
        require(bytes(name).length > 0, "Registry name required");
        require(admin != address(0), "Invalid admin");
        require(factory != address(0), "Invalid factory");
        require(namedRegistries[name] == address(0), "Registry name already exists");
        
        registry = address(new PoolRegistry(factory, admin));
        
        namedRegistries[name] = registry;
        validRegistries[registry] = true;
        allRegistries.push(registry);
        
        emit RegistryCreated(registry, name, admin, factory);
        
        return registry;
    }
    
    function getRegistryByName(string memory name) external view returns (address) {
        return namedRegistries[name];
    }
    
    function isValidRegistry(address registry) external view returns (bool) {
        return validRegistries[registry];
    }
    
    function getAllRegistries() external view returns (address[] memory) {
        return allRegistries;
    }
    
    function getRegistryCount() external view returns (uint256) {
        return allRegistries.length;
    }
    
    function deactivateRegistry(string memory name) external onlyRole(REGISTRY_ADMIN_ROLE) {
        address registry = namedRegistries[name];
        require(registry != address(0), "Registry not found");
        
        validRegistries[registry] = false;
        delete namedRegistries[name];
    }
} 