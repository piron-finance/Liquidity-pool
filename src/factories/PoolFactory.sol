// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IPoolFactory.sol";
import "../interfaces/IPoolRegistry.sol";
import "../interfaces/IManager.sol";
import "../AccessManager.sol";
import "../PoolEscrow.sol";
import "../LiquidityPool.sol";

contract PoolFactory is IPoolFactory, ReentrancyGuard {
    
    bytes32 public constant POOL_CREATOR_ROLE = keccak256("POOL_CREATOR_ROLE");
    
    address public registry;
    address public manager; 
    uint256 public totalPoolsCreated;
    
    AccessManager public accessManager;
    
    mapping(address => address[]) public poolsByAsset;
    mapping(address => address[]) public poolsByCreator;
    mapping(address => bool) public validPools;
    
    modifier onlyRole(bytes32 role) {
        require(accessManager.hasRole(role, msg.sender), "PoolFactory/access-denied");
        _;
    }
    
    modifier onlyPoolCreator() {
        require(
            accessManager.hasRole(POOL_CREATOR_ROLE, msg.sender) || 
            accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), msg.sender), 
            "PoolFactory/not-authorized"
        );
        _;
    }
    
    constructor(
        address _registry,
        address _manager,
        address _accessManager
    ) {
        require(_registry != address(0) && _manager != address(0) && _accessManager != address(0), "Invalid addresses");
        
        registry = _registry;
        manager = _manager; 
        accessManager = AccessManager(_accessManager);
    }
    
    function createPool(
        PoolConfig memory config
    ) external override onlyPoolCreator nonReentrant returns (address pool, address escrow) {
        require(
            config.asset != address(0) &&
            config.targetRaise > 0 &&
            config.epochDuration > 0 &&
            config.spvAddress != address(0) &&
            bytes(config.instrumentName).length > 0,
            "Invalid config"
        );
        require(config.maturityDate > block.timestamp + config.epochDuration, "Invalid maturity");
        
        escrow = address(new PoolEscrow(config.asset, manager, config.spvAddress));
        
        pool = address(new LiquidityPool(
            IERC20(config.asset),
            string(abi.encodePacked("Piron Pool ", config.instrumentName)),
            string(abi.encodePacked("PIRON", totalPoolsCreated)),
            manager,
            escrow
        ));
        
        poolsByAsset[config.asset].push(pool);
        poolsByCreator[msg.sender].push(pool);
        validPools[pool] = true;
        totalPoolsCreated++;
        
        IPoolRegistry(registry).registerPool(pool, IPoolRegistry.PoolInfo({
            pool: pool,
            manager: manager,
            escrow: escrow,
            asset: config.asset,
            instrumentType: config.instrumentName,
            createdAt: block.timestamp,
            isActive: true,
            creator: msg.sender,
            targetRaise: config.targetRaise,
            maturityDate: config.maturityDate
        }));
        
        IPoolManager(manager).initializePool(pool, IPoolManager.PoolConfig({
            instrumentType: config.instrumentType,
            faceValue: 0, 
            purchasePrice: config.targetRaise,
            targetRaise: config.targetRaise,
            epochEndTime: block.timestamp + config.epochDuration,
            maturityDate: config.maturityDate,
            couponDates: config.couponDates,
            couponRates: config.couponRates,
            refundGasFee: 0,
            discountRate: config.discountRate
        }));
        
        emit PoolCreated(pool, manager, config.asset, config.instrumentName, config.targetRaise, config.maturityDate);
        
        return (pool, escrow);
    }
    
    function getPoolsByAsset(address asset) external view override returns (address[] memory) {
        return poolsByAsset[asset];
    }
    
    function getPoolsByCreator(address creator) external view override returns (address[] memory) {
        return poolsByCreator[creator];
    }
    
    function isValidPool(address pool) external view override returns (bool) {
        return validPools[pool];
    }
    
    function setRegistry(address newRegistry) external override onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(newRegistry != address(0), "Invalid registry");
        registry = newRegistry;
    }
    
    function setManager(address newManager) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(newManager != address(0), "Invalid manager");
        manager = newManager;
    }
} 