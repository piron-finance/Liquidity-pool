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
    address public override factory;
    AccessManager public accessManager;
    address public timelockController;
    uint256 public version;
    
    uint256 public override totalPools;
    uint256 public override activePools;
    
    mapping(address => PoolInfo) private poolInfos;
    
    address[] private poolList;
    mapping(string => address[]) private poolsByType;
    

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
        STABLE_YIELD_FLEXIBLE,
        STABLE_YIELD_LOCKED
    }

    // StableYield pool tracking
    mapping(address => IStableYieldTypes.PoolData) public stableYieldPools;
    mapping(address => bool) public isStableYieldPool;
    uint256 public totalStableYieldPools;
    mapping(uint256 => address) public stableYieldPoolAtIndex;
    
    event FactoryUpdated(address indexed oldFactory, address indexed newFactory);
    event AccessManagerUpdated(address indexed oldAccessManager, address indexed newAccessManager);
    event ImplementationApproved(address indexed implementation);
    event ImplementationRevoked(address indexed implementation);
    event StableYieldPoolRegistered(
        address indexed poolAddress,
        address indexed escrowAddress,
        address indexed asset,
        bool isLocked,
        string name
    );
    event StableYieldPoolStatusUpdated(address indexed pool, bool isActive);
    
    // Asset Management Events
    event AssetApproved(
        address indexed asset,
        string name,
        string symbol,
        string country,
        string region
    );
  
    event AssetMetadataUpdated(address indexed asset);
    
    modifier onlyFactory() {
        require(msg.sender == factory, "PoolRegistry/only-factory");
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
        __AccessControl_init();
        
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

    /**
     * @notice Register a new StableYield pool
     * @param poolData Pool data from StableYieldManager
     */
    function registerStableYieldPool(
        IStableYieldTypes.PoolData memory poolData
    ) external onlyRole(accessManager.POOL_CREATOR_ROLE()) {
        require(poolData.poolAddress != address(0), "PoolRegistry/invalid pool");
        require(!isStableYieldPool[poolData.poolAddress], "PoolRegistry/pool already registered");
        require(assetInfo[poolData.asset].isApproved, "PoolRegistry/asset not approved");
        
        // Store StableYield pool data
        stableYieldPools[poolData.poolAddress] = poolData;
        isStableYieldPool[poolData.poolAddress] = true;
        stableYieldPoolAtIndex[totalStableYieldPools] = poolData.poolAddress;
        totalStableYieldPools++;
        
        // Also register in legacy PoolInfo format for compatibility
        PoolInfo memory legacyInfo = PoolInfo({
            pool: poolData.poolAddress,
            manager: address(0), // StableYieldManager handles this
            escrow: poolData.escrowAddress,
            asset: poolData.asset,
            instrumentType: poolData.isLocked ? "STABLE_YIELD_LOCKED" : "STABLE_YIELD_FLEXIBLE",
            createdAt: poolData.createdAt,
            isActive: poolData.isActive,
            creator: msg.sender,
            targetRaise: 0, // Not applicable for StableYield pools
            maturityDate: 0 // Not applicable for StableYield pools
        });
        
        poolInfos[poolData.poolAddress] = legacyInfo;
        poolList.push(poolData.poolAddress);
        poolsByType[legacyInfo.instrumentType].push(poolData.poolAddress);
        
        totalPools++;
        if (poolData.isActive) {
            activePools++;
        }
        
        emit StableYieldPoolRegistered(
            poolData.poolAddress,
            poolData.escrowAddress,
            poolData.asset,
            poolData.isLocked,
            poolData.name
        );
        emit PoolRegistered(
            poolData.poolAddress,
            address(0), // No manager for new architecture
            poolData.asset,
            legacyInfo.instrumentType,
            msg.sender
        );
    }



    /**
     * @notice Check if address is a StableYield pool
     * @param pool Address to check
     * @return True if it's a StableYield pool
     */
    function isStableYieldPoolRegistered(address pool) external view returns (bool) {
        return isStableYieldPool[pool];
    }
    
    /**
     * @notice Check if address is a managed pool (now refers to StableYield pools)
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
     * @notice Get all StableYield pools
     * @return Array of StableYield pool addresses
     */
    function getAllStableYieldPools() external view returns (address[] memory) {
        address[] memory pools = new address[](totalStableYieldPools);
        for (uint256 i = 0; i < totalStableYieldPools; i++) {
            pools[i] = stableYieldPoolAtIndex[i];
        }
        return pools;
    }
    
    /**
     * @notice Get StableYield pools by type
     * @param isLocked Whether to get locked or flexible pools
     * @return Array of matching pool addresses
     */
    function getStableYieldPoolsByType(bool isLocked) external view returns (address[] memory) {
        // Count matching pools first
        uint256 count = 0;
        for (uint256 i = 0; i < totalStableYieldPools; i++) {
            address poolAddr = stableYieldPoolAtIndex[i];
            if (stableYieldPools[poolAddr].isLocked == isLocked) {
                count++;
            }
        }
        
        // Build result array
        address[] memory matchingPools = new address[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < totalStableYieldPools; i++) {
            address poolAddr = stableYieldPoolAtIndex[i];
            if (stableYieldPools[poolAddr].isLocked == isLocked) {
                matchingPools[index] = poolAddr;
                index++;
            }
        }
        
        return matchingPools;
    }
    
    /**
     * @notice Get all managed pools (StableYield pools)
     * @return Array of all StableYield pool addresses
     */
    function getAllManagedPools() external view returns (address[] memory) {
        address[] memory pools = new address[](totalStableYieldPools);
        for (uint256 i = 0; i < totalStableYieldPools; i++) {
            pools[i] = stableYieldPoolAtIndex[i];
        }
        return pools;
    }
    
    /**
     * @notice Get total number of StableYield pools
     * @return Total StableYield pools count
     */
    function getTotalStableYieldPools() external view returns (uint256) {
        return totalStableYieldPools;
    }
    
    /**
     * @notice Get total number of managed pools (StableYield pools)
     * @return Total managed pools count
     */
    function getTotalManagedPools() external view returns (uint256) {
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
    
    // updateStableYieldPoolStatus functionality is now integrated into updatePoolStatus
    
    function updatePoolStatus(address pool, bool isActive) public override onlyRole(accessManager.OPERATOR_ROLE()) {
        require(poolInfos[pool].createdAt != 0, "PoolRegistry/pool-not-registered");
        
        bool wasActive;
        
        // Handle StableYield pools differently
        if (isStableYieldPool[pool]) {
            wasActive = stableYieldPools[pool].isActive;
            stableYieldPools[pool].isActive = isActive;
            
            // Also update legacy PoolInfo for compatibility
            poolInfos[pool].isActive = isActive;
            
            emit StableYieldPoolStatusUpdated(pool, isActive);
        } else {
            wasActive = poolInfos[pool].isActive;
            poolInfos[pool].isActive = isActive;
        }
        
        // Update active pools counter
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
    
    function approveAsset(address asset) external override onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(asset != address(0), "PoolRegistry/invalid asset");
        require(!assetInfo[asset].isApproved, "PoolRegistry/already approved");
        
        uint8 decimals = 18;
        try IERC20Metadata(asset).decimals() returns (uint8 d) {
            decimals = d;
        } catch {}
        
        assetInfo[asset] = AssetInfo({
            isApproved: true,
            name: "",
            symbol: "",
            country: "",
            region: "",
            tokenAddress: asset,
            decimals: decimals,
            isStablecoin: true,
            approvedAt: block.timestamp
        });
        
        approvedAssetsList.push(asset);
        emit AssetApproved(asset);
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