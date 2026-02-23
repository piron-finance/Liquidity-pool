// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/Manager.sol";
import "../src/PoolRegistry.sol";
import "../src/FeeManager.sol";
import "../src/factories/PoolFactory.sol";
import "../src/factories/ManagedPoolFactory.sol";
import "../src/StableYieldManager.sol";
import "../src/managed/StableYieldPool.sol";
import "../src/escrows/StableYieldEscrow.sol";
import "../src/LockedPoolManager.sol";
import "../src/managed/LockedPool.sol";
import "../src/escrows/LockedPoolEscrow.sol";
import "../src/escrows/YieldReserveEscrow.sol";
import "../src/AccessManager.sol";
import "../src/governance/TimelockController.sol" as PironTimelock;
import "../src/governance/UpgradeGuardian.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract DeployUpgradeable is Script {

    struct DeploymentConfig {
        address admin;
        address multisigAdmin;
        address proposer;
        address executor;
        address canceller;
        address guardian;
        address spv;
        address operator;
        address emergency;
        address treasury;
        address opsWallet;
        address baseToken;
        bool deployMockToken;
        uint256 roleDelay;
        uint256 defaultFeeBps;
        uint256 treasuryBps;
        uint256 minReserveFloor;
    }

    struct DeployedContracts {
        address accessManager;
        address timelockController;
        address upgradeGuardian;

        address managerImpl;
        address managerProxy;

        address poolRegistryImpl;
        address poolRegistryProxy;

        address poolFactoryImpl;
        address poolFactoryProxy;

        address liquidityPoolImpl;
        address poolEscrowImpl;

        address feeManagerImpl;
        address feeManagerProxy;

        address yieldReserveImpl;
        address yieldReserveProxy;

        address stableYieldManagerImpl;
        address stableYieldManagerProxy;
        address managedPoolFactoryImpl;
        address managedPoolFactoryProxy;
        address stableYieldPoolImpl;
        address stableYieldEscrowImpl;

        address lockedPoolManagerImpl;
        address lockedPoolManagerProxy;
        address lockedPoolImpl;
        address lockedPoolEscrowImpl;

        address baseToken;
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
        config.admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        config.multisigAdmin = vm.envOr("MULTISIG_ADMIN_ADDRESS", address(0));
        config.proposer = vm.envOr("PROPOSER_ADDRESS", msg.sender);
        config.executor = vm.envOr("EXECUTOR_ADDRESS", msg.sender);
        config.canceller = vm.envOr("CANCELLER_ADDRESS", msg.sender);
        config.guardian = vm.envOr("GUARDIAN_ADDRESS", msg.sender);
        config.spv = vm.envOr("SPV_ADDRESS", msg.sender);
        config.operator = vm.envOr("OPERATOR_ADDRESS", msg.sender);
        config.emergency = vm.envOr("EMERGENCY_ADDRESS", address(0));
        config.treasury = vm.envOr("TREASURY_ADDRESS", msg.sender);
        config.opsWallet = vm.envOr("OPS_WALLET_ADDRESS", msg.sender);
        config.baseToken = vm.envOr("BASE_TOKEN_ADDRESS", address(0));
        config.deployMockToken = vm.envOr("DEPLOY_MOCK_TOKEN", true);
        config.roleDelay = vm.envOr("ROLE_DELAY", uint256(24 hours));
        config.defaultFeeBps = vm.envOr("DEFAULT_FEE_BPS", uint256(300));
        config.treasuryBps = vm.envOr("TREASURY_BPS", uint256(5000));
        config.minReserveFloor = vm.envOr("MIN_RESERVE_FLOOR", uint256(100_000e6));

        require(config.admin != address(0), "Invalid admin address");
        require(config.multisigAdmin != address(0), "MULTISIG_ADMIN_ADDRESS env var required");
        require(config.multisigAdmin != config.admin, "Multisig admin must differ from admin");
        require(config.proposer != address(0), "Invalid proposer address");
        require(config.executor != address(0), "Invalid executor address");
        require(config.canceller != address(0), "Invalid canceller address");
        require(config.guardian != address(0), "Invalid guardian address");
        require(config.spv != address(0), "Invalid SPV address");
        require(config.operator != address(0), "Invalid operator address");
        require(config.emergency != address(0), "EMERGENCY_ADDRESS env var required");
        require(config.emergency != config.admin, "Emergency must differ from admin");
        require(config.treasury != address(0), "Invalid treasury address");
        require(config.opsWallet != address(0), "Invalid ops wallet address");
    }

    function _deployContracts(DeploymentConfig memory config) internal returns (DeployedContracts memory contracts) {
        console.log("=== DEPLOYING UPGRADEABLE CONTRACTS ===");

        if (config.deployMockToken) {
            contracts.baseToken = address(new ERC20Mock());
            console.log("MockERC20 deployed at: %s", contracts.baseToken);
            emit ContractDeployed("MockERC20", contracts.baseToken);
        } else {
            require(config.baseToken != address(0), "BASE_TOKEN_ADDRESS required when not deploying mock");
            contracts.baseToken = config.baseToken;
            console.log("Using existing token at: %s", contracts.baseToken);
        }

        contracts.accessManager = address(new AccessManager(
            config.admin,
            config.spv,
            config.operator,
            config.emergency,
            config.multisigAdmin
        ));
        console.log("AccessManager deployed at: %s", contracts.accessManager);
        emit ContractDeployed("AccessManager", contracts.accessManager);

        contracts.timelockController = address(new PironTimelock.PironTimelockController(
            config.admin,
            config.proposer,
            config.executor,
            config.canceller,
            config.admin
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

        PironTimelock.PironTimelockController(contracts.timelockController).updateGuardian(contracts.upgradeGuardian);
        console.log("TimelockController guardian updated to UpgradeGuardian");

        contracts.poolRegistryImpl = address(new PoolRegistry());
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

        contracts.yieldReserveImpl = address(new YieldReserveEscrow());
        bytes memory yieldReserveInitData = abi.encodeWithSignature(
            "initialize(address,address,address,uint256,uint256)",
            contracts.baseToken,
            contracts.accessManager,
            config.treasury,
            config.treasuryBps,
            config.minReserveFloor
        );
        contracts.yieldReserveProxy = address(new ERC1967Proxy(
            contracts.yieldReserveImpl,
            yieldReserveInitData
        ));
        console.log("YieldReserveEscrow proxy deployed at: %s", contracts.yieldReserveProxy);
        emit ProxyDeployed("YieldReserveEscrow", contracts.yieldReserveProxy, contracts.yieldReserveImpl);

        contracts.feeManagerImpl = address(new FeeManager());
        bytes memory feeManagerInitData = abi.encodeWithSignature(
            "initialize(address,address,address,address,address)",
            contracts.accessManager,
            contracts.poolRegistryProxy,
            contracts.yieldReserveProxy,
            config.treasury,
            config.opsWallet
        );
        contracts.feeManagerProxy = address(new ERC1967Proxy(
            contracts.feeManagerImpl,
            feeManagerInitData
        ));
        console.log("FeeManager proxy deployed at: %s", contracts.feeManagerProxy);
        emit ProxyDeployed("FeeManager", contracts.feeManagerProxy, contracts.feeManagerImpl);

        contracts.managerImpl = address(new Manager());
        bytes memory managerInitData = abi.encodeWithSignature(
            "initialize(address,address,address,address)",
            contracts.poolRegistryProxy,
            contracts.accessManager,
            contracts.timelockController,
            config.treasury
        );
        contracts.managerProxy = address(new ERC1967Proxy(
            contracts.managerImpl,
            managerInitData
        ));
        console.log("Manager proxy deployed at: %s", contracts.managerProxy);
        emit ProxyDeployed("Manager", contracts.managerProxy, contracts.managerImpl);

        contracts.liquidityPoolImpl = address(new LiquidityPool());
        emit ContractDeployed("LiquidityPoolImpl", contracts.liquidityPoolImpl);

        contracts.poolEscrowImpl = address(new PoolEscrow());
        emit ContractDeployed("PoolEscrowImpl", contracts.poolEscrowImpl);

        contracts.poolFactoryImpl = address(new PoolFactory());
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

        contracts.stableYieldManagerImpl = address(new StableYieldManager());
        bytes memory stableYieldManagerInitData = abi.encodeWithSignature(
            "initialize(address,address,address,uint256)",
            contracts.accessManager,
            contracts.poolRegistryProxy,
            contracts.timelockController,
            config.defaultFeeBps
        );
        contracts.stableYieldManagerProxy = address(new ERC1967Proxy(
            contracts.stableYieldManagerImpl,
            stableYieldManagerInitData
        ));
        console.log("StableYieldManager proxy deployed at: %s", contracts.stableYieldManagerProxy);
        emit ProxyDeployed("StableYieldManager", contracts.stableYieldManagerProxy, contracts.stableYieldManagerImpl);

        contracts.stableYieldPoolImpl = address(new StableYieldPool());
        emit ContractDeployed("StableYieldPoolImpl", contracts.stableYieldPoolImpl);

        contracts.stableYieldEscrowImpl = address(new StableYieldEscrow());
        emit ContractDeployed("StableYieldEscrowImpl", contracts.stableYieldEscrowImpl);

        contracts.managedPoolFactoryImpl = address(new ManagedPoolFactory());
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

        contracts.lockedPoolManagerImpl = address(new LockedPoolManager());
        bytes memory lockedPoolManagerInitData = abi.encodeWithSignature(
            "initialize(address,address,address)",
            contracts.accessManager,
            contracts.poolRegistryProxy,
            contracts.timelockController
        );
        contracts.lockedPoolManagerProxy = address(new ERC1967Proxy(
            contracts.lockedPoolManagerImpl,
            lockedPoolManagerInitData
        ));
        console.log("LockedPoolManager proxy deployed at: %s", contracts.lockedPoolManagerProxy);
        emit ProxyDeployed("LockedPoolManager", contracts.lockedPoolManagerProxy, contracts.lockedPoolManagerImpl);

        contracts.lockedPoolImpl = address(new LockedPool());
        emit ContractDeployed("LockedPoolImpl", contracts.lockedPoolImpl);

        contracts.lockedPoolEscrowImpl = address(new LockedPoolEscrow());
        emit ContractDeployed("LockedPoolEscrowImpl", contracts.lockedPoolEscrowImpl);
    }

    function _configureSystem(DeployedContracts memory contracts, DeploymentConfig memory config) internal {
        console.log("=== CONFIGURING SYSTEM ===");

        AccessManager accessMgr = AccessManager(contracts.accessManager);

        accessMgr.grantFactoryRoleDuringDeployment(contracts.managedPoolFactoryProxy);
        accessMgr.grantRoleDuringDeployment(accessMgr.POOL_CREATOR_ROLE(), contracts.managedPoolFactoryProxy);
        accessMgr.grantRoleDuringDeployment(accessMgr.POOL_CREATOR_ROLE(), contracts.stableYieldManagerProxy);
        accessMgr.grantRoleDuringDeployment(accessMgr.OPERATOR_ROLE(), contracts.stableYieldManagerProxy);
        accessMgr.grantRoleDuringDeployment(accessMgr.POOL_CREATOR_ROLE(), contracts.lockedPoolManagerProxy);
        accessMgr.grantRoleDuringDeployment(accessMgr.OPERATOR_ROLE(), contracts.lockedPoolManagerProxy);
        accessMgr.finalizeDeployment();
        console.log("Roles granted and deployment finalized");

        PoolRegistry registry = PoolRegistry(contracts.poolRegistryProxy);
        registry.setFactory(contracts.poolFactoryProxy);

        string memory tokenName = vm.envOr("BASE_TOKEN_NAME", string("USD Coin"));
        string memory tokenSymbol = vm.envOr("BASE_TOKEN_SYMBOL", string("USDC"));
        registry.approveAsset(contracts.baseToken, tokenName, tokenSymbol, true);
        console.log("Base token approved in registry");

        StableYieldManager(contracts.stableYieldManagerProxy).setManagedPoolFactory(contracts.managedPoolFactoryProxy);
        LockedPoolManager(contracts.lockedPoolManagerProxy).setManagedPoolFactory(contracts.managedPoolFactoryProxy);

        ManagedPoolFactory managedFactory = ManagedPoolFactory(contracts.managedPoolFactoryProxy);
        managedFactory.setLockedPoolManager(contracts.lockedPoolManagerProxy);
        managedFactory.updateLockedPoolImplementation(contracts.lockedPoolImpl);
        managedFactory.updateLockedPoolEscrowImplementation(contracts.lockedPoolEscrowImpl);
        managedFactory.setFeeManager(contracts.feeManagerProxy);
        managedFactory.setYieldReserve(contracts.yieldReserveProxy);
        console.log("ManagedPoolFactory configured with FeeManager and YieldReserve");

        Manager(contracts.managerProxy).setFeeManager(contracts.feeManagerProxy);
        console.log("Manager configured with FeeManager");

        YieldReserveEscrow yieldReserve = YieldReserveEscrow(contracts.yieldReserveProxy);
        yieldReserve.setLockedPoolManager(contracts.lockedPoolManagerProxy);
        yieldReserve.setStableYieldManager(contracts.stableYieldManagerProxy);
        console.log("YieldReserveEscrow configured with managers");

        StableYieldManager(contracts.stableYieldManagerProxy).setYieldReserve(contracts.yieldReserveProxy);
        LockedPoolManager(contracts.lockedPoolManagerProxy).setYieldReserve(contracts.yieldReserveProxy);
        console.log("Managers configured with YieldReserve");

        console.log("System configuration complete");
    }

    function _verifyDeployment(DeployedContracts memory contracts, DeploymentConfig memory config) internal view {
        console.log("=== VERIFYING DEPLOYMENT ===");

        require(Manager(contracts.managerProxy).version() == 1, "Manager version mismatch");
        require(PoolRegistry(contracts.poolRegistryProxy).version() == 1, "PoolRegistry version mismatch");
        require(PoolFactory(contracts.poolFactoryProxy).version() == 1, "PoolFactory version mismatch");
        require(StableYieldManager(contracts.stableYieldManagerProxy).version() == 1, "StableYieldManager version mismatch");
        require(ManagedPoolFactory(contracts.managedPoolFactoryProxy).version() == 1, "ManagedPoolFactory version mismatch");
        require(LockedPoolManager(contracts.lockedPoolManagerProxy).version() == 1, "LockedPoolManager version mismatch");
        require(FeeManager(contracts.feeManagerProxy).version() == 1, "FeeManager version mismatch");
        require(YieldReserveEscrow(contracts.yieldReserveProxy).version() == 1, "YieldReserveEscrow version mismatch");

        require(Manager(contracts.managerProxy).timelockController() == contracts.timelockController, "Manager timelock mismatch");
        require(StableYieldManager(contracts.stableYieldManagerProxy).timelockController() == contracts.timelockController, "StableYieldManager timelock mismatch");
        require(LockedPoolManager(contracts.lockedPoolManagerProxy).timelockController() == contracts.timelockController, "LockedPoolManager timelock mismatch");

        AccessManager accessManager = AccessManager(contracts.accessManager);
        require(accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), config.admin), "Admin role not granted");
        require(accessManager.hasRole(accessManager.SPV_ROLE(), config.spv), "SPV role not granted");
        require(accessManager.hasRole(accessManager.OPERATOR_ROLE(), config.operator), "Operator role not granted");
        require(accessManager.hasRole(accessManager.EMERGENCY_ROLE(), config.emergency), "Emergency role not granted");
        require(accessManager.hasRole(accessManager.POOL_CREATOR_ROLE(), config.admin), "Pool creator role not granted to admin");
        require(accessManager.hasRole(accessManager.FACTORY_ROLE(), contracts.managedPoolFactoryProxy), "Factory role not granted");
        require(accessManager.hasRole(accessManager.POOL_CREATOR_ROLE(), contracts.managedPoolFactoryProxy), "Pool creator not granted to factory");
        require(accessManager.hasRole(accessManager.POOL_CREATOR_ROLE(), contracts.stableYieldManagerProxy), "Pool creator not granted to SYM");
        require(accessManager.hasRole(accessManager.POOL_CREATOR_ROLE(), contracts.lockedPoolManagerProxy), "Pool creator not granted to LPM");
        require(accessManager.hasRole(accessManager.OPERATOR_ROLE(), contracts.lockedPoolManagerProxy), "Operator not granted to LPM");
        require(accessManager.deploymentComplete(), "Deployment not finalized");

        require(FeeManager(contracts.feeManagerProxy).treasury() == config.treasury, "FeeManager treasury mismatch");
        require(FeeManager(contracts.feeManagerProxy).yieldReserve() == contracts.yieldReserveProxy, "FeeManager yieldReserve mismatch");
        require(address(FeeManager(contracts.feeManagerProxy).poolRegistry()) == contracts.poolRegistryProxy, "FeeManager registry mismatch");

        require(YieldReserveEscrow(contracts.yieldReserveProxy).lockedPoolManager() == contracts.lockedPoolManagerProxy, "YieldReserve LPM mismatch");
        require(YieldReserveEscrow(contracts.yieldReserveProxy).stableYieldManager() == contracts.stableYieldManagerProxy, "YieldReserve SYM mismatch");

        require(StableYieldManager(contracts.stableYieldManagerProxy).yieldReserve() == contracts.yieldReserveProxy, "SYM yieldReserve not set");
        require(LockedPoolManager(contracts.lockedPoolManagerProxy).yieldReserve() == contracts.yieldReserveProxy, "LPM yieldReserve not set");

        PironTimelock.PironTimelockController timelock = PironTimelock.PironTimelockController(contracts.timelockController);
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), config.proposer), "Proposer role not granted");
        require(timelock.hasRole(timelock.EXECUTOR_ROLE(), config.executor), "Executor role not granted");

        console.log("All contracts verified successfully");
    }

    function _logDeploymentResults(DeployedContracts memory contracts, DeploymentConfig memory config) internal pure {
        console.log("=== DEPLOYMENT SUMMARY ===");
        console.log("Admin: %s", config.admin);
        console.log("Multisig Admin: %s", config.multisigAdmin);
        console.log("SPV: %s", config.spv);
        console.log("Operator: %s", config.operator);
        console.log("Treasury: %s", config.treasury);
        console.log("");
        console.log("=== GOVERNANCE ===");
        console.log("AccessManager: %s", contracts.accessManager);
        console.log("TimelockController: %s", contracts.timelockController);
        console.log("UpgradeGuardian: %s", contracts.upgradeGuardian);
        console.log("");
        console.log("=== CORE (UPGRADEABLE) ===");
        console.log("Manager Proxy: %s", contracts.managerProxy);
        console.log("PoolRegistry Proxy: %s", contracts.poolRegistryProxy);
        console.log("PoolFactory Proxy: %s", contracts.poolFactoryProxy);
        console.log("FeeManager Proxy: %s", contracts.feeManagerProxy);
        console.log("YieldReserveEscrow Proxy: %s", contracts.yieldReserveProxy);
        console.log("");
        console.log("=== STABLE YIELD (UPGRADEABLE) ===");
        console.log("StableYieldManager Proxy: %s", contracts.stableYieldManagerProxy);
        console.log("ManagedPoolFactory Proxy: %s", contracts.managedPoolFactoryProxy);
        console.log("");
        console.log("=== LOCKED POOL (UPGRADEABLE) ===");
        console.log("LockedPoolManager Proxy: %s", contracts.lockedPoolManagerProxy);
        console.log("");
        console.log("=== IMPLEMENTATIONS ===");
        console.log("LiquidityPool: %s", contracts.liquidityPoolImpl);
        console.log("PoolEscrow: %s", contracts.poolEscrowImpl);
        console.log("StableYieldPool: %s", contracts.stableYieldPoolImpl);
        console.log("StableYieldEscrow: %s", contracts.stableYieldEscrowImpl);
        console.log("LockedPool: %s", contracts.lockedPoolImpl);
        console.log("LockedPoolEscrow: %s", contracts.lockedPoolEscrowImpl);
        console.log("");
        console.log("=== TOKEN ===");
        console.log("Base Token: %s", contracts.baseToken);
        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
    }
}
