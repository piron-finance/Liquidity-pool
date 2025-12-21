// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../../src/managed/StableYieldPool.sol";
import "../../src/factories/ManagedPoolFactory.sol";
import "../../src/StableYieldManager.sol";
import "../../src/escrows/StableYieldEscrow.sol";
import "../../src/AccessManager.sol";
import "../../src/FeeManager.sol";
import "../../src/PoolRegistry.sol";
import "../mocks/MockContracts.sol";

/**
 * @title DeployedContractsTest
 * @notice Tests the deployed contracts on Base Sepolia
 * @dev This test can be run against a fork of Base Sepolia or locally with deployed addresses
 */
contract DeployedContractsTest is Test {
    
    // Deployed addresses from kk.txt
    address constant ADMIN = 0xFeed27E8413d416Df4B26bf7BE275Bf92997413c;
    address constant MOCK_TOKEN = 0x9e50F96908187CD5cf19EFeB666B6e017DF42Aa0;
    address constant MANAGED_FACTORY = 0xfA5ae2Ea54e6cBbC8CBEa1C37b40CE8fAc9F856C;
    address constant STABLE_YIELD_MANAGER = 0x87528b87C9d46022a89b95932a44b6a5fBA31894;
    address constant ACCESS_MANAGER = 0xF1759a96d67DF3666FB32420ba62ab4Bb2a0aA38;
    address constant FEE_MANAGER = 0x3BBdbc2Bc7A2bdAE85010831AcFad0c6c170334a;
    address constant POOL_REGISTRY = 0xdD9f279912Af7E27371efEf620eA686A8184dE34;
    
    ManagedPoolFactory factory;
    StableYieldManager stableYieldMgr;
    AccessManager accessMgr;
    MockERC20 token;
    PoolRegistry registry;
    FeeManager feeManager;
    
    address poolAddress;
    address escrowAddress;
    address user1;
    address user2;
    
    function setUp() public {
        // Create test users
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        
        // Initialize deployed contracts
        factory = ManagedPoolFactory(MANAGED_FACTORY);
        stableYieldMgr = StableYieldManager(STABLE_YIELD_MANAGER);
        accessMgr = AccessManager(ACCESS_MANAGER);
        token = MockERC20(MOCK_TOKEN);
        registry = PoolRegistry(POOL_REGISTRY);
        feeManager = FeeManager(FEE_MANAGER);
    }
    
    /**
     * TEST 1: Verify deployment configuration
     */
    function test_deploymentConfiguration() public view {
        console.log("\n=== TEST: Deployment Configuration ===");
        
        // Check admin has all roles
        assertTrue(accessMgr.hasRole(accessMgr.DEFAULT_ADMIN_ROLE(), ADMIN), "Admin missing DEFAULT_ADMIN_ROLE");
        assertTrue(accessMgr.hasRole(accessMgr.SPV_ROLE(), ADMIN), "Admin missing SPV_ROLE");
        assertTrue(accessMgr.hasRole(accessMgr.OPERATOR_ROLE(), ADMIN), "Admin missing OPERATOR_ROLE");
        assertTrue(accessMgr.hasRole(accessMgr.POOL_CREATOR_ROLE(), ADMIN), "Admin missing POOL_CREATOR_ROLE");
        
        console.log("  Admin has all required roles");
        
        // Check factories are registered
        assertTrue(accessMgr.hasRole(accessMgr.FACTORY_ROLE(), MANAGED_FACTORY), "Factory missing FACTORY_ROLE");
        console.log("  Managed factory has FACTORY_ROLE");
        
        // Check deployment is finalized
        assertTrue(accessMgr.deploymentComplete(), "Deployment not finalized");
        console.log("  Deployment finalized");
        
        console.log("  SUCCESS: All deployment checks passed");
    }
    
    /**
     * TEST 2: Create and configure pool
     */
    function test_createAndConfigurePool() public {
        console.log("\n=== TEST: Create and Configure Pool ===");
        
        vm.startPrank(ADMIN);
        
        uint256[] memory tenors = new uint256[](2);
        tenors[0] = 90;
        tenors[1] = 180;
        
        ManagedPoolFactory.PoolDeploymentConfig memory config = ManagedPoolFactory.PoolDeploymentConfig({
            asset: MOCK_TOKEN,
            poolName: "Test Integration Pool",
            poolSymbol: "pINT",
            spvAddress: ADMIN,
            supportedTenors: tenors,
            minInvestment: 100e6,
            expenseRatio: 50,
            underlyingPools: new address[](0)
        });
        
        uint256 poolCountBefore = registry.totalStableYieldPools();
        
        (poolAddress, escrowAddress) = factory.createStableYieldPool(config);
        
        uint256 poolCountAfter = registry.totalStableYieldPools();
        
        console.log("  Pool created:", poolAddress);
        console.log("  Escrow created:", escrowAddress);
        console.log("  Total pools before:", poolCountBefore);
        console.log("  Total pools after:", poolCountAfter);
        
        assertEq(poolCountAfter, poolCountBefore + 1, "Pool count not increased");
        assertTrue(registry.isStableYieldPool(poolAddress), "Pool not registered");
        
        vm.stopPrank();
        
        console.log("  SUCCESS: Pool creation verified");
    }
    
    /**
     * TEST 3: Full deposit and withdrawal cycle
     */
    function test_fullDepositWithdrawalCycle() public {
        console.log("\n=== TEST: Full Deposit/Withdrawal Cycle ===");
        
        // Create pool first
        test_createAndConfigurePool();
        
        vm.startPrank(ADMIN);
        
        // Mint tokens
        uint256 depositAmount = 5000e6;
        token.mint(ADMIN, depositAmount);
        console.log("  Minted tokens:", depositAmount);
        
        // Approve and deposit
        token.approve(poolAddress, depositAmount);
        uint256 shares = StableYieldPool(poolAddress).deposit(depositAmount, ADMIN);
        
        console.log("  Deposited:", depositAmount);
        console.log("  Shares received:", shares);
        
        assertGt(shares, 0, "No shares minted");
        assertEq(StableYieldPool(poolAddress).balanceOf(ADMIN), shares, "Share balance mismatch");
        
        // Check escrow balance
        uint256 escrowBalance = token.balanceOf(escrowAddress);
        console.log("  Escrow balance:", escrowBalance);
        assertEq(escrowBalance, depositAmount, "Escrow balance incorrect");
        
        // Wait minimum holding period
        vm.warp(block.timestamp + 31 days);
        console.log("  Warped forward 31 days");
        
        // Withdraw
        uint256 balanceBefore = token.balanceOf(ADMIN);
        uint256 assetsReceived = StableYieldPool(poolAddress).redeem(shares, ADMIN, ADMIN);
        uint256 balanceAfter = token.balanceOf(ADMIN);
        
        console.log("  Withdrew shares:", shares);
        console.log("  Assets received:", assetsReceived);
        console.log("  Balance increase:", balanceAfter - balanceBefore);
        
        assertGt(assetsReceived, 0, "No assets received");
        assertGt(balanceAfter, balanceBefore, "Balance not increased");
        assertEq(StableYieldPool(poolAddress).balanceOf(ADMIN), 0, "Shares not burned");
        
        vm.stopPrank();
        
        console.log("  SUCCESS: Deposit/withdrawal cycle completed");
    }
    
    /**
     * TEST 4: SPV allocation and instrument management
     */
    function test_spvAllocationAndInstrument() public {
        console.log("\n=== TEST: SPV Allocation and Instrument ===");
        
        // Create pool and deposit first
        test_createAndConfigurePool();
        
        vm.startPrank(ADMIN);
        
        // Deposit funds
        uint256 depositAmount = 10000e6;
        token.mint(ADMIN, depositAmount);
        token.approve(poolAddress, depositAmount);
        StableYieldPool(poolAddress).deposit(depositAmount, ADMIN);
        
        console.log("  Initial deposit:", depositAmount);
        
        // Allocate to SPV
        StableYieldEscrow escrow = StableYieldEscrow(escrowAddress);
        uint256 allocationAmount = 5000e6;
        uint256 reservesBefore = escrow.getPoolReserves();
        
        escrow.allocateToSPV(ADMIN, allocationAmount);
        
        uint256 reservesAfter = escrow.getPoolReserves();
        console.log("  Allocated to SPV:", allocationAmount);
        console.log("  Reserves before:", reservesBefore);
        console.log("  Reserves after:", reservesAfter);
        
        assertEq(reservesAfter, reservesBefore - allocationAmount, "Reserves not updated");
        
        // Add instrument
        stableYieldMgr.addInstrument(
            poolAddress,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            4500e6,
            5000e6,
            block.timestamp + 90 days,
            0,
            0
        );
        
        console.log("  Instrument added");
        
        // Check NAV
        uint256 nav = stableYieldMgr.calculatePoolNAV(poolAddress);
        uint256 navPerShare = stableYieldMgr.calculateNAVPerShare(poolAddress);
        
        console.log("  Pool NAV:", nav);
        console.log("  NAV per share:", navPerShare);
        
        assertGt(nav, 9000e6, "NAV too low");
        assertGt(navPerShare, 0, "NAV per share is zero");
        
        vm.stopPrank();
        
        console.log("  SUCCESS: SPV allocation and instrument working");
    }
    
    /**
     * TEST 5: Multiple users depositing
     */
    function test_multipleUsersDeposit() public {
        console.log("\n=== TEST: Multiple Users Deposit ===");
        
        // Create pool
        test_createAndConfigurePool();
        
        // User 1 deposits
        vm.startPrank(ADMIN);
        token.mint(user1, 5000e6);
        vm.stopPrank();
        
        vm.startPrank(user1);
        token.approve(poolAddress, 5000e6);
        uint256 shares1 = StableYieldPool(poolAddress).deposit(5000e6, user1);
        vm.stopPrank();
        
        console.log("  User1 deposited 5000e6, received shares:", shares1);
        
        // User 2 deposits
        vm.startPrank(ADMIN);
        token.mint(user2, 5000e6);
        vm.stopPrank();
        
        vm.startPrank(user2);
        token.approve(poolAddress, 5000e6);
        uint256 shares2 = StableYieldPool(poolAddress).deposit(5000e6, user2);
        vm.stopPrank();
        
        console.log("  User2 deposited 5000e6, received shares:", shares2);
        
        // Both should receive similar shares (accounting for fees)
        assertGt(shares1, 0, "User1 no shares");
        assertGt(shares2, 0, "User2 no shares");
        assertApproxEqRel(shares1, shares2, 0.01e18, "Share amounts too different");
        
        console.log("  SUCCESS: Multiple users can deposit fairly");
    }
}

