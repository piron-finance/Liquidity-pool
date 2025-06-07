// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IPoolRegistry.sol";

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
    
    address public immutable registryImplementation;
    
    mapping(string => address) public namedRegistries;
    mapping(address => bool) public validRegistries;
    address[] public allRegistries;
    
    event RegistryCreated(
        address indexed registry,
        string name,
        address indexed admin,
        address indexed factory
    );
    
    constructor(address _registryImplementation, address _admin) {
        require(_registryImplementation != address(0), "Invalid registry implementation");
        require(_admin != address(0), "Invalid admin");
        
        registryImplementation = _registryImplementation;
        
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
        
        bytes memory bytecode = abi.encodePacked(
            type(PoolRegistry).creationCode,
            abi.encode(factory, admin)
        );
        
        bytes32 salt = keccak256(abi.encodePacked(name, admin, factory, block.timestamp));
        
        assembly {
            registry := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        
        require(registry != address(0), "Registry creation failed");
        
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

contract PoolRegistry is IPoolRegistry {
    address public override factory;
    
    uint256 public override totalPools;
    uint256 public override activePools;
    
    mapping(address => PoolInfo) private poolInfos;
    mapping(address => bool) private registeredPools;
    
    address[] private poolList;
    mapping(address => address[]) private poolsByAsset;
    mapping(string => address[]) private poolsByType;
    mapping(address => address[]) private poolsByCreator;
    
    address public admin;
    
    modifier onlyFactory() {
        require(msg.sender == factory, "Only factory can call");
        _;
    }
    
    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call");
        _;
    }
    
    constructor(address _factory, address _admin) {
        require(_factory != address(0), "Invalid factory");
        require(_admin != address(0), "Invalid admin");
        
        factory = _factory;
        admin = _admin;
    }
    
    function getPoolInfo(address pool) external view override returns (PoolInfo memory) {
        return poolInfos[pool];
    }
    
    function isRegisteredPool(address pool) external view override returns (bool) {
        return registeredPools[pool];
    }
    
    function isActivePool(address pool) external view override returns (bool) {
        return registeredPools[pool] && poolInfos[pool].isActive;
    }
    
    function registerPool(address pool, PoolInfo memory info) external override onlyFactory {
        require(pool != address(0), "Invalid pool");
        require(!registeredPools[pool], "Pool already registered");
        
        poolInfos[pool] = info;
        registeredPools[pool] = true;
        
        poolList.push(pool);
        poolsByAsset[info.asset].push(pool);
        poolsByType[info.instrumentType].push(pool);
        poolsByCreator[info.creator].push(pool);
        
        totalPools++;
        if (info.isActive) {
            activePools++;
        }
        
        emit PoolRegistered(pool, info.manager, info.asset, info.instrumentType, info.creator);
    }
    
    function updatePoolStatus(address pool, bool isActive) external override onlyAdmin {
        require(registeredPools[pool], "Pool not registered");
        
        bool wasActive = poolInfos[pool].isActive;
        poolInfos[pool].isActive = isActive;
        
        if (wasActive && !isActive) {
            activePools--;
        } else if (!wasActive && isActive) {
            activePools++;
        }
        
        emit PoolStatusUpdated(pool, isActive);
    }
    
    function updatePoolCategory(address pool, string memory newCategory) external override onlyAdmin {
        require(registeredPools[pool], "Pool not registered");
        
        string memory oldCategory = poolInfos[pool].instrumentType;
        poolInfos[pool].instrumentType = newCategory;
        
        emit PoolCategoryUpdated(pool, oldCategory, newCategory);
    }
    
    function getActivePools() external view override returns (address[] memory) {
        address[] memory active = new address[](activePools);
        uint256 index = 0;
        
        for (uint256 i = 0; i < poolList.length; i++) {
            if (poolInfos[poolList[i]].isActive) {
                active[index] = poolList[i];
                index++;
            }
        }
        
        return active;
    }
    
    function getAllPools() external view override returns (address[] memory) {
        return poolList;
    }
    
    function getPoolsByAsset(address asset) external view override returns (address[] memory) {
        return poolsByAsset[asset];
    }
    
    function getPoolsByType(string memory instrumentType) external view override returns (address[] memory) {
        return poolsByType[instrumentType];
    }
    
    function getPoolsByCreator(address creator) external view override returns (address[] memory) {
        return poolsByCreator[creator];
    }
    
    function getPoolsByMaturityRange(uint256 minMaturity, uint256 maxMaturity) external view override returns (address[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < poolList.length; i++) {
            uint256 maturity = poolInfos[poolList[i]].maturityDate;
            if (maturity >= minMaturity && maturity <= maxMaturity) {
                count++;
            }
        }
        
        address[] memory matchingPools = new address[](count);
        uint256 index = 0;
        
        for (uint256 i = 0; i < poolList.length; i++) {
            uint256 maturity = poolInfos[poolList[i]].maturityDate;
            if (maturity >= minMaturity && maturity <= maxMaturity) {
                matchingPools[index] = poolList[i];
                index++;
            }
        }
        
        return matchingPools;
    }
    
    function getPoolCount() external view override returns (uint256) {
        return poolList.length;
    }
    
    function getPoolAtIndex(uint256 index) external view override returns (address) {
        require(index < poolList.length, "Index out of bounds");
        return poolList[index];
    }
    
    function pausePool(address pool) external override onlyAdmin {
        updatePoolStatus(pool, false);
    }
    
    function unpausePool(address pool) external override onlyAdmin {
        updatePoolStatus(pool, true);
    }
    
    function emergencyDeactivatePool(address pool) external override onlyAdmin {
        updatePoolStatus(pool, false);
    }
} 