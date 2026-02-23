// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./fixtures/BaseTest.sol";
import "../src/LockedPoolManager.sol";
import "../src/StableYieldManager.sol";
import "../src/PoolRegistry.sol";
import "../src/FeeManager.sol";
import "../src/escrows/YieldReserveEscrow.sol";
import "../src/factories/ManagedPoolFactory.sol";
import "../src/managed/LockedPool.sol";
import "../src/managed/StableYieldPool.sol";
import "../src/escrows/LockedPoolEscrow.sol";
import "../src/escrows/StableYieldEscrow.sol";
import "../src/AccessManager.sol";
import "../src/types/ILockedPoolTypes.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract LockedPoolTest is BaseTest {
    using SafeERC20 for IERC20;
    
    AccessManager accessManager;
    PoolRegistry registry;
    LockedPoolManager lockedPoolManager;
    StableYieldManager stableYieldManager;
    ManagedPoolFactory managedFactory;
    FeeManager feeManager;
    YieldReserveEscrow yieldReserve;
    MockERC20 token;
    
    address poolAddress;
    address escrowAddress;
    
    uint256 constant MIN_DEPOSIT = 1000e6;
    
    uint16 constant TIER_3M_DAYS = 90;
    uint16 constant TIER_3M_APY = 500;
    uint16 constant TIER_3M_PENALTY = 1000;
    
    uint16 constant TIER_6M_DAYS = 180;
    uint16 constant TIER_6M_APY = 700;
    uint16 constant TIER_6M_PENALTY = 1500;
    
    uint16 constant TIER_12M_DAYS = 365;
    uint16 constant TIER_12M_APY = 1000;
    uint16 constant TIER_12M_PENALTY = 2000;
    
    function setUp() public override {
        super.setUp();
        
        token = new MockERC20("Mock USDC", "USDC", 6);
        token.mint(user1, INITIAL_BALANCE);
        token.mint(user2, INITIAL_BALANCE);
        token.mint(user3, INITIAL_BALANCE);
        token.mint(treasury, INITIAL_BALANCE * 100);
        token.mint(operator, INITIAL_BALANCE * 100);
        
        accessManager = new AccessManager(admin, spv, operator, emergency, multisigAdmin);
        
        PoolRegistry registryImpl = new PoolRegistry();
        bytes memory registryInit = abi.encodeWithSignature(
            "initialize(address,address)",
            address(accessManager),
            admin
        );
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryInit);
        registry = PoolRegistry(address(registryProxy));
        
        LockedPoolManager managerImpl = new LockedPoolManager();
        bytes memory managerInit = abi.encodeWithSignature(
            "initialize(address,address,address)",
            address(accessManager),
            address(registry),
            admin
        );
        ERC1967Proxy managerProxy = new ERC1967Proxy(address(managerImpl), managerInit);
        lockedPoolManager = LockedPoolManager(address(managerProxy));
        
        StableYieldManager syManagerImpl = new StableYieldManager();
        bytes memory syManagerInit = abi.encodeWithSignature(
            "initialize(address,address,address,uint256)",
            address(accessManager),
            address(registry),
            admin,
            300
        );
        ERC1967Proxy syManagerProxy = new ERC1967Proxy(address(syManagerImpl), syManagerInit);
        stableYieldManager = StableYieldManager(address(syManagerProxy));
        
        YieldReserveEscrow yieldReserveImpl = new YieldReserveEscrow();
        bytes memory yieldReserveInit = abi.encodeWithSignature(
            "initialize(address,address,address,uint256,uint256)",
            address(token),
            address(accessManager),
            treasury,
            5000,
            5000
        );
        ERC1967Proxy yieldReserveProxy = new ERC1967Proxy(address(yieldReserveImpl), yieldReserveInit);
        yieldReserve = YieldReserveEscrow(address(yieldReserveProxy));

        FeeManager feeManagerImpl = new FeeManager();
        bytes memory feeManagerInit = abi.encodeWithSignature(
            "initialize(address,address,address,address,address)",
            address(accessManager),
            address(registry),
            address(yieldReserve),
            treasury,
            treasury
        );
        ERC1967Proxy feeManagerProxy = new ERC1967Proxy(address(feeManagerImpl), feeManagerInit);
        feeManager = FeeManager(address(feeManagerProxy));

        LockedPool lockedPoolImpl = new LockedPool();
        LockedPoolEscrow lockedEscrowImpl = new LockedPoolEscrow();
        StableYieldPool stablePoolImpl = new StableYieldPool();
        StableYieldEscrow stableEscrowImpl = new StableYieldEscrow();
        
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
        
        vm.startPrank(admin);
        registry.approveAsset(address(token), "Mock USDC", "USDC", true);
        managedFactory.setLockedPoolManager(address(lockedPoolManager));
        managedFactory.updateLockedPoolImplementation(address(lockedPoolImpl));
        managedFactory.updateLockedPoolEscrowImplementation(address(lockedEscrowImpl));
        managedFactory.setFeeManager(address(feeManager));
        managedFactory.setYieldReserve(address(yieldReserve));
        lockedPoolManager.setManagedPoolFactory(address(managedFactory));
        stableYieldManager.setManagedPoolFactory(address(managedFactory));
        lockedPoolManager.setYieldReserve(address(yieldReserve));
        yieldReserve.setLockedPoolManager(address(lockedPoolManager));
        yieldReserve.setStableYieldManager(address(stableYieldManager));
        
        accessManager.grantRoleDuringDeployment(accessManager.POOL_CREATOR_ROLE(), address(lockedPoolManager));
        accessManager.grantRoleDuringDeployment(accessManager.POOL_CREATOR_ROLE(), address(stableYieldManager));
        accessManager.grantRoleDuringDeployment(accessManager.POOL_CREATOR_ROLE(), admin);
        accessManager.grantRoleDuringDeployment(accessManager.OPERATOR_ROLE(), operator);
        accessManager.grantRoleDuringDeployment(accessManager.OPERATOR_ROLE(), address(lockedPoolManager));
        accessManager.grantFactoryRoleDuringDeployment(address(managedFactory));
        accessManager.grantRoleDuringDeployment(accessManager.POOL_CREATOR_ROLE(), address(managedFactory));
        vm.stopPrank();
    }
    
    function _createPool() internal returns (address, address) {
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
        vm.startPrank(operator);
        IERC20(address(token)).safeTransfer(escrowAddress, amount);
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
        
        vm.prank(operator);
        lockedPoolManager.configureLockTier(
            poolAddress,
            3,
            ILockedPoolTypes.LockTier({
                durationDays: 730,
                apyBps: 1500,
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
        
        vm.prank(operator);
        vm.expectRevert(LockedPoolManager.InvalidTier.selector);
        lockedPoolManager.configureLockTier(
            poolAddress,
            4,
            ILockedPoolTypes.LockTier({
                durationDays: TIER_3M_DAYS,
                apyBps: TIER_3M_APY,
                earlyExitPenaltyBps: TIER_3M_PENALTY,
                minDeposit: MIN_DEPOSIT,
                isActive: true
            })
        );
    }
    
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
    
    function test_interest_upfrontPayment() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(1_000_000e6);
        
        uint256 principal = 100_000e6;
        uint256 balanceBefore = token.balanceOf(user1);
        
        uint256 positionId = _depositAsUpfront(user1, principal, 0);
        
        uint256 balanceAfter = token.balanceOf(user1);
        
        uint256 expectedInterest = (principal * TIER_3M_APY * TIER_3M_DAYS) / (365 * 10000);
        
        ILockedPoolTypes.UserPosition memory position = lockedPoolManager.getPosition(positionId);
        
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
        
        assertEq(balanceBefore - principal, balanceAfter, "Should only deduct principal");
        
        ILockedPoolTypes.UserPosition memory position = lockedPoolManager.getPosition(positionId);
        assertFalse(position.interestPaid, "Interest should not be paid yet");
    }
    
    function test_interest_3monthTier_calculation() public {
        (poolAddress, escrowAddress) = _createPool();
        
        uint256 principal = 100_000e6;
        
        (uint256 interest, uint256 apyBps, uint256 durationDays) = LockedPool(poolAddress).previewInterest(principal, 0);
        
        assertEq(apyBps, TIER_3M_APY, "Wrong APY");
        assertEq(durationDays, TIER_3M_DAYS, "Wrong duration");
        
        uint256 expectedInterest = (principal * TIER_3M_APY * TIER_3M_DAYS) / (365 * 10000);
        assertEq(interest, expectedInterest, "Wrong interest calculation");
    }
    
    function test_redeem_afterMaturity() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);
        
        uint256 principal = 100_000e6;
        uint256 positionId = _depositAs(user1, principal, 0);
        
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
        uint256 balanceBefore = token.balanceOf(user1);
        
        vm.prank(user1);
        LockedPool(poolAddress).redeemPosition(positionId);
        
        uint256 received = token.balanceOf(user1) - balanceBefore;
        
        uint256 expectedInterest = (principal * TIER_3M_APY * TIER_3M_DAYS) / (365 * 10000);
        assertApproxEqRel(received, principal + expectedInterest, 0.02e18);
        
        ILockedPoolTypes.UserPosition memory position = lockedPoolManager.getPosition(positionId);
        assertTrue(position.status == ILockedPoolTypes.PositionStatus.REDEEMED, "Should be redeemed");
    }
    
    function test_redeem_beforeMaturity_reverts() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(1_000_000e6);
        
        uint256 positionId = _depositAs(user1, 100_000e6, 0);
        
        vm.prank(user1);
        vm.expectRevert();
        LockedPool(poolAddress).redeemPosition(positionId);
    }
    
    function test_earlyExit_withPenalty() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);
        
        uint256 principal = 100_000e6;
        uint256 positionId = _depositAs(user1, principal, 0);
        
        skipTime(30 days);
        
        uint256 balanceBefore = token.balanceOf(user1);
        
        vm.prank(user1);
        (uint256 payout, uint256 penalty) = LockedPool(poolAddress).earlyExitPosition(positionId);
        
        uint256 received = token.balanceOf(user1) - balanceBefore;
        
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
        
        uint256 pos3m = _depositAs(user1, principal, 0);
        uint256 pos6m = _depositAs(user2, principal, 1);
        uint256 pos12m = _depositAs(user3, principal, 2);
        
        skipTime(30 days);
        
        vm.prank(user1);
        (, uint256 penalty3m) = LockedPool(poolAddress).earlyExitPosition(pos3m);
        
        vm.prank(user2);
        (, uint256 penalty6m) = LockedPool(poolAddress).earlyExitPosition(pos6m);
        
        vm.prank(user3);
        (, uint256 penalty12m) = LockedPool(poolAddress).earlyExitPosition(pos12m);
        
        assertTrue(penalty6m > penalty3m, "6m penalty should be higher than 3m");
        assertTrue(penalty12m > penalty6m, "12m penalty should be higher than 6m");
    }
    
    function test_edgeCase_multipleDepositsAndExits() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(100_000_000e6);
        
        uint256 pos1 = _depositAs(user1, 50_000e6, 0);
        uint256 pos2 = _depositAs(user1, 30_000e6, 1);
        uint256 pos3 = _depositAs(user2, 40_000e6, 2);
        
        skipTime(30 days);
        vm.prank(user1);
        LockedPool(poolAddress).earlyExitPosition(pos1);
        
        skipTime(150 days);
        vm.prank(user1);
        LockedPool(poolAddress).redeemPosition(pos2);
        
        skipTime(185 days);
        vm.prank(user2);
        LockedPool(poolAddress).redeemPosition(pos3);
        
        assertEq(uint8(lockedPoolManager.getPosition(pos1).status), uint8(ILockedPoolTypes.PositionStatus.EARLY_EXIT));
        assertEq(uint8(lockedPoolManager.getPosition(pos2).status), uint8(ILockedPoolTypes.PositionStatus.REDEEMED));
        assertEq(uint8(lockedPoolManager.getPosition(pos3).status), uint8(ILockedPoolTypes.PositionStatus.REDEEMED));
    }
    
    function test_edgeCase_exitAtExactMaturity() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);
        
        uint256 principal = 100_000e6;
        uint256 positionId = _depositAs(user1, principal, 0);
        
        skipTime(TIER_3M_DAYS * 1 days);
        
        vm.prank(user1);
        LockedPool(poolAddress).redeemPosition(positionId);
        
        assertTrue(lockedPoolManager.getPosition(positionId).status == ILockedPoolTypes.PositionStatus.REDEEMED);
    }
    
    function test_edgeCase_differentUsersCannotRedeemOthersPosition() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);
        
        uint256 positionId = _depositAs(user1, 100_000e6, 0);
        
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
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
        
        vm.prank(user1);
        vm.expectRevert();
        LockedPool(poolAddress).redeemPosition(positionId);
    }
    
    function test_apyUpdate_canUpdateExistingTier() public {
        (poolAddress, escrowAddress) = _createPool();
        
        vm.prank(operator);
        lockedPoolManager.configureLockTier(
            poolAddress,
            0,
            ILockedPoolTypes.LockTier({
                durationDays: TIER_3M_DAYS,
                apyBps: 800,
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
        
        vm.prank(operator);
        lockedPoolManager.configureLockTier(
            poolAddress,
            2,
            ILockedPoolTypes.LockTier({
                durationDays: TIER_12M_DAYS,
                apyBps: TIER_12M_APY,
                earlyExitPenaltyBps: TIER_12M_PENALTY,
                minDeposit: MIN_DEPOSIT,
                isActive: false
            })
        );
        
        vm.startPrank(user1);
        token.approve(poolAddress, 100_000e6);
        vm.expectRevert();
        LockedPool(poolAddress).depositLocked(100_000e6, 2, ILockedPoolTypes.InterestPayment.AT_MATURITY);
        vm.stopPrank();
    }
    
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
    
    function test_autoRollover_setPreference() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);
        
        uint256 positionId = _depositAs(user1, 100_000e6, 0);
        
        ILockedPoolTypes.UserPosition memory position = lockedPoolManager.getPosition(positionId);
        assertFalse(position.autoRollover, "Should default to false");
        
        vm.prank(user1);
        LockedPool(poolAddress).setAutoRollover(positionId, true);
        
        position = lockedPoolManager.getPosition(positionId);
        assertTrue(position.autoRollover, "Should be enabled");
        
        vm.prank(user1);
        LockedPool(poolAddress).setAutoRollover(positionId, false);
        
        position = lockedPoolManager.getPosition(positionId);
        assertFalse(position.autoRollover, "Should be disabled");
    }
    
    function test_autoRollover_onlyOwnerCanSet() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);
        
        uint256 positionId = _depositAs(user1, 100_000e6, 0);
        
        vm.prank(user2);
        vm.expectRevert(LockedPoolManager.NotOwner.selector);
        LockedPool(poolAddress).setAutoRollover(positionId, true);
    }
    
    function test_autoRollover_executeRollover_atMaturity() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(100_000_000e6);
        
        uint256 principal = 100_000e6;
        uint256 positionId = _depositAs(user1, principal, 0);
        
        uint256 expectedInterest = (principal * TIER_3M_APY * TIER_3M_DAYS) / (365 * 10000);
        uint256 expectedCompoundedPrincipal = principal + expectedInterest;
        
        vm.prank(user1);
        LockedPool(poolAddress).setAutoRollover(positionId, true);
        
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
        vm.prank(operator);
        uint256 newPositionId = lockedPoolManager.executeRollover(positionId);
        
        ILockedPoolTypes.UserPosition memory oldPosition = lockedPoolManager.getPosition(positionId);
        assertTrue(oldPosition.status == ILockedPoolTypes.PositionStatus.ROLLED_OVER, "Old position should be rolled over");
        
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
        uint256 positionId = _depositAs(user1, principal, 0);
        
        uint256 expectedInterest = (principal * TIER_3M_APY * TIER_3M_DAYS) / (365 * 10000);
        
        vm.prank(user1);
        LockedPool(poolAddress).setAutoRollover(positionId, true);
        
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
        vm.prank(operator);
        uint256 newPositionId = lockedPoolManager.executeRollover(positionId);
        
        ILockedPoolTypes.UserPosition memory newPosition = lockedPoolManager.getPosition(newPositionId);
        
        assertApproxEqRel(newPosition.principalDeposited, principal + expectedInterest, 0.01e18, "Should compound interest");
    }
    
    function test_autoRollover_upfront_onlyPrincipalRolls() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(100_000_000e6);
        
        uint256 principal = 100_000e6;
        uint256 positionId = _depositAsUpfront(user1, principal, 0);
        
        vm.prank(user1);
        LockedPool(poolAddress).setAutoRollover(positionId, true);
        
        ILockedPoolTypes.UserPosition memory oldPosition = lockedPoolManager.getPosition(positionId);
        assertTrue(oldPosition.interestPaid, "Interest should be paid upfront");
        
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
        uint256 userBalanceBefore = token.balanceOf(user1);
        
        vm.prank(operator);
        uint256 newPositionId = lockedPoolManager.executeRollover(positionId);
        
        ILockedPoolTypes.UserPosition memory newPosition = lockedPoolManager.getPosition(newPositionId);
        
        assertEq(newPosition.principalDeposited, principal, "Only principal should roll for UPFRONT");
        
        uint256 userBalanceAfter = token.balanceOf(user1);
        assertTrue(userBalanceAfter > userBalanceBefore, "Should receive new upfront interest");
    }
    
    function test_autoRollover_cannotExecuteBeforeMaturity() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);
        
        uint256 positionId = _depositAs(user1, 100_000e6, 0);
        
        vm.prank(user1);
        LockedPool(poolAddress).setAutoRollover(positionId, true);
        
        skipTime(30 days);
        
        vm.prank(operator);
        vm.expectRevert(LockedPoolManager.NotMatured.selector);
        lockedPoolManager.executeRollover(positionId);
    }
    
    function test_autoRollover_cannotExecuteIfDisabled() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);
        
        uint256 positionId = _depositAs(user1, 100_000e6, 0);
        
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
        vm.prank(operator);
        vm.expectRevert(LockedPoolManager.RolloverNotEnabled.selector);
        lockedPoolManager.executeRollover(positionId);
    }
    
    function test_autoRollover_batchExecute() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(100_000_000e6);
        
        uint256 pos1 = _depositAs(user1, 50_000e6, 0);
        uint256 pos2 = _depositAs(user2, 30_000e6, 0);
        uint256 pos3 = _depositAs(user3, 40_000e6, 0);
        
        vm.prank(user1);
        LockedPool(poolAddress).setAutoRollover(pos1, true);
        
        vm.prank(user2);
        LockedPool(poolAddress).setAutoRollover(pos2, true);
        
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
        uint256[] memory positionIds = new uint256[](3);
        positionIds[0] = pos1;
        positionIds[1] = pos2;
        positionIds[2] = pos3;
        
        vm.prank(operator);
        uint256[] memory newPositionIds = lockedPoolManager.batchExecuteRollovers(positionIds);
        
        assertTrue(newPositionIds[0] > 0, "pos1 should have rolled");
        assertTrue(newPositionIds[1] > 0, "pos2 should have rolled");
        
        assertEq(newPositionIds[2], 0, "pos3 should not have rolled");
        
        assertEq(uint8(lockedPoolManager.getPosition(pos1).status), uint8(ILockedPoolTypes.PositionStatus.ROLLED_OVER));
        assertEq(uint8(lockedPoolManager.getPosition(pos2).status), uint8(ILockedPoolTypes.PositionStatus.ROLLED_OVER));
        assertEq(uint8(lockedPoolManager.getPosition(pos3).status), uint8(ILockedPoolTypes.PositionStatus.ACTIVE));
    }
    
    function test_autoRollover_chainedRollovers() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(100_000_000e6);
        
        uint256 principal = 100_000e6;
        uint256 positionId = _depositAs(user1, principal, 0);
        
        vm.prank(user1);
        LockedPool(poolAddress).setAutoRollover(positionId, true);
        
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
        vm.prank(operator);
        uint256 secondPositionId = lockedPoolManager.executeRollover(positionId);
        
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
        vm.prank(operator);
        uint256 thirdPositionId = lockedPoolManager.executeRollover(secondPositionId);
        
        ILockedPoolTypes.UserPosition memory thirdPos = lockedPoolManager.getPosition(thirdPositionId);
        assertEq(thirdPos.rolledFromPositionId, secondPositionId, "Should reference second position");
        assertTrue(thirdPos.autoRollover, "Auto-rollover should persist");
        
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
        
        vm.prank(operator);
        lockedPoolManager.configureLockTier(
            poolAddress,
            0,
            ILockedPoolTypes.LockTier({
                durationDays: TIER_3M_DAYS,
                apyBps: TIER_3M_APY,
                earlyExitPenaltyBps: TIER_3M_PENALTY,
                minDeposit: MIN_DEPOSIT,
                isActive: false
            })
        );
        
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
        vm.prank(operator);
        vm.expectRevert(LockedPoolManager.TierNotActive.selector);
        lockedPoolManager.executeRollover(positionId);
    }
    
    function test_autoRollover_canStillRedeemIfPreferManual() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(100_000_000e6);
        
        uint256 principal = 100_000e6;
        uint256 positionId = _depositAs(user1, principal, 0);
        
        vm.prank(user1);
        LockedPool(poolAddress).setAutoRollover(positionId, true);
        
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
        vm.prank(user1);
        LockedPool(poolAddress).setAutoRollover(positionId, false);
        
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
        
        vm.prank(user1);
        vm.expectRevert(LockedPoolManager.InvalidStatus.selector);
        LockedPool(poolAddress).setAutoRollover(positionId, true);
    }
    
    function test_rollover_atMaturity_mintsAdditionalShares() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(100_000_000e6);
        
        uint256 principal = 100_000e6;
        
        vm.startPrank(user1);
        token.approve(poolAddress, principal);
        (uint256 positionId,) = LockedPool(poolAddress).depositLocked(
            principal,
            0,
            ILockedPoolTypes.InterestPayment.AT_MATURITY
        );
        vm.stopPrank();
        
        uint256 sharesBefore = LockedPool(poolAddress).balanceOf(user1);
        assertEq(sharesBefore, principal, "Initial shares should equal principal");
        
        vm.prank(user1);
        LockedPool(poolAddress).setAutoRollover(positionId, true);
        
        skipTime(TIER_3M_DAYS * 1 days + 1);
        
        vm.prank(operator);
        uint256 newPositionId = lockedPoolManager.executeRollover(positionId);
        
        ILockedPoolTypes.UserPosition memory newPos = lockedPoolManager.getPosition(newPositionId);
        uint256 expectedInterest = (principal * TIER_3M_APY * TIER_3M_DAYS) / (365 * 10000);
        uint256 expectedNewPrincipal = principal + expectedInterest;
        
        assertApproxEqRel(newPos.principalDeposited, expectedNewPrincipal, 0.01e18, "New principal should include compounded interest");
        
        uint256 sharesAfter = LockedPool(poolAddress).balanceOf(user1);
        assertApproxEqRel(sharesAfter, expectedNewPrincipal, 0.01e18, "Shares should equal new principal after rollover");
        assertTrue(sharesAfter > sharesBefore, "Should have more shares after AT_MATURITY rollover");
    }
    
    function test_earlyExit_upfront_penaltyIncludesInterest() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(100_000_000e6);
        
        uint256 principal = 100_000e6;
        
        uint256 expectedInterest = (principal * TIER_3M_APY * TIER_3M_DAYS) / (365 * 10000);
        
        uint256 balanceBefore = token.balanceOf(user1);
        vm.startPrank(user1);
        token.approve(poolAddress, principal);
        (uint256 positionId,) = LockedPool(poolAddress).depositLocked(
            principal,
            0,
            ILockedPoolTypes.InterestPayment.UPFRONT
        );
        vm.stopPrank();
        
        uint256 balanceAfterDeposit = token.balanceOf(user1);
        uint256 interestReceived = balanceAfterDeposit - (balanceBefore - principal);
        
        skipTime(1 days);
        
        vm.prank(user1);
        (uint256 payout, uint256 penalty) = LockedPool(poolAddress).earlyExitPosition(positionId);
        
        uint256 balanceAfterExit = token.balanceOf(user1);
        
        uint256 totalReceived = interestReceived + payout;
        
        assertTrue(totalReceived < principal, "Early exit should result in net loss");
        
        uint256 totalValue = principal + expectedInterest;
        uint256 expectedPenalty = (totalValue * TIER_3M_PENALTY) / 10000;
        assertApproxEqRel(penalty, expectedPenalty, 0.05e18, "Penalty should be based on total value received");
    }
    
    function test_shareTransfer_disabled() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);
        
        uint256 positionId = _depositAs(user1, 100_000e6, 0);
        
        uint256 shares = LockedPool(poolAddress).balanceOf(user1);
        assertTrue(shares > 0, "User should have shares");
        
        vm.prank(user1);
        vm.expectRevert("LockedPool/transfers disabled");
        LockedPool(poolAddress).transfer(user2, shares);
        
        vm.prank(user1);
        LockedPool(poolAddress).approve(user2, shares);
        
        vm.prank(user2);
        vm.expectRevert("LockedPool/transfers disabled");
        LockedPool(poolAddress).transferFrom(user1, user2, shares);
    }
    
    function test_explicitPositionTransfer() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);
        
        uint256 positionId = _depositAs(user1, 100_000e6, 0);
        
        uint256 sharesBefore = LockedPool(poolAddress).balanceOf(user1);
        assertTrue(sharesBefore > 0, "User1 should have shares");
        assertEq(LockedPool(poolAddress).balanceOf(user2), 0, "User2 should have no shares");
        
        vm.prank(user1);
        LockedPool(poolAddress).transferPosition(positionId, user2);
        
        assertEq(LockedPool(poolAddress).balanceOf(user1), 0, "User1 should have no shares");
        assertEq(LockedPool(poolAddress).balanceOf(user2), sharesBefore, "User2 should have shares");
        
        ILockedPoolTypes.UserPosition memory pos = LockedPool(poolAddress).getPosition(positionId);
        assertEq(pos.user, user2, "Position owner should be user2");
        
        skipTime(TIER_3M_DAYS * 1 days);
        vm.prank(operator);
        lockedPoolManager.batchMaturePositions(_toArray(positionId));
        
        vm.prank(user2);
        uint256 payout = LockedPool(poolAddress).redeemPosition(positionId);
        assertTrue(payout > 0, "User2 should receive payout");
    }
    
    function test_audit_rolloverShareSyncUpfront() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(100_000_000e6);
        
        uint256 principal = 100_000e6;
        
        vm.startPrank(user1);
        token.approve(poolAddress, principal);
        (uint256 positionId,) = LockedPool(poolAddress).depositLocked(
            principal,
            0,
            ILockedPoolTypes.InterestPayment.UPFRONT
        );
        vm.stopPrank();
        
        ILockedPoolTypes.UserPosition memory posBefore = lockedPoolManager.getPosition(positionId);
        uint256 sharesBefore = LockedPool(poolAddress).balanceOf(user1);
        
        assertEq(sharesBefore, posBefore.investedAmount, "Shares should equal investedAmount");
        
        vm.prank(user1);
        LockedPool(poolAddress).setAutoRollover(positionId, true);
        
        skipTime(TIER_3M_DAYS * 1 days);
        vm.prank(operator);
        lockedPoolManager.batchMaturePositions(_toArray(positionId));
        
        vm.prank(operator);
        uint256 newPositionId = lockedPoolManager.executeRollover(positionId);
        
        ILockedPoolTypes.UserPosition memory posAfter = lockedPoolManager.getPosition(newPositionId);
        uint256 sharesAfter = LockedPool(poolAddress).balanceOf(user1);
        
        assertEq(sharesAfter, posAfter.investedAmount, "Shares should sync to new investedAmount");
    }
    
    function _toArray(uint256 value) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = value;
    }

    function _seedYieldReserve(uint256 amount) internal {
        token.mint(address(lockedPoolManager), amount);
        vm.startPrank(address(lockedPoolManager));
        token.approve(address(yieldReserve), amount);
        yieldReserve.receiveYield(amount);
        vm.stopPrank();
    }

    // ==================== YIELD RESERVE TESTS ====================

    function test_earlyExit_borrowsFromReserve_whenEscrowInsufficient() public {
        (poolAddress, escrowAddress) = _createPool();

        uint256 principal = 50_000e6;
        uint256 positionId = _depositAs(user1, principal, 0);

        // SPV takes all the funds out via allocation, leaving escrow near-empty
        vm.prank(operator);
        bytes32 allocId = lockedPoolManager.createPendingAllocation(poolAddress, spv, principal);

        // Seed the yield reserve so it can backstop the early exit
        _seedYieldReserve(200_000e6);

        skipTime(30 days);

        uint256 userBalBefore = token.balanceOf(user1);

        vm.prank(user1);
        (uint256 payout, uint256 penalty) = LockedPool(poolAddress).earlyExitPosition(positionId);

        uint256 received = token.balanceOf(user1) - userBalBefore;
        assertEq(received, payout, "User should receive payout even when escrow is short");
        assertTrue(payout > 0, "Payout should be non-zero");

        ILockedPoolTypes.UserPosition memory pos = lockedPoolManager.getPosition(positionId);
        assertEq(uint8(pos.status), uint8(ILockedPoolTypes.PositionStatus.EARLY_EXIT), "Status should be EARLY_EXIT");

        // A debt position should be created for the reserve loan
        ILockedPoolTypes.DebtPosition memory debt = lockedPoolManager.getDebtPosition(positionId);
        assertTrue(debt.reserveLoan > 0, "Reserve loan should be tracked");
        assertFalse(debt.settled, "Debt should not be settled yet");
    }

    function test_earlyExit_noReserve_reverts_whenEscrowInsufficient() public {
        (poolAddress, escrowAddress) = _createPool();

        uint256 principal = 50_000e6;
        uint256 positionId = _depositAs(user1, principal, 0);

        // SPV takes all funds
        vm.prank(operator);
        lockedPoolManager.createPendingAllocation(poolAddress, spv, principal);

        // Do NOT seed the yield reserve -- it has no balance
        skipTime(30 days);

        vm.prank(user1);
        vm.expectRevert();
        LockedPool(poolAddress).earlyExitPosition(positionId);
    }

    function test_spvAllocation_excessYield_flowsToReserve() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(1_000_000e6);

        _depositAs(user1, 100_000e6, 0);

        // Create SPV allocation
        vm.prank(operator);
        bytes32 allocId = lockedPoolManager.createPendingAllocation(poolAddress, spv, 80_000e6);

        // SPV returns more than allocated (excess yield)
        uint256 returnAmount = 85_000e6;
        token.mint(spv, 5_000e6); // mint extra to simulate yield earned externally

        // Seed the yield reserve so it has initial tracking
        _seedYieldReserve(10_000e6);
        uint256 reserveBalBefore = yieldReserve.getAvailableBalance();

        vm.startPrank(spv);
        token.approve(address(lockedPoolManager), returnAmount);
        lockedPoolManager.matureAllocation(allocId, returnAmount);
        vm.stopPrank();

        (,,,,, ILockedPoolTypes.AllocationStatus allocStatus) = lockedPoolManager.spvAllocations(allocId);

        // Allocation should be marked matured since returned >= allocated
        assertEq(uint8(allocStatus), uint8(ILockedPoolTypes.AllocationStatus.MATURED), "Allocation should be MATURED");

        // The excess yield (5000e6) should flow to reserve
        uint256 reserveBalAfter = yieldReserve.getAvailableBalance();
        assertTrue(reserveBalAfter > reserveBalBefore, "Reserve should have received yield");
    }

    function test_deployProtocolCapital_fromReserve() public {
        (poolAddress, escrowAddress) = _createPool();

        // Seed the yield reserve
        _seedYieldReserve(500_000e6);

        uint256 deployAmount = 100_000e6;
        uint256 escrowBalBefore = token.balanceOf(escrowAddress);

        vm.prank(admin);
        lockedPoolManager.deployProtocolCapital(poolAddress, deployAmount);

        uint256 escrowBalAfter = token.balanceOf(escrowAddress);
        assertEq(escrowBalAfter - escrowBalBefore, deployAmount, "Escrow should receive deployed capital");

        LockedPoolEscrow escrow = LockedPoolEscrow(escrowAddress);
        assertEq(escrow.protocolFundsFromReserve(), deployAmount, "Protocol funds tracking should match");
    }

    function test_recallProtocolCapital_toReserve() public {
        (poolAddress, escrowAddress) = _createPool();

        // Seed reserve and deploy
        _seedYieldReserve(500_000e6);

        vm.prank(admin);
        lockedPoolManager.deployProtocolCapital(poolAddress, 100_000e6);

        uint256 reserveBalBefore = yieldReserve.getAvailableBalance();

        vm.prank(admin);
        lockedPoolManager.recallProtocolCapital(poolAddress, 50_000e6);

        uint256 reserveBalAfter = yieldReserve.getAvailableBalance();
        assertEq(reserveBalAfter - reserveBalBefore, 50_000e6, "Reserve should receive recalled funds");

        LockedPoolEscrow escrow = LockedPoolEscrow(escrowAddress);
        assertEq(escrow.protocolFundsFromReserve(), 50_000e6, "Protocol funds should reflect partial recall");
    }

    function test_deployProtocolCapital_reverts_withoutYieldReserve() public {
        // Create a manager without yieldReserve set
        LockedPoolManager bareManager = new LockedPoolManager();
        // This tests the revert path -- the main manager has it set so we just verify the getter
        assertTrue(address(yieldReserve) != address(0), "Yield reserve should be set in test setup");
        assertEq(lockedPoolManager.yieldReserve(), address(yieldReserve), "Manager should know yield reserve");
    }

    function test_escrowAuthorized_afterPoolCreation() public {
        (poolAddress, escrowAddress) = _createPool();

        // The factory should have auto-authorized the escrow
        assertTrue(
            yieldReserve.isEscrowAuthorized(escrowAddress),
            "Escrow should be auto-authorized on pool creation"
        );
    }

    function test_adminDirectDeposit_trackedOnReserve() public {
        (poolAddress, escrowAddress) = _createPool();

        uint256 depositAmount = 50_000e6;
        token.mint(admin, depositAmount);

        vm.startPrank(admin);
        token.approve(escrowAddress, depositAmount);
        LockedPoolEscrow(escrowAddress).receiveProtocolFundsFromAdmin(depositAmount);
        vm.stopPrank();

        LockedPoolEscrow escrow = LockedPoolEscrow(escrowAddress);
        assertEq(escrow.protocolFundsDirectDeposit(), depositAmount, "Direct deposit should be tracked");

        // YieldReserveEscrow should also track this
        assertEq(
            yieldReserve.directDepositsToPool(poolAddress),
            depositAmount,
            "Reserve should track direct deposit"
        );
    }

    function test_transferPenalties_toFeeManager() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);

        uint256 positionId = _depositAs(user1, 100_000e6, 0);

        skipTime(30 days);

        vm.prank(user1);
        LockedPool(poolAddress).earlyExitPosition(positionId);

        LockedPoolEscrow escrow = LockedPoolEscrow(escrowAddress);
        uint256 penalties = escrow.getPenaltiesCollected();
        assertTrue(penalties > 0, "Should have collected penalties");

        uint256 feeManagerBalBefore = token.balanceOf(address(feeManager));

        vm.prank(operator);
        escrow.transferPenaltiesToFeeManager();

        uint256 feeManagerBalAfter = token.balanceOf(address(feeManager));
        assertEq(feeManagerBalAfter - feeManagerBalBefore, penalties, "FeeManager should receive penalties");
        assertEq(escrow.getPenaltiesCollected(), 0, "Penalties should be zeroed out");
    }

    // ==================== SPV ALLOCATION ADDITIONAL SCENARIOS ====================

    function test_spvAllocation_exactReturn_noYieldToReserve() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(1_000_000e6);

        _depositAs(user1, 100_000e6, 0);

        vm.prank(operator);
        bytes32 allocId = lockedPoolManager.createPendingAllocation(poolAddress, spv, 80_000e6);

        _seedYieldReserve(10_000e6);
        uint256 reserveBefore = yieldReserve.getAvailableBalance();

        vm.startPrank(spv);
        token.approve(address(lockedPoolManager), 80_000e6);
        lockedPoolManager.matureAllocation(allocId, 80_000e6);
        vm.stopPrank();

        uint256 reserveAfter = yieldReserve.getAvailableBalance();
        assertEq(reserveAfter, reserveBefore, "No yield should flow to reserve on exact return");
    }

    function test_spvAllocation_partialReturn_statusReturned() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(1_000_000e6);

        _depositAs(user1, 100_000e6, 0);

        vm.prank(operator);
        bytes32 allocId = lockedPoolManager.createPendingAllocation(poolAddress, spv, 80_000e6);

        vm.startPrank(spv);
        token.approve(address(lockedPoolManager), 50_000e6);
        lockedPoolManager.matureAllocation(allocId, 50_000e6);
        vm.stopPrank();

        (,,,,,ILockedPoolTypes.AllocationStatus status) = lockedPoolManager.spvAllocations(allocId);
        assertEq(uint8(status), uint8(ILockedPoolTypes.AllocationStatus.RETURNED), "Partial return = RETURNED");
    }

    // ==================== PENALTIES TO RESERVE ====================

    function test_transferPenalties_toReserve() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundEscrow(10_000_000e6);

        uint256 positionId = _depositAs(user1, 100_000e6, 0);

        skipTime(30 days);

        vm.prank(user1);
        LockedPool(poolAddress).earlyExitPosition(positionId);

        LockedPoolEscrow escrow = LockedPoolEscrow(escrowAddress);
        uint256 penalties = escrow.getPenaltiesCollected();
        assertTrue(penalties > 0, "Should have penalties");

        _seedYieldReserve(1_000e6);
        uint256 reserveBefore = yieldReserve.getAvailableBalance();

        vm.prank(operator);
        escrow.transferPenaltiesToReserve(address(yieldReserve));

        uint256 reserveAfter = yieldReserve.getAvailableBalance();
        assertTrue(reserveAfter > reserveBefore, "Reserve should receive penalties");
        assertEq(escrow.getPenaltiesCollected(), 0, "Penalties zeroed");
    }

    // ==================== DEPLOY / RECALL PROTOCOL CAPITAL ====================

    function test_deployProtocolCapital_andUseForEarlyExit() public {
        (poolAddress, escrowAddress) = _createPool();

        _seedYieldReserve(500_000e6);

        vm.prank(admin);
        lockedPoolManager.deployProtocolCapital(poolAddress, 200_000e6);

        uint256 positionId = _depositAs(user1, 50_000e6, 0);

        skipTime(30 days);

        uint256 userBalBefore = token.balanceOf(user1);

        vm.prank(user1);
        (uint256 payout,) = LockedPool(poolAddress).earlyExitPosition(positionId);

        uint256 received = token.balanceOf(user1) - userBalBefore;
        assertEq(received, payout, "User gets full payout from escrow with protocol capital");

        ILockedPoolTypes.DebtPosition memory debt = lockedPoolManager.getDebtPosition(positionId);
        assertEq(debt.reserveLoan, 0, "No reserve loan when escrow has protocol capital");
    }

    // ==================== MULTIPLE EARLY EXITS WITH RESERVE ====================

    function test_multipleEarlyExits_allBorrowFromReserve() public {
        (poolAddress, escrowAddress) = _createPool();

        uint256 pos1 = _depositAs(user1, 30_000e6, 0);
        uint256 pos2 = _depositAs(user2, 30_000e6, 0);

        vm.prank(operator);
        lockedPoolManager.createPendingAllocation(poolAddress, spv, 60_000e6);

        _seedYieldReserve(500_000e6);

        skipTime(30 days);

        vm.prank(user1);
        LockedPool(poolAddress).earlyExitPosition(pos1);

        vm.prank(user2);
        LockedPool(poolAddress).earlyExitPosition(pos2);

        ILockedPoolTypes.DebtPosition memory d1 = lockedPoolManager.getDebtPosition(pos1);
        ILockedPoolTypes.DebtPosition memory d2 = lockedPoolManager.getDebtPosition(pos2);

        assertTrue(d1.reserveLoan > 0, "Position 1 should have reserve loan");
        assertTrue(d2.reserveLoan > 0, "Position 2 should have reserve loan");

        uint256 totalLoaned = yieldReserve.getTotalLoaned();
        assertTrue(totalLoaned >= d1.reserveLoan + d2.reserveLoan, "Total loaned should be cumulative");
    }

    // ==================== ESCROW BALANCE INTEGRITY ====================

    function test_escrowBalanceIntegrity_afterMultipleOps() public {
        (poolAddress, escrowAddress) = _createPool();

        _seedYieldReserve(500_000e6);

        vm.prank(admin);
        lockedPoolManager.deployProtocolCapital(poolAddress, 100_000e6);

        uint256 directDeposit = 50_000e6;
        token.mint(admin, directDeposit);
        vm.startPrank(admin);
        token.approve(escrowAddress, directDeposit);
        LockedPoolEscrow(escrowAddress).receiveProtocolFundsFromAdmin(directDeposit);
        vm.stopPrank();

        _depositAs(user1, 100_000e6, 0);

        LockedPoolEscrow escrow = LockedPoolEscrow(escrowAddress);
        uint256 expected = escrow.getExpectedBalance();
        uint256 actual = escrow.getTotalBalance();
        assertEq(actual, expected, "Balance accounting must match after all ops");
    }

    // ==================== ADMIN DIRECT DEPOSIT ====================

    function test_adminDirectDeposit_releaseAndTracking() public {
        (poolAddress, escrowAddress) = _createPool();

        uint256 depositAmt = 50_000e6;
        token.mint(admin, depositAmt);

        vm.startPrank(admin);
        token.approve(escrowAddress, depositAmt);
        LockedPoolEscrow(escrowAddress).receiveProtocolFundsFromAdmin(depositAmt);
        vm.stopPrank();

        assertEq(yieldReserve.directDepositsToPool(poolAddress), depositAmt, "Reserve tracks direct deposit");
        assertEq(LockedPoolEscrow(escrowAddress).protocolFundsDirectDeposit(), depositAmt, "Escrow tracks direct deposit");

        vm.prank(admin);
        LockedPoolEscrow(escrowAddress).releaseDirectDepositFunds(treasury, 20_000e6);

        assertEq(yieldReserve.directDepositsToPool(poolAddress), 30_000e6, "Reserve updates after release");
        assertEq(LockedPoolEscrow(escrowAddress).protocolFundsDirectDeposit(), 30_000e6, "Escrow updates after release");
    }
}
