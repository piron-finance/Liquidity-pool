// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../fixtures/BaseTest.sol";
import "../../src/LiquidityPool.sol";
import "../../src/interfaces/ILiquidityPool.sol";
import "../../src/interfaces/IManager.sol";
import "../../src/interfaces/IPoolEscrow.sol";
import "../../src/types/IPoolTypes.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title MockPoolManager
 * @notice Mock manager for testing LiquidityPool
 */
contract MockPoolManager is IPoolManager {
    uint256 public totalAssets;
    uint8 public poolStatus;
    uint256 public totalRaised;
    mapping(address => uint256) public userReturns;
    mapping(address => uint256) public userDiscounts;
    mapping(address => uint256) public userCoupons;
    mapping(address => uint256) public depositTimes;
    mapping(address => uint256) public poolRaised;
    
    bool public isInFunding;
    bool public isMaturedFlag;
    uint256 public timeToMaturity;
    uint256 public expectedReturn;
    
    IPoolTypes.PoolConfig public poolConfig;
    
    function setTotalAssets(uint256 _totalAssets) external {
        totalAssets = _totalAssets;
    }
    
    function setPoolStatus(uint8 _status) external {
        poolStatus = _status;
    }
    
    function setUserReturn(address user, uint256 amount) external {
        userReturns[user] = amount;
    }
    
    function setUserCoupon(address user, uint256 amount) external {
        userCoupons[user] = amount;
    }
    
    function setIsInFunding(bool _isInFunding) external {
        isInFunding = _isInFunding;
    }
    
    function setPoolTotalRaised(address pool, uint256 amount) external {
        poolRaised[pool] = amount;
    }
    
    function handleDeposit(
        address,
        uint256 assets,
        address,
        address sender
    ) external returns (uint256 shares) {
        depositTimes[sender] = block.timestamp;
        totalRaised += assets;
        return assets; // 1:1 for testing
    }
    
    function handleWithdraw(
        address,
        uint256 assets,
        address,
        address /* owner */,
        address
    ) external returns (uint256 shares) {
        return assets; // 1:1 for testing
    }
    
    function calculateTotalAssets() external view returns (uint256) {
        return totalAssets;
    }
    
    function calculateUserReturn(address user) external view returns (uint256) {
        return userReturns[user];
    }
    
    function calculateUserDiscount(address user) external view returns (uint256) {
        return userDiscounts[user];
    }
    
    function getUserAvailableCoupon(address, address user) external view returns (uint256) {
        return userCoupons[user];
    }
    
    function claimUserCoupon(address, address user) external returns (uint256) {
        uint256 amount = userCoupons[user];
        userCoupons[user] = 0;
        return amount;
    }
    
    function isInFundingPeriod() external view returns (bool) {
        return isInFunding;
    }
    
    function isMatured() external view returns (bool) {
        return isMaturedFlag;
    }
    
    function getTimeToMaturity() external view returns (uint256) {
        return timeToMaturity;
    }
    
    function getExpectedReturn() external view returns (uint256) {
        return expectedReturn;
    }
    
    function getPoolStatus() external view returns (uint8) {
        return poolStatus;
    }
    
    function poolTotalRaised(address pool) external view returns (uint256) {
        return poolRaised[pool];
    }
    
    function userDepositTime(address user) external view returns (uint256) {
        return depositTimes[user];
    }
    
    // Stub implementations
    function escrow() external view returns (address) { return address(0); }
    function config() external view returns (IPoolTypes.PoolConfig memory) { return poolConfig; }
    function status() external view returns (IPoolTypes.PoolStatus) { return IPoolTypes.PoolStatus.FUNDING; }
    function actualInvested() external view returns (uint256) { return 0; }
    function totalDiscountEarned() external view returns (uint256) { return 0; }
    function totalCouponsReceived() external view returns (uint256) { return 0; }
    function processInvestment(address, uint256, string memory) external {}
    function processCouponPayment(address, uint256) external {}
    function processMaturity(address, uint256) external {}
    function claimMaturityEntitlement(address) external view returns (uint256) { return 0; }
    function emergencyExit() external {}
    function pausePool(address) external {}
    function unpausePool(address) external {}
    function closeEpoch(address) external {}
    function initializePool(address, IPoolTypes.PoolConfig memory) external {}
    function getUnclaimedCoupons(address) external view returns (uint256) { return 0; }
    function setTimelockController(address) external {}
    function version() external view returns (uint256) { return 1; }
}

/**
 * @title MockPoolEscrow
 * @notice Mock escrow for testing LiquidityPool
 */
contract MockPoolEscrow is IPoolEscrow {
    address public pool;
    address public manager;
    address public spvAddress;
    uint256 public balance;
    
    function setPool(address _pool) external {
        pool = _pool;
    }
    
    function setManager(address _manager) external {
        manager = _manager;
    }
    
    function receiveDeposit(address, uint256 amount) external {
        balance += amount;
    }
    
    function releaseFunds(address, uint256 amount) external {
        require(balance >= amount, "Insufficient balance");
        balance -= amount;
    }
    
    function getBalance() external view returns (uint256) {
        return balance;
    }
    
    // Stub implementations
    function getTransfer(bytes32) external pure returns (Transfer memory) {
        return Transfer({
            transferType: TransferType.TO_SPV,
            recipient: address(0),
            amount: 0,
            data: "",
            confirmations: 0,
            executed: false,
            timestamp: 0
        });
    }
    function lockFunds(uint256) external {}
    function trackCouponPayment(uint256) external {}
    function trackMaturityReturn(uint256) external {}
    function claimCoupon(address, uint256) external {}
    function withdrawForInvestment(uint256) external returns (bytes32) { return bytes32(0); }
    function canWithdrawForInvestment(uint256) external pure returns (bool) { return true; }
}

/**
 * @title LiquidityPoolTest
 * @notice Comprehensive unit tests for LiquidityPool contract
 */
contract LiquidityPoolTest is BaseTest {
    
    LiquidityPool public poolImplementation;
    LiquidityPool public pool;
    MockPoolManager public mockManager;
    MockPoolEscrow public mockEscrow;
    MockERC20 public token;
    
    // Events to test
    event RefundSet(address indexed user, uint256 amount);
    event DiscountAccrued(address indexed user, uint256 amount);
    event RefundClaimed(address indexed user, uint256 amount);
    event EmergencyWithdrawal(address indexed user, uint256 refundAmount, uint256 sharesBurned);
    event CouponClaimed(address indexed user, uint256 amount);
    
    function setUp() public override {
        super.setUp();
        
        // Deploy token
        token = new MockERC20("Mock USDC", "USDC", 6);
        
        // Deploy mocks
        mockManager = new MockPoolManager();
        mockEscrow = new MockPoolEscrow();
        
        // Deploy implementation
        poolImplementation = new LiquidityPool();
        
        // Deploy proxy
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,string,string,address,address)",
            address(token),
            "Piron Pool",
            "pPool",
            address(mockManager),
            address(mockEscrow)
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(poolImplementation),
            initData
        );
        
        pool = LiquidityPool(address(proxy));
        
        // Setup mocks
        mockEscrow.setPool(address(pool));
        mockEscrow.setManager(address(mockManager));
        mockManager.setPoolStatus(0); // FUNDING
        mockManager.setIsInFunding(true);
        mockManager.setTotalAssets(0);
        
        // Mint tokens to users
        token.mint(user1, INITIAL_BALANCE);
        token.mint(user2, INITIAL_BALANCE);
        token.mint(user3, INITIAL_BALANCE);
    }
    
    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_Initialize_Success() public view {
        assertEq(address(pool.asset()), address(token));
        assertEq(pool.name(), "Piron Pool");
        assertEq(pool.symbol(), "pPool");
        assertEq(address(pool.manager()), address(mockManager));
        assertEq(address(pool.escrow()), address(mockEscrow));
    }
    
    function test_Initialize_RevertIf_InvalidManager() public {
        LiquidityPool newPoolImpl = new LiquidityPool();
        
        bytes memory badInitData = abi.encodeWithSignature(
            "initialize(address,string,string,address,address)",
            address(token),
            "Test Pool",
            "tPool",
            address(0), // Invalid manager
            address(mockEscrow)
        );
        
        vm.expectRevert("LiquidityPool/invalid-manager");
        new ERC1967Proxy(address(newPoolImpl), badInitData);
    }
    
    function test_Initialize_RevertIf_InvalidEscrow() public {
        LiquidityPool newPoolImpl = new LiquidityPool();
        
        bytes memory badInitData = abi.encodeWithSignature(
            "initialize(address,string,string,address,address)",
            address(token),
            "Test Pool",
            "tPool",
            address(mockManager),
            address(0) // Invalid escrow
        );
        
        vm.expectRevert("LiquidityPool/invalid-escrow");
        new ERC1967Proxy(address(newPoolImpl), badInitData);
    }
    
    function test_Initialize_CannotReinitialize() public {
        vm.expectRevert();
        pool.initialize(
            token,
            "New Name",
            "NEW",
            address(mockManager),
            address(mockEscrow)
        );
    }
    
    /*//////////////////////////////////////////////////////////////
                        DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_Deposit_Success() public {
        uint256 depositAmount = 1000e6;
        
        vm.startPrank(user1);
        token.approve(address(pool), depositAmount);
        
        uint256 sharesMinted = pool.deposit(depositAmount, user1);
        vm.stopPrank();
        
        assertEq(sharesMinted, depositAmount); // 1:1 in mock
        assertEq(pool.balanceOf(user1), depositAmount);
        assertEq(token.balanceOf(address(mockEscrow)), depositAmount);
    }
    
    function test_Deposit_ToOtherReceiver() public {
        uint256 depositAmount = 1000e6;
        
        vm.startPrank(user1);
        token.approve(address(pool), depositAmount);
        
        pool.deposit(depositAmount, user2);
        vm.stopPrank();
        
        assertEq(pool.balanceOf(user2), depositAmount);
        assertEq(pool.balanceOf(user1), 0);
    }
    
    function test_Deposit_RevertIf_ZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert("LiquidityPool/Non zero deposits allowed");
        pool.deposit(0, user1);
    }
    
    function test_Deposit_RevertIf_InvalidReceiver() public {
        vm.prank(user1);
        vm.expectRevert("LiquidityPool/Valid addresses only");
        pool.deposit(1000e6, address(0));
    }
    
    function test_Deposit_RevertIf_InsufficientBalance() public {
        uint256 tooMuch = INITIAL_BALANCE + 1;
        
        vm.startPrank(user1);
        token.approve(address(pool), tooMuch);
        
        vm.expectRevert("LiquidityPool/Insufficient balance");
        pool.deposit(tooMuch, user1);
        vm.stopPrank();
    }
    
    function test_Deposit_RevertIf_Paused() public {
        // Pause the pool
        vm.prank(address(mockManager));
        pool.pause();
        
        vm.startPrank(user1);
        token.approve(address(pool), 1000e6);
        
        vm.expectRevert();
        pool.deposit(1000e6, user1);
        vm.stopPrank();
    }
    
    function test_Deposit_MultipleUsers() public {
        uint256 depositAmount = 1000e6;
        
        // User1 deposits
        vm.startPrank(user1);
        token.approve(address(pool), depositAmount);
        pool.deposit(depositAmount, user1);
        vm.stopPrank();
        
        // User2 deposits
        vm.startPrank(user2);
        token.approve(address(pool), depositAmount);
        pool.deposit(depositAmount, user2);
        vm.stopPrank();
        
        assertEq(pool.balanceOf(user1), depositAmount);
        assertEq(pool.balanceOf(user2), depositAmount);
        assertEq(pool.totalSupply(), depositAmount * 2);
    }
    
    /*//////////////////////////////////////////////////////////////
                        MINT TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_Mint_Success() public {
        uint256 sharesToMint = 1000e6;
        
        vm.startPrank(user1);
        token.approve(address(pool), sharesToMint);
        
        uint256 assetsPaid = pool.mint(sharesToMint, user1);
        vm.stopPrank();
        
        assertEq(assetsPaid, sharesToMint); // 1:1 in mock
        assertEq(pool.balanceOf(user1), sharesToMint);
    }
    
    function test_Mint_RevertIf_ZeroShares() public {
        vm.prank(user1);
        vm.expectRevert("LiquidityPool/Non zero shares allowed");
        pool.mint(0, user1);
    }
    
    function test_Mint_RevertIf_InvalidReceiver() public {
        vm.prank(user1);
        vm.expectRevert("LiquidityPool/Valid addresses only");
        pool.mint(1000e6, address(0));
    }
    
    /*//////////////////////////////////////////////////////////////
                        WITHDRAW TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_Withdraw_Success() public {
        // First deposit
        uint256 depositAmount = 1000e6;
        vm.startPrank(user1);
        token.approve(address(pool), depositAmount);
        pool.deposit(depositAmount, user1);
        vm.stopPrank();
        
        // Then withdraw
        uint256 withdrawAmount = 500e6;
        vm.prank(user1);
        uint256 sharesBurned = pool.withdraw(withdrawAmount, user1, user1);
        
        assertEq(sharesBurned, withdrawAmount);
    }
    
    function test_Withdraw_RevertIf_ZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert("LiquidityPool/Non zero assets allowed");
        pool.withdraw(0, user1, user1);
    }
    
    function test_Withdraw_RevertIf_InvalidReceiver() public {
        vm.prank(user1);
        vm.expectRevert("LiquidityPool/Valid addresses only");
        pool.withdraw(100e6, address(0), user1);
    }
    
    function test_Withdraw_RevertIf_InvalidOwner() public {
        vm.prank(user1);
        vm.expectRevert("LiquidityPool/Valid owner required");
        pool.withdraw(100e6, user1, address(0));
    }
    
    /*//////////////////////////////////////////////////////////////
                        REFUND TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_SetUserRefund_Success() public {
        uint256 refundAmount = 500e6;
        
        vm.prank(address(mockManager));
        vm.expectEmit(true, false, false, true);
        emit RefundSet(user1, refundAmount);
        
        pool.setUserRefund(user1, refundAmount);
        
        assertEq(pool.pendingRefunds(user1), refundAmount);
        assertEq(pool.totalPendingRefunds(), refundAmount);
    }
    
    function test_SetUserRefund_RevertIf_NotManager() public {
        vm.prank(user1);
        vm.expectRevert("Only manager can call");
        pool.setUserRefund(user1, 500e6);
    }
    
    function test_SetUserRefund_UpdatesTotal() public {
        vm.startPrank(address(mockManager));
        
        // Set initial refund
        pool.setUserRefund(user1, 100e6);
        assertEq(pool.totalPendingRefunds(), 100e6);
        
        // Increase refund
        pool.setUserRefund(user1, 200e6);
        assertEq(pool.totalPendingRefunds(), 200e6);
        
        // Decrease refund
        pool.setUserRefund(user1, 50e6);
        assertEq(pool.totalPendingRefunds(), 50e6);
        
        vm.stopPrank();
    }
    
    function test_ClaimRefund_Success() public {
        // Setup: User has deposited
        uint256 depositAmount = 1000e6;
        vm.startPrank(user1);
        token.approve(address(pool), depositAmount);
        pool.deposit(depositAmount, user1);
        vm.stopPrank();
        
        // Setup: Manager sets refund
        uint256 refundAmount = 500e6;
        vm.prank(address(mockManager));
        pool.setUserRefund(user1, refundAmount);
        
        // Setup: Mock manager's calculateUserReturn
        mockManager.setUserReturn(user1, 1000e6);
        
        uint256 sharesBefore = pool.balanceOf(user1);
        
        // Claim refund
        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit RefundClaimed(user1, refundAmount);
        
        pool.claimRefund();
        
        assertEq(pool.pendingRefunds(user1), 0);
        assertEq(pool.totalPendingRefunds(), 0);
        assertTrue(pool.balanceOf(user1) < sharesBefore); // Some shares burned
    }
    
    function test_ClaimRefund_RevertIf_NoRefundAvailable() public {
        vm.prank(user1);
        vm.expectRevert("LiquidityPool/no-refund-available");
        pool.claimRefund();
    }
    
    /*//////////////////////////////////////////////////////////////
                        DISCOUNT ACCRUAL TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_SetDiscountAccrued_Success() public {
        uint256 discountAmount = 100e6;
        
        vm.prank(address(mockManager));
        vm.expectEmit(true, false, false, true);
        emit DiscountAccrued(user1, discountAmount);
        
        pool.setDiscountAccrued(user1, discountAmount);
        
        assertEq(pool.discountedBillsAccrued(user1), discountAmount);
        assertEq(pool.totalDiscountAccrued(), discountAmount);
    }
    
    function test_SetDiscountAccrued_RevertIf_NotManager() public {
        vm.prank(user1);
        vm.expectRevert("Only manager can call");
        pool.setDiscountAccrued(user1, 100e6);
    }
    
    function test_SetDiscountAccrued_UpdatesTotal() public {
        vm.startPrank(address(mockManager));
        
        // Set for user1
        pool.setDiscountAccrued(user1, 100e6);
        assertEq(pool.totalDiscountAccrued(), 100e6);
        
        // Set for user2
        pool.setDiscountAccrued(user2, 200e6);
        assertEq(pool.totalDiscountAccrued(), 300e6);
        
        // Decrease user1
        pool.setDiscountAccrued(user1, 50e6);
        assertEq(pool.totalDiscountAccrued(), 250e6);
        
        vm.stopPrank();
    }
    
    /*//////////////////////////////////////////////////////////////
                        COUPON CLAIM TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_ClaimCoupon_Success() public {
        uint256 couponAmount = 100e6;
        
        // Setup: Manager has coupon for user
        mockManager.setUserCoupon(user1, couponAmount);
        
        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit CouponClaimed(user1, couponAmount);
        
        uint256 claimed = pool.claimCoupon();
        
        assertEq(claimed, couponAmount);
    }
    
    function test_ClaimCoupon_RevertIf_NoCouponAvailable() public {
        mockManager.setUserCoupon(user1, 0);
        
        vm.prank(user1);
        vm.expectRevert("LiquidityPool/no-coupon-available");
        pool.claimCoupon();
    }
    
    function test_GetUserCouponAmount() public {
        uint256 couponAmount = 100e6;
        mockManager.setUserCoupon(user1, couponAmount);
        
        assertEq(pool.getUserCouponAmount(user1), couponAmount);
    }
    
    /*//////////////////////////////////////////////////////////////
                        EMERGENCY WITHDRAWAL TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_EmergencyWithdraw_Success() public {
        // Setup: User has shares
        uint256 depositAmount = 1000e6;
        vm.startPrank(user1);
        token.approve(address(pool), depositAmount);
        pool.deposit(depositAmount, user1);
        vm.stopPrank();
        
        uint256 userShares = pool.balanceOf(user1);
        
        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit EmergencyWithdrawal(user1, userShares, userShares);
        
        pool.emergencyWithdraw();
    }
    
    function test_EmergencyWithdraw_RevertIf_NoShares() public {
        vm.prank(user1);
        vm.expectRevert("LiquidityPool/no-shares");
        pool.emergencyWithdraw();
    }
    
    /*//////////////////////////////////////////////////////////////
                        MANAGER-ONLY FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_MintShares_Success() public {
        uint256 sharesToMint = 1000e6;
        
        vm.prank(address(mockManager));
        pool.mintShares(sharesToMint, user1);
        
        assertEq(pool.balanceOf(user1), sharesToMint);
        assertEq(pool.totalSupply(), sharesToMint);
    }
    
    function test_MintShares_RevertIf_NotManager() public {
        vm.prank(user1);
        vm.expectRevert("Only manager can call");
        pool.mintShares(1000e6, user1);
    }
    
    function test_BurnShares_Success() public {
        // First mint shares
        vm.prank(address(mockManager));
        pool.mintShares(1000e6, user1);
        
        // Then burn
        uint256 burnAmount = 500e6;
        vm.prank(address(mockManager));
        pool.burnShares(user1, burnAmount);
        
        assertEq(pool.balanceOf(user1), 500e6);
        assertEq(pool.totalSupply(), 500e6);
    }
    
    function test_BurnShares_RevertIf_NotManager() public {
        vm.prank(user1);
        vm.expectRevert("Only manager can call");
        pool.burnShares(user1, 100e6);
    }
    
    /*//////////////////////////////////////////////////////////////
                        PAUSE/UNPAUSE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_Pause_Success() public {
        vm.prank(address(mockManager));
        pool.pause();
        
        assertTrue(pool.paused());
    }
    
    function test_Pause_RevertIf_NotManager() public {
        vm.prank(user1);
        vm.expectRevert("Only manager can call");
        pool.pause();
    }
    
    function test_Unpause_Success() public {
        vm.prank(address(mockManager));
        pool.pause();
        assertTrue(pool.paused());
        
        vm.prank(address(mockManager));
        pool.unpause();
        assertFalse(pool.paused());
    }
    
    function test_Unpause_RevertIf_NotManager() public {
        vm.prank(address(mockManager));
        pool.pause();
        
        vm.prank(user1);
        vm.expectRevert("Only manager can call");
        pool.unpause();
    }
    
    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_TotalAssets() public {
        uint256 expectedAssets = 10_000e6;
        mockManager.setTotalAssets(expectedAssets);
        
        assertEq(pool.totalAssets(), expectedAssets);
    }
    
    function test_GetUserReturn() public {
        uint256 expectedReturn = 1500e6;
        mockManager.setUserReturn(user1, expectedReturn);
        
        assertEq(pool.getUserReturn(user1), expectedReturn);
    }
    
    function test_GetPoolStatus() public {
        mockManager.setPoolStatus(2); // INVESTED
        assertEq(pool.getPoolStatus(), 2);
    }
    
    function test_IsInFundingPeriod() public {
        mockManager.setIsInFunding(true);
        assertTrue(pool.isInFundingPeriod());
        
        mockManager.setIsInFunding(false);
        assertFalse(pool.isInFundingPeriod());
    }
    
    function test_IsActive() public {
        mockManager.setPoolStatus(2); // INVESTED = 2
        assertTrue(pool.isActive());
        
        mockManager.setPoolStatus(0); // FUNDING
        assertFalse(pool.isActive());
    }
    
    function test_IsInEmergency() public {
        mockManager.setPoolStatus(4); // EMERGENCY = 4
        assertTrue(pool.isInEmergency());
        
        mockManager.setPoolStatus(0); // FUNDING
        assertFalse(pool.isInEmergency());
    }
    
    /*//////////////////////////////////////////////////////////////
                        UPGRADE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_AuthorizeUpgrade_AlwaysReverts() public {
        vm.prank(address(mockManager));
        vm.expectRevert("Pool upgrades disabled for security");
        pool.upgradeToAndCall(address(0x123), "");
    }
    
    /*//////////////////////////////////////////////////////////////
                        ERC4626 COMPLIANCE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_Asset() public view {
        assertEq(address(pool.asset()), address(token));
    }
    
    function test_ConvertToShares() public {
        uint256 assets = 1000e6;
        uint256 shares = pool.convertToShares(assets);
        assertTrue(shares > 0);
    }
    
    function test_ConvertToAssets() public {
        uint256 shares = 1000e6;
        uint256 assets = pool.convertToAssets(shares);
        assertTrue(assets > 0);
    }
    
    function test_PreviewDeposit() public {
        uint256 assets = 1000e6;
        uint256 shares = pool.previewDeposit(assets);
        assertTrue(shares > 0);
    }
    
    function test_PreviewMint() public {
        uint256 shares = 1000e6;
        uint256 assets = pool.previewMint(shares);
        assertTrue(assets > 0);
    }
    
    /*//////////////////////////////////////////////////////////////
                        INTEGRATION SCENARIO TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_CompleteDepositWithdrawCycle() public {
        uint256 depositAmount = 1000e6;
        
        // 1. User deposits
        vm.startPrank(user1);
        token.approve(address(pool), depositAmount);
        uint256 shares = pool.deposit(depositAmount, user1);
        vm.stopPrank();
        
        assertEq(pool.balanceOf(user1), shares);
        
        // 2. User withdraws half
        uint256 withdrawAmount = 500e6;
        vm.prank(user1);
        pool.withdraw(withdrawAmount, user1, user1);
        
        // Verify state
        assertTrue(pool.balanceOf(user1) > 0);
    }
    
    function test_MultipleUsersDepositAndRefund() public {
        uint256 depositAmount = 1000e6;
        
        // User1 and User2 deposit
        vm.startPrank(user1);
        token.approve(address(pool), depositAmount);
        pool.deposit(depositAmount, user1);
        vm.stopPrank();
        
        vm.startPrank(user2);
        token.approve(address(pool), depositAmount);
        pool.deposit(depositAmount, user2);
        vm.stopPrank();
        
        // Set refunds for both
        vm.startPrank(address(mockManager));
        pool.setUserRefund(user1, 500e6);
        pool.setUserRefund(user2, 300e6);
        vm.stopPrank();
        
        assertEq(pool.totalPendingRefunds(), 800e6);
        assertEq(pool.pendingRefunds(user1), 500e6);
        assertEq(pool.pendingRefunds(user2), 300e6);
    }
    
    /*//////////////////////////////////////////////////////////////
                        FUZZ TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testFuzz_Deposit(uint256 amount) public {
        vm.assume(amount > 0 && amount <= INITIAL_BALANCE);
        
        vm.startPrank(user1);
        token.approve(address(pool), amount);
        uint256 shares = pool.deposit(amount, user1);
        vm.stopPrank();
        
        assertEq(pool.balanceOf(user1), shares);
        assertTrue(shares > 0);
    }
    
    function testFuzz_SetUserRefund(uint256 amount) public {
        vm.assume(amount < type(uint128).max);
        
        vm.prank(address(mockManager));
        pool.setUserRefund(user1, amount);
        
        assertEq(pool.pendingRefunds(user1), amount);
        assertEq(pool.totalPendingRefunds(), amount);
    }
    
    function testFuzz_MintAndBurnShares(uint256 mintAmount, uint256 burnAmount) public {
        vm.assume(mintAmount > 0 && mintAmount < type(uint96).max);
        vm.assume(burnAmount > 0 && burnAmount <= mintAmount);
        
        vm.startPrank(address(mockManager));
        
        pool.mintShares(mintAmount, user1);
        assertEq(pool.balanceOf(user1), mintAmount);
        
        pool.burnShares(user1, burnAmount);
        assertEq(pool.balanceOf(user1), mintAmount - burnAmount);
        
        vm.stopPrank();
    }
    
    function testFuzz_MultipleDeposits(uint8 userCount, uint96 depositAmount) public {
        vm.assume(userCount > 0 && userCount <= 10);
        vm.assume(depositAmount > 0 && depositAmount <= INITIAL_BALANCE / userCount);
        
        uint256 totalShares = 0;
        
        for (uint8 i = 0; i < userCount; i++) {
            address user = address(uint160(uint256(keccak256(abi.encodePacked("fuzzUser", i)))));
            token.mint(user, depositAmount);
            
            vm.startPrank(user);
            token.approve(address(pool), depositAmount);
            uint256 shares = pool.deposit(depositAmount, user);
            vm.stopPrank();
            
            totalShares += shares;
        }
        
        assertEq(pool.totalSupply(), totalShares);
    }
    
    /*//////////////////////////////////////////////////////////////
                        EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_Deposit_MinimumAmount() public {
        uint256 minAmount = 1; // 1 wei
        
        vm.startPrank(user1);
        token.approve(address(pool), minAmount);
        uint256 shares = pool.deposit(minAmount, user1);
        vm.stopPrank();
        
        assertTrue(shares > 0);
    }
    
    function test_SetUserRefund_MultipleUpdates() public {
        vm.startPrank(address(mockManager));
        
        // First update
        pool.setUserRefund(user1, 100e6);
        assertEq(pool.totalPendingRefunds(), 100e6);
        
        // Second update (increase)
        pool.setUserRefund(user1, 200e6);
        assertEq(pool.totalPendingRefunds(), 200e6);
        
        // Third update (decrease)
        pool.setUserRefund(user1, 50e6);
        assertEq(pool.totalPendingRefunds(), 50e6);
        
        // Set to zero
        pool.setUserRefund(user1, 0);
        assertEq(pool.totalPendingRefunds(), 0);
        
        vm.stopPrank();
    }
    
    function test_ClaimRefund_WithZeroShares() public {
        // Set refund without having shares
        vm.prank(address(mockManager));
        pool.setUserRefund(user1, 100e6);
        
        mockManager.setUserReturn(user1, 0);
        
        vm.prank(user1);
        pool.claimRefund();
        
        assertEq(pool.pendingRefunds(user1), 0);
    }
    
    /*//////////////////////////////////////////////////////////////
                        ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_OnlyManager_MintShares() public {
        address[] memory unauthorizedAddresses = new address[](4);
        unauthorizedAddresses[0] = user1;
        unauthorizedAddresses[1] = user2;
        unauthorizedAddresses[2] = admin;
        unauthorizedAddresses[3] = operator;
        
        for (uint256 i = 0; i < unauthorizedAddresses.length; i++) {
            vm.prank(unauthorizedAddresses[i]);
            vm.expectRevert("Only manager can call");
            pool.mintShares(100e6, user1);
        }
    }
    
    function test_OnlyManager_BurnShares() public {
        vm.prank(user1);
        vm.expectRevert("Only manager can call");
        pool.burnShares(user1, 100e6);
    }
    
    function test_OnlyManager_SetUserRefund() public {
        vm.prank(user1);
        vm.expectRevert("Only manager can call");
        pool.setUserRefund(user1, 100e6);
    }
    
    function test_OnlyManager_SetDiscountAccrued() public {
        vm.prank(user1);
        vm.expectRevert("Only manager can call");
        pool.setDiscountAccrued(user1, 100e6);
    }
    
    function test_OnlyManager_Pause() public {
        vm.prank(user1);
        vm.expectRevert("Only manager can call");
        pool.pause();
    }
    
    function test_OnlyManager_Unpause() public {
        vm.prank(user1);
        vm.expectRevert("Only manager can call");
        pool.unpause();
    }
    
    /*//////////////////////////////////////////////////////////////
                        STATE CONSISTENCY TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_TotalPendingRefunds_Consistency() public {
        vm.startPrank(address(mockManager));
        
        pool.setUserRefund(user1, 100e6);
        pool.setUserRefund(user2, 200e6);
        pool.setUserRefund(user3, 300e6);
        
        uint256 expectedTotal = 600e6;
        assertEq(pool.totalPendingRefunds(), expectedTotal);
        
        // Update user1
        pool.setUserRefund(user1, 150e6);
        assertEq(pool.totalPendingRefunds(), 650e6);
        
        vm.stopPrank();
    }
    
    function test_TotalDiscountAccrued_Consistency() public {
        vm.startPrank(address(mockManager));
        
        pool.setDiscountAccrued(user1, 50e6);
        pool.setDiscountAccrued(user2, 75e6);
        
        assertEq(pool.totalDiscountAccrued(), 125e6);
        
        // Decrease user1
        pool.setDiscountAccrued(user1, 25e6);
        assertEq(pool.totalDiscountAccrued(), 100e6);
        
        vm.stopPrank();
    }
}

