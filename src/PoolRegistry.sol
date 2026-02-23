// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22; 

import "./interfaces/IPoolRegistry.sol";
import "./AccessManager.sol";
import "./types/IStableYieldTypes.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title PoolRegistry
 * @dev Central registry for all pool types, approved assets, and SPV addresses.
 *      Upgraded via TimelockController. Tracks Single Asset, Stable Yield, and Locked pools.
 */
contract PoolRegistry is Initializable, UUPSUpgradeable, IPoolRegistry {

    // ==================== STATE ====================

    address public override factory;
    AccessManager public accessManager;
    address public timelockController;
    uint256 public version; 
    
    uint256 public override totalPools;
    uint256 public override activePools;
    uint256 public totalStableYieldPools;
    uint256 public totalLockedPools;

    address[] private poolList;
    address[] public approvedAssetsList;
    
    mapping(address => PoolInfo) private poolInfos;
    mapping(string => address[]) private poolsByType;
    mapping(address => AssetInfo) public assetInfo;
    mapping(address => bool) public approvedImplementations;

    mapping(address => IStableYieldTypes.PoolData) public stableYieldPools;
    mapping(uint256 => address) public stableYieldPoolAtIndex;
    mapping(address => bool) public isStableYieldPool;

    mapping(uint256 => address) public lockedPoolAtIndex;
    mapping(address => bool) public isLockedPool;
    
    mapping(address => bool) public approvedSPVs;
    mapping(address => uint256) public spvApprovedAt;
    address[] public approvedSPVList;

    struct AssetInfo {
        bool isApproved;
        string name;
        string symbol;
        uint8 decimals;
        bool isStablecoin;
        uint256 approvedAt;
    }
    
    enum PoolCategory {
        SINGLE_ASSET,
        STABLE_YIELD_FLEXIBLE,
        LOCKED_POOL
    }

    // ==================== MODIFIERS ====================

    modifier onlyFactory() {
        require(msg.sender == factory, "PoolRegistry/only-factory");
        _;
    }

    modifier onlyRole(bytes32 role) {
        require(accessManager.hasRole(role, msg.sender), "PoolRegistry/access denied");
        _;
    }

    // ==================== INITIALIZATION ====================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @dev Initialize the registry with access manager and timelock.
     * @param _accessManager AccessManager contract address
     * @param _timelockController TimelockController for upgrade authorization
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

    function _authorizeUpgrade(address newImplementation) internal override {
        require(msg.sender == timelockController, "Only timelock can upgrade");
        require(newImplementation != address(0), "Invalid implementation");
        version += 1;
    }

    // ==================== ADMIN CONFIG ====================

    /**
     * @dev Set the single-asset pool factory address.
     * @param _factory PoolFactory proxy address
     */
    function setFactory(address _factory) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(_factory != address(0), "PoolRegistry/invalid-factory");
        
        address oldFactory = factory;
        factory = _factory;
        
        emit FactoryUpdated(oldFactory, _factory);
    }
    
    /**
     * @dev Rotate the AccessManager contract.
     * @param _accessManager New AccessManager address
     */
    function setAccessManager(address _accessManager) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(_accessManager != address(0), "PoolRegistry/invalid-access-manager");
        
        address oldAccessManager = address(accessManager);
        accessManager = AccessManager(_accessManager);
        
        emit AccessManagerUpdated(oldAccessManager, _accessManager);
    }

    // ==================== POOL REGISTRATION ====================

    /**
     * @dev Register a Single Asset pool. Called by PoolFactory.
     * @param pool Pool proxy address
     * @param info Pool metadata
     */
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
     * @dev Register a Stable Yield pool. Called by StableYieldManager or ManagedPoolFactory.
     * @param poolData Full pool metadata struct
     */
    function registerStableYieldPool(
        IStableYieldTypes.PoolData memory poolData
    ) external override onlyRole(accessManager.POOL_CREATOR_ROLE()) {
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

    /**
     * @dev Register a Locked pool. Called by LockedPoolManager or ManagedPoolFactory.
     * @param poolAddress Pool proxy address
     * @param escrowAddress Escrow proxy address
     * @param asset Underlying asset token
     * @param name Human-readable pool name
     */
    function registerLockedPool(
        address poolAddress,
        address escrowAddress,
        address asset,
        string memory name
    ) external override onlyRole(accessManager.POOL_CREATOR_ROLE()) {
        require(poolAddress != address(0), "PoolRegistry/invalid pool");
        require(escrowAddress != address(0), "PoolRegistry/invalid escrow");
        require(!isLockedPool[poolAddress], "PoolRegistry/pool already registered");
        require(assetInfo[asset].isApproved, "PoolRegistry/asset not approved");
        
        isLockedPool[poolAddress] = true;
        lockedPoolAtIndex[totalLockedPools] = poolAddress;
        totalLockedPools++;
        
        emit LockedPoolRegistered(poolAddress, escrowAddress, asset, name);
    }

    // ==================== ASSET MANAGEMENT ====================

    /**
     * @dev Approve a token for use in pools. Automatically fetches decimals.
     * @param asset Token contract address
     * @param name Human-readable name
     * @param symbol Token symbol
     * @param isStablecoin Whether the asset is a stablecoin
     */
    function approveAsset(
        address asset,
        string memory name,
        string memory symbol,
        bool isStablecoin
    ) external override onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(asset != address(0), "PoolRegistry/invalid asset");
        require(bytes(name).length > 0, "PoolRegistry/invalid name");
        require(bytes(symbol).length > 0, "PoolRegistry/invalid symbol");
        require(!assetInfo[asset].isApproved, "PoolRegistry/already approved");
        
        uint8 decimals = 18;
        try IERC20Metadata(asset).decimals() returns (uint8 d) {
            decimals = d;
        } catch {}
        
        assetInfo[asset] = AssetInfo({
            isApproved: true,
            name: name,
            symbol: symbol,
            decimals: decimals,
            isStablecoin: isStablecoin,
            approvedAt: block.timestamp
        });
        
        approvedAssetsList.push(asset);
        
        emit AssetApproved(asset, name, symbol);
    }
    
    /**
     * @dev Revoke asset approval. Existing pools using this asset are unaffected.
     * @param asset Token to revoke
     */
    function revokeAsset(address asset) external override onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(assetInfo[asset].isApproved, "PoolRegistry/asset not approved");
        
        assetInfo[asset].isApproved = false;
        
        emit AssetRevoked(asset);
    }

    // ==================== SPV MANAGEMENT ====================

    /**
     * @dev Approve an SPV address for pool operations.
     * @param spv SPV address to approve
     */
    function approveSPV(address spv) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(spv != address(0), "PoolRegistry/invalid SPV");
        require(!approvedSPVs[spv], "PoolRegistry/SPV already approved");
        
        approvedSPVs[spv] = true;
        spvApprovedAt[spv] = block.timestamp;
        approvedSPVList.push(spv);
        
        emit SPVApproved(spv, block.timestamp);
    }

    /**
     * @dev Revoke SPV approval.
     * @param spv SPV address to revoke
     */
    function revokeSPV(address spv) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(approvedSPVs[spv], "PoolRegistry/SPV not approved");
        
        approvedSPVs[spv] = false;
        
        emit SPVRevoked(spv);
    }

    function isApprovedSPV(address spv) external view returns (bool) {
        return approvedSPVs[spv];
    }

    function getAllApprovedSPVs() external view returns (address[] memory) {
        return approvedSPVList;
    }

    function getSPVApprovalTime(address spv) external view returns (uint256) {
        return spvApprovedAt[spv];
    }

    // ==================== POOL STATUS ====================

    /**
     * @dev Toggle pool active status. Updates global activePools counter.
     * @param pool Pool address
     * @param isActive New active state
     */
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

    // ==================== UPGRADE & MULTISIG ====================

    /**
     * @dev Approve a new contract implementation. Requires MULTISIG_ADMIN_ROLE.
     * @param implementation Implementation address to whitelist
     */
    function approveImplementation(address implementation) external override onlyRole(accessManager.MULTISIG_ADMIN_ROLE()) {
        require(implementation != address(0), "Invalid implementation");
        require(!approvedImplementations[implementation], "Already approved");
        
        approvedImplementations[implementation] = true;
        
        emit ImplementationApproved(implementation);
    }

    /**
     * @dev Revoke an approved implementation.
     * @param implementation Implementation address to revoke
     */
    function revokeImplementation(address implementation) external override onlyRole(accessManager.MULTISIG_ADMIN_ROLE()) {
        require(approvedImplementations[implementation], "Implementation not approved");
        
        approvedImplementations[implementation] = false;
        
        emit ImplementationRevoked(implementation);
    }

    // ==================== VIEW ====================

    function getPoolInfo(address pool) external view override returns (PoolInfo memory) {
        return poolInfos[pool];
    }

     function isActivePool(address pool) external view override returns (bool) {
        return poolInfos[pool].createdAt != 0 && poolInfos[pool].isActive;
    }
    
    function isRegisteredPool(address pool) external view override returns (bool) {
        return poolInfos[pool].createdAt != 0 || isStableYieldPool[pool] || isLockedPool[pool];
    } 

    function isManagedPool(address pool) external view override returns (bool) {
        return isStableYieldPool[pool] || isLockedPool[pool];
    }
    
    function isManagedLockedPool(address pool) external view override returns (bool) {
        return isLockedPool[pool];
    }
    
    function getStableYieldPoolData(address pool) external view returns (IStableYieldTypes.PoolData memory) {
        require(isStableYieldPool[pool], "PoolRegistry/not a StableYield pool");
        return stableYieldPools[pool];
    }
    
    function getTotalStableYieldPools() external view override returns (uint256) {
        return totalStableYieldPools;
    }
    
    function getStableYieldPoolAtIndex(uint256 index) external view override returns (address) {
        require(index < totalStableYieldPools, "PoolRegistry/index out of bounds");
        return stableYieldPoolAtIndex[index];
    }
    
    function getPoolAtIndex(uint256 index) external view override returns (address) {
        require(index < poolList.length, "Index out of bounds");
        return poolList[index];
    }

    function getLockedPoolAtIndex(uint256 index) external view override returns (address) {
        require (index < totalLockedPools, "Index out of bounds");

        return lockedPoolAtIndex[index];
    }

    function getManagedPoolAtIndex(uint256 index) external view override returns (address) {
        require(index < totalStableYieldPools, "PoolRegistry/index out of bounds");
        return stableYieldPoolAtIndex[index];
    }
    
    function isApprovedAsset(address asset) external view override returns (bool) {
        return assetInfo[asset].isApproved;
    }
    
    function getAssetInfo(address asset) external view returns (AssetInfo memory) {
        return assetInfo[asset];
    }
    
    function getAllApprovedAssets() external view returns (address[] memory) {
        return approvedAssetsList;
    }
 
    function getPoolCount() external view override returns (uint256) {
        return poolList.length;
    }

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
    
    function isApprovedImplementation(address implementation) external view override returns (bool) {
        return approvedImplementations[implementation];
    }

} 
