// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./IManager.sol";

interface IPoolFactory {
    event PoolCreated(
        address indexed pool,
        address indexed manager,
        address indexed asset,
        string instrumentName,
        uint256 targetRaise,
        uint256 maturityDate
    );
    
    struct PoolConfig {
        address asset;
        IPoolManager.InstrumentType instrumentType;
        string instrumentName;
        uint256 targetRaise;
        uint256 epochDuration;
        uint256 maturityDate;
        uint256 discountRate;
        address spvAddress;
        address[] multisigSigners;
        uint256[] couponDates;
        uint256[] couponRates;
    }
    
    function createPool(PoolConfig memory config) external returns (address pool, address escrow);
    function getPoolsByAsset(address asset) external view returns (address[] memory);
    function getPoolsByCreator(address creator) external view returns (address[] memory);
    function isValidPool(address pool) external view returns (bool);
    function setRegistry(address newRegistry) external;
} 