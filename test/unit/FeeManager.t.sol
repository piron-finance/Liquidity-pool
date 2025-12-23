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
        
        // Check default fee config (transaction fees only)
        IFeeManager.FeeConfig memory defaultConfig = feeManager.defaultFeeConfig();
        assertEq(defaultConfig.protocolFee, 200); // 2%
        assertEq(defaultConfig.spvFee, 100);      // 1%
        assertEq(defaultConfig.performanceFee, 100); // 1% (10% of profits)
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
        
        // Default protocol fee is 200 bps (2%) + spv fee 100 bps (1%) = 300 bps (3%)
        uint256 expectedFee = (amount * 300) / 10_000;
        assertEq(fee, expectedFee);
    }
    
    function test_CalculateSpvFee() public view {
        uint256 amount = 10_000e6;
        uint256 fee = feeManager.calculateSpvFee(pool, amount);
        
        // Default SPV fee is 100 bps (1%)
        uint256 expectedFee = (amount * 100) / 10_000;
        assertEq(fee, expectedFee);
    }
    
    function test_CalculatePerformanceFee() public view {
        uint256 profit = 100_000e6; // 100k profit
        uint256 fee = feeManager.calculatePerformanceFee(pool, profit);
        
        // Default performance fee is 100 bps (1%)
        uint256 expectedFee = (profit * 100) / 10_000;
        assertEq(fee, expectedFee);
    }
    
    function test_CalculateFee_ReturnsZeroForZeroAmount() public view {
        assertEq(feeManager.calculateProtocolFee(pool, 0), 0);
        assertEq(feeManager.calculateSpvFee(pool, 0), 0);
        assertEq(feeManager.calculatePerformanceFee(pool, 0), 0);
    }
    
    /*//////////////////////////////////////////////////////////////
                    FEE CONFIGURATION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_SetDefaultFeeConfig_Success() public {
        IFeeManager.FeeConfig memory newConfig = IFeeManager.FeeConfig({
            protocolFee: 50,
            spvFee: 100,
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
    
    function test_CollectTransactionFee_MultipleCollections() public {
        uint256 depositFee = 100e6;
        uint256 withdrawalFee = 50e6;
        
        vm.startPrank(operator);
        token.approve(address(feeManager), depositFee + withdrawalFee);
        
        // Collect deposit fee
        feeManager.collectTransactionFee(pool, address(token), depositFee, "deposit");
        
        // Collect withdrawal fee
        feeManager.collectTransactionFee(pool, address(token), withdrawalFee, "withdrawal");
        vm.stopPrank();
        
        assertEq(feeManager.getTreasuryBalance(address(token)), depositFee + withdrawalFee);
        assertEq(feeManager.getTransactionFees(pool, address(token)), depositFee + withdrawalFee);
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
    
    function test_EstimateFeesForAmount() public view {
        uint256 amount = 10_000e6;
        
        uint256 protocolFee = feeManager.estimateFeesForAmount(pool, amount, "protocol");
        uint256 spvFee = feeManager.estimateFeesForAmount(pool, amount, "spv");
        uint256 unknownFee = feeManager.estimateFeesForAmount(pool, amount, "unknown");
        
        assertTrue(protocolFee > 0);
        assertTrue(spvFee > 0);
        assertEq(unknownFee, 0);
    }
    
    /*//////////////////////////////////////////////////////////////
                    FUZZ TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testFuzz_CalculateProtocolFee(uint256 amount) public view {
        vm.assume(amount > 0 && amount < type(uint128).max);
        
        uint256 fee = feeManager.calculateProtocolFee(pool, amount);
        
        // Fee should be proportional to amount and not exceed amount
        assertTrue(fee <= amount);
        // Protocol fee is 200 bps + spv fee 100 bps = 300 bps
        assertEq(fee, (amount * 300) / 10_000);
    }
    
    function testFuzz_TreasuryDeposit(uint256 amount) public {
        vm.assume(amount > 0 && amount <= INITIAL_BALANCE);
        
        vm.startPrank(operator);
        token.approve(address(feeManager), amount);
        feeManager.depositToTreasury(address(token), amount);
        vm.stopPrank();
        
        assertEq(feeManager.getTreasuryBalance(address(token)), amount);
    }
    
    function testFuzz_TransactionFeeCollection(uint256 amount) public {
        vm.assume(amount > 0 && amount <= INITIAL_BALANCE);
        
        vm.startPrank(operator);
        token.approve(address(feeManager), amount);
        feeManager.collectTransactionFee(pool, address(token), amount, "deposit");
        vm.stopPrank();
        
        assertEq(feeManager.getTransactionFees(pool, address(token)), amount);
        assertEq(feeManager.getTreasuryBalance(address(token)), amount);
    }
}
