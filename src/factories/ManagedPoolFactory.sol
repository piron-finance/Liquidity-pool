// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../interfaces/IPoolRegistry.sol";
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
 * @dev factory for deploying  managed pools
 * @notice Deploy managed pools for any approved stablecoin with flexible configuration
 */
contract ManagedPoolFactory is Initializable, UUPSUpgradeable {
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STATE VARIABLES //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

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
    
    uint256 public deploymentNonce;

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STRUCTS ////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    struct PoolDeploymentConfig { // delete unused props
        address asset;              // CNGN, KES, USDT, USDC, etc.
        string poolName;            // "Piron Nigeria Treasury Pool"
        string poolSymbol;          // "pCNGN-TREAS"
        address spvAddress;         // SPV for this pool
        uint256[] supportedTenors;  // Optional: [90, 180, 270, 360] days (empty for flexible-only pools)
        uint256 minInvestment;      // 1000 * 10^decimals
        address[] underlyingPools;  // Optional: existing T-bill pools to aggregate . mark to delete
    }

    struct LockedPoolDeploymentConfig {
        address asset;              // CNGN, KES, USDT, USDC, etc.
        string poolName;            // "Piron CNGN Treasury Locked Pool"
        string poolSymbol;          // "pCNGN-LOCK"
        address spvAddress;         // SPV for this pool
        uint256 minInvestment;      // Minimum deposit
        ILockedPoolTypes.LockTier[] initialTiers;  // Multiple tenors: 3mo, 6mo, 12mo etc.
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EVENTS //////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

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

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// MODIFIERS ///////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    modifier onlyPoolCreator() {
        require(accessManager.hasRole(accessManager.POOL_CREATOR_ROLE(), msg.sender), "ManagedPoolFactory/not pool creator");
        _;
    }
    
    modifier onlyAdmin() {
        require(accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), msg.sender), "ManagedPoolFactory/not admin");
        _;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INITIALIZATION /////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the ManagedPoolFactory contract
     * @param _registry PoolRegistry contract address
     * @param _accessManager AccessManager contract address
     * @param _stableYieldManager StableYieldManager contract address
     * @param _timelockController TimelockController contract address
     * @param _stableYieldPoolImplementation StableYieldPool implementation address
     * @param _managedPoolEscrowImplementation ManagedPoolEscrow implementation address
     */
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
        // StableYieldManager is optional - only required for creating StableYield pools
        // StableYieldPool implementation is optional - only required for creating StableYield pools
        // ManagedPoolEscrow implementation is optional - only required for creating StableYield pools
        
        __UUPSUpgradeable_init();
        
        registry = IPoolRegistry(_registry);
        accessManager = AccessManager(_accessManager);
        timelockController = _timelockController;
        version = 1;
        deploymentNonce = 0;
        
        // Set optional StableYield components if provided
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

    /**
     * @notice Authorize contract upgrades (timelock only)
     */
    function _authorizeUpgrade(address newImplementation) internal override {
        require(msg.sender == timelockController, "ManagedPoolFactory/only timelock");
        require(newImplementation != address(0), "ManagedPoolFactory/invalid implementation");

        version ++;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// POOL DEPLOYMENT ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Deploy a new stable yield pool
     * @param config Deployment configuration
     * @return poolAddress Address of deployed StableYieldPool
     * @return escrowAddress Address of deployed ManagedPoolEscrow
     */
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

    /**
     * @notice Deploy a new locked pool
     * @param config Deployment configuration
     * @return poolAddress Address of deployed LockedPool
     * @return escrowAddress Address of deployed LockedPoolEscrow
     */
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

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INTERNAL DEPLOYMENT ////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

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

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// VALIDATION ///////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function _validateDeploymentConfig(PoolDeploymentConfig memory config) internal view {
        require(registry.isApprovedAsset(config.asset), "ManagedPoolFactory/asset not approved");
        require(config.spvAddress != address(0), "ManagedPoolFactory/invalid spv");
        require(bytes(config.poolName).length > 0, "ManagedPoolFactory/invalid pool name");
        require(bytes(config.poolSymbol).length > 0, "ManagedPoolFactory/invalid pool symbol");
        require(config.minInvestment > 0, "ManagedPoolFactory/invalid min investment");

        if (config.supportedTenors.length > 0) {
            for (uint256 i = 0; i < config.supportedTenors.length; i++) {
                uint256 tenor = config.supportedTenors[i];
                require(
                    tenor == 90 || tenor == 180 || tenor == 270 || tenor == 360,
                    "ManagedPoolFactory/invalid tenor"
                );
            }
        }
        
        if (config.underlyingPools.length > 0) {
            for (uint256 i = 0; i < config.underlyingPools.length; i++) {
                require(
                    registry.isRegisteredPool(config.underlyingPools[i]),
                    "ManagedPoolFactory/invalid underlying pool"
                );
            }
        }
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

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ADMIN FUNCTIONS ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Update StableYieldPool implementation
     * @param newImplementation New implementation address
     */
    function updateStableYieldPoolImplementation(address newImplementation) external onlyAdmin {
        require(newImplementation != address(0), "ManagedPoolFactory/invalid implementation");
        
        address oldImplementation = stableYieldPoolImplementation;
        stableYieldPoolImplementation = newImplementation;
        
        emit ImplementationUpdated("StableYieldPool", oldImplementation, newImplementation);
    }
    
    /**
     * @notice Update ManagedPoolEscrow implementation
     * @param newImplementation New implementation address
     */
    function updateManagedPoolEscrowImplementation(address newImplementation) external onlyAdmin {
        require(newImplementation != address(0), "ManagedPoolFactory/invalid implementation");
        
        address oldImplementation = managedPoolEscrowImplementation;
        managedPoolEscrowImplementation = newImplementation;
        
        emit ImplementationUpdated("ManagedPoolEscrow", oldImplementation, newImplementation);
    }

    /**
     * @notice Set LockedPoolManager address
     * @param _lockedPoolManager LockedPoolManager contract address
     */
    function setLockedPoolManager(address _lockedPoolManager) external onlyAdmin {
        require(_lockedPoolManager != address(0), "ManagedPoolFactory/invalid locked pool manager");
        lockedPoolManager = LockedPoolManager(_lockedPoolManager);
    }

    /**
     * @notice Update LockedPool implementation
     * @param newImplementation New implementation address
     */
    function updateLockedPoolImplementation(address newImplementation) external onlyAdmin {
        require(newImplementation != address(0), "ManagedPoolFactory/invalid implementation");
        
        address oldImplementation = lockedPoolImplementation;
        lockedPoolImplementation = newImplementation;
        
        emit ImplementationUpdated("LockedPool", oldImplementation, newImplementation);
    }

    /**
     * @notice Update LockedPoolEscrow implementation
     * @param newImplementation New implementation address
     */
    function updateLockedPoolEscrowImplementation(address newImplementation) external onlyAdmin {
        require(newImplementation != address(0), "ManagedPoolFactory/invalid implementation");
        
        address oldImplementation = lockedPoolEscrowImplementation;
        lockedPoolEscrowImplementation = newImplementation;
        
        emit ImplementationUpdated("LockedPoolEscrow", oldImplementation, newImplementation);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// UTILITY FUNCTIONS ///////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Get all managed pools created by this factory
     * @return pools Array of managed pool addresses
     */
    function getAllManagedPools() external view returns (address[] memory pools) {
        uint256 totalPools = registry.getTotalStableYieldPools();
        pools = new address[](totalPools);
        for (uint256 i = 0; i < totalPools; i++) {
            pools[i] = registry.getManagedPoolAtIndex(i);
        }
        return pools;
    }
    
    /**
     * @notice Check if pool was created by this factory
     * @param poolAddress Pool address to check
     * @return isManaged Whether pool is a managed pool
     */
    function isManagedPool(address poolAddress) external view returns (bool isManaged) {
        return registry.isManagedPool(poolAddress);
    }
    
    /**
     * @notice Get managed pool count
     * @return count Number of managed pools
     */
    function getTotalManagedPools() external view returns (uint256 count) {
        return registry.getTotalStableYieldPools();
    }
    
    /**
     * @notice Get managed pool at index
     * @param index Pool index
     * @return poolAddress Pool address
     */
    function getManagedPoolAtIndex(uint256 index) external view returns (address poolAddress) {
        return registry.getManagedPoolAtIndex(index);
    }
}