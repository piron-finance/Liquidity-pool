// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "../fixtures/BaseTest.sol";
import "../../src/escrows/PoolEscrow.sol";
import "../../src/interfaces/IPoolEscrow.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 10_000_000e6);
    }
    
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract PoolEscrowTest is BaseTest {
    PoolEscrow public escrowImpl;
    PoolEscrow public escrow;
    MockToken public token;
    
    address public manager = makeAddr("manager");
    address public pool = makeAddr("pool");
    
    event Deposit(address indexed user, uint256 amount, uint256 timestamp);
    event FundsReleased(address indexed recipient, uint256 amount, bytes32 indexed transferId);
    event FundsLocked(uint256 amount, string reason);
    event LargeTransferDetected(bytes32 indexed transferId, uint256 amount, uint256 threshold);
    
    function setUp() public override {
        super.setUp();
        
        // Deploy token
        token = new MockToken();
        
        // Deploy and initialize escrow
        escrowImpl = new PoolEscrow();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address)",
            address(token),
            manager,
            spv,
            address(0) // timelock
        );
        ERC1967Proxy escrowProxy = new ERC1967Proxy(address(escrowImpl), initData);
        escrow = PoolEscrow(payable(address(escrowProxy)));
        
        // Set pool
        vm.prank(manager);
        escrow.setPool(pool);
        
        // Fund users
        token.transfer(user1, INITIAL_BALANCE);
        token.transfer(user2, INITIAL_BALANCE);
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INITIALIZATION TESTS ///////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function test_Initialize_Success() public view {
        assertEq(address(escrow.asset()), address(token));
        assertEq(escrow.manager(), manager);
        assertEq(escrow.spvAddress(), spv);
        assertEq(escrow.pool(), pool);
    }
    
    function test_Initialize_RevertsIfAlreadyInitialized() public {
        PoolEscrow newEscrowImpl = new PoolEscrow();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address)",
            address(token),
            manager,
            spv,
            address(0)
        );
        ERC1967Proxy newEscrowProxy = new ERC1967Proxy(address(newEscrowImpl), initData);
        PoolEscrow newEscrow = PoolEscrow(payable(address(newEscrowProxy)));
        
        vm.expectRevert();
        newEscrow.initialize(address(token), manager, spv, address(0));
    }
    
    function test_Initialize_RevertsIfInvalidAsset() public {
        PoolEscrow newEscrowImpl = new PoolEscrow();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address)",
            address(0),
            manager,
            spv,
            address(0)
        );
        
        vm.expectRevert("PoolEscrow/invalid-asset");
        new ERC1967Proxy(address(newEscrowImpl), initData);
    }
    
    function test_Initialize_RevertsIfInvalidManager() public {
        PoolEscrow newEscrowImpl = new PoolEscrow();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address)",
            address(token),
            address(0),
            spv,
            address(0)
        );
        
        vm.expectRevert("PoolEscrow/invalid-manager");
        new ERC1967Proxy(address(newEscrowImpl), initData);
    }
    
    function test_Initialize_RevertsIfInvalidSPV() public {
        PoolEscrow newEscrowImpl = new PoolEscrow();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address)",
            address(token),
            manager,
            address(0),
            address(0)
        );
        
        vm.expectRevert("PoolEscrow/invalid-spv");
        new ERC1967Proxy(address(newEscrowImpl), initData);
    }
    
    function test_SetPool_Success() public {
        // Create new escrow without pool set
        PoolEscrow newEscrowImpl = new PoolEscrow();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address)",
            address(token),
            manager,
            spv,
            address(0)
        );
        ERC1967Proxy newEscrowProxy = new ERC1967Proxy(address(newEscrowImpl), initData);
        PoolEscrow newEscrow = PoolEscrow(payable(address(newEscrowProxy)));
        
        address newPool = makeAddr("newPool");
        
        vm.prank(manager);
        newEscrow.setPool(newPool);
        
        assertEq(newEscrow.pool(), newPool);
    }
    
    function test_SetPool_RevertsIfNotAdmin() public {
        PoolEscrow newEscrowImpl = new PoolEscrow();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address)",
            address(token),
            manager,
            spv,
            address(0)
        );
        ERC1967Proxy newEscrowProxy = new ERC1967Proxy(address(newEscrowImpl), initData);
        PoolEscrow newEscrow = PoolEscrow(payable(address(newEscrowProxy)));
        
        vm.prank(user1);
        vm.expectRevert();
        newEscrow.setPool(makeAddr("newPool"));
    }
    
    function test_SetPool_RevertsIfInvalidPool() public {
        PoolEscrow newEscrowImpl = new PoolEscrow();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address)",
            address(token),
            manager,
            spv,
            address(0)
        );
        ERC1967Proxy newEscrowProxy = new ERC1967Proxy(address(newEscrowImpl), initData);
        PoolEscrow newEscrow = PoolEscrow(payable(address(newEscrowProxy)));
        
        vm.prank(manager);
        vm.expectRevert("PoolEscrow/invalid-pool");
        newEscrow.setPool(address(0));
    }
    
    function test_SetPool_RevertsIfPoolAlreadySet() public {
        vm.prank(manager);
        vm.expectRevert("PoolEscrow/pool-already-set");
        escrow.setPool(makeAddr("anotherPool"));
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// DEPOSIT TESTS //////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function test_ReceiveDeposit_Success() public {
        uint256 depositAmount = 100_000e6;
        
        vm.expectEmit(true, false, false, true);
        emit Deposit(user1, depositAmount, block.timestamp);
        
        vm.prank(manager);
        escrow.receiveDeposit(user1, depositAmount);
        
        assertEq(escrow.deposits(user1), depositAmount);
        assertEq(escrow.totalDeposits(), depositAmount);
        assertEq(escrow.userDepositHistory(user1), depositAmount);
    }
    
    function test_ReceiveDeposit_MultipleDeposits() public {
        uint256 firstDeposit = 100_000e6;
        uint256 secondDeposit = 50_000e6;
        
        vm.prank(manager);
        escrow.receiveDeposit(user1, firstDeposit);
        
        vm.prank(manager);
        escrow.receiveDeposit(user1, secondDeposit);
        
        assertEq(escrow.deposits(user1), firstDeposit + secondDeposit);
        assertEq(escrow.totalDeposits(), firstDeposit + secondDeposit);
        assertEq(escrow.userDepositHistory(user1), firstDeposit + secondDeposit);
    }
    
    function test_ReceiveDeposit_RevertsIfNotManager() public {
        vm.prank(user1);
        vm.expectRevert("PoolEscrow/only-manager");
        escrow.receiveDeposit(user1, 100_000e6);
    }
    
    function test_ReceiveDeposit_RevertsIfInvalidUser() public {
        vm.prank(manager);
        vm.expectRevert("PoolEscrow/invalid-user");
        escrow.receiveDeposit(address(0), 100_000e6);
    }
    
    function test_ReceiveDeposit_RevertsIfInvalidAmount() public {
        vm.prank(manager);
        vm.expectRevert("PoolEscrow/invalid-amount");
        escrow.receiveDeposit(user1, 0);
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// FUND MANAGEMENT TESTS //////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function test_LockFunds_Success() public {
        // First deposit some funds
        uint256 depositAmount = 100_000e6;
        vm.prank(user1);
        token.transfer(address(escrow), depositAmount);
        
        uint256 lockAmount = 50_000e6;
        
        vm.expectEmit(false, false, false, true);
        emit FundsLocked(lockAmount, "Manager lock");
        
        vm.prank(manager);
        escrow.lockFunds(lockAmount);
        
        assertEq(escrow.totalLocked(), lockAmount);
        assertEq(escrow.getAvailableBalance(), depositAmount - lockAmount);
    }
    
    function test_LockFunds_RevertsIfNotManager() public {
        vm.prank(user1);
        vm.expectRevert("PoolEscrow/only-manager");
        escrow.lockFunds(100_000e6);
    }
    
    function test_LockFunds_RevertsIfInvalidAmount() public {
        vm.prank(manager);
        vm.expectRevert("PoolEscrow/invalid-amount");
        escrow.lockFunds(0);
    }
    
    function test_LockFunds_RevertsIfInsufficientBalance() public {
        vm.prank(manager);
        vm.expectRevert("PoolEscrow/insufficient-balance");
        escrow.lockFunds(100_000e6);
    }
    
    function test_ReleaseFunds_Success() public {
        // Deposit and release funds
        uint256 depositAmount = 100_000e6;
        vm.prank(user1);
        token.transfer(address(escrow), depositAmount);
        
        uint256 releaseAmount = 50_000e6;
        uint256 user1BalanceBefore = token.balanceOf(user1);
        
        vm.expectEmit(true, false, false, true);
        emit FundsReleased(user1, releaseAmount, bytes32(0));
        
        vm.prank(manager);
        escrow.releaseFunds(user1, releaseAmount);
        
        assertEq(token.balanceOf(user1), user1BalanceBefore + releaseAmount);
        assertEq(escrow.userWithdrawalHistory(user1), releaseAmount);
    }
    
    function test_ReleaseFunds_LargeTransferDetected() public {
        // Deposit large amount
        uint256 depositAmount = 200_000e6;
        vm.prank(user1);
        token.transfer(address(escrow), depositAmount);
        
        uint256 releaseAmount = 150_000e6; // Above threshold
        
        vm.expectEmit(false, false, false, false);
        emit LargeTransferDetected(bytes32(0), releaseAmount, escrow.LARGE_TRANSFER_THRESHOLD());
        
        vm.prank(manager);
        escrow.releaseFunds(user1, releaseAmount);
    }
    
    function test_ReleaseFunds_RevertsIfNotManager() public {
        vm.prank(user1);
        vm.expectRevert("PoolEscrow/only-manager");
        escrow.releaseFunds(user1, 100_000e6);
    }
    
    function test_ReleaseFunds_RevertsIfInvalidRecipient() public {
        vm.prank(manager);
        vm.expectRevert("PoolEscrow/invalid-recipient");
        escrow.releaseFunds(address(0), 100_000e6);
    }
    
    function test_ReleaseFunds_RevertsIfInvalidAmount() public {
        vm.prank(manager);
        vm.expectRevert("PoolEscrow/invalid-amount");
        escrow.releaseFunds(user1, 0);
    }
    
    function test_ReleaseFunds_RevertsIfInsufficientBalance() public {
        vm.prank(manager);
        vm.expectRevert("PoolEscrow/insufficient-balance");
        escrow.releaseFunds(user1, 100_000e6);
    }
    
    function test_WithdrawForInvestment_Success() public {
        // Deposit funds
        uint256 depositAmount = 100_000e6;
        vm.prank(user1);
        token.transfer(address(escrow), depositAmount);
        
        uint256 withdrawAmount = 80_000e6;
        uint256 spvBalanceBefore = token.balanceOf(spv);
        
        vm.expectEmit(true, false, false, true);
        emit FundsReleased(spv, withdrawAmount, bytes32(0));
        
        vm.prank(manager);
        bytes32 transferId = escrow.withdrawForInvestment(withdrawAmount);
        
        assertEq(token.balanceOf(spv), spvBalanceBefore + withdrawAmount);
        assertTrue(transferId != bytes32(0));
        
        IPoolEscrow.Transfer memory transfer = escrow.getTransfer(transferId);
        assertEq(uint8(transfer.transferType), uint8(IPoolEscrow.TransferType.TO_SPV));
        assertEq(transfer.recipient, spv);
        assertEq(transfer.amount, withdrawAmount);
        assertTrue(transfer.executed);
    }
    
    function test_WithdrawForInvestment_LargeTransferDetected() public {
        // Deposit large amount
        uint256 depositAmount = 200_000e6;
        vm.prank(user1);
        token.transfer(address(escrow), depositAmount);
        
        uint256 withdrawAmount = 150_000e6; // Above threshold
        
        vm.expectEmit(false, false, false, false);
        emit LargeTransferDetected(bytes32(0), withdrawAmount, escrow.LARGE_TRANSFER_THRESHOLD());
        
        vm.prank(manager);
        escrow.withdrawForInvestment(withdrawAmount);
    }
    
    function test_WithdrawForInvestment_RevertsIfNotManager() public {
        vm.prank(user1);
        vm.expectRevert("PoolEscrow/only-manager");
        escrow.withdrawForInvestment(100_000e6);
    }
    
    function test_WithdrawForInvestment_RevertsIfInvalidAmount() public {
        vm.prank(manager);
        vm.expectRevert("PoolEscrow/invalid-amount");
        escrow.withdrawForInvestment(0);
    }
    
    function test_WithdrawForInvestment_RevertsIfInsufficientBalance() public {
        vm.prank(manager);
        vm.expectRevert("PoolEscrow/insufficient-balance");
        escrow.withdrawForInvestment(100_000e6);
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// COUPON PAYMENT TESTS ///////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function test_TrackCouponPayment_Success() public {
        uint256 couponAmount = 10_000e6;
        
        vm.expectEmit(true, false, false, true);
        emit FundsReleased(address(escrow), couponAmount, bytes32(uint256(0xcafe)));
        
        vm.prank(manager);
        escrow.trackCouponPayment(couponAmount);
        
        assertEq(escrow.totalCouponPaymentsReceived(), couponAmount);
        assertEq(escrow.totalCouponPool(), couponAmount);
    }
    
    function test_TrackCouponPayment_RevertsIfNotManager() public {
        vm.prank(user1);
        vm.expectRevert("PoolEscrow/only-manager");
        escrow.trackCouponPayment(10_000e6);
    }
    
    function test_TrackCouponPayment_RevertsIfInvalidAmount() public {
        vm.prank(manager);
        vm.expectRevert("PoolEscrow/invalid-amount");
        escrow.trackCouponPayment(0);
    }
    
    function test_TrackMaturityReturn_Success() public {
        uint256 maturityAmount = 50_000e6;
        
        vm.expectEmit(true, false, false, true);
        emit FundsReleased(address(escrow), maturityAmount, bytes32(uint256(0xfeed)));
        
        vm.prank(manager);
        escrow.trackMaturityReturn(maturityAmount);
        
        assertEq(escrow.totalMaturityReturns(), maturityAmount);
    }
    
    function test_TrackMaturityReturn_RevertsIfNotManager() public {
        vm.prank(user1);
        vm.expectRevert("PoolEscrow/only-manager");
        escrow.trackMaturityReturn(50_000e6);
    }
    
    function test_TrackMaturityReturn_RevertsIfInvalidAmount() public {
        vm.prank(manager);
        vm.expectRevert("PoolEscrow/invalid-amount");
        escrow.trackMaturityReturn(0);
    }
    
    function test_ClaimCoupon_Success() public {
        // Deposit funds first
        uint256 depositAmount = 100_000e6;
        vm.prank(user1);
        token.transfer(address(escrow), depositAmount);
        
        uint256 couponAmount = 5_000e6;
        uint256 user1BalanceBefore = token.balanceOf(user1);
        
        vm.expectEmit(true, false, false, true);
        emit FundsReleased(user1, couponAmount, bytes32(uint256(0xc0ff)));
        
        vm.prank(manager);
        escrow.claimCoupon(user1, couponAmount);
        
        assertEq(token.balanceOf(user1), user1BalanceBefore + couponAmount);
        assertEq(escrow.totalCouponsClaimed(), couponAmount);
        assertEq(escrow.userCouponHistory(user1), couponAmount);
    }
    
    function test_ClaimCoupon_RevertsIfNotManager() public {
        vm.prank(user1);
        vm.expectRevert("PoolEscrow/only-manager");
        escrow.claimCoupon(user1, 5_000e6);
    }
    
    function test_ClaimCoupon_RevertsIfInvalidUser() public {
        vm.prank(manager);
        vm.expectRevert("PoolEscrow/invalid-user");
        escrow.claimCoupon(address(0), 5_000e6);
    }
    
    function test_ClaimCoupon_RevertsIfInvalidAmount() public {
        vm.prank(manager);
        vm.expectRevert("PoolEscrow/invalid-amount");
        escrow.claimCoupon(user1, 0);
    }
    
    function test_ClaimCoupon_RevertsIfInsufficientBalance() public {
        vm.prank(manager);
        vm.expectRevert("PoolEscrow/insufficient-balance");
        escrow.claimCoupon(user1, 5_000e6);
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// VIEW FUNCTION TESTS ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function test_GetBalance_ReturnsCorrectValue() public {
        uint256 depositAmount = 100_000e6;
        vm.prank(user1);
        token.transfer(address(escrow), depositAmount);
        
        assertEq(escrow.getBalance(), depositAmount);
    }
    
    function test_GetAvailableBalance_WithLockedFunds() public {
        uint256 depositAmount = 100_000e6;
        vm.prank(user1);
        token.transfer(address(escrow), depositAmount);
        
        uint256 lockAmount = 30_000e6;
        vm.prank(manager);
        escrow.lockFunds(lockAmount);
        
        assertEq(escrow.getAvailableBalance(), depositAmount - lockAmount);
    }
    
    function test_GetAvailableBalance_ReturnsZeroIfLocked() public {
        uint256 depositAmount = 100_000e6;
        vm.prank(user1);
        token.transfer(address(escrow), depositAmount);
        
        vm.prank(manager);
        escrow.lockFunds(depositAmount);
        
        assertEq(escrow.getAvailableBalance(), 0);
    }
    
    function test_CanWithdrawForInvestment_ReturnsTrue() public {
        uint256 depositAmount = 100_000e6;
        vm.prank(user1);
        token.transfer(address(escrow), depositAmount);
        
        assertTrue(escrow.canWithdrawForInvestment(50_000e6));
    }
    
    function test_CanWithdrawForInvestment_ReturnsFalseIfInsufficientBalance() public {
        assertFalse(escrow.canWithdrawForInvestment(100_000e6));
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// UPGRADE TESTS //////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function test_AuthorizeUpgrade_RevertsAlways() public {
        vm.prank(manager);
        vm.expectRevert("Escrow upgrades disabled for security");
        escrow.upgradeToAndCall(address(escrowImpl), "");
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ETH REJECTION TESTS ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function test_Receive_RevertsEth() public {
        (bool success, ) = address(escrow).call{value: 1 ether}("");
        assertFalse(success);
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// FUZZ TESTS /////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function testFuzz_ReceiveDeposit(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 1_000_000e6);
        
        vm.prank(manager);
        escrow.receiveDeposit(user1, amount);
        
        assertEq(escrow.deposits(user1), amount);
        assertEq(escrow.totalDeposits(), amount);
    }
    
    function testFuzz_LockFunds(uint256 depositAmount, uint256 lockAmount) public {
        vm.assume(depositAmount > 0 && depositAmount <= 1_000_000e6);
        vm.assume(lockAmount > 0 && lockAmount <= depositAmount);
        
        vm.prank(user1);
        token.transfer(address(escrow), depositAmount);
        
        vm.prank(manager);
        escrow.lockFunds(lockAmount);
        
        assertEq(escrow.totalLocked(), lockAmount);
        assertEq(escrow.getAvailableBalance(), depositAmount - lockAmount);
    }
    
    function testFuzz_ReleaseFunds(uint256 depositAmount, uint256 releaseAmount) public {
        vm.assume(depositAmount > 0 && depositAmount <= 1_000_000e6);
        vm.assume(releaseAmount > 0 && releaseAmount <= depositAmount);
        
        vm.prank(user1);
        token.transfer(address(escrow), depositAmount);
        
        uint256 user2BalanceBefore = token.balanceOf(user2);
        
        vm.prank(manager);
        escrow.releaseFunds(user2, releaseAmount);
        
        assertEq(token.balanceOf(user2), user2BalanceBefore + releaseAmount);
    }
}

