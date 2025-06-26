// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IPoolFactory.sol";
import "../interfaces/IPoolRegistry.sol";
import "../interfaces/IManager.sol";

contract PoolFactory is IPoolFactory, ReentrancyGuard {
    using Clones for address;
    
    bytes32 public constant POOL_CREATOR_ROLE = keccak256("POOL_CREATOR_ROLE");
    
    address public override poolImplementation;
    address public override managerImplementation;
    address public override registry;
    uint256 public override totalPoolsCreated;
    
    mapping(address => address[]) public poolsByAsset;
    mapping(address => address[]) public poolsByCreator;
    mapping(address => bool) public validPools;
    
    address public admin;
    mapping(bytes32 => mapping(address => bool)) private _roles;
    
    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin");
        _;
    }
    
    modifier onlyPoolCreator() {
        require(hasRole(POOL_CREATOR_ROLE, msg.sender) || msg.sender == admin, "Not authorized");
        _;
    }
    
    constructor(
        address _poolImpl,
        address _managerImpl,
        address _registry,
        address _admin
    ) {
        require(_poolImpl != address(0), "Invalid pool implementation");
        require(_managerImpl != address(0), "Invalid manager implementation");
        require(_registry != address(0), "Invalid registry");
        require(_admin != address(0), "Invalid admin");
        
        poolImplementation = _poolImpl;
        managerImplementation = _managerImpl;
        registry = _registry;
        admin = _admin;
        
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
        require(bytes(config.instrumentName).length > 0, "Instrument name required");
        
        bytes32 salt = keccak256(
            abi.encodePacked(
                config.asset,
                config.instrumentType,
                config.instrumentName,
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
            instrumentType: config.instrumentName,
            createdAt: block.timestamp,
            isActive: true,
            creator: msg.sender,
            targetRaise: config.targetRaise,
            maturityDate: config.maturityDate
        });
        
        IPoolRegistry(registry).registerPool(pool, poolInfo);
        
        // Initialize the manager with pool configuration
        IPoolManager.PoolConfig memory managerConfig = IPoolManager.PoolConfig({
            instrumentType: config.instrumentType,
            faceValue: config.targetRaise, // Assuming face value equals target raise for now
            purchasePrice: config.targetRaise, // Will be adjusted based on instrument type
            targetRaise: config.targetRaise,
            epochEndTime: block.timestamp + config.epochDuration,
            maturityDate: config.maturityDate,
            couponDates: new uint256[](0), // Empty for now, can be set later
            couponRates: new uint256[](0), // Empty for now, can be set later
            refundGasFee: 0 // Default to 0, can be configured later
        });
        
        IPoolManager(manager).initializePool(pool, managerConfig);
        
        emit PoolCreated(
            pool,
            manager,
            config.asset,
            config.instrumentName,
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
    
    function setImplementations(address poolImpl, address managerImpl) external override onlyAdmin {
        require(poolImpl != address(0), "Invalid pool implementation");
        require(managerImpl != address(0), "Invalid manager implementation");
        
        address oldPoolImpl = poolImplementation;
        address oldManagerImpl = managerImplementation;
        
        poolImplementation = poolImpl;
        managerImplementation = managerImpl;
        
        emit ImplementationUpdated(oldPoolImpl, poolImpl, oldManagerImpl, managerImpl);
    }
    
    function setRegistry(address newRegistry) external override onlyAdmin {
        require(newRegistry != address(0), "Invalid registry");
        registry = newRegistry;
    }
    
    function predictPoolAddress(
        PoolConfig memory config,
        uint256 nonce,
        uint256 timestamp
    ) external view returns (address pool, address manager) {
        bytes32 salt = keccak256(
            abi.encodePacked(
                config.asset,
                config.instrumentType,
                config.instrumentName,
                config.targetRaise,
                config.maturityDate,
                nonce,
                timestamp
            )
        );
        
        pool = poolImplementation.predictDeterministicAddress(salt);
        manager = managerImplementation.predictDeterministicAddress(
            keccak256(abi.encodePacked(salt, "manager"))
        );
    }
    
    function grantPoolCreatorRole(address account) external onlyAdmin {
        _grantRole(POOL_CREATOR_ROLE, account);
    }
    
    function revokePoolCreatorRole(address account) external onlyAdmin {
        _revokeRole(POOL_CREATOR_ROLE, account);
    }
    
    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role][account];
    }
    
    function _grantRole(bytes32 role, address account) internal {
        if (!hasRole(role, account)) {
            _roles[role][account] = true;
        }
    }
    
    function _revokeRole(bytes32 role, address account) internal {
        if (hasRole(role, account)) {
            _roles[role][account] = false;
        }
    }
} 