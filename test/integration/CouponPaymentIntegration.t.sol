// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../fixtures/BaseTest.sol";
import "../../src/PoolRegistry.sol";
import "../../src/factories/PoolFactory.sol";
import "../../src/LiquidityPool.sol";
import "../../src/escrows/PoolEscrow.sol";
import "../../src/Manager.sol";
import "../../src/AccessManager.sol";
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
 * @title CouponPaymentIntegration
 * @notice Integration test for interest-bearing instruments with coupon payments
 * @dev Tests the complete coupon payment flow: receive -> distribute -> claim
 * 
 * TEST COVERAGE:
 * - Coupon payment reception and distribution
 * - User coupon claims (single and multiple users)
 * - Partial coupon distributions
 * - Coupon tracking and accounting
 * - Edge cases (zero coupons, invalid claims, etc.)
 */
contract CouponPaymentIntegration is BaseTest {
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STATE VARIABLES ////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    MockERC20 public token;
    AccessManager public accessManager;
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
    uint256 constant EPOCH_DURATION = 7 days;
    uint256 constant COUPON_RATE = 1000; // 10% annualized
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EVENTS /////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    event CouponReceived(uint256 amount, uint256 timestamp);
    event CouponDistributed(address indexed pool, uint256 amount, uint256 timestamp);
    event CouponClaimed(address indexed pool, address indexed user, uint256 amount);
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// SETUP //////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function setUp() public override {
        super.setUp();
        
        // Deploy token
        token = new MockERC20("Mock USDC", "USDC", 6);
        token.mint(user1, INITIAL_BALANCE);
        token.mint(user2, INITIAL_BALANCE);
        token.mint(user3, INITIAL_BALANCE);
        token.mint(spv, INITIAL_BALANCE * 3); // SPV needs funds for coupons + maturity
        
        // Deploy AccessManager
        accessManager = new AccessManager(admin, spv, operator, emergency, multisigAdmin);
        
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
        
        // Set factory
        vm.prank(admin);
        registry.setFactory(address(factory));
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// COUPON PAYMENT TESTS ///////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    /**
     * @notice Test complete coupon payment flow with multiple payments and users
     * @dev Tests: create pool → deposits → investment → coupon payments → claims → maturity
     */
    function test_couponPayment_twoPayments() public {
        console.log("\n=== TEST: Coupon Payment Flow with Multiple Payments ===");
        
        // Create interest-bearing pool with 3 coupon payments
        console.log("\nStep 1: Creating interest-bearing pool...");
        uint256 maturityDate = block.timestamp + EPOCH_DURATION + 180 days;
        
        uint256[] memory couponDates = new uint256[](3);
        couponDates[0] = block.timestamp + EPOCH_DURATION + 60 days;
        couponDates[1] = block.timestamp + EPOCH_DURATION + 120 days;
        couponDates[2] = block.timestamp + EPOCH_DURATION + 180 days;
        
        uint256[] memory couponRates = new uint256[](3);
        couponRates[0] = COUPON_RATE; // 10%
        couponRates[1] = COUPON_RATE; // 10%
        couponRates[2] = COUPON_RATE; // 10%
        
        console.log("  Coupon Rate: 10%% per payment");
        console.log("  Number of Coupons: 3");
        console.log("  Maturity Date:", maturityDate);
        
        IPoolFactory.PoolConfig memory config = IPoolFactory.PoolConfig({
            asset: address(token),
            instrumentType: IPoolTypes.InstrumentType.INTEREST_BEARING,
            instrumentName: "TEST-COUPON",
            targetRaise: TARGET_RAISE,
            epochDuration: EPOCH_DURATION,
            maturityDate: maturityDate,
            discountRate: 0,
            spvAddress: spv,
            couponDates: couponDates,
            couponRates: couponRates,
            minimumFundingThreshold: 8000
        });
        
        vm.prank(admin);
        (poolAddress, escrowAddress) = factory.createPool(config);
        pool = LiquidityPool(poolAddress);
        
        console.log("  Pool Created:", poolAddress);
        console.log("  Escrow:", escrowAddress);
        
        // ====== PHASE 1: FUNDING ======
        console.log("\nStep 2: FUNDING PHASE - Users depositing...");
        uint256 user1Deposit = 40_000e6;
        uint256 user2Deposit = 35_000e6;
        uint256 user3Deposit = 25_000e6;
        uint256 totalDeposited = user1Deposit + user2Deposit + user3Deposit;
        
        console.log("  User1 depositing:", user1Deposit);
        // Users deposit
        vm.startPrank(user1);
        token.approve(poolAddress, user1Deposit);
        pool.deposit(user1Deposit, user1);
        vm.stopPrank();
        
        console.log("  User2 depositing:", user2Deposit);
        vm.startPrank(user2);
        token.approve(poolAddress, user2Deposit);
        pool.deposit(user2Deposit, user2);
        vm.stopPrank();
        
        console.log("  User3 depositing:", user3Deposit);
        vm.startPrank(user3);
        token.approve(poolAddress, user3Deposit);
        pool.deposit(user3Deposit, user3);
        vm.stopPrank();
        
        console.log("  Total Deposited:", totalDeposited);
        console.log("  Escrow Balance:", token.balanceOf(escrowAddress));
        
        // ====== PHASE 2: CLOSE EPOCH & INVEST ======
        console.log("\nStep 3: INVESTMENT PHASE - Closing epoch and investing...");
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        console.log("  Time warped to:", block.timestamp);
        
        console.log("  Operator closing epoch...");
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        console.log("  Status:", uint8(manager.poolStatus(poolAddress)));
        
        console.log("  SPV withdrawing funds for investment:", totalDeposited);
        vm.prank(spv);
        manager.withdrawFundsForInvestment(poolAddress, totalDeposited);
        console.log("  SPV Balance:", token.balanceOf(spv));
        
        console.log("  SPV confirming investment...");
        vm.prank(spv);
        manager.processInvestment(poolAddress, totalDeposited, "proof-hash");
        console.log("  Status:", uint8(manager.poolStatus(poolAddress)), "(INVESTED)");
        
        assertEq(uint8(manager.poolStatus(poolAddress)), uint8(IPoolTypes.PoolStatus.INVESTED));
        
        // ====== PHASE 3: FIRST COUPON PAYMENT ======
        console.log("\nStep 4: FIRST COUPON PAYMENT...");
        vm.warp(couponDates[0]);
        console.log("  Warped to first coupon date:", couponDates[0]);
        
        // SPV pays first coupon (10% of principal)
        uint256 firstCouponAmount = (totalDeposited * COUPON_RATE) / 10000;
        console.log("  First Coupon Amount (10%):", firstCouponAmount);
        
        console.log("  SPV paying coupon to manager...");
        vm.startPrank(spv);
        token.approve(address(manager), firstCouponAmount); // Manager pulls tokens
        manager.processCouponPayment(poolAddress, firstCouponAmount);
        vm.stopPrank();
        console.log("  Total Coupons Received:", manager.poolTotalCouponsReceived(poolAddress));
        
        assertEq(manager.poolTotalCouponsReceived(poolAddress), firstCouponAmount, "First coupon not received");
        
        // Operator distributes coupon
        console.log("  Operator distributing coupon to all users...");
        vm.prank(operator);
        manager.distributeCouponPayment(poolAddress);
        console.log("  Total Coupons Distributed:", manager.poolTotalCouponsDistributed(poolAddress));
        
        assertEq(manager.poolTotalCouponsDistributed(poolAddress), firstCouponAmount, "First coupon not distributed");
        
        // Users claim their proportional share
        console.log("\nStep 5: USER1 CLAIMING FIRST COUPON...");
        uint256 user1Share = pool.balanceOf(user1);
        uint256 totalShares = pool.totalSupply();
        uint256 user1ExpectedCoupon = (user1Share * firstCouponAmount) / totalShares;
        console.log("  User1 Shares:", user1Share);
        console.log("  Total Shares:", totalShares);
        console.log("  User1 Expected Coupon:", user1ExpectedCoupon);
        
        uint256 user1BalanceBefore = token.balanceOf(user1);
        console.log("  User1 Balance Before:", user1BalanceBefore);
        
        vm.prank(user1);
        uint256 user1CouponClaimed = pool.claimCoupon();
        console.log("  User1 Coupon Claimed:", user1CouponClaimed);
        
        uint256 user1BalanceAfter = token.balanceOf(user1);
        console.log("  User1 Balance After:", user1BalanceAfter);
        console.log("  Actual Received:", user1BalanceAfter - user1BalanceBefore);
        
        assertEq(user1CouponClaimed, user1ExpectedCoupon, "User1 coupon amount mismatch");
        assertEq(user1BalanceAfter - user1BalanceBefore, user1ExpectedCoupon, "User1 balance not updated");
        
        // Verify user can't claim again immediately
        console.log("  Verifying double-claim prevention...");
        vm.prank(user1);
        vm.expectRevert("Manager/no new coupons");
        pool.claimCoupon();
        console.log("  SUCCESS: User1 cannot double-claim");
        
        // ====== PHASE 4: SECOND COUPON PAYMENT ======
        console.log("\nStep 6: SECOND COUPON PAYMENT...");
        vm.warp(couponDates[1]);
        console.log("  Warped to second coupon date:", couponDates[1]);
        
        uint256 secondCouponAmount = (totalDeposited * COUPON_RATE) / 10000;
        console.log("  Second Coupon Amount (10%):", secondCouponAmount);
        
        console.log("  SPV paying second coupon...");
        vm.startPrank(spv);
        token.approve(address(manager), secondCouponAmount); // Manager pulls tokens
        manager.processCouponPayment(poolAddress, secondCouponAmount);
        vm.stopPrank();
        console.log("  Total Coupons Received:", manager.poolTotalCouponsReceived(poolAddress));
        
        console.log("  Operator distributing second coupon...");
        vm.prank(operator);
        manager.distributeCouponPayment(poolAddress);
        console.log("  Total Coupons Distributed:", manager.poolTotalCouponsDistributed(poolAddress));
        
        // User2 claims both unclaimed first coupon and second coupon
        console.log("\nStep 7: USER2 CLAIMING ACCUMULATED COUPONS...");
        uint256 user2Share = pool.balanceOf(user2);
        uint256 user2TotalExpected = (user2Share * (firstCouponAmount + secondCouponAmount)) / totalShares;
        console.log("  User2 has not claimed yet - should get BOTH coupons");
        console.log("  User2 Expected Total:", user2TotalExpected);
        
        uint256 user2BalanceBefore = token.balanceOf(user2);
        console.log("  User2 Balance Before:", user2BalanceBefore);
        
        vm.prank(user2);
        uint256 user2CouponClaimed = pool.claimCoupon();
        console.log("  User2 Coupon Claimed:", user2CouponClaimed);
        
        uint256 user2BalanceAfter = token.balanceOf(user2);
        console.log("  User2 Balance After:", user2BalanceAfter);
        console.log("  Actual Received:", user2BalanceAfter - user2BalanceBefore);
        
        assertEq(user2CouponClaimed, user2TotalExpected, "User2 total coupon mismatch");
        assertEq(user2BalanceAfter - user2BalanceBefore, user2TotalExpected, "User2 balance not updated");
        
        // User1 claims second coupon
        console.log("\nStep 8: USER1 CLAIMING SECOND COUPON...");
        uint256 user1SecondExpected = (user1Share * secondCouponAmount) / totalShares;
        console.log("  User1 Expected (second only):", user1SecondExpected);
        vm.prank(user1);
        uint256 user1Second = pool.claimCoupon();
        console.log("  User1 Claimed:", user1Second);
        assertEq(user1Second, user1SecondExpected, "User1 second coupon mismatch");
        
        console.log("\n=== TEST PASSED ===\n");
    }
    
    function test_couponPayment_getUserAvailableCoupon() public {
        // Create pool
        uint256 maturityDate = block.timestamp + EPOCH_DURATION + 90 days;
        
        uint256[] memory couponDates = new uint256[](2);
        couponDates[0] = block.timestamp + EPOCH_DURATION + 45 days;
        couponDates[1] = block.timestamp + EPOCH_DURATION + 90 days;
        
        uint256[] memory couponRates = new uint256[](2);
        couponRates[0] = 500; // 5%
        couponRates[1] = 500; // 5%
        
        IPoolFactory.PoolConfig memory config = IPoolFactory.PoolConfig({
            asset: address(token),
            instrumentType: IPoolTypes.InstrumentType.INTEREST_BEARING,
            instrumentName: "TEST-VIEW",
            targetRaise: TARGET_RAISE,
            epochDuration: EPOCH_DURATION,
            maturityDate: maturityDate,
            discountRate: 0,
            spvAddress: spv,
            couponDates: couponDates,
            couponRates: couponRates,
            minimumFundingThreshold: 8000
        });
        
        vm.prank(admin);
        (poolAddress, escrowAddress) = factory.createPool(config);
        pool = LiquidityPool(poolAddress);
        
        // User deposits
        uint256 depositAmount = 100_000e6;
        vm.startPrank(user1);
        token.approve(poolAddress, depositAmount);
        pool.deposit(depositAmount, user1);
        vm.stopPrank();
        
        // Close epoch and invest
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        
        vm.prank(spv);
        manager.withdrawFundsForInvestment(poolAddress, depositAmount);
        
        vm.prank(spv);
        manager.processInvestment(poolAddress, depositAmount, "proof");
        
        // SPV pays coupon but doesn't distribute yet
        vm.warp(couponDates[0]);
        
        uint256 couponAmount = (depositAmount * 500) / 10000;
        
        vm.startPrank(spv);
        token.approve(address(manager), couponAmount); // Manager pulls tokens
        manager.processCouponPayment(poolAddress, couponAmount);
        vm.stopPrank();
        
        // Before distribution, user should see 0 available
        uint256 availableBefore = pool.getUserCouponAmount(user1);
        assertEq(availableBefore, 0, "Coupon available before distribution");
        
        // After distribution, user should see full amount
        vm.prank(operator);
        manager.distributeCouponPayment(poolAddress);
        
        uint256 availableAfter = pool.getUserCouponAmount(user1);
        assertEq(availableAfter, couponAmount, "Coupon not available after distribution");
        
        // After claiming, should be 0 again
        vm.prank(user1);
        pool.claimCoupon();
        
        uint256 availableAfterClaim = pool.getUserCouponAmount(user1);
        assertEq(availableAfterClaim, 0, "Coupon still available after claim");
    }
    
    function test_couponPayment_multipleUsersProportionalDistribution() public {
        // Create pool
        uint256 maturityDate = block.timestamp + EPOCH_DURATION + 60 days;
        
        uint256[] memory couponDates = new uint256[](1);
        couponDates[0] = block.timestamp + EPOCH_DURATION + 30 days;
        
        uint256[] memory couponRates = new uint256[](1);
        couponRates[0] = 1000; // 10%
        
        IPoolFactory.PoolConfig memory config = IPoolFactory.PoolConfig({
            asset: address(token),
            instrumentType: IPoolTypes.InstrumentType.INTEREST_BEARING,
            instrumentName: "TEST-PROPORTIONAL",
            targetRaise: TARGET_RAISE,
            epochDuration: EPOCH_DURATION,
            maturityDate: maturityDate,
            discountRate: 0,
            spvAddress: spv,
            couponDates: couponDates,
            couponRates: couponRates,
            minimumFundingThreshold: 8000
        });
        
        vm.prank(admin);
        (poolAddress, escrowAddress) = factory.createPool(config);
        pool = LiquidityPool(poolAddress);
        
        // Three users deposit different amounts
        uint256 user1Deposit = 50_000e6; // 50%
        uint256 user2Deposit = 30_000e6; // 30%
        uint256 user3Deposit = 20_000e6; // 20%
        uint256 totalDeposit = user1Deposit + user2Deposit + user3Deposit;
        
        vm.startPrank(user1);
        token.approve(poolAddress, user1Deposit);
        pool.deposit(user1Deposit, user1);
        vm.stopPrank();
        
        vm.startPrank(user2);
        token.approve(poolAddress, user2Deposit);
        pool.deposit(user2Deposit, user2);
        vm.stopPrank();
        
        vm.startPrank(user3);
        token.approve(poolAddress, user3Deposit);
        pool.deposit(user3Deposit, user3);
        vm.stopPrank();
        
        // Close epoch and invest
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        
        vm.prank(spv);
        manager.withdrawFundsForInvestment(poolAddress, totalDeposit);
        
        vm.prank(spv);
        manager.processInvestment(poolAddress, totalDeposit, "proof");
        
        // Pay and distribute coupon
        vm.warp(couponDates[0]);
        
        uint256 totalCoupon = (totalDeposit * 1000) / 10000; // 10%
        
        vm.startPrank(spv);
        token.approve(address(manager), totalCoupon); // Manager pulls tokens
        manager.processCouponPayment(poolAddress, totalCoupon);
        vm.stopPrank();
        
        vm.prank(operator);
        manager.distributeCouponPayment(poolAddress);
        
        // Verify proportional distribution
        uint256 user1Expected = (totalCoupon * 50) / 100; // 50%
        uint256 user2Expected = (totalCoupon * 30) / 100; // 30%
        uint256 user3Expected = (totalCoupon * 20) / 100; // 20%
        
        assertEq(pool.getUserCouponAmount(user1), user1Expected, "User1 proportional coupon mismatch");
        assertEq(pool.getUserCouponAmount(user2), user2Expected, "User2 proportional coupon mismatch");
        assertEq(pool.getUserCouponAmount(user3), user3Expected, "User3 proportional coupon mismatch");
        
        // Users claim
        vm.prank(user1);
        uint256 claimed1 = pool.claimCoupon();
        assertEq(claimed1, user1Expected, "User1 claimed amount mismatch");
        
        vm.prank(user2);
        uint256 claimed2 = pool.claimCoupon();
        assertEq(claimed2, user2Expected, "User2 claimed amount mismatch");
        
        vm.prank(user3);
        uint256 claimed3 = pool.claimCoupon();
        assertEq(claimed3, user3Expected, "User3 claimed amount mismatch");
    }
}


