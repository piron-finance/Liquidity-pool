// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../interfaces/IPoolRegistry.sol";
import "../StableYieldManager.sol";
import "../managed/StableYieldPool.sol";
import "../escrows/ManagedPoolEscrow.sol";
import "../AccessManager.sol";
import "../types/IPoolTypes.sol";

/**
 * @title ManagedPoolFactory
 * @dev Plug-and-play factory for deploying composable managed pools
 * @notice Deploy managed pools for any approved stablecoin with flexible configuration
 */
contract ManagedPoolFactory is Initializable, UUPSUpgradeable {
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STATE VARIABLES //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /// @dev Pool registry for asset validation and registration
    IPoolRegistry public registry;
    
    /// @dev Access manager for role-based permissions
    AccessManager public accessManager;
    
    /// @dev StableYieldManager for business logic
    StableYieldManager public stableYieldManager;
    
    /// @dev Timelock controller for upgrade authorization
    address public timelockController;
    
    /// @dev Version for upgrade tracking
    uint256 public version;

    /// @dev Implementation contracts for cloning
    address public stableYieldPoolImplementation;
    address public managedPoolEscrowImplementation;
    
    /// @dev Deployment nonce for unique addresses
    uint256 public deploymentNonce;

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STRUCTS ////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @dev Complete configuration for deploying a managed pool
     */
    struct PoolDeploymentConfig {
        address asset;              // CNGN, KES, USDT, USDC, etc.
        string poolName;            // "Piron Nigeria Treasury Pool"
        string poolSymbol;          // "pCNGN-TREAS"
        address spvAddress;         // SPV for this pool
        uint256[] supportedTenors;  // [90, 180, 270, 360] days
        uint256 minInvestment;      // 1000 * 10^decimals
        uint256 expenseRatio;       // 50 basis points (0.5%)
        address[] underlyingPools;  // Optional: existing T-bill pools to aggregate
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
    
    event ImplementationUpdated(
        string indexed contractType,
        address indexed oldImplementation,
        address indexed newImplementation
    );

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// MODIFIERS ///////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    modifier onlyRole(bytes32 role) {
        require(accessManager.hasRole(role, msg.sender), "ManagedPoolFactory/access denied");
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
        require(_stableYieldManager != address(0), "ManagedPoolFactory/invalid stable yield manager");
        require(_timelockController != address(0), "ManagedPoolFactory/invalid timelock controller");
        require(_stableYieldPoolImplementation != address(0), "ManagedPoolFactory/invalid pool implementation");
        require(_managedPoolEscrowImplementation != address(0), "ManagedPoolFactory/invalid escrow implementation");
        
        __UUPSUpgradeable_init();
        
        registry = IPoolRegistry(_registry);
        accessManager = AccessManager(_accessManager);
        stableYieldManager = StableYieldManager(_stableYieldManager);
        timelockController = _timelockController;
        stableYieldPoolImplementation = _stableYieldPoolImplementation;
        managedPoolEscrowImplementation = _managedPoolEscrowImplementation;
        version = 1;
        deploymentNonce = 0;
    }

    /**
     * @notice Authorize contract upgrades (UUPS)
     * @param newImplementation New implementation address
     */
    function _authorizeUpgrade(address newImplementation) internal override {
        require(msg.sender == timelockController, "ManagedPoolFactory/unauthorized upgrade");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// POOL DEPLOYMENT ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Deploy a new stable yield pool (completely composable)
     * @param config Deployment configuration
     * @return poolAddress Address of deployed StableYieldPool
     * @return escrowAddress Address of deployed ManagedPoolEscrow
     */
    function createStableYieldPool(PoolDeploymentConfig memory config) 
        external 
        onlyRole(accessManager.POOL_CREATOR_ROLE()) 
        returns (address poolAddress, address escrowAddress) 
    {
        // Validate configuration
        _validateDeploymentConfig(config);
        
        // Deploy escrow first
        escrowAddress = _deployManagedPoolEscrow(config);
        
        // Deploy pool
        poolAddress = _deployStableYieldPool(config, escrowAddress);
        
        // Register with StableYieldManager
        stableYieldManager.registerManagedPool(
            poolAddress,
            config.asset,
            escrowAddress,
            config.spvAddress,
            config.supportedTenors,
            config.minInvestment,
            config.expenseRatio
        );
        
        // Register with PoolRegistry
        registry.registerManagedPool(
            poolAddress,
            IPoolRegistry.ManagedPoolType.STABLE_YIELD,
            config.underlyingPools
        );
        
        // Increment deployment nonce
        deploymentNonce++;
        
        emit StableYieldPoolCreated(poolAddress, escrowAddress, config.asset, config.poolName, config.spvAddress);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INTERNAL DEPLOYMENT ////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @dev Deploy ManagedPoolEscrow using Clones
     */
    function _deployManagedPoolEscrow(PoolDeploymentConfig memory config) 
        internal 
        returns (address escrowAddress) 
    {
        // Create deterministic salt for escrow
        bytes32 salt = keccak256(abi.encodePacked(
            config.asset,
            config.poolName,
            config.spvAddress,
            deploymentNonce
        ));
        
        // Clone the escrow implementation
        escrowAddress = Clones.cloneDeterministic(managedPoolEscrowImplementation, salt);
        
        // Initialize the escrow
        ManagedPoolEscrow(escrowAddress).initialize(
            config.asset,
            address(0), // managedPool will be set after pool deployment
            address(accessManager),
            timelockController
        );
        
        return escrowAddress;
    }

    /**
     * @dev Deploy StableYieldPool using Clones
     */
    function _deployStableYieldPool(PoolDeploymentConfig memory config, address escrowAddress) 
        internal 
        returns (address poolAddress) 
    {
        // Create deterministic salt for pool
        bytes32 salt = keccak256(abi.encodePacked(
            config.asset,
            config.poolName,
            escrowAddress,
            deploymentNonce
        ));
        
        // Clone the pool implementation
        poolAddress = Clones.cloneDeterministic(stableYieldPoolImplementation, salt);
        
        // Initialize the pool
        StableYieldPool(poolAddress).initialize(
            IERC20(config.asset),
            config.poolName,
            config.poolSymbol,
            address(stableYieldManager),
            address(accessManager),
            escrowAddress
        );
        
        // Update escrow with pool address
        ManagedPoolEscrow(escrowAddress).updateManagedPool(poolAddress);
        
        return poolAddress;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// VALIDATION ///////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @dev Validate deployment configuration
     */
    function _validateDeploymentConfig(PoolDeploymentConfig memory config) internal view {
        // Validate asset is approved by Registry
        require(registry.isApprovedAsset(config.asset), "ManagedPoolFactory/asset not approved");
        require(config.spvAddress != address(0), "ManagedPoolFactory/invalid spv");
        require(bytes(config.poolName).length > 0, "ManagedPoolFactory/invalid pool name");
        require(bytes(config.poolSymbol).length > 0, "ManagedPoolFactory/invalid pool symbol");
        require(config.supportedTenors.length > 0, "ManagedPoolFactory/no tenors");
        require(config.minInvestment > 0, "ManagedPoolFactory/invalid min investment");
        require(config.expenseRatio <= 1000, "ManagedPoolFactory/expense ratio too high"); // Max 10%
        
        // Validate tenors
        for (uint256 i = 0; i < config.supportedTenors.length; i++) {
            uint256 tenor = config.supportedTenors[i];
            require(
                tenor == 90 || tenor == 180 || tenor == 270 || tenor == 360,
                "ManagedPoolFactory/invalid tenor"
            );
        }
        
        // Validate underlying pools (if provided)
        for (uint256 i = 0; i < config.underlyingPools.length; i++) {
            require(
                registry.isRegisteredPool(config.underlyingPools[i]),
                "ManagedPoolFactory/invalid underlying pool"
            );
        }
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// DEPLOYMENT HELPERS //////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Predict pool address before deployment
     * @param config Deployment configuration
     * @return poolAddress Predicted pool address
     * @return escrowAddress Predicted escrow address
     */
    function predictPoolAddresses(PoolDeploymentConfig memory config) 
        external 
        view 
        returns (address poolAddress, address escrowAddress) 
    {
        // Escrow salt
        bytes32 escrowSalt = keccak256(abi.encodePacked(
            config.asset,
            config.poolName,
            config.spvAddress,
            deploymentNonce
        ));
        
        escrowAddress = Clones.predictDeterministicAddress(
            managedPoolEscrowImplementation,
            escrowSalt,
            address(this)
        );
        
        // Pool salt
        bytes32 poolSalt = keccak256(abi.encodePacked(
            config.asset,
            config.poolName,
            escrowAddress,
            deploymentNonce
        ));
        
        poolAddress = Clones.predictDeterministicAddress(
            stableYieldPoolImplementation,
            poolSalt,
            address(this)
        );
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// VIEW FUNCTIONS ///////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Check if pool can be deployed with given config
     * @param config Deployment configuration
     * @return canDeploy Whether deployment is possible
     * @return reason Reason if deployment is not possible
     */
    function canDeployPool(PoolDeploymentConfig memory config) 
        external 
        view 
        returns (bool canDeploy, string memory reason) 
    {
        if (!registry.isApprovedAsset(config.asset)) {
            return (false, "Asset not approved");
        }
        
        if (config.spvAddress == address(0)) {
            return (false, "Invalid SPV address");
        }
        
        if (bytes(config.poolName).length == 0) {
            return (false, "Invalid pool name");
        }
        
        if (config.supportedTenors.length == 0) {
            return (false, "No tenors specified");
        }
        
        if (config.expenseRatio > 1000) {
            return (false, "Expense ratio too high");
        }
        
        return (true, "");
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

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// UTILITY FUNCTIONS ///////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Get all managed pools created by this factory
     * @return pools Array of managed pool addresses
     */
    function getAllManagedPools() external view returns (address[] memory pools) {
        return registry.getAllManagedPools();
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
        return registry.getTotalManagedPools();
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