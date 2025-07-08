// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/Manager.sol";
import "../src/PoolRegistry.sol";
import "../src/AccessManager.sol";
import "../src/interfaces/IManager.sol";
import "../src/interfaces/IPoolRegistry.sol";

contract SimpleIntegrationTest is Test {
    Manager public manager;
    PoolRegistry public registry;
    AccessManager public accessManager;
    
    address public admin = address(0x1);
    address public spv = address(0x2);
    address public operator = address(0x3);
    address public user1 = address(0x4);
    address public testPool = address(0x6);
    address public testAsset = address(0x8);
    
    function setUp() public {
        // Deploy access manager
        accessManager = new AccessManager(admin);
        
        // Deploy registry
        registry = new PoolRegistry(address(0), admin);
        
        // Deploy manager with real registry
        manager = new Manager(address(registry), address(accessManager));
        
        // Set factory in registry (using manager as mock factory for testing)
        vm.startPrank(admin);
        registry.setFactory(address(manager));
        
        // Approve the test asset
        registry.approveAsset(testAsset);
        
        // Setup roles
        accessManager.grantRole(accessManager.SPV_ROLE(), spv);
        accessManager.grantRole(accessManager.OPERATOR_ROLE(), operator);
        vm.stopPrank();
        
        // Register test pool in registry
        IPoolRegistry.PoolInfo memory poolInfo = IPoolRegistry.PoolInfo({
            pool: testPool,
            manager: address(manager),
            escrow: address(0x7),
            asset: testAsset,
            instrumentType: "Test Pool",
            createdAt: block.timestamp,
            isActive: true,
            creator: admin,
            targetRaise: 100_000e6,
            maturityDate: block.timestamp + 90 days
        });
        
        // Mock factory call to register pool
        vm.startPrank(address(manager));
        registry.registerPool(testPool, poolInfo);
        vm.stopPrank();
        
        vm.warp(block.timestamp + 1 days); // Skip role delays
    }
    
    function testSlippageProtectionFunctionality() public {
        console.log("=== Testing Slippage Protection ===");
        
        // Test default slippage tolerance
        uint256 defaultTolerance = manager.getSlippageTolerance(testPool);
        assertEq(defaultTolerance, 500, "Default slippage tolerance should be 5%");
        console.log("Default slippage tolerance:", defaultTolerance, "basis points");
        
        // Test custom slippage tolerance
        vm.prank(admin);
        manager.setSlippageTolerance(testPool, 1000); // 10%
        
        uint256 customTolerance = manager.getSlippageTolerance(testPool);
        assertEq(customTolerance, 1000, "Custom slippage tolerance should be 10%");
        console.log("Custom slippage tolerance:", customTolerance, "basis points");
        
        // Test slippage validation
        uint256 expectedAmount = 100_000e6; // 100k USDC
        
        // Test valid slippage (within 10% tolerance)
        assertTrue(manager.validateSlippage(testPool, expectedAmount, 95_000e6), "5% down should be valid");
        assertTrue(manager.validateSlippage(testPool, expectedAmount, 105_000e6), "5% up should be valid");
        console.log("Valid slippage cases pass");
        
        // Test invalid slippage (exceeds 10% tolerance)
        assertFalse(manager.validateSlippage(testPool, expectedAmount, 89_000e6), "11% down should be invalid");
        assertFalse(manager.validateSlippage(testPool, expectedAmount, 111_000e6), "11% up should be invalid");
        console.log("Invalid slippage cases fail");
        
        // Test edge cases
        assertTrue(manager.validateSlippage(testPool, expectedAmount, 90_000e6), "Exactly 10% down should be valid");
        assertTrue(manager.validateSlippage(testPool, expectedAmount, 110_000e6), "Exactly 10% up should be valid");
        console.log("Edge cases work correctly");
    }
    
    function testDiscountCalculation() public {
        console.log("=== Testing Discount Calculation ===");
        
        // Test various discount rates
        uint256 actualRaised = 100_000e6; // 100k USDC
        
        // 18% discount rate (1800 basis points)
        uint256 discountRate18 = 1800;
        uint256 faceValue18 = (actualRaised * 10000) / (10000 - discountRate18);
        uint256 expectedFaceValue18 = 121_951_219_512; // Approximately 121,951.22 USDC
        
        // Allow for small rounding differences
        assertApproxEqRel(faceValue18, expectedFaceValue18, 0.001e18, "18% discount calculation should be correct");
        console.log("18% discount: 100k USDC to", faceValue18 / 1e6, "USDC face value");
        
        // 10% discount rate (1000 basis points)
        uint256 discountRate10 = 1000;
        uint256 faceValue10 = (actualRaised * 10000) / (10000 - discountRate10);
        uint256 expectedFaceValue10 = 111_111_111_111; // Approximately 111,111.11 USDC
        
        assertApproxEqRel(faceValue10, expectedFaceValue10, 0.001e18, "10% discount calculation should be correct");
        console.log("10% discount: 100k USDC to", faceValue10 / 1e6, "USDC face value");
        
        // 5% discount rate (500 basis points)
        uint256 discountRate5 = 500;
        uint256 faceValue5 = (actualRaised * 10000) / (10000 - discountRate5);
        uint256 expectedFaceValue5 = 105_263_157_894; // Approximately 105,263.16 USDC
        
        assertApproxEqRel(faceValue5, expectedFaceValue5, 0.001e18, "5% discount calculation should be correct");
        console.log("5% discount: 100k USDC to", faceValue5 / 1e6, "USDC face value");
        
        // Calculate APY for 90-day investment
        uint256 profit18 = faceValue18 - actualRaised;
        uint256 apy18 = (profit18 * 365 * 100) / (actualRaised * 90);
        console.log("18% discount APY:", apy18, "%");
        
        uint256 profit10 = faceValue10 - actualRaised;
        uint256 apy10 = (profit10 * 365 * 100) / (actualRaised * 90);
        console.log("10% discount APY:", apy10, "%");
        
        uint256 profit5 = faceValue5 - actualRaised;
        uint256 apy5 = (profit5 * 365 * 100) / (actualRaised * 90);
        console.log("5% discount APY:", apy5, "%");
    }
    
    function testAccessControlSystem() public {
        console.log("=== Testing Access Control System ===");
        
        // Test role assignments
        assertTrue(accessManager.hasRole(accessManager.SPV_ROLE(), spv), "SPV should have SPV role");
        assertTrue(accessManager.hasRole(accessManager.OPERATOR_ROLE(), operator), "Operator should have operator role");
        assertTrue(accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), admin), "Admin should have admin role");
        console.log("Role assignments correct");
        
        // Test role restrictions
        vm.prank(user1);
        vm.expectRevert("Manager/access-denied");
        manager.setSlippageTolerance(testPool, 1000);
        console.log("Non-admin cannot set slippage tolerance");
        
        // Test admin can set slippage tolerance
        vm.prank(admin);
        manager.setSlippageTolerance(testPool, 750);
        assertEq(manager.getSlippageTolerance(testPool), 750, "Admin should be able to set slippage tolerance");
        console.log("Admin can set slippage tolerance");
        
        // Test maximum slippage tolerance limit
        vm.prank(admin);
        vm.expectRevert("Manager/tolerance-too-high");
        manager.setSlippageTolerance(testPool, 1100); // 11% - should fail
        console.log("Maximum slippage tolerance enforced");
    }
    
    function testManagerConstants() public {
        console.log("=== Testing Manager Constants ===");
        
        // Test slippage constants
        assertEq(manager.DEFAULT_SLIPPAGE_TOLERANCE(), 500, "Default slippage tolerance should be 5%");
        assertEq(manager.MAX_SLIPPAGE_TOLERANCE(), 1000, "Max slippage tolerance should be 10%");
        console.log("Slippage constants correct");
        console.log("  - Default tolerance:", manager.DEFAULT_SLIPPAGE_TOLERANCE(), "basis points");
        console.log("  - Maximum tolerance:", manager.MAX_SLIPPAGE_TOLERANCE(), "basis points");
    }
    
    function testEdgeCases() public {
        console.log("=== Testing Edge Cases ===");
        
        // Test zero amount slippage validation
        assertTrue(manager.validateSlippage(testPool, 0, 0), "Zero amounts should be valid");
        console.log("Zero amount slippage validation works");
        
        // Test very small amounts
        assertTrue(manager.validateSlippage(testPool, 1, 1), "Very small amounts should be valid");
        console.log("Very small amount slippage validation works");
        
        // Test large amounts (avoiding overflow)
        uint256 largeAmount = 1_000_000_000e6; // 1 billion USDC
        uint256 largeAmountWithSlippage = largeAmount * 105 / 100; // 5% up
        assertTrue(manager.validateSlippage(testPool, largeAmount, largeAmountWithSlippage), "Large amounts should work");
        console.log("Large amount slippage validation works");
        
        // Test discount calculation edge cases
        uint256 minDiscount = 1; // 0.01%
        uint256 faceValueMin = (100_000e6 * 10000) / (10000 - minDiscount);
        assertGt(faceValueMin, 100_000e6, "Minimum discount should increase face value");
        console.log("Minimum discount calculation works");
        
        uint256 maxDiscount = 9000; // 90% (more reasonable than 99.99%)
        uint256 faceValueMax = (100_000e6 * 10000) / (10000 - maxDiscount);
        assertGt(faceValueMax, 100_000e6 * 5, "Maximum discount should create large face value");
        console.log("Maximum discount calculation works");
    }
    
    function testSystemIntegration() public {
        console.log("=== Testing System Integration ===");
        
        // Test that all components work together
        
        // 1. Set up slippage protection
        vm.prank(admin);
        manager.setSlippageTolerance(testPool, 800); // 8%
        
        // 2. Test discount calculation with slippage
        uint256 targetRaise = 100_000e6;
        uint256 discountRate = 1500; // 15%
        uint256 expectedFaceValue = (targetRaise * 10000) / (10000 - discountRate);
        
        // 3. Test that actual investment within slippage tolerance would be valid
        uint256 actualInvestment = targetRaise * 102 / 100; // 2% slippage
        assertTrue(manager.validateSlippage(testPool, targetRaise, actualInvestment), "Investment within tolerance should be valid");
        
        // 4. Test that maturity amount within slippage tolerance would be valid
        uint256 maturityAmount = expectedFaceValue * 98 / 100; // 2% slippage down
        assertTrue(manager.validateSlippage(testPool, expectedFaceValue, maturityAmount), "Maturity amount within tolerance should be valid");
        
        console.log("System integration test passed");
        console.log("  - Target raise:", targetRaise / 1e6, "USDC");
        console.log("  - Expected face value:", expectedFaceValue / 1e6, "USDC");
        console.log("  - Actual investment:", actualInvestment / 1e6, "USDC");
        console.log("  - Maturity amount:", maturityAmount / 1e6, "USDC");
        console.log("  - Slippage tolerance:", manager.getSlippageTolerance(testPool), "basis points");
    }
} 