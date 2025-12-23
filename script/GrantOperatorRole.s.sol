// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/StableYieldManager.sol";
import "../src/AccessManager.sol";

/**
 * @title GrantOperatorRole
 * @notice Script to grant OPERATOR_ROLE to admin address via AccessManager
 * @dev StableYieldManager uses an external AccessManager for role checks
 *      Roles are granted via AccessManager, not on StableYieldManager directly
 */
contract GrantOperatorRole is Script {
    
    // Base Sepolia addresses (update for your deployment)
    address constant STABLE_YIELD_MANAGER = 0xE756E61e69cd090Cfe7bF0648c6f488c47629a80;
    address constant ACCESS_MANAGER = 0x05b326d12D802DF04b96Fa82335c5b9e7e22EA4b;
    address constant ADMIN = 0xFeed27E8413d416Df4B26bf7BE275Bf92997413c;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        
        AccessManager accessMgr = AccessManager(ACCESS_MANAGER);
        
        // Get the OPERATOR_ROLE bytes32 from AccessManager
        bytes32 operatorRole = accessMgr.OPERATOR_ROLE();
        
        console.log("=== GRANTING OPERATOR_ROLE VIA ACCESS MANAGER ===");
        console.log("StableYieldManager:", STABLE_YIELD_MANAGER);
        console.log("AccessManager:", ACCESS_MANAGER);
        console.log("Admin Address:", ADMIN);
        console.log("OPERATOR_ROLE bytes32:", vm.toString(operatorRole));
        
        // Check current role status via AccessManager
        bool hasRoleBefore = accessMgr.hasRole(operatorRole, ADMIN);
        console.log("Has OPERATOR_ROLE before:", hasRoleBefore);
        
        if (!hasRoleBefore) {
            // Note: Role grants via AccessManager may require proposals and delays
            // For immediate grants during deployment, use grantRoleDuringDeployment
            // For post-deployment, use the proposal system
            console.log("NOTE: Use AccessManager proposal system to grant roles post-deployment");
            console.log("      Or use grantRoleDuringDeployment during initial setup");
        } else {
            console.log("Admin already has OPERATOR_ROLE via AccessManager");
        }
        
        // Also check SPV_ROLE
        bytes32 spvRole = accessMgr.SPV_ROLE();
        bool hasSpvRole = accessMgr.hasRole(spvRole, ADMIN);
        console.log("Has SPV_ROLE:", hasSpvRole);
        
        // Check DEFAULT_ADMIN_ROLE
        bytes32 adminRole = accessMgr.DEFAULT_ADMIN_ROLE();
        bool hasAdminRole = accessMgr.hasRole(adminRole, ADMIN);
        console.log("Has DEFAULT_ADMIN_ROLE:", hasAdminRole);
        
        vm.stopBroadcast();
    }
}
