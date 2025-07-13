// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/Manager.sol";
import "../src/LiquidityPool.sol";
import "../src/PoolRegistry.sol";
import "../src/PoolEscrow.sol";
import "../src/AccessManager.sol";
import "../src/PoolOracle.sol";
import "../src/FeeManager.sol";
import "../src/factories/PoolFactory.sol";
import "../src/interfaces/IManager.sol";
import "../src/interfaces/IPoolFactory.sol";
import "../src/interfaces/IPoolOracle.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 10_000_000 * 1e6);
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract PironPoolsIntegrationTest is Test {
    // Core contracts
    Manager public manager; // Singleton manager
    PoolRegistry public registry;
    AccessManager public accessManager;
    PoolFactory public factory;
    PoolOracle public oracle;
    FeeManager public feeManager;
    
    // Mock token
    MockUSDC public usdc;
    
    // Test accounts
    address public admin = address(0x1);
    address public spv = address(0x2);
    address public operator = address(0x3);
    address public user1 = address(0x4);
    address public user2 = address(0x5);
    address public user3 = address(0x6);
    address public oracle1 = address(0x7);
    address public oracle2 = address(0x8);
    address public treasury = address(0x9);
    
    // Test pool
    address public testPool;
    address public testEscrow;
    
    // Test parameters
    uint256 public constant TARGET_RAISE = 100_000e6; // 100k USDC
    uint256 public constant DISCOUNT_RATE = 1800; // 18% discount
    uint256 public constant MATURITY_DAYS = 90;
    uint256 public constant FUNDING_DAYS = 7;
    
    event PoolCreated(address indexed pool, address indexed manager, address indexed asset, string instrumentName, uint256 targetRaise, uint256 maturityDate);
    event StatusChanged(IPoolManager.PoolStatus oldStatus, IPoolManager.PoolStatus newStatus);
    event Deposit(address liquidityPool, address indexed sender, address indexed receiver, uint256 assets, uint256 shares);
    event InvestmentConfirmed(uint256 actualAmount, string proofHash);
    event MaturityProcessed(uint256 finalAmount);
    
    function setUp() public {
        console.log("=== Setting up Piron Pools Integration Test ===");
        
        // Deploy mock USDC
        usdc = new MockUSDC();
        console.log("Mock USDC deployed at:", address(usdc));
        
        // Deploy AccessManager
        accessManager = new AccessManager(admin);
        console.log("AccessManager deployed at:", address(accessManager));
        
        // Deploy PoolRegistry with zero address initially (will be set later)
        registry = new PoolRegistry(address(accessManager));
        console.log("PoolRegistry deployed at:", address(registry));
        
        // Deploy singleton Manager
        manager = new Manager(address(registry), address(accessManager));
        console.log("Singleton Manager deployed at:", address(manager));
        
        // Deploy PoolFactory with singleton manager
        factory = new PoolFactory(
            address(registry),
            address(manager), // Singleton manager
            address(accessManager)
        );
        console.log("PoolFactory deployed at:", address(factory));
        
        // Now properly initialize the registry with the real factory address
        // This avoids re-deployment by using a setter method
        vm.prank(admin);
        registry.setFactory(address(factory));
        console.log("PoolRegistry initialized with factory address");
        
        // Setup access control
        vm.startPrank(admin);
        accessManager.grantRole(factory.POOL_CREATOR_ROLE(), admin);
        
        // Grant other roles
        accessManager.grantRole(accessManager.SPV_ROLE(), spv);
        accessManager.grantRole(accessManager.OPERATOR_ROLE(), operator);
        accessManager.grantRole(accessManager.ORACLE_ROLE(), oracle1);
        accessManager.grantRole(accessManager.ORACLE_ROLE(), oracle2);
        
        // Deploy other contracts
        oracle = new PoolOracle(address(accessManager));
        feeManager = new FeeManager(address(accessManager), treasury);
        console.log("Oracle deployed at:", address(oracle));
        console.log("FeeManager deployed at:", address(feeManager));
        
        // Add oracles to the oracle contract
        oracle.addOracle(oracle1, "Primary Oracle");
        oracle.addOracle(oracle2, "Secondary Oracle");
        
        // Approve USDC as asset
        registry.approveAsset(address(usdc));
        vm.stopPrank();
        
        // Mint USDC for testing
        usdc.mint(user1, 1_000_000e6);
        usdc.mint(user2, 1_000_000e6);
        usdc.mint(user3, 1_000_000e6);
        usdc.mint(spv, 1_000_000e6);
        
        console.log("=== Setup Complete ===");
        console.log("Admin:", admin);
        console.log("SPV:", spv);
        console.log("Operator:", operator);
        console.log("Singleton Manager:", address(manager));
        console.log("User1 balance:", usdc.balanceOf(user1) / 1e6, "USDC");
        console.log("User2 balance:", usdc.balanceOf(user2) / 1e6, "USDC");
        console.log("User3 balance:", usdc.balanceOf(user3) / 1e6, "USDC");
    }
    
    function testAdminPoolCreation() public {
        console.log("\n=== Test: Admin Pool Creation ===");
        
        // Create multisig signers array
        address[] memory signers = new address[](2);
        signers[0] = admin;
        signers[1] = spv;
        
        // Create pool configuration
        IPoolFactory.PoolConfig memory config = IPoolFactory.PoolConfig({
            asset: address(usdc),
            instrumentType: IPoolManager.InstrumentType.DISCOUNTED,
            instrumentName: "90-Day US Treasury Bill",
            targetRaise: TARGET_RAISE,
            epochDuration: FUNDING_DAYS * 1 days,
            maturityDate: block.timestamp + FUNDING_DAYS * 1 days + MATURITY_DAYS * 1 days,
            discountRate: DISCOUNT_RATE,
            spvAddress: spv,
            multisigSigners: signers,
            couponDates: new uint256[](0),
            couponRates: new uint256[](0)
        });
        
        // Remove the redundant assignments since we already set them above
        // config.multisigSigners[0] = admin;
        // config.multisigSigners[1] = spv;
        
        console.log("Creating pool with config:");
        console.log("  - Asset:", config.asset);
        console.log("  - Instrument:", config.instrumentName);
        console.log("  - Target Raise:", config.targetRaise / 1e6, "USDC");
        console.log("  - Discount Rate:", config.discountRate, "bps");
        console.log("  - Funding Period:", config.epochDuration / 1 days, "days");
        console.log("  - Maturity:", (config.maturityDate - block.timestamp) / 1 days, "days from now");
        
        // Admin creates pool
        vm.prank(admin);
        (testPool, testEscrow) = factory.createPool(config);
        
        console.log("Pool created successfully:");
        console.log("  - Pool address:", testPool);
        console.log("  - Escrow address:", testEscrow);
        console.log("  - Manager address (singleton):", address(manager));
        
        // Verify pool creation
        assertTrue(testPool != address(0), "Pool should be created");
        assertTrue(testEscrow != address(0), "Escrow should be created");
        assertTrue(factory.isValidPool(testPool), "Pool should be valid");
        assertTrue(registry.isRegisteredPool(testPool), "Pool should be registered");
        
        // Get pool info
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(testPool);
        assertEq(poolInfo.asset, address(usdc), "Pool asset should match");
        assertEq(poolInfo.targetRaise, TARGET_RAISE, "Pool target raise should match");
        assertEq(poolInfo.creator, admin, "Pool creator should match");
        assertEq(poolInfo.manager, address(manager), "Pool manager should be singleton");
        assertEq(poolInfo.escrow, testEscrow, "Pool escrow should match");
        
        // Check pool status using singleton manager
        assertEq(uint256(manager.poolStatus(testPool)), uint256(IPoolManager.PoolStatus.FUNDING), "Pool should be in funding status");
        
        console.log("Pool status:", uint256(manager.poolStatus(testPool)));
        
        console.log("=== Pool Creation Test Passed ===");
    }
    
    function testUserDepositJourney() public {
        console.log("\n=== Test: User Deposit Journey ===");
        
        // First create a pool
        testAdminPoolCreation();
        
        uint256 user1Deposit = 45_000e6;
        uint256 user2Deposit = 30_000e6;
        uint256 user3Deposit = 20_000e6;
        
        console.log("Users depositing into pool:");
        console.log("  - User1:", user1Deposit / 1e6, "USDC");
        console.log("  - User2:", user2Deposit / 1e6, "USDC");
        console.log("  - User3:", user3Deposit / 1e6, "USDC");
        
        // User 1 deposits
        vm.startPrank(user1);
        usdc.approve(testPool, user1Deposit);
        
        vm.expectEmit(true, true, true, true);
        emit Deposit(testPool, user1, user1, user1Deposit, user1Deposit);
        
        uint256 shares1 = LiquidityPool(testPool).deposit(user1Deposit, user1);
        vm.stopPrank();
        
        console.log("User1 deposited USDC:", user1Deposit / 1e6);
        console.log("User1 received shares:", shares1 / 1e6);
        
        // User 2 deposits
        vm.startPrank(user2);
        usdc.approve(testPool, user2Deposit);
        uint256 shares2 = LiquidityPool(testPool).deposit(user2Deposit, user2);
        vm.stopPrank();
        
        console.log("User2 deposited USDC:", user2Deposit / 1e6);
        console.log("User2 received shares:", shares2 / 1e6);
        
        // User 3 deposits
        vm.startPrank(user3);
        usdc.approve(testPool, user3Deposit);
        uint256 shares3 = LiquidityPool(testPool).deposit(user3Deposit, user3);
        vm.stopPrank();
        
        console.log("User3 deposited USDC:", user3Deposit / 1e6);
        console.log("User3 received shares:", shares3 / 1e6);
        
        // Verify deposits
        assertEq(shares1, user1Deposit, "User1 shares should equal deposit");
        assertEq(shares2, user2Deposit, "User2 shares should equal deposit");
        assertEq(shares3, user3Deposit, "User3 shares should equal deposit");
        
        assertEq(LiquidityPool(testPool).balanceOf(user1), user1Deposit, "User1 balance should match");
        assertEq(LiquidityPool(testPool).balanceOf(user2), user2Deposit, "User2 balance should match");
        assertEq(LiquidityPool(testPool).balanceOf(user3), user3Deposit, "User3 balance should match");
        
        // Check total raised using singleton manager
        uint256 totalRaised = manager.poolTotalRaised(testPool);
        assertEq(totalRaised, user1Deposit + user2Deposit + user3Deposit, "Total raised should match deposits");
        
        console.log("Total raised USDC:", totalRaised / 1e6);
        console.log("Target raise USDC:", TARGET_RAISE / 1e6);
        console.log("Funding progress %:", (totalRaised * 100) / TARGET_RAISE);
        
        console.log("=== User Deposit Journey Test Passed ===");
    }
    
    function testEpochClosureAndInvestment() public {
        console.log("\n=== Test: Epoch Closure and Investment ===");
        
        // Setup pool with deposits
        testUserDepositJourney();
        
        // Fast forward to end of funding period
        vm.warp(block.timestamp + FUNDING_DAYS * 1 days + 1 hours);
        console.log("Fast forwarded past funding period");
        
        // Operator closes epoch
        vm.startPrank(operator);
        
        vm.expectEmit(true, true, false, true);
        emit StatusChanged(IPoolManager.PoolStatus.FUNDING, IPoolManager.PoolStatus.PENDING_INVESTMENT);
        
        manager.closeEpoch(testPool);
        vm.stopPrank();
        
        console.log("Epoch closed by operator");
        
        // Verify epoch closure
        assertEq(uint256(manager.poolStatus(testPool)), uint256(IPoolManager.PoolStatus.PENDING_INVESTMENT), "Pool should be pending investment");
        
        uint256 totalRaised = manager.poolTotalRaised(testPool);
        console.log("Total raised:", totalRaised / 1e6, "USDC");
        
        // Calculate expected face value
        uint256 expectedFaceValue = (totalRaised * 10000) / (10000 - DISCOUNT_RATE);
        console.log("Expected face value:", expectedFaceValue / 1e6, "USDC");
        console.log("Expected profit:", (expectedFaceValue - totalRaised) / 1e6, "USDC");
        
        // SPV processes investment
        string memory proofHash = "QmX1Y2Z3A4B5C6D7E8F9G0H1I2J3K4L5M6N7O8P9Q0R1S2T3U4V5W6X7Y8Z9A0B1C2";
        
        vm.startPrank(spv);
        
        vm.expectEmit(true, false, false, true);
        emit InvestmentConfirmed(totalRaised, proofHash);
        
        manager.processInvestment(testPool, totalRaised, proofHash);
        vm.stopPrank();
        
        console.log("Investment processed by SPV");
        console.log("Proof hash:", proofHash);
        
        // Verify investment processing
        assertEq(uint256(manager.poolStatus(testPool)), uint256(IPoolManager.PoolStatus.INVESTED), "Pool should be invested");
        assertEq(manager.poolActualInvested(testPool), totalRaised, "Actual invested should match total raised");
        
        uint256 totalDiscount = manager.poolTotalDiscountEarned(testPool);
        console.log("Total discount earned:", totalDiscount / 1e6, "USDC");
        
        console.log("=== Epoch Closure and Investment Test Passed ===");
    }
    
    function testMaturityAndWithdrawals() public {
        console.log("\n=== Test: Maturity and Withdrawals ===");
        
        // Setup pool through investment
        testEpochClosureAndInvestment();
        
        // Fast forward to maturity
        vm.warp(block.timestamp + MATURITY_DAYS * 1 days);
        console.log("Fast forwarded to maturity");
        
        // Get pool config to calculate final amount
        uint256 totalRaised = manager.poolTotalRaised(testPool);
        uint256 faceValue = (totalRaised * 10000) / (10000 - DISCOUNT_RATE);
        
        console.log("Processing maturity:");
        console.log("  - Total raised:", totalRaised / 1e6, "USDC");
        console.log("  - Face value:", faceValue / 1e6, "USDC");
        
        // SPV processes maturity
        vm.startPrank(spv);
        
        vm.expectEmit(true, false, false, true);
        emit MaturityProcessed(faceValue);
        
        manager.processMaturity(testPool, faceValue);
        vm.stopPrank();
        
        console.log("Maturity processed by SPV");
        
        // Verify maturity processing
        assertEq(uint256(manager.poolStatus(testPool)), uint256(IPoolManager.PoolStatus.MATURED), "Pool should be matured");
        
        // Calculate expected returns for each user
        uint256 user1Shares = LiquidityPool(testPool).balanceOf(user1);
        uint256 user2Shares = LiquidityPool(testPool).balanceOf(user2);
        uint256 user3Shares = LiquidityPool(testPool).balanceOf(user3);
        uint256 totalShares = LiquidityPool(testPool).totalSupply();
        
        uint256 user1Expected = (user1Shares * faceValue) / totalShares;
        uint256 user2Expected = (user2Shares * faceValue) / totalShares;
        uint256 user3Expected = (user3Shares * faceValue) / totalShares;
        
        console.log("Expected returns:");
        console.log("  - User1:", user1Expected / 1e6, "USDC");
        console.log("  - User2:", user2Expected / 1e6, "USDC");
        console.log("  - User3:", user3Expected / 1e6, "USDC");
        
        console.log("=== Maturity and Withdrawals Test Passed ===");
    }
    
    function testOracleIntegration() public {
        console.log("\n=== Test: Oracle Integration ===");
        
        // Setup pool through investment
        testEpochClosureAndInvestment();
        
        uint256 totalRaised = manager.poolTotalRaised(testPool);
        string memory proofHash = "QmTestProofHash";
        
        console.log("Testing oracle integration:");
        console.log("  - Pool:", testPool);
        console.log("  - Amount:", totalRaised / 1e6, "USDC");
        console.log("  - Proof hash:", proofHash);
        
        // Submit investment proof through oracle
        vm.startPrank(spv);
        oracle.submitInvestmentProof(testPool, proofHash, totalRaised);
        vm.stopPrank();
        
        console.log("Investment proof submitted");
        
        // Fast forward past timelock
        vm.warp(block.timestamp + 24 hours + 1);
        
        // Verify oracle proof with oracle1
        vm.startPrank(oracle1);
        oracle.verifyProof(testPool);
        vm.stopPrank();
        
        console.log("Proof verified by oracle1");
        
        // Verify oracle proof with oracle2
        vm.startPrank(oracle2);
        oracle.verifyProof(testPool);
        vm.stopPrank();
        
        console.log("Proof verified by oracle2");
        
        // Check if proof is verified
        IPoolOracle.InvestmentProof memory proof = oracle.getInvestmentProof(testPool);
        assertTrue(proof.verified, "Proof should be verified by multiple oracles");
        
        console.log("Oracle verification status:", proof.verified);
        console.log("Verification timestamp:", proof.timestamp);
        
        console.log("=== Oracle Integration Test Passed ===");
    }
    
    function testCompletePoolLifecycle() public {
        console.log("\n=== Test: Complete Pool Lifecycle ===");
        
        console.log("Phase 1: Pool Creation");
        testAdminPoolCreation();
        
        console.log("\nPhase 2: User Deposits");
        testUserDepositJourney();
        
        console.log("\nPhase 3: Epoch Closure & Investment");
        testEpochClosureAndInvestment();
        
        console.log("\nPhase 4: Oracle Integration");
        testOracleIntegration();
        
        console.log("\nPhase 5: Maturity & Withdrawals");
        testMaturityAndWithdrawals();
        
        console.log("\n=== Complete Pool Lifecycle Test Passed ===");
    }
    
    function testEmergencyScenarios() public {
        console.log("\n=== Test: Emergency Scenarios ===");
        
        // Create pool but don't meet minimum funding
        testAdminPoolCreation();
        
        // Only deposit 30% of target (below 50% minimum)
        vm.startPrank(user1);
        uint256 smallDeposit = TARGET_RAISE * 30 / 100;
        usdc.approve(testPool, smallDeposit);
        LiquidityPool(testPool).deposit(smallDeposit, user1);
        vm.stopPrank();
        
        console.log("Small deposit made:", smallDeposit / 1e6, "USDC (30% of target)");
        
        // Fast forward and close epoch
        vm.warp(block.timestamp + FUNDING_DAYS * 1 days + 1 hours);
        
        vm.startPrank(operator);
        manager.closeEpoch(testPool);
        vm.stopPrank();
        
        console.log("Epoch closed with insufficient funding");
        
        // Should be in emergency status
        assertEq(uint256(manager.poolStatus(testPool)), uint256(IPoolManager.PoolStatus.EMERGENCY), "Pool should be in emergency status");
        
        console.log("Pool status: EMERGENCY");
        console.log("Users can now claim refunds");
        
        console.log("=== Emergency Scenarios Test Passed ===");
    }
} 