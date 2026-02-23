// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../types/IStableYieldTypes.sol";

/// @title IPoolRegistry
/// @dev Central registry for all pool types: deal pools, stable-yield pools, and locked pools.
///      Also manages asset approvals, implementation approvals, and pool status updates.
interface IPoolRegistry {

    // ==================== STRUCTS ====================
    
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
    
    // ==================== EVENTS ====================

    event PoolRegistered(
        address indexed pool,
        address indexed manager,
        address indexed asset,
        string instrumentType,
        address creator
    );
    
    event PoolStatusUpdated(address indexed pool, bool isActive);
    
    event StableYieldPoolRegistered(
        address indexed poolAddress,
        address indexed escrowAddress,
        address indexed asset,
        string name
    );
    event StableYieldPoolStatusUpdated(address indexed pool, bool isActive);
    
    event LockedPoolRegistered(
        address indexed poolAddress,
        address indexed escrowAddress,
        address indexed asset,
        string name
    );
    event LockedPoolStatusUpdated(address indexed pool, bool isActive);
    
    event AssetApproved(address indexed asset, string name, string symbol);
    event AssetRevoked(address indexed asset);
    event AssetMetadataUpdated(address indexed asset);
    
    event FactoryUpdated(address indexed oldFactory, address indexed newFactory);
    event AccessManagerUpdated(address indexed oldAccessManager, address indexed newAccessManager);
    event ImplementationApproved(address indexed implementation);
    event ImplementationRevoked(address indexed implementation);
    
    event SPVApproved(address indexed spv, uint256 approvedAt);
    event SPVRevoked(address indexed spv);

    // ==================== VIEW FUNCTIONS ====================

    function factory() external view returns (address);
    function totalPools() external view returns (uint256);
    function activePools() external view returns (uint256);
    
    function getPoolInfo(address pool) external view returns (PoolInfo memory);
    function isRegisteredPool(address pool) external view returns (bool);
    function isActivePool(address pool) external view returns (bool);
    function getPoolsByType(string memory instrumentType) external view returns (address[] memory);
    function getPoolCount() external view returns (uint256);
    function getPoolAtIndex(uint256 index) external view returns (address);
    
    function isManagedPool(address pool) external view returns (bool);
    function getTotalStableYieldPools() external view returns (uint256);
    function getStableYieldPoolAtIndex(uint256 index) external view returns (address);
    function getManagedPoolAtIndex(uint256 index) external view returns (address);
    
    function isManagedLockedPool(address pool) external view returns (bool);
    function getLockedPoolAtIndex(uint256 index) external view returns (address);
    
    function isApprovedAsset(address asset) external view returns (bool);
    
    function isApprovedImplementation(address implementation) external view returns (bool);

    // ==================== REGISTRATION ====================

    function registerPool(address pool, PoolInfo memory info) external;
    function registerStableYieldPool(IStableYieldTypes.PoolData memory poolData) external;
    function registerLockedPool(
        address poolAddress,
        address escrowAddress,
        address asset,
        string memory name
    ) external;

    // ==================== POOL MANAGEMENT ====================

    function updatePoolStatus(address pool, bool isActive) external;
    function pausePool(address pool) external;
    function unpausePool(address pool) external;
    function emergencyDeactivatePool(address pool) external;
    
    // ==================== ASSET / IMPLEMENTATION MANAGEMENT ====================

    function approveAsset(
        address asset,
        string memory name,
        string memory symbol,
        bool isStablecoin
    ) external;
    function revokeAsset(address asset) external;
    
    function approveImplementation(address implementation) external;
    function revokeImplementation(address implementation) external;
}
