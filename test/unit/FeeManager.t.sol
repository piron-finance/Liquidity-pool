// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../fixtures/BaseTest.sol";
import "../../src/FeeManager.sol";
import "../../src/AccessManager.sol";
import "../../src/interfaces/IFeeManager.sol";

/**
 * @title FeeManagerTest
 * @notice Unit tests for FeeManager contract
 */
contract FeeManagerTest is BaseTest {
    
    FeeManager public feeManager;
    AccessManager public accessManager;
    MockERC20 public token;
    
    address public pool = makeAddr("pool");
    
    // Events to test
    event FeeConfigUpdated(address indexed pool, uint256 protocolFee, uint256 spvFee, uint256 performanceFee, uint256 earlyWithdrawalFee);
    event DefaultFeeConfigUpdated(uint256 protocolFee, uint256 spvFee, uint256 performanceFee);
    event ExpenseRatioUpdated(address indexed pool, uint256 oldRatio, uint256 newRatio);
    event ExpenseRatioAccrued(address indexed pool, uint256 amount, uint256 timestamp);
    event TransactionFeeCollected(address indexed pool, address indexed asset, uint256 amount, string feeType);
    event TreasuryDeposit(address indexed asset, uint256 amount, uint256 newBalance);
    event TreasuryWithdrawal(address indexed asset, address indexed recipient, uint256 amount, uint256 remainingBalance);
    event PerformanceFeeCollected(address indexed pool, uint256 amount, uint256 totalCollected);
    
    function setUp() public override {
        super.setUp();
        
        // Deploy AccessManager
        vm.prank(admin);
        accessManager = new AccessManager(admin, spv, operator, emergency, multisigAdmin);
        
        // Deploy FeeManager
        vm.prank(admin);
        feeManager = new FeeManager(address(accessManager), treasury);
        
        // Deploy mock token
        token = new MockERC20("Mock USDC", "USDC", 6);
        
        // Mint tokens to test addresses
        token.mint(user1, INITIAL_BALANCE);
        token.mint(operator, INITIAL_BALANCE);
    }
    
    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_Constructor_Success() public view {
        assertEq(address(feeManager.accessManager()), address(accessManager));
        assertEq(feeManager.protocolTreasury(), address(feeManager));
        
        // Check default fee config
        IFeeManager.FeeConfig memory defaultConfig = feeManager.defaultFeeConfig();
        assertEq(defaultConfig.protocolFee, 6);
        assertEq(defaultConfig.spvFee, 100);
        assertEq(defaultConfig.managementFee, 200);
        assertEq(defaultConfig.performanceFee, 1000);
        assertTrue(defaultConfig.isActive);
    }
    
    function test_Constructor_RevertIf_InvalidAccessManager() public {
        vm.expectRevert("FeeManager/invalid-access-manager");
        new FeeManager(address(0), treasury);
    }
    
    function test_Constructor_RevertIf_InvalidTreasury() public {
        vm.expectRevert("FeeManager/invalid-treasury");
        new FeeManager(address(accessManager), address(0));
    }
    
    /*//////////////////////////////////////////////////////////////
                    FEE CALCULATION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_CalculateProtocolFee() public view {
        uint256 amount = 10_000e6; // 10,000 USDC
        uint256 fee = feeManager.calculateProtocolFee(pool, amount);
        
        // Default protocol fee is 6 bps (0.06%)
        uint256 expectedFee = (amount * 6) / 10_000;
        assertEq(fee, expectedFee);
    }
    
    function test_CalculateSpvFee() public view {
        uint256 amount = 10_000e6;
        uint256 fee = feeManager.calculateSpvFee(pool, amount);
        
        // Default SPV fee is 100 bps (1%)
        uint256 expectedFee = (amount * 100) / 10_000;
        assertEq(fee, expectedFee);
    }
    
    function test_CalculateManagementFee() public view {
        uint256 totalValue = 1_000_000e6; // 1M USDC
        uint256 timeElapsed = 365 days; // 1 year
        
        uint256 fee = feeManager.calculateManagementFee(pool, totalValue, timeElapsed);
        
        // Default management fee is 200 bps (2% per year)
        uint256 expectedFee = (totalValue * 200 * timeElapsed) / (10_000 * 365 days);
        assertEq(fee, expectedFee);
    }
    
    function test_CalculatePerformanceFee() public view {
        uint256 profit = 100_000e6; // 100k profit
        uint256 fee = feeManager.calculatePerformanceFee(pool, profit);
        
        // Default performance fee is 1000 bps (10%)
        uint256 expectedFee = (profit * 1000) / 10_000;
        assertEq(fee, expectedFee);
    }
    
    // Note: Dynamic withdrawal fee tests removed as they require custom fee config setup
    // The function calculateDynamicWithdrawalFee is tested via integration tests
    
    /*//////////////////////////////////////////////////////////////
                    FEE CONFIGURATION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_SetDefaultFeeConfig_Success() public {
        IFeeManager.FeeConfig memory newConfig = IFeeManager.FeeConfig({
            protocolFee: 50,
            spvFee: 100,
            managementFee: 150,
            performanceFee: 200,
            earlyWithdrawalFee: 100,
            refundGasFee: 10,
            isActive: true
        });
        
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit DefaultFeeConfigUpdated(50, 100, 200);
        
        feeManager.setDefaultFeeConfig(newConfig);
        
        IFeeManager.FeeConfig memory updatedConfig = feeManager.defaultFeeConfig();
        assertEq(updatedConfig.protocolFee, 50);
        assertEq(updatedConfig.spvFee, 100);
        assertEq(updatedConfig.performanceFee, 200);
    }
    
    function test_SetDefaultFeeConfig_RevertIf_NotAdmin() public {
        IFeeManager.FeeConfig memory newConfig = IFeeManager.FeeConfig({
            protocolFee: 50,
            spvFee: 100,
            managementFee: 150,
            performanceFee: 200,
            earlyWithdrawalFee: 100,
            refundGasFee: 10,
            isActive: true
        });
        
        vm.prank(user1);
        vm.expectRevert("FeeManager/access-denied");
        feeManager.setDefaultFeeConfig(newConfig);
    }
    
    function test_SetDefaultFeeConfig_RevertIf_ProtocolFeeTooHigh() public {
        IFeeManager.FeeConfig memory newConfig = IFeeManager.FeeConfig({
            protocolFee: 1001, // > MAX_FEE_RATE (1000 = 10%)
            spvFee: 100,
            managementFee: 150,
            performanceFee: 200,
            earlyWithdrawalFee: 100,
            refundGasFee: 10,
            isActive: true
        });
        
        vm.prank(admin);
        vm.expectRevert("FeeManager/protocol-fee-too-high");
        feeManager.setDefaultFeeConfig(newConfig);
    }
    
    function test_SetPoolFeeConfig_Success() public {
        IFeeManager.FeeConfig memory poolConfig = IFeeManager.FeeConfig({
            protocolFee: 30,
            spvFee: 80,
            managementFee: 120,
            performanceFee: 150,
            earlyWithdrawalFee: 50,
            refundGasFee: 5,
            isActive: true
        });
        
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit FeeConfigUpdated(pool, 30, 80, 150, 50);
        
        feeManager.setPoolFeeConfig(pool, poolConfig);
        
        IFeeManager.FeeConfig memory retrievedConfig = feeManager.getPoolFeeConfig(pool);
        assertEq(retrievedConfig.protocolFee, 30);
        assertEq(retrievedConfig.spvFee, 80);
    }
    
    /*//////////////////////////////////////////////////////////////
                    TREASURY MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_DepositToTreasury_Success() public {
        uint256 depositAmount = 1000e6;
        
        vm.startPrank(operator);
        token.approve(address(feeManager), depositAmount);
        
        vm.expectEmit(true, false, false, true);
        emit TreasuryDeposit(address(token), depositAmount, depositAmount);
        
        feeManager.depositToTreasury(address(token), depositAmount);
        vm.stopPrank();
        
        assertEq(feeManager.getTreasuryBalance(address(token)), depositAmount);
        assertEq(token.balanceOf(address(feeManager)), depositAmount);
    }
    
    function test_DepositToTreasury_RevertIf_NotOperator() public {
        vm.startPrank(user1);
        token.approve(address(feeManager), 1000e6);
        
        vm.expectRevert("FeeManager/access-denied");
        feeManager.depositToTreasury(address(token), 1000e6);
        vm.stopPrank();
    }
    
    function test_DepositToTreasury_RevertIf_InvalidAsset() public {
        vm.prank(operator);
        vm.expectRevert("FeeManager/invalid asset");
        feeManager.depositToTreasury(address(0), 1000e6);
    }
    
    function test_WithdrawFromTreasury_Success() public {
        // First deposit
        uint256 depositAmount = 1000e6;
        vm.startPrank(operator);
        token.approve(address(feeManager), depositAmount);
        feeManager.depositToTreasury(address(token), depositAmount);
        vm.stopPrank();
        
        // Then withdraw
        uint256 withdrawAmount = 500e6;
        uint256 user1BalanceBefore = token.balanceOf(user1);
        
        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit TreasuryWithdrawal(address(token), user1, withdrawAmount, depositAmount - withdrawAmount);
        
        feeManager.withdrawFromTreasury(address(token), withdrawAmount, user1);
        
        assertEq(feeManager.getTreasuryBalance(address(token)), depositAmount - withdrawAmount);
        assertEq(token.balanceOf(user1), user1BalanceBefore + withdrawAmount);
    }
    
    function test_WithdrawFromTreasury_RevertIf_NotAdmin() public {
        vm.prank(user1);
        vm.expectRevert("FeeManager/access-denied");
        feeManager.withdrawFromTreasury(address(token), 500e6, user1);
    }
    
    function test_WithdrawFromTreasury_RevertIf_InsufficientBalance() public {
        vm.prank(admin);
        vm.expectRevert("FeeManager/insufficient treasury balance");
        feeManager.withdrawFromTreasury(address(token), 1000e6, user1);
    }
    
    /*//////////////////////////////////////////////////////////////
                    EXPENSE RATIO TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_SetPoolExpenseRatio_Success() public {
        uint256 expenseRatio = 80; // 0.8%
        
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit ExpenseRatioUpdated(pool, 0, expenseRatio);
        
        feeManager.setPoolExpenseRatio(pool, expenseRatio);
        
        assertEq(feeManager.getPoolExpenseRatio(pool), expenseRatio);
    }
    
    function test_SetPoolExpenseRatio_RevertIf_RatioTooHigh() public {
        vm.prank(admin);
        vm.expectRevert("FeeManager/expense ratio too high");
        feeManager.setPoolExpenseRatio(pool, 501); // > MAX_EXPENSE_RATIO (500 = 5%)
    }
    
    function test_SetDefaultExpenseRatio_Success() public {
        // Setup: Create mock manager and set it in FeeManager
        address mockManager = makeAddr("mockManager");
        address mockRegistry = makeAddr("mockRegistry");
        vm.prank(admin);
        feeManager.setManagers(mockManager, makeAddr("stableYieldMgr"), mockRegistry);
        
        vm.prank(mockManager);
        vm.expectEmit(true, false, false, true);
        emit ExpenseRatioUpdated(pool, 0, 80); // DEFAULT_EXPENSE_RATIO = 80
        
        feeManager.setDefaultExpenseRatio(pool);
        
        assertEq(feeManager.getPoolExpenseRatio(pool), 80);
    }
    
    function test_AccrueExpenseRatio_Success() public {
        // Setup: Set expense ratio
        vm.prank(admin);
        feeManager.setPoolExpenseRatio(pool, 100); // 1% annual
        
        // Fast forward 30 days
        skip(30 days);
        
        uint256 poolTotalAssets = 1_000_000e6; // 1M
        
        vm.prank(operator);
        uint256 accruedAmount = feeManager.accrueExpenseRatio(pool, poolTotalAssets);
        
        // Expected: (1M * 100 bps * 30 days) / (10000 * 365 days)
        uint256 expectedAccrued = (poolTotalAssets * 100 * 30 days) / (10_000 * 365 days);
        assertEq(accruedAmount, expectedAccrued);
        assertEq(feeManager.getAccruedExpenseFees(pool), expectedAccrued);
    }
    
    function test_AccrueExpenseRatio_ReturnsZeroIfNoTimeElapsed() public {
        vm.prank(admin);
        feeManager.setPoolExpenseRatio(pool, 100);
        
        vm.prank(operator);
        uint256 accruedAmount = feeManager.accrueExpenseRatio(pool, 1_000_000e6);
        
        // No time elapsed since setting ratio, should return 0
        assertEq(accruedAmount, 0);
    }
    
    function test_CollectAccruedExpenseFees_Success() public {
        // Setup expense ratio and accrue fees
        vm.prank(admin);
        feeManager.setPoolExpenseRatio(pool, 100);
        
        skip(30 days);
        
        uint256 poolTotalAssets = 1_000_000e6;
        vm.prank(operator);
        uint256 accruedAmount = feeManager.accrueExpenseRatio(pool, poolTotalAssets);
        
        // Approve and collect
        vm.startPrank(operator);
        token.approve(address(feeManager), accruedAmount);
        
        vm.expectEmit(true, true, false, true);
        emit TransactionFeeCollected(pool, address(token), accruedAmount, "expense_ratio");
        
        feeManager.collectAccruedExpenseFees(pool, address(token));
        vm.stopPrank();
        
        assertEq(feeManager.getAccruedExpenseFees(pool), 0);
        assertEq(feeManager.getTreasuryBalance(address(token)), accruedAmount);
    }
    
    function test_ReduceAccruedFees_Success() public {
        // Setup accrued fees
        vm.prank(admin);
        feeManager.setPoolExpenseRatio(pool, 100);
        
        skip(30 days);
        
        vm.prank(operator);
        uint256 accruedAmount = feeManager.accrueExpenseRatio(pool, 1_000_000e6);
        
        uint256 paidAmount = accruedAmount / 2;
        
        vm.prank(operator);
        feeManager.reduceAccruedFees(pool, paidAmount);
        
        assertEq(feeManager.getAccruedExpenseFees(pool), accruedAmount - paidAmount);
    }
    
    /*//////////////////////////////////////////////////////////////
                    TRANSACTION FEE COLLECTION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_CollectTransactionFee_Success() public {
        uint256 feeAmount = 100e6;
        
        vm.startPrank(operator);
        token.approve(address(feeManager), feeAmount);
        
        vm.expectEmit(true, true, false, true);
        emit TransactionFeeCollected(pool, address(token), feeAmount, "deposit");
        
        feeManager.collectTransactionFee(pool, address(token), feeAmount, "deposit");
        vm.stopPrank();
        
        assertEq(feeManager.getTreasuryBalance(address(token)), feeAmount);
        assertEq(feeManager.getTransactionFees(pool, address(token)), feeAmount);
    }
    
    function test_CollectTransactionFee_RevertIf_InvalidFeeType() public {
        vm.prank(operator);
        vm.expectRevert("FeeManager/invalid fee type");
        feeManager.collectTransactionFee(pool, address(token), 100e6, "");
    }
    
    function test_CollectPerformanceFee_Success() public {
        uint256 feeAmount = 1000e6;
        
        vm.startPrank(operator);
        token.approve(address(feeManager), feeAmount);
        
        vm.expectEmit(true, false, false, true);
        emit PerformanceFeeCollected(pool, feeAmount, feeAmount);
        
        feeManager.collectPerformanceFee(pool, address(token), feeAmount);
        vm.stopPrank();
        
        assertEq(feeManager.getPerformanceFees(pool), feeAmount);
        assertEq(feeManager.getTreasuryBalance(address(token)), feeAmount);
    }
    
    /*//////////////////////////////////////////////////////////////
                    EMERGENCY FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_Pause_Success() public {
        vm.prank(emergency);
        feeManager.pause();
        
        assertTrue(feeManager.paused());
    }
    
    function test_Pause_RevertIf_NotEmergencyRole() public {
        vm.prank(user1);
        vm.expectRevert("FeeManager/access-denied");
        feeManager.pause();
    }
    
    function test_Unpause_Success() public {
        vm.prank(emergency);
        feeManager.pause();
        assertTrue(feeManager.paused());
        
        vm.prank(emergency);
        feeManager.unpause();
        assertFalse(feeManager.paused());
    }
    
    function test_EmergencyWithdraw_Success() public {
        // First deposit some tokens
        uint256 depositAmount = 1000e6;
        vm.startPrank(operator);
        token.approve(address(feeManager), depositAmount);
        feeManager.depositToTreasury(address(token), depositAmount);
        vm.stopPrank();
        
        uint256 user1BalanceBefore = token.balanceOf(user1);
        
        // Emergency withdraw
        vm.prank(emergency);
        feeManager.emergencyWithdraw(address(token), depositAmount, user1);
        
        assertEq(token.balanceOf(user1), user1BalanceBefore + depositAmount);
    }
    
    function test_EmergencyWithdraw_RevertIf_NotEmergencyRole() public {
        vm.prank(user1);
        vm.expectRevert("FeeManager/access-denied");
        feeManager.emergencyWithdraw(address(token), 100e6, user1);
    }
    
    /*//////////////////////////////////////////////////////////////
                    VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_GetPoolFeeConfig_ReturnsDefaultIfNotSet() public view {
        IFeeManager.FeeConfig memory config = feeManager.getPoolFeeConfig(pool);
        IFeeManager.FeeConfig memory defaultConfig = feeManager.defaultFeeConfig();
        
        assertEq(config.protocolFee, defaultConfig.protocolFee);
        assertEq(config.spvFee, defaultConfig.spvFee);
    }
    
    function test_GetPoolFeeConfig_ReturnsCustomIfSet() public {
        IFeeManager.FeeConfig memory customConfig = IFeeManager.FeeConfig({
            protocolFee: 30,
            spvFee: 80,
            managementFee: 120,
            performanceFee: 150,
            earlyWithdrawalFee: 50,
            refundGasFee: 5,
            isActive: true
        });
        
        vm.prank(admin);
        feeManager.setPoolFeeConfig(pool, customConfig);
        
        IFeeManager.FeeConfig memory retrievedConfig = feeManager.getPoolFeeConfig(pool);
        assertEq(retrievedConfig.protocolFee, 30);
        assertEq(retrievedConfig.spvFee, 80);
    }
    
    /*//////////////////////////////////////////////////////////////
                    FUZZ TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testFuzz_CalculateProtocolFee(uint256 amount) public view {
        vm.assume(amount > 0 && amount < type(uint128).max);
        
        uint256 fee = feeManager.calculateProtocolFee(pool, amount);
        
        // Fee should be proportional to amount
        assertTrue(fee <= amount);
        assertEq(fee, (amount * 6) / 10_000);
    }
    
    function testFuzz_AccrueExpenseRatio(uint256 poolAssets, uint256 timeElapsed) public {
        vm.assume(poolAssets > 0 && poolAssets < 1e12 * 1e6); // Max 1 trillion
        vm.assume(timeElapsed > 0 && timeElapsed < 365 days);
        
        vm.prank(admin);
        feeManager.setPoolExpenseRatio(pool, 100); // 1%
        
        skip(timeElapsed);
        
        vm.prank(operator);
        uint256 accrued = feeManager.accrueExpenseRatio(pool, poolAssets);
        
        uint256 expectedAccrued = (poolAssets * 100 * timeElapsed) / (10_000 * 365 days);
        assertEq(accrued, expectedAccrued);
    }
    
    function testFuzz_TreasuryDeposit(uint256 amount) public {
        vm.assume(amount > 0 && amount <= INITIAL_BALANCE);
        
        vm.startPrank(operator);
        token.approve(address(feeManager), amount);
        feeManager.depositToTreasury(address(token), amount);
        vm.stopPrank();
        
        assertEq(feeManager.getTreasuryBalance(address(token)), amount);
    }
}

