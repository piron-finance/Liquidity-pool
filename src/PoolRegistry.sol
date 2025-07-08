// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./interfaces/IPoolRegistry.sol";

contract PoolRegistry is IPoolRegistry {
    address public override factory;
    
    uint256 public override totalPools;
    uint256 public override activePools;
    
    mapping(address => PoolInfo) private poolInfos;
    
    address[] private poolList;
    mapping(string => address[]) private poolsByType;
    
    mapping(address => bool) private approvedAssets;
    
    address public admin;
    
    modifier onlyFactory() {
        require(msg.sender == factory, "Only factory can call");
        _;
    }
    
    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call");
        _;
    }
    
    constructor(address _factory, address _admin) {
        require(_admin != address(0), "Invalid admin");
        
        factory = _factory; // Can be address(0) initially
        admin = _admin;
    }
    
    function setFactory(address _factory) external onlyAdmin {
        require(_factory != address(0), "Invalid factory");
        factory = _factory;
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
        require(pool != address(0), "Invalid pool");
        require(poolInfos[pool].createdAt == 0, "Pool already registered");
        require(approvedAssets[info.asset], "Asset not approved");
        
        poolInfos[pool] = info;
        poolList.push(pool);
        poolsByType[info.instrumentType].push(pool);
        
        totalPools++;
        if (info.isActive) {
            activePools++;
        }
        
        emit PoolRegistered(pool, info.manager, info.asset, info.instrumentType, info.creator);
    }
    
    function updatePoolStatus(address pool, bool isActive) public override onlyAdmin {
        require(poolInfos[pool].createdAt != 0, "Pool not registered");
        
        bool wasActive = poolInfos[pool].isActive;
        poolInfos[pool].isActive = isActive;
        
        if (wasActive && !isActive) {
            activePools--;
        } else if (!wasActive && isActive) {
            activePools++;
        }
        
        emit PoolStatusUpdated(pool, isActive);
    }
    
    function updatePoolCategory(address pool, string memory newCategory) external override onlyAdmin {
        require(poolInfos[pool].createdAt != 0, "Pool not registered");
        
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
    
    function pausePool(address pool) external override onlyAdmin {
        updatePoolStatus(pool, false);
    }
    
    function unpausePool(address pool) external override onlyAdmin {
        updatePoolStatus(pool, true);
    }
    
    function emergencyDeactivatePool(address pool) external override onlyAdmin {
        updatePoolStatus(pool, false);
    }
    
    function approveAsset(address asset) external override onlyAdmin {
        require(asset != address(0), "Invalid asset");
        require(!approvedAssets[asset], "Asset already approved");
        
        approvedAssets[asset] = true;
        
        emit AssetApproved(asset);
    }
    
    function revokeAsset(address asset) external override onlyAdmin {
        require(approvedAssets[asset], "Asset not approved");
        
        approvedAssets[asset] = false;
        
        emit AssetRevoked(asset);
    }
    
    function isApprovedAsset(address asset) external view override returns (bool) {
        return approvedAssets[asset];
    }
} 