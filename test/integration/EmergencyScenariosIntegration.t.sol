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
 * @title EmergencyScenariosIntegration
 * @notice Integration test for emergency scenarios and pool cancellation
 * @dev Tests emergency withdrawals, pool cancellation, and refund flows
 * 
 * TEST COVERAGE:
 * - Emergency pool cancellation at different lifecycle stages
 * - Emergency withdrawals during funding phase
 * - Refund mechanisms for cancelled pools
 * - Partial refunds and pro-rata distribution
 * - SPV default scenarios
 */
contract EmergencyScenariosIntegration is BaseTest {
    
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
    uint256 constant DISCOUNT_RATE = 500; // 5%
    uint256 constant EPOCH_DURATION = 7 days;
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EVENTS /////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    event PoolCancelled(address indexed poolAddress, address indexed cancelledBy, uint256 timestamp);
    event EmergencyStateChanged(address indexed poolAddress, string trigger, uint256 totalAmount, uint256 totalShares, uint256 timestamp);
    event EmergencyWithdrawal(address indexed user, uint256 shares, uint256 assets);
    
    function setUp() public override {
        super.setUp();
        
        // Deploy token
        token = new MockERC20("Mock USDC", "USDC", 6);
        token.mint(user1, INITIAL_BALANCE);
        token.mint(user2, INITIAL_BALANCE);
        token.mint(user3, INITIAL_BALANCE);
        token.mint(spv, INITIAL_BALANCE * 2);
        
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
    
    function _createTestPool() internal returns (address, address) {
        uint256 maturityDate = block.timestamp + EPOCH_DURATION + 30 days;
        
        IPoolFactory.PoolConfig memory config = IPoolFactory.PoolConfig({
            asset: address(token),
            instrumentType: IPoolTypes.InstrumentType.DISCOUNTED,
            instrumentName: "TEST-EMERGENCY",
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
        return factory.createPool(config);
    }
    
    /**
     * @notice Test emergency cancellation during funding phase with full refunds
     * @dev Tests: pool creation → deposits → emergency cancel → user refunds
     */
    function test_emergency_adminCancelsPoolDuringFunding() public {
        console.log("\n=== TEST: Emergency Pool Cancellation During Funding ===");
        
        console.log("\nStep 1: Creating pool...");
        (poolAddress, escrowAddress) = _createTestPool();
        pool = LiquidityPool(poolAddress);
        console.log("  Pool:", poolAddress);
        console.log("  Escrow:", escrowAddress);
        
        // Users deposit
        console.log("\nStep 2: Users depositing funds...");
        uint256 user1Deposit = 40_000e6;
        uint256 user2Deposit = 35_000e6;
        console.log("  User1 depositing:", user1Deposit);
        
        vm.startPrank(user1);
        token.approve(poolAddress, user1Deposit);
        pool.deposit(user1Deposit, user1);
        vm.stopPrank();
        console.log("  User1 shares:", pool.balanceOf(user1));
        
        console.log("  User2 depositing:", user2Deposit);
        vm.startPrank(user2);
        token.approve(poolAddress, user2Deposit);
        pool.deposit(user2Deposit, user2);
        vm.stopPrank();
        console.log("  User2 shares:", pool.balanceOf(user2));
        
        console.log("  Total in escrow:", token.balanceOf(escrowAddress));
        console.log("  Pool Status:", uint8(manager.poolStatus(poolAddress)), "(FUNDING)");
        assertEq(uint8(manager.poolStatus(poolAddress)), uint8(IPoolTypes.PoolStatus.FUNDING));
        
        // Emergency role cancels pool
        console.log("\nStep 3: EMERGENCY CANCELLATION...");
        console.log("  Emergency role:", emergency);
        console.log("  Cancelling pool...");
        
        vm.expectEmit(true, true, false, true);
        emit PoolCancelled(poolAddress, emergency, block.timestamp);
        
        vm.prank(emergency);
        manager.cancelPool(poolAddress);
        
        console.log("  Pool Status:", uint8(manager.poolStatus(poolAddress)), "(EMERGENCY)");
        assertEq(uint8(manager.poolStatus(poolAddress)), uint8(IPoolTypes.PoolStatus.EMERGENCY), "Pool not in EMERGENCY status");
        
        // Users can emergency withdraw
        console.log("\nStep 4: USER1 EMERGENCY WITHDRAWAL...");
        uint256 user1BalanceBefore = token.balanceOf(user1);
        console.log("  User1 Balance Before:", user1BalanceBefore);
        console.log("  User1 Shares Before:", pool.balanceOf(user1));
        
        vm.prank(user1);
        pool.emergencyWithdraw();
        
        uint256 user1BalanceAfter = token.balanceOf(user1);
        console.log("  User1 Balance After:", user1BalanceAfter);
        console.log("  User1 Shares After:", pool.balanceOf(user1));
        console.log("  Refund Amount:", user1BalanceAfter - user1BalanceBefore);
        
        assertEq(user1BalanceAfter - user1BalanceBefore, user1Deposit, "User1 didn't receive full refund");
        assertEq(pool.balanceOf(user1), 0, "User1 still has shares");
        
        // User2 withdraws
        console.log("\nStep 5: USER2 EMERGENCY WITHDRAWAL...");
        uint256 user2BalanceBefore = token.balanceOf(user2);
        console.log("  User2 Balance Before:", user2BalanceBefore);
        console.log("  User2 Shares Before:", pool.balanceOf(user2));
        
        vm.prank(user2);
        pool.emergencyWithdraw();
        
        uint256 user2BalanceAfter = token.balanceOf(user2);
        console.log("  User2 Balance After:", user2BalanceAfter);
        console.log("  User2 Shares After:", pool.balanceOf(user2));
        console.log("  Refund Amount:", user2BalanceAfter - user2BalanceBefore);
        
        assertEq(user2BalanceAfter - user2BalanceBefore, user2Deposit, "User2 didn't receive full refund");
        assertEq(pool.balanceOf(user2), 0, "User2 still has shares");
        
        console.log("\nSUCCESS: Both users received full refunds!");
        console.log("=== TEST PASSED ===\n");
    }
    
    /**
     * @notice Test automatic emergency status when pool is underfunded at epoch close
     * @dev Tests: deposit below threshold → close epoch → auto EMERGENCY → refund
     */
    function test_emergency_poolUnderfundedAutoEntersEmergency() public {
        console.log("\n=== TEST: Underfunded Pool Auto-Enters Emergency ===");
        
        console.log("\nStep 1: Creating pool with 80% minimum funding threshold...");
        (poolAddress, escrowAddress) = _createTestPool();
        pool = LiquidityPool(poolAddress);
        console.log("  Pool:", poolAddress);
        console.log("  Target Raise:", TARGET_RAISE);
        console.log("  Minimum Threshold: 80% =", (TARGET_RAISE * 80) / 100);
        
        // Deposit only 70% (below 80% minimum threshold)
        console.log("\nStep 2: User depositing BELOW threshold...");
        uint256 depositAmount = 70_000e6;
        console.log("  User1 depositing: 70,000 USDC (70% of target)");
        console.log("  This is BELOW the 80% minimum threshold!");
        
        vm.startPrank(user1);
        token.approve(poolAddress, depositAmount);
        pool.deposit(depositAmount, user1);
        vm.stopPrank();
        
        console.log("  Total Deposited:", depositAmount);
        console.log("  Percentage:", (depositAmount * 100) / TARGET_RAISE, "%");
        
        // Close epoch
        console.log("\nStep 3: Closing epoch (should trigger automatic EMERGENCY)...");
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        console.log("  Time:", block.timestamp);
        console.log("  Operator closing epoch...");
        
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        
        console.log("  Pool Status:", uint8(manager.poolStatus(poolAddress)), "(AUTO EMERGENCY)");
        
        // Should automatically enter EMERGENCY status
        assertEq(uint8(manager.poolStatus(poolAddress)), uint8(IPoolTypes.PoolStatus.EMERGENCY), "Pool not in EMERGENCY");
        
        console.log("\nNOTE: Pool automatically entered EMERGENCY due to underfunding!");
        
        // User can withdraw
        console.log("\nStep 4: User emergency withdrawal...");
        uint256 balanceBefore = token.balanceOf(user1);
        console.log("  User Balance Before:", balanceBefore);
        
        vm.prank(user1);
        pool.emergencyWithdraw();
        
        uint256 balanceAfter = token.balanceOf(user1);
        console.log("  User Balance After:", balanceAfter);
        console.log("  Refund Amount:", balanceAfter - balanceBefore);
        console.log("  Expected:", depositAmount);
        
        assertEq(balanceAfter - balanceBefore, depositAmount, "Full refund not received");
        
        console.log("\nSUCCESS: User received full refund after auto-emergency!");
        console.log("=== TEST PASSED ===\n");
    }
    
    function test_emergency_forceCloseEpochWhenUnderfunded() public {
        (poolAddress, escrowAddress) = _createTestPool();
        pool = LiquidityPool(poolAddress);
        
        // Deposit below threshold
        uint256 depositAmount = 75_000e6;
        
        vm.startPrank(user1);
        token.approve(poolAddress, depositAmount);
        pool.deposit(depositAmount, user1);
        vm.stopPrank();
        
        // Emergency role force closes before epoch end
        vm.prank(emergency);
        manager.forceCloseEpoch(poolAddress);
        
        // Should enter EMERGENCY because underfunded
        assertEq(uint8(manager.poolStatus(poolAddress)), uint8(IPoolTypes.PoolStatus.EMERGENCY), "Not in EMERGENCY");
    }
    
    function test_emergency_forceCloseEpochWhenOverfunded() public {
        (poolAddress, escrowAddress) = _createTestPool();
        pool = LiquidityPool(poolAddress);
        
        // Deposit above threshold
        uint256 depositAmount = 95_000e6;
        
        vm.startPrank(user1);
        token.approve(poolAddress, depositAmount);
        pool.deposit(depositAmount, user1);
        vm.stopPrank();
        
        // Emergency role force closes
        vm.prank(emergency);
        manager.forceCloseEpoch(poolAddress);
        
        // Should enter PENDING_INVESTMENT because above threshold
        assertEq(uint8(manager.poolStatus(poolAddress)), uint8(IPoolTypes.PoolStatus.PENDING_INVESTMENT), "Not in PENDING_INVESTMENT");
    }
    
    /**
     * @notice Test proportional refunds for multiple users after emergency cancellation
     * @dev Tests: multiple deposits → cancel → each user gets exact deposit back
     */
    function test_emergency_multipleUsersProportionalRefunds() public {
        console.log("\n=== TEST: Multiple Users Proportional Emergency Refunds ===");
        
        console.log("\nStep 1: Creating pool...");
        (poolAddress, escrowAddress) = _createTestPool();
        pool = LiquidityPool(poolAddress);
        console.log("  Pool:", poolAddress);
        
        // Three users deposit different amounts
        console.log("\nStep 2: Three users depositing different amounts...");
        uint256 user1Deposit = 50_000e6;
        uint256 user2Deposit = 30_000e6;
        uint256 user3Deposit = 20_000e6;
        uint256 totalDeposited = user1Deposit + user2Deposit + user3Deposit;
        
        console.log("  User1 depositing: 50,000 (50%)");
        vm.startPrank(user1);
        token.approve(poolAddress, user1Deposit);
        pool.deposit(user1Deposit, user1);
        vm.stopPrank();
        
        console.log("  User2 depositing: 30,000 (30%)");
        vm.startPrank(user2);
        token.approve(poolAddress, user2Deposit);
        pool.deposit(user2Deposit, user2);
        vm.stopPrank();
        
        console.log("  User3 depositing: 20,000 (20%)");
        vm.startPrank(user3);
        token.approve(poolAddress, user3Deposit);
        pool.deposit(user3Deposit, user3);
        vm.stopPrank();
        
        console.log("  Total Deposited:", totalDeposited);
        console.log("  Escrow Balance:", token.balanceOf(escrowAddress));
        
        // Cancel pool
        console.log("\nStep 3: Emergency cancelling pool...");
        vm.prank(emergency);
        manager.cancelPool(poolAddress);
        console.log("  Pool Status:", uint8(manager.poolStatus(poolAddress)), "(EMERGENCY)");
        
        // Each user withdraws and gets exact deposit back
        console.log("\nStep 4: USER1 CLAIMING REFUND...");
        uint256 user1Before = token.balanceOf(user1);
        console.log("  User1 Balance Before:", user1Before);
        console.log("  User1 Shares:", pool.balanceOf(user1));
        
        vm.prank(user1);
        pool.emergencyWithdraw();
        console.log("  User1 Balance After:", token.balanceOf(user1));
        console.log("  Refunded:", token.balanceOf(user1) - user1Before);
        console.log("  Expected:", user1Deposit);
        assertEq(token.balanceOf(user1) - user1Before, user1Deposit, "User1 refund mismatch");
        
        console.log("\nStep 5: USER2 CLAIMING REFUND...");
        uint256 user2Before = token.balanceOf(user2);
        console.log("  User2 Balance Before:", user2Before);
        console.log("  User2 Shares:", pool.balanceOf(user2));
        
        vm.prank(user2);
        pool.emergencyWithdraw();
        console.log("  User2 Balance After:", token.balanceOf(user2));
        console.log("  Refunded:", token.balanceOf(user2) - user2Before);
        console.log("  Expected:", user2Deposit);
        assertEq(token.balanceOf(user2) - user2Before, user2Deposit, "User2 refund mismatch");
        
        console.log("\nStep 6: USER3 CLAIMING REFUND...");
        uint256 user3Before = token.balanceOf(user3);
        console.log("  User3 Balance Before:", user3Before);
        console.log("  User3 Shares:", pool.balanceOf(user3));
        
        vm.prank(user3);
        pool.emergencyWithdraw();
        console.log("  User3 Balance After:", token.balanceOf(user3));
        console.log("  Refunded:", token.balanceOf(user3) - user3Before);
        console.log("  Expected:", user3Deposit);
        assertEq(token.balanceOf(user3) - user3Before, user3Deposit, "User3 refund mismatch");
        
        console.log("\nSUCCESS: All users received exact deposits back!");
        console.log("  Total Refunded:", (token.balanceOf(user1) - user1Before) + (token.balanceOf(user2) - user2Before) + (token.balanceOf(user3) - user3Before));
        console.log("  Escrow Balance After:", token.balanceOf(escrowAddress));
        console.log("=== TEST PASSED ===\n");
    }
    
    function test_emergency_cannotDepositAfterCancellation() public {
        (poolAddress, escrowAddress) = _createTestPool();
        pool = LiquidityPool(poolAddress);
        
        // Initial deposit
        uint256 depositAmount = 50_000e6;
        vm.startPrank(user1);
        token.approve(poolAddress, depositAmount);
        pool.deposit(depositAmount, user1);
        vm.stopPrank();
        
        // Cancel pool
        vm.prank(emergency);
        manager.cancelPool(poolAddress);
        
        // Try to deposit - should fail
        uint256 newDeposit = 10_000e6;
        vm.startPrank(user2);
        token.approve(poolAddress, newDeposit);
        vm.expectRevert();
        pool.deposit(newDeposit, user2);
        vm.stopPrank();
    }
    
    function test_emergency_partialWithdrawal() public {
        (poolAddress, escrowAddress) = _createTestPool();
        pool = LiquidityPool(poolAddress);
        
        // User deposits
        uint256 depositAmount = 100_000e6;
        vm.startPrank(user1);
        token.approve(poolAddress, depositAmount);
        pool.deposit(depositAmount, user1);
        vm.stopPrank();
        
        // Cancel pool
        vm.prank(emergency);
        manager.cancelPool(poolAddress);
        
        // User makes partial emergency withdrawal
        uint256 partialAmount = 30_000e6;
        
        uint256 balanceBefore = token.balanceOf(user1);
        
        vm.prank(user1);
        pool.withdraw(partialAmount, user1, user1);
        
        uint256 balanceAfter = token.balanceOf(user1);
        
        assertEq(balanceAfter - balanceBefore, partialAmount, "Partial withdrawal amount mismatch");
        assertEq(pool.balanceOf(user1), depositAmount - partialAmount, "Remaining shares mismatch");
        
        // User withdraws rest
        uint256 remainingShares = pool.balanceOf(user1);
        
        balanceBefore = token.balanceOf(user1);
        
        vm.prank(user1);
        pool.withdraw(remainingShares, user1, user1);
        
        balanceAfter = token.balanceOf(user1);
        
        assertEq(balanceAfter - balanceBefore, remainingShares, "Remaining withdrawal mismatch");
        assertEq(pool.balanceOf(user1), 0, "User still has shares");
    }
    
    function test_emergency_accessControl() public {
        (poolAddress, escrowAddress) = _createTestPool();
        pool = LiquidityPool(poolAddress);
        
        // User deposits
        vm.startPrank(user1);
        token.approve(poolAddress, 50_000e6);
        pool.deposit(50_000e6, user1);
        vm.stopPrank();
        
        // Non-emergency role cannot cancel
        vm.prank(user2);
        vm.expectRevert();
        manager.cancelPool(poolAddress);
        
        // Operator cannot cancel
        vm.prank(operator);
        vm.expectRevert();
        manager.cancelPool(poolAddress);
        
        // Only emergency role can cancel
        vm.prank(emergency);
        manager.cancelPool(poolAddress);
        
        assertEq(uint8(manager.poolStatus(poolAddress)), uint8(IPoolTypes.PoolStatus.EMERGENCY));
    }
    
    function test_emergency_cannotCancelAfterInvestment() public {
        (poolAddress, escrowAddress) = _createTestPool();
        pool = LiquidityPool(poolAddress);
        
        // Deposit and reach investment
        uint256 depositAmount = 100_000e6;
        vm.startPrank(user1);
        token.approve(poolAddress, depositAmount);
        pool.deposit(depositAmount, user1);
        vm.stopPrank();
        
        // Close epoch
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        
        // Withdraw for investment
        vm.prank(spv);
        manager.withdrawFundsForInvestment(poolAddress, depositAmount);
        
        // Process investment
        vm.prank(spv);
        manager.processInvestment(poolAddress, depositAmount, "proof");
        
        assertEq(uint8(manager.poolStatus(poolAddress)), uint8(IPoolTypes.PoolStatus.INVESTED));
        
        // Try to cancel - should fail
        vm.prank(emergency);
        vm.expectRevert();
        manager.cancelPool(poolAddress);
    }
    
    function test_emergency_pauseAndUnpausePool() public {
        (poolAddress, escrowAddress) = _createTestPool();
        pool = LiquidityPool(poolAddress);
        
        // Initial deposit works
        uint256 depositAmount = 50_000e6;
        vm.startPrank(user1);
        token.approve(poolAddress, depositAmount);
        pool.deposit(depositAmount, user1);
        vm.stopPrank();
        
        // Operator pauses pool
        vm.prank(operator);
        manager.pausePool(poolAddress);
        
        assertTrue(pool.paused(), "Pool not paused");
        
        // Cannot deposit while paused
        vm.startPrank(user2);
        token.approve(poolAddress, depositAmount);
        vm.expectRevert();
        pool.deposit(depositAmount, user2);
        vm.stopPrank();
        
        // Operator unpauses
        vm.prank(operator);
        manager.unpausePool(poolAddress);
        
        assertFalse(pool.paused(), "Pool still paused");
        
        // Can deposit again
        vm.startPrank(user2);
        token.approve(poolAddress, depositAmount);
        pool.deposit(depositAmount, user2);
        vm.stopPrank();
        
        assertEq(pool.balanceOf(user2), depositAmount, "User2 deposit failed after unpause");
    }
}

