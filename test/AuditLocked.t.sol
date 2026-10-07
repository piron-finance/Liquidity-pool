// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./LockedPool.t.sol";

/// Locked-pool regression tests for the audit findings. Each asserts the corrected
/// behaviour, so a failure here means a fix has been undone.
contract AuditLocked is LockedPoolTest {

    /// A position carries the pool it belongs to. `redeem` and `earlyWithdraw` bind only
    /// to the pool that *called* them, so a position opened in one pool can be settled
    /// against another pool's escrow — at that pool's tier terms, and against its metrics.
    ///
    /// Two neighbouring functions (`setAutoRollover`, `transferPositionOwnership`) bind to
    /// `position.poolAddress`, and the read-only `calculateEarlyExitPayout` prices against
    /// `poolTiers[position.poolAddress]`. Only the two money-moving paths use the argument.
    function test_locked_positionCannotBeRedeemedAgainstAnotherPool() public {
        // Pool A: the victim, well funded.
        (address poolA, address escrowA) = _createPool();
        poolAddress = poolA;
        escrowAddress = escrowA;
        _fundEscrow(500_000e6);
        _depositAs(user1, 100_000e6, 0);

        // Pool B: where the attacker's position actually lives.
        (address poolB, address escrowB) = _createPool();
        poolAddress = poolB;
        escrowAddress = escrowB;
        _fundEscrow(10_000e6);
        uint256 positionInB = _depositAs(user2, 50_000e6, 0);

        // The attacker also holds shares in pool A, which is what `redeemPosition` burns.
        poolAddress = poolA;
        escrowAddress = escrowA;
        _depositAs(user2, 50_000e6, 0);

        skipTime(91 days);

        uint256 escrowABefore = token.balanceOf(escrowA);
        uint256 escrowBBefore = token.balanceOf(escrowB);

        // Pool A is asked to settle a position that belongs to pool B.
        vm.prank(user2);
        vm.expectRevert(LockedPoolManager.InvalidPosition.selector);
        LockedPool(poolA).redeemPosition(positionInB);

        // Nothing moved out of either escrow.
        assertEq(token.balanceOf(escrowA), escrowABefore, "pool A paid for pool B");
        assertEq(token.balanceOf(escrowB), escrowBBefore, "pool B was touched");

        // And the position still redeems against its own pool.
        vm.prank(user2);
        LockedPool(poolB).redeemPosition(positionInB);
    }

    /// The same hole on the early-exit path, which additionally prices the foreign
    /// position against the calling pool's tier terms.
    function test_locked_positionCannotBeExitedAgainstAnotherPool() public {
        (address poolA, address escrowA) = _createPool();
        poolAddress = poolA;
        escrowAddress = escrowA;
        _fundEscrow(500_000e6);
        _depositAs(user1, 100_000e6, 0);

        (address poolB, address escrowB) = _createPool();
        poolAddress = poolB;
        escrowAddress = escrowB;
        _fundEscrow(10_000e6);
        uint256 positionInB = _depositAs(user2, 50_000e6, 0);
        assertTrue(escrowB != address(0));

        poolAddress = poolA;
        escrowAddress = escrowA;
        _depositAs(user2, 50_000e6, 0);

        skipTime(30 days);

        uint256 escrowABefore = token.balanceOf(escrowA);
        vm.prank(user2);
        vm.expectRevert(LockedPoolManager.InvalidPosition.selector);
        LockedPool(poolA).earlyExitPosition(positionInB);
        assertEq(token.balanceOf(escrowA), escrowABefore, "pool A funded pool B's exit");

        // The exit still works against its own pool.
        vm.prank(user2);
        LockedPool(poolB).earlyExitPosition(positionInB);
    }
}
