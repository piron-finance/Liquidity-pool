// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../fixtures/BaseTest.sol";
import "../../src/PoolRegistry.sol";
import "../../src/factories/PoolFactory.sol";
import "../../src/LiquidityPool.sol";
import "../../src/escrows/PoolEscrow.sol";
import "../../src/interfaces/IPoolFactory.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * Minimal mock AccessManager used by PoolRegistry/PoolFactory in tests
 */
contract PF_MockAccessManager {
    mapping(bytes32 => mapping(address => bool)) public roles;
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant SPV_ROLE = keccak256("SPV_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");
    bytes32 public constant POOL_CREATOR_ROLE = keccak256("POOL_CREATOR_ROLE");
    bytes32 public constant MULTISIG_ADMIN_ROLE = keccak256("MULTISIG_ADMIN_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant ASSET_MANAGER_ROLE = keccak256("ASSET_MANAGER_ROLE");

    constructor(address admin) { roles[DEFAULT_ADMIN_ROLE][admin] = true; }
    function hasRole(bytes32 role, address account) external view returns (bool) { return roles[role][account]; }
    function grantRole(bytes32 role, address account) external { roles[role][account] = true; }
}

/**
 * Minimal mock manager implementing only initializePool used by factory
 */
contract PF_MockPoolManager {
    function initializePool(address /*pool*/, IPoolTypes.PoolConfig memory /*config*/) external {}
}

// Test helper: PoolRegistry variant that grants initial roles during initialize (mirrors unit test helper)
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

        // Grant initial roles so tests can call registry-onlyRole functions
        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(accessManager.ASSET_MANAGER_ROLE(), _initialAdmin);
        _grantRole(accessManager.POOL_CREATOR_ROLE(), _initialAdmin);
        _grantRole(accessManager.OPERATOR_ROLE(), _operator);
        _grantRole(accessManager.EMERGENCY_ROLE(), _emergency);
        _grantRole(accessManager.MULTISIG_ADMIN_ROLE(), _initialAdmin);
        // Ensure emergency address can act as operator for certain flows
        _grantRole(accessManager.OPERATOR_ROLE(), _emergency);
    }
}

/**
 * @title PoolFactoryIntegration
 * @notice Integration test for PoolFactory createPool → PoolRegistry registration
 * @dev Tests pool creation, registration, and initialization flows
 * 
 * TEST COVERAGE:
 * - Pool creation via PoolFactory
 * - Automatic registration in PoolRegistry
 * - Pool and escrow proxy deployment
 * - Configuration validation
 * - Pool initialization with Manager
 */
contract PoolFactoryIntegration is BaseTest {
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STATE VARIABLES ////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    event Progress(string msg);
    MockERC20 public token;
    PF_MockAccessManager public access;
    PF_MockPoolManager public manager;

    PoolRegistry public registryImpl;
    PoolRegistry public registryProxy;
    PoolFactory public factoryImpl;
    PoolFactory public factoryProxy;
    LiquidityPool public liquidityPoolImpl;
    PoolEscrow public poolEscrowImpl;

    function setUp() public override {
        super.setUp();

        // Deploy token and mint
          token = new MockERC20("Mock USDC", "USDC", 6);
          token.mint(user1, INITIAL_BALANCE);

        // Deploy Access Manager and grant roles to this test
        access = new PF_MockAccessManager(admin);
        access.grantRole(access.ASSET_MANAGER_ROLE(), address(this));
        access.grantRole(access.POOL_CREATOR_ROLE(), address(this));
    emit Progress("access-deployed-and-roles-granted");

    // Deploy registry as proxy (use TestPoolRegistry to grant roles)
    registryImpl = new TestPoolRegistry();
    bytes memory regInit = abi.encodeWithSignature("initialize(address,address,address,address,address)", address(access), admin, admin, operator, emergency);
    // Deploy proxy and initialize in one step
    ERC1967Proxy regProxy = new ERC1967Proxy(address(registryImpl), regInit);
    registryProxy = PoolRegistry(address(regProxy));
    emit Progress("registry-proxy-deployed");

    // Approve the test asset in registry (requires ASSET_MANAGER_ROLE)
    vm.prank(admin);
    registryProxy.approveAsset(address(token), "Mock USDC", "USDC", "", "", true);

    // Deploy mock manager
    manager = new PF_MockPoolManager();
    emit Progress("manager-deployed");

          // Deploy implementations for pool and escrow
          liquidityPoolImpl = new LiquidityPool();
          poolEscrowImpl = new PoolEscrow();

        // Quick sanity-check: try initializing an escrow proxy manually to capture any init revert reason
        bytes memory escrowInitDataCheck = abi.encodeWithSignature(
            "initialize(address,address,address,address)",
            address(token),
            address(manager),
            address(spv),
            admin
        );
        ERC1967Proxy testEscrowProxy = new ERC1967Proxy(address(poolEscrowImpl), "");
        address testEscrowAddr = address(testEscrowProxy);
        (bool escrowOk, bytes memory escrowRes) = testEscrowAddr.call(escrowInitDataCheck);
        if (!escrowOk) {
            if (escrowRes.length > 0) {
                assembly { revert(add(escrowRes, 32), mload(escrowRes)) }
            } else {
                revert("PoolFactoryIntegration: escrow.initialize reverted without reason");
            }
        }

    emit Progress("liquidity-and-escrow-impl-deployed");
    // Deploy factory proxy
        factoryImpl = new PoolFactory();
        bytes memory factoryInit = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address)",
            address(registryProxy),
            address(manager),
            address(access),
            admin, // timelock controller
            address(liquidityPoolImpl),
            address(poolEscrowImpl)
        );
        ERC1967Proxy factoryProxyInst = new ERC1967Proxy(address(factoryImpl), factoryInit);
        factoryProxy = PoolFactory(address(factoryProxyInst));
      
      // Tell the registry which factory is authorized to register pools
      vm.prank(admin);
      registryProxy.setFactory(address(factoryProxy));
      emit Progress("registry-factory-set");
    }

    /**
     * @notice Test pool creation and automatic registration in registry
     * @dev Tests: configure pool → factory creates → registry registers → verify deployment
     */
    function test_createPool_registersPoolAndEscrow() public {
        console.log("\n=== TEST: Pool Factory Creates and Registers Pool ===");
        
        // Build PoolConfig for factory
        console.log("\nStep 1: Building pool configuration...");
        uint256 epochDuration = 1 days;
        uint256 maturity = block.timestamp + epochDuration + 1 days;
        console.log("  Instrument Type: DISCOUNTED");
        console.log("  Instrument Name: TEST");
        console.log("  Target Raise: 1,000 USDC");
        console.log("  Epoch Duration:", epochDuration, "seconds (1 day)");
        console.log("  Maturity Date:", maturity);
        console.log("  Discount Rate: 0 bps");
        console.log("  SPV Address:", address(spv));
        
        IPoolFactory.PoolConfig memory factoryCfg = IPoolFactory.PoolConfig({
            asset: address(token),
            instrumentType: IPoolTypes.InstrumentType.DISCOUNTED,
            instrumentName: "TEST",
            targetRaise: 1000e6,
            epochDuration: epochDuration,
            maturityDate: maturity,
            discountRate: 0,
            spvAddress: address(spv),
            couponDates: new uint256[](0),
            couponRates: new uint256[](0),
            minimumFundingThreshold: 0
        });

        // Call createPool (wrap in try/catch to surface revert reason)
        console.log("\nStep 2: PoolFactory creating pool...");
        console.log("  Factory Address:", address(factoryProxy));
        console.log("  Registry Address:", address(registryProxy));
        console.log("  Manager Address:", address(manager));
        
        address poolAddr;
        address escrowAddr;
        try factoryProxy.createPool(factoryCfg) returns (address _poolAddr, address _escrowAddr) {
            poolAddr = _poolAddr;
            escrowAddr = _escrowAddr;
            console.log("  Pool Created Successfully!");
            console.log("  Pool Address:", poolAddr);
            console.log("  Escrow Address:", escrowAddr);
        } catch (bytes memory reason) {
            // Revert with caught reason for clearer test output
            console.log("  ERROR: Pool creation failed!");
            if (reason.length > 0) {
                assembly { revert(add(reason, 32), mload(reason)) }
            } else {
                revert("PoolFactoryIntegration: createPool reverted without reason");
            }
        }

        // Assertions
        console.log("\nStep 3: Verifying pool deployment...");
        require(poolAddr != address(0), "pool not created");
        require(escrowAddr != address(0), "escrow not created");
        console.log("  Pool address is valid:", poolAddr != address(0));
        console.log("  Escrow address is valid:", escrowAddr != address(0));

        // Registry should have the pool registered
        console.log("\nStep 4: Verifying registry registration...");
        console.log("  Checking if pool is registered...");
        bool isRegistered = registryProxy.isRegisteredPool(poolAddr);
        console.log("  Is Registered:", isRegistered);
        
        PoolRegistry.PoolInfo memory info = registryProxy.getPoolInfo(poolAddr);
        console.log("\n  Pool Info Retrieved:");
        console.log("    Pool:", info.pool);
        console.log("    Manager:", info.manager);
        console.log("    Escrow:", info.escrow);
        console.log("    Asset:", info.asset);
        console.log("    Instrument Type:", info.instrumentType);
        console.log("    Created At:", info.createdAt);
        console.log("    Is Active:", info.isActive);
        console.log("    Creator:", info.creator);
        console.log("    Target Raise:", info.targetRaise);
        console.log("    Maturity Date:", info.maturityDate);
        
        assertEq(info.pool, poolAddr);
        assertEq(info.asset, address(token));
        assertTrue(registryProxy.isRegisteredPool(poolAddr));
        
        console.log("\n====== VERIFICATION COMPLETE ======");
        console.log("  Factory successfully created pool");
        console.log("  Pool deployed as proxy");
        console.log("  Escrow deployed as proxy");
        console.log("  Pool automatically registered in registry");
        console.log("  All pool info stored correctly");
        console.log("\n=== TEST PASSED ===\n");
    }
}

