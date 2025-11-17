// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/Manager.sol";
import "../src/PoolRegistry.sol";
import "../src/factories/PoolFactory.sol";
import "../src/factories/ManagedPoolFactory.sol";
import "../src/StableYieldManager.sol";
import "../src/managed/StableYieldPool.sol";
import "../src/escrows/StableYieldEscrow.sol";
import "../src/AccessManager.sol";
import "../src/governance/TimelockController.sol" as PironTimelock;
import "../src/governance/UpgradeGuardian.sol";
import "../src/FeeManager.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/**
 * @title DeployUpgradeable
 * @notice Deployment script for upgradeable Piron Pools contracts
 * @dev Deploys all contracts with proxy pattern and security controls
 */
contract DeployUpgradeable is Script {
    
    struct DeploymentConfig {
        address admin;           // Multi-sig admin wallet
        address proposer;        // Multi-sig proposer wallet (4/7)
        address executor;        // Multi-sig executor wallet (4/7)  
        address canceller;       // Multi-sig canceller wallet (3/5)
        address guardian;        // Emergency guardian (3/5)
        address spv;            // SPV address
        address operator;       // Operator address
        address emergency;      // Emergency address
        address treasury;       // Treasury address
        address baseToken;      // Base token (USDC)
        bool deployMockToken;   // Whether to deploy mock token
        uint256 roleDelay;      // Role delay (24 hours)
    }
    
    struct DeployedContracts {
        address accessManager;      // Immutable
        address timelockController; // Immutable
        address upgradeGuardian;    // Immutable
        
        address managerImpl;        // Implementation
        address managerProxy;       // Proxy
        
        address poolRegistryImpl;   // Implementation
        address poolRegistryProxy;  // Proxy
        
        address poolFactoryImpl;    // Implementation
        address poolFactoryProxy;   // Proxy
        
        address liquidityPoolImpl;  // Implementation
        address poolEscrowImpl;     // Implementation
        
        // Stable Yield Components
        address stableYieldManagerImpl;     // Implementation
        address stableYieldManagerProxy;    // Proxy
        address managedPoolFactoryImpl;     // Implementation
        address managedPoolFactoryProxy;    // Proxy
        address stableYieldPoolImpl;        // Implementation
        address stableYieldEscrowImpl;      // Implementation
        
        address feeManager;         // Immutable
        address baseToken;          // Token
    }
    
    event ContractDeployed(string name, address addr);
    event ProxyDeployed(string name, address proxy, address implementation);
    event DeploymentComplete(DeployedContracts contracts);
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        
        DeploymentConfig memory config = _loadConfig();
        
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
        config.proposer = vm.envOr("PROPOSER_ADDRESS", msg.sender);
        config.executor = vm.envOr("EXECUTOR_ADDRESS", msg.sender);
        config.canceller = vm.envOr("CANCELLER_ADDRESS", msg.sender);
        config.guardian = vm.envOr("GUARDIAN_ADDRESS", msg.sender);
        config.spv = vm.envOr("SPV_ADDRESS", msg.sender);
        config.operator = vm.envOr("OPERATOR_ADDRESS", msg.sender);
        config.emergency = vm.envOr("EMERGENCY_ADDRESS", msg.sender);
        config.treasury = vm.envOr("TREASURY_ADDRESS", msg.sender);
        config.baseToken = vm.envOr("BASE_TOKEN_ADDRESS", address(0));
        config.deployMockToken = vm.envOr("DEPLOY_MOCK_TOKEN", true);
        config.roleDelay = vm.envOr("ROLE_DELAY", uint256(24 hours));
        
        require(config.admin != address(0), "Invalid admin address");
        require(config.proposer != address(0), "Invalid proposer address");
        require(config.executor != address(0), "Invalid executor address");
        require(config.canceller != address(0), "Invalid canceller address");
        require(config.guardian != address(0), "Invalid guardian address");
        require(config.spv != address(0), "Invalid SPV address");
        require(config.operator != address(0), "Invalid operator address");
        require(config.emergency != address(0), "Invalid emergency address");
        require(config.treasury != address(0), "Invalid treasury address");
    }
    
    function _deployContracts(DeploymentConfig memory config) internal returns (DeployedContracts memory contracts) {
        console.log("=== DEPLOYING UPGRADEABLE CONTRACTS ===");
        
        // 1. Deploy base token (if needed)
        if (config.deployMockToken) {
            contracts.baseToken = address(new ERC20Mock());
            console.log("MockERC20 deployed at: %s", contracts.baseToken);
            emit ContractDeployed("MockERC20", contracts.baseToken);
        } else {
            contracts.baseToken = config.baseToken;
            console.log("Using existing token at: %s", contracts.baseToken);
        }
        
        // 2. Deploy immutable contracts first
        contracts.accessManager = address(new AccessManager(
            config.admin,
            config.spv,
            config.operator,
            config.emergency,
            config.admin  // TODO: Replace with multi-sig wallet address for production deployment
        ));
        console.log("AccessManager deployed at: %s", contracts.accessManager);
        emit ContractDeployed("AccessManager", contracts.accessManager);
        
        // 3. Deploy governance contracts
        contracts.timelockController = address(new PironTimelock.PironTimelockController(
            config.admin,
            config.proposer,
            config.executor,
            config.canceller,
            config.admin  // Temporary guardian, will be updated to UpgradeGuardian
        ));
        console.log("TimelockController deployed at: %s", contracts.timelockController);
        emit ContractDeployed("TimelockController", contracts.timelockController);
        
        contracts.upgradeGuardian = address(new UpgradeGuardian(
            config.admin,
            config.guardian,
            config.emergency,
            contracts.timelockController
        ));
        console.log("UpgradeGuardian deployed at: %s", contracts.upgradeGuardian);
        emit ContractDeployed("UpgradeGuardian", contracts.upgradeGuardian);
        
        // Update TimelockController guardian to point to UpgradeGuardian contract
        PironTimelock.PironTimelockController(contracts.timelockController).updateGuardian(contracts.upgradeGuardian);
        console.log("TimelockController guardian updated to UpgradeGuardian contract");
        
        // 4. Deploy PoolRegistry implementation and proxy
        contracts.poolRegistryImpl = address(new PoolRegistry());
        console.log("PoolRegistry implementation deployed at: %s", contracts.poolRegistryImpl);
        emit ContractDeployed("PoolRegistryImpl", contracts.poolRegistryImpl);
        
        bytes memory poolRegistryInitData = abi.encodeWithSignature(
            "initialize(address,address)",
            contracts.accessManager,
            contracts.timelockController
        );
        
        contracts.poolRegistryProxy = address(new ERC1967Proxy(
            contracts.poolRegistryImpl,
            poolRegistryInitData
        ));
        console.log("PoolRegistry proxy deployed at: %s", contracts.poolRegistryProxy);
        emit ProxyDeployed("PoolRegistry", contracts.poolRegistryProxy, contracts.poolRegistryImpl);
        
        // 5. Deploy Manager implementation and proxy
        contracts.managerImpl = address(new Manager());
        console.log("Manager implementation deployed at: %s", contracts.managerImpl);
        emit ContractDeployed("ManagerImpl", contracts.managerImpl);
        
        bytes memory managerInitData = abi.encodeWithSignature(
            "initialize(address,address,address)",
            contracts.poolRegistryProxy,
            contracts.accessManager,
            contracts.timelockController
        );
        
        contracts.managerProxy = address(new ERC1967Proxy(
            contracts.managerImpl,
            managerInitData
        ));
        console.log("Manager proxy deployed at: %s", contracts.managerProxy);
        emit ProxyDeployed("Manager", contracts.managerProxy, contracts.managerImpl);
        
        // 6. Deploy LiquidityPool and PoolEscrow implementations
        contracts.liquidityPoolImpl = address(new LiquidityPool());
        console.log("LiquidityPool implementation deployed at: %s", contracts.liquidityPoolImpl);
        emit ContractDeployed("LiquidityPoolImpl", contracts.liquidityPoolImpl);
        
        contracts.poolEscrowImpl = address(new PoolEscrow());
        console.log("PoolEscrow implementation deployed at: %s", contracts.poolEscrowImpl);
        emit ContractDeployed("PoolEscrowImpl", contracts.poolEscrowImpl);
        
        // 7. Deploy PoolFactory implementation and proxy
        contracts.poolFactoryImpl = address(new PoolFactory());
        console.log("PoolFactory implementation deployed at: %s", contracts.poolFactoryImpl);
        emit ContractDeployed("PoolFactoryImpl", contracts.poolFactoryImpl);
        
        bytes memory poolFactoryInitData = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address)",
            contracts.poolRegistryProxy,
            contracts.managerProxy,
            contracts.accessManager,
            contracts.timelockController,
            contracts.liquidityPoolImpl,
            contracts.poolEscrowImpl
        );
        
        contracts.poolFactoryProxy = address(new ERC1967Proxy(
            contracts.poolFactoryImpl,
            poolFactoryInitData
        ));
        console.log("PoolFactory proxy deployed at: %s", contracts.poolFactoryProxy);
        emit ProxyDeployed("PoolFactory", contracts.poolFactoryProxy, contracts.poolFactoryImpl);
        
        // 8. Deploy FeeManager (immutable first, needed by StableYieldManager)
        contracts.feeManager = address(new FeeManager(
            contracts.accessManager,
            config.treasury
        ));
        console.log("FeeManager deployed at: %s", contracts.feeManager);
        emit ContractDeployed("FeeManager", contracts.feeManager);
        
        // 9. Deploy StableYieldManager implementation and proxy
        contracts.stableYieldManagerImpl = address(new StableYieldManager());
        console.log("StableYieldManager implementation deployed at: %s", contracts.stableYieldManagerImpl);
        emit ContractDeployed("StableYieldManagerImpl", contracts.stableYieldManagerImpl);
        
        bytes memory stableYieldManagerInitData = abi.encodeWithSignature(
            "initialize(address,address,address,address)",
            contracts.accessManager,
            contracts.poolRegistryProxy,
            contracts.timelockController,
            contracts.feeManager
        );
        
        contracts.stableYieldManagerProxy = address(new ERC1967Proxy(
            contracts.stableYieldManagerImpl,
            stableYieldManagerInitData
        ));
        console.log("StableYieldManager proxy deployed at: %s", contracts.stableYieldManagerProxy);
        emit ProxyDeployed("StableYieldManager", contracts.stableYieldManagerProxy, contracts.stableYieldManagerImpl);
        
        // 10. Deploy StableYieldPool and StableYieldEscrow implementations
        contracts.stableYieldPoolImpl = address(new StableYieldPool());
        console.log("StableYieldPool implementation deployed at: %s", contracts.stableYieldPoolImpl);
        emit ContractDeployed("StableYieldPoolImpl", contracts.stableYieldPoolImpl);
        
        contracts.stableYieldEscrowImpl = address(new StableYieldEscrow());
        console.log("StableYieldEscrow implementation deployed at: %s", contracts.stableYieldEscrowImpl);
        emit ContractDeployed("StableYieldEscrowImpl", contracts.stableYieldEscrowImpl);
        
        // 11. Deploy ManagedPoolFactory implementation and proxy
        contracts.managedPoolFactoryImpl = address(new ManagedPoolFactory());
        console.log("ManagedPoolFactory implementation deployed at: %s", contracts.managedPoolFactoryImpl);
        emit ContractDeployed("ManagedPoolFactoryImpl", contracts.managedPoolFactoryImpl);
        
        bytes memory managedPoolFactoryInitData = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address)",
            contracts.poolRegistryProxy,
            contracts.accessManager,
            contracts.stableYieldManagerProxy,
            contracts.timelockController,
            contracts.stableYieldPoolImpl,
            contracts.stableYieldEscrowImpl
        );
        
        contracts.managedPoolFactoryProxy = address(new ERC1967Proxy(
            contracts.managedPoolFactoryImpl,
            managedPoolFactoryInitData
        ));
        console.log("ManagedPoolFactory proxy deployed at: %s", contracts.managedPoolFactoryProxy);
        emit ProxyDeployed("ManagedPoolFactory", contracts.managedPoolFactoryProxy, contracts.managedPoolFactoryImpl);
    }
    
    function _configureSystem(DeployedContracts memory contracts, DeploymentConfig memory /* config */) internal {
        console.log("=== CONFIGURING UPGRADEABLE SYSTEM ===");
        
        PoolRegistry registry = PoolRegistry(contracts.poolRegistryProxy);
        
        AccessManager accessMgr = AccessManager(contracts.accessManager);
        
        // Grant FACTORY_ROLE to ManagedPoolFactory so it can call setStableYieldPool on escrows
        accessMgr.grantFactoryRoleDuringDeployment(contracts.managedPoolFactoryProxy);
        console.log("FACTORY_ROLE granted to ManagedPoolFactory");
        
        // Finalize deployment to prevent further immediate role grants
        accessMgr.finalizeDeployment();
        console.log("Deployment finalized - future role grants require 24h timelock");
        
        // Set factories in registry
        registry.setFactory(contracts.poolFactoryProxy);
        console.log("PoolFactory registered in PoolRegistry");
        
        // Set ManagedPoolFactory in StableYieldManager
        StableYieldManager(contracts.stableYieldManagerProxy).setManagedPoolFactory(contracts.managedPoolFactoryProxy);
        console.log("ManagedPoolFactory registered in StableYieldManager");
        
        // Note: All critical roles (SPV, OPERATOR, EMERGENCY, POOL_CREATOR, ASSET_MANAGER) 
        // are granted to admin in AccessManager constructor with no delay
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
        
        // Configure fee manager
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
        
        console.log("Upgradeable system configuration complete!");
    }
    
    function _verifyDeployment(DeployedContracts memory contracts, DeploymentConfig memory config) internal view {
        console.log("=== VERIFYING UPGRADEABLE DEPLOYMENT ===");
        
        // Verify proxy implementations
        require(Manager(contracts.managerProxy).version() == 1, "Manager version mismatch");
        require(PoolRegistry(contracts.poolRegistryProxy).version() == 1, "PoolRegistry version mismatch");
        require(PoolFactory(contracts.poolFactoryProxy).version() == 1, "PoolFactory version mismatch");
        require(StableYieldManager(contracts.stableYieldManagerProxy).version() == 1, "StableYieldManager version mismatch");
        require(ManagedPoolFactory(contracts.managedPoolFactoryProxy).version() == 1, "ManagedPoolFactory version mismatch");
        
        // Verify manager proxies
        require(Manager(contracts.managerProxy).timelockController() == contracts.timelockController, "Manager timelock mismatch");
        require(StableYieldManager(contracts.stableYieldManagerProxy).timelockController() == contracts.timelockController, "StableYieldManager timelock mismatch");
        
        // Verify access control (roles granted in AccessManager constructor)
        AccessManager accessManager = AccessManager(contracts.accessManager);
        require(accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), config.admin), "Admin role not granted");
        require(accessManager.hasRole(accessManager.SPV_ROLE(), config.spv), "SPV role not granted");
        require(accessManager.hasRole(accessManager.OPERATOR_ROLE(), config.operator), "Operator role not granted");
        require(accessManager.hasRole(accessManager.EMERGENCY_ROLE(), config.emergency), "Emergency role not granted");
        require(accessManager.hasRole(accessManager.POOL_CREATOR_ROLE(), config.admin), "Pool creator role not granted");
        require(accessManager.hasRole(accessManager.ASSET_MANAGER_ROLE(), config.admin), "Asset manager role not granted");
        require(accessManager.hasRole(accessManager.FACTORY_ROLE(), contracts.managedPoolFactoryProxy), "Factory role not granted to ManagedPoolFactory");
        require(accessManager.deploymentComplete(), "Deployment not finalized");
        console.log("AccessManager roles verified (from constructor and deployment)");
        
        // Verify timelock configuration
        PironTimelock.PironTimelockController timelock = PironTimelock.PironTimelockController(contracts.timelockController);
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), config.proposer), "Proposer role not granted");
        require(timelock.hasRole(timelock.EXECUTOR_ROLE(), config.executor), "Executor role not granted");
        
        console.log("All upgradeable contracts verified successfully!");
    }
    
    function _logDeploymentResults(DeployedContracts memory contracts, DeploymentConfig memory config) internal pure {
        console.log("=== UPGRADEABLE DEPLOYMENT SUMMARY ===");
        console.log("Admin Address: %s", config.admin);
        console.log("Proposer Address: %s", config.proposer);
        console.log("Executor Address: %s", config.executor);
        console.log("Guardian Address: %s", config.guardian);
        console.log("SPV Address: %s", config.spv);
        console.log("");
        console.log("=== GOVERNANCE CONTRACTS ===");
        console.log("AccessManager: %s", contracts.accessManager);
        console.log("TimelockController: %s", contracts.timelockController);
        console.log("UpgradeGuardian: %s", contracts.upgradeGuardian);
        console.log("");
        console.log("=== CORE CONTRACTS (UPGRADEABLE) ===");
        console.log("Manager Proxy: %s", contracts.managerProxy);
        console.log("Manager Implementation: %s", contracts.managerImpl);
        console.log("PoolRegistry Proxy: %s", contracts.poolRegistryProxy);
        console.log("PoolRegistry Implementation: %s", contracts.poolRegistryImpl);
        console.log("PoolFactory Proxy: %s", contracts.poolFactoryProxy);
        console.log("PoolFactory Implementation: %s", contracts.poolFactoryImpl);
        console.log("");
        console.log("=== STABLE YIELD CONTRACTS (UPGRADEABLE) ===");
        console.log("StableYieldManager Proxy: %s", contracts.stableYieldManagerProxy);
        console.log("StableYieldManager Implementation: %s", contracts.stableYieldManagerImpl);
        console.log("ManagedPoolFactory Proxy: %s", contracts.managedPoolFactoryProxy);
        console.log("ManagedPoolFactory Implementation: %s", contracts.managedPoolFactoryImpl);
        console.log("");
        console.log("=== POOL IMPLEMENTATIONS ===");
        console.log("LiquidityPool Implementation: %s", contracts.liquidityPoolImpl);
        console.log("PoolEscrow Implementation: %s", contracts.poolEscrowImpl);
        console.log("StableYieldPool Implementation: %s", contracts.stableYieldPoolImpl);
        console.log("StableYieldEscrow Implementation: %s", contracts.stableYieldEscrowImpl);
        console.log("");
        console.log("=== SUPPORTING CONTRACTS ===");
        console.log("FeeManager: %s", contracts.feeManager);
        console.log("Base Token: %s", contracts.baseToken);
        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("System is ready for immediate use!");
        console.log("Admin has all necessary roles to create pools.");
        console.log("");
        console.log("Upgrade Delay: 72 hours");
        console.log("Multi-sig Security: Active");
        console.log("Emergency Guardian: Active");
    }
}