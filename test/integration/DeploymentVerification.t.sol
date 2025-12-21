// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../fixtures/BaseTest.sol";
import "../../src/AccessManager.sol";
import "../../src/PoolRegistry.sol";
import "../../src/Manager.sol";
import "../../src/StableYieldManager.sol";
import "../../src/factories/PoolFactory.sol";
import "../../src/factories/ManagedPoolFactory.sol";
import "../../src/FeeManager.sol";
import "../../src/LiquidityPool.sol";
import "../../src/managed/StableYieldPool.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeploymentVerification
 * @notice Tests that EXACTLY mirror the deployment script flow
 * @dev These tests ensure deployment script grants all necessary roles and configurations
 * 
 * CRITICAL: These tests should fail if deployment script is incomplete
 */
contract DeploymentVerification is BaseTest {
    
    AccessManager public accessMgr;
    PoolRegistry public registry;
    Manager public manager;
    StableYieldManager public stableYieldMgr;
    PoolFactory public poolFactory;
    ManagedPoolFactory public managedFactory;
    FeeManager public feeManager;
    MockERC20 public asset;
    
    address public timelockController;
    
    function setUp() public override {
        super.setUp();
        
        // Deploy EXACTLY as deployment script does
        _deploySystem();
        _configureSystem();
    }
    
    function _deploySystem() internal {
        vm.startPrank(admin);
        
        // 0. Deploy test asset
        asset = new MockERC20("Test Token", "TEST", 6);
        
        // 1. Deploy AccessManager
        accessMgr = new AccessManager(admin, spv, operator, emergency, admin);
        
        // 2. Deploy timelock (mock for test)
        timelockController = makeAddr("timelock");
        
        // 3. Deploy PoolRegistry
        PoolRegistry registryImpl = new PoolRegistry();
        bytes memory registryInitData = abi.encodeWithSignature(
            "initialize(address,address)",
            address(accessMgr),
            timelockController
        );
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryInitData);
        registry = PoolRegistry(address(registryProxy));
        
        // 4. Deploy Manager
        Manager managerImpl = new Manager();
        bytes memory managerInitData = abi.encodeWithSignature(
            "initialize(address,address,address)",
            address(accessMgr),
            address(registry),
            timelockController
        );
        ERC1967Proxy managerProxy = new ERC1967Proxy(address(managerImpl), managerInitData);
        manager = Manager(address(managerProxy));
        
        // 5. Deploy FeeManager
        feeManager = new FeeManager(address(accessMgr), treasury);
        
        // 6. Deploy StableYieldManager
        StableYieldManager stableYieldMgrImpl = new StableYieldManager();
        bytes memory stableYieldInitData = abi.encodeWithSignature(
            "initialize(address,address,address,address)",
            address(accessMgr),
            address(registry),
            timelockController,
            address(feeManager)
        );
        ERC1967Proxy stableYieldProxy = new ERC1967Proxy(address(stableYieldMgrImpl), stableYieldInitData);
        stableYieldMgr = StableYieldManager(address(stableYieldProxy));
        
        // 7. Deploy PoolFactory
        PoolFactory poolFactoryImpl = new PoolFactory();
        LiquidityPool poolImpl = new LiquidityPool();
        PoolEscrow escrowImpl = new PoolEscrow();
        
        bytes memory poolFactoryInitData = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address)",
            address(registry),
            address(accessMgr),
            address(manager),
            timelockController,
            address(poolImpl),
            address(escrowImpl)
        );
        ERC1967Proxy poolFactoryProxy = new ERC1967Proxy(address(poolFactoryImpl), poolFactoryInitData);
        poolFactory = PoolFactory(address(poolFactoryProxy));
        
        // 8. Deploy ManagedPoolFactory
        ManagedPoolFactory managedFactoryImpl = new ManagedPoolFactory();
        StableYieldPool stablePoolImpl = new StableYieldPool();
        StableYieldEscrow stableEscrowImpl = new StableYieldEscrow();
        
        bytes memory managedFactoryInitData = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address)",
            address(registry),
            address(accessMgr),
            address(stableYieldMgr),
            timelockController,
            address(stablePoolImpl),
            address(stableEscrowImpl)
        );
        ERC1967Proxy managedFactoryProxy = new ERC1967Proxy(address(managedFactoryImpl), managedFactoryInitData);
        managedFactory = ManagedPoolFactory(address(managedFactoryProxy));
        
        vm.stopPrank();
    }
    
    function _configureSystem() internal {
        // EXACTLY mirror deployment script configuration
        vm.startPrank(admin);
        
        // Grant FACTORY_ROLE to ManagedPoolFactory
        accessMgr.grantFactoryRoleDuringDeployment(address(managedFactory));
        
        // Grant POOL_CREATOR_ROLE to StableYieldManager
        accessMgr.grantRoleDuringDeployment(accessMgr.POOL_CREATOR_ROLE(), address(stableYieldMgr));
        
        // Grant OPERATOR_ROLE to StableYieldManager
        accessMgr.grantRoleDuringDeployment(accessMgr.OPERATOR_ROLE(), address(stableYieldMgr));
        
        // Finalize deployment
        accessMgr.finalizeDeployment();
        
        // Set factory in registry
        registry.setFactory(address(poolFactory));
        
        // Set ManagedPoolFactory in StableYieldManager
        stableYieldMgr.setManagedPoolFactory(address(managedFactory));
        
        // Set managers in FeeManager
        feeManager.setManagers(address(manager), address(stableYieldMgr), address(registry));
        
        // Approve test asset
        registry.approveAsset(address(asset), "Test Asset", "TEST", "NG", "Test", true);
        
        vm.stopPrank();
    }
    
    /**
     * @notice TEST 1: Verify all critical roles are granted after deployment
     */
    function test_deployment_allRolesGranted() public {
        console.log("\n=== TEST: Deployment Role Verification ===");
        
        // Admin should have all roles except SPV
        assertTrue(accessMgr.hasRole(accessMgr.DEFAULT_ADMIN_ROLE(), admin), "Admin missing DEFAULT_ADMIN_ROLE");
        assertTrue(accessMgr.hasRole(accessMgr.OPERATOR_ROLE(), admin), "Admin missing OPERATOR_ROLE");
        assertTrue(accessMgr.hasRole(accessMgr.EMERGENCY_ROLE(), admin), "Admin missing EMERGENCY_ROLE");
        assertTrue(accessMgr.hasRole(accessMgr.POOL_CREATOR_ROLE(), admin), "Admin missing POOL_CREATOR_ROLE");
        assertTrue(accessMgr.hasRole(accessMgr.ASSET_MANAGER_ROLE(), admin), "Admin missing ASSET_MANAGER_ROLE");
        
        // ManagedPoolFactory should have FACTORY_ROLE
        assertTrue(accessMgr.hasRole(accessMgr.FACTORY_ROLE(), address(managedFactory)), "ManagedPoolFactory missing FACTORY_ROLE");
        
        // StableYieldManager should have POOL_CREATOR_ROLE and OPERATOR_ROLE
        assertTrue(accessMgr.hasRole(accessMgr.POOL_CREATOR_ROLE(), address(stableYieldMgr)), "StableYieldManager missing POOL_CREATOR_ROLE");
        assertTrue(accessMgr.hasRole(accessMgr.OPERATOR_ROLE(), address(stableYieldMgr)), "StableYieldManager missing OPERATOR_ROLE");
        
        // Deployment should be finalized
        assertTrue(accessMgr.deploymentComplete(), "Deployment not finalized");
        
        console.log("  All roles verified!");
    }
    
    /**
     * @notice TEST 2: Verify all factory registrations
     */
    function test_deployment_factoriesRegistered() public {
        console.log("\n=== TEST: Factory Registration Verification ===");
        
        // PoolFactory should be registered in PoolRegistry
        assertEq(registry.factory(), address(poolFactory), "PoolFactory not registered in PoolRegistry");
        
        // ManagedPoolFactory should be set in StableYieldManager
        assertEq(stableYieldMgr.managedPoolFactory(), address(managedFactory), "ManagedPoolFactory not set in StableYieldManager");
        
        // FeeManager should have managers set
        assertEq(feeManager.manager(), address(manager), "Manager not set in FeeManager");
        assertEq(feeManager.stableYieldManager(), address(stableYieldMgr), "StableYieldManager not set in FeeManager");
        
        console.log("  All factories registered!");
    }
    
    /**
     * @notice TEST 3: Verify stable yield pool can be created after deployment
     * @dev This is the CRITICAL test that would have caught our production issues
     */
    function test_deployment_canCreateStableYieldPool() public {
        console.log("\n=== TEST: Post-Deployment Pool Creation ===");
        
        // Debug role status
        console.log("  Admin address:", admin);
        console.log("  Admin has POOL_CREATOR_ROLE:", accessMgr.hasRole(accessMgr.POOL_CREATOR_ROLE(), admin));
        console.log("  Caller (test contract):", address(this));
        
        uint256[] memory tenors = new uint256[](2);
        tenors[0] = 90;
        tenors[1] = 180;
        
        ManagedPoolFactory.PoolDeploymentConfig memory config = ManagedPoolFactory.PoolDeploymentConfig({
            asset: address(asset),
            poolName: "Test Pool",
            poolSymbol: "TPOOL",
            spvAddress: spv,
            supportedTenors: tenors,
            minInvestment: 100e6,
            expenseRatio: 50,
            underlyingPools: new address[](0)
        });
        
        vm.prank(admin);
        (address pool, address escrow) = managedFactory.createStableYieldPool(config);
        
        assertTrue(pool != address(0), "Pool not created");
        assertTrue(escrow != address(0), "Escrow not created");
        assertTrue(managedFactory.isManagedPool(pool), "Pool not registered");
        
        console.log("  Pool created successfully!");
        console.log("  Pool:", pool);
        console.log("  Escrow:", escrow);
    }
    
    /**
     * @notice TEST 4: Verify deposit works after pool creation
     * @dev Full end-to-end flow: deploy → create pool → deposit
     */
    function test_deployment_canDepositToCreatedPool() public {
        console.log("\n=== TEST: Post-Deployment Deposit Flow ===");
        
        // Create pool
        uint256[] memory tenors = new uint256[](1);
        tenors[0] = 90;
        
        ManagedPoolFactory.PoolDeploymentConfig memory config = ManagedPoolFactory.PoolDeploymentConfig({
            asset: address(asset),
            poolName: "Deposit Test Pool",
            poolSymbol: "DPOOL",
            spvAddress: spv,
            supportedTenors: tenors,
            minInvestment: 100e6,
            expenseRatio: 50,
            underlyingPools: new address[](0)
        });
        
        vm.prank(admin);
        (address pool, address escrow) = managedFactory.createStableYieldPool(config);
        
        // Mint and deposit
        asset.mint(user1, 1000e6);
        
        vm.startPrank(user1);
        asset.approve(pool, 1000e6);
        uint256 shares = StableYieldPool(pool).deposit(1000e6, user1);
        vm.stopPrank();
        
        assertTrue(shares > 0, "No shares minted");
        assertEq(StableYieldPool(pool).balanceOf(user1), shares, "Shares not credited");
        assertEq(asset.balanceOf(escrow), 1000e6, "Tokens not in escrow");
        
        console.log("  Deposit successful!");
        console.log("  Shares minted:", shares);
    }
    
    /**
     * @notice TEST 5: Verify FeeManager can set expense ratio
     */
    function test_deployment_feeManagerWorks() public {
        console.log("\n=== TEST: FeeManager Configuration ===");
        
        // Create pool
        uint256[] memory tenors = new uint256[](1);
        tenors[0] = 90;
        
        ManagedPoolFactory.PoolDeploymentConfig memory config = ManagedPoolFactory.PoolDeploymentConfig({
            asset: address(asset),
            poolName: "Fee Test Pool",
            poolSymbol: "FPOOL",
            spvAddress: spv,
            supportedTenors: tenors,
            minInvestment: 100e6,
            expenseRatio: 50,
            underlyingPools: new address[](0)
        });
        
        vm.prank(admin);
        (address pool,) = managedFactory.createStableYieldPool(config);
        
        // Verify expense ratio was set during creation
        uint256 expenseRatio = feeManager.getPoolExpenseRatio(pool);
        // FeeManager sets DEFAULT_EXPENSE_RATIO (80) not the config.expenseRatio (50)
        assertEq(expenseRatio, 80, "Expense ratio not set to default");
        
        console.log("  FeeManager working correctly!");
    }
}

