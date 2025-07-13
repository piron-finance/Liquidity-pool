// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./interfaces/IPoolRegistry.sol";
import "./AccessManager.sol";

contract PoolRegistry is IPoolRegistry {
    address public override factory;
    AccessManager public accessManager;
    
    uint256 public override totalPools;
    uint256 public override activePools;
    
    mapping(address => PoolInfo) private poolInfos;
    
    address[] private poolList;
    mapping(string => address[]) private poolsByType;
    
    mapping(address => bool) private approvedAssets;
    
    event FactoryUpdated(address indexed oldFactory, address indexed newFactory);
    event AccessManagerUpdated(address indexed oldAccessManager, address indexed newAccessManager);
    
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
    
    constructor(address _accessManager) {
        require(_accessManager != address(0), "PoolRegistry/invalid-access-manager");
        
        accessManager = AccessManager(_accessManager);
        factory = address(0);
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
} 