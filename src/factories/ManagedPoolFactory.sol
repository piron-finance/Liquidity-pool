// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../interfaces/IPoolRegistry.sol";
import "../interfaces/IFeeManager.sol";
import "../interfaces/IYieldReserveEscrow.sol";
import "../escrows/YieldReserveEscrow.sol";
import "../StableYieldManager.sol";
import "../LockedPoolManager.sol";
import "../managed/StableYieldPool.sol";
import "../managed/LockedPool.sol";
import "../escrows/StableYieldEscrow.sol";
import "../escrows/LockedPoolEscrow.sol";
import "../AccessManager.sol";
import "../types/IPoolTypes.sol";
import "../types/ILockedPoolTypes.sol";

/**
 * @title ManagedPoolFactory
 * @dev Deploys StableYieldPool and LockedPool pairs with their escrows using
 *      minimal proxies (Clones). Registers pools with the registry and managers,
 *      and configures escrow-level fee manager and yield reserve addresses.
 */
contract ManagedPoolFactory is Initializable, UUPSUpgradeable {

    // ==================== STATE ====================
    
    IPoolRegistry public registry;
    AccessManager public accessManager;
    StableYieldManager public stableYieldManager;
    LockedPoolManager public lockedPoolManager;
    address public timelockController;
    uint256 public version;
    address public stableYieldPoolImplementation;
    address public managedPoolEscrowImplementation;
    address public lockedPoolImplementation;
    address public lockedPoolEscrowImplementation;
    address public feeManager;
    address public yieldReserve;
    uint256 public deploymentNonce;

    // ==================== STRUCTS ====================

    /// @dev Configuration for deploying a StableYieldPool + escrow pair.
    struct PoolDeploymentConfig {
        address asset;
        string poolName;
        string poolSymbol;
        address spvAddress;
        uint256 minInvestment;
    }

    /// @dev Configuration for deploying a LockedPool + escrow pair with lock tiers.
    struct LockedPoolDeploymentConfig {
        address asset;
        string poolName;
        string poolSymbol;
        address spvAddress;
        uint256 minInvestment;
        ILockedPoolTypes.LockTier[] initialTiers;
    }

    // ==================== EVENTS ====================

    event StableYieldPoolCreated(
        address indexed poolAddress,
        address indexed escrowAddress,
        address indexed asset,
        string poolName,
        address spvAddress
    );

    event LockedPoolCreated(
        address indexed poolAddress,
        address indexed escrowAddress,
        address indexed asset,
        string poolName,
        address spvAddress
    );
    
    event ImplementationUpdated(
        string indexed contractType,
        address indexed oldImplementation,
        address indexed newImplementation
    );

    // ==================== MODIFIERS ====================

    modifier onlyPoolCreator() {
        require(accessManager.hasRole(accessManager.POOL_CREATOR_ROLE(), msg.sender), "ManagedPoolFactory/not pool creator");
        _;
    }
    
    modifier onlyAdmin() {
        require(accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), msg.sender), "ManagedPoolFactory/not admin");
        _;
    }

    // ==================== INITIALIZER ====================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Sets registry, access manager, and initial implementations.
    function initialize(
        address _registry,
        address _accessManager,
        address _stableYieldManager,
        address _timelockController,
        address _stableYieldPoolImplementation,
        address _managedPoolEscrowImplementation
    ) public initializer {
        require(_registry != address(0), "ManagedPoolFactory/invalid registry");
        require(_accessManager != address(0), "ManagedPoolFactory/invalid access manager");
        require(_timelockController != address(0), "ManagedPoolFactory/invalid timelock controller");
        
        __UUPSUpgradeable_init();
        
        registry = IPoolRegistry(_registry);
        accessManager = AccessManager(_accessManager);
        timelockController = _timelockController;
        version = 1;
        deploymentNonce = 0;
        
        if (_stableYieldManager != address(0)) {
            stableYieldManager = StableYieldManager(_stableYieldManager);
        }
        if (_stableYieldPoolImplementation != address(0)) {
            stableYieldPoolImplementation = _stableYieldPoolImplementation;
        }
        if (_managedPoolEscrowImplementation != address(0)) {
            managedPoolEscrowImplementation = _managedPoolEscrowImplementation;
        }
    }

    // ==================== UPGRADE ====================

    function _authorizeUpgrade(address newImplementation) internal override {
        require(msg.sender == timelockController, "ManagedPoolFactory/only timelock");
        require(newImplementation != address(0), "ManagedPoolFactory/invalid implementation");

        version ++;
    }

    // ==================== POOL CREATION ====================

    /// @dev Deploys a StableYieldPool + StableYieldEscrow pair, registers with manager and registry.
    function createStableYieldPool(PoolDeploymentConfig memory config) 
        external 
        onlyPoolCreator() 
        returns (address poolAddress, address escrowAddress) 
    {
        require(address(stableYieldManager) != address(0), "ManagedPoolFactory/stable yield manager not set");
        require(stableYieldPoolImplementation != address(0), "ManagedPoolFactory/pool impl not set");
        require(managedPoolEscrowImplementation != address(0), "ManagedPoolFactory/escrow impl not set");
        _validateDeploymentConfig(config);
        
        escrowAddress = _deployManagedPoolEscrow(config);

        poolAddress = _deployStableYieldPool(config, escrowAddress);
        
        StableYieldEscrow(escrowAddress).setStableYieldPool(poolAddress);
        StableYieldEscrow(escrowAddress).setStableYieldManager(address(stableYieldManager));
        
        if (feeManager != address(0)) {
            StableYieldEscrow(escrowAddress).setFeeManager(feeManager);
            IFeeManager(feeManager).authorizeCollector(escrowAddress, true);
        }
        if (yieldReserve != address(0)) {
            StableYieldEscrow(escrowAddress).setYieldReserve(yieldReserve);
            YieldReserveEscrow(yieldReserve).authorizeEscrow(escrowAddress, true);
        }
        
        stableYieldManager.registerPool(
            poolAddress,
            escrowAddress,
            config.asset,
            config.poolName,
            config.minInvestment
        );
        
        deploymentNonce++;
        
        emit StableYieldPoolCreated(poolAddress, escrowAddress, config.asset, config.poolName, config.spvAddress);
    }

    /// @dev Deploys a LockedPool + LockedPoolEscrow pair, registers with manager, and configures tiers.
    function createLockedPool(LockedPoolDeploymentConfig memory config) 
        external 
        onlyPoolCreator() 
        returns (address poolAddress, address escrowAddress) 
    {
        require(address(lockedPoolManager) != address(0), "ManagedPoolFactory/locked pool manager not set");
        require(lockedPoolImplementation != address(0), "ManagedPoolFactory/locked pool impl not set");
        require(lockedPoolEscrowImplementation != address(0), "ManagedPoolFactory/locked escrow impl not set");
        _validateLockedPoolConfig(config);
        
        escrowAddress = _deployLockedPoolEscrow(config);
        poolAddress = _deployLockedPool(config, escrowAddress);
        
        LockedPoolEscrow(escrowAddress).setLockedPool(poolAddress);
        LockedPoolEscrow(escrowAddress).setLockedPoolManager(address(lockedPoolManager));
        
        if (feeManager != address(0)) {
            LockedPoolEscrow(escrowAddress).setFeeManager(feeManager);
            IFeeManager(feeManager).authorizeCollector(escrowAddress, true);
        }
        if (yieldReserve != address(0)) {
            LockedPoolEscrow(escrowAddress).setYieldReserve(yieldReserve);
            YieldReserveEscrow(yieldReserve).authorizeEscrow(escrowAddress, true);
        }
        
        lockedPoolManager.registerPool(
            poolAddress,
            escrowAddress,
            config.asset,
            config.poolName,
            config.minInvestment
        );
        
        for (uint8 i = 0; i < config.initialTiers.length; i++) {
            lockedPoolManager.configureLockTier(poolAddress, i, config.initialTiers[i]);
        }
        
        registry.registerLockedPool(poolAddress, escrowAddress, config.asset, config.poolName);
        
        deploymentNonce++;
        
        emit LockedPoolCreated(poolAddress, escrowAddress, config.asset, config.poolName, config.spvAddress);
        
        return (poolAddress, escrowAddress);
    }

    // ==================== INTERNAL DEPLOY HELPERS ====================

    function _deployManagedPoolEscrow(PoolDeploymentConfig memory config) 
        internal 
        returns (address escrowAddress) 
    {
        bytes32 salt = keccak256(abi.encodePacked(
            config.asset,
            config.poolName,
            config.spvAddress,
            deploymentNonce
        ));
        
        escrowAddress = Clones.cloneDeterministic(managedPoolEscrowImplementation, salt);
        
        string memory poolName = string(abi.encodePacked("Piron", config.poolName));
        
        StableYieldEscrow(escrowAddress).initialize(
            config.asset,
            address(accessManager),
            poolName
        );
        
        return escrowAddress;
    }

    function _deployStableYieldPool(PoolDeploymentConfig memory config, address escrowAddress) 
        internal 
        returns (address poolAddress) 
    {
        bytes32 salt = keccak256(abi.encodePacked(
            config.asset,
            config.poolName,
            escrowAddress,
            deploymentNonce
        ));
        
        poolAddress = Clones.cloneDeterministic(stableYieldPoolImplementation, salt);
        
        StableYieldPool(poolAddress).initialize(
            config.asset,
            config.poolName,
            config.poolSymbol,
            escrowAddress,
            address(stableYieldManager),
            address(accessManager)
        );
        
        return poolAddress;
    }

    function _deployLockedPoolEscrow(LockedPoolDeploymentConfig memory config) 
        internal 
        returns (address escrowAddress) 
    {
        bytes32 salt = keccak256(abi.encodePacked(
            config.asset,
            config.poolName,
            config.spvAddress,
            deploymentNonce,
            "LOCKED"
        ));
        
        escrowAddress = Clones.cloneDeterministic(lockedPoolEscrowImplementation, salt);
        
        string memory poolName = string(abi.encodePacked("Piron", config.poolName));
        
        LockedPoolEscrow(escrowAddress).initialize(
            config.asset,
            address(accessManager),
            poolName
        );
        
        return escrowAddress;
    }

    function _deployLockedPool(LockedPoolDeploymentConfig memory config, address escrowAddress) 
        internal 
        returns (address poolAddress) 
    {
        bytes32 salt = keccak256(abi.encodePacked(
            config.asset,
            config.poolName,
            escrowAddress,
            deploymentNonce,
            "LOCKED"
        ));
        
        poolAddress = Clones.cloneDeterministic(lockedPoolImplementation, salt);
        
        LockedPool(poolAddress).initialize(
            config.asset,
            config.poolName,
            config.poolSymbol,
            escrowAddress,
            address(lockedPoolManager),
            address(accessManager)
        );
        
        return poolAddress;
    }

    // ==================== VALIDATION ====================

    function _validateDeploymentConfig(PoolDeploymentConfig memory config) internal view {
        require(registry.isApprovedAsset(config.asset), "ManagedPoolFactory/asset not approved");
        require(config.spvAddress != address(0), "ManagedPoolFactory/invalid spv");
        require(bytes(config.poolName).length > 0, "ManagedPoolFactory/invalid pool name");
        require(bytes(config.poolSymbol).length > 0, "ManagedPoolFactory/invalid pool symbol");
        require(config.minInvestment > 0, "ManagedPoolFactory/invalid min investment");
        
    }

    function _validateLockedPoolConfig(LockedPoolDeploymentConfig memory config) internal view {
        require(registry.isApprovedAsset(config.asset), "ManagedPoolFactory/asset not approved");
        require(config.spvAddress != address(0), "ManagedPoolFactory/invalid spv");
        require(bytes(config.poolName).length > 0, "ManagedPoolFactory/invalid pool name");
        require(bytes(config.poolSymbol).length > 0, "ManagedPoolFactory/invalid pool symbol");
        require(config.minInvestment > 0, "ManagedPoolFactory/invalid min investment");
        require(config.initialTiers.length > 0, "ManagedPoolFactory/no tiers");
        require(config.initialTiers.length <= 10, "ManagedPoolFactory/too many tiers");
        require(address(lockedPoolManager) != address(0), "ManagedPoolFactory/locked manager not set");
        require(lockedPoolImplementation != address(0), "ManagedPoolFactory/locked pool impl not set");
        require(lockedPoolEscrowImplementation != address(0), "ManagedPoolFactory/locked escrow impl not set");
        
        for (uint256 i = 0; i < config.initialTiers.length; i++) {
            require(config.initialTiers[i].durationDays > 0, "ManagedPoolFactory/invalid tier duration");
            require(config.initialTiers[i].apyBps > 0, "ManagedPoolFactory/invalid tier apy");
        }
    }

    // ==================== ADMIN CONFIGURATION ====================

    /// @dev Updates the implementation address for new StableYieldPool clones.
    function updateStableYieldPoolImplementation(address newImplementation) external onlyAdmin {
        require(newImplementation != address(0), "ManagedPoolFactory/invalid implementation");
        
        address oldImplementation = stableYieldPoolImplementation;
        stableYieldPoolImplementation = newImplementation;
        
        emit ImplementationUpdated("StableYieldPool", oldImplementation, newImplementation);
    }
    
    function updateManagedPoolEscrowImplementation(address newImplementation) external onlyAdmin {
        require(newImplementation != address(0), "ManagedPoolFactory/invalid implementation");
        
        address oldImplementation = managedPoolEscrowImplementation;
        managedPoolEscrowImplementation = newImplementation;
        
        emit ImplementationUpdated("ManagedPoolEscrow", oldImplementation, newImplementation);
    }

    function setLockedPoolManager(address _lockedPoolManager) external onlyAdmin {
        require(_lockedPoolManager != address(0), "ManagedPoolFactory/invalid locked pool manager");
        lockedPoolManager = LockedPoolManager(_lockedPoolManager);
    }

    function setFeeManager(address _feeManager) external onlyAdmin {
        require(_feeManager != address(0), "ManagedPoolFactory/invalid fee manager");
        feeManager = _feeManager;
    }

    function setYieldReserve(address _yieldReserve) external onlyAdmin {
        require(_yieldReserve != address(0), "ManagedPoolFactory/invalid yield reserve");
        yieldReserve = _yieldReserve;
    }

    function updateLockedPoolImplementation(address newImplementation) external onlyAdmin {
        require(newImplementation != address(0), "ManagedPoolFactory/invalid implementation");
        
        address oldImplementation = lockedPoolImplementation;
        lockedPoolImplementation = newImplementation;
        
        emit ImplementationUpdated("LockedPool", oldImplementation, newImplementation);
    }

    function updateLockedPoolEscrowImplementation(address newImplementation) external onlyAdmin {
        require(newImplementation != address(0), "ManagedPoolFactory/invalid implementation");
        
        address oldImplementation = lockedPoolEscrowImplementation;
        lockedPoolEscrowImplementation = newImplementation;
        
        emit ImplementationUpdated("LockedPoolEscrow", oldImplementation, newImplementation);
    }

    // ==================== VIEW FUNCTIONS ====================

    /// @dev Returns all managed pools registered in the registry.
    function getAllManagedPools() external view returns (address[] memory pools) {
        uint256 totalPools = registry.getTotalStableYieldPools();
        pools = new address[](totalPools);
        for (uint256 i = 0; i < totalPools; i++) {
            pools[i] = registry.getManagedPoolAtIndex(i);
        }
        return pools;
    }
    
    function isManagedPool(address poolAddress) external view returns (bool isManaged) {
        return registry.isManagedPool(poolAddress);
    }
    
    function getTotalManagedPools() external view returns (uint256 count) {
        return registry.getTotalStableYieldPools();
    }
    
    function getManagedPoolAtIndex(uint256 index) external view returns (address poolAddress) {
        return registry.getManagedPoolAtIndex(index);
    }
}
