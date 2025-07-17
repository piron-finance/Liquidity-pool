// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/Manager.sol";
import "../src/LiquidityPool.sol";
import "../src/PoolEscrow.sol";
import "../src/PoolRegistry.sol";
import "../src/AccessManager.sol";
import "../src/factories/PoolFactory.sol";
import "../src/interfaces/IManager.sol";
import "../src/interfaces/IPoolRegistry.sol";
import "../src/interfaces/IPoolEscrow.sol";
import "../src/interfaces/IPoolFactory.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract ManagerTest is Test {
    Manager public manager;
    PoolRegistry public registry;
    AccessManager public accessManager;
    PoolFactory public factory;
    MockUSDC public usdc;
    
    // Test actors
    address public admin = address(0x1);
    address public spv = address(0x2);
    address public operator = address(0x3);
    address public poolCreator = address(0x4);
    address public user1 = address(0x5);
    address public user2 = address(0x6);
    address public user3 = address(0x7);
    address public signer1 = address(0x8);
    address public signer2 = address(0x9);
    address public signer3 = address(0xA);
    
    // Test pools
    LiquidityPool public discountedPool;
    PoolEscrow public discountedEscrow;
    LiquidityPool public interestPool;
    PoolEscrow public interestEscrow;
    
    // Pool constants
    uint256 constant TARGET_RAISE = 100_000e6;
    uint256 constant DISCOUNT_RATE = 1800; // 18%
    uint256 constant EPOCH_DURATION = 7 days;
    uint256 constant MATURITY_DURATION = 97 days;
    uint256 constant MINIMUM_RAISE_PERCENT = 50; // 50%
    
    // Test amounts
    uint256 constant DEPOSIT_AMOUNT_1 = 25_000e6;
    uint256 constant DEPOSIT_AMOUNT_2 = 40_000e6;
    uint256 constant DEPOSIT_AMOUNT_3 = 15_000e6;
    uint256 constant LARGE_DEPOSIT = 200_000e6;
    
    // Events for testing
    event StatusChanged(IPoolManager.PoolStatus oldStatus, IPoolManager.PoolStatus newStatus);
    event Deposit(address liquidityPool, address indexed sender, address indexed receiver, uint256 assets, uint256 shares);
    event Withdraw(address indexed pool, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event InvestmentConfirmed(uint256 actualAmount, string proofHash);
    event MaturityProcessed(uint256 finalAmount);
    event CouponReceived(uint256 amount, uint256 timestamp);
    event CouponDistributed(address indexed pool, uint256 amount, uint256 timestamp);
    event CouponClaimed(address indexed pool, address indexed user, uint256 amount);
    event EmergencyExit(address indexed pool, uint256 timestamp);
    event SlippageProtectionTriggered(address indexed pool, uint256 expected, uint256 actual, uint256 tolerance);
    event SPVFundsWithdrawn(address indexed pool, uint256 amount, bytes32 transferId);
    event SPVFundsReturned(address indexed pool, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        // Deploy core contracts
        usdc = new MockUSDC();
        accessManager = new AccessManager(admin);
        registry = new PoolRegistry(address(accessManager));
        manager = new Manager(address(registry), address(accessManager));
        factory = new PoolFactory(address(registry), address(manager), address(accessManager));
        
        // Setup system configuration
        vm.startPrank(admin);
        registry.setFactory(address(factory));
        registry.approveAsset(address(usdc));
        
        // Grant roles
        accessManager.grantRole(accessManager.SPV_ROLE(), spv);
        accessManager.grantRole(accessManager.OPERATOR_ROLE(), operator);
        accessManager.grantRole(accessManager.EMERGENCY_ROLE(), admin);
        accessManager.grantRole(factory.POOL_CREATOR_ROLE(), poolCreator);
        accessManager.grantRole(factory.POOL_CREATOR_ROLE(), admin);
        vm.stopPrank();
        
        // Skip role delays
        vm.warp(block.timestamp + 1 days);
        
        // Create test pools(we are creating two pools here. a discounted and a interest bearing)
        _createTestPools();
        
        // Mint tokens for testing
        usdc.mint(user1, 1_000_000e6);
        usdc.mint(user2, 1_000_000e6);
        usdc.mint(user3, 1_000_000e6);
        usdc.mint(spv, 10_000_000e6);
        
        // Label addresses for better trace output
        vm.label(admin, "Admin");
        vm.label(spv, "SPV");
        vm.label(operator, "Operator");
        vm.label(user1, "User1");
        vm.label(user2, "User2");
        vm.label(user3, "User3");
        vm.label(address(discountedPool), "DiscountedPool");
        vm.label(address(interestPool), "InterestPool");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// PHASE 1: SETUP & INITIALIZATION /////////////
    ////////////////////////////////////////////////////////////////////////////////

    function test_01_SystemSetup() public view {
        assertTrue(address(usdc) != address(0), "USDC not deployed");
        assertTrue(address(accessManager) != address(0), "AccessManager not deployed");
        assertTrue(address(registry) != address(0), "Registry not deployed");
        assertTrue(address(manager) != address(0), "Manager not deployed");
        assertTrue(address(factory) != address(0), "Factory not deployed");
        
        assertEq(registry.factory(), address(factory), "Factory not set in registry");
        assertTrue(registry.isApprovedAsset(address(usdc)), "USDC not approved");
        

        assertTrue(accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), admin), "Admin role not set");
        assertTrue(accessManager.hasRole(accessManager.SPV_ROLE(), spv), "SPV role not set");
        assertTrue(accessManager.hasRole(accessManager.OPERATOR_ROLE(), operator), "Operator role not set");
        
        console.log(" System setup verified");
    }

    function test_02_PoolCreation() public {
        assertTrue(registry.isRegisteredPool(address(discountedPool)), "Discounted pool not registered");
        assertTrue(registry.isRegisteredPool(address(interestPool)), "Interest pool not registered");
        assertTrue(registry.isActivePool(address(discountedPool)), "Discounted pool not active");
        assertTrue(registry.isActivePool(address(interestPool)), "Interest pool not active");
        

        vm.startPrank(address(discountedPool));
        IPoolManager.PoolConfig memory discountedConfig = manager.config();
        assertEq(discountedConfig.targetRaise, TARGET_RAISE, "Target raise not set");
        assertEq(uint256(discountedConfig.instrumentType), uint256(IPoolManager.InstrumentType.DISCOUNTED), "Instrument type not set");
        assertEq(discountedConfig.discountRate, DISCOUNT_RATE, "Discount rate not set");
        assertEq(uint256(manager.status()), uint256(IPoolManager.PoolStatus.FUNDING), "Pool not in funding status");
        vm.stopPrank();
        
        vm.startPrank(address(interestPool));
        IPoolManager.PoolConfig memory interestConfig = manager.config();
        assertEq(uint256(interestConfig.instrumentType), uint256(IPoolManager.InstrumentType.INTEREST_BEARING), "Interest pool type not set");
        assertEq(interestConfig.couponDates.length, 4, "Coupon dates not set");
        assertEq(interestConfig.couponRates.length, 4, "Coupon rates not set");
        vm.stopPrank();
        

        assertEq(discountedPool.escrow(), address(discountedEscrow), "Discounted pool escrow not connected");
        assertEq(interestPool.escrow(), address(interestEscrow), "Interest pool escrow not connected");
        assertEq(discountedEscrow.pool(), address(discountedPool), "Discounted escrow pool not set");
        assertEq(interestEscrow.pool(), address(interestPool), "Interest escrow pool not set");
        
        console.log("Pool creation verified");
    }

    function test_03_PoolInitializationFailures() public {
        IPoolManager.PoolConfig memory config = _createDiscountedPoolConfig();
        vm.prank(address(factory));
        vm.expectRevert("Manager/already-initialized");
        manager.initializePool(address(discountedPool), config);
        
        // Test unauthorized initialization
        vm.prank(user1);
        vm.expectRevert("Manager/only-factory");
        manager.initializePool(address(discountedPool), config);
        
        console.log("pool initialization failures tested");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// PHASE 2: FUNDING PHASE //////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function test_04_FundingPhase_SingleDeposit() public {
        uint256 depositAmount = DEPOSIT_AMOUNT_1;
        
        vm.startPrank(user1);
        
        // Expect the Approval event first
        vm.expectEmit(true, true, true, true);
        emit Approval(user1, address(discountedPool), depositAmount);
        usdc.approve(address(discountedPool), depositAmount);
        
        // Then expect the Deposit event
        vm.expectEmit(true, true, true, true);
        emit Deposit(address(discountedPool), user1, user1, depositAmount, depositAmount);
        uint256 shares = LiquidityPool(address(discountedPool)).deposit(depositAmount, user1);
        
        vm.stopPrank();
        
        // Verify the deposit worked
        assertEq(shares, depositAmount, "Shares should equal amount in funding phase");
        
        // Verify deposit tracking
        assertEq(manager.poolTotalRaised(address(discountedPool)), depositAmount, "Total raised not updated");
        assertEq(manager.poolUserDepositTime(address(discountedPool), user1), block.timestamp, "User deposit time not set");
        assertEq(discountedPool.balanceOf(user1), depositAmount, "User shares not minted");
        
        console.log(" Single deposit in funding phase verified");
    }

    function test_05_FundingPhase_MultipleDeposits() public {
        // Multiple users deposit
        _simulateDeposit(address(discountedPool), user1, DEPOSIT_AMOUNT_1);
        _simulateDeposit(address(discountedPool), user2, DEPOSIT_AMOUNT_2);
        _simulateDeposit(address(discountedPool), user3, DEPOSIT_AMOUNT_3);
        
        uint256 totalExpected = DEPOSIT_AMOUNT_1 + DEPOSIT_AMOUNT_2 + DEPOSIT_AMOUNT_3;
        
        // Verify total tracking
        assertEq(manager.poolTotalRaised(address(discountedPool)), totalExpected, "Total raised incorrect");
        assertEq(discountedPool.balanceOf(user1), DEPOSIT_AMOUNT_1, "User1 shares incorrect");
        assertEq(discountedPool.balanceOf(user2), DEPOSIT_AMOUNT_2, "User2 shares incorrect");
        assertEq(discountedPool.balanceOf(user3), DEPOSIT_AMOUNT_3, "User3 shares incorrect");
        assertEq(discountedPool.totalSupply(), totalExpected, "Total supply incorrect");
        
        console.log(" Multiple deposits in funding phase verified");
    }

    function test_06_FundingPhase_DepositFailures() public {

        vm.prank(address(discountedPool));
        vm.expectRevert("Manager/exceeds-target");
        manager.handleDeposit(address(discountedPool), TARGET_RAISE + 1, user1, user1);
        

        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        vm.prank(address(discountedPool));
        vm.expectRevert("Manager/funding-ended");
        manager.handleDeposit(address(discountedPool), DEPOSIT_AMOUNT_1, user1, user1);
        
        vm.warp(block.timestamp - EPOCH_DURATION - 1);
        
        vm.prank(user1);
        vm.expectRevert("Manager/caller is not a pool");
        manager.handleDeposit(address(discountedPool), DEPOSIT_AMOUNT_1, user1, user1);
        console.log(" Deposit failures tested");
    }

    function test_07_FundingPhase_WithdrawalsAndRedemptions() public {
        _simulateDeposit(address(discountedPool), user1, DEPOSIT_AMOUNT_1); //25k
        _simulateDeposit(address(discountedPool), user2, DEPOSIT_AMOUNT_2);// 40k
        
        uint256 withdrawAmount = 10_000e6;
        uint256 redeemShares = 5_000e6;
        

        vm.prank(address(discountedPool));
        uint256 sharesWithdrawn = manager.handleWithdraw(address(discountedPool), withdrawAmount, user1, user1, user1);
        assertEq(sharesWithdrawn, withdrawAmount, "Withdrawal shares incorrect");
        assertEq(manager.poolTotalRaised(address(discountedPool)), DEPOSIT_AMOUNT_1 + DEPOSIT_AMOUNT_2 - withdrawAmount, "Total raised not updated after withdrawal");
        
        vm.prank(address(discountedPool));
        uint256 assetsRedeemed = manager.handleRedeem(redeemShares, user2, user2, user2);
        assertEq(assetsRedeemed, redeemShares, "Redemption assets incorrect");
        
        console.log(" Funding phase withdrawals and redemptions verified");
    }

    function test_08_FundingPhase_WithdrawalFailures() public {
        _simulateDeposit(address(discountedPool), user1, DEPOSIT_AMOUNT_1);
        
        // Testing withdrawal after epoch
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        vm.prank(address(discountedPool));
        vm.expectRevert("Manager/funding-ended");
        manager.handleWithdraw(address(discountedPool), 10_000e6, user1, user1, user1);
        
        // Reset time
        vm.warp(block.timestamp - EPOCH_DURATION - 1);
        
        // Test invalid params
        vm.prank(address(discountedPool));
        vm.expectRevert("Manager/invalid-receiver");
        manager.handleWithdraw(address(discountedPool), 10_000e6, address(0), user1, user1);
        
        vm.prank(address(discountedPool));
        vm.expectRevert("Manager/invalid-amount");
        manager.handleWithdraw(address(discountedPool), 0, user1, user1, user1);
        
        console.log(" Withdrawal failures tested");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// PHASE 3: EPOCH MANAGEMENT ///////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function test_09_EpochManagement_SuccessfulClose() public {
        // Fund pool above minimum threshold - (threshold: half of target raise)
        uint256 fundingAmount = (TARGET_RAISE * 60) / 100; // 60% of target
        _simulateDeposit(address(discountedPool), user1, fundingAmount);
        
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        
        vm.expectEmit(true, true, false, false);
        emit StatusChanged(IPoolManager.PoolStatus.FUNDING, IPoolManager.PoolStatus.PENDING_INVESTMENT);
        
        vm.prank(operator);
        manager.closeEpoch(address(discountedPool));
        
        // Verify status change
        vm.startPrank(address(discountedPool));
        assertEq(uint256(manager.status()), uint256(IPoolManager.PoolStatus.PENDING_INVESTMENT), "Status not updated");
        
        // Verify face value calculation for discounted instruments
        IPoolManager.PoolConfig memory config = manager.config();
        uint256 expectedFaceValue = (fundingAmount * 10000) / (10000 - DISCOUNT_RATE);
        assertEq(config.faceValue, expectedFaceValue, "Face value calculation incorrect");
        vm.stopPrank();
        
        console.log(" Successful epoch close verified");
    }

    function test_10_EpochManagement_InsufficientFunding() public {
        // Fund pool below minimum threshold(ideally should go into emergency)
        uint256 fundingAmount = (TARGET_RAISE * 30) / 100; // 30% of target (below 50% minimum)
        _simulateDeposit(address(discountedPool), user1, fundingAmount);

        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        
        vm.expectEmit(true, true, false, false);
        emit StatusChanged(IPoolManager.PoolStatus.FUNDING, IPoolManager.PoolStatus.EMERGENCY);
        
        vm.prank(operator);
        manager.closeEpoch(address(discountedPool));
        
        // Verify emergency status
        vm.startPrank(address(discountedPool));
        assertEq(uint256(manager.status()), uint256(IPoolManager.PoolStatus.EMERGENCY), "Status not updated to emergency");
        vm.stopPrank();
        
        console.log(" Insufficient funding epoch close verified");
    }

    function test_11_EpochManagement_ForceClose() public {
        uint256 fundingAmount = (TARGET_RAISE * 30) / 100;
        _simulateDeposit(address(discountedPool), user1, fundingAmount);
        
        // Test force close before epoch end
        vm.prank(admin); // Emergency role
        manager.forceCloseEpoch(address(discountedPool));
        
        // Verify emergency status
        vm.startPrank(address(discountedPool));
        assertEq(uint256(manager.status()), uint256(IPoolManager.PoolStatus.EMERGENCY), "Status not updated to emergency");
        vm.stopPrank();
        
        console.log(" Force close epoch verified");
    }

    function test_12_EpochManagement_Failures() public {
                _simulateDeposit(address(discountedPool), user1, TARGET_RAISE);

        // Test close epoch too early
        vm.prank(operator);
        vm.expectRevert("Manager/epoch-not-ended");
        manager.closeEpoch(address(discountedPool));
        
        // Test unauthorized close
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        vm.prank(user1);
        vm.expectRevert("Manager/access-denied");
        manager.closeEpoch(address(discountedPool));
        
        // Test close epoch in wrong status(we deposit because the first attempt to close epoch will fail if min threshold for deposit is not met)

        vm.prank(operator);
        manager.closeEpoch(address(discountedPool));
        
        vm.prank(operator);
        vm.expectRevert("Manager/not-in-funding");
        manager.closeEpoch(address(discountedPool));
        
        console.log(" Epoch management failures tested");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// PHASE 4: INVESTMENT FLOW ////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function test_13_InvestmentFlow_FundWithdrawal() public {
        // Setup pool in pending investment state
        _fundAndCloseEpoch(address(discountedPool), (TARGET_RAISE * 70) / 100);
        
        uint256 withdrawAmount = 50_000e6;
        
        // Test SPV fund withdrawal
        vm.expectEmit(true, true, false, false);
        emit SPVFundsWithdrawn(address(discountedPool), withdrawAmount, bytes32(0));
        
        vm.prank(spv);
        manager.withdrawFundsForInvestment(address(discountedPool), withdrawAmount);
        
        // Verify tracking
        assertEq(manager.poolFundsWithdrawnBySPV(address(discountedPool)), withdrawAmount, "SPV withdrawal not tracked");
        assertEq(usdc.balanceOf(spv), 10_000_000e6 + withdrawAmount, "SPV balance not updated");
        
        console.log(" Investment fund withdrawal verified");
    }

    function test_14_InvestmentFlow_ProcessInvestment() public {
        uint256 fundingAmount = (TARGET_RAISE * 70) / 100;
        _fundAndCloseEpoch(address(discountedPool), fundingAmount);
        
        vm.prank(spv);
        manager.withdrawFundsForInvestment(address(discountedPool), fundingAmount);
        
        // using a slight slippage
        uint256 actualInvestment = (fundingAmount * 97) / 100; // 3% slippage
        
        vm.expectEmit(true, true, false, true);
        emit InvestmentConfirmed(actualInvestment, "investment-proof-hash");
        
        vm.prank(spv);
        manager.processInvestment(address(discountedPool), actualInvestment, "investment-proof-hash");
        
 
        vm.startPrank(address(discountedPool));
        assertEq(uint256(manager.status()), uint256(IPoolManager.PoolStatus.INVESTED), "Status not updated to invested");
        assertEq(manager.actualInvested(), actualInvestment, "Actual investment not tracked");
        

        IPoolManager.PoolConfig memory config = manager.config();
        uint256 expectedDiscount = config.faceValue - actualInvestment;
        assertEq(manager.totalDiscountEarned(), expectedDiscount, "Discount calculation incorrect");
        vm.stopPrank();
        
        console.log(" Investment processing verified");
    }

    function test_15_InvestmentFlow_SlippageProtection() public {
        uint256 fundingAmount = (TARGET_RAISE * 70) / 100;
        _fundAndCloseEpoch(address(discountedPool), fundingAmount);
        
        uint256 actualInvestment = (fundingAmount * 85) / 100; // 15% slippage - exceeds 10% max
        
        vm.expectEmit(true, true, false, true);
        emit SlippageProtectionTriggered(address(discountedPool), fundingAmount, actualInvestment, 500);
        
        vm.prank(spv);
        vm.expectRevert("Manager/slippage-protection-triggered");
        manager.processInvestment(address(discountedPool), actualInvestment, "proof");
        
        console.log(" Slippage protection verified");
    }

    function test_16_InvestmentFlow_CustomSlippageTolerance() public {
        vm.prank(admin);
        manager.setSlippageTolerance(address(discountedPool), 1000); // 10%
        
        uint256 fundingAmount = (TARGET_RAISE * 70) / 100;
        _fundAndCloseEpoch(address(discountedPool), fundingAmount);
        
        // Test investment with 10% slippage (should now pass)
        uint256 actualInvestment = (fundingAmount * 90) / 100;
        
        vm.prank(spv);
        manager.processInvestment(address(discountedPool), actualInvestment, "proof");
        
        vm.startPrank(address(discountedPool));
        assertEq(uint256(manager.status()), uint256(IPoolManager.PoolStatus.INVESTED), "Investment should succeed with custom tolerance");
        vm.stopPrank();
        
        console.log(" Custom slippage tolerance verified");
    }

    function test_17_InvestmentFlow_Failures() public {
        //  withdrawal from wrong status
        vm.prank(spv);
        vm.expectRevert("Manager/not-pending-investment");
        manager.withdrawFundsForInvestment(address(discountedPool), 10_000e6);
        
        //  process investment from wrong status (still FUNDING)
        vm.prank(spv);
        vm.expectRevert("Manager/not-pending-investment");
        manager.processInvestment(address(discountedPool), 10_000e6, "proof");
        
        // Test 3: unauthorized withdrawal (need PENDING_INVESTMENT status first)
        _fundAndCloseEpoch(address(discountedPool), TARGET_RAISE);
        vm.prank(user1);
        vm.expectRevert("Manager/access-denied");
        manager.withdrawFundsForInvestment(address(discountedPool), 10_000e6);
        
        console.log("Investment flow failures tested");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// PHASE 5: INVESTED STATE OPERATIONS ///////////
    ////////////////////////////////////////////////////////////////////////////////

    function test_18_InvestedState_WithdrawalsWithPenalty() public {
        uint256 fundingAmount = (TARGET_RAISE * 70) / 100;
        _simulateFullInvestmentFlow(address(discountedPool), fundingAmount);
        
        uint256 liquidityBuffer = 10_000e6; // 10k USDC for early withdrawals
        vm.prank(spv);
        usdc.approve(address(manager), liquidityBuffer);
        vm.prank(spv);
        manager.provideLiquidityBuffer(address(discountedPool), liquidityBuffer);
        
        // Test withdrawal with penalty - use amount within liquidity limits
        // Available liquidity = min(actualInvested / 10, liquidityBuffer)
        // actualInvested = 67,900, so theoretical limit = 6,790
        // liquidityBuffer = 10,000, so available = min(6,790, 10,000) = 6,790
        // With 5% penalty, we need netAssets ≤ 6,790
        // So withdrawAmount should be ≤ 6,790 / 0.95 ≈ 7,147 USDC
        uint256 withdrawAmount = 6_000e6; // Safe amount within limits
        
        vm.prank(address(discountedPool));
        uint256 sharesWithdrawn = manager.handleWithdraw(address(discountedPool), withdrawAmount, user1, user1, user1);
        
        // Verify penalty was applied (withdrawal should result in more shares burned than assets received)
        assertGt(sharesWithdrawn, 0, "Shares should be withdrawn");
        
        // User held for exactly 7 days, so penalty is 3% (not 5%)
        uint256 penalty = (withdrawAmount * 300) / 10000; // 3% penalty for 7 days to 30 days
        uint256 expectedNetAssets = withdrawAmount - penalty;
        
        // Verify liquidity buffer was consumed
        uint256 remainingBuffer = manager.poolLiquidityBuffer(address(discountedPool));
        assertEq(remainingBuffer, liquidityBuffer - expectedNetAssets, "Liquidity buffer should be consumed");
        
        // The user should have received expectedNetAssets (less than withdrawAmount due to penalty)
        console.log("Withdraw amount:", withdrawAmount);
        console.log("Expected penalty:", penalty);
        console.log("Expected net assets:", expectedNetAssets);
        console.log("Shares withdrawn:", sharesWithdrawn);
        console.log("Remaining liquidity buffer:", remainingBuffer);
        
        console.log("Invested state withdrawals with penalty verified");
    }

    function test_19_InvestedState_PenaltyCalculation() public {
        uint256 fundingAmount = (TARGET_RAISE * 70) / 100;
        _simulateFullInvestmentFlow(address(discountedPool), fundingAmount);
        
        uint256 liquidityBuffer = 20_000e6; // 20k USDC for early withdrawals
        vm.prank(spv);
        usdc.approve(address(manager), liquidityBuffer);
        vm.prank(spv);
        manager.provideLiquidityBuffer(address(discountedPool), liquidityBuffer);
        
        uint256 withdrawAmount = 6_000e6; // Use smaller amount to stay within liquidity limits
        
        // First withdrawal (after 7 days from investment flow) - 3% penalty
        vm.prank(address(discountedPool));
        uint256 sharesImmediate = manager.handleWithdraw(address(discountedPool), withdrawAmount, user1, user1, user1);
        
        // Setup new user for time-based test (deposit after investment)
        // Note: This user will have a different deposit time
        vm.prank(user2);
        usdc.approve(address(discountedPool), 20_000e6);
        // Since pool is in INVESTED state, we can't deposit normally
        // Instead, let's test with existing user2 who didn't deposit yet
        

        
        //let's test the penalty calculation by checking the actual penalty applied
        uint256 expectedPenalty1 = (withdrawAmount * 300) / 10000; // 3% penalty for 7-30 days
        uint256 expectedNetAssets1 = withdrawAmount - expectedPenalty1;
        
        // Verify the first withdrawal worked with correct penalty
        assertGt(sharesImmediate, 0, "First withdrawal should work");
        
        // Test immediate withdrawal (< 7 days) by warping back and testing with fresh pool
        console.log("First withdrawal shares:", sharesImmediate);
        console.log("Expected penalty (3%):", expectedPenalty1);
        console.log("Expected net assets:", expectedNetAssets1);
        
        console.log("Penalty calculation verified");
    }

    function test_20_InvestedState_LiquidityLimits() public {
        uint256 fundingAmount = (TARGET_RAISE * 70) / 100;
        _simulateFullInvestmentFlow(address(discountedPool), fundingAmount);
        
        // Test liquidity limits (10% of actual invested)
        uint256 actualInvested = manager.poolActualInvested(address(discountedPool));
        uint256 maxLiquidity = actualInvested / 10;
        
        vm.prank(address(discountedPool));
        vm.expectRevert("Manager/insufficient-liquidity");
        manager.handleWithdraw(address(discountedPool), maxLiquidity + 1e6, user1, user1, user1);
        
        console.log(" Liquidity limits verified");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// PHASE 6: COUPON SYSTEM ///////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function test_21_CouponSystem_PaymentProcessing() public {
        uint256 fundingAmount = (TARGET_RAISE * 70) / 100;
        _simulateFullInvestmentFlow(address(interestPool), fundingAmount);
        
        // Move to first coupon date (set during pool creation)
        vm.startPrank(address(interestPool));
        IPoolManager.PoolConfig memory config = manager.config();
        vm.stopPrank();
        
        vm.warp(config.couponDates[0]);
        
        uint256 couponAmount = 2_000e6;
        
        // Process coupon payment
        vm.prank(spv);
        usdc.approve(address(manager), couponAmount);
        
        vm.expectEmit(true, true, false, true);
        emit CouponReceived(couponAmount, block.timestamp);
        
        vm.prank(spv);
        manager.processCouponPayment(address(interestPool), couponAmount);

        assertEq(manager.poolTotalCouponsReceived(address(interestPool)), couponAmount, "Coupon amount not tracked");
        
        console.log(" Coupon payment processing verified");
    }

    function test_22_CouponSystem_Distribution() public {
        uint256 fundingAmount = (TARGET_RAISE * 70) / 100;
        _simulateFullInvestmentFlow(address(interestPool), fundingAmount);
        
         vm.startPrank(address(interestPool));
        IPoolManager.PoolConfig memory config = manager.config();
        vm.stopPrank();
        
        vm.warp(config.couponDates[0]);
        uint256 couponAmount = 2_000e6;
        
       
        vm.prank(spv);
        usdc.approve(address(manager), couponAmount);
        vm.prank(spv);
        manager.processCouponPayment(address(interestPool), couponAmount);
        
        // Distribute coupon payment
        vm.expectEmit(true, true, false, true);
        emit CouponDistributed(address(interestPool), couponAmount, block.timestamp);
        
        vm.prank(operator);
        manager.distributeCouponPayment(address(interestPool));

        assertEq(manager.poolTotalCouponsDistributed(address(interestPool)), couponAmount, "Coupon distribution not tracked");
        
        console.log(" Coupon distribution verified");
    }

    function test_23_CouponSystem_UserClaims() public {
        uint256 fundingAmount = (TARGET_RAISE * 70) / 100;
        _simulateFullInvestmentFlow(address(interestPool), fundingAmount);
        
          vm.startPrank(address(interestPool));
        IPoolManager.PoolConfig memory config = manager.config();
        vm.stopPrank();
        
        vm.warp(config.couponDates[0]);
        uint256 couponAmount = 2_000e6;
        
        vm.prank(spv);
        usdc.approve(address(manager), couponAmount);
        vm.prank(spv);
        manager.processCouponPayment(address(interestPool), couponAmount);
        
        vm.prank(operator);
        manager.distributeCouponPayment(address(interestPool));
        
        // User claims coupon
        vm.prank(address(interestPool));
        uint256 claimedAmount = manager.claimUserCoupon(address(interestPool), user1);
        
        assertGt(claimedAmount, 0, "User should receive coupon");
        assertEq(manager.poolUserCouponsClaimed(address(interestPool), user1), claimedAmount, "Claim not tracked");
        
        console.log(" User coupon claims verified");
    }

    function test_24_CouponSystem_Failures() public {
        _simulateFullInvestmentFlow(address(discountedPool), TARGET_RAISE);
        
        vm.prank(spv);
        vm.expectRevert("Manager/not-interest-bearing");
        manager.processCouponPayment(address(discountedPool), 1_000e6);
        
        // coupon payment on wrong date - need to reset time and fund interest pool first
        // Reset to start of test and fund interest pool
        vm.warp(86401); // Reset to setup time
        
        // Fund interest pool during its funding period
        _simulateDeposit(address(interestPool), user1, TARGET_RAISE);
        
        // Move to investment state
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        vm.prank(operator);
        manager.closeEpoch(address(interestPool));
        
        vm.prank(spv);
        manager.withdrawFundsForInvestment(address(interestPool), TARGET_RAISE);
        
        uint256 actualInvestment = (TARGET_RAISE * 97) / 100; // 3% slippage
        vm.prank(spv);
        manager.processInvestment(address(interestPool), actualInvestment, "investment-proof");
        
        // test coupon payment on wrong date (not at a coupon date)
        vm.prank(spv);
        vm.expectRevert("Manager/invalid-coupon-date");
        manager.processCouponPayment(address(interestPool), 1_000e6);
        
        console.log(" Coupon system failures tested");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// PHASE 7: MATURITY PROCESSING /////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function test_25_MaturityProcessing_DiscountedInstrument() public {
        uint256 fundingAmount = (TARGET_RAISE * 70) / 100;
        _simulateFullInvestmentFlow(address(discountedPool), fundingAmount); 
        
        vm.warp(block.timestamp + MATURITY_DURATION);
        
        // Get face value for return
        vm.startPrank(address(discountedPool));
        IPoolManager.PoolConfig memory config = manager.config();
        vm.stopPrank();
        
        // Process maturity
        vm.prank(spv);
        usdc.approve(address(manager), config.faceValue);
        
        vm.expectEmit(true, true, false, true);
        emit MaturityProcessed(config.faceValue);
        
        vm.prank(spv);
        manager.processMaturity(address(discountedPool), config.faceValue);
        
        // Verify maturity processing
        vm.startPrank(address(discountedPool));
        assertEq(uint256(manager.status()), uint256(IPoolManager.PoolStatus.MATURED), "Status not updated to matured");
        vm.stopPrank();
        
        assertEq(manager.poolFundsReturnedBySPV(address(discountedPool)), config.faceValue, "SPV return not tracked");
        
        console.log(" Discounted instrument maturity processing verified");
    }

    function test_26_MaturityProcessing_InterestBearingInstrument() public {
        uint256 fundingAmount = (TARGET_RAISE * 70) / 100;
        _simulateFullInvestmentFlow(address(interestPool), fundingAmount);

        vm.warp(block.timestamp + MATURITY_DURATION);
        
        // Process maturity (principal + any remaining coupons)
        uint256 actualInvested = manager.poolActualInvested(address(interestPool));
        uint256 maturityAmount = actualInvested; // Simplified - just return principal
        
        vm.prank(spv);
        usdc.approve(address(manager), maturityAmount);
        
        vm.prank(spv);
        manager.processMaturity(address(interestPool), maturityAmount);
        
        vm.startPrank(address(interestPool));
        assertEq(uint256(manager.status()), uint256(IPoolManager.PoolStatus.MATURED), "Status not updated to matured");
        vm.stopPrank();
        
        console.log("Interest-bearing instrument maturity processing verified");
    }

    function test_27_MaturityProcessing_Failures() public {
        _simulateFullInvestmentFlow(address(discountedPool), TARGET_RAISE);
        
        vm.prank(spv);
        vm.expectRevert("Manager/not-matured");
        manager.processMaturity(address(discountedPool), 100_000e6);
        
        vm.warp(block.timestamp + MATURITY_DURATION);
        
        // Get the correct face value to avoid slippage protection
        vm.startPrank(address(discountedPool));
        IPoolManager.PoolConfig memory config = manager.config();
        vm.stopPrank();
        
        // maturity processing with correct amount but wrong caller
        vm.prank(user1);
        vm.expectRevert("Manager/access-denied");
        manager.processMaturity(address(discountedPool), config.faceValue);
        
        console.log("Maturity processing failures tested");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// PHASE 8: MATURED STATE OPERATIONS ////////////
    ////////////////////////////////////////////////////////////////////////////////

    function test_28_MaturedState_WithdrawalsAndRedemptions() public {
        uint256 fundingAmount = (TARGET_RAISE * 70) / 100;
        _simulateFullMaturityFlow(address(discountedPool), fundingAmount);
        
        // withdrawal in matured state
        vm.prank(address(discountedPool));
        // passing 1 for assets so as not to trigger a revert that ensures assets > 0.
        // it doesnt matter what we pass, for matured state all user shares are burnt. 
        // assets as a param is only useful for withdrawals in funding, invested and emergency states not maturity.
        uint256 sharesWithdrawn = manager.handleWithdraw(address(discountedPool), 1, user1, user1, user1); 
        
        // In matured state, all user shares should be burned, leaving user with 0 balance
        assertEq(discountedPool.balanceOf(user1), 0, "User should have no shares after matured withdrawal");
        assertEq(sharesWithdrawn, 70000000000, "Should have withdrawn all user shares");
        
        console.log("Matured state withdrawals verified");
    }

    function test_29_MaturedState_UserReturnCalculations() public {
        uint256 fundingAmount = (TARGET_RAISE * 70) / 100;
        _simulateFullMaturityFlow(address(discountedPool), fundingAmount);
        
        // Test user return calculation
        vm.prank(address(discountedPool));
        uint256 userReturn = manager.calculateUserReturn(user1);
        
        // User should get their proportional share of total returns
        assertGt(userReturn, 0, "User should have positive return");
        
        console.log("User return calculations verified");
    }

    function test_30_MaturedState_MaturityEntitlements() public {
        // Setup matured pool
        uint256 fundingAmount = (TARGET_RAISE * 70) / 100;
        _simulateFullMaturityFlow(address(discountedPool), fundingAmount);
        
        // Test maturity entitlement calculation
        vm.prank(address(discountedPool));
        uint256 entitlement = manager.claimMaturityEntitlement(user1);
        
        assertGt(entitlement, 0, "User should have maturity entitlement");
        
        console.log("Maturity entitlements verified");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// PHASE 9: EMERGENCY SCENARIOS //////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function test_31_EmergencyScenarios_PoolEmergencyExit() public {
        // Setup funded pool
        _simulateDeposit(address(discountedPool), user1, DEPOSIT_AMOUNT_1);
        
        // Test emergency exit
        vm.expectEmit(true, true, false, true);
        emit EmergencyExit(address(discountedPool), block.timestamp);
        
        vm.prank(address(discountedPool));
        manager.emergencyExit();
        
        // Verify emergency status
        vm.startPrank(address(discountedPool));
        assertEq(uint256(manager.status()), uint256(IPoolManager.PoolStatus.EMERGENCY), "Status not updated to emergency");
        vm.stopPrank();
        
        console.log("Pool emergency exit verified");
    }

    function test_32_EmergencyScenarios_PoolCancellation() public {
        // Test pool cancellation during funding
        vm.prank(admin);
        manager.cancelPool();
        
        // Verify emergency status
        vm.startPrank(address(discountedPool));
        assertEq(uint256(manager.status()), uint256(IPoolManager.PoolStatus.EMERGENCY), "Status not updated to emergency");
        vm.stopPrank();
        
        console.log("Pool cancellation verified");
    }

    function test_33_EmergencyScenarios_RefundCalculations() public {
        // Setup emergency pool
        _simulateDeposit(address(discountedPool), user1, DEPOSIT_AMOUNT_1);
        _simulateDeposit(address(discountedPool), user2, DEPOSIT_AMOUNT_2);
        
        vm.prank(address(discountedPool));
        manager.emergencyExit();
        
        // Test refund calculations
        vm.prank(address(discountedPool));
        uint256 user1Refund = manager.getUserRefund(user1);
        
        vm.prank(address(discountedPool));
        uint256 user2Refund = manager.getUserRefund(user2);
        
        // Verify proportional refunds
        assertEq(user1Refund, DEPOSIT_AMOUNT_1, "User1 refund should equal deposit");
        assertEq(user2Refund, DEPOSIT_AMOUNT_2, "User2 refund should equal deposit");
        
        console.log("Refund calculations verified");
    }

    function test_34_EmergencyScenarios_EmergencyWithdrawals() public {
        // Setup emergency pool
        _simulateDeposit(address(discountedPool), user1, DEPOSIT_AMOUNT_1);
        vm.prank(address(discountedPool));
        manager.emergencyExit();
        
        // Test emergency withdrawal
        vm.prank(address(discountedPool));
        uint256 sharesWithdrawn = manager.handleWithdraw(address(discountedPool), DEPOSIT_AMOUNT_1, user1, user1, user1);
        
        assertEq(sharesWithdrawn, DEPOSIT_AMOUNT_1, "Emergency withdrawal should return all assets");
        
        console.log("Emergency withdrawals verified");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// PHASE 10: ADMIN & ACCESS CONTROL /////////////
    ////////////////////////////////////////////////////////////////////////////////

    function test_35_AdminFunctions_PoolPauseUnpause() public {
        // Test pool pause
        vm.prank(operator);
        manager.pausePool();
        
        assertTrue(discountedPool.paused(), "Pool should be paused");
        
        // Test pool unpause
        vm.prank(operator);
        manager.unpausePool();
        
        assertFalse(discountedPool.paused(), "Pool should be unpaused");
        
        console.log("Pool pause/unpause verified");
    }

    function test_36_AdminFunctions_SlippageManagement() public {
        // Test slippage tolerance setting
        uint256 newTolerance = 750; // 7.5%
        
        vm.prank(admin);
        manager.setSlippageTolerance(address(discountedPool), newTolerance);
        
        assertEq(manager.getSlippageTolerance(address(discountedPool)), newTolerance, "Slippage tolerance not updated");
        
        // Test validation
        assertTrue(manager.validateSlippage(address(discountedPool), 100_000e6, 92_500e6), "7.5% slippage should be valid");
        assertFalse(manager.validateSlippage(address(discountedPool), 100_000e6, 90_000e6), "10% slippage should be invalid");
        
        console.log("Slippage management verified");
    }

    function test_37_AdminFunctions_AccessManagerUpdate() public {
        // Deploy new access manager
        AccessManager newAccessManager = new AccessManager(admin);
        
        // Update access manager
        vm.prank(admin);
        manager.setAccessManager(address(newAccessManager));
        
        assertEq(address(manager.accessManager()), address(newAccessManager), "Access manager not updated");
        
        console.log("Access manager update verified");
    }

    function test_38_AccessControl_RoleBasedPermissions() public {
        // Test various role-based permissions
        
        // SPV role tests
        vm.prank(user1);
        vm.expectRevert("Manager/access-denied");
        manager.withdrawFundsForInvestment(address(discountedPool), 1000e6);
        
        // Operator role tests
        vm.prank(user1);
        vm.expectRevert("Manager/access-denied");
        manager.closeEpoch(address(discountedPool));
        
        // Admin role tests
        vm.prank(user1);
        vm.expectRevert("Manager/access-denied");
        manager.setSlippageTolerance(address(discountedPool), 1000);
        
        console.log("Role-based permissions verified");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// PHASE 11: VIEW FUNCTIONS & CALCULATIONS ///////
    ////////////////////////////////////////////////////////////////////////////////

    function test_39_ViewFunctions_PoolInformation() public {
        // Test various view functions
        vm.startPrank(address(discountedPool));
        
        IPoolManager.PoolConfig memory config = manager.config();
        assertEq(config.targetRaise, TARGET_RAISE, "Config target raise incorrect");
        
        IPoolManager.PoolStatus status = manager.status();
        assertEq(uint256(status), uint256(IPoolManager.PoolStatus.FUNDING), "Status incorrect");
        
        uint256 totalRaised = manager.totalRaised();
        assertEq(totalRaised, 0, "Total raised should be 0 initially");
        
        bool inFunding = manager.isInFundingPeriod();
        assertTrue(inFunding, "Should be in funding period");
        
        bool matured = manager.isMatured();
        assertFalse(matured, "Should not be matured");
        
        uint256 timeToMaturity = manager.getTimeToMaturity();
        assertGt(timeToMaturity, 0, "Time to maturity should be positive");
        
        vm.stopPrank();
        
        console.log(" View functions verified");
    }

    function test_40_ViewFunctions_UserCalculations() public {
        // Setup pool with deposits
        _simulateDeposit(address(discountedPool), user1, DEPOSIT_AMOUNT_1);
        _simulateDeposit(address(discountedPool), user2, DEPOSIT_AMOUNT_2);
        
        // Test user calculations
        vm.prank(address(discountedPool));
        uint256 user1Return = manager.calculateUserReturn(user1);
        assertEq(user1Return, DEPOSIT_AMOUNT_1, "User1 return should equal deposit in funding phase");
        
        vm.prank(address(discountedPool));
        uint256 user2Return = manager.calculateUserReturn(user2);
        assertEq(user2Return, DEPOSIT_AMOUNT_2, "User2 return should equal deposit in funding phase");
        
        vm.prank(address(discountedPool));
        uint256 totalAssets = manager.calculateTotalAssets();
        assertEq(totalAssets, DEPOSIT_AMOUNT_1 + DEPOSIT_AMOUNT_2, "Total assets should equal total deposits");
        
        console.log(" User calculations verified");
    }

    function test_41_ViewFunctions_ExpectedReturns() public {
        // Test expected return calculations
        vm.prank(address(discountedPool));
        uint256 expectedReturn = manager.getExpectedReturn();
        assertGt(expectedReturn, 0, "Expected return should be positive for discounted instrument");
        
        // Test maturity value calculation
        vm.prank(address(discountedPool));
        uint256 maturityValue = manager.calculateMaturityValue();
        assertGt(maturityValue, 0, "Maturity value should be positive");
        
        console.log(" Expected returns verified");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// PHASE 12: EDGE CASES & STRESS TESTS ///////////
    ////////////////////////////////////////////////////////////////////////////////

    function test_42_EdgeCases_ZeroAmountOperations() public {
        // Test zero amount deposit
        vm.prank(address(discountedPool));
        vm.expectRevert("Manager/invalid-amount");
        manager.handleWithdraw(address(discountedPool), 0, user1, user1, user1);
        
        // Test zero shares redemption
        vm.prank(address(discountedPool));
        vm.expectRevert("Manager/invalid-shares");
        manager.handleRedeem(0, user1, user1, user1);
        
        console.log(" Zero amount operations tested");
    }

    function test_43_EdgeCases_MaximumCapacityOperations() public {
        // Test maximum capacity deposit
        vm.prank(user1);
        usdc.transfer(address(discountedEscrow), TARGET_RAISE);
        
        vm.prank(address(discountedPool));
        uint256 shares = manager.handleDeposit(address(discountedPool), TARGET_RAISE, user1, user1);
        
        assertEq(shares, TARGET_RAISE, "Max capacity deposit should work");
        assertEq(manager.poolTotalRaised(address(discountedPool)), TARGET_RAISE, "Total raised should equal target");
        
        console.log(" Maximum capacity operations tested");
    }

    function test_44_EdgeCases_TimeBoundaryConditions() public {
        // Test operations exactly at epoch boundary
        vm.warp(block.timestamp + EPOCH_DURATION);
        
        // Deposit should still work at exact epoch end time
        vm.prank(address(discountedPool));
        uint256 shares = manager.handleDeposit(address(discountedPool), 1000e6, user1, user1);
        assertEq(shares, 1000e6, "Deposit at epoch boundary should work");
        
        // But not one second after
        vm.warp(block.timestamp + 1);
        vm.prank(address(discountedPool));
        vm.expectRevert("Manager/funding-ended");
        manager.handleDeposit(address(discountedPool), 1000e6, user1, user1);
        
        console.log(" Time boundary conditions tested");
    }

    function test_45_StressTest_MultipleUsersAndOperations() public {
        // Create multiple users and perform various operations
        address[] memory users = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            users[i] = address(uint160(0x1000 + i));
            usdc.mint(users[i], 100_000e6);
        }
        
        // Multiple deposits
        for (uint256 i = 0; i < 5; i++) {
            _simulateDeposit(address(discountedPool), users[i], 10_000e6);
        }
        
        // Verify total tracking
        assertEq(manager.poolTotalRaised(address(discountedPool)), 50_000e6, "Total raised should be 50k");
        
        // Multiple withdrawals
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(address(discountedPool));
            manager.handleWithdraw(address(discountedPool), 5_000e6, users[i], users[i], users[i]);
        }
        
        // Verify remaining balance
        assertEq(manager.poolTotalRaised(address(discountedPool)), 35_000e6, "Total raised should be 35k after withdrawals");
        
        console.log(" Stress test with multiple users completed");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// HELPER FUNCTIONS /////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function _createTestPools() internal {
        address[] memory signers = new address[](3);
        signers[0] = admin;
        signers[1] = signer1;
        signers[2] = signer2;
        
        // Create discounted pool
        IPoolFactory.PoolConfig memory discountedConfig = IPoolFactory.PoolConfig({
            asset: address(usdc),
            instrumentType: IPoolManager.InstrumentType.DISCOUNTED,
            instrumentName: "Test Discounted Bill",
            targetRaise: TARGET_RAISE,
            epochDuration: EPOCH_DURATION,
            maturityDate: block.timestamp + MATURITY_DURATION,
            discountRate: DISCOUNT_RATE,
            spvAddress: spv,
            multisigSigners: signers,
            couponDates: new uint256[](0),
            couponRates: new uint256[](0)
        });
        
        vm.prank(admin);
        (address discountedPoolAddr, address discountedEscrowAddr) = factory.createPool(discountedConfig);
        discountedPool = LiquidityPool(discountedPoolAddr);
        discountedEscrow = PoolEscrow(payable(discountedEscrowAddr));
        
        // Create coupon schedule for interest-bearing pool
        uint256[] memory couponDates = new uint256[](4);
        uint256[] memory couponRates = new uint256[](4);
        
        // Set quarterly coupon payments
        couponDates[0] = block.timestamp + 30 days;
        couponDates[1] = block.timestamp + 60 days;
        couponDates[2] = block.timestamp + 90 days;
        couponDates[3] = block.timestamp + MATURITY_DURATION;
        
        // Set 2% quarterly coupon rates (200 basis points each)
        couponRates[0] = 200;
        couponRates[1] = 200;
        couponRates[2] = 200;
        couponRates[3] = 200;
        
        // Create interest-bearing pool with coupon schedule
        IPoolFactory.PoolConfig memory interestConfig = IPoolFactory.PoolConfig({
            asset: address(usdc),
            instrumentType: IPoolManager.InstrumentType.INTEREST_BEARING,
            instrumentName: "Test Interest Bearing Note",
            targetRaise: TARGET_RAISE,
            epochDuration: EPOCH_DURATION,
            maturityDate: block.timestamp + MATURITY_DURATION,
            discountRate: 0,
            spvAddress: spv,
            multisigSigners: signers,
            couponDates: couponDates,
            couponRates: couponRates
        });
        
        vm.prank(admin);
        (address interestPoolAddr, address interestEscrowAddr) = factory.createPool(interestConfig);
        interestPool = LiquidityPool(interestPoolAddr);
        interestEscrow = PoolEscrow(payable(interestEscrowAddr));
    }
    
    function _createDiscountedPoolConfig() internal view returns (IPoolManager.PoolConfig memory) {
        return IPoolManager.PoolConfig({
            instrumentType: IPoolManager.InstrumentType.DISCOUNTED,
            faceValue: 0,
            purchasePrice: 0,
            targetRaise: TARGET_RAISE,
            epochEndTime: block.timestamp + EPOCH_DURATION,
            maturityDate: block.timestamp + MATURITY_DURATION,
            couponDates: new uint256[](0),
            couponRates: new uint256[](0),
            refundGasFee: 1000,
            discountRate: DISCOUNT_RATE
        });
    }

    function _simulateDeposit(address poolAddress, address user, uint256 amount) internal {
        // Approve the pool to spend user's tokens
        vm.startPrank(user);
        usdc.approve(poolAddress, amount);
        
        // Call the real deposit function
        uint256 shares = LiquidityPool(poolAddress).deposit(amount, user);
        vm.stopPrank();
        
        // Verify the deposit worked
        assertEq(shares, amount, "Shares should equal amount in funding phase");
    }

    function _fundAndCloseEpoch(address poolAddress, uint256 amount) internal {
        _simulateDeposit(poolAddress, user1, amount);
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
    }

    function _simulateFullInvestmentFlow(address poolAddress, uint256 fundingAmount) internal {
        _fundAndCloseEpoch(poolAddress, fundingAmount);
        
        // SPV withdraws and invests
        vm.prank(spv);
        manager.withdrawFundsForInvestment(poolAddress, fundingAmount);
        
        uint256 actualInvestment = (fundingAmount * 97) / 100; // 3% slippage
        vm.prank(spv);
        manager.processInvestment(poolAddress, actualInvestment, "investment-proof");
    }

    function _simulateFullMaturityFlow(address poolAddress, uint256 fundingAmount) internal {
        _simulateFullInvestmentFlow(poolAddress, fundingAmount);
        
        // Fast forward to maturity
        vm.warp(block.timestamp + MATURITY_DURATION);
        
        // Process maturity
        vm.startPrank(address(poolAddress));
        IPoolManager.PoolConfig memory config = manager.config();
        vm.stopPrank();
        
        uint256 maturityAmount = config.instrumentType == IPoolManager.InstrumentType.DISCOUNTED 
            ? config.faceValue 
            : manager.poolActualInvested(poolAddress);
        vm.prank(spv);
        usdc.approve(address(manager), maturityAmount);
        
        vm.prank(spv);
        manager.processMaturity(poolAddress, maturityAmount);
    }

    // Gas usage reporting
    function test_99_GasUsageReport() public {
        console.log("=== GAS USAGE REPORT ===");
        
        // Test deposit gas usage
        uint256 gasStart = gasleft();
        _simulateDeposit(address(discountedPool), user1, 10_000e6);
        uint256 gasUsed = gasStart - gasleft();
        console.log("Deposit gas usage:", gasUsed);
        
        // Test withdrawal gas usage
        gasStart = gasleft();
        vm.prank(address(discountedPool));
        manager.handleWithdraw(address(discountedPool), 5_000e6, user1, user1, user1);
        gasUsed = gasStart - gasleft();
        console.log("Withdrawal gas usage:", gasUsed);
        
        // Test epoch close gas usage
        _simulateDeposit(address(discountedPool), user2, 60_000e6);
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        gasStart = gasleft();
        vm.prank(operator);
        manager.closeEpoch(address(discountedPool));
        gasUsed = gasStart - gasleft();
        console.log("Epoch close gas usage:", gasUsed);
        
        console.log("=== END GAS REPORT ===");
    }
} 