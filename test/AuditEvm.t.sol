// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SingleAssetPool.t.sol";

/// Regression tests for the audit findings on EVM. Each asserts the corrected
/// behaviour, so a failure here means a fix has been undone.
contract AuditEvm is SingleAssetPoolTest {

    uint256 internal c0;
    uint256 internal c1;

    function _interestBearingInvested() internal returns (address, address) {
        uint256[] memory couponDates = new uint256[](2);
        couponDates[0] = block.timestamp + 30 days;
        couponDates[1] = block.timestamp + 60 days;
        c0 = couponDates[0];
        c1 = couponDates[1];
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
        (address pool, address escrow) = factory.createPool(config);
        return (pool, escrow);
    }

    /// C1 on EVM: shares are a plain ERC20 with no transfer hook on LiquidityPool.
    function test_evm_couponCannotBeClaimedTwiceByMovingShares() public {
        (poolAddress, escrowAddress) = _interestBearingInvested();

        _depositAs(user1, 50_000e6);
        _depositAs(user2, 50_000e6);

        skipTime(EPOCH_DURATION + 1);
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        // The SPV places 90,000 and leaves 10,000 of principal in escrow.
        vm.prank(spv);
        manager.withdrawFundsForInvestment(poolAddress, 90_000e6);
        vm.prank(spv);
        manager.processInvestment(poolAddress, 90_000e6, "ipfs://proof");

        vm.warp(c0);

        uint256 coupon = 2_000e6;
        vm.startPrank(spv);
        token.approve(address(manager), coupon);
        manager.processCouponPayment(poolAddress, coupon);
        vm.stopPrank();

        vm.prank(operator);
        manager.distributeCouponPayment(poolAddress);

        uint256 escrowBefore = token.balanceOf(escrowAddress);

        vm.prank(user1);
        uint256 aliceGot = LiquidityPool(poolAddress).claimCoupon();

        // Alice hands her shares to Bob, who is also a holder.
        uint256 aliceShares = LiquidityPool(poolAddress).balanceOf(user1);
        vm.prank(user1);
        LiquidityPool(poolAddress).transfer(user2, aliceShares);

        vm.prank(user2);
        uint256 bobGot = LiquidityPool(poolAddress).claimCoupon();

        uint256 paid = escrowBefore - token.balanceOf(escrowAddress);
        emit log_named_uint("distributed  ", coupon);
        emit log_named_uint("alice claimed", aliceGot);
        emit log_named_uint("bob claimed  ", bobGot);
        emit log_named_uint("escrow paid  ", paid);
        // Alice's half, and Bob's half — not the whole distribution twice.
        assertEq(aliceGot, coupon / 2, "alice's share");
        assertEq(bobGot, coupon / 2, "bob's share, not the whole pot");
        assertEq(paid, coupon, "exactly the distributed coupon left the escrow");
    }

    /// H1 on EVM: does a distributed-but-unclaimed coupon survive settlement?
    function test_evm_unclaimedCouponSurvivesSettlement() public {
        (poolAddress, escrowAddress) = _interestBearingInvested();

        _depositAs(user1, 50_000e6);
        _depositAs(user2, 50_000e6);

        skipTime(EPOCH_DURATION + 1);
        vm.prank(operator);
        manager.closeEpoch(poolAddress);
        vm.prank(spv);
        manager.withdrawFundsForInvestment(poolAddress, 100_000e6);
        vm.prank(spv);
        manager.processInvestment(poolAddress, 100_000e6, "ipfs://proof");

        vm.warp(c0);
        uint256 coupon = 2_000e6;
        vm.startPrank(spv);
        token.approve(address(manager), coupon);
        manager.processCouponPayment(poolAddress, coupon);
        vm.stopPrank();
        vm.prank(operator);
        manager.distributeCouponPayment(poolAddress);

        // Alice claims. Bob does not — he is passive, like most holders.
        vm.prank(user1);
        LiquidityPool(poolAddress).claimCoupon();

        // The deal settles.
        skipTime(MATURITY_DURATION);
        vm.startPrank(spv);
        token.approve(address(manager), 100_000e6);
        manager.processMaturity(poolAddress, 100_000e6);
        vm.stopPrank();

        uint256 bobBefore = token.balanceOf(user2);
        uint256 bobShares = LiquidityPool(poolAddress).balanceOf(user2);
        vm.prank(user2);
        LiquidityPool(poolAddress).withdraw(bobShares, user2, user2);
        uint256 bobGot = token.balanceOf(user2) - bobBefore;

        emit log_named_uint("bob principal ", 50_000e6);
        emit log_named_uint("bob coupon due", coupon / 2);
        emit log_named_uint("bob received  ", bobGot);
        // He should get his principal back plus the 1,000 coupon he never claimed,
        // less the 1% withdrawal fee.
        // Principal share less the 1% fee, plus the 1,000 coupon he never claimed.
        assertEq(bobGot, 49_500e6 + coupon / 2, "bob lost his unclaimed coupon at settlement");
    }

    /// H2. The SPV must account for everything it drew. Confirming less used to leave the
    /// difference with the SPV and unrecorded as owed, with every valuation struck on the
    /// smaller figure.
    function test_evm_spvCannotConfirmLessThanItDrew() public {
        (poolAddress, escrowAddress) = _createPool();
        _depositAs(user1, 100_000e6);

        skipTime(EPOCH_DURATION + 1);
        vm.prank(operator);
        manager.closeEpoch(poolAddress);

        vm.prank(spv);
        manager.withdrawFundsForInvestment(poolAddress, 100_000e6);

        vm.prank(spv);
        vm.expectRevert(bytes("PoolLifecycle/must account for all funds drawn"));
        manager.processInvestment(poolAddress, 60_000e6, "ipfs://proof");

        // Accounting for the whole draw is accepted.
        vm.prank(spv);
        manager.processInvestment(poolAddress, 100_000e6, "ipfs://proof");
    }
}
