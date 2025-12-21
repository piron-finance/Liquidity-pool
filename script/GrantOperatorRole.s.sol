// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/StableYieldManager.sol";
import "../src/AccessManager.sol";

/**
 * @title GrantOperatorRole
 * @notice Script to grant OPERATOR_ROLE to admin address on StableYieldManager
 * @dev StableYieldManager uses its own AccessControl storage, so roles must be granted on it directly
 *      This is separate from AccessManager roles
 */
contract GrantOperatorRole is Script {
    
    // Base Sepolia addresses (update for your deployment)
    address constant STABLE_YIELD_MANAGER = 0xE756E61e69cd090Cfe7bF0648c6f488c47629a80;
    address constant ACCESS_MANAGER = 0x05b326d12D802DF04b96Fa82335c5b9e7e22EA4b;
    address constant ADMIN = 0xFeed27E8413d416Df4B26bf7BE275Bf92997413c;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        
        StableYieldManager manager = StableYieldManager(STABLE_YIELD_MANAGER);
        AccessManager accessMgr = AccessManager(ACCESS_MANAGER);
        
        // Get the OPERATOR_ROLE bytes32 from AccessManager
        bytes32 operatorRole = accessMgr.OPERATOR_ROLE();
        
        console.log("=== GRANTING OPERATOR_ROLE ON STABLEYIELDMANAGER ===");
        console.log("StableYieldManager:", STABLE_YIELD_MANAGER);
        console.log("AccessManager:", ACCESS_MANAGER);
        console.log("Admin Address:", ADMIN);
        console.log("OPERATOR_ROLE bytes32:", vm.toString(operatorRole));
        
        // Check current role status
        bool hasRoleBefore = manager.hasRole(operatorRole, ADMIN);
        console.log("Has OPERATOR_ROLE before:", hasRoleBefore);
        
        if (!hasRoleBefore) {
            // Grant OPERATOR_ROLE to admin on StableYieldManager
            // Note: Caller must have DEFAULT_ADMIN_ROLE on StableYieldManager
            manager.grantRole(operatorRole, ADMIN);
            console.log("OPERATOR_ROLE granted to admin on StableYieldManager");
            
            // Verify the grant
            bool hasRoleAfter = manager.hasRole(operatorRole, ADMIN);
            console.log("Has OPERATOR_ROLE after:", hasRoleAfter);
            
            if (hasRoleAfter) {
                console.log("SUCCESS: OPERATOR_ROLE granted successfully!");
            } else {
                console.log("ERROR: Role grant failed!");
            }
        } else {
            console.log("Admin already has OPERATOR_ROLE");
        }
        
        // Also check and grant DEFAULT_ADMIN_ROLE if needed (for future role grants)
        bytes32 adminRole = manager.DEFAULT_ADMIN_ROLE();
        bool hasAdminRole = manager.hasRole(adminRole, ADMIN);
        console.log("Has DEFAULT_ADMIN_ROLE:", hasAdminRole);
        
        if (!hasAdminRole) {
            console.log("WARNING: Admin does not have DEFAULT_ADMIN_ROLE on StableYieldManager");
            console.log("   This may be needed for future role management");
        }
        
        vm.stopBroadcast();
    }
}

