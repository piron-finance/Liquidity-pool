// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StableYieldPool.t.sol";

/// Regression tests for the audit findings. Each asserts the corrected behaviour, so a
/// failure here means a fix has been undone.
contract AuditProbe is StableYieldPoolTest {
    function test_probe_queuedWithdrawalInflatesPriceForEveryoneElse() public {
        (poolAddress, escrowAddress) = _createPool();

        _depositAs(user1, 90_000e6); // alice, the one who queues
        _depositAs(user2, 3_000e6);  // bob, the one who profits
        _depositAs(user3, 7_000e6);  // carol, left holding the loss

        // Most of the cash goes out to the SPV, so a large exit cannot be paid at once.
        vm.prank(operator);
        stableYieldManager.allocateCapital(poolAddress, spv, 50_000e6);

        vm.warp(block.timestamp + 92 days);

        uint256 priceBefore = stableYieldManager.calculateNAVPerShare(poolAddress);
        uint256 bobShares = StableYieldPool(poolAddress).balanceOf(user2);

        // Alice asks to leave. 90,000 against 50,000 of reserves, so it queues — and her
        // shares are burned on the way in regardless.
        uint256 aliceShares = StableYieldPool(poolAddress).balanceOf(user1);
        vm.startPrank(user1);
        StableYieldPool(poolAddress).redeem(aliceShares, user1, user1);
        vm.stopPrank();

        uint256 priceAfter = stableYieldManager.calculateNAVPerShare(poolAddress);
        emit log_named_uint("price before queue", priceBefore);
        emit log_named_uint("price after  queue", priceAfter);

        // Alice's shares are gone and her cash is owed. Both sides of the fraction move
        // by the same amount, so nobody else's share changes value.
        //
        // Approximate rather than exact: the quote is struck with integer division, so
        // NAV and supply cannot cancel to the last wei. The tolerance is 1e-9 relative —
        // the defect this replaces moved the price by 10.56x.
        assertApproxEqRel(priceAfter, priceBefore, 1e9, "queueing an exit repriced the pool");

        // And Bob cannot be paid at once while Alice is waiting, however much free cash
        // there is: his request joins the queue behind hers.
        uint256 bobBefore = token.balanceOf(user2);
        vm.startPrank(user2);
        StableYieldPool(poolAddress).redeem(bobShares, user2, user2);
        vm.stopPrank();
        uint256 bobGot = token.balanceOf(user2) - bobBefore;

        emit log_named_uint("bob deposited", 3_000e6);
        emit log_named_uint("bob received ", bobGot);
        assertEq(bobGot, 0, "bob was paid ahead of alice, out of the cash owed to her");
    }

    /// M5. The queue is served from the head. Serving an arbitrary selection would let an
    /// operator choose who gets paid, which is what the ordering rule exists to prevent.
    function test_probe_queueCannotBeServedOutOfOrder() public {
        (poolAddress, escrowAddress) = _createPool();

        _depositAs(user1, 60_000e6);
        _depositAs(user2, 40_000e6);
        vm.prank(operator);
        stableYieldManager.allocateCapital(poolAddress, spv, 70_000e6);
        vm.warp(block.timestamp + 92 days);

        // Two requests queue, in order.
        uint256 aliceShares = StableYieldPool(poolAddress).balanceOf(user1);
        vm.prank(user1);
        StableYieldPool(poolAddress).redeem(aliceShares, user1, user1);

        uint256 bobShares = StableYieldPool(poolAddress).balanceOf(user2);
        vm.prank(user2);
        StableYieldPool(poolAddress).redeem(bobShares, user2, user2);

        // The SPV returns capital so the head can actually be paid; the point of this
        // test is the ordering rule, not liquidity.
        vm.startPrank(spv);
        token.approve(address(stableYieldManager), 70_000e6);
        stableYieldManager.returnCapital(poolAddress, 70_000e6);
        vm.stopPrank();

        // Serving Bob's request (id 1) before Alice's (id 0) is refused.
        uint256[] memory jumpTheQueue = new uint256[](1);
        jumpTheQueue[0] = 1;
        vm.prank(operator);
        vm.expectRevert(bytes("StableYieldLib/out of order"));
        stableYieldManager.settleWithdrawals(poolAddress, jumpTheQueue);

        // From the head is accepted.
        uint256[] memory fromHead = new uint256[](1);
        fromHead[0] = 0;
        vm.prank(operator);
        stableYieldManager.settleWithdrawals(poolAddress, fromHead);
    }

    /// M3. An interest-bearing instrument bought below par accretes the discount over the
    /// holding period rather than booking it the moment it is recorded.
    ///
    /// Marked straight at face, an SPV lifted NAV simply by buying cheaply — and the gain
    /// was unearned until the bond redeemed, so a default beforehand read as a fall from a
    /// level the pool never held. The existing interest-bearing coverage buys at par, where
    /// both behaviours agree, so this exercises the case that tells them apart.
    function test_probe_interestBearingBoughtBelowParAccretesTheDiscount() public {
        (poolAddress, escrowAddress) = _createPool();
        _depositAs(user1, 200_000e6);
        vm.warp(block.timestamp + 92 days);

        uint256 navBefore = stableYieldManager.calculatePoolNAV(poolAddress);

        vm.prank(operator);
        stableYieldManager.allocateCapital(poolAddress, spv, 90_000e6);

        // 90,000 paid for something redeeming at 100,000 in a year.
        vm.prank(spv);
        stableYieldManager.addInstrument(
            poolAddress,
            IStableYieldTypes.InstrumentType.INTEREST_BEARING,
            90_000e6,
            100_000e6,
            block.timestamp + 365 days,
            800,
            4
        );

        // Recording the purchase moves cash into a holding; it does not create value.
        assertEq(
            stableYieldManager.calculatePoolNAV(poolAddress),
            navBefore,
            "buying below par booked the discount immediately"
        );

        // A year on, the capital leg has reached face and stops there.
        vm.warp(block.timestamp + 365 days);
        uint256 navAtMaturity = stableYieldManager.calculatePoolNAV(poolAddress);
        assertGt(navAtMaturity, navBefore, "the discount never accreted");

        vm.warp(block.timestamp + 365 days);
        assertEq(
            stableYieldManager.calculatePoolNAV(poolAddress),
            navAtMaturity,
            "value kept climbing past maturity"
        );
    }

    /// A deposit is priced at the share price that stood before it, so it cannot move
    /// that price. Priced after the deposit is credited, the new shares are valued as if
    /// the depositor's own money were already the pool's, and the difference passes to
    /// the holders who were there first.
    function test_probe_depositDoesNotMoveSharePrice() public {
        (poolAddress, escrowAddress) = _createPool();

        _depositAs(user1, 100_000e6);
        uint256 priceBefore = StableYieldPool(poolAddress).getNAVPerShare();
        _depositAs(user2, 300_000e6);

        assertApproxEqRel(StableYieldPool(poolAddress).getNAVPerShare(), priceBefore, 0.0001e18, "a deposit moved the share price");
    }

    /// Equal deposits into an idle pool receive equal shares, whatever order they arrive in.
    function test_probe_equalDepositsGetEqualShares() public {
        (poolAddress, escrowAddress) = _createPool();

        _depositAs(user1, 100_000e6);
        _depositAs(user2, 100_000e6);

        assertEq(
            StableYieldPool(poolAddress).balanceOf(user2),
            StableYieldPool(poolAddress).balanceOf(user1),
            "equal deposits, unequal shares"
        );
    }

    /// Straight after depositing, a holder's shares are worth what they paid in less the
    /// entry fee. A large deposit into a small pool is the case that lost the most.
    function test_probe_depositorKeepsWhatTheyPutIn() public {
        (poolAddress, escrowAddress) = _createPool();

        _depositAs(user1, 50_000e6);
        _depositAs(user2, 280_000e6);

        StableYieldPool pool = StableYieldPool(poolAddress);
        uint256 worth = (pool.balanceOf(user2) * pool.getNAVPerShare()) / 1e18;
        uint256 paidIn = 280_000e6 - (280_000e6 * DEFAULT_FEE_BPS) / 10_000;
        assertApproxEqRel(worth, paidIn, 0.0001e18, "the depositor lost money by depositing");
    }

    /// Settling moves the head past what it paid. Left behind, the next request could only
    /// be settled by listing the paid ones again, and the pending count kept counting them.
    function test_probe_settlingAdvancesTheQueueHead() public {
        (poolAddress, escrowAddress) = _createPool();

        _depositAs(user1, 60_000e6);
        _depositAs(user2, 40_000e6);
        vm.prank(operator);
        stableYieldManager.allocateCapital(poolAddress, spv, 70_000e6);
        vm.warp(block.timestamp + 92 days);

        uint256 aliceShares = StableYieldPool(poolAddress).balanceOf(user1);
        vm.prank(user1);
        StableYieldPool(poolAddress).redeem(aliceShares, user1, user1);
        uint256 bobShares = StableYieldPool(poolAddress).balanceOf(user2);
        vm.prank(user2);
        StableYieldPool(poolAddress).redeem(bobShares, user2, user2);

        vm.startPrank(spv);
        token.approve(address(stableYieldManager), 70_000e6);
        stableYieldManager.returnCapital(poolAddress, 70_000e6);
        vm.stopPrank();

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        vm.prank(operator);
        stableYieldManager.settleWithdrawals(poolAddress, ids);

        (uint256 head, uint256 tail, uint256 pending,) = stableYieldManager.getWithdrawalQueueStatus(poolAddress);
        assertEq(head, 1, "request 0 is paid but the head still points at it");
        assertEq(pending, tail - 1, "a paid request is still counted as pending");

        // The next in line is now the head, and is settled on its own.
        ids[0] = 1;
        vm.prank(operator);
        stableYieldManager.settleWithdrawals(poolAddress, ids);

        (head,, pending,) = stableYieldManager.getWithdrawalQueueStatus(poolAddress);
        assertEq(head, 2);
        assertEq(pending, 0);
    }
}
