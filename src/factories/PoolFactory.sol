// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IPoolFactory.sol";
import "../interfaces/IPoolRegistry.sol";
import "../interfaces/IManager.sol";
import "../AccessManager.sol";

contract PoolFactory is IPoolFactory, ReentrancyGuard {
    using Clones for address;
    
    bytes32 public constant POOL_CREATOR_ROLE = keccak256("POOL_CREATOR_ROLE");
    
    address public override poolImplementation;
    address public override managerImplementation;
    address public override registry;
    uint256 public override totalPoolsCreated;
    
    AccessManager public accessManager;
    
    mapping(address => address[]) public poolsByAsset;
    mapping(address => address[]) public poolsByCreator;
    mapping(address => bool) public validPools;
    
    modifier onlyRole(bytes32 role) {
        require(accessManager.hasRole(role, msg.sender), "PoolFactory/access-denied");
        _;
    }
    
    modifier onlyPoolCreator() {
        require(
            accessManager.hasRole(POOL_CREATOR_ROLE, msg.sender) || 
            accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), msg.sender), 
            "PoolFactory/not-authorized"
        );
        _;
    }
    
    constructor(
        address _poolImpl,
        address _managerImpl,
        address _registry,
        address _accessManager
    ) {
        require(_poolImpl != address(0), "Invalid pool implementation");
        require(_managerImpl != address(0), "Invalid manager implementation");
        require(_registry != address(0), "Invalid registry");
        require(_accessManager != address(0), "Invalid access manager");
        
        poolImplementation = _poolImpl;
        managerImplementation = _managerImpl;
        registry = _registry;
        accessManager = AccessManager(_accessManager);
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
            escrow: address(0), // Will be set later when escrow is created
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
            faceValue: 0, // Will be calculated after deposit epoch closes based on actual raised amount
            purchasePrice: config.targetRaise, // We'll spend what we raise
            targetRaise: config.targetRaise,
            epochEndTime: block.timestamp + config.epochDuration,
            maturityDate: config.maturityDate,
            couponDates: new uint256[](0), // Empty for now, can be set later
            couponRates: new uint256[](0), // Empty for now, can be set later
            refundGasFee: 0, // Default to 0, can be configured later
            discountRate: config.discountRate
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
    
    function setImplementations(address poolImpl, address managerImpl) external override onlyRole(POOL_CREATOR_ROLE) {
        require(poolImpl != address(0), "Invalid pool implementation");
        require(managerImpl != address(0), "Invalid manager implementation");
        
        address oldPoolImpl = poolImplementation;
        address oldManagerImpl = managerImplementation;
        
        poolImplementation = poolImpl;
        managerImplementation = managerImpl;
        
        emit ImplementationUpdated(oldPoolImpl, poolImpl, oldManagerImpl, managerImpl);
    }
    
    function setRegistry(address newRegistry) external override onlyRole(POOL_CREATOR_ROLE) {
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
    
    function grantPoolCreatorRole(address account) external onlyRole(POOL_CREATOR_ROLE) {
        accessManager.grantRole(POOL_CREATOR_ROLE, account);
    }
    
    function revokePoolCreatorRole(address account) external onlyRole(POOL_CREATOR_ROLE) {
        accessManager.revokeRole(POOL_CREATOR_ROLE, account);
    }
    
    /**
     * @dev Calculate face value for discounted instruments
     * @param targetRaise Amount we want to raise from investors
     * @param discountRate Discount rate in basis points (e.g., 1800 = 18%)
     * @return faceValue The face value at maturity
     */
    function _calculateFaceValue(uint256 targetRaise, uint256 discountRate) internal pure returns (uint256) {
        // Face Value = Target Raise / (1 - discount rate)
        // For 18% discount: Face Value = 100,000 / (1 - 0.18) = 100,000 / 0.82 = 121,951
        require(discountRate < 10000, "Discount rate must be less than 100%");
        
        uint256 discountFactor = 10000 - discountRate; // e.g., 10000 - 1800 = 8200
        return (targetRaise * 10000) / discountFactor;
    }
} 