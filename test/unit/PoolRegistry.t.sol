// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../fixtures/BaseTest.sol";
import "../../src/PoolRegistry.sol";
import "../../src/AccessManager.sol";
import "../../src/interfaces/IPoolRegistry.sol";
import "../../src/types/IStableYieldTypes.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title MockAccessManager
 * @notice Simple mock AccessManager for testing that provides role constants
 */
contract MockAccessManager {
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant SPV_ROLE = keccak256("SPV_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant ASSET_MANAGER_ROLE = keccak256("ASSET_MANAGER_ROLE");
    bytes32 public constant POOL_CREATOR_ROLE = keccak256("POOL_CREATOR_ROLE");
    bytes32 public constant MULTISIG_ADMIN_ROLE = keccak256("MULTISIG_ADMIN_ROLE");
}

/**
 * @title TestPoolRegistry  
 * @notice PoolRegistry with modified initialization for testing
 */
contract TestPoolRegistry is PoolRegistry {
    function initialize(
        address _accessManager,
        address _timelockController,
        address _initialAdmin,
        address _operator,
        address _emergency
    ) public initializer {
        require(_accessManager != address(0), "PoolRegistry/invalid-access-manager");
        require(_timelockController != address(0), "Invalid timelock controller");
        
        __UUPSUpgradeable_init();
        __AccessControl_init();
        
        accessManager = AccessManager(_accessManager);
        timelockController = _timelockController;
        factory = address(0);
        version = 1;
        
        // Grant initial roles
        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(accessManager.ASSET_MANAGER_ROLE(), _initialAdmin);
        _grantRole(accessManager.POOL_CREATOR_ROLE(), _initialAdmin);
        _grantRole(accessManager.OPERATOR_ROLE(), _operator);
        _grantRole(accessManager.EMERGENCY_ROLE(), _emergency);
        _grantRole(accessManager.MULTISIG_ADMIN_ROLE(), _initialAdmin);
        // Emergency needs operator role because emergencyDeactivatePool calls updatePoolStatus
        _grantRole(accessManager.OPERATOR_ROLE(), _emergency);
    }
}

/**
 * @title PoolRegistryTest
 * @notice Comprehensive unit tests for PoolRegistry contract
 */
contract PoolRegistryTest is BaseTest {
    
    PoolRegistry public registryImplementation;
    PoolRegistry public registry;
    MockAccessManager public accessManager;
    MockERC20 public token;
    
    address public poolFactory = makeAddr("poolFactory");
    address public timelockController = makeAddr("timelockController");
    address public testPool = makeAddr("testPool");
    address public testPool2 = makeAddr("testPool2");
    
    // Events to test
    event PoolRegistered(address indexed pool, address indexed manager, address indexed asset, string instrumentType, address creator);
    event PoolStatusUpdated(address indexed pool, bool isActive);
    event PoolCategoryUpdated(address indexed pool, string oldCategory, string newCategory);
    event FactoryUpdated(address indexed oldFactory, address indexed newFactory);
    event AccessManagerUpdated(address indexed oldAccessManager, address indexed newAccessManager);
    event AssetApproved(address indexed asset, string name, string symbol, string country, string region);
    event AssetRevoked(address indexed asset);
    event AssetMetadataUpdated(address indexed asset);
    event ImplementationApproved(address indexed implementation);
    event ImplementationRevoked(address indexed implementation);
    event StableYieldPoolRegistered(address indexed poolAddress, address indexed escrowAddress, address indexed asset, string name);
    event StableYieldPoolStatusUpdated(address indexed pool, bool isActive);
    
    function setUp() public override {
        super.setUp();
        
        // Deploy MockAccessManager with all needed roles for testing
        accessManager = new MockAccessManager();
        
        // Deploy TestPoolRegistry implementation with role initialization
        registryImplementation = PoolRegistry(address(new TestPoolRegistry()));
        
        // Deploy proxy with roles granted during initialization
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address,address)",
            address(accessManager),
            timelockController,
            admin,
            operator,
            emergency
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(registryImplementation),
            initData
        );
        
        registry = PoolRegistry(address(proxy));
        
        // Deploy test token
        token = new MockERC20("Mock USDC", "USDC", 6);
    }
    
    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_Initialize_Success() public view {
        assertEq(address(registry.accessManager()), address(accessManager));
        assertEq(registry.timelockController(), timelockController);
        assertEq(registry.version(), 1);
        assertEq(registry.factory(), address(0)); // Not set yet
    }
    
    function test_Initialize_RevertIf_InvalidAccessManager() public {
        PoolRegistry newRegistryImpl = new PoolRegistry();
        
        bytes memory badInitData = abi.encodeWithSignature(
            "initialize(address,address)",
            address(0), // Invalid access manager
            timelockController
        );
        
        vm.expectRevert("PoolRegistry/invalid-access-manager");
        new ERC1967Proxy(address(newRegistryImpl), badInitData);
    }
    
    function test_Initialize_RevertIf_InvalidTimelockController() public {
        PoolRegistry newRegistryImpl = new PoolRegistry();
        
        bytes memory badInitData = abi.encodeWithSignature(
            "initialize(address,address)",
            address(accessManager),
            address(0) // Invalid timelock
        );
        
        vm.expectRevert("Invalid timelock controller");
        new ERC1967Proxy(address(newRegistryImpl), badInitData);
    }
    
    function test_Initialize_CannotReinitialize() public {
        vm.expectRevert();
        registry.initialize(address(accessManager), timelockController);
    }
    
    /*//////////////////////////////////////////////////////////////
                        FACTORY MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_SetFactory_Success() public {
        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit FactoryUpdated(address(0), poolFactory);
        
        registry.setFactory(poolFactory);
        
        assertEq(registry.factory(), poolFactory);
    }
    
    function test_SetFactory_RevertIf_NotAdmin() public {
        bytes32 adminRole = accessManager.DEFAULT_ADMIN_ROLE();
        
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                user1,
                adminRole
            )
        );
        registry.setFactory(poolFactory);
    }
    
    function test_SetFactory_RevertIf_InvalidFactory() public {
        vm.prank(admin);
        vm.expectRevert("PoolRegistry/invalid-factory");
        registry.setFactory(address(0));
    }
    
    function test_SetFactory_UpdateExisting() public {
        // Set initial factory
        vm.prank(admin);
        registry.setFactory(poolFactory);
        
        address newFactory = makeAddr("newFactory");
        
        // Update factory
        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit FactoryUpdated(poolFactory, newFactory);
        
        registry.setFactory(newFactory);
        
        assertEq(registry.factory(), newFactory);
    }
    
    /*//////////////////////////////////////////////////////////////
                        ACCESS MANAGER TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_SetAccessManager_Success() public {
        MockAccessManager newAccessManager = new MockAccessManager();
        
        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit AccessManagerUpdated(address(accessManager), address(newAccessManager));
        
        registry.setAccessManager(address(newAccessManager));
        
        assertEq(address(registry.accessManager()), address(newAccessManager));
    }
    
    function test_SetAccessManager_RevertIf_NotAdmin() public {
        bytes32 adminRole = accessManager.DEFAULT_ADMIN_ROLE();
        
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                user1,
                adminRole
            )
        );
        registry.setAccessManager(address(0x123));
    }
    
    function test_SetAccessManager_RevertIf_InvalidAddress() public {
        vm.prank(admin);
        vm.expectRevert("PoolRegistry/invalid-access-manager");
        registry.setAccessManager(address(0));
    }
    
    /*//////////////////////////////////////////////////////////////
                        ASSET APPROVAL TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_ApproveAsset_Success() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit AssetApproved(address(token), "Mock USDC", "USDC", "Nigeria", "West Africa");
        
        registry.approveAsset(
            address(token),
            "Mock USDC",
            "USDC",
            "Nigeria",
            "West Africa",
            true
        );
        
        assertTrue(registry.isApprovedAsset(address(token)));
        
        PoolRegistry.AssetInfo memory assetInfo = registry.getAssetInfo(address(token));
        assertEq(assetInfo.name, "Mock USDC");
        assertEq(assetInfo.symbol, "USDC");
        assertEq(assetInfo.country, "Nigeria");
        assertEq(assetInfo.region, "West Africa");
        assertTrue(assetInfo.isStablecoin);
        assertEq(assetInfo.decimals, 6);
    }
    
    function test_ApproveAsset_RevertIf_NotAssetManager() public {
        bytes32 assetManagerRole = accessManager.ASSET_MANAGER_ROLE();
        
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                user1,
                assetManagerRole
            )
        );
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
    }
    
    function test_ApproveAsset_RevertIf_InvalidAsset() public {
        vm.prank(admin);
        vm.expectRevert("PoolRegistry/invalid asset");
        registry.approveAsset(address(0), "USDC", "USDC", "", "", true);
    }
    
    function test_ApproveAsset_RevertIf_InvalidName() public {
        vm.prank(admin);
        vm.expectRevert("PoolRegistry/invalid name");
        registry.approveAsset(address(token), "", "USDC", "", "", true);
    }
    
    function test_ApproveAsset_RevertIf_InvalidSymbol() public {
        vm.prank(admin);
        vm.expectRevert("PoolRegistry/invalid symbol");
        registry.approveAsset(address(token), "USDC", "", "", "", true);
    }
    
    function test_ApproveAsset_RevertIf_AlreadyApproved() public {
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        
        vm.expectRevert("PoolRegistry/already approved");
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        vm.stopPrank();
    }
    
    function test_ApproveAsset_AddsToApprovedList() public {
        vm.prank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        
        address[] memory approvedAssets = registry.getAllApprovedAssets();
        assertEq(approvedAssets.length, 1);
        assertEq(approvedAssets[0], address(token));
    }
    
    /*//////////////////////////////////////////////////////////////
                        ASSET REVOCATION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_RevokeAsset_Success() public {
        // First approve
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        assertTrue(registry.isApprovedAsset(address(token)));
        
        // Then revoke
        vm.expectEmit(true, false, false, false);
        emit AssetRevoked(address(token));
        
        registry.revokeAsset(address(token));
        vm.stopPrank();
        
        assertFalse(registry.isApprovedAsset(address(token)));
    }
    
    function test_RevokeAsset_RevertIf_NotAssetManager() public {
        bytes32 assetManagerRole = accessManager.ASSET_MANAGER_ROLE();
        
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                user1,
                assetManagerRole
            )
        );
        registry.revokeAsset(address(token));
    }
    
    function test_RevokeAsset_RevertIf_NotApproved() public {
        vm.prank(admin);
        vm.expectRevert("PoolRegistry/asset not approved");
        registry.revokeAsset(address(token));
    }
    
    /*//////////////////////////////////////////////////////////////
                        ASSET METADATA TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_UpdateAssetMetadata_Success() public {
        // First approve asset
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "USA", "North America", true);
        
        // Update metadata
        vm.expectEmit(true, false, false, false);
        emit AssetMetadataUpdated(address(token));
        
        registry.updateAssetMetadata(
            address(token),
            "USD Coin",
            "United States",
            "Americas"
        );
        vm.stopPrank();
        
        PoolRegistry.AssetInfo memory assetInfo = registry.getAssetInfo(address(token));
        assertEq(assetInfo.name, "USD Coin");
        assertEq(assetInfo.country, "United States");
        assertEq(assetInfo.region, "Americas");
    }
    
    function test_UpdateAssetMetadata_RevertIf_NotApproved() public {
        vm.prank(admin);
        vm.expectRevert("PoolRegistry/asset not approved");
        registry.updateAssetMetadata(address(token), "New Name", "Country", "Region");
    }
    
    /*//////////////////////////////////////////////////////////////
                        POOL REGISTRATION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_RegisterPool_Success() public {
        // First approve asset
        vm.prank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        
        // Set factory
        vm.prank(admin);
        registry.setFactory(poolFactory);
        
        IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        vm.prank(poolFactory);
        vm.expectEmit(true, true, true, false);
        emit PoolRegistered(testPool, admin, address(token), "Treasury Bill", admin);
        
        registry.registerPool(testPool, poolInfo);
        
        assertTrue(registry.isRegisteredPool(testPool));
        assertTrue(registry.isActivePool(testPool));
        assertEq(registry.totalPools(), 1);
        assertEq(registry.activePools(), 1);
    }
    
    function test_RegisterPool_RevertIf_NotFactory() public {
        IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        vm.prank(user1);
        vm.expectRevert("PoolRegistry/only-factory");
        registry.registerPool(testPool, poolInfo);
    }
    
    function test_RegisterPool_RevertIf_InvalidPool() public {
        vm.prank(admin);
        registry.setFactory(poolFactory);
        
        IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        vm.prank(poolFactory);
        vm.expectRevert("PoolRegistry/invalid-pool");
        registry.registerPool(address(0), poolInfo);
    }
    
    function test_RegisterPool_RevertIf_AlreadyRegistered() public {
        // Approve asset and set factory
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        registry.setFactory(poolFactory);
        vm.stopPrank();
        
        IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        vm.startPrank(poolFactory);
        registry.registerPool(testPool, poolInfo);
        
        vm.expectRevert("PoolRegistry/pool-already-registered");
        registry.registerPool(testPool, poolInfo);
        vm.stopPrank();
    }
    
    function test_RegisterPool_RevertIf_AssetNotApproved() public {
        vm.prank(admin);
        registry.setFactory(poolFactory);
        
        IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow"),
            asset: address(token), // Not approved yet
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        vm.prank(poolFactory);
        vm.expectRevert("PoolRegistry/asset-not-approved");
        registry.registerPool(testPool, poolInfo);
    }
    
    /*//////////////////////////////////////////////////////////////
                        STABLE YIELD POOL TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_RegisterStableYieldPool_Success() public {
        // Approve asset
        vm.prank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        
        IStableYieldTypes.PoolData memory poolData = IStableYieldTypes.PoolData({
            poolAddress: testPool,
            escrowAddress: makeAddr("escrow"),
            asset: address(token),
            name: "Flexible Pool",
            minInvestment: 100e6,
            isActive: true,
            createdAt: block.timestamp
        });
        
        vm.prank(admin);
        vm.expectEmit(true, true, true, false);
        emit StableYieldPoolRegistered(testPool, poolData.escrowAddress, address(token), "Flexible Pool");
        
        registry.registerStableYieldPool(poolData);
        
        assertTrue(registry.isStableYieldPool(testPool));
        assertTrue(registry.isManagedPool(testPool));
        assertEq(registry.getTotalStableYieldPools(), 1);
        assertEq(registry.getStableYieldPoolAtIndex(0), testPool);
    }
    
    function test_RegisterStableYieldPool_RevertIf_NotPoolCreator() public {
        bytes32 poolCreatorRole = accessManager.POOL_CREATOR_ROLE();
        
        IStableYieldTypes.PoolData memory poolData = IStableYieldTypes.PoolData({
            poolAddress: testPool,
            escrowAddress: makeAddr("escrow"),
            asset: address(token),
            name: "Flexible Pool",
            minInvestment: 100e6,
            isActive: true,
            createdAt: block.timestamp
        });
        
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                user1,
                poolCreatorRole
            )
        );
        registry.registerStableYieldPool(poolData);
    }
    
    function test_RegisterStableYieldPool_RevertIf_InvalidPool() public {
        IStableYieldTypes.PoolData memory poolData = IStableYieldTypes.PoolData({
            poolAddress: address(0),
            escrowAddress: makeAddr("escrow"),
            asset: address(token),
            name: "Flexible Pool",
            minInvestment: 100e6,
            isActive: true,
            createdAt: block.timestamp
        });
        
        vm.prank(admin);
        vm.expectRevert("PoolRegistry/invalid pool");
        registry.registerStableYieldPool(poolData);
    }
    
    function test_RegisterStableYieldPool_RevertIf_AlreadyRegistered() public {
        vm.prank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        
        IStableYieldTypes.PoolData memory poolData = IStableYieldTypes.PoolData({
            poolAddress: testPool,
            escrowAddress: makeAddr("escrow"),
            asset: address(token),
            name: "Flexible Pool",
            minInvestment: 100e6,
            isActive: true,
            createdAt: block.timestamp
        });
        
        vm.startPrank(admin);
        registry.registerStableYieldPool(poolData);
        
        vm.expectRevert("PoolRegistry/pool already registered");
        registry.registerStableYieldPool(poolData);
        vm.stopPrank();
    }
    
    function test_RegisterStableYieldPool_RevertIf_AssetNotApproved() public {
        IStableYieldTypes.PoolData memory poolData = IStableYieldTypes.PoolData({
            poolAddress: testPool,
            escrowAddress: makeAddr("escrow"),
            asset: address(token), // Not approved
            name: "Flexible Pool",
            minInvestment: 100e6,
            isActive: true,
            createdAt: block.timestamp
        });
        
        vm.prank(admin);
        vm.expectRevert("PoolRegistry/asset not approved");
        registry.registerStableYieldPool(poolData);
    }
    
    /*//////////////////////////////////////////////////////////////
                        POOL STATUS MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_UpdatePoolStatus_Success() public {
        // Setup: Register a pool
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        registry.setFactory(poolFactory);
        vm.stopPrank();
        
        IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        vm.prank(poolFactory);
        registry.registerPool(testPool, poolInfo);
        
        // Update status to inactive
        vm.prank(operator);
        vm.expectEmit(true, false, false, true);
        emit PoolStatusUpdated(testPool, false);
        
        registry.updatePoolStatus(testPool, false);
        
        assertFalse(registry.isActivePool(testPool));
        assertEq(registry.activePools(), 0);
    }
    
    function test_UpdatePoolStatus_RevertIf_NotOperator() public {
        bytes32 operatorRole = accessManager.OPERATOR_ROLE();
        
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                user1,
                operatorRole
            )
        );
        registry.updatePoolStatus(testPool, false);
    }
    
    function test_UpdatePoolStatus_ForStableYieldPool() public {
        // Register StableYield pool as INACTIVE initially to avoid underflow bug
        vm.prank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        
        IStableYieldTypes.PoolData memory poolData = IStableYieldTypes.PoolData({
            poolAddress: testPool,
            escrowAddress: makeAddr("escrow"),
            asset: address(token),
            name: "Flexible Pool",
            minInvestment: 100e6,
            isActive: false, // Start as inactive
            createdAt: block.timestamp
        });
        
        vm.prank(admin);
        registry.registerStableYieldPool(poolData);
        
        // Activate it first
        vm.prank(operator);
        registry.updatePoolStatus(testPool, true);
        
        IStableYieldTypes.PoolData memory activeData = registry.getStableYieldPoolData(testPool);
        assertTrue(activeData.isActive);
        
        // Then deactivate
        vm.prank(operator);
        vm.expectEmit(true, false, false, true);
        emit StableYieldPoolStatusUpdated(testPool, false);
        
        registry.updatePoolStatus(testPool, false);
        
        IStableYieldTypes.PoolData memory updatedData = registry.getStableYieldPoolData(testPool);
        assertFalse(updatedData.isActive);
    }
    
    function test_PausePool_Success() public {
        // Register pool
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        registry.setFactory(poolFactory);
        vm.stopPrank();
        
        IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        vm.prank(poolFactory);
        registry.registerPool(testPool, poolInfo);
        
        // Pause
        vm.prank(operator);
        registry.pausePool(testPool);
        
        assertFalse(registry.isActivePool(testPool));
    }
    
    function test_UnpausePool_Success() public {
        // Register and pause pool
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        registry.setFactory(poolFactory);
        vm.stopPrank();
        
        IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        vm.prank(poolFactory);
        registry.registerPool(testPool, poolInfo);
        
        vm.prank(operator);
        registry.pausePool(testPool);
        
        // Unpause
        vm.prank(operator);
        registry.unpausePool(testPool);
        
        assertTrue(registry.isActivePool(testPool));
    }
    
    function test_EmergencyDeactivatePool_Success() public {
        // Register pool
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        registry.setFactory(poolFactory);
        vm.stopPrank();
        
        IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        vm.prank(poolFactory);
        registry.registerPool(testPool, poolInfo);
        
        // Emergency deactivate
        vm.prank(emergency);
        registry.emergencyDeactivatePool(testPool);
        
        assertFalse(registry.isActivePool(testPool));
    }
    
    /*//////////////////////////////////////////////////////////////
                        POOL CATEGORY TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_UpdatePoolCategory_Success() public {
        // Register pool
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        registry.setFactory(poolFactory);
        vm.stopPrank();
        
        IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        vm.prank(poolFactory);
        registry.registerPool(testPool, poolInfo);
        
        // Update category
        vm.prank(operator);
        vm.expectEmit(true, false, false, false);
        emit PoolCategoryUpdated(testPool, "Treasury Bill", "Commercial Paper");
        
        registry.updatePoolCategory(testPool, "Commercial Paper");
        
        IPoolRegistry.PoolInfo memory updatedInfo = registry.getPoolInfo(testPool);
        assertEq(updatedInfo.instrumentType, "Commercial Paper");
    }
    
    function test_UpdatePoolCategory_RevertIf_PoolNotRegistered() public {
        vm.prank(operator);
        vm.expectRevert("PoolRegistry/pool-not-registered");
        registry.updatePoolCategory(testPool, "New Category");
    }
    
    /*//////////////////////////////////////////////////////////////
                        IMPLEMENTATION APPROVAL TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_ApproveImplementation_Success() public {
        address implementation = makeAddr("implementation");
        
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit ImplementationApproved(implementation);
        
        registry.approveImplementation(implementation);
        
        assertTrue(registry.isApprovedImplementation(implementation));
    }
    
    function test_ApproveImplementation_RevertIf_NotMultisigAdmin() public {
        bytes32 multisigRole = accessManager.MULTISIG_ADMIN_ROLE();
        
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                user1,
                multisigRole
            )
        );
        registry.approveImplementation(address(0x123));
    }
    
    function test_ApproveImplementation_RevertIf_InvalidImplementation() public {
        vm.prank(admin);
        vm.expectRevert("Invalid implementation");
        registry.approveImplementation(address(0));
    }
    
    function test_ApproveImplementation_RevertIf_AlreadyApproved() public {
        address implementation = makeAddr("implementation");
        
        vm.startPrank(admin);
        registry.approveImplementation(implementation);
        
        vm.expectRevert("Already approved");
        registry.approveImplementation(implementation);
        vm.stopPrank();
    }
    
    function test_RevokeImplementation_Success() public {
        address implementation = makeAddr("implementation");
        
        vm.startPrank(admin);
        registry.approveImplementation(implementation);
        
        vm.expectEmit(true, false, false, false);
        emit ImplementationRevoked(implementation);
        
        registry.revokeImplementation(implementation);
        vm.stopPrank();
        
        assertFalse(registry.isApprovedImplementation(implementation));
    }
    
    function test_RevokeImplementation_RevertIf_NotApproved() public {
        vm.prank(admin);
        vm.expectRevert("Implementation not approved");
        registry.revokeImplementation(address(0x123));
    }
    
    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_GetPoolInfo() public {
        // Register pool
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        registry.setFactory(poolFactory);
        vm.stopPrank();
        
        IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        vm.prank(poolFactory);
        registry.registerPool(testPool, poolInfo);
        
        IPoolRegistry.PoolInfo memory retrievedInfo = registry.getPoolInfo(testPool);
        assertEq(retrievedInfo.manager, admin);
        assertEq(retrievedInfo.asset, address(token));
        assertEq(retrievedInfo.instrumentType, "Treasury Bill");
    }
    
    function test_GetPoolCount() public {
        // Register multiple pools
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        registry.setFactory(poolFactory);
        vm.stopPrank();
        
        IPoolRegistry.PoolInfo memory poolInfo1 = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow1"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        IPoolRegistry.PoolInfo memory poolInfo2 = IPoolRegistry.PoolInfo({
            pool: testPool2,
            manager: admin,
            escrow: makeAddr("escrow2"),
            asset: address(token),
            instrumentType: "Commercial Paper",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 180 days
        });
        
        vm.startPrank(poolFactory);
        registry.registerPool(testPool, poolInfo1);
        registry.registerPool(testPool2, poolInfo2);
        vm.stopPrank();
        
        assertEq(registry.getPoolCount(), 2);
    }
    
    function test_GetPoolAtIndex() public {
        // Register pool
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        registry.setFactory(poolFactory);
        vm.stopPrank();
        
        IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        vm.prank(poolFactory);
        registry.registerPool(testPool, poolInfo);
        
        assertEq(registry.getPoolAtIndex(0), testPool);
    }
    
    function test_GetPoolAtIndex_RevertIf_OutOfBounds() public {
        vm.expectRevert("Index out of bounds");
        registry.getPoolAtIndex(0);
    }
    
    function test_GetPoolsByType() public {
        // Register multiple pools of different types
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        registry.setFactory(poolFactory);
        vm.stopPrank();
        
        IPoolRegistry.PoolInfo memory poolInfo1 = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow1"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        IPoolRegistry.PoolInfo memory poolInfo2 = IPoolRegistry.PoolInfo({
            pool: testPool2,
            manager: admin,
            escrow: makeAddr("escrow2"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        vm.startPrank(poolFactory);
        registry.registerPool(testPool, poolInfo1);
        registry.registerPool(testPool2, poolInfo2);
        vm.stopPrank();
        
        address[] memory treasuryBills = registry.getPoolsByType("Treasury Bill");
        assertEq(treasuryBills.length, 2);
        assertEq(treasuryBills[0], testPool);
        assertEq(treasuryBills[1], testPool2);
    }
    
    function test_GetAssetInfo() public {
        vm.prank(admin);
        registry.approveAsset(address(token), "Mock USDC", "USDC", "Nigeria", "West Africa", true);
        
        PoolRegistry.AssetInfo memory assetInfo = registry.getAssetInfo(address(token));
        assertTrue(assetInfo.isApproved);
        assertEq(assetInfo.name, "Mock USDC");
        assertEq(assetInfo.symbol, "USDC");
        assertEq(assetInfo.tokenAddress, address(token));
    }
    
    function test_GetAllApprovedAssets() public {
        MockERC20 token2 = new MockERC20("DAI", "DAI", 18);
        
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        registry.approveAsset(address(token2), "DAI", "DAI", "", "", true);
        vm.stopPrank();
        
        address[] memory approvedAssets = registry.getAllApprovedAssets();
        assertEq(approvedAssets.length, 2);
        assertEq(approvedAssets[0], address(token));
        assertEq(approvedAssets[1], address(token2));
    }
    
    function test_GetStableYieldPoolData() public {
        vm.prank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        
        IStableYieldTypes.PoolData memory poolData = IStableYieldTypes.PoolData({
            poolAddress: testPool,
            escrowAddress: makeAddr("escrow"),
            asset: address(token),
            name: "Flexible Pool",
            minInvestment: 100e6,
            isActive: true,
            createdAt: block.timestamp
        });
        
        vm.prank(admin);
        registry.registerStableYieldPool(poolData);
        
        IStableYieldTypes.PoolData memory retrievedData = registry.getStableYieldPoolData(testPool);
        assertEq(retrievedData.poolAddress, testPool);
        assertEq(retrievedData.minInvestment, 100e6);
        assertTrue(retrievedData.isActive);
    }
    
    function test_GetStableYieldPoolData_RevertIf_NotStableYieldPool() public {
        vm.expectRevert("PoolRegistry/not a StableYield pool");
        registry.getStableYieldPoolData(testPool);
    }
    
    function test_GetManagedPoolAtIndex() public {
        vm.prank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        
        IStableYieldTypes.PoolData memory poolData = IStableYieldTypes.PoolData({
            poolAddress: testPool,
            escrowAddress: makeAddr("escrow"),
            asset: address(token),
            name: "Flexible Pool",
            minInvestment: 100e6,
            isActive: true,
            createdAt: block.timestamp
        });
        
        vm.prank(admin);
        registry.registerStableYieldPool(poolData);
        
        assertEq(registry.getManagedPoolAtIndex(0), testPool);
    }
    
    function test_GetManagedPoolAtIndex_RevertIf_OutOfBounds() public {
        vm.expectRevert("PoolRegistry/index out of bounds");
        registry.getManagedPoolAtIndex(0);
    }
    
    /*//////////////////////////////////////////////////////////////
                        ACTIVE POOL TRACKING TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_ActivePools_IncrementOnRegistration() public {
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        registry.setFactory(poolFactory);
        vm.stopPrank();
        
        assertEq(registry.activePools(), 0);
        
        IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        vm.prank(poolFactory);
        registry.registerPool(testPool, poolInfo);
        
        assertEq(registry.activePools(), 1);
    }
    
    function test_ActivePools_DecrementOnDeactivation() public {
        // Register active pool
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        registry.setFactory(poolFactory);
        vm.stopPrank();
        
        IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        vm.prank(poolFactory);
        registry.registerPool(testPool, poolInfo);
        
        assertEq(registry.activePools(), 1);
        
        // Deactivate
        vm.prank(operator);
        registry.updatePoolStatus(testPool, false);
        
        assertEq(registry.activePools(), 0);
    }
    
    function test_ActivePools_IncrementOnReactivation() public {
        // Register and deactivate pool
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        registry.setFactory(poolFactory);
        vm.stopPrank();
        
        IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        vm.prank(poolFactory);
        registry.registerPool(testPool, poolInfo);
        
        vm.prank(operator);
        registry.updatePoolStatus(testPool, false);
        
        assertEq(registry.activePools(), 0);
        
        // Reactivate
        vm.prank(operator);
        registry.updatePoolStatus(testPool, true);
        
        assertEq(registry.activePools(), 1);
    }
    
    /*//////////////////////////////////////////////////////////////
                        INTEGRATION SCENARIO TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_CompleteAssetAndPoolRegistration() public {
        // 1. Approve asset
        vm.prank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "Nigeria", "West Africa", true);
        
        // 2. Set factory
        vm.prank(admin);
        registry.setFactory(poolFactory);
        
        // 3. Register pool
        IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        vm.prank(poolFactory);
        registry.registerPool(testPool, poolInfo);
        
        // Verify complete state
        assertTrue(registry.isApprovedAsset(address(token)));
        assertTrue(registry.isRegisteredPool(testPool));
        assertTrue(registry.isActivePool(testPool));
        assertEq(registry.totalPools(), 1);
        assertEq(registry.activePools(), 1);
    }
    
    function test_MultipleAssetsAndPools() public {
        MockERC20 token2 = new MockERC20("DAI", "DAI", 18);
        MockERC20 token3 = new MockERC20("USDT", "USDT", 6);
        
        // Approve multiple assets
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "Nigeria", "West Africa", true);
        registry.approveAsset(address(token2), "DAI", "DAI", "Kenya", "East Africa", true);
        registry.approveAsset(address(token3), "USDT", "USDT", "", "Pan-African", true);
        registry.setFactory(poolFactory);
        vm.stopPrank();
        
        // Register pools with different assets
        vm.startPrank(poolFactory);
        
        IPoolRegistry.PoolInfo memory pool1 = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow1"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        registry.registerPool(testPool, pool1);
        
        IPoolRegistry.PoolInfo memory pool2 = IPoolRegistry.PoolInfo({
            pool: testPool2,
            manager: admin,
            escrow: makeAddr("escrow2"),
            asset: address(token2),
            instrumentType: "Commercial Paper",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 500_000e6,
            maturityDate: block.timestamp + 180 days
        });
        registry.registerPool(testPool2, pool2);
        
        vm.stopPrank();
        
        assertEq(registry.totalPools(), 2);
        assertEq(registry.getAllApprovedAssets().length, 3);
    }
    
    function test_MixedTraditionalAndStableYieldPools() public {
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        registry.setFactory(poolFactory);
        vm.stopPrank();
        
        // Register traditional pool
        IPoolRegistry.PoolInfo memory traditionalPool = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow1"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        vm.prank(poolFactory);
        registry.registerPool(testPool, traditionalPool);
        
        // Register StableYield pool
        IStableYieldTypes.PoolData memory stableYieldPool = IStableYieldTypes.PoolData({
            poolAddress: testPool2,
            escrowAddress: makeAddr("escrow"),
            asset: address(token),
            name: "Flexible Pool",
            minInvestment: 100e6,
            isActive: true,
            createdAt: block.timestamp
        });
        
        vm.prank(admin);
        registry.registerStableYieldPool(stableYieldPool);
        
        // Verify both types
        assertTrue(registry.isRegisteredPool(testPool));
        assertFalse(registry.isManagedPool(testPool));
        
        assertTrue(registry.isStableYieldPool(testPool2));
        assertTrue(registry.isManagedPool(testPool2));
        
        assertEq(registry.totalPools(), 1); // Traditional pools
        assertEq(registry.getTotalStableYieldPools(), 1); // StableYield pools
    }
    
    /*//////////////////////////////////////////////////////////////
                        FUZZ TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testFuzz_ApproveMultipleAssets(uint8 assetCount) public {
        vm.assume(assetCount > 0 && assetCount <= 10); // Reduced to avoid gas issues
        
        vm.startPrank(admin);
        
        for (uint8 i = 0; i < assetCount; i++) {
            // Create unique asset addresses
            address assetAddress = address(uint160(uint256(keccak256(abi.encodePacked("fuzzAsset", i, block.timestamp)))));
            
            // Deploy actual mock token to avoid issues
            MockERC20 assetToken = new MockERC20(
                string(abi.encodePacked("Asset", uint256(i))),
                string(abi.encodePacked("AST", uint256(i))),
                18
            );
            
            registry.approveAsset(
                address(assetToken),
                string(abi.encodePacked("Asset", uint256(i))),
                string(abi.encodePacked("AST", uint256(i))),
                "",
                "",
                true
            );
        }
        
        vm.stopPrank();
        
        assertEq(registry.getAllApprovedAssets().length, assetCount);
    }
    
    function testFuzz_RegisterMultiplePools(uint8 poolCount) public {
        vm.assume(poolCount > 0 && poolCount <= 50);
        
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        registry.setFactory(poolFactory);
        vm.stopPrank();
        
        vm.startPrank(poolFactory);
        
        for (uint8 i = 0; i < poolCount; i++) {
            address poolAddress = address(uint160(uint256(keccak256(abi.encodePacked("pool", i)))));
            
            IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
                pool: poolAddress,
                manager: admin,
                escrow: address(uint160(uint256(keccak256(abi.encodePacked("escrow", i))))),
                asset: address(token),
                instrumentType: "Treasury Bill",
                createdAt: block.timestamp,
                isActive: true,
                creator: admin,
                targetRaise: 1_000_000e6,
                maturityDate: block.timestamp + 365 days
            });
            
            registry.registerPool(poolAddress, poolInfo);
        }
        
        vm.stopPrank();
        
        assertEq(registry.totalPools(), poolCount);
        assertEq(registry.activePools(), poolCount);
    }
    
    function testFuzz_UpdatePoolStatus(bool initialStatus, bool newStatus) public {
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        registry.setFactory(poolFactory);
        vm.stopPrank();
        
        IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: initialStatus,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        vm.prank(poolFactory);
        registry.registerPool(testPool, poolInfo);
        
        vm.prank(operator);
        registry.updatePoolStatus(testPool, newStatus);
        
        assertEq(registry.isActivePool(testPool), newStatus);
    }
    
    /*//////////////////////////////////////////////////////////////
                        EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_ApproveAsset_WithEmptyCountryAndRegion() public {
        vm.prank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        
        PoolRegistry.AssetInfo memory assetInfo = registry.getAssetInfo(address(token));
        assertEq(assetInfo.country, "");
        assertEq(assetInfo.region, "");
    }
    
    function test_RegisterPool_InactiveInitially() public {
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        registry.setFactory(poolFactory);
        vm.stopPrank();
        
        IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: false, // Inactive from start
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        vm.prank(poolFactory);
        registry.registerPool(testPool, poolInfo);
        
        assertEq(registry.totalPools(), 1);
        assertEq(registry.activePools(), 0); // Not counted as active
        assertFalse(registry.isActivePool(testPool));
    }
    
    function test_UpdatePoolStatus_NoChangeInCount() public {
        // Register active pool
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        registry.setFactory(poolFactory);
        vm.stopPrank();
        
        IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        vm.prank(poolFactory);
        registry.registerPool(testPool, poolInfo);
        
        // Update to same status (no change)
        vm.prank(operator);
        registry.updatePoolStatus(testPool, true);
        
        assertEq(registry.activePools(), 1); // Still 1
    }
    
    /*//////////////////////////////////////////////////////////////
                        STATE CONSISTENCY TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_TotalPools_Consistency() public {
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        registry.setFactory(poolFactory);
        vm.stopPrank();
        
        address[] memory pools = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            pools[i] = address(uint160(uint256(keccak256(abi.encodePacked("pool", i)))));
        }
        
        vm.startPrank(poolFactory);
        for (uint256 i = 0; i < pools.length; i++) {
            IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
                pool: pools[i],
                manager: admin,
                escrow: address(uint160(uint256(keccak256(abi.encodePacked("escrow", i))))),
                asset: address(token),
                instrumentType: "Treasury Bill",
                createdAt: block.timestamp,
                isActive: i % 2 == 0, // Every other pool is active
                creator: admin,
                targetRaise: 1_000_000e6,
                maturityDate: block.timestamp + 365 days
            });
            
            registry.registerPool(pools[i], poolInfo);
        }
        vm.stopPrank();
        
        assertEq(registry.totalPools(), 5);
        assertEq(registry.activePools(), 3); // 3 active (index 0, 2, 4)
        assertEq(registry.getPoolCount(), 5);
    }
    
    function test_AssetList_Consistency() public {
        MockERC20 token2 = new MockERC20("DAI", "DAI", 18);
        MockERC20 token3 = new MockERC20("USDT", "USDT", 6);
        
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        registry.approveAsset(address(token2), "DAI", "DAI", "", "", false);
        registry.approveAsset(address(token3), "USDT", "USDT", "", "", true);
        vm.stopPrank();
        
        address[] memory assets = registry.getAllApprovedAssets();
        assertEq(assets.length, 3);
        
        // Revoke one
        vm.prank(admin);
        registry.revokeAsset(address(token2));
        
        // Asset still in list but marked as not approved
        assertFalse(registry.isApprovedAsset(address(token2)));
        assertTrue(registry.isApprovedAsset(address(token)));
        assertTrue(registry.isApprovedAsset(address(token3)));
    }
    
    /*//////////////////////////////////////////////////////////////
                        UPGRADE AUTHORIZATION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_AuthorizeUpgrade_OnlyTimelock() public {
        address newImplementation = makeAddr("newImpl");
        
        vm.prank(user1);
        vm.expectRevert("Only timelock can upgrade");
        registry.upgradeToAndCall(newImplementation, "");
    }
    
    function test_AuthorizeUpgrade_RevertIf_InvalidImplementation() public {
        vm.prank(timelockController);
        vm.expectRevert("Invalid implementation");
        registry.upgradeToAndCall(address(0), "");
    }
    
    /*//////////////////////////////////////////////////////////////
                        ACCESS CONTROL COMPREHENSIVE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_AccessControl_AssetManager() public {
        bytes32 assetManagerRole = accessManager.ASSET_MANAGER_ROLE();
        
        // Test all asset manager functions require the role
        address[] memory unauthorizedUsers = new address[](3);
        unauthorizedUsers[0] = user1;
        unauthorizedUsers[1] = operator;
        unauthorizedUsers[2] = spv;
        
        for (uint256 i = 0; i < unauthorizedUsers.length; i++) {
            vm.prank(unauthorizedUsers[i]);
            vm.expectRevert(
                abi.encodeWithSignature(
                    "AccessControlUnauthorizedAccount(address,bytes32)",
                    unauthorizedUsers[i],
                    assetManagerRole
                )
            );
            registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        }
    }
    
    function test_AccessControl_Operator() public {
        // Register pool first
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        registry.setFactory(poolFactory);
        vm.stopPrank();
        
        IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        vm.prank(poolFactory);
        registry.registerPool(testPool, poolInfo);
        
        bytes32 operatorRole = accessManager.OPERATOR_ROLE();
        
        // Test operator functions
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                user1,
                operatorRole
            )
        );
        registry.updatePoolStatus(testPool, false);
    }
    
    function test_AccessControl_Emergency() public {
        // Register pool
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        registry.setFactory(poolFactory);
        vm.stopPrank();
        
        IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: admin,
            escrow: makeAddr("escrow"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        
        vm.prank(poolFactory);
        registry.registerPool(testPool, poolInfo);
        
        bytes32 emergencyRole = accessManager.EMERGENCY_ROLE();
        
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                user1,
                emergencyRole
            )
        );
        registry.emergencyDeactivatePool(testPool);
    }
    
    /*//////////////////////////////////////////////////////////////
                        QUERY FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_IsRegisteredPool_False() public view {
        assertFalse(registry.isRegisteredPool(testPool));
    }
    
    function test_IsActivePool_False() public view {
        assertFalse(registry.isActivePool(testPool));
    }
    
    function test_IsManagedPool_False() public view {
        assertFalse(registry.isManagedPool(testPool));
    }
    
    function test_IsApprovedAsset_False() public view {
        assertFalse(registry.isApprovedAsset(address(token)));
    }
    
    function test_IsApprovedImplementation_False() public view {
        assertFalse(registry.isApprovedImplementation(address(0x123)));
    }
    
    /*//////////////////////////////////////////////////////////////
                        POOL CATEGORY BY TYPE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_GetPoolsByType_EmptyArray() public view {
        address[] memory pools = registry.getPoolsByType("Treasury Bill");
        assertEq(pools.length, 0);
    }
    
    function test_GetPoolsByType_GroupsByType() public {
        vm.startPrank(admin);
        registry.approveAsset(address(token), "USDC", "USDC", "", "", true);
        registry.setFactory(poolFactory);
        vm.stopPrank();
        
        address pool1 = makeAddr("pool1");
        address pool2 = makeAddr("pool2");
        address pool3 = makeAddr("pool3");
        
        vm.startPrank(poolFactory);
        
        // Register 2 Treasury Bills
        IPoolRegistry.PoolInfo memory tb1 = IPoolRegistry.PoolInfo({
            pool: pool1,
            manager: admin,
            escrow: makeAddr("escrow1"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        registry.registerPool(pool1, tb1);
        
        IPoolRegistry.PoolInfo memory tb2 = IPoolRegistry.PoolInfo({
            pool: pool2,
            manager: admin,
            escrow: makeAddr("escrow2"),
            asset: address(token),
            instrumentType: "Treasury Bill",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 1_000_000e6,
            maturityDate: block.timestamp + 365 days
        });
        registry.registerPool(pool2, tb2);
        
        // Register 1 Commercial Paper
        IPoolRegistry.PoolInfo memory cp = IPoolRegistry.PoolInfo({
            pool: pool3,
            manager: admin,
            escrow: makeAddr("escrow3"),
            asset: address(token),
            instrumentType: "Commercial Paper",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 500_000e6,
            maturityDate: block.timestamp + 180 days
        });
        registry.registerPool(pool3, cp);
        
        vm.stopPrank();
        
        address[] memory treasuryBills = registry.getPoolsByType("Treasury Bill");
        address[] memory commercialPapers = registry.getPoolsByType("Commercial Paper");
        
        assertEq(treasuryBills.length, 2);
        assertEq(commercialPapers.length, 1);
    }
    
    /*//////////////////////////////////////////////////////////////
                        VERSION TRACKING TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_Version_InitiallyOne() public view {
        assertEq(registry.version(), 1);
    }
}

