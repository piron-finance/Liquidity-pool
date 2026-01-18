// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./fixtures/BaseTest.sol";
import "../src/Manager.sol";
import "../src/PoolRegistry.sol";
import "../src/factories/PoolFactory.sol";
import "../src/LiquidityPool.sol";
import "../src/escrows/PoolEscrow.sol";
import "../src/AccessManager.sol";
import "../src/types/IPoolTypes.sol";
import "../src/interfaces/IPoolFactory.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title SingleAssetPoolTest
 * @notice Comprehensive tests for Single Asset Pool (Deal Pool) functionality
 * @dev Tests full lifecycle: funding → investment → maturity → withdrawal
 */
contract SingleAssetPoolTest is BaseTest {
    
    AccessManager accessManager;
    PoolRegistry registry;
    Manager manager;
    PoolFactory factory;
    MockERC20 token;
    
    address poolAddress;
    address escrowAddress;
    
    uint256 constant TARGET_RAISE = 100_000e6;
    uint256 constant MIN_INVESTMENT = 1000e6;
    uint256 constant EPOCH_DURATION = 7 days;
    uint256 constant MATURITY_DURATION = 90 days;
    
    function setUp() public override {
        super.setUp();
        
        // Deploy token
        token = new MockERC20("Mock USDC", "USDC", 6);
        token.mint(user1, INITIAL_BALANCE);
        token.mint(user2, INITIAL_BALANCE);
        token.mint(user3, INITIAL_BALANCE);
        token.mint(spv, INITIAL_BALANCE * 10);
        
        // Deploy AccessManager
        accessManager = new AccessManager(admin, spv, operator, emergency, multisigAdmin);
        
        // Deploy and initialize PoolRegistry
        PoolRegistry registryImpl = new PoolRegistry();
        bytes memory registryInit = abi.encodeWithSignature(
            "initialize(address,address)",
            address(accessManager),
            admin
        );
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryInit);
        registry = PoolRegistry(address(registryProxy));
        
        // Deploy and initialize Manager
        Manager managerImpl = new Manager();
        bytes memory managerInit = abi.encodeWithSignature(
            "initialize(address,address,address,address)",
            address(registry),
            address(accessManager),
            admin,
            treasury
        );
        ERC1967Proxy managerProxy = new ERC1967Proxy(address(managerImpl), managerInit);
        manager = Manager(address(managerProxy));
        
        // Deploy pool implementations
        LiquidityPool poolImpl = new LiquidityPool();
        PoolEscrow escrowImpl = new PoolEscrow();
        
        // Deploy and initialize PoolFactory
        PoolFactory factoryImpl = new PoolFactory();
        bytes memory factoryInit = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address)",
            address(registry),
            address(manager),
            address(accessManager),
            admin,
            address(poolImpl),
            address(escrowImpl)
        );
        ERC1967Proxy factoryProxy = new ERC1967Proxy(address(factoryImpl), factoryInit);
        factory = PoolFactory(address(factoryProxy));
        
        // Configure registry
        vm.startPrank(admin);
        registry.setFactory(address(factory));
        registry.approveAsset(address(token), "Mock USDC", "USDC", true);
        accessManager.grantRoleDuringDeployment(accessManager.POOL_CREATOR_ROLE(), admin);
        vm.stopPrank();
    }
    
    // ============ HELPER FUNCTIONS ============
    
    function _createPool() internal returns (address, address) {
        IPoolFactory.PoolConfig memory config = IPoolFactory.PoolConfig({
            asset: address(token),
            instrumentType: IPoolTypes.InstrumentType.DISCOUNTED,
            instrumentName: "Test Deal Pool",
            targetRaise: TARGET_RAISE,
            epochDuration: EPOCH_DURATION,
            maturityDate: block.timestamp + MATURITY_DURATION,
            discountRate: 500, // 5%
            spvAddress: spv,
            couponDates: new uint256[](0),
            couponRates: new uint256[](0),
            minimumFundingThreshold: 8000, // 80%
            minInvestment: MIN_INVESTMENT,
            withdrawalFeeBps: 100 // 1%
        });
        
        vm.prank(admin);
        (address pool, address escrow) = factory.createPool(config);
        
        return (pool, escrow);
    }
    
    function _depositAs(address user, uint256 amount) internal {
        vm.startPrank(user);
        token.approve(poolAddress, amount);
        LiquidityPool(poolAddress).deposit(amount, user);
        vm.stopPrank();
    }
    
    // ============ POOL CREATION TESTS ============
    
    function test_createPool_success() public {
        (poolAddress, escrowAddress) = _createPool();
        
        assertTrue(registry.isRegisteredPool(poolAddress), "Pool not registered");
        assertEq(LiquidityPool(poolAddress).asset(), address(token), "Wrong asset");
        assertTrue(manager.poolStatus(poolAddress) == IPoolTypes.PoolStatus.FUNDING, "Wrong status");
    }
    
    function test_createPool_onlyAdmin() public {
        IPoolFactory.PoolConfig memory config = IPoolFactory.PoolConfig({
            asset: address(token),
            instrumentType: IPoolTypes.InstrumentType.DISCOUNTED,
            instrumentName: "Test Pool",
            targetRaise: TARGET_RAISE,
            epochDuration: EPOCH_DURATION,
            maturityDate: block.timestamp + MATURITY_DURATION,
            discountRate: 500,
            spvAddress: spv,
            couponDates: new uint256[](0),
            couponRates: new uint256[](0),
            minimumFundingThreshold: 8000,
            minInvestment: MIN_INVESTMENT,
            withdrawalFeeBps: 100
        });
        
        vm.prank(user1);
        vm.expectRevert();
        factory.createPool(config);
    }
    
    // ============ DEPOSIT TESTS ============
    
    function test_deposit_success() public {
        (poolAddress, escrowAddress) = _createPool();
        
        uint256 depositAmount = 10_000e6;
        _depositAs(user1, depositAmount);
        
        assertEq(LiquidityPool(poolAddress).balanceOf(user1), depositAmount, "Wrong shares");
        assertEq(manager.poolTotalRaised(poolAddress), depositAmount, "Wrong total raised");
    }
    
    function test_deposit_multipleUsers() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 30_000e6);
        _depositAs(user2, 40_000e6);
        _depositAs(user3, 30_000e6);
        
        assertEq(manager.poolTotalRaised(poolAddress), TARGET_RAISE, "Should reach target");
    }
    
    function test_deposit_belowMinimum_reverts() public {
        (poolAddress, escrowAddress) = _createPool();
        
        vm.startPrank(user1);
        token.approve(poolAddress, 500e6);
        vm.expectRevert();
        LiquidityPool(poolAddress).deposit(500e6, user1); // Below MIN_INVESTMENT
        vm.stopPrank();
    }
    
    function test_deposit_exceedsTarget_reverts() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 80_000e6);
        
        vm.startPrank(user2);
        token.approve(poolAddress, 30_000e6);
        vm.expectRevert();
        LiquidityPool(poolAddress).deposit(30_000e6, user2); // Would exceed target
        vm.stopPrank();
    }
    
    function test_deposit_afterEpochEnd_reverts() public {
        (poolAddress, escrowAddress) = _createPool();
        
        skipTime(EPOCH_DURATION + 1);
        
        vm.startPrank(user1);
        token.approve(poolAddress, 10_000e6);
        vm.expectRevert();
        LiquidityPool(poolAddress).deposit(10_000e6, user1);
        vm.stopPrank();
    }
    
    // ============ WITHDRAWAL DURING FUNDING TESTS ============
    
    function test_withdrawDuringFunding_success() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 20_000e6);
        
        uint256 balanceBefore = token.balanceOf(user1);
        
        vm.prank(user1);
        LiquidityPool(poolAddress).withdraw(10_000e6, user1, user1);
        
        // Should get amount back (may have some fee depending on implementation)
        assertTrue(token.balanceOf(user1) > balanceBefore, "Should receive tokens back");
    }
    
    // ============ EPOCH CLOSE TESTS ============
    
    function test_closeEpoch_successfulFunding() public {
        (poolAddress, escrowAddress) = _createPool();
        
        // Fund to 80% (minimum threshold)
        _depositAs(user1, 80_000e6);
        
        skipTime(EPOCH_DURATION + 1);
        
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        
        assertTrue(manager.poolStatus(poolAddress) == IPoolTypes.PoolStatus.PENDING_INVESTMENT);
    }
    
    function test_closeEpoch_underfunded_emergency() public {
        (poolAddress, escrowAddress) = _createPool();
        
        // Fund only 50% (below 80% threshold)
        _depositAs(user1, 50_000e6);
        
        skipTime(EPOCH_DURATION + 1);
        
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        
        assertTrue(manager.poolStatus(poolAddress) == IPoolTypes.PoolStatus.EMERGENCY);
    }
    
    function test_closeEpoch_earlyClose_onlyFilled() public {
        (poolAddress, escrowAddress) = _createPool();
        
        // Fully fund the pool
        _depositAs(user1, 50_000e6);
        _depositAs(user2, 50_000e6);
        
        // Operator marks as filled
        vm.prank(operator);
        manager.handlePoolFilled(poolAddress);
        
        // Can close before epoch ends
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        
        assertTrue(manager.poolStatus(poolAddress) == IPoolTypes.PoolStatus.PENDING_INVESTMENT);
    }
    
    // ============ SPV INVESTMENT FLOW TESTS ============
    
    function test_spvInvestment_fullFlow() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        skipTime(EPOCH_DURATION + 1);
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        
        // SPV withdraws funds
        vm.prank(spv);
        manager.withdrawFundsForInvestment(poolAddress, 100_000e6);
        
        assertEq(token.balanceOf(spv), INITIAL_BALANCE * 10 + 100_000e6, "SPV should receive funds");
        
        // SPV confirms investment
        vm.prank(spv);
        manager.processInvestment(poolAddress, 100_000e6, "ipfs://proof123");
        
        assertTrue(manager.poolStatus(poolAddress) == IPoolTypes.PoolStatus.INVESTED);
        assertEq(manager.poolActualInvested(poolAddress), 100_000e6);
    }
    
    function test_spvInvestment_partialInvestment() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        skipTime(EPOCH_DURATION + 1);
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        
        // SPV withdraws and invests only 80%
        vm.prank(spv);
        manager.withdrawFundsForInvestment(poolAddress, 80_000e6);
        
        vm.prank(spv);
        manager.processInvestment(poolAddress, 80_000e6, "ipfs://proof123");
        
        assertEq(manager.poolActualInvested(poolAddress), 80_000e6);
    }
    
    // ============ MATURITY TESTS ============
    
    function test_maturity_discountedInstrument() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        skipTime(EPOCH_DURATION + 1);
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        
        vm.prank(spv);
        manager.withdrawFundsForInvestment(poolAddress, 100_000e6);
        
        vm.prank(spv);
        manager.processInvestment(poolAddress, 100_000e6, "ipfs://proof");
        
        // Skip to maturity
        skipTime(MATURITY_DURATION);
        
        // SPV returns funds with 5% discount gain
        // Face value = 100000 / (1 - 0.05) = 105263.16
        uint256 faceValue = (uint256(100_000e6) * 10000) / (10000 - 500);
        
        vm.startPrank(spv);
        token.approve(address(manager), faceValue);
        manager.processMaturity(poolAddress, faceValue);
        vm.stopPrank();
        
        assertTrue(manager.poolStatus(poolAddress) == IPoolTypes.PoolStatus.MATURED);
    }
    
    function test_maturity_withdrawal() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        skipTime(EPOCH_DURATION + 1);
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        
        vm.prank(spv);
        manager.withdrawFundsForInvestment(poolAddress, 100_000e6);
        
        vm.prank(spv);
        manager.processInvestment(poolAddress, 100_000e6, "ipfs://proof");
        
        skipTime(MATURITY_DURATION);
        
        uint256 faceValue = (uint256(100_000e6) * 10000) / (10000 - 500);
        
        vm.startPrank(spv);
        token.approve(address(manager), faceValue);
        manager.processMaturity(poolAddress, faceValue);
        vm.stopPrank();
        
        // User withdraws at maturity
        uint256 balanceBefore = token.balanceOf(user1);
        
        vm.prank(user1);
        LiquidityPool(poolAddress).withdraw(100_000e6, user1, user1);
        
        uint256 received = token.balanceOf(user1) - balanceBefore;
        assertTrue(received > 0, "Should receive tokens");
    }
    
    // ============ EMERGENCY TESTS ============
    
    function test_emergency_cancelPool() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 50_000e6);
        
        vm.prank(emergency);
        manager.cancelPool(poolAddress);
        
        assertTrue(manager.poolStatus(poolAddress) == IPoolTypes.PoolStatus.EMERGENCY);
    }
    
    function test_emergency_withdrawal() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 50_000e6);
        
        vm.prank(emergency);
        manager.cancelPool(poolAddress);
        
        // User can withdraw in emergency
        uint256 balanceBefore = token.balanceOf(user1);
        
        vm.prank(user1);
        LiquidityPool(poolAddress).withdraw(50_000e6, user1, user1);
        
        assertTrue(token.balanceOf(user1) > balanceBefore, "Should get refund in emergency");
    }
    
    // ============ INTEREST-BEARING INSTRUMENT TESTS ============
    
    function test_interestBearing_couponPayment() public {
        // Create interest-bearing pool
        uint256[] memory couponDates = new uint256[](2);
        couponDates[0] = block.timestamp + 30 days;
        couponDates[1] = block.timestamp + 60 days;
        
        uint256[] memory couponRates = new uint256[](2);
        couponRates[0] = 200; // 2%
        couponRates[1] = 200; // 2%
        
        IPoolFactory.PoolConfig memory config = IPoolFactory.PoolConfig({
            asset: address(token),
            instrumentType: IPoolTypes.InstrumentType.INTEREST_BEARING,
            instrumentName: "Interest Bearing Pool",
            targetRaise: TARGET_RAISE,
            epochDuration: EPOCH_DURATION,
            maturityDate: block.timestamp + MATURITY_DURATION,
            discountRate: 0,
            spvAddress: spv,
            couponDates: couponDates,
            couponRates: couponRates,
            minimumFundingThreshold: 8000,
            minInvestment: MIN_INVESTMENT,
            withdrawalFeeBps: 100
        });
        
        vm.prank(admin);
        (poolAddress, escrowAddress) = factory.createPool(config);
        
        _depositAs(user1, 100_000e6);
        
        skipTime(EPOCH_DURATION + 1);
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        
        vm.prank(spv);
        manager.withdrawFundsForInvestment(poolAddress, 100_000e6);
        
        vm.prank(spv);
        manager.processInvestment(poolAddress, 100_000e6, "ipfs://proof");
        
        // Skip to first coupon date
        skipTime(30 days);
        
        // SPV pays coupon
        uint256 couponAmount = (100_000e6 * 200) / 10000; // 2%
        
        vm.startPrank(spv);
        token.approve(address(manager), couponAmount);
        manager.processCouponPayment(poolAddress, couponAmount);
        vm.stopPrank();
        
        assertEq(manager.poolTotalCouponsReceived(poolAddress), couponAmount);
    }
    
    // ============ EDGE CASES ============
    
    function test_edgeCase_exactMinimumThreshold() public {
        (poolAddress, escrowAddress) = _createPool();
        
        // Fund exactly 80% (minimum threshold)
        _depositAs(user1, 80_000e6);
        
        skipTime(EPOCH_DURATION + 1);
        
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        
        // Should succeed at exactly minimum threshold
        assertTrue(manager.poolStatus(poolAddress) == IPoolTypes.PoolStatus.PENDING_INVESTMENT);
    }
    
    function test_edgeCase_justBelowThreshold() public {
        (poolAddress, escrowAddress) = _createPool();
        
        // Fund 79.99% (just below threshold)
        _depositAs(user1, 79_999e6);
        
        skipTime(EPOCH_DURATION + 1);
        
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        
        // Should fail and go to emergency
        assertTrue(manager.poolStatus(poolAddress) == IPoolTypes.PoolStatus.EMERGENCY);
    }
    
    function test_edgeCase_withdrawDuringInvested_reverts() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        skipTime(EPOCH_DURATION + 1);
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        
        vm.prank(spv);
        manager.withdrawFundsForInvestment(poolAddress, 100_000e6);
        
        vm.prank(spv);
        manager.processInvestment(poolAddress, 100_000e6, "ipfs://proof");
        
        // User cannot withdraw during INVESTED status (before maturity)
        vm.prank(user1);
        vm.expectRevert();
        LiquidityPool(poolAddress).withdraw(100_000e6, user1, user1);
    }
    
    // ============ VIEW FUNCTIONS ============
    
    function test_poolStatus() public {
        (poolAddress, escrowAddress) = _createPool();
        
        assertTrue(manager.poolStatus(poolAddress) == IPoolTypes.PoolStatus.FUNDING);
    }
    
    function test_poolTotalRaised() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 50_000e6);
        
        assertEq(manager.poolTotalRaised(poolAddress), 50_000e6);
    }
}
