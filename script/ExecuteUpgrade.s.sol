// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import "../src/governance/TimelockController.sol" as PironTimelock;

contract ExecuteUpgrade is Script {

    struct ExecuteConfig {
        address timelockController;
        address targetProxy;
        address newImplementation;
        bytes32 operationId;
        address executor;
    }

    function run() external {
        ExecuteConfig memory config = ExecuteConfig({
            timelockController: vm.envAddress("TIMELOCK_CONTROLLER"),
            targetProxy: vm.envAddress("TARGET_PROXY"),
            newImplementation: vm.envAddress("NEW_IMPLEMENTATION"),
            operationId: vm.envBytes32("OPERATION_ID"),
            executor: vm.envAddress("EXECUTOR_ADDRESS")
        });

        executeScheduledUpgrade(config);
    }

    function executeScheduledUpgrade(ExecuteConfig memory config) public {
        vm.startBroadcast();

        console.log("=== EXECUTING SCHEDULED UPGRADE ===");
        console.log("Target Proxy: %s", config.targetProxy);
        console.log("New Implementation: %s", config.newImplementation);

        PironTimelock.PironTimelockController timelock = PironTimelock.PironTimelockController(config.timelockController);

        timelock.executeUpgrade(
            config.targetProxy,
            config.newImplementation,
            config.operationId
        );

        console.log("Upgrade executed successfully");
        console.log("Proxy %s now uses implementation %s", config.targetProxy, config.newImplementation);

        vm.stopBroadcast();
    }
}
