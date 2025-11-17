// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "../src/Manager.sol";
import "../src/LiquidityPool.sol";
import "../src/escrows/PoolEscrow.sol";
import "../src/AccessManager.sol";
import "../src/PoolRegistry.sol";
import "../src/factories/PoolFactory.sol";
import "../src/FeeManager.sol";
import "../src/interfaces/IFeeManager.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title PironPoolsDeployment

 */
contract PironPoolsDeployment is Script {
    
    struct DeploymentConfig {
        address admin;
        address spv;
        address operator;
        address emergency;
        address treasury;
        address baseToken;
        bool deployMockToken;
        uint256 roleDelay;
    }
    
    struct DeployedContracts {
        address accessManager;
        address poolRegistry;
        address manager;
        address poolFactory;
        address feeManager;
        address baseToken;
    }
    

    event ContractDeployed(string name, address addr);
    event SystemConfigured(address admin, address spv, address operator);
    event DeploymentComplete(DeployedContracts contracts);
    
    function run() external {
        DeploymentConfig memory config = _loadConfig();
        
        console.log("=== PIRON POOLS DEPLOYMENT ===");
        console.log("Network: %s", _getNetworkName());
        console.log("Deployer: %s", config.admin);
        console.log("SPV: %s", config.spv);
        console.log("Operator: %s", config.operator);
        console.log("Emergency: %s", config.emergency);
        console.log("Treasury: %s", config.treasury);
        console.log("");
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        
        DeployedContracts memory contracts = _deployContracts(config);
        
        _configureSystem(contracts, config);
        
        _verifyDeployment(contracts, config);
        
        vm.stopBroadcast();
        
        _logDeploymentResults(contracts, config);
        
        emit DeploymentComplete(contracts);
    }
    
    function _loadConfig() internal view returns (DeploymentConfig memory config) {
        // Load from environment variables with defaults
        config.admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        config.spv = vm.envOr("SPV_ADDRESS", msg.sender);
        config.operator = vm.envOr("OPERATOR_ADDRESS", msg.sender);
        config.emergency = vm.envOr("EMERGENCY_ADDRESS", msg.sender);
        config.treasury = vm.envOr("TREASURY_ADDRESS", msg.sender);
        config.baseToken = vm.envOr("BASE_TOKEN_ADDRESS", address(0));
        config.deployMockToken = vm.envOr("DEPLOY_MOCK_TOKEN", true);
        config.roleDelay = vm.envOr("ROLE_DELAY", uint256(24 hours));
        
        require(config.admin != address(0), "Invalid admin address");
        require(config.spv != address(0), "Invalid SPV address");
        require(config.operator != address(0), "Invalid operator address");
        require(config.emergency != address(0), "Invalid emergency address");
        require(config.treasury != address(0), "Invalid treasury address");
        
        // If no base token address provided and not deploying mock, revert
        if (config.baseToken == address(0) && !config.deployMockToken) {
            revert("Must provide base token address or enable mock deployment");
        }
    }
    
    function _deployContracts(DeploymentConfig memory config) 
        internal 
        returns (DeployedContracts memory contracts) 
    {
        console.log("=== DEPLOYING CONTRACTS ===");
        
        if (config.deployMockToken) {
            contracts.baseToken = address(new MockERC20());
            console.log("MockERC20 deployed at: %s", contracts.baseToken);
            emit ContractDeployed("MockERC20", contracts.baseToken);
        } else {
            contracts.baseToken = config.baseToken;
            console.log("Using existing token at: %s", contracts.baseToken);
        }
        
        contracts.accessManager = address(new AccessManager(
            config.admin,
            config.spv,
            config.operator,
            config.emergency,
            config.admin  // TODO: Replace with multi-sig wallet address for production deployment
        ));
        console.log("AccessManager deployed at: %s", contracts.accessManager);
        emit ContractDeployed("AccessManager", contracts.accessManager);
        
        contracts.poolRegistry = address(new PoolRegistry());
        console.log("PoolRegistry deployed at: %s", contracts.poolRegistry);
        emit ContractDeployed("PoolRegistry", contracts.poolRegistry);
        
        contracts.manager = address(new Manager());
        console.log("Manager deployed at: %s", contracts.manager);
        emit ContractDeployed("Manager", contracts.manager);
        
        contracts.poolFactory = address(new PoolFactory());
        console.log("PoolFactory deployed at: %s", contracts.poolFactory);
        emit ContractDeployed("PoolFactory", contracts.poolFactory);
        
        contracts.feeManager = address(new FeeManager(contracts.accessManager, config.treasury));
        console.log("FeeManager deployed at: %s", contracts.feeManager);
        emit ContractDeployed("FeeManager", contracts.feeManager);
        
        console.log("All contracts deployed successfully!");
        console.log("");
    }
    
    function _configureSystem(DeployedContracts memory contracts, DeploymentConfig memory config) internal {
        console.log("=== CONFIGURING SYSTEM ===");
        
        PoolRegistry registry = PoolRegistry(contracts.poolRegistry);
        
        registry.setFactory(contracts.poolFactory);
        console.log("Factory set in registry");
        
        // Note: POOL_CREATOR_ROLE and ASSET_MANAGER_ROLE are granted to admin in AccessManager constructor
        console.log("Admin roles (POOL_CREATOR, ASSET_MANAGER) granted at deployment");
        
        // Approve stablecoin assets
        registry.approveAsset(
            contracts.baseToken,
            "Mock USDC",
            "USDC",
            "US",
            "Americas",
            true
        );
        console.log("USDC approved as valid asset");
        
        // Approve cNGN (Nigerian Naira stablecoin) - Base testnet address
        registry.approveAsset(
            0x929A08903C22440182646Bb450a67178Be402f7f,
            "Canza Nigerian Naira",
            "cNGN",
            "NG",
            "Africa",
            true
        );
        console.log("cNGN approved as valid asset");
        
        // TODO: Add USDT address when available for this network
        console.log("NOTE: Add USDT approval before mainnet deployment");
        
        FeeManager feeManager = FeeManager(contracts.feeManager);
        IFeeManager.FeeConfig memory feeConfig = IFeeManager.FeeConfig({
            protocolFee: 0,          // 0% protocol fee (reserved for future use)
            spvFee: 100,            // 1.0% SPV fee
            managementFee: 200,     // 2.0% annual management fee
            performanceFee: 0,      // 0% performance fee (reserved for future use)
            earlyWithdrawalFee: 100, // 1.0% early withdrawal fee
            refundGasFee: 10,       // 0.1% refund gas fee
            isActive: true
        });
        feeManager.setDefaultFeeConfig(feeConfig);
        console.log("Default fee configuration set");
        
        console.log("System configuration complete!");
        console.log("");
        
        emit SystemConfigured(config.admin, config.spv, config.operator);
    }
    
    function _verifyDeployment(DeployedContracts memory contracts, DeploymentConfig memory config) internal view {
        console.log("=== VERIFYING DEPLOYMENT ===");
        AccessManager accessManager = AccessManager(contracts.accessManager);
        require(accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), config.admin), "Admin role not set");
        require(accessManager.hasRole(accessManager.SPV_ROLE(), config.spv), "SPV role not set");
        require(accessManager.hasRole(accessManager.OPERATOR_ROLE(), config.operator), "Operator role not set");
        require(accessManager.hasRole(accessManager.EMERGENCY_ROLE(), config.emergency), "Emergency role not set");
        require(accessManager.hasRole(accessManager.POOL_CREATOR_ROLE(), config.admin), "Pool creator role not set");
        require(accessManager.hasRole(accessManager.ASSET_MANAGER_ROLE(), config.admin), "Asset manager role not set");
        console.log("AccessManager roles verified (from constructor)");

        PoolRegistry registry = PoolRegistry(contracts.poolRegistry);
        require(registry.factory() == contracts.poolFactory, "Factory not set in registry");
        require(registry.isApprovedAsset(contracts.baseToken), "Base token not approved");
        console.log("PoolRegistry configuration verified");
        
        Manager manager = Manager(contracts.manager);
        require(address(manager.registry()) == contracts.poolRegistry, "Manager registry not set");
        require(address(manager.accessManager()) == contracts.accessManager, "Manager access manager not set");
        console.log("Manager configuration verified");
        
        PoolFactory factory = PoolFactory(contracts.poolFactory);
        require(factory.registry() == contracts.poolRegistry, "Factory registry not set");
        require(factory.manager() == contracts.manager, "Factory manager not set");
        console.log("PoolFactory configuration verified");
        
        FeeManager feeManager = FeeManager(contracts.feeManager);
        require(address(feeManager.accessManager()) == contracts.accessManager, "FeeManager access manager not set");
        console.log("FeeManager configuration verified");
        
        console.log("All verifications passed!");
        console.log("");
    }
    
    function _logDeploymentResults(DeployedContracts memory contracts, DeploymentConfig memory config) internal view {
        console.log("=== DEPLOYMENT RESULTS ===");
        console.log("Network: %s", _getNetworkName());
        console.log("");
        console.log("CORE CONTRACTS:");
        console.log("AccessManager: %s", contracts.accessManager);
        console.log("PoolRegistry:  %s", contracts.poolRegistry);
        console.log("Manager:       %s", contracts.manager);
        console.log("PoolFactory:   %s", contracts.poolFactory);
        console.log("FeeManager:    %s", contracts.feeManager);
        console.log("");
        console.log("ASSETS:");
        console.log("Base Token:    %s", contracts.baseToken);
        console.log("");
        console.log("ROLES:");
        console.log("Admin:         %s", config.admin);
        console.log("SPV:           %s", config.spv);
        console.log("Operator:      %s", config.operator);
        console.log("Emergency:     %s", config.emergency);
        console.log("Treasury:      %s", config.treasury);
        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("System is ready for immediate use!");
        console.log("Admin has all necessary roles to create pools.");
        console.log("");
    }
    
    function _getNetworkName() internal view returns (string memory) {
        uint256 chainId = block.chainid;
        
        if (chainId == 1) return "Mainnet";
        if (chainId == 17000) return "Holesky";
        if (chainId == 84532) return "Base sepolia";
        if (chainId == 2810) return "Morph Holesky";
        
        return "Unknown";
    }
}

/**
 * @title MockERC20
 * @dev Mock ERC20 token for testing purposes
 */
contract MockERC20 is ERC20 {
    constructor() ERC20("CNGN", "CNGN") {
        _mint(msg.sender, 10_000_000 * 1e6);
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function decimals() public pure override returns (uint8) {
        return 6;
    }
} 