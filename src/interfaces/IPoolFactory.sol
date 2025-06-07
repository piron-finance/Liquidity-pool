// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IPoolFactory {
    struct PoolConfig {
        address asset;
        string instrumentType;
        string instrumentDetails;
        uint256 targetRaise;
        uint256 epochDuration;
        uint256 expectedReturn;
        uint256 maturityDate;
        address spvAddress;
        address[] multisigSigners;
    }
    
    event PoolCreated(
        address indexed pool,
        address indexed manager,
        address indexed asset,
        string instrumentType,
        uint256 targetRaise,
        uint256 maturityDate
    );
    
    event ImplementationUpdated(
        address oldPoolImpl,
        address newPoolImpl,
        address oldManagerImpl,
        address newManagerImpl
    );
    
    function poolImplementation() external view returns (address);
    function managerImplementation() external view returns (address);
    function registry() external view returns (address);
    function totalPoolsCreated() external view returns (uint256);
    
    function createPool(PoolConfig memory config) external returns (address pool, address manager);
    function getPoolsByAsset(address asset) external view returns (address[] memory);
    function getPoolsByCreator(address creator) external view returns (address[] memory);
    function isValidPool(address pool) external view returns (bool);
    
    function setImplementations(address poolImpl, address managerImpl) external;
    function setRegistry(address newRegistry) external;
} 