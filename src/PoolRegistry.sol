// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./interfaces/IPoolRegistry.sol";
import "./AccessManager.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract PoolRegistry is Initializable, UUPSUpgradeable, IPoolRegistry {
    address public override factory;
    AccessManager public accessManager;
    address public timelockController;
    uint256 public version;
    
    uint256 public override totalPools;
    uint256 public override activePools;
    
    mapping(address => PoolInfo) private poolInfos;
    
    address[] private poolList;
    mapping(string => address[]) private poolsByType;
    
    // Enhanced Asset Approval & Metadata System
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
    
    mapping(address => AssetInfo) public assetInfo;
    address[] public approvedAssetsList;
    mapping(address => bool) public approvedImplementations;
    

    enum PoolCategory {
        SINGLE_ASSET,
        MANAGED_POOL
    }

    enum ManagedPoolType {
        STABLE_YIELD,
        LOCKED_YIELD,
        INDEX_POOL,
        TRANCHED_POOL
    }

    struct ManagedPoolInfo {
        address managedPool;
        PoolCategory category;
        ManagedPoolType managedType;
        address[] underlyingPools;
        uint256 createdAt;
        bool isActive;
    }

    mapping(address => ManagedPoolInfo) public managedPoolInfo;
    mapping(address => bool) public isManagedPoolMapping;
    uint256 public totalManagedPools;
    mapping(uint256 => address) public managedPoolAtIndex;
    
    event FactoryUpdated(address indexed oldFactory, address indexed newFactory);
    event AccessManagerUpdated(address indexed oldAccessManager, address indexed newAccessManager);
    event ImplementationApproved(address indexed implementation);
    event ImplementationRevoked(address indexed implementation);
    event ManagedPoolRegistered(address indexed managedPool, ManagedPoolType poolType, uint256 underlyingPoolsCount);
    
    // Asset Management Events
    event AssetApproved(
        address indexed asset,
        string name,
        string symbol,
        string country,
        string region
    );
    event AssetRevoked(address indexed asset);
    event AssetMetadataUpdated(address indexed asset);
    
    modifier onlyFactory() {
        require(msg.sender == factory, "PoolRegistry/only-factory");
        _;
    }
    
    modifier onlyRole(bytes32 role) {
        require(accessManager.hasRole(role, msg.sender), "PoolRegistry/access-denied");
        _;
    }
    
    modifier onlyAdmin() {
        require(accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), msg.sender), "PoolRegistry/only-admin");
        _;
    }
    
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
        
        accessManager = AccessManager(_accessManager);
        timelockController = _timelockController;
        factory = address(0);
        version = 1;
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
    function setFactory(address _factory) external onlyAdmin {
        require(_factory != address(0), "PoolRegistry/invalid-factory");
        
        address oldFactory = factory;
        factory = _factory;
        
        emit FactoryUpdated(oldFactory, _factory);
    }
    
    /**
     * @dev Update the access manager - can only be called by current admin
     * @param _accessManager The new access manager address
     */
    function setAccessManager(address _accessManager) external onlyAdmin {
        require(_accessManager != address(0), "PoolRegistry/invalid-access-manager");
        
        address oldAccessManager = address(accessManager);
        accessManager = AccessManager(_accessManager);
        
        emit AccessManagerUpdated(oldAccessManager, _accessManager);
    }
    
    function getPoolInfo(address pool) external view override returns (PoolInfo memory) {
        return poolInfos[pool];
    }
    
    function isRegisteredPool(address pool) external view override returns (bool) {
        return poolInfos[pool].createdAt != 0;
    }
    
    function isActivePool(address pool) external view override returns (bool) {
        return poolInfos[pool].createdAt != 0 && poolInfos[pool].isActive;
    }
    
    function registerPool(address pool, PoolInfo memory info) external override onlyFactory {
        require(pool != address(0), "PoolRegistry/invalid-pool");
        require(poolInfos[pool].createdAt == 0, "PoolRegistry/pool-already-registered");
        require(approvedAssets[info.asset], "PoolRegistry/asset-not-approved");
        
        poolInfos[pool] = info;
        poolList.push(pool);
        poolsByType[info.instrumentType].push(pool);
        
        totalPools++;
        if (info.isActive) {
            activePools++;
        }
        
        emit PoolRegistered(pool, info.manager, info.asset, info.instrumentType, info.creator);
    }

    /**
     * @notice Register a managed pool
     * @param managedPool Address of the managed pool
     * @param info Managed pool information
     */
    function registerManagedPool(
        address managedPool,
        ManagedPoolInfo memory info
    ) external onlyFactory {
        require(managedPool != address(0), "PoolRegistry/invalid managed pool");
        require(!isManagedPoolMapping[managedPool], "PoolRegistry/managed pool already registered");
        
        // Validate underlying pools exist
        for (uint256 i = 0; i < info.underlyingPools.length; i++) {
            require(poolInfos[info.underlyingPools[i]].createdAt != 0, "PoolRegistry/underlying pool not registered");
        }
        
        managedPoolInfo[managedPool] = info;
        isManagedPoolMapping[managedPool] = true;
        managedPoolAtIndex[totalManagedPools] = managedPool;
        totalManagedPools++;
        
        emit ManagedPoolRegistered(managedPool, info.managedType, info.underlyingPools.length);
    }

    /**
     * @notice Get managed pool information
     * @param managedPool Address of the managed pool
     * @return Managed pool information
     */
    function getManagedPoolInfo(address managedPool) external view returns (ManagedPoolInfo memory) {
        require(isManagedPoolMapping[managedPool], "PoolRegistry/managed pool not registered");
        return managedPoolInfo[managedPool];
    }

    /**
     * @notice Check if address is a managed pool
     * @param pool Address to check
     * @return True if it's a managed pool
     */
    function isManagedPool(address pool) external view returns (bool) {
        return isManagedPoolMapping[pool];
    }

    /**
     * @notice Get all managed pools
     * @return Array of managed pool addresses
     */
    function getAllManagedPools() external view returns (address[] memory) {
        address[] memory pools = new address[](totalManagedPools);
        for (uint256 i = 0; i < totalManagedPools; i++) {
            pools[i] = managedPoolAtIndex[i];
        }
        return pools;
    }
    
    function updatePoolStatus(address pool, bool isActive) public override onlyRole(accessManager.OPERATOR_ROLE()) {
        require(poolInfos[pool].createdAt != 0, "PoolRegistry/pool-not-registered");
        
        bool wasActive = poolInfos[pool].isActive;
        poolInfos[pool].isActive = isActive;
        
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
    
    function getPoolsByType(string memory instrumentType) external view override returns (address[] memory) {
        return poolsByType[instrumentType];
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
    
    function pausePool(address pool) external override onlyRole(accessManager.OPERATOR_ROLE()) {
        updatePoolStatus(pool, false);
    }
    
    function unpausePool(address pool) external override onlyRole(accessManager.OPERATOR_ROLE()) {
        updatePoolStatus(pool, true);
    }
    
    function emergencyDeactivatePool(address pool) external override onlyRole(accessManager.EMERGENCY_ROLE()) {
        updatePoolStatus(pool, false);
    }
    
    function approveAsset(address asset) external override onlyAdmin {
        require(asset != address(0), "PoolRegistry/invalid-asset");
        require(!approvedAssets[asset], "PoolRegistry/asset-already-approved");
        
        approvedAssets[asset] = true;
        
        emit AssetApproved(asset);
    }
    
    function revokeAsset(address asset) external override onlyAdmin {
        require(approvedAssets[asset], "PoolRegistry/asset-not-approved");
        
        approvedAssets[asset] = false;
        
        emit AssetRevoked(asset);
    }
    
    function isApprovedAsset(address asset) external view override returns (bool) {
        return approvedAssets[asset];
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
        string memory country,
        string memory region,
        bool isStablecoin
    ) external onlyRole(accessManager.ASSET_MANAGER_ROLE()) {
        require(asset != address(0), "PoolRegistry/invalid asset");
        require(bytes(name).length > 0, "PoolRegistry/invalid name");
        require(bytes(symbol).length > 0, "PoolRegistry/invalid symbol");
        require(!assetInfo[asset].isApproved, "PoolRegistry/already approved");
        
        // Get decimals from token contract
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