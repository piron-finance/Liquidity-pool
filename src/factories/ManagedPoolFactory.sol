// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../interfaces/IPoolRegistry.sol";
import "../StableYieldManager.sol";
import "../managed/StableYieldPool.sol";
import "../escrows/StableYieldEscrow.sol";
import "../AccessManager.sol";
import "../types/IPoolTypes.sol";

/**
 * @title ManagedPoolFactory
 * @dev factory for deploying  managed pools
 * @notice Deploy managed pools for any approved stablecoin with flexible configuration
 */
contract ManagedPoolFactory is Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STATE VARIABLES //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    IPoolRegistry public registry;
    
    AccessManager public accessManager;

    StableYieldManager public stableYieldManager;

    address public timelockController;

    uint256 public version;

    address public stableYieldPoolImplementation;
    address public managedPoolEscrowImplementation;
    
    uint256 public deploymentNonce;

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STRUCTS ////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    struct PoolDeploymentConfig {
        address asset;              // CNGN, KES, USDT, USDC, etc.
        string poolName;            // "Piron Nigeria Treasury Pool"
        string poolSymbol;          // "pCNGN-TREAS"
        address spvAddress;         // SPV for this pool
        uint256[] supportedTenors;  // Optional: [90, 180, 270, 360] days (empty for flexible-only pools)
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
        require(_stableYieldManager != address(0), "ManagedPoolFactory/invalid stable yield manager");
        require(_timelockController != address(0), "ManagedPoolFactory/invalid timelock controller");
        require(_stableYieldPoolImplementation != address(0), "ManagedPoolFactory/invalid pool implementation");
        require(_managedPoolEscrowImplementation != address(0), "ManagedPoolFactory/invalid escrow implementation");
        
        __UUPSUpgradeable_init();
        __AccessControl_init();
        
        registry = IPoolRegistry(_registry);
        accessManager = AccessManager(_accessManager);
        stableYieldManager = StableYieldManager(_stableYieldManager);
        timelockController = _timelockController;
        stableYieldPoolImplementation = _stableYieldPoolImplementation;
        managedPoolEscrowImplementation = _managedPoolEscrowImplementation;
        version = 1;
        deploymentNonce = 0;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
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
        _validateDeploymentConfig(config);
        
        escrowAddress = _deployManagedPoolEscrow(config);

        poolAddress = _deployStableYieldPool(config, escrowAddress);
        
        StableYieldEscrow(escrowAddress).setStableYieldPool(poolAddress);
        
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
            address(stableYieldManager),
            address(accessManager),
            escrowAddress
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
        require(config.expenseRatio <= 1000, "ManagedPoolFactory/expense ratio too high"); // Max 10%
        

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