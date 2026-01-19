// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./fixtures/BaseTest.sol";
import "../src/LockedPoolManager.sol";
import "../src/StableYieldManager.sol";
import "../src/PoolRegistry.sol";
import "../src/factories/ManagedPoolFactory.sol";
import "../src/managed/LockedPool.sol";
import "../src/managed/StableYieldPool.sol";
import "../src/escrows/LockedPoolEscrow.sol";
import "../src/escrows/StableYieldEscrow.sol";
import "../src/AccessManager.sol";
import "../src/types/ILockedPoolTypes.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title LockedPoolTest
 * @notice Comprehensive tests for Locked Pool (tiered fixed-term deposit) functionality
 * @dev Tests tiers, deposits, interest calculations, early exit, maturity
 */
contract LockedPoolTest is BaseTest {
    
    AccessManager accessManager;
    PoolRegistry registry;
    LockedPoolManager lockedPoolManager;
    StableYieldManager stableYieldManager;
    ManagedPoolFactory managedFactory;
    MockERC20 token;
    
    address poolAddress;
    address escrowAddress;
    
    uint256 constant MIN_DEPOSIT = 1000e6;
    
    // Tier configurations
    uint16 constant TIER_3M_DAYS = 90;
    uint16 constant TIER_3M_APY = 500; // 5%
    uint16 constant TIER_3M_PENALTY = 1000; // 10%
    
    uint16 constant TIER_6M_DAYS = 180;
    uint16 constant TIER_6M_APY = 700; // 7%
    uint16 constant TIER_6M_PENALTY = 1500; // 15%
    
    uint16 constant TIER_12M_DAYS = 365;
    uint16 constant TIER_12M_APY = 1000; // 10%
    uint16 constant TIER_12M_PENALTY = 2000; // 20%
    
    function setUp() public override {
        super.setUp();
        
        // Deploy token
        token = new MockERC20("Mock USDC", "USDC", 6);
        token.mint(user1, INITIAL_BALANCE);
        token.mint(user2, INITIAL_BALANCE);
        token.mint(user3, INITIAL_BALANCE);
        token.mint(treasury, INITIAL_BALANCE * 100); // Treasury for interest
        token.mint(operator, INITIAL_BALANCE * 100); // For funding escrow
        
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
        
        // Deploy and initialize LockedPoolManager
        LockedPoolManager managerImpl = new LockedPoolManager();
        bytes memory managerInit = abi.encodeWithSignature(
            "initialize(address,address,address)",
            address(accessManager),
            address(registry),
            admin
        );
        ERC1967Proxy managerProxy = new ERC1967Proxy(address(managerImpl), managerInit);
        lockedPoolManager = LockedPoolManager(address(managerProxy));
        
        // Deploy and initialize StableYieldManager (required by ManagedPoolFactory)
        StableYieldManager syManagerImpl = new StableYieldManager();
        bytes memory syManagerInit = abi.encodeWithSignature(
            "initialize(address,address,address,uint256)",
            address(accessManager),
            address(registry),
            admin,
            300 // Default 3% fee
        );
        ERC1967Proxy syManagerProxy = new ERC1967Proxy(address(syManagerImpl), syManagerInit);
        stableYieldManager = StableYieldManager(address(syManagerProxy));
        
        // Deploy pool implementations
        LockedPool lockedPoolImpl = new LockedPool();
        LockedPoolEscrow lockedEscrowImpl = new LockedPoolEscrow();
        StableYieldPool stablePoolImpl = new StableYieldPool();
        StableYieldEscrow stableEscrowImpl = new StableYieldEscrow();
        
        // Deploy and initialize ManagedPoolFactory
        ManagedPoolFactory factoryImpl = new ManagedPoolFactory();
        bytes memory factoryInit = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address)",
            address(registry),
            address(accessManager),
            address(stableYieldManager),
            admin,
            address(stablePoolImpl),
            address(stableEscrowImpl)
        );
        ERC1967Proxy factoryProxy = new ERC1967Proxy(address(factoryImpl), factoryInit);
        managedFactory = ManagedPoolFactory(address(factoryProxy));
        
        // Configure
        vm.startPrank(admin);
        registry.approveAsset(address(token), "Mock USDC", "USDC", true);
        managedFactory.setLockedPoolManager(address(lockedPoolManager));
        managedFactory.updateLockedPoolImplementation(address(lockedPoolImpl));
        managedFactory.updateLockedPoolEscrowImplementation(address(lockedEscrowImpl));
        lockedPoolManager.setManagedPoolFactory(address(managedFactory));
        stableYieldManager.setManagedPoolFactory(address(managedFactory));
        
        // Grant roles
        accessManager.grantRoleDuringDeployment(accessManager.POOL_CREATOR_ROLE(), address(lockedPoolManager));
        accessManager.grantRoleDuringDeployment(accessManager.POOL_CREATOR_ROLE(), address(stableYieldManager));
        accessManager.grantRoleDuringDeployment(accessManager.POOL_CREATOR_ROLE(), admin);
        accessManager.grantRoleDuringDeployment(accessManager.OPERATOR_ROLE(), operator);
        accessManager.grantFactoryRoleDuringDeployment(address(managedFactory));
        // Factory also needs POOL_CREATOR_ROLE to register pools in PoolRegistry
        accessManager.grantRoleDuringDeployment(accessManager.POOL_CREATOR_ROLE(), address(managedFactory));
        vm.stopPrank();
    }
    
    // ============ HELPER FUNCTIONS ============
    
    function _createPool() internal returns (address, address) {
        // Create initial tiers
        ILockedPoolTypes.LockTier[] memory tiers = new ILockedPoolTypes.LockTier[](3);
        tiers[0] = ILockedPoolTypes.LockTier({
            durationDays: TIER_3M_DAYS,
            apyBps: TIER_3M_APY,
            earlyExitPenaltyBps: TIER_3M_PENALTY,
            minDeposit: MIN_DEPOSIT,
            isActive: true
        });
        tiers[1] = ILockedPoolTypes.LockTier({
            durationDays: TIER_6M_DAYS,
            apyBps: TIER_6M_APY,
            earlyExitPenaltyBps: TIER_6M_PENALTY,
            minDeposit: MIN_DEPOSIT,
            isActive: true
        });
        tiers[2] = ILockedPoolTypes.LockTier({
            durationDays: TIER_12M_DAYS,
            apyBps: TIER_12M_APY,
            earlyExitPenaltyBps: TIER_12M_PENALTY,
            minDeposit: MIN_DEPOSIT,
            isActive: true
        });
        
        ManagedPoolFactory.LockedPoolDeploymentConfig memory config = ManagedPoolFactory.LockedPoolDeploymentConfig({
            asset: address(token),
            poolName: "Test Locked Pool",
            poolSymbol: "tLP",
            spvAddress: spv,
            minInvestment: MIN_DEPOSIT,
            initialTiers: tiers
        });
        
        vm.prank(admin);
        (address pool, address escrow) = managedFactory.createLockedPool(config);
        
        return (pool, escrow);
    }
    
    function _fundEscrow(uint256 amount) internal {
        // Operator funds escrow for interest payments
        vm.startPrank(operator);
        token.transfer(escrowAddress, amount);
        vm.stopPrank();
    }
    
    function _depositAs(address user, uint256 amount, uint8 tierIndex) internal returns (uint256 positionId) {
        vm.startPrank(user);
        token.approve(poolAddress, amount);
        (positionId, ) = LockedPool(poolAddress).depositLocked(
            amount, 
            tierIndex, 
            ILockedPoolTypes.InterestPayment.AT_MATURITY
        );
        vm.stopPrank();
    }
    
    function _depositAsUpfront(address user, uint256 amount, uint8 tierIndex) internal returns (uint256 positionId) {
        vm.startPrank(user);
        token.approve(poolAddress, amount);
        (positionId, ) = LockedPool(poolAddress).depositLocked(
            amount, 
            tierIndex, 
            ILockedPoolTypes.InterestPayment.UPFRONT
        );
        vm.stopPrank();
    }
    
    // ============ POOL CREATION TESTS ============
    
    function test_createPool_success() public {
        (poolAddress, escrowAddress) = _createPool();
        
        assertTrue(registry.isRegisteredPool(poolAddress), "Pool not registered");
        assertEq(LockedPool(poolAddress).asset(), address(token), "Wrong asset");
    }
    
    function test_getPoolTiers_success() public {
        (poolAddress, escrowAddress) = _createPool();
        
        ILockedPoolTypes.LockTier[] memory tiers = lockedPoolManager.getPoolTiers(poolAddress);
        
        assertEq(tiers.length, 3, "Should have 3 tiers");
        assertEq(tiers[0].durationDays, TIER_3M_DAYS, "Wrong tier 0 duration");
        assertEq(tiers[1].durationDays, TIER_6M_DAYS, "Wrong tier 1 duration");
        assertEq(tiers[2].durationDays, TIER_12M_DAYS, "Wrong tier 2 duration");
    }
    
    function test_configureTiers_addNewTier() public {
        (poolAddress, escrowAddress) = _createPool();
        
        // Add a 4th tier
        vm.prank(operator);
        lockedPoolManager.configureLockTier(
            poolAddress,
            3,
            ILockedPoolTypes.LockTier({
                durationDays: 730, // 2 years
                apyBps: 1500, // 15%
                earlyExitPenaltyBps: 2500,
                minDeposit: MIN_DEPOSIT,
                isActive: true
            })
        );
        
        ILockedPoolTypes.LockTier[] memory tiers = lockedPoolManager.getPoolTiers(poolAddress);
        assertEq(tiers.length, 4, "Should have 4 tiers");
        assertEq(tiers[3].durationDays, 730);
    }
    
    function test_configureTiers_mustBeSequential() public {
        (poolAddress, escrowAddress) = _createPool();
        
        // Pool starts with 3 tiers (0, 1, 2). Try to add tier at index 4, skipping index 3
        vm.prank(operator);
        vm.expectRevert(LockedPoolManager.InvalidTier.selector);
        lockedPoolManager.configureLockTier(
            poolAddress,
            4, // Skipping index 3
            ILockedPoolTypes.LockTier({
                durationDays: TIER_3M_DAYS,
                apyBps: TIER_3M_APY,
                earlyExitPenaltyBps: TIER_3M_PENALTY,
                minDeposit: MIN_DEPOSIT,
                isActive: true
            })
        );
    }
    
    // ============ DEPOSIT TESTS ============
    
    function test_deposit_success() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(1_000_000e6);
        
        uint256 positionId = _depositAs(user1, 10_000e6, 0);
        
        ILockedPoolTypes.UserPosition memory position = lockedPoolManager.getPosition(positionId);
        
        assertEq(position.user, user1, "Wrong owner");
        assertEq(position.principalDeposited, 10_000e6, "Wrong principal");
        assertEq(position.tierIndex, 0, "Wrong tier");
        assertTrue(position.status == ILockedPoolTypes.PositionStatus.ACTIVE, "Wrong status");
    }
    
    function test_deposit_multiplePositions() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(1_000_000e6);
        
        uint256 pos1 = _depositAs(user1, 10_000e6, 0);
        uint256 pos2 = _depositAs(user1, 20_000e6, 1);
        uint256 pos3 = _depositAs(user1, 30_000e6, 2);
        
        assertTrue(pos1 != pos2 && pos2 != pos3, "Position IDs should be unique");
        
        assertEq(lockedPoolManager.getPosition(pos1).tierIndex, 0);
        assertEq(lockedPoolManager.getPosition(pos2).tierIndex, 1);
        assertEq(lockedPoolManager.getPosition(pos3).tierIndex, 2);
    }
    
    function test_deposit_belowMinimum_reverts() public {
        (poolAddress, escrowAddress) = _createPool();
        
        vm.startPrank(user1);
        token.approve(poolAddress, 500e6);
        vm.expectRevert();
        LockedPool(poolAddress).depositLocked(500e6, 0, ILockedPoolTypes.InterestPayment.AT_MATURITY);
        vm.stopPrank();
    }
    
    function test_deposit_invalidTier_reverts() public {
        (poolAddress, escrowAddress) = _createPool();
        
        vm.startPrank(user1);
        token.approve(poolAddress, 10_000e6);
        vm.expectRevert();
        LockedPool(poolAddress).depositLocked(10_000e6, 10, ILockedPoolTypes.InterestPayment.AT_MATURITY);
        vm.stopPrank();
    }
    
    // ============ INTEREST CALCULATION TESTS ============
    
    function test_interest_upfrontPayment() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(1_000_000e6);
        
        uint256 principal = 100_000e6;
        uint256 balanceBefore = token.balanceOf(user1);
        
        uint256 positionId = _depositAsUpfront(user1, principal, 0);
        
        uint256 balanceAfter = token.balanceOf(user1);
        
        // User should have received upfront interest minus the deposit
        // Expected interest: principal * APY * duration / (365 * 10000)
        uint256 expectedInterest = (principal * TIER_3M_APY * TIER_3M_DAYS) / (365 * 10000);
        
        ILockedPoolTypes.UserPosition memory position = lockedPoolManager.getPosition(positionId);
        
        // For upfront payment, user receives interest immediately
        assertEq(balanceBefore - principal + expectedInterest, balanceAfter, "Wrong balance after upfront payment");
        assertTrue(position.interestPaid, "Interest should be marked as paid");
    }
    
    function test_interest_maturityPayment() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(1_000_000e6);
        
        uint256 principal = 100_000e6;
        uint256 balanceBefore = token.balanceOf(user1);
        
        uint256 positionId = _depositAs(user1, principal, 0);
        
        uint256 balanceAfter = token.balanceOf(user1);
        
        // For maturity payment, user only loses the deposit
        assertEq(balanceBefore - principal, balanceAfter, "Should only deduct principal");
        
        ILockedPoolTypes.UserPosition memory position = lockedPoolManager.getPosition(positionId);
        assertFalse(position.interestPaid, "Interest should not be paid yet");
    }
    
    function test_interest_3monthTier_calculation() public {
        (poolAddress, escrowAddress) = _createPool();
        
        uint256 principal = 100_000e6;
        
        // Preview interest calculation
        (uint256 interest, uint256 apyBps, uint256 durationDays) = LockedPool(poolAddress).previewInterest(principal, 0);
        
        assertEq(apyBps, TIER_3M_APY, "Wrong APY");
        assertEq(durationDays, TIER_3M_DAYS, "Wrong duration");
        
        // Verify calculation: principal * APY * duration / (365 * 10000)
        uint256 expectedInterest = (principal * TIER_3M_APY * TIER_3M_DAYS) / (365 * 10000);
        assertEq(interest, expectedInterest, "Wrong interest calculation");
    }
    
    // ============ REDEMPTION TESTS ============
    
    function test_redeem_afterMaturity() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);
        
        uint256 principal = 100_000e6;
        uint256 positionId = _depositAs(user1, principal, 0);
        
        // Skip to maturity
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
        uint256 balanceBefore = token.balanceOf(user1);
        
        vm.prank(user1);
        LockedPool(poolAddress).redeemPosition(positionId);
        
        uint256 received = token.balanceOf(user1) - balanceBefore;
        
        // Should receive principal + interest
        uint256 expectedInterest = (principal * TIER_3M_APY * TIER_3M_DAYS) / (365 * 10000);
        assertApproxEqRel(received, principal + expectedInterest, 0.02e18);
        
        ILockedPoolTypes.UserPosition memory position = lockedPoolManager.getPosition(positionId);
        assertTrue(position.status == ILockedPoolTypes.PositionStatus.REDEEMED, "Should be redeemed");
    }
    
    function test_redeem_beforeMaturity_reverts() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(1_000_000e6);
        
        uint256 positionId = _depositAs(user1, 100_000e6, 0);
        
        // Position is ACTIVE, not MATURED
        vm.prank(user1);
        vm.expectRevert();
        LockedPool(poolAddress).redeemPosition(positionId);
    }
    
    // ============ EARLY EXIT TESTS ============
    
    function test_earlyExit_withPenalty() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);
        
        uint256 principal = 100_000e6;
        uint256 positionId = _depositAs(user1, principal, 0);
        
        // Exit after 30 days (early)
        skipTime(30 days);
        
        uint256 balanceBefore = token.balanceOf(user1);
        
        vm.prank(user1);
        (uint256 payout, uint256 penalty) = LockedPool(poolAddress).earlyExitPosition(positionId);
        
        uint256 received = token.balanceOf(user1) - balanceBefore;
        
        // Should receive principal minus penalty
        uint256 expectedPenalty = (principal * TIER_3M_PENALTY) / 10000;
        assertApproxEqRel(penalty, expectedPenalty, 0.02e18, "Wrong penalty");
        assertApproxEqRel(payout, principal - expectedPenalty, 0.02e18, "Wrong payout");
        assertEq(received, payout, "Received doesn't match payout");
        
        ILockedPoolTypes.UserPosition memory position = lockedPoolManager.getPosition(positionId);
        assertTrue(position.status == ILockedPoolTypes.PositionStatus.EARLY_EXIT);
    }
    
    function test_earlyExit_higherTierHigherPenalty() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);
        
        uint256 principal = 100_000e6;
        
        // Deposit in different tiers
        uint256 pos3m = _depositAs(user1, principal, 0); // 10% penalty
        uint256 pos6m = _depositAs(user2, principal, 1); // 15% penalty
        uint256 pos12m = _depositAs(user3, principal, 2); // 20% penalty
        
        skipTime(30 days);
        
        vm.prank(user1);
        (, uint256 penalty3m) = LockedPool(poolAddress).earlyExitPosition(pos3m);
        
        vm.prank(user2);
        (, uint256 penalty6m) = LockedPool(poolAddress).earlyExitPosition(pos6m);
        
        vm.prank(user3);
        (, uint256 penalty12m) = LockedPool(poolAddress).earlyExitPosition(pos12m);
        
        // Higher tiers should have higher penalties
        assertTrue(penalty6m > penalty3m, "6m penalty should be higher than 3m");
        assertTrue(penalty12m > penalty6m, "12m penalty should be higher than 6m");
    }
    
    // ============ EDGE CASES ============
    
    function test_edgeCase_multipleDepositsAndExits() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(100_000_000e6);
        
        uint256 pos1 = _depositAs(user1, 50_000e6, 0);
        uint256 pos2 = _depositAs(user1, 30_000e6, 1);
        uint256 pos3 = _depositAs(user2, 40_000e6, 2);
        
        // User1 early exits first position
        skipTime(30 days);
        vm.prank(user1);
        LockedPool(poolAddress).earlyExitPosition(pos1);
        
        // User1 waits for second position to mature
        skipTime(150 days);
        vm.prank(user1);
        LockedPool(poolAddress).redeemPosition(pos2);
        
        // User2 waits for 12-month position
        skipTime(185 days);
        vm.prank(user2);
        LockedPool(poolAddress).redeemPosition(pos3);
        
        // Verify all positions properly updated
        assertEq(uint8(lockedPoolManager.getPosition(pos1).status), uint8(ILockedPoolTypes.PositionStatus.EARLY_EXIT));
        assertEq(uint8(lockedPoolManager.getPosition(pos2).status), uint8(ILockedPoolTypes.PositionStatus.REDEEMED));
        assertEq(uint8(lockedPoolManager.getPosition(pos3).status), uint8(ILockedPoolTypes.PositionStatus.REDEEMED));
    }
    
    function test_edgeCase_exitAtExactMaturity() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);
        
        uint256 principal = 100_000e6;
        uint256 positionId = _depositAs(user1, principal, 0);
        
        // Skip exactly to maturity
        skipTime(TIER_3M_DAYS * 1 days);
        
        // Should be able to redeem at exactly lock end
        vm.prank(user1);
        LockedPool(poolAddress).redeemPosition(positionId);
        
        assertTrue(lockedPoolManager.getPosition(positionId).status == ILockedPoolTypes.PositionStatus.REDEEMED);
    }
    
    function test_edgeCase_differentUsersCannotRedeemOthersPosition() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);
        
        uint256 positionId = _depositAs(user1, 100_000e6, 0);
        
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
        // User2 cannot redeem user1's position
        vm.prank(user2);
        vm.expectRevert("LockedPool/not owner");
        LockedPool(poolAddress).redeemPosition(positionId);
    }
    
    function test_edgeCase_cannotRedeemTwice() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);
        
        uint256 positionId = _depositAs(user1, 100_000e6, 0);
        
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
        vm.prank(user1);
        LockedPool(poolAddress).redeemPosition(positionId);
        
        // Cannot redeem again
        vm.prank(user1);
        vm.expectRevert();
        LockedPool(poolAddress).redeemPosition(positionId);
    }
    
    // ============ APY MANAGEMENT TESTS ============
    
    function test_apyUpdate_canUpdateExistingTier() public {
        (poolAddress, escrowAddress) = _createPool();
        
        // Update tier 0 APY to 8%
        vm.prank(operator);
        lockedPoolManager.configureLockTier(
            poolAddress,
            0,
            ILockedPoolTypes.LockTier({
                durationDays: TIER_3M_DAYS,
                apyBps: 800, // 8%
                earlyExitPenaltyBps: TIER_3M_PENALTY,
                minDeposit: MIN_DEPOSIT,
                isActive: true
            })
        );
        
        ILockedPoolTypes.LockTier[] memory tiers = lockedPoolManager.getPoolTiers(poolAddress);
        assertEq(tiers[0].apyBps, 800, "APY should be updated");
    }
    
    function test_tierDeactivation() public {
        (poolAddress, escrowAddress) = _createPool();
        
        // Deactivate tier 2
        vm.prank(operator);
        lockedPoolManager.configureLockTier(
            poolAddress,
            2,
            ILockedPoolTypes.LockTier({
                durationDays: TIER_12M_DAYS,
                apyBps: TIER_12M_APY,
                earlyExitPenaltyBps: TIER_12M_PENALTY,
                minDeposit: MIN_DEPOSIT,
                isActive: false // Deactivated
            })
        );
        
        // Cannot deposit to deactivated tier
        vm.startPrank(user1);
        token.approve(poolAddress, 100_000e6);
        vm.expectRevert();
        LockedPool(poolAddress).depositLocked(100_000e6, 2, ILockedPoolTypes.InterestPayment.AT_MATURITY);
        vm.stopPrank();
    }
    
    // ============ VIEW FUNCTIONS TESTS ============
    
    function test_getUserPositions() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);
        
        _depositAs(user1, 10_000e6, 0);
        _depositAs(user1, 20_000e6, 1);
        _depositAs(user1, 30_000e6, 2);
        
        uint256[] memory positions = LockedPool(poolAddress).getUserPositions(user1);
        
        assertEq(positions.length, 3, "Should have 3 positions");
    }
    
    function test_getPoolMetrics() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);
        
        _depositAs(user1, 50_000e6, 0);
        _depositAs(user2, 30_000e6, 1);
        
        ILockedPoolTypes.PoolMetrics memory metrics = LockedPool(poolAddress).getPoolMetrics();
        
        assertEq(metrics.totalPrincipalLocked, 80_000e6, "Wrong total principal locked");
        assertEq(metrics.activePositions, 2, "Wrong active positions count");
    }
    
    // ============ AUTO-ROLLOVER TESTS ============
    
    function test_autoRollover_setPreference() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);
        
        uint256 positionId = _depositAs(user1, 100_000e6, 0);
        
        // Initially autoRollover should be false
        ILockedPoolTypes.UserPosition memory position = lockedPoolManager.getPosition(positionId);
        assertFalse(position.autoRollover, "Should default to false");
        
        // User enables auto-rollover
        vm.prank(user1);
        LockedPool(poolAddress).setAutoRollover(positionId, true);
        
        position = lockedPoolManager.getPosition(positionId);
        assertTrue(position.autoRollover, "Should be enabled");
        
        // User can disable
        vm.prank(user1);
        LockedPool(poolAddress).setAutoRollover(positionId, false);
        
        position = lockedPoolManager.getPosition(positionId);
        assertFalse(position.autoRollover, "Should be disabled");
    }
    
    function test_autoRollover_onlyOwnerCanSet() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);
        
        uint256 positionId = _depositAs(user1, 100_000e6, 0);
        
        // User2 cannot set user1's rollover preference
        vm.prank(user2);
        vm.expectRevert(LockedPoolManager.NotOwner.selector);
        LockedPool(poolAddress).setAutoRollover(positionId, true);
    }
    
    function test_autoRollover_executeRollover_atMaturity() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(100_000_000e6);
        
        uint256 principal = 100_000e6;
        uint256 positionId = _depositAs(user1, principal, 0);
        
        // Calculate expected compounded principal (for AT_MATURITY, interest compounds)
        uint256 expectedInterest = (principal * TIER_3M_APY * TIER_3M_DAYS) / (365 * 10000);
        uint256 expectedCompoundedPrincipal = principal + expectedInterest;
        
        // Enable auto-rollover
        vm.prank(user1);
        LockedPool(poolAddress).setAutoRollover(positionId, true);
        
        // Skip to maturity
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
        // Operator executes rollover
        vm.prank(operator);
        uint256 newPositionId = lockedPoolManager.executeRollover(positionId);
        
        // Old position should be ROLLED_OVER
        ILockedPoolTypes.UserPosition memory oldPosition = lockedPoolManager.getPosition(positionId);
        assertTrue(oldPosition.status == ILockedPoolTypes.PositionStatus.ROLLED_OVER, "Old position should be rolled over");
        
        // New position should be ACTIVE with compounded principal (for AT_MATURITY)
        ILockedPoolTypes.UserPosition memory newPosition = lockedPoolManager.getPosition(newPositionId);
        assertTrue(newPosition.status == ILockedPoolTypes.PositionStatus.ACTIVE, "New position should be active");
        assertApproxEqRel(newPosition.principalDeposited, expectedCompoundedPrincipal, 0.01e18, "Principal should compound for AT_MATURITY");
        assertEq(newPosition.user, user1, "Owner should be same");
        assertEq(newPosition.tierIndex, 0, "Tier should be same");
        assertTrue(newPosition.autoRollover, "Auto-rollover should be inherited");
        assertEq(newPosition.rolledFromPositionId, positionId, "Should reference old position");
    }
    
    function test_autoRollover_atMaturity_compoundsInterest() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(100_000_000e6);
        
        uint256 principal = 100_000e6;
        uint256 positionId = _depositAs(user1, principal, 0); // AT_MATURITY
        
        // Calculate expected interest
        uint256 expectedInterest = (principal * TIER_3M_APY * TIER_3M_DAYS) / (365 * 10000);
        
        vm.prank(user1);
        LockedPool(poolAddress).setAutoRollover(positionId, true);
        
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
        vm.prank(operator);
        uint256 newPositionId = lockedPoolManager.executeRollover(positionId);
        
        ILockedPoolTypes.UserPosition memory newPosition = lockedPoolManager.getPosition(newPositionId);
        
        // New principal should be original principal + interest (compounded)
        assertApproxEqRel(newPosition.principalDeposited, principal + expectedInterest, 0.01e18, "Should compound interest");
    }
    
    function test_autoRollover_upfront_onlyPrincipalRolls() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(100_000_000e6);
        
        uint256 principal = 100_000e6;
        uint256 positionId = _depositAsUpfront(user1, principal, 0); // UPFRONT
        
        vm.prank(user1);
        LockedPool(poolAddress).setAutoRollover(positionId, true);
        
        // User already received upfront interest
        ILockedPoolTypes.UserPosition memory oldPosition = lockedPoolManager.getPosition(positionId);
        assertTrue(oldPosition.interestPaid, "Interest should be paid upfront");
        
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
        uint256 userBalanceBefore = token.balanceOf(user1);
        
        vm.prank(operator);
        uint256 newPositionId = lockedPoolManager.executeRollover(positionId);
        
        ILockedPoolTypes.UserPosition memory newPosition = lockedPoolManager.getPosition(newPositionId);
        
        // For UPFRONT, only principal rolls, not interest
        assertEq(newPosition.principalDeposited, principal, "Only principal should roll for UPFRONT");
        
        // User should have received NEW upfront interest
        uint256 userBalanceAfter = token.balanceOf(user1);
        assertTrue(userBalanceAfter > userBalanceBefore, "Should receive new upfront interest");
    }
    
    function test_autoRollover_cannotExecuteBeforeMaturity() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);
        
        uint256 positionId = _depositAs(user1, 100_000e6, 0);
        
        vm.prank(user1);
        LockedPool(poolAddress).setAutoRollover(positionId, true);
        
        // Skip only 30 days (not matured)
        skipTime(30 days);
        
        vm.prank(operator);
        vm.expectRevert(LockedPoolManager.NotMatured.selector);
        lockedPoolManager.executeRollover(positionId);
    }
    
    function test_autoRollover_cannotExecuteIfDisabled() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);
        
        uint256 positionId = _depositAs(user1, 100_000e6, 0);
        
        // autoRollover is false by default
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
        vm.prank(operator);
        vm.expectRevert(LockedPoolManager.RolloverNotEnabled.selector);
        lockedPoolManager.executeRollover(positionId);
    }
    
    function test_autoRollover_batchExecute() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(100_000_000e6);
        
        // Multiple users deposit and enable rollover
        uint256 pos1 = _depositAs(user1, 50_000e6, 0);
        uint256 pos2 = _depositAs(user2, 30_000e6, 0);
        uint256 pos3 = _depositAs(user3, 40_000e6, 0);
        
        vm.prank(user1);
        LockedPool(poolAddress).setAutoRollover(pos1, true);
        
        vm.prank(user2);
        LockedPool(poolAddress).setAutoRollover(pos2, true);
        
        // user3 does NOT enable rollover
        
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
        uint256[] memory positionIds = new uint256[](3);
        positionIds[0] = pos1;
        positionIds[1] = pos2;
        positionIds[2] = pos3;
        
        vm.prank(operator);
        uint256[] memory newPositionIds = lockedPoolManager.batchExecuteRollovers(positionIds);
        
        // pos1 and pos2 should have rolled over
        assertTrue(newPositionIds[0] > 0, "pos1 should have rolled");
        assertTrue(newPositionIds[1] > 0, "pos2 should have rolled");
        
        // pos3 should NOT have rolled (autoRollover = false)
        assertEq(newPositionIds[2], 0, "pos3 should not have rolled");
        
        // Verify statuses
        assertEq(uint8(lockedPoolManager.getPosition(pos1).status), uint8(ILockedPoolTypes.PositionStatus.ROLLED_OVER));
        assertEq(uint8(lockedPoolManager.getPosition(pos2).status), uint8(ILockedPoolTypes.PositionStatus.ROLLED_OVER));
        assertEq(uint8(lockedPoolManager.getPosition(pos3).status), uint8(ILockedPoolTypes.PositionStatus.ACTIVE)); // Still active
    }
    
    function test_autoRollover_chainedRollovers() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(100_000_000e6);
        
        uint256 principal = 100_000e6;
        uint256 positionId = _depositAs(user1, principal, 0);
        
        vm.prank(user1);
        LockedPool(poolAddress).setAutoRollover(positionId, true);
        
        // First rollover
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
        vm.prank(operator);
        uint256 secondPositionId = lockedPoolManager.executeRollover(positionId);
        
        // Second rollover (auto-rollover is inherited)
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
        vm.prank(operator);
        uint256 thirdPositionId = lockedPoolManager.executeRollover(secondPositionId);
        
        // Verify chain
        ILockedPoolTypes.UserPosition memory thirdPos = lockedPoolManager.getPosition(thirdPositionId);
        assertEq(thirdPos.rolledFromPositionId, secondPositionId, "Should reference second position");
        assertTrue(thirdPos.autoRollover, "Auto-rollover should persist");
        
        // Verify compounding (AT_MATURITY): each rollover compounds interest
        uint256 expectedAfterFirst = principal + (principal * TIER_3M_APY * TIER_3M_DAYS) / (365 * 10000);
        uint256 expectedAfterSecond = expectedAfterFirst + (expectedAfterFirst * TIER_3M_APY * TIER_3M_DAYS) / (365 * 10000);
        
        assertApproxEqRel(thirdPos.principalDeposited, expectedAfterSecond, 0.02e18, "Should compound twice");
    }
    
    function test_autoRollover_tierDeactivatedPreventsRollover() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);
        
        uint256 positionId = _depositAs(user1, 100_000e6, 0);
        
        vm.prank(user1);
        LockedPool(poolAddress).setAutoRollover(positionId, true);
        
        // Deactivate tier 0
        vm.prank(operator);
        lockedPoolManager.configureLockTier(
            poolAddress,
            0,
            ILockedPoolTypes.LockTier({
                durationDays: TIER_3M_DAYS,
                apyBps: TIER_3M_APY,
                earlyExitPenaltyBps: TIER_3M_PENALTY,
                minDeposit: MIN_DEPOSIT,
                isActive: false // Deactivated
            })
        );
        
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
        // Should fail because tier is deactivated
        vm.prank(operator);
        vm.expectRevert(LockedPoolManager.TierNotActive.selector);
        lockedPoolManager.executeRollover(positionId);
    }
    
    function test_autoRollover_canStillRedeemIfPreferManual() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(100_000_000e6);
        
        uint256 principal = 100_000e6;
        uint256 positionId = _depositAs(user1, principal, 0);
        
        // User enables rollover but changes mind
        vm.prank(user1);
        LockedPool(poolAddress).setAutoRollover(positionId, true);
        
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
        // User disables before operator can rollover
        vm.prank(user1);
        LockedPool(poolAddress).setAutoRollover(positionId, false);
        
        // User manually redeems
        vm.prank(user1);
        LockedPool(poolAddress).redeemPosition(positionId);
        
        assertTrue(lockedPoolManager.getPosition(positionId).status == ILockedPoolTypes.PositionStatus.REDEEMED);
    }
    
    function test_autoRollover_cannotSetOnRedeemedPosition() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);
        
        uint256 positionId = _depositAs(user1, 100_000e6, 0);
        
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
        vm.prank(user1);
        LockedPool(poolAddress).redeemPosition(positionId);
        
        // Cannot set rollover on redeemed position
        vm.prank(user1);
        vm.expectRevert(LockedPoolManager.InvalidStatus.selector);
        LockedPool(poolAddress).setAutoRollover(positionId, true);
    }
}
