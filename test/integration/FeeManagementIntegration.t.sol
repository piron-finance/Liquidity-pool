// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../fixtures/BaseTest.sol";
import "../../src/FeeManager.sol";
import "../../src/PoolRegistry.sol";
import "../../src/factories/PoolFactory.sol";
import "../../src/LiquidityPool.sol";
import "../../src/escrows/PoolEscrow.sol";
import "../../src/Manager.sol";
import "../../src/AccessManager.sol";
import "../../src/interfaces/IFeeManager.sol";
import "../../src/interfaces/IPoolFactory.sol";
import "../../src/types/IPoolTypes.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title TestPoolRegistry
 * @notice Helper contract that grants initial roles during initialization
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

        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(accessManager.ASSET_MANAGER_ROLE(), _initialAdmin);
        _grantRole(accessManager.POOL_CREATOR_ROLE(), _initialAdmin);
        _grantRole(accessManager.OPERATOR_ROLE(), _operator);
        _grantRole(accessManager.EMERGENCY_ROLE(), _emergency);
        _grantRole(accessManager.MULTISIG_ADMIN_ROLE(), _initialAdmin);
        _grantRole(accessManager.OPERATOR_ROLE(), _emergency);
    }
}

/**
 * @title FeeManagementIntegration
 * @notice Integration test for FeeManager with pools
 * @dev Tests expense ratios, transaction fees, and performance fees
 * 
 * TEST COVERAGE:
 * - Expense ratio accrual over time
 * - Transaction fee collection (protocol, SPV, management, performance)
 * - Early withdrawal penalties
 * - Fee distribution to treasury
 * - Performance fee calculations
 */
contract FeeManagementIntegration is BaseTest {
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STATE VARIABLES ////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    MockERC20 public token;
    AccessManager public accessManager;
    FeeManager public feeManager;
    PoolRegistry public registry;
    Manager public manager;
    PoolFactory public factory;
    LiquidityPool public poolImpl;
    PoolEscrow public escrowImpl;
    
    LiquidityPool public pool;
    address public poolAddress;
    address public escrowAddress;
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// CONSTANTS //////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    uint256 constant TARGET_RAISE = 100_000e6;
    uint256 constant DISCOUNT_RATE = 500; // 5%
    uint256 constant EPOCH_DURATION = 7 days;
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EVENTS /////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    event ExpenseRatioAccrued(address indexed pool, uint256 amount, uint256 timestamp);
    event TransactionFeeCollected(address indexed pool, address indexed asset, uint256 amount, string feeType);
    event TreasuryDeposit(address indexed asset, uint256 amount, uint256 newBalance);
    
    function setUp() public override {
        super.setUp();
        
        // Deploy token
        token = new MockERC20("Mock USDC", "USDC", 6);
        token.mint(user1, INITIAL_BALANCE);
        token.mint(user2, INITIAL_BALANCE);
        token.mint(spv, INITIAL_BALANCE * 2);
        
        // Deploy AccessManager
        accessManager = new AccessManager(admin, spv, operator, emergency, multisigAdmin);
        
        // Deploy FeeManager
        feeManager = new FeeManager(address(accessManager), treasury);
        
        // Deploy and initialize PoolRegistry (using TestPoolRegistry to grant initial roles)
        TestPoolRegistry registryImpl = new TestPoolRegistry();
        bytes memory registryInit = abi.encodeWithSignature(
            "initialize(address,address,address,address,address)",
            address(accessManager),
            admin,
            admin,
            operator,
            emergency
        );
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryInit);
        registry = PoolRegistry(address(registryProxy));
        
        // Approve asset
        vm.prank(admin);
        registry.approveAsset(address(token), "Mock USDC", "USDC", "", "", true);
        
        // Deploy and initialize Manager
        Manager managerImpl = new Manager();
        bytes memory managerInit = abi.encodeWithSignature(
            "initialize(address,address,address)",
            address(registry),
            address(accessManager),
            admin
        );
        ERC1967Proxy managerProxy = new ERC1967Proxy(address(managerImpl), managerInit);
        manager = Manager(address(managerProxy));
        
        // Deploy implementations
        poolImpl = new LiquidityPool();
        escrowImpl = new PoolEscrow();
        
        // Deploy and initialize PoolFactory
        PoolFactory factoryImpl = new PoolFactory();
        bytes memory factoryInit = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address)",
            address(registry),
            address(manager),
            address(accessManager),
            admin,
            address(poolImpl),
            address(escrowImpl)
        );
        ERC1967Proxy factoryProxy = new ERC1967Proxy(address(factoryImpl), factoryInit);
        factory = PoolFactory(address(factoryProxy));
        
        // Set factory in registry
        vm.prank(admin);
        registry.setFactory(address(factory));
        
        // Create a pool for testing
        _createTestPool();
    }
    
    function _createTestPool() internal {
        uint256 maturityDate = block.timestamp + EPOCH_DURATION + 30 days;
        
        IPoolFactory.PoolConfig memory config = IPoolFactory.PoolConfig({
            asset: address(token),
            instrumentType: IPoolTypes.InstrumentType.DISCOUNTED,
            instrumentName: "TEST-FEE",
            targetRaise: TARGET_RAISE,
            epochDuration: EPOCH_DURATION,
            maturityDate: maturityDate,
            discountRate: DISCOUNT_RATE,
            spvAddress: spv,
            couponDates: new uint256[](0),
            couponRates: new uint256[](0),
            minimumFundingThreshold: 8000
        });
        
        vm.prank(admin);
        (poolAddress, escrowAddress) = factory.createPool(config);
        pool = LiquidityPool(poolAddress);
    }
    
    /**
     * @notice Test expense ratio accrual over time
     * @dev Tests: set ratio → deposit → time passes → accrue fees based on time elapsed
     */
    function test_feeManager_expenseRatioAccrual() public {
        console.log("\n=== TEST: Expense Ratio Accrual Over Time ===");
        
        // Set expense ratio for pool (0.8% annually = 80 bps)
        console.log("\nStep 1: Admin setting expense ratio...");
        console.log("  Pool:", poolAddress);
        console.log("  Expense Ratio: 80 bps (0.8% annually)");
        
        vm.prank(admin);
        feeManager.setPoolExpenseRatio(poolAddress, 80);
        
        console.log("  Expense Ratio Set:", feeManager.getPoolExpenseRatio(poolAddress));
        assertEq(feeManager.getPoolExpenseRatio(poolAddress), 80, "Expense ratio not set");
        
        // Users deposit to create pool value
        console.log("\nStep 2: User depositing to create pool value...");
        uint256 depositAmount = 100_000e6;
        console.log("  Deposit Amount:", depositAmount);
        
        vm.startPrank(user1);
        token.approve(poolAddress, depositAmount);
        pool.deposit(depositAmount, user1);
        vm.stopPrank();
        
        console.log("  Total Assets in Pool:", manager.totalRaised());
        
        // Fast forward 180 days (half a year)
        console.log("\nStep 3: Fast-forwarding 180 days (half year)...");
        console.log("  Current Time:", block.timestamp);
        vm.warp(block.timestamp + 180 days);
        console.log("  New Time:", block.timestamp);
        console.log("  Days Elapsed: 180");
        
        // Accrue expense ratio
        console.log("\nStep 4: Operator accruing expense ratio...");
        uint256 poolTotalAssets = manager.totalRaised();
        console.log("  Pool Total Assets:", poolTotalAssets);
        
        vm.prank(operator);
        uint256 accruedFees = feeManager.accrueExpenseRatio(poolAddress, poolTotalAssets);
        
        // Expected: (100,000 * 80 bps * 180 days) / (10000 * 365 days)
        // = (100,000 * 0.008 * 180) / 365 = ~394.52 USDC
        uint256 expectedFees = (poolTotalAssets * 80 * 180 days) / (10000 * 365 days);
        
        console.log("  Accrued Fees:", accruedFees);
        console.log("  Expected Fees:", expectedFees);
        console.log("  Formula: (Assets * 80 bps * 180 days) / (10000 * 365 days)");
        console.log("  Stored Accrued Fees:", feeManager.getAccruedExpenseFees(poolAddress));
        
        assertApproxEqAbs(accruedFees, expectedFees, 1e6, "Accrued fees mismatch");
        assertEq(feeManager.getAccruedExpenseFees(poolAddress), accruedFees, "Stored accrued fees mismatch");
        
        console.log("\n=== TEST PASSED ===\n");
    }
    
    /**
     * @notice Test transaction fee collection and treasury deposit
     * @dev Tests: set fee config → calculate protocol fee → collect → deposit to treasury
     */
    function test_feeManager_transactionFeeCollection() public {
        console.log("\n=== TEST: Transaction Fee Collection ===");
        
        // Configure protocol fee (0.06% = 6 bps)
        console.log("\nStep 1: Admin configuring fee structure...");
        IFeeManager.FeeConfig memory feeConfig = IFeeManager.FeeConfig({
            protocolFee: 6,
            spvFee: 100,
            managementFee: 200,
            performanceFee: 1000,
            earlyWithdrawalFee: 50,
            refundGasFee: 10,
            isActive: true
        });
        console.log("  Protocol Fee: 6 bps (0.06%)");
        console.log("  SPV Fee: 100 bps (1%)");
        console.log("  Management Fee: 200 bps (2%)");
        console.log("  Performance Fee: 1000 bps (10%)");
        
        vm.prank(admin);
        feeManager.setPoolFeeConfig(poolAddress, feeConfig);
        console.log("  Fee Config Set Successfully");
        
        // User deposits
        console.log("\nStep 2: User depositing...");
        uint256 depositAmount = 100_000e6;
        console.log("  Deposit Amount:", depositAmount);
        
        vm.startPrank(user1);
        token.approve(poolAddress, depositAmount);
        pool.deposit(depositAmount, user1);
        vm.stopPrank();
        
        // Calculate protocol fee
        console.log("\nStep 3: Calculating protocol fee...");
        uint256 protocolFee = feeManager.calculateProtocolFee(poolAddress, depositAmount);
        console.log("  Deposit Amount:", depositAmount);
        console.log("  Protocol Fee (0.06%):", protocolFee);
        console.log("  Expected:", (depositAmount * 6) / 10000);
        assertEq(protocolFee, (depositAmount * 6) / 10000, "Protocol fee calculation mismatch");
        
        // Simulate fee collection (in real scenario, pool would collect this)
        console.log("\nStep 4: Collecting transaction fee to treasury...");
        token.mint(operator, protocolFee);
        
        uint256 treasuryBalanceBefore = feeManager.getTreasuryBalance(address(token));
        console.log("  Treasury Balance Before:", treasuryBalanceBefore);
        
        vm.startPrank(operator);
        token.approve(address(feeManager), protocolFee);
        feeManager.collectTransactionFee(poolAddress, address(token), protocolFee, "deposit_fee");
        vm.stopPrank();
        
        uint256 treasuryBalanceAfter = feeManager.getTreasuryBalance(address(token));
        console.log("  Treasury Balance After:", treasuryBalanceAfter);
        console.log("  Fee Collected:", treasuryBalanceAfter - treasuryBalanceBefore);
        console.log("  Transaction Fees Tracked:", feeManager.getTransactionFees(poolAddress, address(token)));
        
        assertEq(treasuryBalanceAfter - treasuryBalanceBefore, protocolFee, "Treasury balance not updated");
        assertEq(feeManager.getTransactionFees(poolAddress, address(token)), protocolFee, "Transaction fees not tracked");
        
        console.log("\n=== TEST PASSED ===\n");
    }
    
    /**
     * @notice Test performance fee calculation on profits
     * @dev Tests: set performance fee → simulate profit → calculate 10% performance fee
     */
    function test_feeManager_performanceFeeCalculation() public {
        console.log("\n=== TEST: Performance Fee Calculation ===");
        
        // Configure performance fee (10% = 1000 bps)
        console.log("\nStep 1: Configuring performance fee...");
        IFeeManager.FeeConfig memory feeConfig = IFeeManager.FeeConfig({
            protocolFee: 6,
            spvFee: 100,
            managementFee: 200,
            performanceFee: 1000,
            earlyWithdrawalFee: 50,
            refundGasFee: 10,
            isActive: true
        });
        console.log("  Performance Fee: 1000 bps (10%)");
        
        vm.prank(admin);
        feeManager.setPoolFeeConfig(poolAddress, feeConfig);
        console.log("  Fee Config Set");
        
        // Simulate profit
        console.log("\nStep 2: Simulating pool profit...");
        uint256 profit = 10_000e6; // 10k profit
        console.log("  Pool Profit:", profit);
        
        console.log("\nStep 3: Calculating performance fee...");
        uint256 performanceFee = feeManager.calculatePerformanceFee(poolAddress, profit);
        console.log("  Performance Fee (10% of profit):", performanceFee);
        console.log("  Expected:", (profit * 1000) / 10000);
        
        // Expected: 10% of 10k = 1k
        assertEq(performanceFee, 1_000e6, "Performance fee calculation mismatch");
        
        console.log("\nSUCCESS: Performance fee = 1,000 USDC (10% of 10,000 profit)");
        console.log("=== TEST PASSED ===\n");
    }
    
    /**
     * @notice Test treasury deposit and withdrawal functionality
     * @dev Tests: deposit to treasury → admin withdraws → balance tracking
     */
    function test_feeManager_treasuryManagement() public {
        console.log("\n=== TEST: Treasury Management ===");
        
        // Mint tokens to operator for deposit
        console.log("\nStep 1: Preparing treasury deposit...");
        uint256 depositAmount = 50_000e6;
        token.mint(operator, depositAmount);
        console.log("  Deposit Amount:", depositAmount);
        console.log("  Operator Balance:", token.balanceOf(operator));
        
        // Operator deposits to treasury
        console.log("\nStep 2: Operator depositing to treasury...");
        uint256 treasuryBefore = feeManager.getTreasuryBalance(address(token));
        console.log("  Treasury Balance Before:", treasuryBefore);
        
        vm.startPrank(operator);
        token.approve(address(feeManager), depositAmount);
        feeManager.depositToTreasury(address(token), depositAmount);
        vm.stopPrank();
        
        console.log("  Treasury Balance After:", feeManager.getTreasuryBalance(address(token)));
        console.log("  Deposited:", depositAmount);
        assertEq(feeManager.getTreasuryBalance(address(token)), depositAmount, "Treasury balance mismatch");
        
        // Admin withdraws from treasury
        console.log("\nStep 3: Admin withdrawing from treasury...");
        uint256 withdrawAmount = 20_000e6;
        console.log("  Withdraw Amount:", withdrawAmount);
        console.log("  Treasury Address:", treasury);
        console.log("  Treasury Balance Before Withdrawal:", token.balanceOf(treasury));
        
        vm.prank(admin);
        feeManager.withdrawFromTreasury(address(token), treasury, withdrawAmount);
        
        console.log("  Treasury Balance After Withdrawal:", token.balanceOf(treasury));
        console.log("  FeeManager Treasury Balance:", feeManager.getTreasuryBalance(address(token)));
        console.log("  Remaining:", depositAmount - withdrawAmount);
        
        assertEq(token.balanceOf(treasury), withdrawAmount, "Treasury recipient balance mismatch");
        assertEq(feeManager.getTreasuryBalance(address(token)), depositAmount - withdrawAmount, "Treasury balance after withdrawal mismatch");
        
        console.log("\n=== TEST PASSED ===\n");
    }
    
    function test_feeManager_defaultFeeConfigForNewPool() public {
        // Create new pool without custom fee config
        uint256 maturityDate = block.timestamp + EPOCH_DURATION + 30 days;
        
        IPoolFactory.PoolConfig memory config = IPoolFactory.PoolConfig({
            asset: address(token),
            instrumentType: IPoolTypes.InstrumentType.DISCOUNTED,
            instrumentName: "TEST-DEFAULT-FEE",
            targetRaise: TARGET_RAISE,
            epochDuration: EPOCH_DURATION,
            maturityDate: maturityDate,
            discountRate: DISCOUNT_RATE,
            spvAddress: spv,
            couponDates: new uint256[](0),
            couponRates: new uint256[](0),
            minimumFundingThreshold: 8000
        });
        
        vm.prank(admin);
        (address newPoolAddress,) = factory.createPool(config);
        
        // Get fee config - should return default
        IFeeManager.FeeConfig memory poolFeeConfig = feeManager.getPoolFeeConfig(newPoolAddress);
        IFeeManager.FeeConfig memory defaultConfig = feeManager.defaultFeeConfig();
        
        assertEq(poolFeeConfig.protocolFee, defaultConfig.protocolFee, "Default protocol fee not applied");
        assertEq(poolFeeConfig.performanceFee, defaultConfig.performanceFee, "Default performance fee not applied");
    }
    
    function test_feeManager_expenseRatioPartialPayment() public {
        // Set expense ratio
        vm.prank(admin);
        feeManager.setPoolExpenseRatio(poolAddress, 80);
        
        // Users deposit
        uint256 depositAmount = 100_000e6;
        vm.startPrank(user1);
        token.approve(poolAddress, depositAmount);
        pool.deposit(depositAmount, user1);
        vm.stopPrank();
        
        // Accrue fees over 180 days
        vm.warp(block.timestamp + 180 days);
        
        vm.prank(operator);
        uint256 accruedFees = feeManager.accrueExpenseRatio(poolAddress, depositAmount);
        
        assertGt(accruedFees, 0, "No fees accrued");
        
        // Partial payment
        uint256 partialPayment = accruedFees / 2;
        
        vm.prank(operator);
        feeManager.reduceAccruedFees(poolAddress, partialPayment);
        
        assertEq(feeManager.getAccruedExpenseFees(poolAddress), accruedFees - partialPayment, "Accrued fees not reduced");
    }
    
    function test_feeManager_setDefaultExpenseRatio() public {
        // Create new pool
        uint256 maturityDate = block.timestamp + EPOCH_DURATION + 30 days;
        
        IPoolFactory.PoolConfig memory config = IPoolFactory.PoolConfig({
            asset: address(token),
            instrumentType: IPoolTypes.InstrumentType.DISCOUNTED,
            instrumentName: "TEST-DEFAULT-EXPENSE",
            targetRaise: TARGET_RAISE,
            epochDuration: EPOCH_DURATION,
            maturityDate: maturityDate,
            discountRate: DISCOUNT_RATE,
            spvAddress: spv,
            couponDates: new uint256[](0),
            couponRates: new uint256[](0),
            minimumFundingThreshold: 8000
        });
        
        vm.prank(admin);
        (address newPoolAddress,) = factory.createPool(config);
        
        // Set default expense ratio
        vm.prank(operator);
        feeManager.setDefaultExpenseRatio(newPoolAddress);
        
        assertEq(feeManager.getPoolExpenseRatio(newPoolAddress), 80, "Default expense ratio not set (80 bps = 0.8%)");
    }
}


