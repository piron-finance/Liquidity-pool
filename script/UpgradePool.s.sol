// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import "../src/LiquidityPool.sol";
import "../src/governance/TimelockController.sol" as PironTimelock;

/**
 * @title UpgradePool
 * @notice Script to deploy new LiquidityPool implementation for upgrades
 * @dev Deploy new implementation, then use TimelockController to schedule/execute upgrade
 */
contract UpgradePool is Script {
    
    struct UpgradeConfig {
        address timelockController;
        address targetPoolProxy;     // The specific pool proxy to upgrade
        address proposer;            // Address with PROPOSER_ROLE
        address executor;            // Address with EXECUTOR_ROLE
    }
    
    function run() external {
        UpgradeConfig memory config = UpgradeConfig({
            timelockController: vm.envAddress("TIMELOCK_CONTROLLER"),
            targetPoolProxy: vm.envAddress("TARGET_POOL_PROXY"),
            proposer: vm.envAddress("PROPOSER_ADDRESS"),
            executor: vm.envAddress("EXECUTOR_ADDRESS")
        });
        
        deployNewImplementation(config);
    }
    
    function deployNewImplementation(UpgradeConfig memory config) public {
        vm.startBroadcast();
        
        console.log("=== UPGRADING LIQUIDITY POOL ===");
        console.log("Target Pool Proxy: %s", config.targetPoolProxy);
        
        // 1. Deploy new LiquidityPool implementation
        LiquidityPool newPoolImpl = new LiquidityPool();
        console.log("New LiquidityPool implementation deployed at: %s", address(newPoolImpl));
        
        // 2. Get TimelockController instance
        PironTimelock.PironTimelockController timelock = PironTimelock.PironTimelockController(config.timelockController);
        
        // 3. Schedule the upgrade (requires PROPOSER_ROLE)
        console.log("Scheduling upgrade...");
        bytes32 upgradeId = timelock.scheduleUpgrade(
            config.targetPoolProxy,     // target proxy
            address(newPoolImpl)        // new implementation
        );
        
        console.log("Upgrade scheduled with ID: %s", vm.toString(upgradeId));
        console.log("Execute after 72 hours using:");
        console.log("forge script script/ExecuteUpgrade.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast");
        
        vm.stopBroadcast();
        
        // Log upgrade instructions
        _logUpgradeInstructions(config, address(newPoolImpl), upgradeId);
    }
    
    function _logUpgradeInstructions(
        UpgradeConfig memory config,
        address newImpl,
        bytes32 upgradeId
    ) internal view {
        console.log("\n=== UPGRADE INSTRUCTIONS ===");
        console.log("1. Wait 72 hours (UPGRADE_DELAY)");
        console.log("2. Execute upgrade using ExecuteUpgrade script:");
        console.log("   TARGET_PROXY=%s", config.targetPoolProxy);
        console.log("   NEW_IMPLEMENTATION=%s", newImpl);
        console.log("   UPGRADE_ID=%s", vm.toString(upgradeId));
        console.log("   TIMELOCK_CONTROLLER=%s", config.timelockController);
        console.log("\n3. Verify upgrade completed successfully");
    }
}