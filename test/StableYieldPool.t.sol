// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./fixtures/BaseTest.sol";
import "../src/StableYieldManager.sol";
import "../src/PoolRegistry.sol";
import "../src/factories/ManagedPoolFactory.sol";
import "../src/managed/StableYieldPool.sol";
import "../src/escrows/StableYieldEscrow.sol";
import "../src/AccessManager.sol";
import "../src/types/IStableYieldTypes.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title StableYieldPoolTest
 * @notice Comprehensive tests for Stable Yield Pool (revolving T-bill) functionality
 * @dev Tests NAV, deposits, withdrawals, SPV allocations, instruments
 */
contract StableYieldPoolTest is BaseTest {
    
    AccessManager accessManager;
    PoolRegistry registry;
    StableYieldManager stableYieldManager;
    ManagedPoolFactory managedFactory;
    MockERC20 token;
    
    address poolAddress;
    address escrowAddress;
    
    uint256 constant MIN_INVESTMENT = 1000e6;
    uint256 constant DEFAULT_FEE_BPS = 300; // 3%
    
    function setUp() public override {
        super.setUp();
        
        // Deploy token
        token = new MockERC20("Mock USDC", "USDC", 6);
        token.mint(user1, INITIAL_BALANCE);
        token.mint(user2, INITIAL_BALANCE);
        token.mint(user3, INITIAL_BALANCE);
        token.mint(spv, INITIAL_BALANCE * 10);
        
        // Deploy AccessManager
        accessManager = new AccessManager(admin, spv, operator, emergency, multisigAdmin);
        
        // Deploy and initialize PoolRegistry
        PoolRegistry registryImpl = new PoolRegistry();
        bytes memory registryInit = abi.encodeWithSignature(
            "initialize(address,address)",
            address(accessManager),
            admin
        );
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryInit);
        registry = PoolRegistry(address(registryProxy));
        
        // Deploy and initialize StableYieldManager
        StableYieldManager managerImpl = new StableYieldManager();
        bytes memory managerInit = abi.encodeWithSignature(
            "initialize(address,address,address,uint256)",
            address(accessManager),
            address(registry),
            admin,
            DEFAULT_FEE_BPS
        );
        ERC1967Proxy managerProxy = new ERC1967Proxy(address(managerImpl), managerInit);
        stableYieldManager = StableYieldManager(address(managerProxy));
        
        // Deploy pool implementations
        StableYieldPool poolImpl = new StableYieldPool();
        StableYieldEscrow escrowImpl = new StableYieldEscrow();
        
        // Deploy and initialize ManagedPoolFactory
        ManagedPoolFactory factoryImpl = new ManagedPoolFactory();
        bytes memory factoryInit = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address)",
            address(registry),
            address(accessManager),
            address(stableYieldManager),
            admin,
            address(poolImpl),
            address(escrowImpl)
        );
        ERC1967Proxy factoryProxy = new ERC1967Proxy(address(factoryImpl), factoryInit);
        managedFactory = ManagedPoolFactory(address(factoryProxy));
        
        // Configure
        vm.startPrank(admin);
        registry.approveAsset(address(token), "Mock USDC", "USDC", true);
        stableYieldManager.setManagedPoolFactory(address(managedFactory));
        
        // Grant roles
        accessManager.grantRoleDuringDeployment(accessManager.POOL_CREATOR_ROLE(), address(stableYieldManager));
        accessManager.grantRoleDuringDeployment(accessManager.POOL_CREATOR_ROLE(), admin);
        accessManager.grantFactoryRoleDuringDeployment(address(managedFactory));
        // Factory also needs POOL_CREATOR_ROLE to register pools in PoolRegistry
        accessManager.grantRoleDuringDeployment(accessManager.POOL_CREATOR_ROLE(), address(managedFactory));
        // StableYieldManager needs OPERATOR_ROLE to call escrow.allocateToSPV()
        accessManager.grantRoleDuringDeployment(accessManager.OPERATOR_ROLE(), address(stableYieldManager));
        // Grant operator role to operator address for tests
        accessManager.grantRoleDuringDeployment(accessManager.OPERATOR_ROLE(), operator);
        vm.stopPrank();
    }
    
    // ============ HELPER FUNCTIONS ============
    
    function _createPool() internal returns (address, address) {
        // Tenors are in days (not seconds) - factory validates for 90, 180, 270, or 360
        uint256[] memory tenors = new uint256[](3);
        tenors[0] = 90;
        tenors[1] = 180;
        tenors[2] = 360;
        
        ManagedPoolFactory.PoolDeploymentConfig memory config = ManagedPoolFactory.PoolDeploymentConfig({
            asset: address(token),
            poolName: "Test Stable Yield Pool",
            poolSymbol: "tSYP",
            spvAddress: spv,
            supportedTenors: tenors,
            minInvestment: MIN_INVESTMENT,
            underlyingPools: new address[](0)
        });
        
        vm.prank(admin);
        (address pool, address escrow) = managedFactory.createStableYieldPool(config);
        
        return (pool, escrow);
    }
    
    function _depositAs(address user, uint256 amount) internal {
        vm.startPrank(user);
        token.approve(poolAddress, amount);
        StableYieldPool(poolAddress).deposit(amount, user);
        vm.stopPrank();
    }
    
    // ============ POOL CREATION TESTS ============
    
    function test_createPool_success() public {
        (poolAddress, escrowAddress) = _createPool();
        
        assertTrue(registry.isRegisteredPool(poolAddress), "Pool not registered");
        assertEq(StableYieldPool(poolAddress).asset(), address(token), "Wrong asset");
    }
    
    // ============ DEPOSIT TESTS ============
    
    function test_deposit_success() public {
        (poolAddress, escrowAddress) = _createPool();
        
        uint256 depositAmount = 10_000e6;
        uint256 fee = (depositAmount * DEFAULT_FEE_BPS) / 10000;
        uint256 netDeposit = depositAmount - fee;
        
        _depositAs(user1, depositAmount);
        
        // Shares should equal net deposit (1:1 initially)
        assertApproxEqRel(
            StableYieldPool(poolAddress).balanceOf(user1), 
            netDeposit, 
            0.01e18
        );
    }
    
    function test_deposit_multipleUsers_proportionalShares() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 50_000e6);
        _depositAs(user2, 30_000e6);
        _depositAs(user3, 20_000e6);
        
        // Each user should have proportional shares (minus fees)
        uint256 user1Shares = StableYieldPool(poolAddress).balanceOf(user1);
        uint256 user2Shares = StableYieldPool(poolAddress).balanceOf(user2);
        uint256 user3Shares = StableYieldPool(poolAddress).balanceOf(user3);
        
        assertTrue(user1Shares > user2Shares, "User1 should have more shares than user2");
        assertTrue(user2Shares > user3Shares, "User2 should have more shares than user3");
    }
    
    function test_deposit_belowMinimum_reverts() public {
        (poolAddress, escrowAddress) = _createPool();
        
        vm.startPrank(user1);
        token.approve(poolAddress, 500e6);
        vm.expectRevert();
        StableYieldPool(poolAddress).deposit(500e6, user1);
        vm.stopPrank();
    }
    
    // ============ NAV TESTS ============
    
    function test_nav_initiallyEqualToDeposits() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        uint256 nav = stableYieldManager.calculatePoolNAV(poolAddress);
        uint256 fee = (100_000e6 * DEFAULT_FEE_BPS) / 10000;
        
        assertApproxEqRel(nav, 100_000e6 - fee, 0.01e18);
    }
    
    function test_nav_increasesWithInstrumentValue() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        uint256 navBefore = stableYieldManager.calculatePoolNAV(poolAddress);
        
        // Operator creates allocation for SPV
        vm.prank(operator);
        bytes32 allocationId = stableYieldManager.createPendingAllocation(
            poolAddress,
            spv,
            50_000e6
        );
        
        vm.prank(spv);
        stableYieldManager.addInstrument(
            poolAddress,
            allocationId,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            50_000e6,  // purchase price
            52_500e6,  // face value (5% yield)
            block.timestamp + 90 days, // maturity
            0, // annual coupon rate
            0  // coupon frequency
        );
        
        uint256 navAfter = stableYieldManager.calculatePoolNAV(poolAddress);
        
        // NAV should include mark-to-market value of instrument
        assertTrue(navAfter >= navBefore, "NAV should not decrease");
    }
    
    // ============ WITHDRAWAL TESTS ============
    
    function test_withdraw_afterHoldingPeriod() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        uint256 shares = StableYieldPool(poolAddress).balanceOf(user1);
        
        // Skip the holding period
        skipTime(30 days + 1);
        
        uint256 balanceBefore = token.balanceOf(user1);
        
        vm.prank(user1);
        StableYieldPool(poolAddress).redeem(shares / 2, user1, user1);
        
        assertTrue(token.balanceOf(user1) > balanceBefore, "Should receive tokens");
    }
    
    function test_withdraw_beforeHoldingPeriod_reverts() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        uint256 shares = StableYieldPool(poolAddress).balanceOf(user1);
        
        // Try to withdraw immediately - should fail
        vm.prank(user1);
        vm.expectRevert("StableYieldPool/minimum holding period not met");
        StableYieldPool(poolAddress).redeem(shares, user1, user1);
    }
    
    function test_withdraw_withFee() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        skipTime(30 days + 1);
        
        uint256 shares = StableYieldPool(poolAddress).balanceOf(user1);
        uint256 balanceBefore = token.balanceOf(user1);
        
        vm.prank(user1);
        StableYieldPool(poolAddress).redeem(shares, user1, user1);
        
        uint256 received = token.balanceOf(user1) - balanceBefore;
        
        // Should receive assets minus withdrawal fee
        // The exact amount depends on NAV calculations
        assertTrue(received > 0, "Should receive some tokens");
    }
    
    // ============ SPV ALLOCATION TESTS ============
    
    function test_spvAllocation_createAndUse() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        // Create allocation (operator on behalf of SPV)
        vm.prank(operator);
        bytes32 allocationId = stableYieldManager.createPendingAllocation(
            poolAddress,
            spv,
            50_000e6
        );
        
        IStableYieldTypes.PendingAllocation memory allocation = 
            stableYieldManager.getPendingAllocation(allocationId);
        
        assertEq(allocation.amount, 50_000e6);
        assertEq(allocation.spv, spv);
        assertTrue(allocation.status == IStableYieldTypes.AllocationStatus.PENDING);
    }
    
    function test_spvAllocation_addInstrument() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        vm.prank(operator);
        bytes32 allocationId = stableYieldManager.createPendingAllocation(
            poolAddress,
            spv,
            50_000e6
        );
        
        vm.prank(spv);
        stableYieldManager.addInstrument(
            poolAddress,
            allocationId,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            50_000e6,
            52_500e6, // 5% yield
            block.timestamp + 90 days,
            0,
            0
        );
        
        IStableYieldTypes.InstrumentHolding[] memory instruments = 
            stableYieldManager.getPoolInstruments(poolAddress);
        
        assertEq(instruments.length, 1, "Should have 1 instrument");
        assertEq(instruments[0].purchasePrice, 50_000e6);
        assertEq(instruments[0].faceValue, 52_500e6);
    }
    
    function test_spvAllocation_returnUnused() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        vm.prank(operator);
        bytes32 allocationId = stableYieldManager.createPendingAllocation(
            poolAddress,
            spv,
            50_000e6
        );
        
        // SPV only uses 30k
        vm.prank(spv);
        stableYieldManager.addInstrument(
            poolAddress,
            allocationId,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            30_000e6,
            31_500e6,
            block.timestamp + 90 days,
            0,
            0
        );
        
        // Return unused funds (20k)
        vm.startPrank(spv);
        token.approve(address(stableYieldManager), 20_000e6);
        stableYieldManager.returnUnusedFunds(allocationId, 20_000e6);
        vm.stopPrank();
        
        IStableYieldTypes.PendingAllocation memory allocation = 
            stableYieldManager.getPendingAllocation(allocationId);
        
        assertEq(allocation.returnedAmount, 20_000e6);
    }
    
    // ============ INSTRUMENT MATURITY TESTS ============
    
    function test_instrumentMaturity_fullCycle() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        vm.prank(operator);
        bytes32 allocationId = stableYieldManager.createPendingAllocation(
            poolAddress,
            spv,
            50_000e6
        );
        
        vm.prank(spv);
        stableYieldManager.addInstrument(
            poolAddress,
            allocationId,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            50_000e6,
            52_500e6,
            block.timestamp + 90 days,
            0,
            0
        );
        
        // Verify instrument exists before maturity
        IStableYieldTypes.InstrumentHolding[] memory instrumentsBefore = 
            stableYieldManager.getPoolInstruments(poolAddress);
        assertEq(instrumentsBefore.length, 1, "Should have 1 instrument before maturity");
        assertTrue(instrumentsBefore[0].isActive, "Instrument should be active before maturity");
        
        // Skip to maturity
        skipTime(90 days + 1);
        
        // SPV returns matured funds
        vm.startPrank(spv);
        token.approve(address(stableYieldManager), 52_500e6);
        stableYieldManager.matureInstrumentWithFunds(poolAddress, 0, 52_500e6);
        vm.stopPrank();
        
        // Instrument is removed after maturity (not just marked inactive)
        IStableYieldTypes.InstrumentHolding[] memory instrumentsAfter = 
            stableYieldManager.getPoolInstruments(poolAddress);
        
        assertEq(instrumentsAfter.length, 0, "Instrument should be removed after maturity");
    }
    
    // ============ SHARE TRANSFER TESTS ============
    
    function test_shareTransfer_resetsHoldingPeriod() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        // Skip some time (but not full holding period)
        skipTime(15 days);
        
        uint256 shares = StableYieldPool(poolAddress).balanceOf(user1);
        
        // Transfer to user2
        vm.prank(user1);
        StableYieldPool(poolAddress).transfer(user2, shares);
        
        // User2 cannot withdraw immediately (holding period reset)
        vm.prank(user2);
        vm.expectRevert("StableYieldPool/minimum holding period not met");
        StableYieldPool(poolAddress).redeem(shares, user2, user2);
        
        // After full holding period, user2 can withdraw
        skipTime(30 days + 1);
        
        vm.prank(user2);
        StableYieldPool(poolAddress).redeem(shares, user2, user2);
    }
    
    // ============ EDGE CASES ============
    
    function test_edgeCase_depositWhenNoLiquidity() public {
        (poolAddress, escrowAddress) = _createPool();
        
        // First deposit should work
        _depositAs(user1, 100_000e6);
        
        assertTrue(StableYieldPool(poolAddress).balanceOf(user1) > 0);
    }
    
    function test_edgeCase_withdrawAllLiquidity() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        skipTime(30 days + 1);
        
        uint256 shares = StableYieldPool(poolAddress).balanceOf(user1);
        
        vm.prank(user1);
        StableYieldPool(poolAddress).redeem(shares, user1, user1);
        
        assertEq(StableYieldPool(poolAddress).balanceOf(user1), 0);
        assertEq(StableYieldPool(poolAddress).totalSupply(), 0);
    }
    
    function test_edgeCase_expiredAllocation() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        vm.prank(operator);
        bytes32 allocationId = stableYieldManager.createPendingAllocation(
            poolAddress,
            spv,
            50_000e6
        );
        
        // Skip past expiry (ALLOCATION_EXPIRY is 10 days)
        skipTime(11 days);
        
        // Try to add instrument - should fail
        vm.prank(spv);
        vm.expectRevert("StableYieldManager/allocation expired");
        stableYieldManager.addInstrument(
            poolAddress,
            allocationId,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            50_000e6,
            52_500e6,
            block.timestamp + 90 days,
            0,
            0
        );
    }
    
    // ============ FEE TESTS ============
    
    function test_fee_customPoolFee() public {
        (poolAddress, escrowAddress) = _createPool();
        
        // Set custom fee for this pool (5%)
        vm.prank(admin);
        stableYieldManager.setPoolTransactionFee(poolAddress, 500);
        
        uint256 depositAmount = 100_000e6;
        uint256 expectedFee = (depositAmount * 500) / 10000;
        
        _depositAs(user1, depositAmount);
        
        uint256 shares = StableYieldPool(poolAddress).balanceOf(user1);
        // Shares should be approximately deposit minus 5% fee
        assertApproxEqRel(shares, depositAmount - expectedFee, 0.02e18);
    }
    
    // ============ VIEW FUNCTION TESTS ============
    
    function test_canWithdraw_returnsFalseBeforeHoldingPeriod() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        assertFalse(StableYieldPool(poolAddress).canWithdraw(user1));
        
        skipTime(30 days + 1);
        
        assertTrue(StableYieldPool(poolAddress).canWithdraw(user1));
    }
    
    function test_getRemainingHoldingPeriod() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        uint256 remaining = StableYieldPool(poolAddress).getRemainingHoldingPeriod(user1);
        assertApproxEqRel(remaining, 30 days, 0.01e18);
        
        skipTime(15 days);
        
        remaining = StableYieldPool(poolAddress).getRemainingHoldingPeriod(user1);
        assertApproxEqRel(remaining, 15 days, 0.01e18);
        
        skipTime(20 days);
        
        remaining = StableYieldPool(poolAddress).getRemainingHoldingPeriod(user1);
        assertEq(remaining, 0);
    }
    
    function test_getNAVPerShare() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        uint256 navPerShare = StableYieldPool(poolAddress).getNAVPerShare();
        
        // Initially should be 1e18 (1:1)
        assertApproxEqRel(navPerShare, 1e18, 0.01e18);
    }
}
