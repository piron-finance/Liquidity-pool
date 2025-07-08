// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/Manager.sol";
import "../src/LiquidityPool.sol";
import "../src/PoolEscrow.sol";
import "../src/AccessManager.sol";
import "../src/PoolRegistry.sol";
import "../src/factories/PoolFactory.sol";
import "../src/FeeManager.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Define MockUSDC here since it's for deployment
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 10_000_000 * 1e6);
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        vm.startBroadcast(deployerPrivateKey);
        
        console.log("Deploying Piron Pools system...");
        console.log("Deployer:", deployer);
        
        // 1. Deploy mock USDC for testing
        MockUSDC usdc = new MockUSDC();
        console.log("Mock USDC deployed at:", address(usdc));
        
        // 2. Deploy AccessManager
        AccessManager accessManager = new AccessManager(deployer);
        console.log("AccessManager deployed at:", address(accessManager));
        
        // 3. Deploy PoolFactory first (with dummy registry and manager)
        PoolFactory factory = new PoolFactory(
            address(0x1),                 // Dummy registry for now
            address(0x1),                 // Dummy manager for now
            address(accessManager)
        );
        console.log("PoolFactory deployed at:", address(factory));
        
        // 4. Deploy PoolRegistry with the real factory address
        PoolRegistry registry = new PoolRegistry(address(factory), deployer);
        console.log("PoolRegistry deployed at:", address(registry));
        
        // 5. Deploy singleton Manager with real registry
        Manager manager = new Manager(address(registry), address(accessManager));
        console.log("Singleton Manager deployed at:", address(manager));
        
        // 6. Deploy FeeManager
        FeeManager feeManager = new FeeManager(address(accessManager), deployer);
        console.log("FeeManager deployed at:", address(feeManager));
        
        // 7. Update factory with real registry and manager addresses
        factory.setRegistry(address(registry));
        console.log("Factory updated with registry address");
        
        factory.setManager(address(manager));
        console.log("Factory updated with manager address");
        
        // 8. Set up roles
        accessManager.grantRole(accessManager.DEFAULT_ADMIN_ROLE(), deployer);
        accessManager.grantRole(keccak256("POOL_CREATOR_ROLE"), deployer);
        accessManager.grantRole(keccak256("SPV_ROLE"), deployer);
        accessManager.grantRole(keccak256("OPERATOR_ROLE"), deployer);
        
        console.log("Roles granted to deployer");
        
        // 9. Approve USDC as valid asset
        registry.approveAsset(address(usdc));
        console.log("USDC approved as valid asset");
        
        vm.stopBroadcast();
        
        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("You can now create pools using the factory!");
        console.log("Factory address:", address(factory));
        console.log("Manager address:", address(manager));
        console.log("USDC address:", address(usdc));
        
        // Example: Create a test pool
        console.log("\n=== CREATING TEST POOL ===");
        
        vm.startBroadcast(deployerPrivateKey);
        
        IPoolFactory.PoolConfig memory config = IPoolFactory.PoolConfig({
            asset: address(usdc),
            instrumentType: IPoolManager.InstrumentType.DISCOUNTED,
            instrumentName: "90-Day Treasury Bills",
            targetRaise: 100_000e6, // 100k USDC
            epochDuration: 7 days,
            maturityDate: block.timestamp + 90 days,
            discountRate: 1800, // 18% discount
            spvAddress: deployer,
            multisigSigners: new address[](0) // Empty for now
        });
        
        (address pool, address escrow) = factory.createPool(config);
        
        console.log("Test pool created!");
        console.log("Pool address:", pool);
        console.log("Escrow address:", escrow);
        
        vm.stopBroadcast();
    }
} 