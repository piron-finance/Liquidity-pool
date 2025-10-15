// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../fixtures/BaseTest.sol";
import "../../src/AccessManager.sol";

/**
 * @title AccessManagerTest
 * @notice Unit tests for AccessManager contract
 */
contract AccessManagerTest is BaseTest { 
    
    AccessManager public accessManager;
    
    // Test addresses
    address public newUser = makeAddr("newUser");
    
    // Events to test
    event RoleProposed(bytes32 indexed proposalId, bytes32 indexed role, address indexed account, uint256 timestamp);
    event RoleProposalExecuted(bytes32 indexed proposalId, bytes32 indexed role, address indexed account);
    event RoleProposalCancelled(bytes32 indexed proposalId);
    event EmergencyPause(address indexed pauser, uint256 timestamp);
    event EmergencyUnpause(address indexed unpauser, uint256 timestamp);
    
    function setUp() public override {
        super.setUp();
        
        // Deploy AccessManager
        // Use admin as multisigAdmin so admin has both DEFAULT_ADMIN_ROLE and MULTISIG_ADMIN_ROLE
        vm.prank(admin);
        accessManager = new AccessManager(
            admin,
            spv,
            operator,
            emergency,
            admin  // admin is also multisigAdmin for testing
        );
    }
    
    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_Constructor_Success() public view {
        // Verify all roles were granted correctly
        assertTrue(accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(accessManager.hasRole(accessManager.SPV_ROLE(), spv));
        assertTrue(accessManager.hasRole(accessManager.OPERATOR_ROLE(), operator));
        assertTrue(accessManager.hasRole(accessManager.EMERGENCY_ROLE(), emergency));
        assertTrue(accessManager.hasRole(accessManager.MULTISIG_ADMIN_ROLE(), admin));  // admin is also multisigAdmin
        
        // Verify initial role grant times are zero (immediate access)
        assertEq(accessManager.roleGrantTime(admin), 0);
        assertEq(accessManager.roleGrantTime(spv), 0);
        assertEq(accessManager.roleGrantTime(operator), 0);
        assertEq(accessManager.roleGrantTime(emergency), 0);
        
        // Verify emergency pauser
        assertTrue(accessManager.emergencyPausers(emergency));
    }
    
    function test_Constructor_RevertIf_InvalidAdmin() public {
        vm.expectRevert("AccessManager: invalid admin");
        new AccessManager(address(0), spv, operator, emergency, multisigAdmin);
    }
    
    function test_Constructor_RevertIf_InvalidSPV() public {
        vm.expectRevert("AccessManager: invalid spv");
        new AccessManager(admin, address(0), operator, emergency, multisigAdmin);
    }
    
    function test_Constructor_RevertIf_InvalidOperator() public {
        vm.expectRevert("AccessManager: invalid operator");
        new AccessManager(admin, spv, address(0), emergency, multisigAdmin);
    }
    
    function test_Constructor_RevertIf_InvalidEmergency() public {
        vm.expectRevert("AccessManager: invalid emergency");
        new AccessManager(admin, spv, operator, address(0), multisigAdmin);
    }
    
    function test_Constructor_RevertIf_InvalidMultisigAdmin() public {
        vm.expectRevert("AccessManager: invalid multisig admin");
        new AccessManager(admin, spv, operator, emergency, address(0));
    }
    
    /*//////////////////////////////////////////////////////////////
                        ROLE PROPOSAL TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_ProposeRoleGrant_Success() public {
        bytes32 role = accessManager.OPERATOR_ROLE();
        
        vm.prank(admin);
        bytes32 proposalId = accessManager.proposeRoleGrant(role, newUser);
        
        // Verify proposal was created
        (
            bytes32 proposedRole,
            address proposedAccount,
            uint256 proposedAt,
            bool executed,
            bool cancelled,
            bool canExecute
        ) = accessManager.getProposal(proposalId);
        
        assertEq(proposedRole, role);
        assertEq(proposedAccount, newUser);
        assertEq(proposedAt, block.timestamp);
        assertFalse(executed);
        assertFalse(cancelled);
        assertFalse(canExecute); // Can't execute immediately due to delay
        assertTrue(proposalId != bytes32(0)); // Valid proposal ID was generated
    }
    
    function test_ProposeRoleGrant_RevertIf_NotAdmin() public {
        bytes32 operatorRole = accessManager.OPERATOR_ROLE();
        bytes32 adminRole = accessManager.DEFAULT_ADMIN_ROLE();
        
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                user1,
                adminRole
            )
        );
        accessManager.proposeRoleGrant(operatorRole, newUser);
    }
    
    function test_ProposeRoleGrant_RevertIf_InvalidAccount() public {
        bytes32 operatorRole = accessManager.OPERATOR_ROLE();
        
        vm.prank(admin);
        vm.expectRevert("AccessManager: invalid account");
        accessManager.proposeRoleGrant(operatorRole, address(0));
    }
    
    function test_ProposeRoleGrant_RevertIf_AccountAlreadyHasRole() public {
        bytes32 spvRole = accessManager.SPV_ROLE();
        
        vm.prank(admin);
        vm.expectRevert("AccessManager: account already has role");
        accessManager.proposeRoleGrant(spvRole, spv);
    }
    
    /*//////////////////////////////////////////////////////////////
                    ROLE PROPOSAL EXECUTION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_ExecuteRoleGrant_Success() public {
        bytes32 role = accessManager.OPERATOR_ROLE();
        uint256 roleDelay = accessManager.ROLE_DELAY();
        
        // Propose role grant
        vm.prank(admin);
        bytes32 proposalId = accessManager.proposeRoleGrant(role, newUser);
        
        // Fast forward past delay period
        skip(roleDelay + 1);
        
        // Execute proposal - admin has DEFAULT_ADMIN_ROLE and MULTISIG_ADMIN_ROLE from constructor
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit RoleProposalExecuted(proposalId, role, newUser);
        
        accessManager.executeRoleGrant(proposalId);
        
        // Verify role was granted
        assertTrue(accessManager.hasRole(role, newUser));
        assertEq(accessManager.roleGrantTime(newUser), block.timestamp);
        
        // Verify proposal status
        (, , , bool executed, , ) = accessManager.getProposal(proposalId);
        assertTrue(executed);
    }
    
    function test_ExecuteRoleGrant_RevertIf_NotMultisigAdmin() public {
        bytes32 operatorRole = accessManager.OPERATOR_ROLE();
        bytes32 multisigRole = accessManager.MULTISIG_ADMIN_ROLE();
        uint256 roleDelay = accessManager.ROLE_DELAY();
        
        vm.prank(admin);
        bytes32 proposalId = accessManager.proposeRoleGrant(operatorRole, newUser);
        
        skip(roleDelay + 1);
        
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                user1,
                multisigRole
            )
        );
        accessManager.executeRoleGrant(proposalId);
    }
    
    function test_ExecuteRoleGrant_RevertIf_ProposalDoesNotExist() public {
        bytes32 fakeProposalId = keccak256("fake");
        
        vm.prank(admin);
        vm.expectRevert("AccessManager: proposal does not exist");
        accessManager.executeRoleGrant(fakeProposalId);
    }
    
    function test_ExecuteRoleGrant_RevertIf_AlreadyExecuted() public {
        bytes32 operatorRole = accessManager.OPERATOR_ROLE();
        uint256 roleDelay = accessManager.ROLE_DELAY();
        
        vm.prank(admin);
        bytes32 proposalId = accessManager.proposeRoleGrant(operatorRole, newUser);
        
        skip(roleDelay + 1);
        
        vm.prank(admin);
        accessManager.executeRoleGrant(proposalId);
        
        // Try to execute again
        vm.prank(admin);
        vm.expectRevert("AccessManager: proposal already executed");
        accessManager.executeRoleGrant(proposalId);
    }
    
    function test_ExecuteRoleGrant_RevertIf_DelayNotMet() public {
        bytes32 operatorRole = accessManager.OPERATOR_ROLE();
        
        vm.prank(admin);
        bytes32 proposalId = accessManager.proposeRoleGrant(operatorRole, newUser);
        
        // Don't wait for delay
        vm.prank(admin);
        vm.expectRevert("AccessManager: delay period not met");
        accessManager.executeRoleGrant(proposalId);
    }
    
    function test_ExecuteRoleGrant_RevertIf_Cancelled() public {
        bytes32 operatorRole = accessManager.OPERATOR_ROLE();
        uint256 roleDelay = accessManager.ROLE_DELAY();
        
        vm.prank(admin);
        bytes32 proposalId = accessManager.proposeRoleGrant(operatorRole, newUser);
        
        // Cancel proposal
        vm.prank(admin);
        accessManager.cancelRoleProposal(proposalId);
        
        skip(roleDelay + 1);
        
        vm.prank(admin);
        vm.expectRevert("AccessManager: proposal cancelled");
        accessManager.executeRoleGrant(proposalId);
    }
    
    /*//////////////////////////////////////////////////////////////
                    ROLE PROPOSAL CANCELLATION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_CancelRoleProposal_Success() public {
        bytes32 operatorRole = accessManager.OPERATOR_ROLE();
        
        vm.prank(admin);
        bytes32 proposalId = accessManager.proposeRoleGrant(operatorRole, newUser);
        
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit RoleProposalCancelled(proposalId);
        
        accessManager.cancelRoleProposal(proposalId);
        
        // Verify proposal was cancelled
        (, , , , bool cancelled, ) = accessManager.getProposal(proposalId);
        assertTrue(cancelled);
    }
    
    function test_CancelRoleProposal_RevertIf_NotAdmin() public {
        bytes32 operatorRole = accessManager.OPERATOR_ROLE();
        bytes32 adminRole = accessManager.DEFAULT_ADMIN_ROLE();
        
        vm.prank(admin);
        bytes32 proposalId = accessManager.proposeRoleGrant(operatorRole, newUser);
        
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                user1,
                adminRole
            )
        );
        accessManager.cancelRoleProposal(proposalId);
    }
    
    function test_CancelRoleProposal_RevertIf_AlreadyCancelled() public {
        bytes32 operatorRole = accessManager.OPERATOR_ROLE();
        
        vm.prank(admin);
        bytes32 proposalId = accessManager.proposeRoleGrant(operatorRole, newUser);
        
        vm.prank(admin);
        accessManager.cancelRoleProposal(proposalId);
        
        vm.prank(admin);
        vm.expectRevert("AccessManager: proposal already cancelled");
        accessManager.cancelRoleProposal(proposalId);
    }
    
    /*//////////////////////////////////////////////////////////////
                        ROLE REVOCATION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_RevokeRole_Success() public {
        bytes32 operatorRole = accessManager.OPERATOR_ROLE();
        uint256 roleDelay = accessManager.ROLE_DELAY();
        
        // First grant a role
        vm.prank(admin);
        bytes32 proposalId = accessManager.proposeRoleGrant(operatorRole, newUser);
        
        skip(roleDelay + 1);
        
        vm.prank(admin);
        accessManager.executeRoleGrant(proposalId);
        
        // Verify role was granted
        assertTrue(accessManager.hasRole(operatorRole, newUser));
        
        // Revoke the role
        vm.prank(admin);
        accessManager.revokeRole(operatorRole, newUser);
        
        // Verify role was revoked
        assertFalse(accessManager.hasRole(operatorRole, newUser));
        assertEq(accessManager.roleGrantTime(newUser), 0);
        assertFalse(accessManager.emergencyPausers(newUser));
    }
    
    /*//////////////////////////////////////////////////////////////
                        EMERGENCY PAUSE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_EmergencyPause_ByAdmin() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit EmergencyPause(admin, block.timestamp);
        
        accessManager.emergencyPause();
        
        assertTrue(accessManager.paused());
    }
    
    function test_EmergencyPause_ByEmergencyRole() public {
        vm.prank(emergency);
        vm.expectEmit(true, false, false, true);
        emit EmergencyPause(emergency, block.timestamp);
        
        accessManager.emergencyPause();
        
        assertTrue(accessManager.paused());
    }
    
    function test_EmergencyPause_RevertIf_NotAuthorized() public {
        vm.prank(user1);
        vm.expectRevert("AccessManager: not authorized");
        accessManager.emergencyPause();
    }
    
    function test_EmergencyUnpause_Success() public {
        // First pause
        vm.prank(admin);
        accessManager.emergencyPause();
        assertTrue(accessManager.paused());
        
        // Then unpause
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit EmergencyUnpause(admin, block.timestamp);
        
        accessManager.emergencyUnpause();
        
        assertFalse(accessManager.paused());
    }
    
    /*//////////////////////////////////////////////////////////////
                    EMERGENCY PAUSER MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_AddEmergencyPauser_Success() public {
        vm.prank(admin);
        accessManager.addEmergencyPauser(newUser);
        
        assertTrue(accessManager.emergencyPausers(newUser));
    }
    
    function test_AddEmergencyPauser_RevertIf_NotAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        accessManager.addEmergencyPauser(newUser);
    }
    
    function test_AddEmergencyPauser_RevertIf_InvalidAddress() public {
        vm.prank(admin);
        vm.expectRevert("AccessManager: invalid pauser");
        accessManager.addEmergencyPauser(address(0));
    }
    
    function test_RemoveEmergencyPauser_Success() public {
        vm.prank(admin);
        accessManager.addEmergencyPauser(newUser);
        assertTrue(accessManager.emergencyPausers(newUser));
        
        vm.prank(admin);
        accessManager.removeEmergencyPauser(newUser);
        assertFalse(accessManager.emergencyPausers(newUser));
    }
    
    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_IsAdmin() public view {
        assertTrue(accessManager.isAdmin(admin));
        assertFalse(accessManager.isAdmin(user1));
    }
    
    function test_IsSPV() public view {
        assertTrue(accessManager.isSPV(spv));
        assertFalse(accessManager.isSPV(user1));
    }
    
    function test_IsOperator() public view {
        assertTrue(accessManager.isOperator(operator));
        assertFalse(accessManager.isOperator(user1));
    }
    
    function test_IsPoolCreator() public {
        bytes32 poolCreatorRole = accessManager.POOL_CREATOR_ROLE();
        uint256 roleDelay = accessManager.ROLE_DELAY();
        
        // Grant pool creator role
        vm.prank(admin);
        bytes32 proposalId = accessManager.proposeRoleGrant(poolCreatorRole, newUser);
        
        skip(roleDelay + 1);
        
        vm.prank(admin);
        accessManager.executeRoleGrant(proposalId);
        
        assertTrue(accessManager.isPoolCreator(newUser));
        assertFalse(accessManager.isPoolCreator(user1));
    }
    
    function test_CanActWithDelay() public {
        bytes32 operatorRole = accessManager.OPERATOR_ROLE();
        uint256 roleDelay = accessManager.ROLE_DELAY();
        
        // Newly granted role can't act immediately
        vm.prank(admin);
        bytes32 proposalId = accessManager.proposeRoleGrant(operatorRole, newUser);
        
        skip(roleDelay + 1);
        
        vm.prank(admin);
        accessManager.executeRoleGrant(proposalId);
        
        assertFalse(accessManager.canActWithDelay(operatorRole, newUser));
        
        // After delay period, can act
        skip(roleDelay + 1);
        assertTrue(accessManager.canActWithDelay(operatorRole, newUser));
    }
    
    function test_IsMultisigAdmin() public view {
        assertTrue(accessManager.isMultisigAdmin(admin));  // admin is also multisigAdmin in tests
        assertFalse(accessManager.isMultisigAdmin(user1));
    }
    
    /*//////////////////////////////////////////////////////////////
                        FUZZ TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testFuzz_ProposeAndExecuteRoleGrant(address randomUser, uint8 roleIndex) public {
        vm.assume(randomUser != address(0));
        vm.assume(roleIndex < 10); // Limit to defined roles
        
        bytes32 spvRole = accessManager.SPV_ROLE();
        bytes32 operatorRole = accessManager.OPERATOR_ROLE();
        bytes32 emergencyRole = accessManager.EMERGENCY_ROLE();
        bytes32 oracleRole = accessManager.ORACLE_ROLE();
        bytes32 verifierRole = accessManager.VERIFIER_ROLE();
        bytes32 factoryRole = accessManager.FACTORY_ROLE();
        bytes32 poolCreatorRole = accessManager.POOL_CREATOR_ROLE();
        bytes32 multisigAdminRole = accessManager.MULTISIG_ADMIN_ROLE();
        bytes32 executorRole = accessManager.EXECUTOR_ROLE();
        bytes32 assetManagerRole = accessManager.ASSET_MANAGER_ROLE();
        uint256 roleDelay = accessManager.ROLE_DELAY();
        
        bytes32[] memory roles = new bytes32[](10);
        roles[0] = spvRole;
        roles[1] = operatorRole;
        roles[2] = emergencyRole;
        roles[3] = oracleRole;
        roles[4] = verifierRole;
        roles[5] = factoryRole;
        roles[6] = poolCreatorRole;
        roles[7] = multisigAdminRole;
        roles[8] = executorRole;
        roles[9] = assetManagerRole;
        
        bytes32 role = roles[roleIndex];
        
        // Skip if user already has role
        if (accessManager.hasRole(role, randomUser)) {
            return;
        }
        
        // Propose role grant
        vm.prank(admin);
        bytes32 proposalId = accessManager.proposeRoleGrant(role, randomUser);
        
        // Fast forward past delay
        skip(roleDelay + 1);
        
        // Execute proposal - admin has both DEFAULT_ADMIN_ROLE and MULTISIG_ADMIN_ROLE
        vm.prank(admin);
        accessManager.executeRoleGrant(proposalId);
        
        // Verify
        assertTrue(accessManager.hasRole(role, randomUser));
    }
}

