// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IPoolRegistry {
    struct PoolInfo {
        address pool;
        address manager;
        address escrow;
        address asset;
        string instrumentType;
        uint256 createdAt;
        bool isActive;
        address creator;
        uint256 targetRaise;
        uint256 maturityDate;
    }
    
    event PoolRegistered(
        address indexed pool,
        address indexed manager,
        address indexed asset,
        string instrumentType,
        address creator
    );
    
    event PoolStatusUpdated(
        address indexed pool,
        bool isActive
    );
    
    event PoolCategoryUpdated(
        address indexed pool,
        string oldCategory,
        string newCategory
    );
    
    event AssetApproved(
        address indexed asset
    );
    
    event AssetRevoked(
        address indexed asset
    );
    
    function factory() external view returns (address);
    function totalPools() external view returns (uint256);
    function activePools() external view returns (uint256);
    
    function getPoolInfo(address pool) external view returns (PoolInfo memory);
    function isRegisteredPool(address pool) external view returns (bool);
    function isActivePool(address pool) external view returns (bool);
    
    function registerPool(address pool, PoolInfo memory info) external;
    function updatePoolStatus(address pool, bool isActive) external;
    function updatePoolCategory(address pool, string memory newCategory) external;
    
    function getActivePools() external view returns (address[] memory);
    function getAllPools() external view returns (address[] memory);
    function getPoolsByType(string memory instrumentType) external view returns (address[] memory);
    function getPoolsByMaturityRange(uint256 minMaturity, uint256 maxMaturity) external view returns (address[] memory);
    
    function getPoolCount() external view returns (uint256);
    function getPoolAtIndex(uint256 index) external view returns (address);
    
    function pausePool(address pool) external;
    function unpausePool(address pool) external;
    function emergencyDeactivatePool(address pool) external;
    
    function approveAsset(address asset) external;
    function revokeAsset(address asset) external;
    function isApprovedAsset(address asset) external view returns (bool);
} 