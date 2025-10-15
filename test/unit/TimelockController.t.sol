// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "../fixtures/BaseTest.sol";
import "../../src/governance/TimelockController.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

contract MockUpgradeable {
    uint256 public version;
    
    constructor() {
        version = 1;
    }
    
    function upgradeTo(address newImplementation) external {
        require(newImplementation != address(0), "Invalid implementation");
        version++;
    }
}

contract TimelockControllerTest is BaseTest {
    PironTimelockController public timelock;
    MockUpgradeable public mockContract;
    
    address public proposer = makeAddr("proposer");
    address public executor = makeAddr("executor");
    address public canceller = makeAddr("canceller");
    address public guardian = makeAddr("guardian");
    
    event UpgradeScheduled(
        bytes32 indexed id,
        address indexed target,
        address indexed newImplementation,
        uint256 executeTime
    );
    event UpgradeExecuted(
        bytes32 indexed id,
        address indexed target,
        address indexed newImplementation
    );
    event UpgradeCancelled(bytes32 indexed id);
    event UpgradesPaused(address indexed guardian);
    event UpgradesUnpaused(address indexed admin);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    
    function setUp() public override {
        super.setUp();
        
        // Deploy timelock
        timelock = new PironTimelockController(
            admin,
            proposer,
            executor,
            canceller,
            guardian
        );
        
        // Deploy mock upgradeable contract
        mockContract = new MockUpgradeable();
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INITIALIZATION TESTS ///////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function test_Constructor_Success() public view {
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(timelock.hasRole(timelock.TIMELOCK_ADMIN_ROLE(), admin));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), proposer));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), executor));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), canceller));
        assertEq(timelock.guardian(), guardian);
        assertFalse(timelock.upgradesPaused());
    }
    
    function test_Constructor_RevertsIfInvalidAdmin() public {
        vm.expectRevert("Invalid admin");
        new PironTimelockController(
            address(0),
            proposer,
            executor,
            canceller,
            guardian
        );
    }
    
    function test_Constructor_RevertsIfInvalidProposer() public {
        vm.expectRevert("Invalid proposer");
        new PironTimelockController(
            admin,
            address(0),
            executor,
            canceller,
            guardian
        );
    }
    
    function test_Constructor_RevertsIfInvalidExecutor() public {
        vm.expectRevert("Invalid executor");
        new PironTimelockController(
            admin,
            proposer,
            address(0),
            canceller,
            guardian
        );
    }
    
    function test_Constructor_RevertsIfInvalidCanceller() public {
        vm.expectRevert("Invalid canceller");
        new PironTimelockController(
            admin,
            proposer,
            executor,
            address(0),
            guardian
        );
    }
    
    function test_Constructor_RevertsIfInvalidGuardian() public {
        vm.expectRevert("Invalid guardian");
        new PironTimelockController(
            admin,
            proposer,
            executor,
            canceller,
            address(0)
        );
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// SCHEDULE UPGRADE TESTS /////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function test_ScheduleUpgrade_Success() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        
        uint256 expectedExecuteTime = block.timestamp + timelock.UPGRADE_DELAY();
        
        vm.expectEmit(false, true, true, false);
        emit UpgradeScheduled(
            bytes32(0),
            address(mockContract),
            address(newImplementation),
            expectedExecuteTime
        );
        
        vm.prank(proposer);
        bytes32 operationId = timelock.scheduleUpgrade(
            address(mockContract),
            address(newImplementation)
        );
        
        assertTrue(operationId != bytes32(0));
        
        (uint256 timestamp, bool executed, bool cancelled) = timelock.getOperation(operationId);
        assertEq(timestamp, expectedExecuteTime);
        assertFalse(executed);
        assertFalse(cancelled);
    }
    
    function test_ScheduleUpgrade_RevertsIfNotProposer() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        
        vm.prank(user1);
        vm.expectRevert();
        timelock.scheduleUpgrade(address(mockContract), address(newImplementation));
    }
    
    function test_ScheduleUpgrade_RevertsIfInvalidTarget() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        
        vm.prank(proposer);
        vm.expectRevert("Invalid target");
        timelock.scheduleUpgrade(address(0), address(newImplementation));
    }
    
    function test_ScheduleUpgrade_RevertsIfInvalidImplementation() public {
        vm.prank(proposer);
        vm.expectRevert("Invalid implementation");
        timelock.scheduleUpgrade(address(mockContract), address(0));
    }
    
    function test_ScheduleUpgrade_RevertsIfNotContract() public {
        vm.prank(proposer);
        vm.expectRevert("Invalid implementation");
        timelock.scheduleUpgrade(address(mockContract), user1);
    }
    
    function test_ScheduleUpgrade_RevertsIfUpgradesPaused() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        
        vm.prank(guardian);
        timelock.pauseUpgrades();
        
        vm.prank(proposer);
        vm.expectRevert("Upgrades paused by guardian");
        timelock.scheduleUpgrade(address(mockContract), address(newImplementation));
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EXECUTE UPGRADE TESTS //////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function test_ExecuteUpgrade_Success() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        
        vm.prank(proposer);
        bytes32 operationId = timelock.scheduleUpgrade(
            address(mockContract),
            address(newImplementation)
        );
        
        // Fast forward past delay
        skip(timelock.UPGRADE_DELAY() + 1);
        
        uint256 versionBefore = mockContract.version();
        
        vm.expectEmit(true, true, true, false);
        emit UpgradeExecuted(operationId, address(mockContract), address(newImplementation));
        
        vm.prank(executor);
        timelock.executeUpgrade(
            address(mockContract),
            address(newImplementation),
            operationId
        );
        
        (uint256 timestamp, bool executed, bool cancelled) = timelock.getOperation(operationId);
        assertTrue(executed);
        assertFalse(cancelled);
        assertEq(mockContract.version(), versionBefore + 1);
    }
    
    function test_ExecuteUpgrade_RevertsIfNotExecutor() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        
        vm.prank(proposer);
        bytes32 operationId = timelock.scheduleUpgrade(
            address(mockContract),
            address(newImplementation)
        );
        
        skip(timelock.UPGRADE_DELAY() + 1);
        
        vm.prank(user1);
        vm.expectRevert();
        timelock.executeUpgrade(
            address(mockContract),
            address(newImplementation),
            operationId
        );
    }
    
    function test_ExecuteUpgrade_RevertsIfNotScheduled() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        bytes32 fakeOperationId = keccak256("fake");
        
        vm.prank(executor);
        vm.expectRevert("Operation not scheduled");
        timelock.executeUpgrade(
            address(mockContract),
            address(newImplementation),
            fakeOperationId
        );
    }
    
    function test_ExecuteUpgrade_RevertsIfNotReady() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        
        vm.prank(proposer);
        bytes32 operationId = timelock.scheduleUpgrade(
            address(mockContract),
            address(newImplementation)
        );
        
        // Don't wait for delay
        vm.prank(executor);
        vm.expectRevert("Operation not ready");
        timelock.executeUpgrade(
            address(mockContract),
            address(newImplementation),
            operationId
        );
    }
    
    function test_ExecuteUpgrade_RevertsIfExpired() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        
        vm.prank(proposer);
        bytes32 operationId = timelock.scheduleUpgrade(
            address(mockContract),
            address(newImplementation)
        );
        
        // Fast forward past grace period
        skip(timelock.UPGRADE_DELAY() + timelock.GRACE_PERIOD() + 1);
        
        vm.prank(executor);
        vm.expectRevert("Operation expired");
        timelock.executeUpgrade(
            address(mockContract),
            address(newImplementation),
            operationId
        );
    }
    
    function test_ExecuteUpgrade_RevertsIfAlreadyExecuted() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        
        vm.prank(proposer);
        bytes32 operationId = timelock.scheduleUpgrade(
            address(mockContract),
            address(newImplementation)
        );
        
        skip(timelock.UPGRADE_DELAY() + 1);
        
        vm.prank(executor);
        timelock.executeUpgrade(
            address(mockContract),
            address(newImplementation),
            operationId
        );
        
        vm.prank(executor);
        vm.expectRevert("Operation already executed");
        timelock.executeUpgrade(
            address(mockContract),
            address(newImplementation),
            operationId
        );
    }
    
    function test_ExecuteUpgrade_RevertsIfCancelled() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        
        vm.prank(proposer);
        bytes32 operationId = timelock.scheduleUpgrade(
            address(mockContract),
            address(newImplementation)
        );
        
        vm.prank(canceller);
        timelock.cancelUpgrade(operationId);
        
        skip(timelock.UPGRADE_DELAY() + 1);
        
        vm.prank(executor);
        vm.expectRevert("Operation cancelled");
        timelock.executeUpgrade(
            address(mockContract),
            address(newImplementation),
            operationId
        );
    }
    
    function test_ExecuteUpgrade_RevertsIfUpgradesPaused() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        
        vm.prank(proposer);
        bytes32 operationId = timelock.scheduleUpgrade(
            address(mockContract),
            address(newImplementation)
        );
        
        skip(timelock.UPGRADE_DELAY() + 1);
        
        vm.prank(guardian);
        timelock.pauseUpgrades();
        
        vm.prank(executor);
        vm.expectRevert("Upgrades paused by guardian");
        timelock.executeUpgrade(
            address(mockContract),
            address(newImplementation),
            operationId
        );
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// CANCEL UPGRADE TESTS ///////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function test_CancelUpgrade_Success() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        
        vm.prank(proposer);
        bytes32 operationId = timelock.scheduleUpgrade(
            address(mockContract),
            address(newImplementation)
        );
        
        vm.expectEmit(true, false, false, false);
        emit UpgradeCancelled(operationId);
        
        vm.prank(canceller);
        timelock.cancelUpgrade(operationId);
        
        (uint256 timestamp, bool executed, bool cancelled) = timelock.getOperation(operationId);
        assertTrue(timestamp > 0);
        assertFalse(executed);
        assertTrue(cancelled);
    }
    
    function test_CancelUpgrade_RevertsIfNotCanceller() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        
        vm.prank(proposer);
        bytes32 operationId = timelock.scheduleUpgrade(
            address(mockContract),
            address(newImplementation)
        );
        
        vm.prank(user1);
        vm.expectRevert();
        timelock.cancelUpgrade(operationId);
    }
    
    function test_CancelUpgrade_RevertsIfNotScheduled() public {
        bytes32 fakeOperationId = keccak256("fake");
        
        vm.prank(canceller);
        vm.expectRevert("Operation not scheduled");
        timelock.cancelUpgrade(fakeOperationId);
    }
    
    function test_CancelUpgrade_RevertsIfAlreadyExecuted() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        
        vm.prank(proposer);
        bytes32 operationId = timelock.scheduleUpgrade(
            address(mockContract),
            address(newImplementation)
        );
        
        skip(timelock.UPGRADE_DELAY() + 1);
        
        vm.prank(executor);
        timelock.executeUpgrade(
            address(mockContract),
            address(newImplementation),
            operationId
        );
        
        vm.prank(canceller);
        vm.expectRevert("Operation already executed");
        timelock.cancelUpgrade(operationId);
    }
    
    function test_CancelUpgrade_RevertsIfAlreadyCancelled() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        
        vm.prank(proposer);
        bytes32 operationId = timelock.scheduleUpgrade(
            address(mockContract),
            address(newImplementation)
        );
        
        vm.prank(canceller);
        timelock.cancelUpgrade(operationId);
        
        vm.prank(canceller);
        vm.expectRevert("Operation cancelled");
        timelock.cancelUpgrade(operationId);
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// PAUSE/UNPAUSE TESTS ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function test_PauseUpgrades_Success() public {
        vm.expectEmit(true, false, false, false);
        emit UpgradesPaused(guardian);
        
        vm.prank(guardian);
        timelock.pauseUpgrades();
        
        assertTrue(timelock.upgradesPaused());
    }
    
    function test_PauseUpgrades_RevertsIfNotGuardian() public {
        vm.prank(user1);
        vm.expectRevert("Unauthorized guardian");
        timelock.pauseUpgrades();
    }
    
    function test_UnpauseUpgrades_Success() public {
        vm.prank(guardian);
        timelock.pauseUpgrades();
        
        vm.expectEmit(true, false, false, false);
        emit UpgradesUnpaused(admin);
        
        vm.prank(admin);
        timelock.unpauseUpgrades();
        
        assertFalse(timelock.upgradesPaused());
    }
    
    function test_UnpauseUpgrades_RevertsIfNotAdmin() public {
        vm.prank(guardian);
        timelock.pauseUpgrades();
        
        vm.prank(user1);
        vm.expectRevert();
        timelock.unpauseUpgrades();
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// GUARDIAN TESTS /////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function test_UpdateGuardian_Success() public {
        address newGuardian = makeAddr("newGuardian");
        
        vm.expectEmit(true, true, false, false);
        emit GuardianUpdated(guardian, newGuardian);
        
        vm.prank(admin);
        timelock.updateGuardian(newGuardian);
        
        assertEq(timelock.guardian(), newGuardian);
    }
    
    function test_UpdateGuardian_RevertsIfNotAdmin() public {
        address newGuardian = makeAddr("newGuardian");
        
        vm.prank(user1);
        vm.expectRevert();
        timelock.updateGuardian(newGuardian);
    }
    
    function test_UpdateGuardian_RevertsIfInvalidAddress() public {
        vm.prank(admin);
        vm.expectRevert("Invalid guardian");
        timelock.updateGuardian(address(0));
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// VIEW FUNCTION TESTS ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function test_IsOperationReady_ReturnsTrueWhenReady() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        
        vm.prank(proposer);
        bytes32 operationId = timelock.scheduleUpgrade(
            address(mockContract),
            address(newImplementation)
        );
        
        skip(timelock.UPGRADE_DELAY() + 1);
        
        assertTrue(timelock.isOperationReady(operationId));
    }
    
    function test_IsOperationReady_ReturnsFalseWhenNotReady() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        
        vm.prank(proposer);
        bytes32 operationId = timelock.scheduleUpgrade(
            address(mockContract),
            address(newImplementation)
        );
        
        assertFalse(timelock.isOperationReady(operationId));
    }
    
    function test_IsOperationReady_ReturnsFalseWhenExpired() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        
        vm.prank(proposer);
        bytes32 operationId = timelock.scheduleUpgrade(
            address(mockContract),
            address(newImplementation)
        );
        
        skip(timelock.UPGRADE_DELAY() + timelock.GRACE_PERIOD() + 1);
        
        assertFalse(timelock.isOperationReady(operationId));
    }
    
    function test_IsOperationReady_ReturnsFalseWhenExecuted() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        
        vm.prank(proposer);
        bytes32 operationId = timelock.scheduleUpgrade(
            address(mockContract),
            address(newImplementation)
        );
        
        skip(timelock.UPGRADE_DELAY() + 1);
        
        vm.prank(executor);
        timelock.executeUpgrade(
            address(mockContract),
            address(newImplementation),
            operationId
        );
        
        assertFalse(timelock.isOperationReady(operationId));
    }
    
    function test_IsOperationReady_ReturnsFalseWhenCancelled() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        
        vm.prank(proposer);
        bytes32 operationId = timelock.scheduleUpgrade(
            address(mockContract),
            address(newImplementation)
        );
        
        vm.prank(canceller);
        timelock.cancelUpgrade(operationId);
        
        skip(timelock.UPGRADE_DELAY() + 1);
        
        assertFalse(timelock.isOperationReady(operationId));
    }
    
    function test_GetOperation_ReturnsCorrectDetails() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        
        vm.prank(proposer);
        bytes32 operationId = timelock.scheduleUpgrade(
            address(mockContract),
            address(newImplementation)
        );
        
        (uint256 timestamp, bool executed, bool cancelled) = timelock.getOperation(operationId);
        
        assertEq(timestamp, block.timestamp + timelock.UPGRADE_DELAY());
        assertFalse(executed);
        assertFalse(cancelled);
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// CONSTANTS TESTS ////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function test_UpgradeDelay_Is72Hours() public view {
        assertEq(timelock.UPGRADE_DELAY(), 72 hours);
    }
    
    function test_GracePeriod_Is7Days() public view {
        assertEq(timelock.GRACE_PERIOD(), 7 days);
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INTEGRATION TESTS //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function test_Integration_FullUpgradeLifecycle() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        
        // 1. Schedule upgrade
        vm.prank(proposer);
        bytes32 operationId = timelock.scheduleUpgrade(
            address(mockContract),
            address(newImplementation)
        );
        
        // 2. Verify operation is not ready
        assertFalse(timelock.isOperationReady(operationId));
        
        // 3. Wait for delay
        skip(timelock.UPGRADE_DELAY() + 1);
        
        // 4. Verify operation is ready
        assertTrue(timelock.isOperationReady(operationId));
        
        // 5. Execute upgrade
        vm.prank(executor);
        timelock.executeUpgrade(
            address(mockContract),
            address(newImplementation),
            operationId
        );
        
        // 6. Verify operation is executed
        (uint256 timestamp, bool executed, bool cancelled) = timelock.getOperation(operationId);
        assertTrue(executed);
        assertFalse(cancelled);
    }
    
    function test_Integration_ScheduleAndCancel() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        
        // 1. Schedule upgrade
        vm.prank(proposer);
        bytes32 operationId = timelock.scheduleUpgrade(
            address(mockContract),
            address(newImplementation)
        );
        
        // 2. Cancel upgrade
        vm.prank(canceller);
        timelock.cancelUpgrade(operationId);
        
        // 3. Verify operation is cancelled
        (uint256 timestamp, bool executed, bool cancelled) = timelock.getOperation(operationId);
        assertFalse(executed);
        assertTrue(cancelled);
        
        // 4. Verify operation cannot be executed
        skip(timelock.UPGRADE_DELAY() + 1);
        assertFalse(timelock.isOperationReady(operationId));
    }
    
    function test_Integration_GuardianPauseBlocksUpgrades() public {
        MockUpgradeable newImplementation = new MockUpgradeable();
        
        // 1. Schedule upgrade
        vm.prank(proposer);
        bytes32 operationId = timelock.scheduleUpgrade(
            address(mockContract),
            address(newImplementation)
        );
        
        // 2. Guardian pauses upgrades
        vm.prank(guardian);
        timelock.pauseUpgrades();
        
        // 3. Wait for delay
        skip(timelock.UPGRADE_DELAY() + 1);
        
        // 4. Execution should fail
        vm.prank(executor);
        vm.expectRevert("Upgrades paused by guardian");
        timelock.executeUpgrade(
            address(mockContract),
            address(newImplementation),
            operationId
        );
        
        // 5. Admin unpauses
        vm.prank(admin);
        timelock.unpauseUpgrades();
        
        // 6. Execution should now succeed
        vm.prank(executor);
        timelock.executeUpgrade(
            address(mockContract),
            address(newImplementation),
            operationId
        );
        
        (uint256 timestamp, bool executed, bool cancelled) = timelock.getOperation(operationId);
        assertTrue(executed);
    }
}

