// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./fixtures/BaseTest.sol";
import "../src/FeeManager.sol";
import "../src/escrows/YieldReserveEscrow.sol";
import "../src/PoolRegistry.sol";
import "../src/AccessManager.sol";
import "../src/interfaces/IFeeManager.sol";
import "../src/types/IStableYieldTypes.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract FeeManagerTest is BaseTest {
    
    AccessManager accessManager;
    PoolRegistry registry;
    FeeManager feeManager;
    YieldReserveEscrow yieldReserve;
    MockERC20 token;
    
    address mockPool;
    address mockEscrow;
    
    uint256 constant DEFAULT_TREASURY_BPS = 6000;
    uint256 constant MIN_RESERVE_FLOOR = 10_000e6;
    
    function setUp() public override {
        super.setUp();
        
        token = new MockERC20("Mock USDC", "USDC", 6);
        token.mint(admin, INITIAL_BALANCE * 10);
        token.mint(operator, INITIAL_BALANCE * 10);
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
            DEFAULT_TREASURY_BPS,
            MIN_RESERVE_FLOOR
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
            operator
        );
        ERC1967Proxy feeManagerProxy = new ERC1967Proxy(address(feeManagerImpl), feeManagerInit);
        feeManager = FeeManager(address(feeManagerProxy));
        
        mockPool = makeAddr("mockPool");
        mockEscrow = makeAddr("mockEscrow");
        
        vm.startPrank(admin);
        
        registry.approveAsset(address(token), "Mock USDC", "USDC", true);
        
        IStableYieldTypes.PoolData memory poolData = IStableYieldTypes.PoolData({
            poolAddress: mockPool,
            escrowAddress: mockEscrow,
            asset: address(token),
            name: "Test Pool",
            minInvestment: 1000e6,
            isActive: true,
            createdAt: block.timestamp
        });
        registry.registerStableYieldPool(poolData);
        
        feeManager.authorizeCollector(mockEscrow, true);
        
        vm.stopPrank();
        
        token.mint(mockEscrow, INITIAL_BALANCE);
        vm.prank(mockEscrow);
        token.approve(address(feeManager), type(uint256).max);
    }
    
    function test_collectFee_depositFee() public {
        uint256 feeAmount = 1000e6;
        
        vm.prank(mockEscrow);
        feeManager.collectFee(mockPool, address(token), feeAmount, IFeeManager.FeeType.DEPOSIT_FEE);
        
        (uint256 treasuryPending, uint256 reservePending, uint256 opsPending) = 
            feeManager.getPendingDistributions(address(token));
        
        assertEq(treasuryPending, feeAmount, "All should go to treasury");
        assertEq(reservePending, 0);
        assertEq(opsPending, 0);
    }
    
    function test_collectFee_earlyExitPenalty() public {
        uint256 feeAmount = 5000e6;
        
        vm.prank(mockEscrow);
        feeManager.collectFee(mockPool, address(token), feeAmount, IFeeManager.FeeType.EARLY_EXIT_PENALTY);
        
        (uint256 treasuryPending, uint256 reservePending, uint256 opsPending) = 
            feeManager.getPendingDistributions(address(token));
        
        assertEq(treasuryPending, 0);
        assertEq(reservePending, feeAmount, "All should go to reserve");
        assertEq(opsPending, 0);
    }
    
    function test_collectFee_unauthorizedCollector_reverts() public {
        vm.prank(user1);
        vm.expectRevert("FeeManager/unauthorized collector");
        feeManager.collectFee(mockPool, address(token), 1000e6, IFeeManager.FeeType.DEPOSIT_FEE);
    }
    
    function test_recordFeeOnly_success() public {
        uint256 feeAmount = 2000e6;
        
        vm.prank(mockEscrow);
        token.transfer(address(feeManager), feeAmount);
        
        vm.prank(mockEscrow);
        feeManager.recordFeeOnly(mockPool, address(token), feeAmount, IFeeManager.FeeType.WITHDRAWAL_FEE);
        
        (uint256 treasuryPending,,) = feeManager.getPendingDistributions(address(token));
        assertEq(treasuryPending, feeAmount);
    }
    
    function test_distributeFees_success() public {
        uint256 feeAmount = 10_000e6;
        
        vm.prank(mockEscrow);
        feeManager.collectFee(mockPool, address(token), feeAmount, IFeeManager.FeeType.DEPOSIT_FEE);
        
        uint256 treasuryBefore = token.balanceOf(treasury);
        
        vm.prank(admin);
        feeManager.distributeFees(address(token));
        
        uint256 treasuryAfter = token.balanceOf(treasury);
        assertEq(treasuryAfter - treasuryBefore, feeAmount);
        
        (uint256 treasuryPending,,) = feeManager.getPendingDistributions(address(token));
        assertEq(treasuryPending, 0);
    }
    
    function test_distributeFees_customSplit() public {
        vm.prank(admin);
        feeManager.setFeeSplit(IFeeManager.FeeType.DEPOSIT_FEE, 5000, 3000, 2000, true);
        
        uint256 feeAmount = 10_000e6;
        
        vm.prank(mockEscrow);
        feeManager.collectFee(mockPool, address(token), feeAmount, IFeeManager.FeeType.DEPOSIT_FEE);
        
        (uint256 treasuryPending, uint256 reservePending, uint256 opsPending) = 
            feeManager.getPendingDistributions(address(token));
        
        assertEq(treasuryPending, 5000e6);
        assertEq(reservePending, 3000e6);
        assertEq(opsPending, 2000e6);
    }
    
    function test_distributeFees_whenPaused_reverts() public {
        vm.prank(mockEscrow);
        feeManager.collectFee(mockPool, address(token), 1000e6, IFeeManager.FeeType.DEPOSIT_FEE);
        
        vm.prank(admin);
        feeManager.pauseDistributions();
        
        vm.prank(admin);
        vm.expectRevert("FeeManager/distribution paused");
        feeManager.distributeFees(address(token));
    }
    
    function test_pausePoolFees() public {
        vm.prank(operator);
        feeManager.pausePoolFees(mockPool);
        
        assertTrue(feeManager.poolFeePaused(mockPool));
        
        vm.prank(mockEscrow);
        vm.expectRevert("FeeManager/pool fees paused");
        feeManager.collectFee(mockPool, address(token), 1000e6, IFeeManager.FeeType.DEPOSIT_FEE);
    }
    
    function test_unpausePoolFees() public {
        vm.prank(operator);
        feeManager.pausePoolFees(mockPool);
        
        vm.prank(operator);
        feeManager.unpausePoolFees(mockPool);
        
        assertFalse(feeManager.poolFeePaused(mockPool));
        
        vm.prank(mockEscrow);
        feeManager.collectFee(mockPool, address(token), 1000e6, IFeeManager.FeeType.DEPOSIT_FEE);
    }
    
    function test_setFeeSplit_invalidSplit_reverts() public {
        vm.prank(admin);
        vm.expectRevert("FeeManager/invalid fee split");
        feeManager.setFeeSplit(IFeeManager.FeeType.DEPOSIT_FEE, 5000, 3000, 1000, true);
    }
    
    function test_setFeeSplit_recordsHistory() public {
        vm.prank(admin);
        feeManager.setFeeSplit(IFeeManager.FeeType.DEPOSIT_FEE, 6000, 3000, 1000, true);
        
        assertEq(feeManager.getFeeRateHistoryCount(), 1);
        
        IFeeManager.FeeRateChange[] memory history = feeManager.getFeeRateHistory();
        assertEq(history[0].newTreasuryBps, 6000);
    }
    
    function test_authorizeCollector() public {
        address newCollector = makeAddr("newCollector");
        
        vm.prank(admin);
        feeManager.authorizeCollector(newCollector, true);
        
        assertTrue(feeManager.isAuthorizedCollector(newCollector));
    }
    
    function test_deauthorizeCollector() public {
        vm.prank(admin);
        feeManager.authorizeCollector(mockEscrow, false);
        
        assertFalse(feeManager.isAuthorizedCollector(mockEscrow));
    }
    
    function test_getAssetStats() public {
        vm.prank(mockEscrow);
        feeManager.collectFee(mockPool, address(token), 5000e6, IFeeManager.FeeType.DEPOSIT_FEE);
        
        (uint256 totalCollected,, uint256 treasuryCollected,,) = 
            feeManager.getAssetStats(address(token));
        
        assertEq(totalCollected, 5000e6);
        assertEq(treasuryCollected, 5000e6);
    }
    
    function test_getPoolFeeStats() public {
        vm.prank(mockEscrow);
        feeManager.collectFee(mockPool, address(token), 3000e6, IFeeManager.FeeType.DEPOSIT_FEE);
        
        vm.prank(mockEscrow);
        feeManager.collectFee(mockPool, address(token), 2000e6, IFeeManager.FeeType.WITHDRAWAL_FEE);
        
        (uint256 totalCollected, uint256[] memory byFeeType) = 
            feeManager.getPoolFeeStats(mockPool, address(token));
        
        assertEq(totalCollected, 5000e6);
        assertEq(byFeeType[uint256(IFeeManager.FeeType.DEPOSIT_FEE)], 3000e6);
        assertEq(byFeeType[uint256(IFeeManager.FeeType.WITHDRAWAL_FEE)], 2000e6);
    }
    
    function _setupYieldReserve() internal {
        vm.prank(admin);
        token.transfer(address(yieldReserve), 100_000e6);
        
        vm.prank(admin);
        yieldReserve.setLockedPoolManager(address(this));
        
        vm.prank(admin);
        yieldReserve.authorizeEscrow(mockEscrow, true);
    }
    
    function test_receiveYield_splitCorrectly() public {
        _setupYieldReserve();
        
        uint256 yieldAmount = 10_000e6;
        
        token.mint(address(this), yieldAmount);
        
        token.approve(address(yieldReserve), yieldAmount);
        
        uint256 treasuryBefore = token.balanceOf(treasury);
        
        yieldReserve.receiveYield(yieldAmount);
        
        uint256 treasuryAfter = token.balanceOf(treasury);
        
        assertEq(treasuryAfter - treasuryBefore, (yieldAmount * DEFAULT_TREASURY_BPS) / 10000);
    }
    
    function test_deployToPool() public {
        _setupYieldReserve();
        
        uint256 fundAmount = 50_000e6;
        
        vm.prank(admin);
        token.transfer(address(yieldReserve), fundAmount);
        
        vm.prank(address(this));
        yieldReserve.recordYield(fundAmount);
        
        uint256 deployAmount = 20_000e6;
        uint256 escrowBefore = token.balanceOf(mockEscrow);
        
        vm.prank(operator);
        yieldReserve.deployToPool(mockPool, mockEscrow, deployAmount);
        
        uint256 escrowAfter = token.balanceOf(mockEscrow);
        assertEq(escrowAfter - escrowBefore, deployAmount);
        assertEq(yieldReserve.deployedToPool(mockPool), deployAmount);
    }
    
    function test_loanToPool() public {
        _setupYieldReserve();
        
        uint256 fundAmount = 50_000e6;
        vm.prank(admin);
        token.transfer(address(yieldReserve), fundAmount);
        
        vm.prank(address(this));
        yieldReserve.recordYield(fundAmount);
        
        uint256 loanAmount = 10_000e6;
        uint256 positionId = 1;
        
        vm.prank(address(this));
        yieldReserve.loanToPool(mockPool, positionId, loanAmount, mockPool);
        
        assertEq(yieldReserve.getPoolLoan(mockPool), loanAmount);
        assertEq(yieldReserve.getPositionLoan(positionId), loanAmount);
        assertEq(yieldReserve.getTotalLoaned(), loanAmount);
    }
    
    function test_repayLoan() public {
        _setupYieldReserve();
        
        uint256 fundAmount = 50_000e6;
        vm.prank(admin);
        token.transfer(address(yieldReserve), fundAmount);
        
        yieldReserve.recordYield(fundAmount);
        
        uint256 loanAmount = 10_000e6;
        uint256 positionId = 1;
        
        yieldReserve.loanToPool(mockPool, positionId, loanAmount, mockPool);
        
        token.mint(address(this), loanAmount);
        token.approve(address(yieldReserve), loanAmount);
        
        yieldReserve.repayLoan(mockPool, positionId, loanAmount);
        
        assertEq(yieldReserve.getPositionLoan(positionId), 0);
        assertEq(yieldReserve.getTotalLoaned(), 0);
    }
    
    function test_coverShortfall() public {
        _setupYieldReserve();
        
        uint256 fundAmount = 50_000e6;
        vm.prank(admin);
        token.transfer(address(yieldReserve), fundAmount);
        
        vm.prank(address(this));
        yieldReserve.recordYield(fundAmount);
        
        uint256 shortfallAmount = 5000e6;
        uint256 poolBefore = token.balanceOf(mockPool);
        
        vm.prank(address(this));
        yieldReserve.coverShortfall(mockPool, shortfallAmount);
        
        uint256 poolAfter = token.balanceOf(mockPool);
        assertEq(poolAfter - poolBefore, shortfallAmount);
        
        (,,,,,uint256 lossesAbsorbed) = yieldReserve.getReserveStats();
        assertEq(lossesAbsorbed, shortfallAmount);
    }
    
    function test_investReserve() public {
        _setupYieldReserve();
        
        uint256 fundAmount = 100_000e6;
        vm.prank(admin);
        token.transfer(address(yieldReserve), fundAmount);
        
        vm.prank(address(this));
        yieldReserve.recordYield(fundAmount);
        
        uint256 investAmount = 20_000e6;
        uint256 expectedReturn = 22_000e6;
        
        vm.prank(operator);
        uint256 investmentId = yieldReserve.investReserve(mockPool, mockEscrow, investAmount, expectedReturn);
        
        YieldReserveEscrow.ReserveInvestment memory investment = yieldReserve.getInvestment(investmentId);
        assertEq(investment.amount, investAmount);
        assertEq(investment.expectedReturn, expectedReturn);
        assertTrue(investment.active);
    }
    
    function test_investReserve_belowFloor_reverts() public {
        _setupYieldReserve();
        
        uint256 fundAmount = MIN_RESERVE_FLOOR;
        vm.prank(admin);
        token.transfer(address(yieldReserve), fundAmount);
        
        vm.prank(address(this));
        yieldReserve.recordYield(fundAmount);
        
        vm.prank(operator);
        vm.expectRevert("YieldReserveEscrow/below floor");
        yieldReserve.investReserve(mockPool, mockEscrow, 1000e6, 1100e6);
    }
    
    function test_sweepToTreasury() public {
        _setupYieldReserve();
        
        uint256 fundAmount = 50_000e6;
        vm.prank(admin);
        token.transfer(address(yieldReserve), fundAmount);
        
        vm.prank(address(this));
        yieldReserve.recordYield(fundAmount);
        
        uint256 treasuryBefore = token.balanceOf(treasury);
        
        vm.prank(operator);
        yieldReserve.sweepToTreasury();
        
        uint256 treasuryAfter = token.balanceOf(treasury);
        
        uint256 reserveBalance = yieldReserve.getAvailableBalance();
        assertEq(reserveBalance, MIN_RESERVE_FLOOR);
        assertTrue(treasuryAfter > treasuryBefore);
    }
    
    function test_setSplitConfig() public {
        vm.prank(admin);
        yieldReserve.setSplitConfig(7000);
        
        (uint256 treasuryPct, uint256 reservePct) = yieldReserve.getSplitConfig();
        assertEq(treasuryPct, 7000);
        assertEq(reservePct, 3000);
    }
    
    function test_setMinReserveFloor() public {
        _setupYieldReserve();
        
        uint256 fundAmount = 150_000e6;
        vm.prank(admin);
        token.transfer(address(yieldReserve), fundAmount);
        
        yieldReserve.recordYield(fundAmount);
        
        uint256 newFloor = 50_000e6;
        vm.prank(admin);
        yieldReserve.setMinReserveFloor(newFloor);
        
        vm.prank(operator);
        yieldReserve.sweepToTreasury();
        
        assertEq(yieldReserve.getAvailableBalance(), newFloor);
    }
    
    function test_recordDirectDeposit() public {
        _setupYieldReserve();
        
        uint256 depositAmount = 25_000e6;
        
        vm.prank(mockEscrow);
        yieldReserve.recordDirectDeposit(mockPool, depositAmount);
        
        YieldReserveEscrow.PoolProtocolFunds memory funds = yieldReserve.getPoolProtocolFunds(mockPool);
        assertEq(funds.directDeposit, depositAmount);
    }
    
    function test_getProtocolFundsSnapshot() public {
        _setupYieldReserve();
        
        uint256 fundAmount = 100_000e6;
        vm.prank(admin);
        token.transfer(address(yieldReserve), fundAmount);
        
        vm.prank(address(this));
        yieldReserve.recordYield(fundAmount);
        
        vm.prank(operator);
        yieldReserve.deployToPool(mockPool, mockEscrow, 20_000e6);
        
        vm.prank(address(this));
        yieldReserve.loanToPool(mockPool, 1, 10_000e6, mockPool);
        
        YieldReserveEscrow.ProtocolFundsSnapshot memory snapshot = yieldReserve.getProtocolFundsSnapshot();
        
        assertTrue(snapshot.totalDeployedViaReserve == 20_000e6);
        assertTrue(snapshot.totalEarlyExitLoans == 10_000e6);
        assertTrue(snapshot.poolCount > 0);
    }
    
    function test_getReserveStats() public {
        _setupYieldReserve();
        
        uint256 fundAmount = 50_000e6;
        vm.prank(admin);
        token.transfer(address(yieldReserve), fundAmount);
        
        vm.prank(address(this));
        yieldReserve.recordYield(fundAmount);
        
        (
            uint256 balance,
            uint256 loaned,
            uint256 invested,
            uint256 yieldReceived,
            uint256 sentToTreasury,
            uint256 lossesAbsorbed
        ) = yieldReserve.getReserveStats();
        
        assertTrue(balance > 0);
        assertEq(loaned, 0);
        assertEq(invested, 0);
        assertTrue(yieldReceived > 0);
    }
    
    function test_emergencyWithdraw() public {
        _setupYieldReserve();
        
        uint256 fundAmount = 50_000e6;
        vm.prank(admin);
        token.transfer(address(yieldReserve), fundAmount);
        
        uint256 withdrawAmount = 30_000e6;
        uint256 adminBefore = token.balanceOf(admin);
        
        vm.prank(admin);
        yieldReserve.emergencyWithdraw(admin, withdrawAmount);
        
        uint256 adminAfter = token.balanceOf(admin);
        assertEq(adminAfter - adminBefore, withdrawAmount);
    }
    
    function test_yieldReserve_upgradeRequiresMultisig() public {
        _setupYieldReserve();
        
        YieldReserveEscrow newImpl = new YieldReserveEscrow();
        
        vm.prank(admin);
        vm.expectRevert("YieldReserveEscrow/only multisig");
        yieldReserve.upgradeToAndCall(address(newImpl), "");
    }
}
