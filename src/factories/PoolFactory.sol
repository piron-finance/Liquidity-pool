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
        require(_registry != address(0), "Invalid registry");
        require(_manager != address(0), "Invalid manager");
        require(_accessManager != address(0), "Invalid access manager");
        
        registry = _registry;
        manager = _manager; 
        accessManager = AccessManager(_accessManager);
    }
    
    function createPool(
        PoolConfig memory config
    ) external override onlyPoolCreator nonReentrant returns (address pool, address escrow) {
        require(config.asset != address(0), "Invalid asset");
        require(config.targetRaise > 0, "Invalid target raise");
        require(config.epochDuration > 0, "Invalid epoch duration");
        require(config.maturityDate > block.timestamp + config.epochDuration, "Invalid maturity date");
        require(config.spvAddress != address(0), "Invalid SPV address");
        require(config.multisigSigners.length >= 2, "Need at least 2 multisig signers");
        require(bytes(config.instrumentName).length > 0, "Instrument name required");
        
        // Validate multisig signers
        for (uint256 i = 0; i < config.multisigSigners.length; i++) {
            require(config.multisigSigners[i] != address(0), "Invalid multisig signer");
            // Check for duplicates
            for (uint256 j = i + 1; j < config.multisigSigners.length; j++) {
                require(config.multisigSigners[i] != config.multisigSigners[j], "Duplicate multisig signer");
            }
        }
        
        // Calculate required confirmations (minimum 2, maximum 75% of signers)
        uint256 requiredConfirmations = config.multisigSigners.length >= 3 ? 
            (config.multisigSigners.length * 3) / 4 : 2;
        if (requiredConfirmations < 2) requiredConfirmations = 2;
        
        // Create enterprise-grade escrow with multisig configuration
        escrow = address(new PoolEscrow(
            config.asset,
            manager,
            config.spvAddress,
            config.multisigSigners,
            requiredConfirmations
        ));
        
        // Create pool with unique name and symbol
        string memory poolName = string(abi.encodePacked("Piron Pool ", config.instrumentName));
        string memory poolSymbol = string(abi.encodePacked("PIRON-", _toString(totalPoolsCreated + 1)));
        
        pool = address(new LiquidityPool(
            IERC20(config.asset),
            poolName,
            poolSymbol,
            manager,
            escrow
        ));
        
        // Track pools
        poolsByAsset[config.asset].push(pool);
        poolsByCreator[msg.sender].push(pool);
        validPools[pool] = true;
        totalPoolsCreated++;
        
        // Register pool in registry
        IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
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
        });
        
        IPoolRegistry(registry).registerPool(pool, poolInfo);
        
        IPoolManager.PoolConfig memory managerConfig = IPoolManager.PoolConfig({
            instrumentType: config.instrumentType,
            faceValue: 0, 
            purchasePrice: config.targetRaise,
            targetRaise: config.targetRaise,
            epochEndTime: block.timestamp + config.epochDuration,
            maturityDate: config.maturityDate,
            couponDates: new uint256[](0),
            couponRates: new uint256[](0),
            refundGasFee: 0,
            discountRate: config.discountRate
        });
        
        IPoolManager(manager).initializePool(pool, managerConfig);
        
        emit PoolCreated(
            pool,
            manager, 
            config.asset,
            config.instrumentName,
            config.targetRaise,
            config.maturityDate
        );
        
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
    
    function setRegistry(address newRegistry) external override onlyRole(POOL_CREATOR_ROLE) {
        require(newRegistry != address(0), "Invalid registry");
        registry = newRegistry;
    }
    
    function setManager(address newManager) external onlyRole(POOL_CREATOR_ROLE) {
        require(newManager != address(0), "Invalid manager");
        manager = newManager;
    }
    
    function grantPoolCreatorRole(address account) external onlyRole(POOL_CREATOR_ROLE) {
        accessManager.grantRole(POOL_CREATOR_ROLE, account);
    }
    
    function revokePoolCreatorRole(address account) external onlyRole(POOL_CREATOR_ROLE) {
        accessManager.revokeRole(POOL_CREATOR_ROLE, account);
    }
    
    /**
     * @dev Calculate face value for discounted instruments
     * @param targetRaise Amount we want to raise from investors
     * @param discountRate Discount rate in basis points (e.g., 1800 = 18%)
     * @return faceValue The face value at maturity
     */
    function _calculateFaceValue(uint256 targetRaise, uint256 discountRate) internal pure returns (uint256) {
        // Face Value = Target Raise / (1 - discount rate)
        // For 18% discount: Face Value = 100,000 / (1 - 0.18) = 100,000 / 0.82 = 121,951
        require(discountRate < 10000, "Discount rate must be less than 100%");
        
        uint256 discountFactor = 10000 - discountRate; // e.g., 10000 - 1800 = 8200
        return (targetRaise * 10000) / discountFactor;
    }
    
    /**
     * @dev Convert uint256 to string
     */
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
} 