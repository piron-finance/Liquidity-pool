// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./fixtures/BaseTest.sol";
import "../src/StableYieldManager.sol";
import "../src/PoolRegistry.sol";
import "../src/FeeManager.sol";
import "../src/escrows/YieldReserveEscrow.sol";
import "../src/factories/ManagedPoolFactory.sol";
import "../src/managed/StableYieldPool.sol";
import "../src/escrows/StableYieldEscrow.sol";
import "../src/AccessManager.sol";
import "../src/types/IStableYieldTypes.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract StableYieldPoolTest is BaseTest {
    
    AccessManager accessManager;
    PoolRegistry registry;
    StableYieldManager stableYieldManager;
    ManagedPoolFactory managedFactory;
    FeeManager feeManager;
    YieldReserveEscrow yieldReserve;
    MockERC20 token;
    
    address poolAddress;
    address escrowAddress;
    
    uint256 constant MIN_INVESTMENT = 1000e6;
    uint256 constant DEFAULT_FEE_BPS = 300;
    
    function setUp() public override {
        super.setUp();
        
        token = new MockERC20("Mock USDC", "USDC", 6);
        token.mint(user1, INITIAL_BALANCE);
        token.mint(user2, INITIAL_BALANCE);
        token.mint(user3, INITIAL_BALANCE);
        token.mint(spv, INITIAL_BALANCE * 10);
        
        accessManager = new AccessManager(admin, spv, operator, emergency, multisigAdmin);
        
        PoolRegistry registryImpl = new PoolRegistry();
        bytes memory registryInit = abi.encodeWithSignature(
            "initialize(address,address)",
            address(accessManager),
            admin
        );
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryInit);
        registry = PoolRegistry(address(registryProxy));
        
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
        
        StableYieldPool poolImpl = new StableYieldPool();
        StableYieldEscrow escrowImpl = new StableYieldEscrow();
        
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
        
        vm.startPrank(admin);
        registry.approveAsset(address(token), "Mock USDC", "USDC", true);
        stableYieldManager.setManagedPoolFactory(address(managedFactory));
        stableYieldManager.setYieldReserve(address(yieldReserve));
        managedFactory.setFeeManager(address(feeManager));
        managedFactory.setYieldReserve(address(yieldReserve));
        yieldReserve.setStableYieldManager(address(stableYieldManager));
        
        accessManager.grantRoleDuringDeployment(accessManager.POOL_CREATOR_ROLE(), address(stableYieldManager));
        accessManager.grantRoleDuringDeployment(accessManager.POOL_CREATOR_ROLE(), admin);
        accessManager.grantFactoryRoleDuringDeployment(address(managedFactory));
        accessManager.grantRoleDuringDeployment(accessManager.POOL_CREATOR_ROLE(), address(managedFactory));
        accessManager.grantRoleDuringDeployment(accessManager.OPERATOR_ROLE(), address(stableYieldManager));
        accessManager.grantRoleDuringDeployment(accessManager.OPERATOR_ROLE(), operator);
        vm.stopPrank();
    }
    
    function _createPool() internal returns (address, address) {
        ManagedPoolFactory.PoolDeploymentConfig memory config = ManagedPoolFactory.PoolDeploymentConfig({
            asset: address(token),
            poolName: "Test Stable Yield Pool",
            poolSymbol: "tSYP",
            spvAddress: spv,
            minInvestment: MIN_INVESTMENT
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
    
    function test_createPool_success() public {
        (poolAddress, escrowAddress) = _createPool();
        
        assertTrue(registry.isRegisteredPool(poolAddress), "Pool not registered");
        assertEq(StableYieldPool(poolAddress).asset(), address(token), "Wrong asset");
    }
    
    function test_deposit_success() public {
        (poolAddress, escrowAddress) = _createPool();
        
        uint256 depositAmount = 10_000e6;
        uint256 fee = (depositAmount * DEFAULT_FEE_BPS) / 10000;
        uint256 netDeposit = depositAmount - fee;
        
        _depositAs(user1, depositAmount);
        
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
        
        vm.prank(operator);
        stableYieldManager.allocateCapital(
            poolAddress,
            spv,
            50_000e6
        );
        
        vm.prank(spv);
        stableYieldManager.addInstrument(
            poolAddress,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            50_000e6,
            52_500e6,
            block.timestamp + 90 days,
            0,
            0
        );
        
        uint256 navAfter = stableYieldManager.calculatePoolNAV(poolAddress);
        
        assertTrue(navAfter >= navBefore, "NAV should not decrease");
    }
    
    function test_withdraw_afterHoldingPeriod() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        uint256 shares = StableYieldPool(poolAddress).balanceOf(user1);
        
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
        
        assertTrue(received > 0, "Should receive some tokens");
    }
    
    function test_allocateCapital_movesCashWithoutChangingNAV() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        uint256 navBefore = stableYieldManager.calculatePoolNAV(poolAddress);
        
        vm.prank(operator);
        stableYieldManager.allocateCapital(poolAddress, spv, 50_000e6);
        
        assertEq(stableYieldManager.getUndeployedCapital(poolAddress, spv), 50_000e6);
        assertEq(
            stableYieldManager.calculatePoolNAV(poolAddress),
            navBefore,
            "Drawing capital moves it between lines; it must not change NAV"
        );
        
        (uint256 deployed, uint256 reserves, uint256 undeployed) = stableYieldManager.getPoolCapital(poolAddress);
        assertEq(deployed + reserves + undeployed, navBefore, "Capital lines must sum to NAV");
    }
    
    function test_spvAllocation_addInstrument() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        vm.prank(operator);
        stableYieldManager.allocateCapital(
            poolAddress,
            spv,
            50_000e6
        );
        
        vm.prank(spv);
        stableYieldManager.addInstrument(
            poolAddress,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            50_000e6,
            52_500e6,
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
    
    function test_returnCapital_afterPartialDeployment() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        vm.prank(operator);
        stableYieldManager.allocateCapital(
            poolAddress,
            spv,
            50_000e6
        );
        
        vm.prank(spv);
        stableYieldManager.addInstrument(
            poolAddress,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            30_000e6,
            31_500e6,
            block.timestamp + 90 days,
            0,
            0
        );
        
        vm.startPrank(spv);
        token.approve(address(stableYieldManager), 20_000e6);
        stableYieldManager.returnCapital(poolAddress, 20_000e6);
        vm.stopPrank();
        
        assertEq(
            stableYieldManager.getUndeployedCapital(poolAddress, spv),
            0,
            "30k deployed and 20k returned leaves nothing undeployed"
        );
    }
    
    function test_instrumentMaturity_fullCycle() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        vm.prank(operator);
        stableYieldManager.allocateCapital(
            poolAddress,
            spv,
            50_000e6
        );
        
        vm.prank(spv);
        stableYieldManager.addInstrument(
            poolAddress,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            50_000e6,
            52_500e6,
            block.timestamp + 90 days,
            0,
            0
        );
        
        IStableYieldTypes.InstrumentHolding[] memory instrumentsBefore = 
            stableYieldManager.getPoolInstruments(poolAddress);
        assertEq(instrumentsBefore.length, 1, "Should have 1 instrument before maturity");
        assertTrue(instrumentsBefore[0].isActive, "Instrument should be active before maturity");
        
        skipTime(90 days + 1);
        
        vm.startPrank(spv);
        token.approve(address(stableYieldManager), 52_500e6);
        stableYieldManager.matureInstrumentWithFunds(poolAddress, 0, 52_500e6);
        vm.stopPrank();
        
        IStableYieldTypes.InstrumentHolding[] memory instrumentsAfter = 
            stableYieldManager.getPoolInstruments(poolAddress);
        
        assertEq(instrumentsAfter.length, 0, "Instrument should be removed after maturity");
    }
    
    function test_shareTransfer_resetsHoldingPeriod() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        skipTime(15 days);
        
        uint256 shares = StableYieldPool(poolAddress).balanceOf(user1);
        
        vm.prank(user1);
        require(StableYieldPool(poolAddress).transfer(user2, shares), "transfer failed");
        
        vm.prank(user2);
        vm.expectRevert("StableYieldPool/minimum holding period not met");
        StableYieldPool(poolAddress).redeem(shares, user2, user2);
        
        skipTime(30 days + 1);
        
        vm.prank(user2);
        StableYieldPool(poolAddress).redeem(shares, user2, user2);
    }
    
    function test_edgeCase_depositWhenNoLiquidity() public {
        (poolAddress, escrowAddress) = _createPool();
        
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
    
    /// @dev The SPV invests on its own schedule. Holding cash while waiting for an
    ///      instrument worth buying is expected, so capital carries no deadline.
    function test_capital_doesNotExpire() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        vm.prank(operator);
        stableYieldManager.allocateCapital(poolAddress, spv, 50_000e6);
        
        uint256 navBefore = stableYieldManager.calculatePoolNAV(poolAddress);
        
        skipTime(200 days);
        
        assertEq(
            stableYieldManager.getUndeployedCapital(poolAddress, spv),
            50_000e6,
            "Undeployed capital must survive any amount of waiting"
        );
        assertEq(stableYieldManager.calculatePoolNAV(poolAddress), navBefore, "NAV must not decay while capital waits");
        
        vm.prank(spv);
        stableYieldManager.addInstrument(
            poolAddress,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            50_000e6,
            52_500e6,
            block.timestamp + 90 days,
            0,
            0
        );
        
        assertEq(stableYieldManager.getUndeployedCapital(poolAddress, spv), 0);
    }
    
    function test_fee_customPoolFee() public {
        (poolAddress, escrowAddress) = _createPool();
        
        vm.prank(admin);
        stableYieldManager.setPoolTransactionFee(poolAddress, 500);
        
        uint256 depositAmount = 100_000e6;
        uint256 expectedFee = (depositAmount * 500) / 10000;
        
        _depositAs(user1, depositAmount);
        
        uint256 shares = StableYieldPool(poolAddress).balanceOf(user1);
        assertApproxEqRel(shares, depositAmount - expectedFee, 0.02e18);
    }
    
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
        
        assertApproxEqRel(navPerShare, 1e18, 0.01e18);
    }
    
    function test_queuedWithdrawal_collectsFees() public {
        (poolAddress, escrowAddress) = _createPool();
        
        uint256 depositAmount = 100_000e6;
        _depositAs(user1, depositAmount);
        
        skipTime(30 days + 1);
        
        uint256 shares = StableYieldPool(poolAddress).balanceOf(user1);
        uint256 user1BalanceBefore = token.balanceOf(user1);
        
        vm.prank(user1);
        StableYieldPool(poolAddress).redeem(shares, user1, user1);
        
        uint256 user1BalanceAfter = token.balanceOf(user1);
        uint256 received = user1BalanceAfter - user1BalanceBefore;
        
        uint256 expectedFee = (depositAmount * DEFAULT_FEE_BPS * 2) / 10000;
        assertTrue(received < depositAmount, "Withdrawal should have fees deducted");
    }
    
    function _seedYieldReserve(uint256 amount) internal {
        token.mint(address(stableYieldManager), amount);
        vm.startPrank(address(stableYieldManager));
        token.approve(address(yieldReserve), amount);
        yieldReserve.receiveYield(amount);
        vm.stopPrank();
    }

    // ==================== YIELD RESERVE TESTS ====================

    function test_deployProtocolCapital_toPool() public {
        (poolAddress, escrowAddress) = _createPool();

        _seedYieldReserve(500_000e6);

        uint256 deployAmount = 100_000e6;
        uint256 escrowReservesBefore = StableYieldEscrow(escrowAddress).getPoolReserves();

        vm.prank(admin);
        stableYieldManager.deployProtocolCapital(poolAddress, deployAmount);

        uint256 escrowReservesAfter = StableYieldEscrow(escrowAddress).getPoolReserves();
        StableYieldEscrow escrow = StableYieldEscrow(escrowAddress);

        assertEq(escrow.protocolFundsFromReserve(), deployAmount, "Protocol funds tracking should match");
        assertEq(token.balanceOf(escrowAddress) - escrowReservesBefore, deployAmount, "Escrow should receive capital");
    }

    function test_recallProtocolCapital_fromPool() public {
        (poolAddress, escrowAddress) = _createPool();

        _seedYieldReserve(500_000e6);

        vm.prank(admin);
        stableYieldManager.deployProtocolCapital(poolAddress, 100_000e6);

        uint256 reserveBalBefore = yieldReserve.getAvailableBalance();

        vm.prank(admin);
        stableYieldManager.recallProtocolCapital(poolAddress, 50_000e6);

        uint256 reserveBalAfter = yieldReserve.getAvailableBalance();
        assertEq(reserveBalAfter - reserveBalBefore, 50_000e6, "Reserve should receive recalled funds");

        StableYieldEscrow escrow = StableYieldEscrow(escrowAddress);
        assertEq(escrow.protocolFundsFromReserve(), 50_000e6, "Should reflect partial recall");
    }

    function test_withdrawalQueue_sourcesFromReserve() public {
        (poolAddress, escrowAddress) = _createPool();

        _depositAs(user1, 100_000e6);

        // Allocate most funds to SPV, leaving escrow short
        vm.prank(operator);
        stableYieldManager.allocateCapital(poolAddress, spv, 80_000e6);

        vm.prank(spv);
        stableYieldManager.addInstrument(
            poolAddress,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            80_000e6,
            84_000e6,
            block.timestamp + 90 days,
            0,
            0
        );

        // Seed yield reserve to backstop
        _seedYieldReserve(500_000e6);

        skipTime(30 days + 1);

        uint256 shares = StableYieldPool(poolAddress).balanceOf(user1);
        uint256 user1BalBefore = token.balanceOf(user1);

        // This should either process immediately or queue + get settled from reserve
        vm.prank(user1);
        StableYieldPool(poolAddress).redeem(shares, user1, user1);

        // Check if queued
        (uint256 head, uint256 tail,,) = stableYieldManager.getWithdrawalQueueStatus(poolAddress);

        if (tail > head) {
            // Was queued; settle from reserve
            uint256[] memory requestIds = new uint256[](1);
            requestIds[0] = head;

            vm.prank(operator);
            stableYieldManager.settleWithdrawals(poolAddress, requestIds);
        }

        uint256 user1BalAfter = token.balanceOf(user1);
        assertTrue(user1BalAfter > user1BalBefore, "User should receive funds even when escrow is short");
    }

    function test_escrowAuthorized_afterPoolCreation() public {
        (poolAddress, escrowAddress) = _createPool();

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
        StableYieldEscrow(escrowAddress).receiveProtocolFundsFromAdmin(depositAmount);
        vm.stopPrank();

        StableYieldEscrow escrow = StableYieldEscrow(escrowAddress);
        assertEq(escrow.protocolFundsDirectDeposit(), depositAmount, "Direct deposit tracked on escrow");

        assertEq(
            yieldReserve.directDepositsToPool(poolAddress),
            depositAmount,
            "Reserve should track direct deposit"
        );
    }

    function test_isReadyForAllocation_accountsForPendingWithdrawals() public {
        (poolAddress, escrowAddress) = _createPool();
        
        uint256 depositAmount = 1_000_000e6;
        _depositAs(user1, depositAmount);
        _depositAs(user2, depositAmount);
        
        skipTime(30 days + 1);
        
        (bool readyBefore, uint256 availableBefore) = stableYieldManager.isReadyForAllocation(poolAddress);
        assertTrue(readyBefore, "Should be ready for allocation after deposits");
        assertTrue(availableBefore > 0, "Should have funds available for allocation");
        
        uint256 user1Shares = StableYieldPool(poolAddress).balanceOf(user1);
        vm.prank(user1);
        StableYieldPool(poolAddress).redeem(user1Shares, user1, user1);
        
        (bool readyAfter, uint256 availableAfter) = stableYieldManager.isReadyForAllocation(poolAddress);
        
        assertTrue(availableAfter < availableBefore, "Available should decrease after withdrawal");
    }

    // ==================== FULL INSTRUMENT LIFECYCLE WITH RESERVE ====================

    function test_fullInstrumentCycle_discountedWithReserveCapital() public {
        (poolAddress, escrowAddress) = _createPool();

        _seedYieldReserve(300_000e6);

        vm.prank(admin);
        stableYieldManager.deployProtocolCapital(poolAddress, 100_000e6);

        _depositAs(user1, 100_000e6);

        vm.prank(operator);
        stableYieldManager.allocateCapital(poolAddress, spv, 80_000e6);

        vm.prank(spv);
        stableYieldManager.addInstrument(
            poolAddress,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            80_000e6,
            84_000e6,
            block.timestamp + 90 days,
            0,
            0
        );

        skipTime(90 days + 1);

        vm.startPrank(spv);
        token.approve(address(stableYieldManager), 84_000e6);
        stableYieldManager.matureInstrumentWithFunds(poolAddress, 0, 84_000e6);
        vm.stopPrank();

        IStableYieldTypes.InstrumentHolding[] memory instruments = stableYieldManager.getPoolInstruments(poolAddress);
        assertEq(instruments.length, 0, "Instrument should be removed after maturity");

        vm.prank(admin);
        stableYieldManager.recallProtocolCapital(poolAddress, 100_000e6);

        StableYieldEscrow escrow = StableYieldEscrow(escrowAddress);
        assertEq(escrow.protocolFundsFromReserve(), 0, "All protocol capital recalled");
    }

    function test_interestBearingInstrument_multipleCoupons() public {
        (poolAddress, escrowAddress) = _createPool();
        _depositAs(user1, 200_000e6);

        vm.prank(operator);
        stableYieldManager.allocateCapital(poolAddress, spv, 100_000e6);

        vm.prank(spv);
        stableYieldManager.addInstrument(
            poolAddress,
            IStableYieldTypes.InstrumentType.INTEREST_BEARING,
            100_000e6,
            100_000e6,
            block.timestamp + 365 days,
            800,
            4
        );

        uint256 couponAmount = 2_000e6;

        for (uint i = 0; i < 3; i++) {
            vm.warp(block.timestamp + 92 days);
            token.mint(spv, couponAmount);
            vm.startPrank(spv);
            token.approve(address(stableYieldManager), couponAmount);
            stableYieldManager.recordCouponPayment(poolAddress, 0, couponAmount);
            vm.stopPrank();
        }

        IStableYieldTypes.InstrumentHolding memory instrument = stableYieldManager.getInstrument(poolAddress, 0);
        assertEq(instrument.couponsPaid, 3, "Should have recorded 3 coupon payments");
    }

    // ==================== WITHDRAWAL QUEUE WITH RESERVE BACKSTOP ====================

    function test_withdrawalQueue_multipleUsers_settledFromReserve() public {
        (poolAddress, escrowAddress) = _createPool();

        _depositAs(user1, 50_000e6);
        _depositAs(user2, 50_000e6);
        _depositAs(user3, 50_000e6);

        vm.prank(operator);
        stableYieldManager.allocateCapital(poolAddress, spv, 120_000e6);

        vm.prank(spv);
        stableYieldManager.addInstrument(
            poolAddress,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            120_000e6,
            126_000e6,
            block.timestamp + 90 days,
            0,
            0
        );

        _seedYieldReserve(1_000_000e6);

        skipTime(30 days + 1);

        uint256 shares1 = StableYieldPool(poolAddress).balanceOf(user1);
        uint256 shares2 = StableYieldPool(poolAddress).balanceOf(user2);

        vm.prank(user1);
        StableYieldPool(poolAddress).redeem(shares1, user1, user1);

        vm.prank(user2);
        StableYieldPool(poolAddress).redeem(shares2, user2, user2);

        (uint256 head, uint256 tail,,) = stableYieldManager.getWithdrawalQueueStatus(poolAddress);

        if (tail > head) {
            uint256 count = tail - head;
            uint256[] memory ids = new uint256[](count);
            for (uint256 i = 0; i < count; i++) {
                ids[i] = head + i;
            }
            vm.prank(operator);
            stableYieldManager.settleWithdrawals(poolAddress, ids);
        }

        assertTrue(token.balanceOf(user1) > 0, "User1 should be paid");
        assertTrue(token.balanceOf(user2) > 0, "User2 should be paid");
    }

    function test_withdrawalQueue_processQueue_fromReserve() public {
        (poolAddress, escrowAddress) = _createPool();

        _depositAs(user1, 100_000e6);

        vm.prank(operator);
        stableYieldManager.allocateCapital(poolAddress, spv, 80_000e6);

        vm.prank(spv);
        stableYieldManager.addInstrument(
            poolAddress,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            80_000e6,
            84_000e6,
            block.timestamp + 90 days,
            0,
            0
        );

        _seedYieldReserve(500_000e6);

        skipTime(30 days + 1);

        uint256 shares = StableYieldPool(poolAddress).balanceOf(user1);
        uint256 balBefore = token.balanceOf(user1);

        vm.prank(user1);
        StableYieldPool(poolAddress).redeem(shares, user1, user1);

        (uint256 head, uint256 tail,,) = stableYieldManager.getWithdrawalQueueStatus(poolAddress);

        if (tail > head) {
            vm.prank(operator);
            stableYieldManager.processWithdrawalQueue(poolAddress, 10);
        }

        uint256 balAfter = token.balanceOf(user1);
        assertTrue(balAfter > balBefore, "User should receive funds");
    }

    // ==================== RETURN UNUSED FUNDS ====================

    function test_returnUnusedFunds_fullReturn() public {
        (poolAddress, escrowAddress) = _createPool();
        _depositAs(user1, 100_000e6);

        vm.prank(operator);
        stableYieldManager.allocateCapital(poolAddress, spv, 50_000e6);

        uint256 reservesBefore = StableYieldEscrow(escrowAddress).getPoolReserves();

        vm.startPrank(spv);
        token.approve(address(stableYieldManager), 50_000e6);
        stableYieldManager.returnCapital(poolAddress, 50_000e6);
        vm.stopPrank();

        uint256 reservesAfter = StableYieldEscrow(escrowAddress).getPoolReserves();
        assertEq(reservesAfter - reservesBefore, 50_000e6, "Full return should restore reserves");

        assertEq(stableYieldManager.getUndeployedCapital(poolAddress, spv), 0, "Nothing left undeployed");
    }

    // ==================== ESCROW BALANCE INTEGRITY ====================

    function test_escrowBalanceIntegrity_afterMultipleOps() public {
        (poolAddress, escrowAddress) = _createPool();

        _seedYieldReserve(500_000e6);

        vm.prank(admin);
        stableYieldManager.deployProtocolCapital(poolAddress, 100_000e6);

        uint256 directDeposit = 50_000e6;
        token.mint(admin, directDeposit);
        vm.startPrank(admin);
        token.approve(escrowAddress, directDeposit);
        StableYieldEscrow(escrowAddress).receiveProtocolFundsFromAdmin(directDeposit);
        vm.stopPrank();

        _depositAs(user1, 50_000e6);

        StableYieldEscrow escrow = StableYieldEscrow(escrowAddress);
        uint256 expected = escrow.getExpectedBalance();
        uint256 actual = escrow.getTotalBalance();
        assertEq(actual, expected, "Balance accounting must match");
    }

    // ==================== ADMIN DIRECT DEPOSIT ====================

    function test_adminDirectDeposit_releaseTracking() public {
        (poolAddress, escrowAddress) = _createPool();

        uint256 depositAmt = 50_000e6;
        token.mint(admin, depositAmt);

        vm.startPrank(admin);
        token.approve(escrowAddress, depositAmt);
        StableYieldEscrow(escrowAddress).receiveProtocolFundsFromAdmin(depositAmt);
        vm.stopPrank();

        assertEq(yieldReserve.directDepositsToPool(poolAddress), depositAmt, "Reserve tracks direct deposit");

        vm.prank(admin);
        StableYieldEscrow(escrowAddress).releaseDirectDepositFunds(treasury, 20_000e6);

        assertEq(yieldReserve.directDepositsToPool(poolAddress), 30_000e6, "Reserve updates after release");
        assertEq(StableYieldEscrow(escrowAddress).protocolFundsDirectDeposit(), 30_000e6, "Escrow updates after release");
    }

    // ==================== NAV WITH PROTOCOL CAPITAL ====================

    function test_nav_withProtocolCapital() public {
        (poolAddress, escrowAddress) = _createPool();

        _seedYieldReserve(500_000e6);

        vm.prank(admin);
        stableYieldManager.deployProtocolCapital(poolAddress, 100_000e6);

        _depositAs(user1, 100_000e6);

        uint256 nav = stableYieldManager.calculatePoolNAV(poolAddress);
        assertTrue(nav > 0, "NAV should be positive with deposits and protocol capital");

        uint256 navPerShare = StableYieldPool(poolAddress).getNAVPerShare();
        assertTrue(navPerShare >= 1e18, "NAV per share should be >= 1.0");
    }

    // ==================== END-TO-END: DEPOSIT -> ALLOCATE -> MATURE -> WITHDRAW ====================

    function test_endToEnd_depositAllocateMatureWithdraw() public {
        (poolAddress, escrowAddress) = _createPool();

        _depositAs(user1, 100_000e6);
        _depositAs(user2, 50_000e6);

        vm.prank(operator);
        stableYieldManager.allocateCapital(poolAddress, spv, 80_000e6);

        vm.prank(spv);
        stableYieldManager.addInstrument(
            poolAddress,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            80_000e6,
            84_000e6,
            block.timestamp + 90 days,
            0,
            0
        );

        skipTime(90 days + 1);

        vm.startPrank(spv);
        token.approve(address(stableYieldManager), 84_000e6);
        stableYieldManager.matureInstrumentWithFunds(poolAddress, 0, 84_000e6);
        vm.stopPrank();

        skipTime(30 days);

        uint256 user1Shares = StableYieldPool(poolAddress).balanceOf(user1);
        uint256 user1BalBefore = token.balanceOf(user1);

        vm.prank(user1);
        StableYieldPool(poolAddress).redeem(user1Shares, user1, user1);

        assertTrue(token.balanceOf(user1) > user1BalBefore, "User should withdraw with yield");

        uint256 user2Shares = StableYieldPool(poolAddress).balanceOf(user2);
        uint256 user2BalBefore = token.balanceOf(user2);

        vm.prank(user2);
        StableYieldPool(poolAddress).redeem(user2Shares, user2, user2);

        assertTrue(token.balanceOf(user2) > user2BalBefore, "User2 should withdraw with yield");
    }

    function test_allocationRemainder_strandedAfterPartialDeployment() public {
        (poolAddress, escrowAddress) = _createPool();

        _depositAs(user1, 100_000e6);

        vm.prank(operator);
        stableYieldManager.allocateCapital(
            poolAddress,
            spv,
            50_000e6
        );

        vm.prank(spv);
        stableYieldManager.addInstrument(
            poolAddress,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            30_000e6,
            31_500e6,
            block.timestamp + 90 days,
            0,
            0
        );

        uint256 navBefore = stableYieldManager.calculatePoolNAV(poolAddress);

        skipTime(90 days + 1);

        vm.startPrank(spv);
        token.approve(address(stableYieldManager), 31_500e6);
        stableYieldManager.matureInstrumentWithFunds(poolAddress, 0, 31_500e6);
        vm.stopPrank();

        uint256 navAfter = stableYieldManager.calculatePoolNAV(poolAddress);

        // The instrument returned 31_500 against a 30_000 cost, so NAV should rise
        // by the 1_500 of realised yield. The 20_000 still sitting with the SPV is
        // untouched by this maturity and must remain in NAV either way.
        assertGe(navAfter, navBefore, "NAV must not fall when an instrument matures at a profit");
    }

    function test_allocationRemainder_returnableAfterPartialDeployment() public {
        (poolAddress, escrowAddress) = _createPool();

        _depositAs(user1, 100_000e6);

        vm.prank(operator);
        stableYieldManager.allocateCapital(
            poolAddress,
            spv,
            50_000e6
        );

        vm.prank(spv);
        stableYieldManager.addInstrument(
            poolAddress,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            30_000e6,
            31_500e6,
            block.timestamp + 90 days,
            0,
            0
        );

        skipTime(90 days + 1);

        vm.startPrank(spv);
        token.approve(address(stableYieldManager), 31_500e6);
        stableYieldManager.matureInstrumentWithFunds(poolAddress, 0, 31_500e6);
        vm.stopPrank();

        // The 20_000 the SPV never deployed is still theirs to hand back.
        vm.startPrank(spv);
        token.approve(address(stableYieldManager), 20_000e6);
        stableYieldManager.returnCapital(poolAddress, 20_000e6);
        vm.stopPrank();
    }


    // ==================== INSTRUMENT WRITE-OFF ====================

    /// @dev A defaulted instrument keeps carrying value until it is written off, so holders
    ///      would redeem against assets the pool will never receive.
    function test_writeOffInstrument_removesValueFromNAV() public {
        (poolAddress, escrowAddress) = _createPool();
        _depositAs(user1, 100_000e6);

        vm.prank(operator);
        stableYieldManager.allocateCapital(poolAddress, spv, 50_000e6);

        vm.prank(spv);
        stableYieldManager.addInstrument(
            poolAddress,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            50_000e6,
            52_500e6,
            block.timestamp + 90 days,
            0,
            0
        );

        uint256 navBefore = stableYieldManager.calculatePoolNAV(poolAddress);

        vm.prank(admin);
        stableYieldManager.writeOffInstrument(poolAddress, 0, "issuer default");

        uint256 navAfter = stableYieldManager.calculatePoolNAV(poolAddress);

        assertEq(
            navBefore - navAfter,
            50_000e6,
            "NAV must drop by the written-off instrument's marked value"
        );
        assertEq(stableYieldManager.getPoolInstruments(poolAddress).length, 0);
    }

    function test_writeOffInstrument_adminOnly() public {
        (poolAddress, escrowAddress) = _createPool();
        _depositAs(user1, 100_000e6);

        vm.prank(operator);
        stableYieldManager.allocateCapital(poolAddress, spv, 50_000e6);

        vm.prank(spv);
        stableYieldManager.addInstrument(
            poolAddress,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            50_000e6,
            52_500e6,
            block.timestamp + 90 days,
            0,
            0
        );

        vm.prank(spv);
        vm.expectRevert();
        stableYieldManager.writeOffInstrument(poolAddress, 0, "not mine to call");

        vm.prank(operator);
        vm.expectRevert();
        stableYieldManager.writeOffInstrument(poolAddress, 0, "not mine either");
    }

    // ==================== EMERGENCY REDEEM ====================

    /// @dev The operator acts on a holder's behalf. Proceeds must reach the holder, or the
    ///      call is a way to burn anyone's shares and take the assets.
    function test_emergencyRedeem_paysTheHolder() public {
        (poolAddress, escrowAddress) = _createPool();
        _depositAs(user1, 100_000e6);

        skipTime(stableYieldPool().getMinimumHoldingPeriod() + 1);

        uint256 shares = IERC20(poolAddress).balanceOf(user1);
        uint256 userBefore = token.balanceOf(user1);
        uint256 operatorBefore = token.balanceOf(operator);

        vm.prank(operator);
        stableYieldPool().emergencyRedeem(shares, user1);

        assertGt(token.balanceOf(user1), userBefore, "Holder must receive the proceeds");
        assertEq(token.balanceOf(operator), operatorBefore, "Operator must receive nothing");
        assertEq(IERC20(poolAddress).balanceOf(user1), 0, "Shares burned");
    }

    // ==================== CAPITAL ACCOUNTING INVARIANT ====================

    /// @dev The three capital lines must sum to NAV at every point of the cycle, whatever
    ///      the SPV is doing with the cash.
    function test_capitalLines_sumToNAVThroughoutCycle() public {
        (poolAddress, escrowAddress) = _createPool();
        _depositAs(user1, 100_000e6);

        _assertCapitalSumsToNAV("after deposit");

        vm.prank(operator);
        stableYieldManager.allocateCapital(poolAddress, spv, 60_000e6);
        _assertCapitalSumsToNAV("after allocation");

        vm.prank(spv);
        stableYieldManager.addInstrument(
            poolAddress,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            40_000e6,
            42_000e6,
            block.timestamp + 90 days,
            0,
            0
        );
        _assertCapitalSumsToNAV("after partial deployment");

        vm.startPrank(spv);
        token.approve(address(stableYieldManager), 20_000e6);
        stableYieldManager.returnCapital(poolAddress, 20_000e6);
        vm.stopPrank();
        _assertCapitalSumsToNAV("after returning the remainder");

        skipTime(90 days + 1);
        vm.startPrank(spv);
        token.approve(address(stableYieldManager), 42_000e6);
        stableYieldManager.matureInstrumentWithFunds(poolAddress, 0, 42_000e6);
        vm.stopPrank();
        _assertCapitalSumsToNAV("after maturity");
    }

    function _assertCapitalSumsToNAV(string memory stage) internal view {
        (uint256 deployed, uint256 reserves, uint256 undeployed) =
            stableYieldManager.getPoolCapital(poolAddress);
        assertEq(
            deployed + reserves + undeployed,
            stableYieldManager.calculatePoolNAV(poolAddress),
            stage
        );
    }

    // ==================== YIELD RESERVE ====================

    /// @dev The reserve pools protocol capital for every pool, so an outbound transfer must
    ///      land on an escrow the protocol knows about, not one the caller names.
    function test_yieldReserve_deployRejectsUnauthorizedEscrow() public {
        (poolAddress, escrowAddress) = _createPool();
        _seedYieldReserve(100_000e6);

        address attackerEscrow = makeAddr("attackerEscrow");

        vm.prank(operator);
        vm.expectRevert("YieldReserveEscrow/unauthorized escrow");
        yieldReserve.deployToPool(poolAddress, attackerEscrow, 100_000e6);
    }

    /// @dev FeeManager.distributeFees sends the reserve its share with a bare transfer, and
    ///      early-exit penalties route 100% here by default. Without a sync those funds are
    ///      invisible to every path that checks totalBalance.
    function test_yieldReserve_syncCreditsBareTransfers() public {
        _seedYieldReserve(50_000e6);

        uint256 balanceBefore = yieldReserve.getAvailableBalance();

        token.mint(address(this), 25_000e6);
        token.transfer(address(yieldReserve), 25_000e6);

        assertEq(
            yieldReserve.getAvailableBalance(),
            balanceBefore,
            "A bare transfer must not be counted until it is synced"
        );
        assertEq(yieldReserve.getUntrackedFunds(), 25_000e6);

        vm.prank(operator);
        yieldReserve.syncUntrackedFunds();

        assertEq(yieldReserve.getAvailableBalance(), balanceBefore + 25_000e6);
        assertEq(yieldReserve.getUntrackedFunds(), 0);
    }

    function stableYieldPool() internal view returns (StableYieldPool) {
        return StableYieldPool(poolAddress);
    }

}
