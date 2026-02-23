// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import "../src/Manager.sol";
import "../src/governance/TimelockController.sol" as PironTimelock;

contract UpgradeManager is Script {

    struct UpgradeConfig {
        address timelockController;
        address managerProxy;
        address proposer;
    }

    function run() external {
        UpgradeConfig memory config = UpgradeConfig({
            timelockController: vm.envAddress("TIMELOCK_CONTROLLER"),
            managerProxy: vm.envAddress("MANAGER_PROXY"),
            proposer: vm.envAddress("PROPOSER_ADDRESS")
        });

        deployNewImplementation(config);
    }

    function deployNewImplementation(UpgradeConfig memory config) public {
        vm.startBroadcast();

        console.log("=== UPGRADING MANAGER CONTRACT ===");
        console.log("Manager Proxy: %s", config.managerProxy);

        Manager newManagerImpl = new Manager();
        console.log("New Manager implementation deployed at: %s", address(newManagerImpl));

        PironTimelock.PironTimelockController timelock = PironTimelock.PironTimelockController(config.timelockController);

        console.log("Scheduling upgrade...");
        bytes32 upgradeId = timelock.scheduleUpgrade(
            config.managerProxy,
            address(newManagerImpl)
        );

        console.log("Upgrade scheduled with ID: %s", vm.toString(upgradeId));
        console.log("Execute after 72 hours using ExecuteUpgrade script");

        vm.stopBroadcast();

        _logUpgradeInstructions(config, address(newManagerImpl));
    }

    function _logUpgradeInstructions(
        UpgradeConfig memory config,
        address newImpl
    ) internal view {
        console.log("");
        console.log("=== UPGRADE INSTRUCTIONS ===");
        console.log("1. Wait 72 hours (UPGRADE_DELAY)");
        console.log("2. Set environment variables:");
        console.log("   export TARGET_PROXY=%s", config.managerProxy);
        console.log("   export NEW_IMPLEMENTATION=%s", newImpl);
        console.log("   export TIMELOCK_CONTROLLER=%s", config.timelockController);
        console.log("3. Execute: forge script script/ExecuteUpgrade.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast");
    }
}
