// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/IPoolFactory.sol";
import "../interfaces/IPoolRegistry.sol";
import "../interfaces/IManager.sol";
import "../types/IPoolTypes.sol";
import "../AccessManager.sol";
import "../PoolEscrow.sol";
import "../LiquidityPool.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract PoolFactory is Initializable, UUPSUpgradeable, IPoolFactory, ReentrancyGuardUpgradeable {
    
    bytes32 public constant POOL_CREATOR_ROLE = keccak256("POOL_CREATOR_ROLE");
    
    address public registry;
    address public manager; 
    uint256 public totalPoolsCreated;
    
    // Implementation contracts for proxies
    address public liquidityPoolImplementation;
    address public poolEscrowImplementation;
    
    AccessManager public accessManager;
    address public timelockController;
    uint256 public version;
    
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
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @notice Initialize the PoolFactory contract
     * @param _registry PoolRegistry contract address
     * @param _manager Manager contract address
     * @param _accessManager AccessManager contract address
     * @param _timelockController TimelockController contract address
     * @param _liquidityPoolImpl LiquidityPool implementation address
     * @param _poolEscrowImpl PoolEscrow implementation address
     */
    function initialize(
        address _registry,
        address _manager,
        address _accessManager,
        address _timelockController,
        address _liquidityPoolImpl,
        address _poolEscrowImpl
    ) public initializer {
        require(_registry != address(0) && _manager != address(0) && _accessManager != address(0), "Invalid addresses");
        require(_timelockController != address(0), "Invalid timelock controller");
        require(_liquidityPoolImpl != address(0), "Invalid pool implementation");
        require(_poolEscrowImpl != address(0), "Invalid escrow implementation");
        
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        registry = _registry;
        manager = _manager; 
        accessManager = AccessManager(_accessManager);
        timelockController = _timelockController;
        liquidityPoolImplementation = _liquidityPoolImpl;
        poolEscrowImplementation = _poolEscrowImpl;
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
        
        // Deploy PoolEscrow proxy
        bytes memory escrowInitData = abi.encodeWithSignature(
            "initialize(address,address,address,address)",
            config.asset,
            manager,
            config.spvAddress,
            timelockController
        );
        
        escrow = address(new ERC1967Proxy(
            poolEscrowImplementation,
            escrowInitData
        ));
        
        // Deploy LiquidityPool proxy
        bytes memory poolInitData = abi.encodeWithSignature(
            "initialize(address,string,string,address,address,address)",
            config.asset,
            string(abi.encodePacked("Piron Pool ", config.instrumentName)),
            string(abi.encodePacked("PIRON", totalPoolsCreated)),
            manager,
            escrow,
            timelockController
        );
        
        pool = address(new ERC1967Proxy(
            liquidityPoolImplementation,
            poolInitData
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
        
        IPoolManager(manager).initializePool(pool, IPoolTypes.PoolConfig({
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

    /**
     * @notice Update pool implementation for new pools
     * @param newPoolImpl New LiquidityPool implementation address
     * @dev Only affects NEW pools created after this update
     */
    function updatePoolImplementation(address newPoolImpl) external onlyRole(accessManager.EXECUTOR_ROLE()) {
        require(newPoolImpl != address(0), "Invalid implementation");
        require(IPoolRegistry(registry).isApprovedImplementation(newPoolImpl), "Implementation not approved");
        
        address oldImpl = liquidityPoolImplementation;
        liquidityPoolImplementation = newPoolImpl;
        
        emit PoolImplementationUpdated(oldImpl, newPoolImpl);
    }

    /**
     * @notice Update escrow implementation for new pools  
     * @param newEscrowImpl New PoolEscrow implementation address
     * @dev Only affects NEW pools created after this update
     */
    function updateEscrowImplementation(address newEscrowImpl) external onlyRole(accessManager.EXECUTOR_ROLE()) {
        require(newEscrowImpl != address(0), "Invalid implementation");
        require(IPoolRegistry(registry).isApprovedImplementation(newEscrowImpl), "Implementation not approved");
        
        address oldImpl = poolEscrowImplementation;
        poolEscrowImplementation = newEscrowImpl;
        
        emit EscrowImplementationUpdated(oldImpl, newEscrowImpl);
    }

    function _isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }
} 