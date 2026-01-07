// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../types/IStableYieldTypes.sol";

/**
 * @title IPoolRegistry
 * @notice Interface for the central pool registry
 * @dev Manages registration of single-asset pools, stable yield pools, and locked pools
 */
interface IPoolRegistry {
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STRUCTS ////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    /// @notice Pool information for single-asset pools
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
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EVENTS /////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    // Single-asset pool events
    event PoolRegistered(
        address indexed pool,
        address indexed manager,
        address indexed asset,
        string instrumentType,
        address creator
    );
    
    event PoolStatusUpdated(address indexed pool, bool isActive);
    
    // StableYield pool events
    event StableYieldPoolRegistered(
        address indexed poolAddress,
        address indexed escrowAddress,
        address indexed asset,
        string name
    );
    event StableYieldPoolStatusUpdated(address indexed pool, bool isActive);
    
    // Locked pool events
    event LockedPoolRegistered(
        address indexed poolAddress,
        address indexed escrowAddress,
        address indexed asset,
        string name
    );
    event LockedPoolStatusUpdated(address indexed pool, bool isActive);
    
    // Asset events
    event AssetApproved(address indexed asset, string name, string symbol);
    event AssetRevoked(address indexed asset);
    event AssetMetadataUpdated(address indexed asset);
    
    // Admin events
    event FactoryUpdated(address indexed oldFactory, address indexed newFactory);
    event AccessManagerUpdated(address indexed oldAccessManager, address indexed newAccessManager);
    event ImplementationApproved(address indexed implementation);
    event ImplementationRevoked(address indexed implementation);

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// VIEW FUNCTIONS /////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function factory() external view returns (address);
    function totalPools() external view returns (uint256);
    function activePools() external view returns (uint256);
    
    // Single-asset pool queries
    function getPoolInfo(address pool) external view returns (PoolInfo memory);
    function isRegisteredPool(address pool) external view returns (bool);
    function isActivePool(address pool) external view returns (bool);
    function getPoolsByType(string memory instrumentType) external view returns (address[] memory);
    function getPoolCount() external view returns (uint256);
    function getPoolAtIndex(uint256 index) external view returns (address);
    
    // StableYield pool queries
    function isManagedPool(address pool) external view returns (bool);
    function getTotalStableYieldPools() external view returns (uint256);
    function getStableYieldPoolAtIndex(uint256 index) external view returns (address);
    function getManagedPoolAtIndex(uint256 index) external view returns (address);
    
    // Locked pool queries
    function isManagedLockedPool(address pool) external view returns (bool);
    function getLockedPoolAtIndex(uint256 index) external view returns (address);
    
    // Asset queries
    function isApprovedAsset(address asset) external view returns (bool);
    
    // Implementation queries
    function isApprovedImplementation(address implementation) external view returns (bool);

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// REGISTRATION ///////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function registerPool(address pool, PoolInfo memory info) external;
    function registerStableYieldPool(IStableYieldTypes.PoolData memory poolData) external;
    function registerLockedPool(
        address poolAddress,
        address escrowAddress,
        address asset,
        string memory name
    ) external;

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ADMIN FUNCTIONS ////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function updatePoolStatus(address pool, bool isActive) external;
    function pausePool(address pool) external;
    function unpausePool(address pool) external;
    function emergencyDeactivatePool(address pool) external;
    
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
