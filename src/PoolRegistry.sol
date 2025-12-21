// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22; 

import "./interfaces/IPoolRegistry.sol";
import "./AccessManager.sol";
import "./types/IStableYieldTypes.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract PoolRegistry is Initializable, UUPSUpgradeable, AccessControlUpgradeable, IPoolRegistry {


    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STATE VARIABLES //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////


    address public override factory;
    AccessManager public accessManager;
    address public timelockController;
    uint256 public version;
    
    uint256 public override totalPools;
    uint256 public override activePools;
    uint256 public totalStableYieldPools;
    address[] private poolList;
    address[] public approvedAssetsList;
    
    mapping(address => PoolInfo) private poolInfos;
    mapping(string => address[]) private poolsByType;
    mapping(address => AssetInfo) public assetInfo;
    mapping(address => bool) public approvedImplementations;

    mapping(address => IStableYieldTypes.PoolData) public stableYieldPools;
    mapping(uint256 => address) public stableYieldPoolAtIndex;
    mapping(address => bool) public isStableYieldPool;
    

    struct AssetInfo {
        bool isApproved;           // Asset approved for use
        string name;               // "Nigerian Naira"
        string symbol;             // "CNGN"
        string country;            // "Nigeria" (empty for multi-country)
        string region;             // "West Africa" (for regional pools)
        address tokenAddress;      // CNGN token contract
        uint8 decimals;           // 18
        bool isStablecoin;        // true
        uint256 approvedAt;       // Approval timestamp
    }
    

    enum PoolCategory {
        SINGLE_ASSET,
        STABLE_YIELD_FLEXIBLE
    }

   
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EVENTS //////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    
    event FactoryUpdated(address indexed oldFactory, address indexed newFactory);
    event AccessManagerUpdated(address indexed oldAccessManager, address indexed newAccessManager);
    event ImplementationApproved(address indexed implementation);
    event ImplementationRevoked(address indexed implementation);
    event StableYieldPoolRegistered( address indexed poolAddress, address indexed escrowAddress, address indexed asset, string name );
    event StableYieldPoolStatusUpdated(address indexed pool, bool isActive);
    
    event AssetApproved( address indexed asset, string name, string symbol, string country, string region );
    event AssetMetadataUpdated(address indexed asset);


    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// MODIFIERS ///////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    
    modifier onlyFactory() {
        require(msg.sender == factory, "PoolRegistry/only-factory");
        _;
    }
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INITIALIZATION & ACCESS CONTROL  /////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @notice Initialize the PoolRegistry contract
     * @param _accessManager AccessManager contract address
     * @param _timelockController TimelockController contract address
     */
    function initialize(
        address _accessManager,
        address _timelockController
    ) public initializer {
        require(_accessManager != address(0), "PoolRegistry/invalid-access-manager");
        require(_timelockController != address(0), "Invalid timelock controller");
        
        __UUPSUpgradeable_init();
        __AccessControl_init();
        
        accessManager = AccessManager(_accessManager);
        timelockController = _timelockController;
        factory = address(0);
        version = 1;
        
        // Grant roles to deployer for initial configuration
        _grantRole(accessManager.DEFAULT_ADMIN_ROLE(), msg.sender);
        _grantRole(accessManager.ASSET_MANAGER_ROLE(), msg.sender);
        _grantRole(accessManager.OPERATOR_ROLE(), msg.sender);
        _grantRole(accessManager.POOL_CREATOR_ROLE(), msg.sender);
    }

    
    /**
     * @notice Authorize contract upgrades
     * @param newImplementation New implementation contract address
     */
    function _authorizeUpgrade(address newImplementation) internal override {
        require(msg.sender == timelockController, "Only timelock can upgrade");
        require(newImplementation != address(0), "Invalid implementation");
        version += 1;
    }
    
    /**
     * @dev Set the factory address - can only be called by admin
     * @param _factory The new factory address
     */
    function setFactory(address _factory) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(_factory != address(0), "PoolRegistry/invalid-factory");
        
        address oldFactory = factory;
        factory = _factory;
        
        emit FactoryUpdated(oldFactory, _factory);
    }
    
    /**
     * @dev Update the access manager - can only be called by current admin
     * @param _accessManager The new access manager address
     */
    function setAccessManager(address _accessManager) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(_accessManager != address(0), "PoolRegistry/invalid-access-manager");
        
        address oldAccessManager = address(accessManager);
        accessManager = AccessManager(_accessManager);
        
        emit AccessManagerUpdated(oldAccessManager, _accessManager);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// POOL REGISTRATION ///////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function registerPool(address pool, PoolInfo memory info) external override onlyFactory {
        require(pool != address(0), "PoolRegistry/invalid-pool");
        require(poolInfos[pool].createdAt == 0, "PoolRegistry/pool-already-registered");
        require(assetInfo[info.asset].isApproved, "PoolRegistry/asset-not-approved");
        
        poolInfos[pool] = info;
        poolList.push(pool);
        poolsByType[info.instrumentType].push(pool);
        
        totalPools++;
        if (info.isActive) {
            activePools++;
        }
        
        emit PoolRegistered(pool, info.manager, info.asset, info.instrumentType, info.creator);
    }


    function registerStableYieldPool(
        IStableYieldTypes.PoolData memory poolData
    ) external {
        require(accessManager.hasRole(accessManager.POOL_CREATOR_ROLE(), msg.sender), "PoolRegistry/not pool creator");
        require(poolData.poolAddress != address(0), "PoolRegistry/invalid pool");
        require(!isStableYieldPool[poolData.poolAddress], "PoolRegistry/pool already registered");
        require(assetInfo[poolData.asset].isApproved, "PoolRegistry/asset not approved");
        
        stableYieldPools[poolData.poolAddress] = poolData;
        isStableYieldPool[poolData.poolAddress] = true;
        stableYieldPoolAtIndex[totalStableYieldPools] = poolData.poolAddress;
        totalStableYieldPools++;
        
        emit StableYieldPoolRegistered(
            poolData.poolAddress,
            poolData.escrowAddress,
            poolData.asset,
            poolData.name
        );
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// VIEW FUNCTIONS ///////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function getPoolInfo(address pool) external view override returns (PoolInfo memory) {
        return poolInfos[pool];
    }
    
    function isRegisteredPool(address pool) external view override returns (bool) {
        return poolInfos[pool].createdAt != 0;
    }
    
    function isActivePool(address pool) external view override returns (bool) {
        return poolInfos[pool].createdAt != 0 && poolInfos[pool].isActive;
    }


    /**
     * @notice Check if address is a managed pool (StableYield pool)
     * @param pool Address to check
     * @return True if it's a StableYield pool
     */
    function isManagedPool(address pool) external view returns (bool) {
        return isStableYieldPool[pool];
    }
    
    /**
     * @notice Get StableYield pool data
     * @param pool Pool address
     * @return StableYield pool data
     */
    function getStableYieldPoolData(address pool) external view returns (IStableYieldTypes.PoolData memory) {
        require(isStableYieldPool[pool], "PoolRegistry/not a StableYield pool");
        return stableYieldPools[pool];
    }
    
    /**
     * @notice Get total number of StableYield pools
     * @return Total StableYield pools count
     */
    function getTotalStableYieldPools() external view returns (uint256) {
        return totalStableYieldPools;
    }
    
    
    /**
     * @notice Get StableYield pool at specific index
     * @param index Index of StableYield pool
     * @return StableYield pool address
     */
    function getStableYieldPoolAtIndex(uint256 index) external view returns (address) {
        require(index < totalStableYieldPools, "PoolRegistry/index out of bounds");
        return stableYieldPoolAtIndex[index];
    }
    
    /**
     * @notice Get managed pool at specific index (StableYield pools)
     * @param index Index of managed pool
     * @return Managed pool address
     */
    function getManagedPoolAtIndex(uint256 index) external view returns (address) {
        require(index < totalStableYieldPools, "PoolRegistry/index out of bounds");
        return stableYieldPoolAtIndex[index];
    }
    
    
    function updatePoolStatus(address pool, bool isActive) public override onlyRole(accessManager.OPERATOR_ROLE()) {
        bool wasActive;

        if (isStableYieldPool[pool]) {
            wasActive = stableYieldPools[pool].isActive;
            stableYieldPools[pool].isActive = isActive;
            
            emit StableYieldPoolStatusUpdated(pool, isActive);
        } else {
            require(poolInfos[pool].createdAt != 0, "PoolRegistry/pool-not-registered");
            wasActive = poolInfos[pool].isActive;
            poolInfos[pool].isActive = isActive;
        }

        if (wasActive && !isActive) {
            activePools--;
        } else if (!wasActive && isActive) {
            activePools++;
        }
        
        emit PoolStatusUpdated(pool, isActive);
    }
    
    function updatePoolCategory(address pool, string memory newCategory) external override onlyRole(accessManager.OPERATOR_ROLE()) {
        require(poolInfos[pool].createdAt != 0, "PoolRegistry/pool-not-registered");
        
        string memory oldCategory = poolInfos[pool].instrumentType;
        poolInfos[pool].instrumentType = newCategory;
        
        emit PoolCategoryUpdated(pool, oldCategory, newCategory);
    }
    
    /**
     * @notice Get pool count for pagination
     * @return Total number of traditional pools
     */
    function getPoolCount() external view override returns (uint256) {
        return poolList.length;
    }
    
    /**
     * @notice Get pool at specific index for pagination
     * @param index Pool index
     * @return Pool address
     */
    function getPoolAtIndex(uint256 index) external view override returns (address) {
        require(index < poolList.length, "Index out of bounds");
        return poolList[index];
    }
    
    /**
     * @notice Get pools by type (efficient - direct mapping access)
     * @param instrumentType Type of instrument
     * @return Array of pool addresses of that type
     */
    function getPoolsByType(string memory instrumentType) external view override returns (address[] memory) {
        return poolsByType[instrumentType];
    }
    
    function pausePool(address pool) external override onlyRole(accessManager.OPERATOR_ROLE()) {
        updatePoolStatus(pool, false);
    }
    
    function unpausePool(address pool) external override onlyRole(accessManager.OPERATOR_ROLE()) {
        updatePoolStatus(pool, true);
    }
    
    function emergencyDeactivatePool(address pool) external override onlyRole(accessManager.EMERGENCY_ROLE()) {
        updatePoolStatus(pool, false);
    }
    

    /**
     * @notice Approve a new pool implementation
     * @param implementation Address of the new implementation contract
     * @dev Only callable by EXECUTOR_ROLE (rare, high-privilege operation)
     */
    function approveImplementation(address implementation) external onlyRole(accessManager.MULTISIG_ADMIN_ROLE()) {
        require(implementation != address(0), "Invalid implementation");
        require(!approvedImplementations[implementation], "Already approved");
        
        approvedImplementations[implementation] = true;
        
        emit ImplementationApproved(implementation);
    }

    /**
     * @notice Revoke an implementation approval
     * @param implementation Address of the implementation to revoke
     */
    function revokeImplementation(address implementation) external onlyRole(accessManager.MULTISIG_ADMIN_ROLE()) {
        require(approvedImplementations[implementation], "Implementation not approved");
        
        approvedImplementations[implementation] = false;
        
        emit ImplementationRevoked(implementation);
    }

    /**
     * @notice Check if implementation is approved
     * @param implementation Address to check
     * @return approved True if implementation is approved
     */
    function isApprovedImplementation(address implementation) external view returns (bool) {
        return approvedImplementations[implementation];
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ASSET MANAGEMENT ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Approve a new asset for use in managed pools
     * @param asset Asset token address
     * @param name Asset name (e.g., "Nigerian Naira")
     * @param symbol Asset symbol (e.g., "CNGN")
     * @param country Country name (empty for multi-country assets)
     * @param region Region name (e.g., "West Africa")
     * @param isStablecoin Whether asset is a stablecoin
     */
    function approveAsset(
        address asset,
        string memory name,
        string memory symbol,
        string memory country, // we dont really use this anymore . prob has no relevance again
        string memory region, //same as above
        bool isStablecoin
    ) external onlyRole(accessManager.ASSET_MANAGER_ROLE()) {
        require(asset != address(0), "PoolRegistry/invalid asset");
        require(bytes(name).length > 0, "PoolRegistry/invalid name");
        require(bytes(symbol).length > 0, "PoolRegistry/invalid symbol");
        require(!assetInfo[asset].isApproved, "PoolRegistry/already approved");
        
        uint8 decimals = 18; // Default
        try IERC20Metadata(asset).decimals() returns (uint8 d) {
            decimals = d;
        } catch {}
        
        assetInfo[asset] = AssetInfo({
            isApproved: true,
            name: name,
            symbol: symbol,
            country: country,
            region: region,
            tokenAddress: asset,
            decimals: decimals,
            isStablecoin: isStablecoin,
            approvedAt: block.timestamp
        });
        
        approvedAssetsList.push(asset);
        
        emit AssetApproved(asset, name, symbol, country, region);
    }
    
    /**
     * @notice Revoke asset approval
     * @param asset Asset token address
     */
    function revokeAsset(address asset) external onlyRole(accessManager.ASSET_MANAGER_ROLE()) {
        require(assetInfo[asset].isApproved, "PoolRegistry/asset not approved");
        
        assetInfo[asset].isApproved = false;
        
        emit AssetRevoked(asset);
    }
    
    /**
     * @notice Update asset metadata
     * @param asset Asset token address
     * @param name New asset name
     * @param country New country name
     * @param region New region name
     */
    function updateAssetMetadata(
        address asset,
        string memory name,
        string memory country,
        string memory region
    ) external onlyRole(accessManager.ASSET_MANAGER_ROLE()) {
        require(assetInfo[asset].isApproved, "PoolRegistry/asset not approved");
        
        AssetInfo storage info = assetInfo[asset];
        info.name = name;
        info.country = country;
        info.region = region;
        
        emit AssetMetadataUpdated(asset);
    }
    
    /**
     * @notice Check if asset is approved
     * @param asset Asset token address
     * @return Whether asset is approved
     */
    function isApprovedAsset(address asset) external view returns (bool) {
        return assetInfo[asset].isApproved;
    }
    
    /**
     * @notice Get asset information
     * @param asset Asset token address
     * @return Asset information struct
     */
    function getAssetInfo(address asset) external view returns (AssetInfo memory) {
        return assetInfo[asset];
    }
    
    /**
     * @notice Get all approved assets
     * @return Array of approved asset addresses
     */
    function getAllApprovedAssets() external view returns (address[] memory) {
        return approvedAssetsList;
    }
} 