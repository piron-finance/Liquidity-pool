// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../../src/AccessManager.sol";
import "../../src/PoolRegistry.sol";
import "../../src/LockedPoolManager.sol";
import "../../src/managed/LockedPool.sol";
import "../../src/escrows/LockedPoolEscrow.sol";
import "../../src/escrows/YieldReserveEscrow.sol";
import "../../src/types/ILockedPoolTypes.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract LockedPoolComprehensiveTest is Test {
    AccessManager public accessManager;
    PoolRegistry public registry;
    LockedPoolManager public manager;
    LockedPool public pool;
    LockedPoolEscrow public escrow;
    YieldReserveEscrow public yieldReserve;
    MockUSDC public usdc;

    address public admin = address(0x1);
    address public operator = address(0x2);
    address public treasury = address(0x3);
    address public spv = address(0x4);
    address public user1 = address(0x100);
    address public user2 = address(0x200);
    address public user3 = address(0x300);

    uint256 constant DEPOSIT_AMOUNT = 100_000e6;

    function setUp() public {
        vm.startPrank(admin);

        usdc = new MockUSDC();

        accessManager = new AccessManager(admin, spv, operator, admin, admin);
        AccessManager registryAccessManager = new AccessManager(admin, spv, operator, admin, admin);

        PoolRegistry registryImpl = new PoolRegistry();
        bytes memory registryData = abi.encodeWithSelector(
            PoolRegistry.initialize.selector,
            address(registryAccessManager),
            admin
        );
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryData);
        registry = PoolRegistry(address(registryProxy));

        registryAccessManager.grantRoleDuringDeployment(registryAccessManager.POOL_CREATOR_ROLE(), admin);
        registryAccessManager.finalizeDeployment();
        registry.approveAsset(address(usdc), "USDC", "USDC", "US", "NA", true);

        LockedPoolManager managerImpl = new LockedPoolManager();
        bytes memory managerData = abi.encodeWithSelector(
            LockedPoolManager.initialize.selector,
            address(accessManager),
            address(registry),
            admin
        );
        ERC1967Proxy managerProxy = new ERC1967Proxy(address(managerImpl), managerData);
        manager = LockedPoolManager(address(managerProxy));

        YieldReserveEscrow reserveImpl = new YieldReserveEscrow();
        bytes memory reserveData = abi.encodeWithSelector(
            YieldReserveEscrow.initialize.selector,
            address(usdc),
            address(accessManager),
            treasury,
            6000,
            100_000e6
        );
        ERC1967Proxy reserveProxy = new ERC1967Proxy(address(reserveImpl), reserveData);
        yieldReserve = YieldReserveEscrow(address(reserveProxy));
        yieldReserve.setLockedPoolManager(address(manager));

        LockedPoolEscrow escrowImpl = new LockedPoolEscrow();
        bytes memory escrowData = abi.encodeWithSelector(
            LockedPoolEscrow.initialize.selector,
            address(usdc),
            address(accessManager),
            "Test Locked Pool Escrow"
        );
        ERC1967Proxy escrowProxy = new ERC1967Proxy(address(escrowImpl), escrowData);
        escrow = LockedPoolEscrow(address(escrowProxy));

        LockedPool poolImpl = new LockedPool();
        bytes memory poolData = abi.encodeWithSelector(
            LockedPool.initialize.selector,
            address(usdc),
            "Locked Treasury Pool",
            "LTP",
            address(escrow),
            address(manager),
            address(accessManager)
        );
        ERC1967Proxy poolProxy = new ERC1967Proxy(address(poolImpl), poolData);
        pool = LockedPool(address(poolProxy));

        accessManager.grantRoleDuringDeployment(accessManager.FACTORY_ROLE(), admin);
        accessManager.grantRoleDuringDeployment(accessManager.OPERATOR_ROLE(), admin);
        accessManager.grantRoleDuringDeployment(accessManager.OPERATOR_ROLE(), address(manager));
        accessManager.finalizeDeployment();
        
        escrow.setLockedPool(address(pool));
        escrow.setLockedPoolManager(address(manager));

        manager.setManagedPoolFactory(admin);
        manager.registerPool(
            address(pool),
            address(escrow),
            address(usdc),
            "Test Locked Pool",
            1000e6
        );

        manager.setYieldReserve(address(yieldReserve));

        _configureTiers();
        _fundUsers();

        vm.stopPrank();

        _approveUsers();
    }

    function _configureTiers() internal {
        manager.configureLockTier(
            address(pool),
            0,
            ILockedPoolTypes.LockTier({
                durationDays: 90,
                apyBps: 800,
                earlyExitPenaltyBps: 500,
                minDeposit: 1000e6,
                isActive: true
            })
        );

        manager.configureLockTier(
            address(pool),
            1,
            ILockedPoolTypes.LockTier({
                durationDays: 180,
                apyBps: 1000,
                earlyExitPenaltyBps: 300,
                minDeposit: 5000e6,
                isActive: true
            })
        );

        manager.configureLockTier(
            address(pool),
            2,
            ILockedPoolTypes.LockTier({
                durationDays: 365,
                apyBps: 1200,
                earlyExitPenaltyBps: 200,
                minDeposit: 10000e6,
                isActive: true
            })
        );
    }

    function _fundUsers() internal {
        usdc.mint(user1, 1_000_000e6);
        usdc.mint(user2, 1_000_000e6);
        usdc.mint(user3, 1_000_000e6);
        usdc.mint(spv, 10_000_000e6);
    }

    function _approveUsers() internal {
        vm.prank(user1);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(user2);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(user3);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(spv);
        usdc.approve(address(manager), type(uint256).max);
    }

    function test_deposit_upfrontInterest() public {
        console.log("\n=== TEST: Deposit with Upfront Interest (3 month) ===");

        vm.startPrank(user1);

        uint256 balanceBefore = usdc.balanceOf(user1);

        (uint256 positionId, uint256 shares) = pool.depositLocked(
            DEPOSIT_AMOUNT,
            0,
            ILockedPoolTypes.InterestPayment.UPFRONT
        );

        uint256 balanceAfter = usdc.balanceOf(user1);
        uint256 interestReceived = balanceAfter - (balanceBefore - DEPOSIT_AMOUNT);

        ILockedPoolTypes.UserPosition memory position = manager.getPosition(positionId);

        assertEq(position.principalDeposited, DEPOSIT_AMOUNT);
        assertTrue(position.interestPaid);
        assertEq(position.fullInterestAmount, interestReceived);

        uint256 expectedInterest = (DEPOSIT_AMOUNT * 800 * 90) / (10000 * 365);
        assertApproxEqAbs(interestReceived, expectedInterest, 1e6);

        uint256 expectedInvested = DEPOSIT_AMOUNT - interestReceived;
        assertEq(shares, expectedInvested);
        assertEq(position.investedAmount, expectedInvested);
        assertEq(position.expectedMaturityPayout, DEPOSIT_AMOUNT);

        console.log("Interest received upfront:", interestReceived / 1e6, "USDC");
        console.log("Invested amount:", position.investedAmount / 1e6, "USDC");

        vm.stopPrank();
    }

    function test_deposit_maturityInterest() public {
        console.log("\n=== TEST: Deposit with Maturity Interest (6 month) ===");

        vm.startPrank(user1);

        uint256 balanceBefore = usdc.balanceOf(user1);

        (uint256 positionId, uint256 shares) = pool.depositLocked(
            DEPOSIT_AMOUNT,
            1,
            ILockedPoolTypes.InterestPayment.AT_MATURITY
        );

        uint256 balanceAfter = usdc.balanceOf(user1);
        assertEq(balanceBefore - balanceAfter, DEPOSIT_AMOUNT);

        ILockedPoolTypes.UserPosition memory position = manager.getPosition(positionId);

        assertEq(position.principalDeposited, DEPOSIT_AMOUNT);
        assertFalse(position.interestPaid);
        assertEq(position.investedAmount, DEPOSIT_AMOUNT);
        assertEq(shares, DEPOSIT_AMOUNT);

        uint256 expectedInterest = (DEPOSIT_AMOUNT * 1000 * 180) / (10000 * 365);
        assertEq(position.fullInterestAmount, expectedInterest);
        assertEq(position.expectedMaturityPayout, DEPOSIT_AMOUNT + expectedInterest);

        console.log("Interest (at maturity):", position.fullInterestAmount / 1e6, "USDC");
        console.log("Expected maturity payout:", position.expectedMaturityPayout / 1e6, "USDC");

        vm.stopPrank();
    }

    function test_redeem_upfrontInterest_noSPV() public {
        console.log("\n=== TEST: Redeem at Maturity (Upfront - Simulated SPV Return) ===");

        vm.prank(user1);
        (uint256 positionId,) = pool.depositLocked(
            DEPOSIT_AMOUNT,
            0,
            ILockedPoolTypes.InterestPayment.UPFRONT
        );

        ILockedPoolTypes.UserPosition memory pos = manager.getPosition(positionId);
        uint256 expectedPayout = pos.expectedMaturityPayout;
        uint256 interestPaid = pos.fullInterestAmount;

        assertEq(expectedPayout, DEPOSIT_AMOUNT);

        vm.prank(admin);
        usdc.mint(address(escrow), interestPaid);
        vm.prank(address(manager));
        escrow.recordReceivedFunds(interestPaid);

        vm.warp(block.timestamp + 91 days);

        uint256 balanceBefore = usdc.balanceOf(user1);

        vm.prank(user1);
        uint256 payout = pool.redeemPosition(positionId);

        uint256 balanceAfter = usdc.balanceOf(user1);

        assertEq(payout, expectedPayout);
        assertEq(balanceAfter - balanceBefore, expectedPayout);

        ILockedPoolTypes.UserPosition memory posAfter = manager.getPosition(positionId);
        assertEq(uint8(posAfter.status), uint8(ILockedPoolTypes.PositionStatus.REDEEMED));

        console.log("Payout:", payout / 1e6, "USDC");
        console.log("SPV return simulated - interest gap funded");
    }

    function test_earlyExit_upfrontInterest() public {
        console.log("\n=== TEST: Early Exit (Upfront Interest Position) ===");

        vm.prank(user1);
        (uint256 positionId,) = pool.depositLocked(
            DEPOSIT_AMOUNT,
            0,
            ILockedPoolTypes.InterestPayment.UPFRONT
        );

        ILockedPoolTypes.UserPosition memory posBefore = manager.getPosition(positionId);

        vm.warp(block.timestamp + 30 days);

        uint256 balanceBefore = usdc.balanceOf(user1);

        vm.prank(user1);
        (uint256 payout, uint256 penalty) = pool.earlyExitPosition(positionId);

        uint256 balanceAfter = usdc.balanceOf(user1);

        uint256 expectedPenalty = (posBefore.investedAmount * 500) / 10000;
        uint256 expectedPayout = posBefore.investedAmount - expectedPenalty;

        assertApproxEqAbs(penalty, expectedPenalty, 1e6);
        assertApproxEqAbs(payout, expectedPayout, 1e6);
        assertApproxEqAbs(balanceAfter - balanceBefore, expectedPayout, 1e6);

        ILockedPoolTypes.UserPosition memory posAfter = manager.getPosition(positionId);
        assertEq(uint8(posAfter.status), uint8(ILockedPoolTypes.PositionStatus.EARLY_EXIT));

        console.log("Penalty (5%):", penalty / 1e6, "USDC");
        console.log("Payout:", payout / 1e6, "USDC");
    }

    function test_earlyExit_maturityInterest_proRata() public {
        console.log("\n=== TEST: Early Exit (Maturity Interest - Pro-rata) ===");

        vm.prank(user1);
        (uint256 positionId,) = pool.depositLocked(
            DEPOSIT_AMOUNT,
            1,
            ILockedPoolTypes.InterestPayment.AT_MATURITY
        );

        ILockedPoolTypes.UserPosition memory posBefore = manager.getPosition(positionId);

        vm.warp(block.timestamp + 90 days);

        vm.prank(user1);
        (uint256 payout, uint256 penalty) = pool.earlyExitPosition(positionId);

        uint256 proRataInterest = (posBefore.fullInterestAmount * 90 days) / (180 days);
        uint256 valueAtExit = posBefore.principalDeposited + proRataInterest;
        uint256 expectedPenalty = (valueAtExit * 300) / 10000;
        uint256 expectedPayout = valueAtExit - expectedPenalty;

        assertApproxEqAbs(payout, expectedPayout, 1e6);
        assertApproxEqAbs(penalty, expectedPenalty, 1e6);

        ILockedPoolTypes.UserPosition memory posAfter = manager.getPosition(positionId);
        assertApproxEqAbs(posAfter.interestEarned, proRataInterest, 1e6);

        console.log("Pro-rata interest earned:", proRataInterest / 1e6, "USDC");
        console.log("Penalty (3%):", penalty / 1e6, "USDC");
        console.log("Final payout:", payout / 1e6, "USDC");
    }

    function test_penaltyTracking() public {
        console.log("\n=== TEST: Penalty Tracking ===");

        vm.prank(user1);
        (uint256 positionId,) = pool.depositLocked(
            DEPOSIT_AMOUNT,
            0,
            ILockedPoolTypes.InterestPayment.UPFRONT
        );

        vm.warp(block.timestamp + 30 days);

        uint256 penaltiesBefore = escrow.getPenaltiesCollected();

        vm.prank(user1);
        (, uint256 penalty) = pool.earlyExitPosition(positionId);

        uint256 penaltiesAfter = escrow.getPenaltiesCollected();

        assertEq(penaltiesAfter - penaltiesBefore, penalty);

        ILockedPoolTypes.PoolProtocolAccounting memory accounting = manager.getPoolAccounting(address(pool));
        assertEq(accounting.totalPenaltiesEarned, penalty);

        console.log("Penalty collected:", penalty / 1e6, "USDC");
    }

    function test_multipleUsers_differentTiers() public {
        console.log("\n=== TEST: Multiple Users Different Tiers ===");

        vm.prank(user1);
        (uint256 pos1,) = pool.depositLocked(50_000e6, 0, ILockedPoolTypes.InterestPayment.UPFRONT);

        vm.prank(user2);
        (uint256 pos2,) = pool.depositLocked(100_000e6, 1, ILockedPoolTypes.InterestPayment.UPFRONT);

        vm.prank(user3);
        (uint256 pos3,) = pool.depositLocked(200_000e6, 2, ILockedPoolTypes.InterestPayment.UPFRONT);

        ILockedPoolTypes.PoolMetrics memory metrics = manager.getPoolMetrics(address(pool));

        assertEq(metrics.activePositions, 3);
        assertEq(metrics.totalPrincipalLocked, 350_000e6);

        console.log("Active positions:", metrics.activePositions);
        console.log("Total principal locked:", metrics.totalPrincipalLocked / 1e6, "USDC");

        uint256 totalInterestPaid = metrics.totalInterestPaidUpfront;
        vm.prank(admin);
        usdc.mint(address(escrow), totalInterestPaid);
        vm.prank(address(manager));
        escrow.recordReceivedFunds(totalInterestPaid);

        vm.warp(block.timestamp + 366 days);

        vm.prank(user1);
        pool.redeemPosition(pos1);

        vm.prank(user2);
        pool.redeemPosition(pos2);

        vm.prank(user3);
        pool.redeemPosition(pos3);

        ILockedPoolTypes.PoolMetrics memory metricsAfter = manager.getPoolMetrics(address(pool));
        assertEq(metricsAfter.activePositions, 0);

        console.log("All positions redeemed successfully");
    }

    function test_spvAllocation() public {
        console.log("\n=== TEST: SPV Allocation ===");

        vm.prank(user1);
        (uint256 positionId,) = pool.depositLocked(
            DEPOSIT_AMOUNT,
            0,
            ILockedPoolTypes.InterestPayment.UPFRONT
        );

        ILockedPoolTypes.UserPosition memory pos = manager.getPosition(positionId);
        uint256 escrowBefore = escrow.getPrincipalHeld();

        console.log("Escrow before allocation:", escrowBefore / 1e6, "USDC");

        vm.prank(admin);
        bytes32 allocationId = manager.createPendingAllocation(address(pool), spv, pos.investedAmount);

        uint256 escrowAfter = escrow.getPrincipalHeld();
        uint256 spvAllocation = manager.totalSPVAllocations(spv);

        assertEq(escrowAfter, 0);
        assertEq(spvAllocation, pos.investedAmount);

        console.log("Escrow after allocation:", escrowAfter / 1e6, "USDC");
        console.log("SPV allocation:", spvAllocation / 1e6, "USDC");
        console.log("Allocation ID:", uint256(allocationId));
    }

    function test_cannotRedeemBeforeMaturity() public {
        vm.prank(user1);
        (uint256 positionId,) = pool.depositLocked(DEPOSIT_AMOUNT, 0, ILockedPoolTypes.InterestPayment.AT_MATURITY);

        vm.warp(block.timestamp + 30 days);

        vm.prank(user1);
        vm.expectRevert("LockedPoolManager/not matured");
        pool.redeemPosition(positionId);
    }

    function test_cannotEarlyExitAfterMaturity() public {
        vm.prank(user1);
        (uint256 positionId,) = pool.depositLocked(DEPOSIT_AMOUNT, 0, ILockedPoolTypes.InterestPayment.AT_MATURITY);

        vm.warp(block.timestamp + 91 days);

        vm.prank(user1);
        vm.expectRevert("LockedPoolManager/already matured");
        pool.earlyExitPosition(positionId);
    }

    function test_cannotRedeemTwice() public {
        vm.prank(user1);
        (uint256 positionId,) = pool.depositLocked(DEPOSIT_AMOUNT, 0, ILockedPoolTypes.InterestPayment.UPFRONT);

        ILockedPoolTypes.UserPosition memory pos = manager.getPosition(positionId);
        vm.prank(admin);
        usdc.mint(address(escrow), pos.fullInterestAmount);
        vm.prank(address(manager));
        escrow.recordReceivedFunds(pos.fullInterestAmount);

        vm.warp(block.timestamp + 91 days);

        vm.prank(user1);
        pool.redeemPosition(positionId);

        vm.prank(user1);
        vm.expectRevert("LockedPool/insufficient shares");
        pool.redeemPosition(positionId);
    }

    function test_onlyOwnerCanRedeem() public {
        vm.prank(user1);
        (uint256 positionId,) = pool.depositLocked(DEPOSIT_AMOUNT, 0, ILockedPoolTypes.InterestPayment.AT_MATURITY);

        vm.warp(block.timestamp + 91 days);

        vm.prank(user2);
        vm.expectRevert("LockedPool/not owner");
        pool.redeemPosition(positionId);
    }

    function test_onlyOwnerCanEarlyExit() public {
        vm.prank(user1);
        (uint256 positionId,) = pool.depositLocked(DEPOSIT_AMOUNT, 0, ILockedPoolTypes.InterestPayment.AT_MATURITY);

        vm.warp(block.timestamp + 30 days);

        vm.prank(user2);
        vm.expectRevert("LockedPool/not owner");
        pool.earlyExitPosition(positionId);
    }

    function test_shareTransfer_warning() public {
        console.log("\n=== TEST: Share Transfer Warning ===");

        vm.prank(user1);
        (uint256 positionId, uint256 shares) = pool.depositLocked(
            DEPOSIT_AMOUNT,
            0,
            ILockedPoolTypes.InterestPayment.UPFRONT
        );

        vm.prank(user1);
        pool.transfer(user2, shares);

        assertEq(pool.balanceOf(user1), 0);
        assertEq(pool.balanceOf(user2), shares);

        vm.warp(block.timestamp + 91 days);

        vm.prank(user1);
        vm.expectRevert("LockedPool/insufficient shares");
        pool.redeemPosition(positionId);

        vm.prank(user2);
        vm.expectRevert("LockedPool/not owner");
        pool.redeemPosition(positionId);

        console.log("User2 has orphaned shares - position ownership not transferred");
    }

    function test_poolMetrics() public {
        console.log("\n=== TEST: Pool Metrics ===");

        vm.prank(user1);
        pool.depositLocked(50_000e6, 0, ILockedPoolTypes.InterestPayment.UPFRONT);

        vm.prank(user2);
        pool.depositLocked(100_000e6, 1, ILockedPoolTypes.InterestPayment.AT_MATURITY);

        ILockedPoolTypes.PoolMetrics memory metrics = manager.getPoolMetrics(address(pool));

        assertEq(metrics.activePositions, 2);
        assertEq(metrics.totalPositions, 2);
        assertEq(metrics.totalPrincipalLocked, 150_000e6);
        assertTrue(metrics.totalInterestCommitted > 0);

        console.log("Active positions:", metrics.activePositions);
        console.log("Total principal:", metrics.totalPrincipalLocked / 1e6, "USDC");
        console.log("Total interest committed:", metrics.totalInterestCommitted / 1e6, "USDC");
        console.log("Interest paid upfront:", metrics.totalInterestPaidUpfront / 1e6, "USDC");
        console.log("Interest pending maturity:", metrics.totalInterestPendingMaturity / 1e6, "USDC");
    }

    function test_tierConfiguration() public {
        console.log("\n=== TEST: Tier Configuration ===");

        ILockedPoolTypes.LockTier[] memory tiers = manager.getPoolTiers(address(pool));

        assertEq(tiers.length, 3);
        
        assertEq(tiers[0].durationDays, 90);
        assertEq(tiers[0].apyBps, 800);
        assertEq(tiers[0].earlyExitPenaltyBps, 500);
        assertTrue(tiers[0].isActive);

        assertEq(tiers[1].durationDays, 180);
        assertEq(tiers[1].apyBps, 1000);
        
        assertEq(tiers[2].durationDays, 365);
        assertEq(tiers[2].apyBps, 1200);

        console.log("3 tiers configured correctly");
    }

    function test_depositBelowMinimum_reverts() public {
        vm.prank(user1);
        vm.expectRevert("LockedPoolManager/below minimum");
        pool.depositLocked(500e6, 0, ILockedPoolTypes.InterestPayment.UPFRONT);
    }

    function test_depositInactiveTier_reverts() public {
        vm.prank(admin);
        manager.setTierActive(address(pool), 0, false);

        vm.prank(user1);
        vm.expectRevert("LockedPoolManager/tier not active");
        pool.depositLocked(DEPOSIT_AMOUNT, 0, ILockedPoolTypes.InterestPayment.UPFRONT);
    }

    function test_positionDetails() public {
        console.log("\n=== TEST: Position Details ===");

        vm.prank(user1);
        (uint256 positionId,) = pool.depositLocked(
            DEPOSIT_AMOUNT,
            1,
            ILockedPoolTypes.InterestPayment.AT_MATURITY
        );

        ILockedPoolTypes.UserPosition memory pos = manager.getPosition(positionId);

        assertEq(pos.positionId, positionId);
        assertEq(pos.user, user1);
        assertEq(pos.poolAddress, address(pool));
        assertEq(pos.principalDeposited, DEPOSIT_AMOUNT);
        assertEq(pos.tierIndex, 1);
        assertEq(uint8(pos.status), uint8(ILockedPoolTypes.PositionStatus.ACTIVE));
        assertEq(pos.apyBpsAtDeposit, 1000);

        console.log("Position ID:", pos.positionId);
        console.log("Principal:", pos.principalDeposited / 1e6, "USDC");
        console.log("APY at deposit:", pos.apyBpsAtDeposit, "bps");
        console.log("Lock end:", pos.lockEnd);
    }

    function test_getUserPositions() public {
        vm.startPrank(user1);
        
        (uint256 pos1,) = pool.depositLocked(50_000e6, 0, ILockedPoolTypes.InterestPayment.UPFRONT);
        (uint256 pos2,) = pool.depositLocked(100_000e6, 1, ILockedPoolTypes.InterestPayment.AT_MATURITY);
        
        vm.stopPrank();

        uint256[] memory positions = manager.getUserPositions(address(pool), user1);

        assertEq(positions.length, 2);
        assertEq(positions[0], pos1);
        assertEq(positions[1], pos2);
    }

    function test_VULN_redemptionFailsWithoutSPVReturn() public {
        console.log("\n=== VULNERABILITY TEST: Redemption without SPV funds ===");

        vm.prank(user1);
        (uint256 positionId,) = pool.depositLocked(
            DEPOSIT_AMOUNT,
            0,
            ILockedPoolTypes.InterestPayment.UPFRONT
        );

        vm.warp(block.timestamp + 91 days);

        vm.prank(user1);
        vm.expectRevert("LockedPoolEscrow/insufficient balance");
        pool.redeemPosition(positionId);

        console.log("VERIFIED: Cannot redeem without SPV return");
    }

    function test_VULN_cannotAllocateMoreThanEscrowHas() public {
        console.log("\n=== VULNERABILITY TEST: Over-allocation ===");

        vm.prank(user1);
        pool.depositLocked(DEPOSIT_AMOUNT, 0, ILockedPoolTypes.InterestPayment.UPFRONT);

        uint256 escrowBalance = escrow.getPrincipalHeld();

        vm.prank(admin);
        vm.expectRevert("LockedPoolManager/insufficient funds");
        manager.createPendingAllocation(address(pool), spv, escrowBalance + 1);

        console.log("VERIFIED: Cannot allocate more than escrow holds");
    }

    function test_VULN_penaltyCannotExceed100Percent() public {
        console.log("\n=== VULNERABILITY TEST: Penalty bounds ===");

        vm.prank(admin);
        vm.expectRevert("LockedPoolManager/invalid penalty");
        manager.configureLockTier(
            address(pool),
            3,
            ILockedPoolTypes.LockTier({
                durationDays: 30,
                apyBps: 500,
                earlyExitPenaltyBps: 10001,
                minDeposit: 1000e6,
                isActive: true
            })
        );

        console.log("VERIFIED: Penalty cannot exceed 100%");
    }

    function test_VULN_apyCannotBeUnreasonable() public {
        console.log("\n=== VULNERABILITY TEST: APY bounds ===");

        vm.prank(admin);
        vm.expectRevert("LockedPoolManager/invalid apy");
        manager.configureLockTier(
            address(pool),
            3,
            ILockedPoolTypes.LockTier({
                durationDays: 30,
                apyBps: 5001,
                earlyExitPenaltyBps: 100,
                minDeposit: 1000e6,
                isActive: true
            })
        );

        console.log("VERIFIED: APY has upper bound (50%)");
    }

    function test_VULN_smallDepositPrecision() public {
        console.log("\n=== VULNERABILITY TEST: Small deposit precision ===");

        vm.prank(user1);
        (uint256 positionId, uint256 shares) = pool.depositLocked(
            1001e6,
            0,
            ILockedPoolTypes.InterestPayment.UPFRONT
        );

        ILockedPoolTypes.UserPosition memory pos = manager.getPosition(positionId);

        assertTrue(pos.fullInterestAmount > 0, "Interest should be non-zero even for small deposits");
        assertTrue(shares > 0, "Shares should be non-zero");

        console.log("Interest on 1001 USDC:", pos.fullInterestAmount);
        console.log("Shares:", shares);
        console.log("VERIFIED: Small deposits still earn interest");
    }

    function test_VULN_earlyExitDayZero() public {
        console.log("\n=== VULNERABILITY TEST: Early exit at day 0 ===");

        vm.prank(user1);
        (uint256 positionId,) = pool.depositLocked(
            DEPOSIT_AMOUNT,
            1,
            ILockedPoolTypes.InterestPayment.AT_MATURITY
        );

        vm.prank(user1);
        (uint256 payout, uint256 penalty) = pool.earlyExitPosition(positionId);

        assertTrue(penalty > 0, "Should have penalty at day 0");

        ILockedPoolTypes.UserPosition memory pos = manager.getPosition(positionId);
        assertEq(pos.interestEarned, 0, "Should earn 0 interest at day 0");

        console.log("Payout at day 0:", payout / 1e6, "USDC");
        console.log("Penalty at day 0:", penalty / 1e6, "USDC");
        console.log("VERIFIED: Day 0 exit has penalty and no interest");
    }

    function test_VULN_unauthorizedTierChange() public {
        console.log("\n=== VULNERABILITY TEST: Unauthorized tier modification ===");

        vm.prank(user1);
        vm.expectRevert();
        manager.configureLockTier(
            address(pool),
            0,
            ILockedPoolTypes.LockTier({
                durationDays: 1,
                apyBps: 5000,
                earlyExitPenaltyBps: 0,
                minDeposit: 0,
                isActive: true
            })
        );

        console.log("VERIFIED: Non-operator cannot modify tiers");
    }

    function test_VULN_unauthorizedAllocation() public {
        console.log("\n=== VULNERABILITY TEST: Unauthorized SPV allocation ===");

        vm.prank(user1);
        pool.depositLocked(DEPOSIT_AMOUNT, 0, ILockedPoolTypes.InterestPayment.UPFRONT);

        vm.prank(user1);
        vm.expectRevert();
        manager.createPendingAllocation(address(pool), user1, 50_000e6);

        console.log("VERIFIED: Non-operator cannot create allocations");
    }

    function test_VULN_positionNotTransferableViaShares() public {
        console.log("\n=== VULNERABILITY TEST: Position ownership via share transfer ===");

        vm.prank(user1);
        (uint256 positionId, uint256 shares) = pool.depositLocked(
            DEPOSIT_AMOUNT,
            0,
            ILockedPoolTypes.InterestPayment.UPFRONT
        );

        vm.prank(user1);
        pool.transfer(user2, shares);

        ILockedPoolTypes.UserPosition memory pos = manager.getPosition(positionId);
        assertEq(pos.user, user1, "Position owner unchanged");

        vm.warp(block.timestamp + 91 days);

        vm.prank(user2);
        vm.expectRevert("LockedPool/not owner");
        pool.redeemPosition(positionId);

        console.log("VERIFIED: Share transfer does NOT transfer position ownership");
    }

    function test_VULN_earlyExitAfterSPVAllocation() public {
        console.log("\n=== VULNERABILITY TEST: Early exit when funds with SPV ===");

        vm.prank(user1);
        (uint256 positionId,) = pool.depositLocked(
            DEPOSIT_AMOUNT,
            0,
            ILockedPoolTypes.InterestPayment.UPFRONT
        );

        ILockedPoolTypes.UserPosition memory pos = manager.getPosition(positionId);

        vm.prank(admin);
        manager.createPendingAllocation(address(pool), spv, pos.investedAmount);

        assertEq(escrow.getPrincipalHeld(), 0, "Escrow should be empty after allocation");

        vm.warp(block.timestamp + 30 days);

        vm.prank(user1);
        vm.expectRevert("LockedPoolManager/insufficient reserve");
        pool.earlyExitPosition(positionId);

        console.log("VERIFIED: Early exit fails when escrow empty and no reserve");
    }

    function test_VULN_directEscrowWithdrawal() public {
        console.log("\n=== VULNERABILITY TEST: Direct escrow withdrawal ===");

        vm.prank(user1);
        pool.depositLocked(DEPOSIT_AMOUNT, 0, ILockedPoolTypes.InterestPayment.UPFRONT);

        vm.prank(user1);
        vm.expectRevert();
        escrow.withdraw(user1, 1000e6);

        console.log("VERIFIED: Users cannot directly withdraw from escrow");
    }

    function test_VULN_directEscrowAllocation() public {
        console.log("\n=== VULNERABILITY TEST: Direct escrow SPV allocation ===");

        vm.prank(user1);
        pool.depositLocked(DEPOSIT_AMOUNT, 0, ILockedPoolTypes.InterestPayment.UPFRONT);

        vm.prank(user1);
        vm.expectRevert();
        escrow.allocateToSPV(user1, 1000e6);

        console.log("VERIFIED: Users cannot directly allocate to SPV");
    }

    function test_VULN_cannotDepositToInactivePool() public {
        console.log("\n=== VULNERABILITY TEST: Deposit to inactive pool ===");

        vm.prank(admin);
        manager.deactivatePool(address(pool));

        vm.prank(user1);
        vm.expectRevert("LockedPoolManager/pool not active");
        pool.depositLocked(DEPOSIT_AMOUNT, 0, ILockedPoolTypes.InterestPayment.UPFRONT);

        console.log("VERIFIED: Cannot deposit to inactive pool");
    }

    function test_VULN_zeroDeposit() public {
        console.log("\n=== VULNERABILITY TEST: Zero deposit ===");

        vm.prank(user1);
        vm.expectRevert("LockedPool/zero amount");
        pool.depositLocked(0, 0, ILockedPoolTypes.InterestPayment.UPFRONT);

        console.log("VERIFIED: Cannot deposit zero");
    }

    function test_VULN_positionStatusAfterEarlyExit() public {
        console.log("\n=== VULNERABILITY TEST: Cannot re-exit after early exit ===");

        vm.prank(user1);
        (uint256 positionId,) = pool.depositLocked(
            DEPOSIT_AMOUNT,
            1,
            ILockedPoolTypes.InterestPayment.AT_MATURITY
        );

        vm.warp(block.timestamp + 30 days);

        vm.prank(user1);
        pool.earlyExitPosition(positionId);

        vm.prank(user1);
        vm.expectRevert("LockedPool/insufficient shares");
        pool.earlyExitPosition(positionId);

        console.log("VERIFIED: Cannot early exit twice");
    }
}
