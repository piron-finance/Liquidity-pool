// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../LockedPool.t.sol";

/// Drives a locked pool through random sequences of the actions a real pool sees, so the
/// invariants below are checked against orderings nobody thought to write a test for.
///
/// The handler deliberately swallows reverts: a rejected action is a guard doing its job,
/// and the run should carry on exploring rather than stop. What must never happen is an
/// action *succeeding* and leaving the accounting broken.
contract LockedHandler is Test {
    LockedPool public pool;
    LockedPoolEscrow public escrow;
    LockedPoolManager public manager;
    MockERC20 public token;
    address public spv;
    address public admin;

    address[] public actors;
    uint256[] public positionIds;

    uint256 public depositedIn;
    uint256 public paidOut;
    uint256 public fundedIn;

    constructor(
        LockedPool pool_,
        LockedPoolEscrow escrow_,
        LockedPoolManager manager_,
        MockERC20 token_,
        address spv_,
        address admin_,
        address[] memory actors_
    ) {
        pool = pool_;
        escrow = escrow_;
        manager = manager_;
        token = token_;
        spv = spv_;
        admin = admin_;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 actorSeed, uint256 amount, uint256 tierSeed, bool upfront) external {
        address who = _actor(actorSeed);
        amount = bound(amount, 1_000e6, 50_000e6);
        uint8 tier = uint8(tierSeed % 3);

        token.mint(who, amount);
        vm.startPrank(who);
        token.approve(address(pool), amount);
        try pool.depositLocked(
            amount,
            tier,
            upfront
                ? ILockedPoolTypes.InterestPayment.UPFRONT
                : ILockedPoolTypes.InterestPayment.AT_MATURITY
        ) returns (uint256 id, uint256) {
            positionIds.push(id);
            depositedIn += amount;
        } catch {}
        vm.stopPrank();
    }

    function redeem(uint256 idSeed) external {
        if (positionIds.length == 0) return;
        uint256 id = positionIds[idSeed % positionIds.length];
        ILockedPoolTypes.UserPosition memory p = manager.getPosition(id);

        uint256 before = token.balanceOf(p.user);
        vm.prank(p.user);
        try pool.redeemPosition(id) {
            paidOut += token.balanceOf(p.user) - before;
        } catch {}
    }

    function exitEarly(uint256 idSeed) external {
        if (positionIds.length == 0) return;
        uint256 id = positionIds[idSeed % positionIds.length];
        ILockedPoolTypes.UserPosition memory p = manager.getPosition(id);

        uint256 before = token.balanceOf(p.user);
        vm.prank(p.user);
        try pool.earlyExitPosition(id) {
            paidOut += token.balanceOf(p.user) - before;
        } catch {}
    }

    /// Protocol capital, which is what funds the interest a locked pool promises.
    function fundProtocolCapital(uint256 amount) external {
        amount = bound(amount, 1_000e6, 100_000e6);
        token.mint(admin, amount);
        vm.startPrank(admin);
        token.approve(address(escrow), amount);
        try escrow.receiveProtocolFundsFromAdmin(amount) {
            fundedIn += amount;
        } catch {}
        vm.stopPrank();
    }

    function warp(uint256 days_) external {
        vm.warp(block.timestamp + bound(days_, 1, 120) * 1 days);
    }

    function positionCount() external view returns (uint256) {
        return positionIds.length;
    }

    function positionAt(uint256 i) external view returns (uint256) {
        return positionIds[i];
    }
}

contract LockedPoolInvariants is LockedPoolTest {
    LockedHandler internal handler;

    function setUp() public override {
        super.setUp();
        (poolAddress, escrowAddress) = _createPool();

        address[] memory actors = new address[](3);
        actors[0] = user1;
        actors[1] = user2;
        actors[2] = user3;

        handler = new LockedHandler(
            LockedPool(poolAddress),
            LockedPoolEscrow(escrowAddress),
            lockedPoolManager,
            token,
            spv,
            admin,
            actors
        );

        targetContract(address(handler));
    }

    /// The escrow's tracked balances are claims on real tokens. If they ever exceed what
    /// it holds, some holder's position is unbacked and whoever withdraws last finds
    /// nothing — the failure mode an escrow exists to prevent.
    function invariant_escrowIsSolventAgainstItsOwnBooks() public view {
        LockedPoolEscrow e = LockedPoolEscrow(escrowAddress);
        uint256 tracked = e.principalHeld()
            + e.protocolFundsFromReserve()
            + e.protocolFundsDirectDeposit();
        assertGe(
            token.balanceOf(escrowAddress),
            tracked,
            "escrow owes more than it holds"
        );
    }

    /// Nothing leaves the escrow that did not first arrive. Deposits and protocol capital
    /// are the only inflows the handler drives, so payouts can never exceed their sum.
    function invariant_noValueIsCreated() public view {
        assertLe(
            handler.paidOut(),
            handler.depositedIn() + handler.fundedIn(),
            "paid out more than was ever put in"
        );
    }

    /// Every position belongs to exactly one pool, and that pool is the one it was opened
    /// against. This is the invariant the cross-pool settlement defect broke.
    function invariant_everyPositionBelongsToThisPool() public view {
        uint256 n = handler.positionCount();
        for (uint256 i = 0; i < n; i++) {
            ILockedPoolTypes.UserPosition memory p =
                lockedPoolManager.getPosition(handler.positionAt(i));
            assertEq(p.poolAddress, poolAddress, "position escaped its pool");
        }
    }

    /// A position settles once. Whichever way it leaves — matured or early — it must end
    /// in a terminal state with a payout recorded, never back to ACTIVE.
    function invariant_settledPositionsStaySettled() public view {
        uint256 n = handler.positionCount();
        for (uint256 i = 0; i < n; i++) {
            ILockedPoolTypes.UserPosition memory p =
                lockedPoolManager.getPosition(handler.positionAt(i));
            if (
                p.status == ILockedPoolTypes.PositionStatus.REDEEMED ||
                p.status == ILockedPoolTypes.PositionStatus.EARLY_EXIT
            ) {
                assertGt(p.actualPayout, 0, "a settled position recorded no payout");
            }
        }
    }

    /// The pool's own count of live positions must match what the positions say. A drifted
    /// counter is what the SPV sizes deployments against.
    function invariant_activeCountMatchesThePositions() public view {
        uint256 n = handler.positionCount();
        uint256 live;
        for (uint256 i = 0; i < n; i++) {
            ILockedPoolTypes.UserPosition memory p =
                lockedPoolManager.getPosition(handler.positionAt(i));
            if (
                p.status == ILockedPoolTypes.PositionStatus.ACTIVE ||
                p.status == ILockedPoolTypes.PositionStatus.MATURED
            ) {
                live++;
            }
        }
        assertEq(
            lockedPoolManager.getPoolMetrics(poolAddress).activePositions,
            live,
            "activePositions drifted from the positions themselves"
        );
    }
}
