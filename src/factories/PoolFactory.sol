// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IPoolFactory.sol";
import "../interfaces/IPoolRegistry.sol";
import "../interfaces/ILiquidityPool.sol";
import "../interfaces/IManager.sol";

abstract contract AccessControl {
    mapping(bytes32 => mapping(address => bool)) private _roles;
    mapping(bytes32 => bytes32) private _roleAdmins;
    
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    
    event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    
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
            emit RoleGranted(role, account, msg.sender);
        }
    }
    
    function _revokeRole(bytes32 role, address account) internal {
        if (hasRole(role, account)) {
            _roles[role][account] = false;
            emit RoleRevoked(role, account, msg.sender);
        }
    }
}

abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;
    
    constructor() {
        _status = _NOT_ENTERED;
    }
    
    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

library Clones {
    function cloneDeterministic(address implementation, bytes32 salt) internal returns (address instance) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        require(instance != address(0), "ERC1167: create2 failed");
    }
    
    function predictDeterministicAddress(address implementation, bytes32 salt) internal view returns (address predicted) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf3ff00000000000000000000000000000000)
            mstore(add(ptr, 0x38), shl(0x60, address()))
            mstore(add(ptr, 0x4c), salt)
            mstore(add(ptr, 0x6c), keccak256(ptr, 0x37))
            predicted := keccak256(add(ptr, 0x37), 0x55)
        }
    }
}

contract PoolFactory is IPoolFactory, AccessControl, ReentrancyGuard {
    using Clones for address;
    
    bytes32 public constant FACTORY_ADMIN_ROLE = keccak256("FACTORY_ADMIN_ROLE");
    bytes32 public constant POOL_CREATOR_ROLE = keccak256("POOL_CREATOR_ROLE");
    
    address public override poolImplementation;
    address public override managerImplementation;
    address public override registry;
    
    uint256 public override totalPoolsCreated;
    
    mapping(address => address[]) public poolsByAsset;
    mapping(address => address[]) public poolsByCreator;
    mapping(address => bool) public validPools;
    
    modifier onlyPoolCreator() {
        require(
            hasRole(POOL_CREATOR_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Not authorized to create pools"
        );
        _;
    }
    
    constructor(
        address _poolImplementation,
        address _managerImplementation,
        address _registry,
        address _admin
    ) {
        require(_poolImplementation != address(0), "Invalid pool implementation");
        require(_managerImplementation != address(0), "Invalid manager implementation");
        require(_registry != address(0), "Invalid registry");
        require(_admin != address(0), "Invalid admin");
        
        poolImplementation = _poolImplementation;
        managerImplementation = _managerImplementation;
        registry = _registry;
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(FACTORY_ADMIN_ROLE, _admin);
        _grantRole(POOL_CREATOR_ROLE, _admin);
    }
    
    function createPool(
        PoolConfig memory config
    ) external override onlyPoolCreator nonReentrant returns (address pool, address manager) {
        require(config.asset != address(0), "Invalid asset");
        require(config.targetRaise > 0, "Invalid target raise");
        require(config.epochDuration > 0, "Invalid epoch duration");
        require(config.maturityDate > block.timestamp + config.epochDuration, "Invalid maturity date");
        require(config.spvAddress != address(0), "Invalid SPV address");
        require(config.multisigSigners.length >= 2, "Need at least 2 multisig signers");
        
        bytes32 salt = keccak256(
            abi.encodePacked(
                config.asset,
                config.instrumentType,
                config.targetRaise,
                config.maturityDate,
                totalPoolsCreated,
                block.timestamp
            )
        );
        
        pool = poolImplementation.cloneDeterministic(salt);
        manager = managerImplementation.cloneDeterministic(
            keccak256(abi.encodePacked(salt, "manager"))
        );
        
        poolsByAsset[config.asset].push(pool);
        poolsByCreator[msg.sender].push(pool);
        validPools[pool] = true;
        totalPoolsCreated++;
        
        IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
            pool: pool,
            manager: manager,
            asset: config.asset,
            instrumentType: config.instrumentType,
            createdAt: block.timestamp,
            isActive: true,
            creator: msg.sender,
            targetRaise: config.targetRaise,
            maturityDate: config.maturityDate
        });
        
        IPoolRegistry(registry).registerPool(pool, poolInfo);
        
        emit PoolCreated(
            pool,
            manager,
            config.asset,
            config.instrumentType,
            config.targetRaise,
            config.maturityDate
        );
        
        return (pool, manager);
    }
    
    function getPoolsByAsset(address asset) external view override returns (address[] memory) {
        return poolsByAsset[asset];
    }
    
    function getPoolsByCreator(address creator) external view override returns (address[] memory) {
        return poolsByCreator[creator];
    }
    
    function isValidPool(address pool) external view override returns (bool) {
        return validPools[pool];
    }
    
    function setImplementations(
        address poolImpl,
        address managerImpl
    ) external override onlyRole(FACTORY_ADMIN_ROLE) {
        require(poolImpl != address(0), "Invalid pool implementation");
        require(managerImpl != address(0), "Invalid manager implementation");
        
        address oldPoolImpl = poolImplementation;
        address oldManagerImpl = managerImplementation;
        
        poolImplementation = poolImpl;
        managerImplementation = managerImpl;
        
        emit ImplementationUpdated(oldPoolImpl, poolImpl, oldManagerImpl, managerImpl);
    }
    
    function setRegistry(address newRegistry) external override onlyRole(FACTORY_ADMIN_ROLE) {
        require(newRegistry != address(0), "Invalid registry");
        registry = newRegistry;
    }
    
    function grantPoolCreatorRole(address account) external onlyRole(FACTORY_ADMIN_ROLE) {
        _grantRole(POOL_CREATOR_ROLE, account);
    }
    
    function revokePoolCreatorRole(address account) external onlyRole(FACTORY_ADMIN_ROLE) {
        _revokeRole(POOL_CREATOR_ROLE, account);
    }
    
    function predictPoolAddress(
        PoolConfig memory config,
        uint256 nonce
    ) external view returns (address pool, address manager) {
        bytes32 salt = keccak256(
            abi.encodePacked(
                config.asset,
                config.instrumentType,
                config.targetRaise,
                config.maturityDate,
                nonce,
                block.timestamp
            )
        );
        
        pool = poolImplementation.predictDeterministicAddress(salt);
        manager = managerImplementation.predictDeterministicAddress(
            keccak256(abi.encodePacked(salt, "manager"))
        );
    }
    
    function _parseInstrumentType(string memory instrumentType) private pure returns (IPoolManager.InstrumentType) {
        bytes32 typeHash = keccak256(bytes(instrumentType));
        
        if (typeHash == keccak256("BOND")) {
            return IPoolManager.InstrumentType.BOND;
        } else if (typeHash == keccak256("TBILL")) {
            return IPoolManager.InstrumentType.TBILL;
        } else if (typeHash == keccak256("COMMERCIAL_PAPER")) {
            return IPoolManager.InstrumentType.COMMERCIAL_PAPER;
        } else if (typeHash == keccak256("FIXED_DEPOSIT")) {
            return IPoolManager.InstrumentType.FIXED_DEPOSIT;
        } else {
            revert("Unsupported instrument type");
        }
    }
} 