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
        
        token = new MockERC20("Mock USDC", "USDC", 6);
        token.mint(user1, INITIAL_BALANCE);
        token.mint(user2, INITIAL_BALANCE);
        token.mint(user3, INITIAL_BALANCE);
        token.mint(spv, INITIAL_BALANCE * 10);
        
        accessManager = new AccessManager(admin, spv, operator, emergency, multisigAdmin);
        
        PoolRegistry registryImpl = new PoolRegistry();
        bytes memory registryInit = abi.encodeWithSignature(
            "initialize(address,address)",
            address(accessManager),
            admin
        );
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryInit);
        registry = PoolRegistry(address(registryProxy));
        
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
        
        LiquidityPool poolImpl = new LiquidityPool();
        PoolEscrow escrowImpl = new PoolEscrow();
        
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
        
        vm.startPrank(admin);
        registry.setFactory(address(factory));
        registry.approveAsset(address(token), "Mock USDC", "USDC", true);
        accessManager.grantRoleDuringDeployment(accessManager.POOL_CREATOR_ROLE(), admin);
        vm.stopPrank();
    }
    
    function _createPool() internal returns (address, address) {
        IPoolFactory.PoolConfig memory config = IPoolFactory.PoolConfig({
            asset: address(token),
            instrumentType: IPoolTypes.InstrumentType.DISCOUNTED,
            instrumentName: "Test Deal Pool",
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
        LiquidityPool(poolAddress).deposit(500e6, user1);
        vm.stopPrank();
    }
    
    function test_deposit_exceedsTarget_reverts() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 80_000e6);
        
        vm.startPrank(user2);
        token.approve(poolAddress, 30_000e6);
        vm.expectRevert();
        LiquidityPool(poolAddress).deposit(30_000e6, user2);
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
    
    function test_withdrawDuringFunding_success() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 20_000e6);
        
        uint256 balanceBefore = token.balanceOf(user1);
        
        vm.prank(user1);
        LiquidityPool(poolAddress).withdraw(10_000e6, user1, user1);
        
        assertTrue(token.balanceOf(user1) > balanceBefore, "Should receive tokens back");
    }
    
    function test_closeEpoch_successfulFunding() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 80_000e6);
        
        skipTime(EPOCH_DURATION + 1);
        
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        
        assertTrue(manager.poolStatus(poolAddress) == IPoolTypes.PoolStatus.PENDING_INVESTMENT);
    }
    
    function test_closeEpoch_underfunded_emergency() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 50_000e6);
        
        skipTime(EPOCH_DURATION + 1);
        
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        
        assertTrue(manager.poolStatus(poolAddress) == IPoolTypes.PoolStatus.EMERGENCY);
    }
    
    function test_closeEpoch_earlyClose_onlyFilled() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 50_000e6);
        _depositAs(user2, 50_000e6);
        
        vm.prank(operator);
        manager.handlePoolFilled(poolAddress);
        
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        
        assertTrue(manager.poolStatus(poolAddress) == IPoolTypes.PoolStatus.PENDING_INVESTMENT);
    }
    
    function test_spvInvestment_fullFlow() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 100_000e6);
        
        skipTime(EPOCH_DURATION + 1);
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        
        vm.prank(spv);
        manager.withdrawFundsForInvestment(poolAddress, 100_000e6);
        
        assertEq(token.balanceOf(spv), INITIAL_BALANCE * 10 + 100_000e6, "SPV should receive funds");
        
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
        
        vm.prank(spv);
        manager.withdrawFundsForInvestment(poolAddress, 80_000e6);
        
        vm.prank(spv);
        manager.processInvestment(poolAddress, 80_000e6, "ipfs://proof123");
        
        assertEq(manager.poolActualInvested(poolAddress), 80_000e6);
    }
    

    /// @dev Interest-bearing variant with a single coupon 30 days out.
    function _createInterestBearingPool() internal returns (address, address, uint256) {
        uint256[] memory dates = new uint256[](1);
        uint256[] memory rates = new uint256[](1);
        dates[0] = block.timestamp + 30 days;
        rates[0] = 200; // 2% of principal

        IPoolFactory.PoolConfig memory config = IPoolFactory.PoolConfig({
            asset: address(token),
            instrumentType: IPoolTypes.InstrumentType.INTEREST_BEARING,
            instrumentName: "Test Coupon Pool",
            targetRaise: TARGET_RAISE,
            epochDuration: EPOCH_DURATION,
            maturityDate: block.timestamp + MATURITY_DURATION,
            discountRate: 0,
            spvAddress: spv,
            couponDates: dates,
            couponRates: rates,
            minimumFundingThreshold: 8000,
            minInvestment: MIN_INVESTMENT,
            withdrawalFeeBps: 100
        });

        vm.prank(admin);
        (address pool, address escrow) = factory.createPool(config);
        return (pool, escrow, dates[0]);
    }

    /// @dev Funds, closes, and deploys a discounted pool with `raised` from user1.
    function _fundAndInvest(uint256 raised) internal {
        _depositAs(user1, raised);
        skipTime(EPOCH_DURATION + 1);
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        vm.prank(spv);
        manager.withdrawFundsForInvestment(poolAddress, raised);
        vm.prank(spv);
        manager.processInvestment(poolAddress, raised, "ipfs://proof");
    }

    function _settle(uint256 amount) internal {
        vm.startPrank(spv);
        token.approve(address(manager), amount);
        manager.processMaturity(poolAddress, amount);
        vm.stopPrank();
    }

    // ==================== REDEMPTION PAYS FROM ACTUALS ====================

    /// @dev A pool that settles short pays out what came back, not what was promised.
    ///
    ///      Before this fix the pot was `actualInvested + totalDiscountEarned` — the
    ///      projection fixed at investment time — so a short settlement still tried to
    ///      release full face value and the escrow refused. The holder could not exit at
    ///      all.
    function test_maturity_shortSettlement_paysFromActuals() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundAndInvest(100_000e6);

        uint256 faceValue = (uint256(100_000e6) * 10000) / (10000 - 500);
        skipTime(MATURITY_DURATION);

        // The SPV returns less than it promised.
        uint256 recovered = 95_000e6;
        assertLt(recovered, faceValue, "test should model a shortfall");
        _settle(recovered);

        uint256 balanceBefore = token.balanceOf(user1);
        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.prank(user1);
        LiquidityPool(poolAddress).withdraw(100_000e6, user1, user1);

        // Sole holder takes the whole recovery, less the 1% withdrawal fee.
        uint256 fee = (recovered * 100) / 10000;
        assertEq(token.balanceOf(user1) - balanceBefore, recovered - fee, "holder paid from actuals");
        assertEq(token.balanceOf(treasury) - treasuryBefore, fee, "fee taken from actuals");
        assertEq(token.balanceOf(escrowAddress), 0, "escrow fully distributed, nothing stranded");
    }

    /// @dev And a pool that settles over hands the upside to holders.
    function test_maturity_overSettlement_passesUpsideToHolders() public {
        (poolAddress, escrowAddress) = _createPool();
        _fundAndInvest(100_000e6);

        uint256 faceValue = (uint256(100_000e6) * 10000) / (10000 - 500);
        skipTime(MATURITY_DURATION);

        uint256 recovered = 110_000e6;
        assertGt(recovered, faceValue, "test should model an overage");
        _settle(recovered);

        uint256 balanceBefore = token.balanceOf(user1);
        vm.prank(user1);
        LiquidityPool(poolAddress).withdraw(100_000e6, user1, user1);

        uint256 fee = (recovered * 100) / 10000;
        assertEq(token.balanceOf(user1) - balanceBefore, recovered - fee, "holder receives the overage");
    }

    /// @dev A coupon that has already been distributed and claimed is not paid again at
    ///      redemption.
    ///
    ///      Before this fix the pot counted `totalCouponsReceived` in full, including
    ///      coupons that had already left the escrow via claimUserCoupon.
    function test_maturity_claimedCouponIsNotPaidTwice() public {
        uint256 couponDate;
        (poolAddress, escrowAddress, couponDate) = _createInterestBearingPool();
        _fundAndInvest(100_000e6);

        // The SPV pays its coupon, the operator releases it, the holder takes it.
        vm.warp(couponDate);
        uint256 coupon = 2_000e6;
        vm.startPrank(spv);
        token.approve(address(manager), coupon);
        manager.processCouponPayment(poolAddress, coupon);
        vm.stopPrank();

        vm.prank(operator);
        manager.distributeCouponPayment(poolAddress);

        uint256 beforeClaim = token.balanceOf(user1);
        vm.prank(user1);
        LiquidityPool(poolAddress).claimCoupon();
        assertEq(token.balanceOf(user1) - beforeClaim, coupon, "coupon claimed and out of escrow");

        // At maturity the SPV returns principal only.
        skipTime(MATURITY_DURATION);
        _settle(100_000e6);

        uint256 balanceBefore = token.balanceOf(user1);
        vm.prank(user1);
        LiquidityPool(poolAddress).withdraw(100_000e6, user1, user1);

        // Principal less the fee — the already-claimed coupon is not in the pot.
        uint256 fee = (uint256(100_000e6) * 100) / 10000;
        assertEq(token.balanceOf(user1) - balanceBefore, 100_000e6 - fee, "coupon not paid twice");
        assertEq(token.balanceOf(escrowAddress), 0, "escrow fully distributed");
    }

    /// @dev Characterisation, not an endorsement: with more than one holder a short
    ///      settlement still strands the last one out.
    ///
    ///      This is a separate defect from the one fixed here. `_handleMaturedWithdrawWithFee`
    ///      divides the pot by the *live* `totalSupply()`, which falls as shares burn, so
    ///      each successive redeemer is entitled to a larger fraction of an unchanged pot.
    ///      This test locks in the current behaviour; it should be inverted when that is
    ///      fixed.
    function test_maturity_multipleHolders_stillRacesOnTheLiveDivisor() public {
        (poolAddress, escrowAddress) = _createPool();

        _depositAs(user1, 60_000e6);
        _depositAs(user2, 40_000e6);
        skipTime(EPOCH_DURATION + 1);
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        vm.prank(spv);
        manager.withdrawFundsForInvestment(poolAddress, 100_000e6);
        vm.prank(spv);
        manager.processInvestment(poolAddress, 100_000e6, "ipfs://proof");

        skipTime(MATURITY_DURATION);
        _settle(95_000e6);

        // First out is paid correctly: 60% of the recovery.
        uint256 before1 = token.balanceOf(user1);
        vm.prank(user1);
        LiquidityPool(poolAddress).withdraw(60_000e6, user1, user1);
        uint256 expected1 = (uint256(60_000e6) * 95_000e6) / 100_000e6;
        uint256 fee1 = (expected1 * 100) / 10000;
        assertEq(token.balanceOf(user1) - before1, expected1 - fee1, "first holder pro-rata");

        // Second is computed against a supply that has already shrunk, so the escrow
        // cannot cover it.
        vm.prank(user2);
        vm.expectRevert("PoolEscrow/insufficient-balance");
        LiquidityPool(poolAddress).withdraw(40_000e6, user2, user2);
    }

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
        
        skipTime(MATURITY_DURATION);
        
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
        
        uint256 balanceBefore = token.balanceOf(user1);
        
        vm.prank(user1);
        LiquidityPool(poolAddress).withdraw(100_000e6, user1, user1);
        
        uint256 received = token.balanceOf(user1) - balanceBefore;
        assertTrue(received > 0, "Should receive tokens");
    }
    
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
        
        uint256 balanceBefore = token.balanceOf(user1);
        
        vm.prank(user1);
        LiquidityPool(poolAddress).withdraw(50_000e6, user1, user1);
        
        assertTrue(token.balanceOf(user1) > balanceBefore, "Should get refund in emergency");
    }
    
    function test_interestBearing_couponPayment() public {
        uint256[] memory couponDates = new uint256[](2);
        couponDates[0] = block.timestamp + 30 days;
        couponDates[1] = block.timestamp + 60 days;
        
        uint256[] memory couponRates = new uint256[](2);
        couponRates[0] = 200;
        couponRates[1] = 200;
        
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
        
        skipTime(30 days);
        
        uint256 couponAmount = (100_000e6 * 200) / 10000;
        
        vm.startPrank(spv);
        token.approve(address(manager), couponAmount);
        manager.processCouponPayment(poolAddress, couponAmount);
        vm.stopPrank();
        
        assertEq(manager.poolTotalCouponsReceived(poolAddress), couponAmount);
    }
    
    function test_edgeCase_exactMinimumThreshold() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 80_000e6);
        
        skipTime(EPOCH_DURATION + 1);
        
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        
        assertTrue(manager.poolStatus(poolAddress) == IPoolTypes.PoolStatus.PENDING_INVESTMENT);
    }
    
    function test_edgeCase_justBelowThreshold() public {
        (poolAddress, escrowAddress) = _createPool();
        
        _depositAs(user1, 79_999e6);
        
        skipTime(EPOCH_DURATION + 1);
        
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        
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
        
        vm.prank(user1);
        vm.expectRevert();
        LiquidityPool(poolAddress).withdraw(100_000e6, user1, user1);
    }
    
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
