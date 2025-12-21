// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/managed/StableYieldPool.sol";
import "../src/factories/ManagedPoolFactory.sol";
import "../src/StableYieldManager.sol";
import "../src/escrows/StableYieldEscrow.sol";
import "../src/AccessManager.sol";
import "../test/mocks/MockContracts.sol";

contract LiveTest is Script {
    
    // From kk.txt (updated deployment)
    address constant MANAGED_FACTORY = 0x7C02801f94504C5507A3372fec0b411E56038522;
    address constant MOCK_TOKEN = 0x18625b1eD92fE98423F00dc24121D3D9617F33f0;
    address constant STABLE_YIELD_MANAGER = 0x908e17A013d7D5092df122B5012F640AB5100a12;
    address constant ACCESS_MANAGER = 0xB4Bbd9e831Bc191879ee4239FD88dF23450d0B2E;
    
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(pk);
        
        vm.startBroadcast(pk);
        
        console.log("=== STEP 1: CREATE POOL ===");
        console.log("Admin:", admin);
        
        uint256[] memory tenors = new uint256[](2);
        tenors[0] = 90;
        tenors[1] = 180;
        
        ManagedPoolFactory.PoolDeploymentConfig memory config = ManagedPoolFactory.PoolDeploymentConfig({
            asset: MOCK_TOKEN,
            poolName: "Live Test Pool",
            poolSymbol: "pLIVE",
            spvAddress: admin,
            supportedTenors: tenors,
            minInvestment: 100e6,
            expenseRatio: 50,
            underlyingPools: new address[](0)
        });
        
        (address pool, address escrow) = ManagedPoolFactory(MANAGED_FACTORY).createStableYieldPool(config);
        console.log("Pool created:", pool);
        console.log("Escrow:", escrow);
        
        console.log("\n=== STEP 2: MINT & DEPOSIT ===");
        MockERC20 token = MockERC20(MOCK_TOKEN);
        token.mint(admin, 10000e6);
        console.log("Minted: 10000e6");
        
        token.approve(pool, 10000e6);
        uint256 shares = StableYieldPool(pool).deposit(10000e6, admin);
        console.log("Deposited: 10000e6");
        console.log("Shares received:", shares);
        
        console.log("\n=== STEP 3: ALLOCATE TO SPV ===");
        StableYieldEscrow(escrow).allocateToSPV(admin, 5000e6);
        console.log("Allocated 5000e6 to SPV");
        
        console.log("\n=== STEP 4: ADD INSTRUMENT ===");
        
        // Ensure admin has SPV_ROLE on StableYieldManager (it checks its own AccessControl, not AccessManager)
        AccessManager accessMgr = AccessManager(ACCESS_MANAGER);
        bytes32 spvRole = accessMgr.SPV_ROLE();
        StableYieldManager manager = StableYieldManager(STABLE_YIELD_MANAGER);
        
        if (!manager.hasRole(spvRole, admin)) {
            console.log("Granting SPV_ROLE to admin on StableYieldManager...");
            manager.grantRole(spvRole, admin);
        }
        
        manager.addInstrument(
            pool,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            4500e6,
            5000e6,
            block.timestamp + 90 days,
            0,
            0
        );
        console.log("Instrument added: 4500e6 purchase, 5000e6 face value");
        
        console.log("\n=== STEP 5: CHECK NAV ===");
        uint256 nav = StableYieldManager(STABLE_YIELD_MANAGER).calculatePoolNAV(pool);
        uint256 navPerShare = StableYieldManager(STABLE_YIELD_MANAGER).calculateNAVPerShare(pool);
        console.log("Pool NAV:", nav);
        console.log("NAV per share:", navPerShare);
        
        console.log("\n=== SUCCESS ===");
        console.log("All steps completed!");
        console.log("Pool:", pool);
        console.log("Shares owned:", shares);
        console.log("Current NAV:", nav);
        
        vm.stopBroadcast();
    }
}

