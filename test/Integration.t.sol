// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./fixtures/BaseTest.sol";
import "../src/LockedPoolManager.sol";
import "../src/StableYieldManager.sol";
import "../src/PoolRegistry.sol";
import "../src/FeeManager.sol";
import "../src/factories/ManagedPoolFactory.sol";
import "../src/factories/PoolFactory.sol";
import "../src/managed/LockedPool.sol";
import "../src/managed/StableYieldPool.sol";
import "../src/LiquidityPool.sol";
import "../src/Manager.sol";
import "../src/escrows/LockedPoolEscrow.sol";
import "../src/escrows/StableYieldEscrow.sol";
import "../src/escrows/PoolEscrow.sol";
import "../src/escrows/YieldReserveEscrow.sol";
import "../src/AccessManager.sol";
import "../src/types/ILockedPoolTypes.sol";
import "../src/types/IStableYieldTypes.sol";
import "../src/types/IPoolTypes.sol";
import "../src/interfaces/IPoolFactory.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract IntegrationTest is BaseTest {
    using SafeERC20 for IERC20;
    
    AccessManager accessManager;
    PoolRegistry registry;
    FeeManager feeManager;
    YieldReserveEscrow yieldReserve;
    
    LockedPoolManager lockedPoolManager;
    StableYieldManager stableYieldManager;
    Manager dealPoolManager;
    
    ManagedPoolFactory managedFactory;
    PoolFactory dealPoolFactory;
    
    MockERC20 token;
    
    address lockedPoolAddress;
    address lockedEscrowAddress;
    address stablePoolAddress;
    address stableEscrowAddress;
    address dealPoolAddress;
    address dealEscrowAddress;
    
    uint256 constant MIN_DEPOSIT = 1000e6;
    uint256 constant TARGET_RAISE = 100_000e6;
    
    function setUp() public override {
        super.setUp();
        
        token = new MockERC20("Mock USDC", "USDC", 6);
        _fundAllUsers();
        
        _deployAccessManager();
        _deployPoolRegistry();
        _deployYieldReserve();
        _deployFeeManager();
        
        _deployLockedPoolManager();
        _deployStableYieldManager();
        _deployDealPoolManager();
        
        _deployManagedPoolFactory();
        _deployDealPoolFactory();
        
        _configurePermissions();
    }
    
    function _fundAllUsers() internal {
        address[10] memory users = [user1, user2, user3, admin, operator, spv, emergency, treasury, multisigAdmin, makeAddr("extraUser")];
        for (uint i = 0; i < users.length; i++) {
            token.mint(users[i], INITIAL_BALANCE * 100);
        }
    }
    
    function _deployAccessManager() internal {
        accessManager = new AccessManager(admin, spv, operator, emergency, multisigAdmin);
    }
    
    function _deployPoolRegistry() internal {
        PoolRegistry impl = new PoolRegistry();
        bytes memory init = abi.encodeWithSignature(
            "initialize(address,address)",
            address(accessManager),
            admin
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        registry = PoolRegistry(address(proxy));
        
        vm.prank(admin);
        registry.approveAsset(address(token), "Mock USDC", "USDC", true);
    }
    
    function _deployYieldReserve() internal {
        YieldReserveEscrow impl = new YieldReserveEscrow();
        bytes memory init = abi.encodeWithSignature(
            "initialize(address,address,address,uint256,uint256)",
            address(token),
            address(accessManager),
            treasury,
            6000,
            10_000e6
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        yieldReserve = YieldReserveEscrow(address(proxy));
    }
    
    function _deployFeeManager() internal {
        FeeManager impl = new FeeManager();
        bytes memory init = abi.encodeWithSignature(
            "initialize(address,address,address,address,address)",
            address(accessManager),
            address(registry),
            address(yieldReserve),
            treasury,
            operator
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        feeManager = FeeManager(address(proxy));
    }
    
    function _deployLockedPoolManager() internal {
        LockedPoolManager impl = new LockedPoolManager();
        bytes memory init = abi.encodeWithSignature(
            "initialize(address,address,address)",
            address(accessManager),
            address(registry),
            admin
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        lockedPoolManager = LockedPoolManager(address(proxy));
    }
    
    function _deployStableYieldManager() internal {
        StableYieldManager impl = new StableYieldManager();
        bytes memory init = abi.encodeWithSignature(
            "initialize(address,address,address,uint256)",
            address(accessManager),
            address(registry),
            admin,
            300
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        stableYieldManager = StableYieldManager(address(proxy));
    }
    
    function _deployDealPoolManager() internal {
        Manager impl = new Manager();
        bytes memory init = abi.encodeWithSignature(
            "initialize(address,address,address,address)",
            address(registry),
            address(accessManager),
            admin,
            treasury
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        dealPoolManager = Manager(address(proxy));
    }
    
    function _deployManagedPoolFactory() internal {
        LockedPool lockedPoolImpl = new LockedPool();
        LockedPoolEscrow lockedEscrowImpl = new LockedPoolEscrow();
        StableYieldPool stablePoolImpl = new StableYieldPool();
        StableYieldEscrow stableEscrowImpl = new StableYieldEscrow();
        
        ManagedPoolFactory impl = new ManagedPoolFactory();
        bytes memory init = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address)",
            address(registry),
            address(accessManager),
            address(stableYieldManager),
            admin,
            address(stablePoolImpl),
            address(stableEscrowImpl)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        managedFactory = ManagedPoolFactory(address(proxy));
        
        vm.startPrank(admin);
        managedFactory.setLockedPoolManager(address(lockedPoolManager));
        managedFactory.updateLockedPoolImplementation(address(lockedPoolImpl));
        managedFactory.updateLockedPoolEscrowImplementation(address(lockedEscrowImpl));
        managedFactory.setFeeManager(address(feeManager));
        managedFactory.setYieldReserve(address(yieldReserve));
        lockedPoolManager.setManagedPoolFactory(address(managedFactory));
        stableYieldManager.setManagedPoolFactory(address(managedFactory));
        lockedPoolManager.setYieldReserve(address(yieldReserve));
        stableYieldManager.setYieldReserve(address(yieldReserve));
        yieldReserve.setLockedPoolManager(address(lockedPoolManager));
        yieldReserve.setStableYieldManager(address(stableYieldManager));
        vm.stopPrank();
    }
    
    function _deployDealPoolFactory() internal {
        LiquidityPool poolImpl = new LiquidityPool();
        PoolEscrow escrowImpl = new PoolEscrow();
        
        PoolFactory impl = new PoolFactory();
        bytes memory init = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address)",
            address(registry),
            address(dealPoolManager),
            address(accessManager),
            admin,
            address(poolImpl),
            address(escrowImpl)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        dealPoolFactory = PoolFactory(address(proxy));
        
        vm.prank(admin);
        registry.setFactory(address(dealPoolFactory));
    }
    
    function _configurePermissions() internal {
        vm.startPrank(admin);
        accessManager.grantRoleDuringDeployment(accessManager.POOL_CREATOR_ROLE(), address(lockedPoolManager));
        accessManager.grantRoleDuringDeployment(accessManager.POOL_CREATOR_ROLE(), address(stableYieldManager));
        accessManager.grantRoleDuringDeployment(accessManager.POOL_CREATOR_ROLE(), address(managedFactory));
        accessManager.grantRoleDuringDeployment(accessManager.POOL_CREATOR_ROLE(), admin);
        accessManager.grantRoleDuringDeployment(accessManager.OPERATOR_ROLE(), operator);
        accessManager.grantRoleDuringDeployment(accessManager.OPERATOR_ROLE(), address(stableYieldManager));
        accessManager.grantRoleDuringDeployment(accessManager.OPERATOR_ROLE(), address(lockedPoolManager));
        accessManager.grantFactoryRoleDuringDeployment(address(managedFactory));
        vm.stopPrank();
    }
    
    function _createLockedPool() internal returns (address pool, address escrow) {
        ILockedPoolTypes.LockTier[] memory tiers = new ILockedPoolTypes.LockTier[](2);
        tiers[0] = ILockedPoolTypes.LockTier({
            durationDays: 90,
            apyBps: 500,
            earlyExitPenaltyBps: 1000,
            minDeposit: MIN_DEPOSIT,
            isActive: true
        });
        tiers[1] = ILockedPoolTypes.LockTier({
            durationDays: 180,
            apyBps: 800,
            earlyExitPenaltyBps: 1500,
            minDeposit: MIN_DEPOSIT,
            isActive: true
        });
        
        ManagedPoolFactory.LockedPoolDeploymentConfig memory config = ManagedPoolFactory.LockedPoolDeploymentConfig({
            asset: address(token),
            poolName: "Integration Locked Pool",
            poolSymbol: "iLP",
            spvAddress: spv,
            minInvestment: MIN_DEPOSIT,
            initialTiers: tiers
        });
        
        vm.prank(admin);
        return managedFactory.createLockedPool(config);
    }
    
    function _createStableYieldPool() internal returns (address pool, address escrow) {
        ManagedPoolFactory.PoolDeploymentConfig memory config = ManagedPoolFactory.PoolDeploymentConfig({
            asset: address(token),
            poolName: "Integration Stable Yield Pool",
            poolSymbol: "iSYP",
            spvAddress: spv,
            minInvestment: MIN_DEPOSIT
        });
        
        vm.prank(admin);
        return managedFactory.createStableYieldPool(config);
    }
    
    function _createDealPool() internal returns (address pool, address escrow) {
        IPoolFactory.PoolConfig memory config = IPoolFactory.PoolConfig({
            asset: address(token),
            instrumentType: IPoolTypes.InstrumentType.DISCOUNTED,
            instrumentName: "Integration Deal Pool",
            targetRaise: TARGET_RAISE,
            epochDuration: 7 days,
            maturityDate: block.timestamp + 90 days,
            discountRate: 500,
            spvAddress: spv,
            couponDates: new uint256[](0),
            couponRates: new uint256[](0),
            minimumFundingThreshold: 8000,
            minInvestment: MIN_DEPOSIT,
            withdrawalFeeBps: 100
        });
        
        vm.prank(admin);
        return dealPoolFactory.createPool(config);
    }
    
    // ================================================================
    //  HELPERS
    // ================================================================

    function _lockedDeposit(address user, uint256 amount, uint8 tierIndex) internal returns (uint256 positionId) {
        vm.startPrank(user);
        token.approve(lockedPoolAddress, amount);
        (positionId,) = LockedPool(lockedPoolAddress).depositLocked(
            amount,
            tierIndex,
            ILockedPoolTypes.InterestPayment.AT_MATURITY
        );
        vm.stopPrank();
    }
    
    function _stableDeposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        token.approve(stablePoolAddress, amount);
        StableYieldPool(stablePoolAddress).deposit(amount, user);
        vm.stopPrank();
    }
    
    function _dealDeposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        token.approve(dealPoolAddress, amount);
        LiquidityPool(dealPoolAddress).deposit(amount, user);
        vm.stopPrank();
    }

    function _seedYieldReserve(uint256 amount) internal {
        token.mint(address(lockedPoolManager), amount);
        vm.startPrank(address(lockedPoolManager));
        token.approve(address(yieldReserve), amount);
        yieldReserve.receiveYield(amount);
        vm.stopPrank();
    }

    function _seedYieldReserveViaStableManager(uint256 amount) internal {
        token.mint(address(stableYieldManager), amount);
        vm.startPrank(address(stableYieldManager));
        token.approve(address(yieldReserve), amount);
        yieldReserve.receiveYield(amount);
        vm.stopPrank();
    }

    // ================================================================
    //  FINDING 1 - ESCROW AUTO-AUTHORIZATION ON YIELD RESERVE
    // ================================================================

    function test_finding1_lockedEscrow_autoAuthorized_onCreation() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();
        assertTrue(
            yieldReserve.isEscrowAuthorized(lockedEscrowAddress),
            "Locked escrow must be auto-authorized after factory creates pool"
        );
    }

    function test_finding1_stableEscrow_autoAuthorized_onCreation() public {
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();
        assertTrue(
            yieldReserve.isEscrowAuthorized(stableEscrowAddress),
            "Stable escrow must be auto-authorized after factory creates pool"
        );
    }

    function test_finding1_multiplePoolEscrows_allAuthorized() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();

        assertTrue(yieldReserve.isEscrowAuthorized(lockedEscrowAddress));
        assertTrue(yieldReserve.isEscrowAuthorized(stableEscrowAddress));
        assertTrue(lockedEscrowAddress != stableEscrowAddress, "Escrows should be different contracts");
    }

    // ================================================================
    //  FINDING 2 - YIELD RESERVE SET ON BOTH MANAGERS
    // ================================================================

    function test_finding2_yieldReserve_setOnBothManagers() public {
        assertEq(lockedPoolManager.yieldReserve(), address(yieldReserve), "LPM yieldReserve must be set");
        assertEq(stableYieldManager.yieldReserve(), address(yieldReserve), "SYM yieldReserve must be set");
    }

    function test_finding2_yieldReserve_knowsBothManagers() public {
        assertEq(yieldReserve.lockedPoolManager(), address(lockedPoolManager), "Reserve -> LPM");
        assertEq(yieldReserve.stableYieldManager(), address(stableYieldManager), "Reserve -> SYM");
    }

    // ================================================================
    //  FINDING 3 - FEE MANAGER SET ON ESCROWS VIA FACTORY
    // ================================================================

    function test_finding3_feeManager_setOnLockedEscrow() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();
        assertEq(
            LockedPoolEscrow(lockedEscrowAddress).feeManager(),
            address(feeManager),
            "Locked escrow feeManager must be set by factory"
        );
    }

    function test_finding3_feeManager_setOnStableEscrow() public {
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();
        assertEq(
            StableYieldEscrow(stableEscrowAddress).feeManager(),
            address(feeManager),
            "Stable escrow feeManager must be set by factory"
        );
    }

    // ================================================================
    //  FINDING 4 - SPV ALLOCATION BOUND TO DESIGNATED SPV
    // ================================================================

    function test_finding4_spvAllocation_boundToDesignatedSPV() public {
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();
        _stableDeposit(user1, 100_000e6);

        vm.prank(operator);
        bytes32 allocId = stableYieldManager.createPendingAllocation(stablePoolAddress, spv, 50_000e6);

        IStableYieldTypes.PendingAllocation memory alloc = stableYieldManager.getPendingAllocation(allocId);
        assertEq(alloc.spv, spv, "Allocation must be bound to designated SPV");

        address randomSPV = makeAddr("randomSPV");
        vm.startPrank(admin);
        accessManager.grantRoleDuringDeployment(accessManager.SPV_ROLE(), randomSPV);
        vm.stopPrank();

        vm.prank(randomSPV);
        vm.expectRevert(StableYieldManager.NotAllocationSPV.selector);
        stableYieldManager.addInstrument(
            stablePoolAddress,
            allocId,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            50_000e6,
            52_500e6,
            block.timestamp + 90 days,
            0,
            0
        );
    }

    // ================================================================
    //  BUG FIX - ESCROW sendYieldToReserve / transferPenaltiesToReserve
    // ================================================================

    function test_bugfix_lockedEscrow_sendYieldToReserve_works() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();

        vm.prank(operator);
        token.transfer(lockedEscrowAddress, 1_000_000e6);

        _lockedDeposit(user1, 100_000e6, 0);

        vm.prank(operator);
        bytes32 allocId = lockedPoolManager.createPendingAllocation(lockedPoolAddress, spv, 80_000e6);

        _seedYieldReserve(10_000e6);
        uint256 reserveBefore = yieldReserve.getAvailableBalance();

        uint256 returnAmount = 85_000e6;
        token.mint(spv, 5_000e6);

        vm.startPrank(spv);
        token.approve(address(lockedPoolManager), returnAmount);
        lockedPoolManager.matureAllocation(allocId, returnAmount);
        vm.stopPrank();

        uint256 reserveAfter = yieldReserve.getAvailableBalance();
        assertTrue(reserveAfter > reserveBefore, "Excess yield must flow to reserve via escrow.sendYieldToReserve");
    }

    function test_bugfix_lockedEscrow_transferPenaltiesToReserve_works() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();
        
        vm.prank(operator);
        token.transfer(lockedEscrowAddress, 10_000_000e6);

        uint256 positionId = _lockedDeposit(user1, 100_000e6, 0);

        skipTime(30 days);

        vm.prank(user1);
        LockedPool(lockedPoolAddress).earlyExitPosition(positionId);

        LockedPoolEscrow escrow = LockedPoolEscrow(lockedEscrowAddress);
        uint256 penalties = escrow.getPenaltiesCollected();
        assertTrue(penalties > 0, "Should have penalties after early exit");

        uint256 reserveBefore = yieldReserve.getAvailableBalance();

        vm.prank(operator);
        escrow.transferPenaltiesToReserve(address(yieldReserve));

        uint256 reserveAfter = yieldReserve.getAvailableBalance();
        assertTrue(reserveAfter > reserveBefore, "Reserve should receive penalties");
        assertEq(escrow.getPenaltiesCollected(), 0, "Penalties should be zeroed");
    }

    // ================================================================
    //  LOCKED POOL - EARLY EXIT WITH RESERVE BACKSTOP (FULL PATH)
    // ================================================================

    function test_lockedPool_earlyExit_escrowHasFunds_noReserveLoan() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();

        vm.prank(operator);
        token.transfer(lockedEscrowAddress, 10_000_000e6);

        uint256 positionId = _lockedDeposit(user1, 50_000e6, 0);

        skipTime(30 days);

        vm.prank(user1);
        (uint256 payout, uint256 penalty) = LockedPool(lockedPoolAddress).earlyExitPosition(positionId);

        assertTrue(payout > 0, "Payout must be positive");
        assertTrue(penalty > 0, "Penalty must be positive");

        ILockedPoolTypes.DebtPosition memory debt = lockedPoolManager.getDebtPosition(positionId);
        assertEq(debt.reserveLoan, 0, "No reserve loan needed when escrow has sufficient funds");
    }

    function test_lockedPool_earlyExit_escrowShort_borrowsFromReserve() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();

        uint256 principal = 50_000e6;
        uint256 positionId = _lockedDeposit(user1, principal, 0);

        vm.prank(operator);
        lockedPoolManager.createPendingAllocation(lockedPoolAddress, spv, principal);

        _seedYieldReserve(200_000e6);

        skipTime(30 days);

        uint256 userBalBefore = token.balanceOf(user1);

        vm.prank(user1);
        (uint256 payout,) = LockedPool(lockedPoolAddress).earlyExitPosition(positionId);

        uint256 received = token.balanceOf(user1) - userBalBefore;
        assertEq(received, payout, "User must receive full payout via reserve backstop");
        assertTrue(payout > 0, "Payout must be positive");

        ILockedPoolTypes.DebtPosition memory debt = lockedPoolManager.getDebtPosition(positionId);
        assertTrue(debt.reserveLoan > 0, "Reserve loan should be recorded");
        assertFalse(debt.settled, "Debt should not be settled yet");
        assertEq(debt.positionId, positionId, "Debt position ID must match");
        assertEq(debt.user, user1, "Debt user must match");
    }

    function test_lockedPool_earlyExit_noReserve_noFunds_reverts() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();

        uint256 positionId = _lockedDeposit(user1, 50_000e6, 0);

        vm.prank(operator);
        lockedPoolManager.createPendingAllocation(lockedPoolAddress, spv, 50_000e6);

        skipTime(30 days);

        vm.prank(user1);
        vm.expectRevert();
        LockedPool(lockedPoolAddress).earlyExitPosition(positionId);
    }

    function test_lockedPool_earlyExit_reserveInsufficient_reverts() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();

        uint256 positionId = _lockedDeposit(user1, 50_000e6, 0);

        vm.prank(operator);
        lockedPoolManager.createPendingAllocation(lockedPoolAddress, spv, 50_000e6);

        _seedYieldReserve(100e6);

        skipTime(30 days);

        vm.prank(user1);
        vm.expectRevert();
        LockedPool(lockedPoolAddress).earlyExitPosition(positionId);
    }

    // ================================================================
    //  LOCKED POOL - SPV ALLOCATION FULL CYCLE WITH YIELD TO RESERVE
    // ================================================================

    function test_lockedPool_spvAllocation_fullCycle_yieldToReserve() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();

        vm.prank(operator);
        token.transfer(lockedEscrowAddress, 1_000_000e6);

        _lockedDeposit(user1, 100_000e6, 0);

        vm.prank(operator);
        bytes32 allocId = lockedPoolManager.createPendingAllocation(lockedPoolAddress, spv, 80_000e6);

        (,,,,,ILockedPoolTypes.AllocationStatus statusAfterCreate) = lockedPoolManager.spvAllocations(allocId);
        assertEq(uint8(statusAfterCreate), uint8(ILockedPoolTypes.AllocationStatus.INVESTED));

        _seedYieldReserve(10_000e6);
        uint256 reserveBefore = yieldReserve.getAvailableBalance();

        uint256 yieldAmount = 5_000e6;
        uint256 returnAmount = 80_000e6 + yieldAmount;
        token.mint(spv, yieldAmount);

        vm.startPrank(spv);
        token.approve(address(lockedPoolManager), returnAmount);
        lockedPoolManager.matureAllocation(allocId, returnAmount);
        vm.stopPrank();

        (,,,,,ILockedPoolTypes.AllocationStatus statusAfterMature) = lockedPoolManager.spvAllocations(allocId);
        assertEq(uint8(statusAfterMature), uint8(ILockedPoolTypes.AllocationStatus.MATURED));

        uint256 reserveAfter = yieldReserve.getAvailableBalance();
        assertTrue(reserveAfter > reserveBefore, "Excess yield must flow to reserve");

        ILockedPoolTypes.PoolProtocolAccounting memory accounting = lockedPoolManager.getPoolAccounting(lockedPoolAddress);
        assertTrue(accounting.totalYieldEarned > 0, "Pool yield accounting must be updated");
    }

    function test_lockedPool_spvAllocation_partialReturn() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();

        vm.prank(operator);
        token.transfer(lockedEscrowAddress, 1_000_000e6);

        _lockedDeposit(user1, 100_000e6, 0);

        vm.prank(operator);
        bytes32 allocId = lockedPoolManager.createPendingAllocation(lockedPoolAddress, spv, 80_000e6);

        vm.startPrank(spv);
        token.approve(address(lockedPoolManager), 50_000e6);
        lockedPoolManager.matureAllocation(allocId, 50_000e6);
        vm.stopPrank();

        (,,,,,ILockedPoolTypes.AllocationStatus status) = lockedPoolManager.spvAllocations(allocId);
        assertEq(uint8(status), uint8(ILockedPoolTypes.AllocationStatus.RETURNED), "Partial return should be RETURNED status");
    }

    // ================================================================
    //  LOCKED POOL - DEPLOY & RECALL PROTOCOL CAPITAL (LOAN FROM RESERVE)
    // ================================================================

    function test_lockedPool_deployProtocolCapital_roundTrip() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();

        _seedYieldReserve(500_000e6);
        uint256 reserveBal0 = yieldReserve.getAvailableBalance();
        uint256 escrowBal0 = token.balanceOf(lockedEscrowAddress);

        vm.prank(admin);
        lockedPoolManager.deployProtocolCapital(lockedPoolAddress, 200_000e6);

        LockedPoolEscrow escrow = LockedPoolEscrow(lockedEscrowAddress);
        assertEq(escrow.protocolFundsFromReserve(), 200_000e6, "Escrow must track deployed capital");
        assertEq(token.balanceOf(lockedEscrowAddress), escrowBal0 + 200_000e6, "Escrow balance must increase");
        assertEq(yieldReserve.getAvailableBalance(), reserveBal0 - 200_000e6, "Reserve balance must decrease");

        vm.prank(admin);
        lockedPoolManager.recallProtocolCapital(lockedPoolAddress, 200_000e6);

        assertEq(escrow.protocolFundsFromReserve(), 0, "Recalled fully");
        assertEq(yieldReserve.getAvailableBalance(), reserveBal0, "Reserve balance must be restored");
    }

    function test_lockedPool_deployProtocolCapital_partialRecall() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();

        _seedYieldReserve(500_000e6);

        vm.prank(admin);
        lockedPoolManager.deployProtocolCapital(lockedPoolAddress, 100_000e6);

        uint256 reserveBeforeRecall = yieldReserve.getAvailableBalance();

        vm.prank(admin);
        lockedPoolManager.recallProtocolCapital(lockedPoolAddress, 40_000e6);

        LockedPoolEscrow escrow = LockedPoolEscrow(lockedEscrowAddress);
        assertEq(escrow.protocolFundsFromReserve(), 60_000e6, "Should reflect partial recall");
        assertEq(yieldReserve.getAvailableBalance(), reserveBeforeRecall + 40_000e6, "Reserve gets back partial amount");
    }

    // ================================================================
    //  STABLE YIELD - DEPLOY & RECALL PROTOCOL CAPITAL
    // ================================================================

    function test_stableYield_deployProtocolCapital_roundTrip() public {
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();

        _seedYieldReserve(500_000e6);
        uint256 reserveBefore = yieldReserve.getAvailableBalance();

        vm.prank(admin);
        stableYieldManager.deployProtocolCapital(stablePoolAddress, 100_000e6);

        StableYieldEscrow escrow = StableYieldEscrow(stableEscrowAddress);
        assertEq(escrow.protocolFundsFromReserve(), 100_000e6, "Escrow tracks reserve funds");
        assertEq(yieldReserve.getAvailableBalance(), reserveBefore - 100_000e6, "Reserve debited");

        vm.prank(admin);
        stableYieldManager.recallProtocolCapital(stablePoolAddress, 100_000e6);

        assertEq(escrow.protocolFundsFromReserve(), 0, "Escrow tracking zeroed");
        assertEq(yieldReserve.getAvailableBalance(), reserveBefore, "Reserve fully restored");
    }

    function test_stableYield_deployProtocolCapital_partialRecall() public {
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();

        _seedYieldReserve(500_000e6);

        vm.prank(admin);
        stableYieldManager.deployProtocolCapital(stablePoolAddress, 200_000e6);

        vm.prank(admin);
        stableYieldManager.recallProtocolCapital(stablePoolAddress, 80_000e6);

        StableYieldEscrow escrow = StableYieldEscrow(stableEscrowAddress);
        assertEq(escrow.protocolFundsFromReserve(), 120_000e6, "Should track remaining");
    }

    // ================================================================
    //  STABLE YIELD - WITHDRAWAL QUEUE BACKSTOPPED BY RESERVE
    // ================================================================

    function test_stableYield_withdrawalQueue_backstoppedByReserve() public {
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();

        _stableDeposit(user1, 100_000e6);

        vm.prank(operator);
        bytes32 allocId = stableYieldManager.createPendingAllocation(stablePoolAddress, spv, 80_000e6);

        vm.prank(spv);
        stableYieldManager.addInstrument(
            stablePoolAddress,
            allocId,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            80_000e6,
            84_000e6,
            block.timestamp + 90 days,
            0,
            0
        );

        _seedYieldReserve(500_000e6);

        skipTime(30 days + 1);

        uint256 shares = StableYieldPool(stablePoolAddress).balanceOf(user1);
        uint256 balBefore = token.balanceOf(user1);

        vm.prank(user1);
        StableYieldPool(stablePoolAddress).redeem(shares, user1, user1);

        (uint256 head, uint256 tail,,) = stableYieldManager.getWithdrawalQueueStatus(stablePoolAddress);

        if (tail > head) {
            uint256[] memory ids = new uint256[](1);
            ids[0] = head;
            vm.prank(operator);
            stableYieldManager.settleWithdrawals(stablePoolAddress, ids);
        }

        uint256 balAfter = token.balanceOf(user1);
        assertTrue(balAfter > balBefore, "User must receive funds with reserve backstop");
    }

    function test_stableYield_withdrawalQueue_settleMultiple() public {
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();

        _stableDeposit(user1, 50_000e6);
        _stableDeposit(user2, 50_000e6);

        vm.prank(operator);
        bytes32 allocId = stableYieldManager.createPendingAllocation(stablePoolAddress, spv, 80_000e6);

        vm.prank(spv);
        stableYieldManager.addInstrument(
            stablePoolAddress,
            allocId,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            80_000e6,
            84_000e6,
            block.timestamp + 90 days,
            0,
            0
        );

        _seedYieldReserve(500_000e6);

        skipTime(30 days + 1);

        uint256 shares1 = StableYieldPool(stablePoolAddress).balanceOf(user1);
        uint256 shares2 = StableYieldPool(stablePoolAddress).balanceOf(user2);

        vm.prank(user1);
        StableYieldPool(stablePoolAddress).redeem(shares1, user1, user1);

        vm.prank(user2);
        StableYieldPool(stablePoolAddress).redeem(shares2, user2, user2);

        (uint256 head, uint256 tail,,) = stableYieldManager.getWithdrawalQueueStatus(stablePoolAddress);

        if (tail > head) {
            uint256 count = tail - head;
            uint256[] memory ids = new uint256[](count);
            for (uint256 i = 0; i < count; i++) {
                ids[i] = head + i;
            }
            vm.prank(operator);
            stableYieldManager.settleWithdrawals(stablePoolAddress, ids);
        }

        assertTrue(token.balanceOf(user1) > 0, "User1 should have been paid");
        assertTrue(token.balanceOf(user2) > 0, "User2 should have been paid");
    }

    // ================================================================
    //  STABLE YIELD - FULL INSTRUMENT LIFECYCLE
    // ================================================================

    function test_stableYield_fullInstrumentLifecycle_discounted() public {
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();

        _stableDeposit(user1, 100_000e6);

        vm.prank(operator);
        bytes32 allocId = stableYieldManager.createPendingAllocation(stablePoolAddress, spv, 50_000e6);

        vm.prank(spv);
        stableYieldManager.addInstrument(
            stablePoolAddress,
            allocId,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            50_000e6,
            52_500e6,
            block.timestamp + 90 days,
            0,
            0
        );

        IStableYieldTypes.InstrumentHolding[] memory instruments = stableYieldManager.getPoolInstruments(stablePoolAddress);
        assertEq(instruments.length, 1, "Should have 1 instrument");
        assertTrue(instruments[0].isActive, "Instrument should be active");

        skipTime(90 days + 1);

        vm.startPrank(spv);
        token.approve(address(stableYieldManager), 52_500e6);
        stableYieldManager.matureInstrumentWithFunds(stablePoolAddress, 0, 52_500e6);
        vm.stopPrank();

        instruments = stableYieldManager.getPoolInstruments(stablePoolAddress);
        assertEq(instruments.length, 0, "Instrument should be removed after maturity");

        skipTime(30 days);

        uint256 userShares = StableYieldPool(stablePoolAddress).balanceOf(user1);
        uint256 balBefore = token.balanceOf(user1);

        vm.prank(user1);
        StableYieldPool(stablePoolAddress).redeem(userShares, user1, user1);

        assertTrue(token.balanceOf(user1) > balBefore, "User should withdraw with yield");
    }

    function test_stableYield_fullInstrumentLifecycle_interestBearing_withCoupons() public {
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();

        _stableDeposit(user1, 100_000e6);

        vm.prank(operator);
        bytes32 allocId = stableYieldManager.createPendingAllocation(stablePoolAddress, spv, 50_000e6);

        vm.prank(spv);
        stableYieldManager.addInstrument(
            stablePoolAddress,
            allocId,
            IStableYieldTypes.InstrumentType.INTEREST_BEARING,
            50_000e6,
            50_000e6,
            block.timestamp + 365 days,
            500,
            4
        );

        vm.warp(block.timestamp + 92 days);

        uint256 couponAmount = 625e6;
        token.mint(spv, couponAmount);
        vm.startPrank(spv);
        token.approve(address(stableYieldManager), couponAmount);
        uint256 reservesBefore = StableYieldEscrow(stableEscrowAddress).getPoolReserves();
        stableYieldManager.recordCouponPayment(stablePoolAddress, 0, couponAmount);
        vm.stopPrank();

        uint256 reservesAfter = StableYieldEscrow(stableEscrowAddress).getPoolReserves();
        assertEq(reservesAfter - reservesBefore, couponAmount, "Coupon must be added to reserves");

        skipTime(365 days);

        vm.startPrank(spv);
        token.approve(address(stableYieldManager), 50_000e6);
        stableYieldManager.matureInstrumentWithFunds(stablePoolAddress, 0, 50_000e6);
        vm.stopPrank();
    }

    // ================================================================
    //  LOCKED POOL - FULL LIFECYCLE WITH YIELD RESERVE INTEGRATION
    // ================================================================

    function test_lockedPool_fullCycle_withReserve() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();

        vm.prank(operator);
        token.transfer(lockedEscrowAddress, 1_000_000e6);

        uint256 pos1 = _lockedDeposit(user1, 50_000e6, 0);
        uint256 pos2 = _lockedDeposit(user2, 30_000e6, 1);
        uint256 pos3 = _lockedDeposit(user3, 20_000e6, 0);

        skipTime(30 days);
        vm.prank(user1);
        LockedPool(lockedPoolAddress).earlyExitPosition(pos1);

        skipTime(150 days);
        vm.prank(user2);
        LockedPool(lockedPoolAddress).redeemPosition(pos2);

        vm.prank(user3);
        LockedPool(lockedPoolAddress).setAutoRollover(pos3, true);

        vm.prank(operator);
        uint256 newPos3 = lockedPoolManager.executeRollover(pos3);

        assertEq(uint8(lockedPoolManager.getPosition(pos1).status), uint8(ILockedPoolTypes.PositionStatus.EARLY_EXIT));
        assertEq(uint8(lockedPoolManager.getPosition(pos2).status), uint8(ILockedPoolTypes.PositionStatus.REDEEMED));
        assertEq(uint8(lockedPoolManager.getPosition(pos3).status), uint8(ILockedPoolTypes.PositionStatus.ROLLED_OVER));
        assertTrue(lockedPoolManager.getPosition(newPos3).autoRollover);
    }

    // ================================================================
    //  ADMIN DIRECT DEPOSITS TRACKING
    // ================================================================

    function test_adminDirectDeposit_bothPoolTypes_tracked() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();

        uint256 amount = 50_000e6;
        token.mint(admin, amount * 2);

        vm.startPrank(admin);
        token.approve(lockedEscrowAddress, amount);
        LockedPoolEscrow(lockedEscrowAddress).receiveProtocolFundsFromAdmin(amount);

        token.approve(stableEscrowAddress, amount);
        StableYieldEscrow(stableEscrowAddress).receiveProtocolFundsFromAdmin(amount);
        vm.stopPrank();

        assertEq(yieldReserve.directDepositsToPool(lockedPoolAddress), amount, "Locked pool direct deposit tracked");
        assertEq(yieldReserve.directDepositsToPool(stablePoolAddress), amount, "Stable pool direct deposit tracked");

        YieldReserveEscrow.ProtocolFundsSnapshot memory snapshot = yieldReserve.getProtocolFundsSnapshot();
        assertEq(snapshot.totalDirectDeposits, amount * 2, "Total direct deposits should sum");
        assertEq(snapshot.poolCount, 2, "Should track 2 pools");
    }

    // ================================================================
    //  RESERVE STATS & SNAPSHOT AFTER MULTIPLE OPERATIONS
    // ================================================================

    function test_reserveStats_afterMultipleOps() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();

        _seedYieldReserve(1_000_000e6);

        vm.startPrank(admin);
        lockedPoolManager.deployProtocolCapital(lockedPoolAddress, 100_000e6);
        stableYieldManager.deployProtocolCapital(stablePoolAddress, 100_000e6);
        vm.stopPrank();

        (uint256 balance,,,,, ) = yieldReserve.getReserveStats();
        assertTrue(balance < 1_000_000e6, "Balance should decrease after deployments");

        YieldReserveEscrow.ProtocolFundsSnapshot memory snapshot = yieldReserve.getProtocolFundsSnapshot();
        assertEq(snapshot.totalDeployedViaReserve, 200_000e6, "Total deployed should be 200k");
    }

    // ================================================================
    //  YIELD RESERVE TREASURY SPLIT
    // ================================================================

    function test_yieldReserve_treasurySplit_onReceiveYield() public {
        _seedYieldReserve(100_000e6);

        uint256 treasuryBal = token.balanceOf(treasury);
        assertTrue(treasuryBal > 0, "Treasury should have received its split");

        (uint256 tBps, uint256 rBps) = yieldReserve.getSplitConfig();
        assertEq(tBps, 6000, "Treasury should get 60%");
        assertEq(rBps, 4000, "Reserve should get 40%");
    }

    // ================================================================
    //  END-TO-END: DEPOSIT -> SPV ALLOCATE -> SPV MATURE WITH YIELD -> EARLY EXIT FROM RESERVE -> PENALTIES TO RESERVE
    // ================================================================

    function test_endToEnd_lockedPool_fullPath() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();

        vm.prank(operator);
        token.transfer(lockedEscrowAddress, 500_000e6);

        uint256 pos1 = _lockedDeposit(user1, 100_000e6, 0);
        uint256 pos2 = _lockedDeposit(user2, 100_000e6, 0);

        vm.prank(operator);
        bytes32 allocId = lockedPoolManager.createPendingAllocation(lockedPoolAddress, spv, 150_000e6);

        _seedYieldReserve(500_000e6);
        uint256 reserveAfterSeed = yieldReserve.getAvailableBalance();

        uint256 returnAmount = 160_000e6;
        token.mint(spv, 10_000e6);

        vm.startPrank(spv);
        token.approve(address(lockedPoolManager), returnAmount);
        lockedPoolManager.matureAllocation(allocId, returnAmount);
        vm.stopPrank();

        uint256 reserveAfterYield = yieldReserve.getAvailableBalance();
        assertTrue(reserveAfterYield > reserveAfterSeed, "Yield should flow to reserve");

        skipTime(30 days);

        vm.prank(user1);
        (uint256 payout1, uint256 penalty1) = LockedPool(lockedPoolAddress).earlyExitPosition(pos1);
        assertTrue(payout1 > 0 && penalty1 > 0, "Early exit should produce payout and penalty");

        LockedPoolEscrow escrow = LockedPoolEscrow(lockedEscrowAddress);
        uint256 penaltiesCollected = escrow.getPenaltiesCollected();

        if (penaltiesCollected > 0) {
            uint256 reserveBeforePenalties = yieldReserve.getAvailableBalance();

            vm.prank(operator);
            escrow.transferPenaltiesToReserve(address(yieldReserve));

            uint256 reserveAfterPenalties = yieldReserve.getAvailableBalance();
            assertTrue(reserveAfterPenalties > reserveBeforePenalties, "Penalties should flow to reserve");
        }

        skipTime(60 days + 1);

        vm.prank(user2);
        LockedPool(lockedPoolAddress).redeemPosition(pos2);

        assertEq(uint8(lockedPoolManager.getPosition(pos1).status), uint8(ILockedPoolTypes.PositionStatus.EARLY_EXIT));
        assertEq(uint8(lockedPoolManager.getPosition(pos2).status), uint8(ILockedPoolTypes.PositionStatus.REDEEMED));
    }

    function test_endToEnd_stableYield_fullPath() public {
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();

        _stableDeposit(user1, 100_000e6);
        _stableDeposit(user2, 50_000e6);

        _seedYieldReserve(300_000e6);

        vm.prank(admin);
        stableYieldManager.deployProtocolCapital(stablePoolAddress, 50_000e6);

        StableYieldEscrow escrow = StableYieldEscrow(stableEscrowAddress);
        assertEq(escrow.protocolFundsFromReserve(), 50_000e6, "Protocol capital tracked");

        vm.prank(operator);
        bytes32 allocId = stableYieldManager.createPendingAllocation(stablePoolAddress, spv, 100_000e6);

        vm.prank(spv);
        stableYieldManager.addInstrument(
            stablePoolAddress,
            allocId,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            100_000e6,
            105_000e6,
            block.timestamp + 90 days,
            0,
            0
        );

        skipTime(90 days + 1);

        vm.startPrank(spv);
        token.approve(address(stableYieldManager), 105_000e6);
        stableYieldManager.matureInstrumentWithFunds(stablePoolAddress, 0, 105_000e6);
        vm.stopPrank();

        vm.prank(admin);
        stableYieldManager.recallProtocolCapital(stablePoolAddress, 50_000e6);

        assertEq(escrow.protocolFundsFromReserve(), 0, "All protocol capital recalled");

        skipTime(30 days);

        uint256 user1Shares = StableYieldPool(stablePoolAddress).balanceOf(user1);
        uint256 user1BalBefore = token.balanceOf(user1);

        vm.prank(user1);
        StableYieldPool(stablePoolAddress).redeem(user1Shares, user1, user1);

        assertTrue(token.balanceOf(user1) > user1BalBefore, "User1 should withdraw with yield");
    }

    // ================================================================
    //  CROSS-POOL OPERATIONS (BOTH POOL TYPES SIMULTANEOUSLY)
    // ================================================================

    function test_crossPool_simultaneousOperations() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();

        vm.prank(operator);
        token.transfer(lockedEscrowAddress, 1_000_000e6);

        _lockedDeposit(user1, 50_000e6, 0);
        _stableDeposit(user1, 50_000e6);

        _seedYieldReserve(500_000e6);

        vm.startPrank(admin);
        lockedPoolManager.deployProtocolCapital(lockedPoolAddress, 50_000e6);
        stableYieldManager.deployProtocolCapital(stablePoolAddress, 50_000e6);
        vm.stopPrank();

        YieldReserveEscrow.ProtocolFundsSnapshot memory snap1 = yieldReserve.getProtocolFundsSnapshot();
        assertEq(snap1.totalDeployedViaReserve, 100_000e6, "100k deployed across both pools");

        vm.startPrank(admin);
        lockedPoolManager.recallProtocolCapital(lockedPoolAddress, 50_000e6);
        stableYieldManager.recallProtocolCapital(stablePoolAddress, 50_000e6);
        vm.stopPrank();

        YieldReserveEscrow.ProtocolFundsSnapshot memory snap2 = yieldReserve.getProtocolFundsSnapshot();
        assertEq(snap2.totalDeployedViaReserve, 0, "All capital recalled");
    }

    // ================================================================
    //  RESERVE INVESTMENT FLOW
    // ================================================================

    function test_reserve_investAndMature() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();

        _seedYieldReserve(500_000e6);

        vm.prank(operator);
        uint256 investmentId = yieldReserve.investReserve(
            lockedPoolAddress,
            lockedEscrowAddress,
            50_000e6,
            55_000e6
        );

        YieldReserveEscrow.ReserveInvestment memory inv = yieldReserve.getInvestment(investmentId);
        assertTrue(inv.active, "Investment should be active");
        assertEq(inv.amount, 50_000e6, "Investment amount");
        assertEq(inv.expectedReturn, 55_000e6, "Expected return");

        uint256 reserveAfterInvest = yieldReserve.getAvailableBalance();

        token.mint(address(lockedPoolManager), 55_000e6);
        vm.startPrank(address(lockedPoolManager));
        yieldReserve.recordInvestmentMaturity(investmentId, 55_000e6);
        vm.stopPrank();

        YieldReserveEscrow.ReserveInvestment memory invAfter = yieldReserve.getInvestment(investmentId);
        assertFalse(invAfter.active, "Investment should be inactive after maturity");

        uint256 reserveAfterMature = yieldReserve.getAvailableBalance();
        assertTrue(reserveAfterMature > reserveAfterInvest, "Reserve should grow from investment return");
    }

    // ================================================================
    //  RESERVE LOAN TRACKING
    // ================================================================

    function test_reserve_loanTracking() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();

        uint256 principal = 100_000e6;
        uint256 positionId = _lockedDeposit(user1, principal, 0);

        vm.prank(operator);
        lockedPoolManager.createPendingAllocation(lockedPoolAddress, spv, principal);

        _seedYieldReserve(500_000e6);
        uint256 reserveBefore = yieldReserve.getAvailableBalance();

        skipTime(30 days);

        vm.prank(user1);
        LockedPool(lockedPoolAddress).earlyExitPosition(positionId);

        uint256 reserveAfter = yieldReserve.getAvailableBalance();
        assertTrue(reserveAfter < reserveBefore, "Reserve balance should decrease from loan");

        uint256 poolLoan = yieldReserve.getPoolLoan(lockedPoolAddress);
        assertTrue(poolLoan > 0, "Pool loan should be tracked on reserve");

        uint256 totalLoaned = yieldReserve.getTotalLoaned();
        assertTrue(totalLoaned > 0, "Total loaned should be tracked");

        ILockedPoolTypes.DebtPosition memory debt = lockedPoolManager.getDebtPosition(positionId);
        assertTrue(debt.reserveLoan > 0, "Debt position should track reserve loan");

        uint256[] memory debtIds = lockedPoolManager.getPoolDebtPositions(lockedPoolAddress);
        assertTrue(debtIds.length > 0, "Pool should have debt position IDs");
    }

    // ================================================================
    //  YIELD RESERVE SWEEP TO TREASURY
    // ================================================================

    function test_reserve_sweepToTreasury() public {
        _seedYieldReserve(100_000e6);

        uint256 reserveBal = yieldReserve.getAvailableBalance();
        uint256 floor = yieldReserve.minReserveFloor();

        if (reserveBal > floor) {
            uint256 treasuryBefore = token.balanceOf(treasury);

            vm.prank(operator);
            yieldReserve.sweepToTreasury();

            uint256 treasuryAfter = token.balanceOf(treasury);
            assertTrue(treasuryAfter > treasuryBefore, "Treasury should receive swept funds");
            assertEq(yieldReserve.getAvailableBalance(), floor, "Reserve should be at floor after sweep");
        }
    }

    // ================================================================
    //  YIELD RESERVE EMERGENCY WITHDRAW
    // ================================================================

    function test_reserve_emergencyWithdraw() public {
        _seedYieldReserve(100_000e6);

        uint256 adminBefore = token.balanceOf(admin);

        vm.prank(admin);
        yieldReserve.emergencyWithdraw(admin, 10_000e6);

        assertEq(token.balanceOf(admin) - adminBefore, 10_000e6, "Admin should receive emergency funds");
    }

    // ================================================================
    //  ACCESS CONTROL ON YIELD RESERVE
    // ================================================================

    function test_reserve_unauthorizedManager_reverts() public {
        vm.prank(user1);
        vm.expectRevert("YieldReserveEscrow/unauthorized manager");
        yieldReserve.loanToPool(address(0x1), 1, 1000e6, address(0x1));
    }

    function test_reserve_unauthorizedEscrow_reverts() public {
        vm.prank(user1);
        vm.expectRevert("YieldReserveEscrow/unauthorized escrow");
        yieldReserve.receiveRecalledFunds(address(0x1), 1000e6);
    }

    // ================================================================
    //  MULTIPLE EARLY EXITS WITH RESERVE LOANS
    // ================================================================

    function test_multipleEarlyExits_withReserveLoans() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();

        uint256 pos1 = _lockedDeposit(user1, 50_000e6, 0);
        uint256 pos2 = _lockedDeposit(user2, 50_000e6, 0);
        uint256 pos3 = _lockedDeposit(user3, 50_000e6, 0);

        vm.prank(operator);
        lockedPoolManager.createPendingAllocation(lockedPoolAddress, spv, 150_000e6);

        _seedYieldReserve(1_000_000e6);

        skipTime(30 days);

        vm.prank(user1);
        LockedPool(lockedPoolAddress).earlyExitPosition(pos1);

        vm.prank(user2);
        LockedPool(lockedPoolAddress).earlyExitPosition(pos2);

        vm.prank(user3);
        LockedPool(lockedPoolAddress).earlyExitPosition(pos3);

        for (uint256 id = pos1; id <= pos3; id++) {
            ILockedPoolTypes.DebtPosition memory debt = lockedPoolManager.getDebtPosition(id);
            assertTrue(debt.reserveLoan > 0, "Each position should have a reserve loan");
        }

        uint256 totalPoolLoans = yieldReserve.getPoolLoan(lockedPoolAddress);
        assertTrue(totalPoolLoans > 0, "Pool should have cumulative loans");
    }

    // ================================================================
    //  ESCROW BALANCE ACCOUNTING INTEGRITY
    // ================================================================

    function test_escrowBalanceAccounting_lockedPool() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();

        _seedYieldReserve(500_000e6);

        vm.prank(admin);
        lockedPoolManager.deployProtocolCapital(lockedPoolAddress, 100_000e6);

        uint256 amount = 50_000e6;
        token.mint(admin, amount);
        vm.startPrank(admin);
        token.approve(lockedEscrowAddress, amount);
        LockedPoolEscrow(lockedEscrowAddress).receiveProtocolFundsFromAdmin(amount);
        vm.stopPrank();

        LockedPoolEscrow escrow = LockedPoolEscrow(lockedEscrowAddress);
        uint256 expectedBal = escrow.getExpectedBalance();
        uint256 actualBal = escrow.getTotalBalance();

        assertEq(actualBal, expectedBal, "Actual and expected balance must match");
        assertEq(escrow.protocolFundsFromReserve(), 100_000e6, "Reserve funds tracked");
        assertEq(escrow.protocolFundsDirectDeposit(), 50_000e6, "Direct deposit tracked");
    }

    function test_escrowBalanceAccounting_stableYield() public {
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();

        _seedYieldReserve(500_000e6);

        vm.prank(admin);
        stableYieldManager.deployProtocolCapital(stablePoolAddress, 100_000e6);

        uint256 amount = 50_000e6;
        token.mint(admin, amount);
        vm.startPrank(admin);
        token.approve(stableEscrowAddress, amount);
        StableYieldEscrow(stableEscrowAddress).receiveProtocolFundsFromAdmin(amount);
        vm.stopPrank();

        _stableDeposit(user1, 30_000e6);

        StableYieldEscrow escrow = StableYieldEscrow(stableEscrowAddress);
        uint256 expectedBal = escrow.getExpectedBalance();
        uint256 actualBal = escrow.getTotalBalance();

        assertEq(actualBal, expectedBal, "Actual and expected balance must match");
    }

    // ================================================================
    //  POOL PROTOCOL FUNDS SNAPSHOT
    // ================================================================

    function test_protocolFundsSnapshot_comprehensive() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();

        _seedYieldReserve(1_000_000e6);

        vm.startPrank(admin);
        lockedPoolManager.deployProtocolCapital(lockedPoolAddress, 100_000e6);
        stableYieldManager.deployProtocolCapital(stablePoolAddress, 200_000e6);
        vm.stopPrank();

        token.mint(admin, 50_000e6);
        vm.startPrank(admin);
        token.approve(lockedEscrowAddress, 50_000e6);
        LockedPoolEscrow(lockedEscrowAddress).receiveProtocolFundsFromAdmin(50_000e6);
        vm.stopPrank();

        YieldReserveEscrow.ProtocolFundsSnapshot memory snapshot = yieldReserve.getProtocolFundsSnapshot();

        assertEq(snapshot.totalDeployedViaReserve, 300_000e6, "300k deployed total");
        assertEq(snapshot.totalDirectDeposits, 50_000e6, "50k direct deposits");
        assertTrue(snapshot.grandTotal > 0, "Grand total should be positive");

        YieldReserveEscrow.PoolProtocolFunds memory lockedFunds = yieldReserve.getPoolProtocolFunds(lockedPoolAddress);
        assertEq(lockedFunds.fromReserve, 100_000e6, "Locked pool: 100k from reserve");
        assertEq(lockedFunds.directDeposit, 50_000e6, "Locked pool: 50k direct");

        YieldReserveEscrow.PoolProtocolFunds memory stableFunds = yieldReserve.getPoolProtocolFunds(stablePoolAddress);
        assertEq(stableFunds.fromReserve, 200_000e6, "Stable pool: 200k from reserve");
    }

    // ================================================================
    //  DEAL POOL FULL CYCLE (UNCHANGED)
    // ================================================================

    function test_integration_fullDealPoolCycle() public {
        (dealPoolAddress, dealEscrowAddress) = _createDealPool();
        
        _dealDeposit(user1, 50_000e6);
        _dealDeposit(user2, 30_000e6);
        _dealDeposit(user3, 20_000e6);
        
        skipTime(7 days + 1);
        vm.prank(operator);
        dealPoolManager.closeEpoch(dealPoolAddress);
        
        vm.prank(spv);
        dealPoolManager.withdrawFundsForInvestment(dealPoolAddress, 100_000e6);
        
        vm.prank(spv);
        dealPoolManager.processInvestment(dealPoolAddress, 100_000e6, "ipfs://proof");
        
        skipTime(90 days);
        
        uint256 faceValue = (uint256(100_000e6) * 10000) / 9500;
        
        vm.startPrank(spv);
        token.approve(address(dealPoolManager), faceValue);
        dealPoolManager.processMaturity(dealPoolAddress, faceValue);
        vm.stopPrank();
        
        uint256 user1BalBefore = token.balanceOf(user1);
        vm.prank(user1);
        LiquidityPool(dealPoolAddress).withdraw(50_000e6, user1, user1);
        
        assertTrue(token.balanceOf(user1) > user1BalBefore);
    }

    // ================================================================
    //  MULTIPLE POOL TYPES SIMULTANEOUSLY
    // ================================================================

    function test_multiplePoolTypes_simultaneous() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();
        (dealPoolAddress, dealEscrowAddress) = _createDealPool();
        
        vm.prank(operator);
        token.transfer(lockedEscrowAddress, 1_000_000e6);
        
        _lockedDeposit(user1, 30_000e6, 0);
        _stableDeposit(user1, 30_000e6);
        _dealDeposit(user1, 30_000e6);
        
        assertTrue(LockedPool(lockedPoolAddress).getUserPositions(user1).length > 0);
        assertTrue(StableYieldPool(stablePoolAddress).balanceOf(user1) > 0);
        assertTrue(LiquidityPool(dealPoolAddress).balanceOf(user1) > 0);
        
        assertTrue(registry.isRegisteredPool(lockedPoolAddress) || registry.isManagedPool(lockedPoolAddress));
        assertTrue(registry.isRegisteredPool(stablePoolAddress) || registry.isManagedPool(stablePoolAddress));
        assertTrue(registry.isRegisteredPool(dealPoolAddress));
    }

    // ================================================================
    //  STRESS TESTS
    // ================================================================

    function test_stress_manyLockedPositions() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();
        
        vm.prank(operator);
        token.transfer(lockedEscrowAddress, 100_000_000e6);
        
        uint256[] memory positions = new uint256[](50);
        for (uint i = 0; i < 50; i++) {
            address user = i % 3 == 0 ? user1 : (i % 3 == 1 ? user2 : user3);
            uint8 tier = uint8(i % 2);
            positions[i] = _lockedDeposit(user, 10_000e6, tier);
        }
        
        skipTime(90 days + 1);
        
        uint256[] memory maturableIds = new uint256[](25);
        uint256 count = 0;
        for (uint i = 0; i < 50; i++) {
            if (lockedPoolManager.getPosition(positions[i]).tierIndex == 0 && count < 25) {
                maturableIds[count] = positions[i];
                count++;
            }
        }
        
        vm.prank(operator);
        lockedPoolManager.batchMaturePositions(maturableIds);
    }

    function test_stress_manyStableYieldDeposits() public {
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();
        
        for (uint i = 0; i < 100; i++) {
            address user = i % 3 == 0 ? user1 : (i % 3 == 1 ? user2 : user3);
            _stableDeposit(user, 5_000e6);
        }
        
        uint256 totalAssets = StableYieldPool(stablePoolAddress).totalAssets();
        assertTrue(totalAssets > 400_000e6);
    }

    // ================================================================
    //  ACCESS MANAGER
    // ================================================================

    function test_accessManager_rolesConfigured() public {
        assertTrue(accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(accessManager.hasRole(accessManager.SPV_ROLE(), spv));
        assertTrue(accessManager.hasRole(accessManager.OPERATOR_ROLE(), operator));
        assertTrue(accessManager.hasRole(accessManager.EMERGENCY_ROLE(), emergency));
        assertTrue(accessManager.hasRole(accessManager.FACTORY_ROLE(), address(managedFactory)));
    }

    function test_accessManager_pauseSystem() public {
        vm.prank(emergency);
        accessManager.emergencyPause();
        assertTrue(accessManager.paused());

        vm.prank(admin);
        accessManager.emergencyUnpause();
        assertFalse(accessManager.paused());
    }

    function test_accessManager_renounceBlocked() public {
        bytes32 role = accessManager.OPERATOR_ROLE();
        vm.prank(operator);
        vm.expectRevert("AccessManager: renouncing roles is disabled");
        accessManager.renounceRole(role, operator);
    }

    // ================================================================
    //  NAV INCLUDES PENDING ALLOCATIONS
    // ================================================================

    function test_navIncludesPendingAllocations() public {
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();
        _stableDeposit(user1, 100_000e6);

        uint256 navBefore = stableYieldManager.calculatePoolNAV(stablePoolAddress);

        vm.prank(operator);
        stableYieldManager.createPendingAllocation(stablePoolAddress, spv, 50_000e6);

        uint256 navAfter = stableYieldManager.calculatePoolNAV(stablePoolAddress);
        assertApproxEqRel(navAfter, navBefore, 0.01e18, "NAV should include pending allocations");
    }

    // ================================================================
    //  COUPON FREQUENCY VALIDATION
    // ================================================================

    function test_couponFrequencyValidation() public {
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();
        _stableDeposit(user1, 100_000e6);

        vm.prank(operator);
        bytes32 allocId = stableYieldManager.createPendingAllocation(stablePoolAddress, spv, 50_000e6);

        vm.prank(spv);
        vm.expectRevert(StableYieldManager.InvalidCouponFrequency.selector);
        stableYieldManager.addInstrument(
            stablePoolAddress,
            allocId,
            IStableYieldTypes.InstrumentType.INTEREST_BEARING,
            50_000e6,
            50_000e6,
            block.timestamp + 365 days,
            500,
            0
        );
    }

    // ================================================================
    //  ESCROW YIELD RESERVE WIRING
    // ================================================================

    function test_escrow_yieldReserve_wiring() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();

        assertEq(
            LockedPoolEscrow(lockedEscrowAddress).yieldReserve(),
            address(yieldReserve),
            "Locked escrow yieldReserve must be set"
        );
        assertEq(
            StableYieldEscrow(stableEscrowAddress).yieldReserve(),
            address(yieldReserve),
            "Stable escrow yieldReserve must be set"
        );
    }

    // ================================================================
    //  ALL POOLS PROTOCOL FUNDS VIEW
    // ================================================================

    function test_getAllPoolsProtocolFunds() public {
        (lockedPoolAddress, lockedEscrowAddress) = _createLockedPool();
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();

        _seedYieldReserve(1_000_000e6);

        vm.startPrank(admin);
        lockedPoolManager.deployProtocolCapital(lockedPoolAddress, 100_000e6);
        stableYieldManager.deployProtocolCapital(stablePoolAddress, 200_000e6);
        vm.stopPrank();

        (
            address[] memory pools,
            uint256[] memory fromReserve,
            uint256[] memory directDeposits,
            ,
            uint256[] memory totals
        ) = yieldReserve.getAllPoolsProtocolFunds();

        assertTrue(pools.length >= 2, "Should track at least 2 pools");

        bool foundLocked = false;
        bool foundStable = false;
        for (uint i = 0; i < pools.length; i++) {
            if (pools[i] == lockedPoolAddress) {
                assertEq(fromReserve[i], 100_000e6);
                foundLocked = true;
            }
            if (pools[i] == stablePoolAddress) {
                assertEq(fromReserve[i], 200_000e6);
                foundStable = true;
            }
        }
        assertTrue(foundLocked && foundStable, "Both pools must be in the list");
    }


    // ==================== A MALFORMED INSTRUMENT CANNOT FREEZE NAV ====================

    /// @dev Already enforced in _addInstrumentWithAllocation; asserted here alongside the
    ///      rate check so both halves of the coupon config are covered.
    function test_stableYield_zeroCouponFrequency_isRejected() public {
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();
        _stableDeposit(user1, 100_000e6);

        vm.prank(operator);
        bytes32 allocId = stableYieldManager.createPendingAllocation(stablePoolAddress, spv, 50_000e6);

        vm.prank(spv);
        vm.expectRevert(StableYieldManager.InvalidCouponFrequency.selector);
        stableYieldManager.addInstrument(
            stablePoolAddress,
            allocId,
            IStableYieldTypes.InstrumentType.INTEREST_BEARING,
            50_000e6,
            50_000e6,
            block.timestamp + 90 days,
            800,
            0
        );
    }

    function test_stableYield_zeroCouponRate_isRejected() public {
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();
        _stableDeposit(user1, 100_000e6);

        vm.prank(operator);
        bytes32 allocId = stableYieldManager.createPendingAllocation(stablePoolAddress, spv, 50_000e6);

        vm.prank(spv);
        vm.expectRevert(StableYieldManager.InvalidCouponRate.selector);
        stableYieldManager.addInstrument(
            stablePoolAddress,
            allocId,
            IStableYieldTypes.InstrumentType.INTEREST_BEARING,
            50_000e6,
            50_000e6,
            block.timestamp + 90 days,
            0,
            4
        );
    }

    /// @dev A discounted instrument legitimately carries no coupon config.
    function test_stableYield_discountedNeedsNoCouponConfig() public {
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();
        _stableDeposit(user1, 100_000e6);

        vm.prank(operator);
        bytes32 allocId = stableYieldManager.createPendingAllocation(stablePoolAddress, spv, 50_000e6);

        vm.prank(spv);
        stableYieldManager.addInstrument(
            stablePoolAddress,
            allocId,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            50_000e6,
            52_500e6,
            block.timestamp + 90 days,
            0,
            0
        );

        assertGt(stableYieldManager.calculatePoolNAV(stablePoolAddress), 0, "NAV still computable");
    }

    /// @dev An admin can take a bad holding out of NAV without waiting for its maturity
    ///      or needing the SPV to return funds.
    function test_stableYield_writeOffInstrument_restoresNav() public {
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();
        _stableDeposit(user1, 100_000e6);

        vm.prank(operator);
        bytes32 allocId = stableYieldManager.createPendingAllocation(stablePoolAddress, spv, 50_000e6);

        vm.prank(spv);
        stableYieldManager.addInstrument(
            stablePoolAddress,
            allocId,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            50_000e6,
            52_500e6,
            block.timestamp + 90 days,
            0,
            0
        );

        uint256 navWithInstrument = stableYieldManager.calculatePoolNAV(stablePoolAddress);

        vm.prank(admin);
        stableYieldManager.writeOffInstrument(stablePoolAddress, 0);

        assertLt(
            stableYieldManager.calculatePoolNAV(stablePoolAddress),
            navWithInstrument,
            "written-off holding leaves NAV"
        );

        vm.prank(admin);
        vm.expectRevert(StableYieldManager.InstrumentNotActive.selector);
        stableYieldManager.writeOffInstrument(stablePoolAddress, 0);
    }

    function test_stableYield_writeOffInstrument_adminOnly() public {
        (stablePoolAddress, stableEscrowAddress) = _createStableYieldPool();
        _stableDeposit(user1, 100_000e6);

        vm.prank(operator);
        bytes32 allocId = stableYieldManager.createPendingAllocation(stablePoolAddress, spv, 50_000e6);
        vm.prank(spv);
        stableYieldManager.addInstrument(
            stablePoolAddress,
            allocId,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            50_000e6,
            52_500e6,
            block.timestamp + 90 days,
            0,
            0
        );

        vm.prank(operator);
        vm.expectRevert();
        stableYieldManager.writeOffInstrument(stablePoolAddress, 0);
    }

}
