// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../StableYieldPool.t.sol";

/// Drives a stable-yield pool through random sequences of everything it actually does:
/// holders arriving and leaving, the SPV drawing and returning capital, instruments
/// bought, settled and written off, and time passing while all of it accrues.
///
/// Reverts are swallowed — a rejected action is a guard working, and the run should keep
/// exploring. What must never happen is an action *succeeding* and leaving the pool
/// mispriced or short.
contract StableYieldHandler is Test {
    StableYieldPool public pool;
    StableYieldEscrow public escrow;
    StableYieldManager public manager;
    MockERC20 public token;
    address public operator;
    address public spv;
    address public poolAddr;

    address[] public actors;

    uint256 public depositedIn;
    uint256 public paidOut;
    uint256 public returnedBySpv;
    uint256 public drawnBySpv;

    constructor(
        StableYieldPool pool_,
        StableYieldEscrow escrow_,
        StableYieldManager manager_,
        MockERC20 token_,
        address operator_,
        address spv_,
        address[] memory actors_
    ) {
        pool = pool_;
        escrow = escrow_;
        manager = manager_;
        token = token_;
        operator = operator_;
        spv = spv_;
        poolAddr = address(pool_);
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address who = _actor(actorSeed);
        amount = bound(amount, 1_000e6, 100_000e6);
        token.mint(who, amount);
        vm.startPrank(who);
        token.approve(poolAddr, amount);
        try pool.deposit(amount, who) {
            depositedIn += amount;
        } catch {}
        vm.stopPrank();
    }

    function redeem(uint256 actorSeed, uint256 shares) external {
        address who = _actor(actorSeed);
        uint256 held = pool.balanceOf(who);
        if (held == 0) return;
        shares = bound(shares, 1, held);

        uint256 before = token.balanceOf(who);
        vm.prank(who);
        try pool.redeem(shares, who, who) {
            paidOut += token.balanceOf(who) - before;
        } catch {}
    }

    function processQueue(uint256 maxRequests) external {
        maxRequests = bound(maxRequests, 1, 10);
        vm.prank(operator);
        try manager.processWithdrawalQueue(poolAddr, maxRequests) {} catch {}
    }

    function allocateToSpv(uint256 amount) external {
        amount = bound(amount, 1_000e6, 200_000e6);
        vm.prank(operator);
        try manager.allocateCapital(poolAddr, spv, amount) {
            drawnBySpv += amount;
        } catch {}
    }

    function returnFromSpv(uint256 amount) external {
        amount = bound(amount, 1_000e6, 200_000e6);
        token.mint(spv, amount);
        vm.startPrank(spv);
        token.approve(address(manager), amount);
        try manager.returnCapital(poolAddr, amount) {
            returnedBySpv += amount;
        } catch {}
        vm.stopPrank();
    }

    function buyInstrument(uint256 price, uint256 premiumBps, uint256 days_) external {
        price = bound(price, 1_000e6, 100_000e6);
        premiumBps = bound(premiumBps, 1, 2_000);
        days_ = bound(days_, 1, 365);
        uint256 face = price + (price * premiumBps) / 10_000;

        vm.prank(spv);
        try manager.addInstrument(
            poolAddr,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            price,
            face,
            block.timestamp + days_ * 1 days,
            0,
            0
        ) {} catch {}
    }

    function settleInstrument(uint256 index, uint256 proceedsBps) external {
        IStableYieldTypes.InstrumentHolding[] memory held = manager.getPoolInstruments(poolAddr);
        if (held.length == 0) return;
        index = index % held.length;

        // Anywhere from a loss to a gain: a pool must stay consistent either way.
        proceedsBps = bound(proceedsBps, 5_000, 12_000);
        uint256 proceeds = (held[index].faceValue * proceedsBps) / 10_000;

        // Settlement is refused before maturity, so reach it — otherwise this action only
        // ever exercises the rejection and the settled paths go untested.
        if (block.timestamp < held[index].maturityDate) {
            vm.warp(held[index].maturityDate);
        }

        token.mint(spv, proceeds);
        vm.startPrank(spv);
        token.approve(address(manager), proceeds);
        try manager.matureInstrumentWithFunds(poolAddr, index, proceeds) {
            returnedBySpv += proceeds;
        } catch {}
        vm.stopPrank();
    }

    function writeOffInstrument(uint256 index) external {
        IStableYieldTypes.InstrumentHolding[] memory held = manager.getPoolInstruments(poolAddr);
        if (held.length == 0) return;
        index = index % held.length;
        vm.prank(admin());
        try manager.writeOffInstrument(poolAddr, index, "written off by the fuzzer") {} catch {}
    }

    function warp(uint256 days_) external {
        vm.warp(block.timestamp + bound(days_, 1, 60) * 1 days);
    }

    /// The write-off path is admin-gated; the handler needs that address.
    function admin() public view returns (address) {
        return actors[actors.length - 1];
    }
}

contract StableYieldInvariants is StableYieldPoolTest {
    StableYieldHandler internal handler;

    function setUp() public virtual override {
        super.setUp();
        (poolAddress, escrowAddress) = _createPool();

        address[] memory actors = new address[](4);
        actors[0] = user1;
        actors[1] = user2;
        actors[2] = user3;
        actors[3] = admin; // last slot is the write-off authority

        handler = new StableYieldHandler(
            StableYieldPool(poolAddress),
            StableYieldEscrow(escrowAddress),
            stableYieldManager,
            token,
            operator,
            spv,
            actors
        );

        targetContract(address(handler));
    }

    /// NAV can never claim more than the pool's holdings could possibly return: cash on
    /// hand, capital out with the SPV, and every live instrument at its face value.
    ///
    /// Asserted on NAV alone, not on `NAV + pending`. The earlier formulation added the
    /// queue liability back to recover the gross figure, on the reasoning that NAV is
    /// `gross - owed`. It is not, quite — `calculatePoolNAV` clamps:
    ///
    ///     return gross > owed ? gross - owed : 0;
    ///
    /// So once the queue is owed more than the pool holds, NAV is zero and `NAV + pending`
    /// is just `pending`, which has no reason to respect this bound. The fuzzer found
    /// exactly that state at depth 64 and the bound was wrong, not the contract. NAV on its
    /// own is below the gross figure in both branches, which is what makes this sound.
    function invariant_navNeverExceedsWhatTheHoldingsCouldReturn() public view {
        IStableYieldTypes.InstrumentHolding[] memory held =
            stableYieldManager.getPoolInstruments(poolAddress);

        uint256 bestCase = StableYieldEscrow(escrowAddress).getPoolReserves()
            + stableYieldManager.poolUndeployedCapital(poolAddress);
        for (uint256 i = 0; i < held.length; i++) {
            if (held[i].isActive) bestCase += held[i].faceValue;
        }

        assertLe(
            stableYieldManager.calculatePoolNAV(poolAddress),
            bestCase,
            "NAV claims more than the holdings could ever return"
        );
    }

    /// A pool can end up owing the queue more than it is worth: quotes are struck when a
    /// request is made, and the pool's value can fall afterwards through a write-off or a
    /// settlement below the mark. When that happens NAV must read zero rather than wrap,
    /// and the queue must simply stop paying — which is what the fuzzer drove it into.
    function invariant_aPoolOwingMoreThanItHoldsPricesAtZero() public view {
        (, , , uint256 pending) = stableYieldManager.getWithdrawalQueueStatus(poolAddress);
        uint256 nav = stableYieldManager.calculatePoolNAV(poolAddress);

        IStableYieldTypes.InstrumentHolding[] memory held =
            stableYieldManager.getPoolInstruments(poolAddress);
        uint256 holdings = StableYieldEscrow(escrowAddress).getPoolReserves()
            + stableYieldManager.poolUndeployedCapital(poolAddress);
        for (uint256 i = 0; i < held.length; i++) {
            if (held[i].isActive) holdings += held[i].purchasePrice;
        }

        // If the liability exceeds even the most generous reading of what is held, the only
        // sound answer is zero — never a wrapped enormous number.
        if (pending > holdings + _faceUplift(held)) {
            assertEq(nav, 0, "a pool owing more than it holds reported a positive NAV");
        }
    }

    function _faceUplift(IStableYieldTypes.InstrumentHolding[] memory held)
        internal
        pure
        returns (uint256 uplift)
    {
        for (uint256 i = 0; i < held.length; i++) {
            if (held[i].isActive) uplift += held[i].faceValue - held[i].purchasePrice;
        }
    }

    /// Every holder's claim, added up, must fit inside NAV. This is the whole of solvency
    /// per share: if the sum exceeds NAV then somebody's redemption is funded by somebody
    /// else's, and the last one out finds nothing.
    function invariant_allClaimsTogetherFitInsideNav() public view {
        uint256 supply = StableYieldPool(poolAddress).totalSupply();
        if (supply == 0) return;

        uint256 claims = (supply * stableYieldManager.calculateNAVPerShare(poolAddress)) / 1e18;
        uint256 nav = stableYieldManager.calculatePoolNAV(poolAddress);

        // One unit of slack for the truncation in NAV-per-share, which rounds down and so
        // can only ever understate a claim.
        assertLe(claims, nav + 1, "holders together claim more than the pool is worth");
    }

    /// Cash standing against queued exits is already spoken for. If the SPV could draw it,
    /// the pool would be unable to pay requests it has already priced and burned for.
    function invariant_queuedCashIsNotDeployable() public view {
        (, , , uint256 pending) = stableYieldManager.getWithdrawalQueueStatus(poolAddress);
        (, uint256 deployable) = stableYieldManager.isReadyForAllocation(poolAddress);
        uint256 reserves = StableYieldEscrow(escrowAddress).getPoolReserves();

        if (reserves >= pending) {
            assertLe(deployable, reserves - pending, "the SPV could draw cash owed to the queue");
        } else {
            assertEq(deployable, 0, "deployable while the escrow cannot even cover the queue");
        }
    }

    /// The escrow's tracked reserves are a claim on real tokens. Tracking more than it
    /// holds means somebody's redemption is unbacked.
    function invariant_escrowHoldsWhatItClaims() public view {
        assertGe(
            token.balanceOf(escrowAddress),
            StableYieldEscrow(escrowAddress).getPoolReserves(),
            "escrow claims more than it holds"
        );
    }

    /// Nothing leaves that did not arrive. Deposits and SPV returns are the only inflows
    /// the handler drives.
    function invariant_noValueIsCreated() public view {
        assertLe(
            handler.paidOut(),
            handler.depositedIn() + handler.returnedBySpv(),
            "paid out more than was ever put in"
        );
    }

    /// A share is a claim on NAV. If the supply outruns it the pool is insolvent per share,
    /// and an empty pool must price at exactly one rather than divide by zero.
    function invariant_pricePerShareStaysSane() public view {
        uint256 supply = StableYieldPool(poolAddress).totalSupply();
        uint256 price = stableYieldManager.calculateNAVPerShare(poolAddress);
        uint256 nav = stableYieldManager.calculatePoolNAV(poolAddress);

        if (supply == 0) {
            assertEq(price, 1e18, "an empty pool did not price at par");
        } else if (nav > 0) {
            assertGt(price, 0, "a pool with value priced its shares at nothing");
        }
        // nav == 0 with shares still outstanding is reachable and not asserted away: the
        // queue's quotes are fixed when requested and paid in full when served, so a fall
        // in value between those two moments is borne entirely by the holders who stayed.
        // That makes a queued exit senior to a remaining holder. It is the behaviour as
        // built and it matches the reference implementation — but it is a seniority
        // decision rather than an accident, so it is recorded in SOLIDITY_FINDINGS.md
        // rather than quietly pinned by a test.
    }

    /// Replays the exact counterexample the fuzzer found for
    /// `invariant_navNeverExceedsWhatTheHoldingsCouldReturn`, before the handler was changed
    /// to warp to maturity before settling.
///
    /// `bound` is a pure function of its arguments, so feeding the handler the raw values from
    /// the saved failure reproduces that state deterministically — which is the only way to
    /// tell a real violation from a bound of mine that was never sound. A later green campaign
    /// proves nothing about a counterexample a different seed already found.
    function test_replaysTheNavCounterexample() public {
        handler.deposit(23716, 313885514);
        handler.allocateToSpv(576418438610817853256);
        handler.warp(3107982121641296174468877861704);
        handler.redeem(
            2585016446132045238860070344469645864,
            12959170328215204113019360748920794454612233104509558977504079731852
        );
        handler.redeem(1920, 363872176849749236873409492245005140398199957685308718);
        handler.buyInstrument(12646405329, 911, 1444098643138086211093433789128);
        handler.writeOffInstrument(2590);

        (, , , uint256 pending) = stableYieldManager.getWithdrawalQueueStatus(poolAddress);
        IStableYieldTypes.InstrumentHolding[] memory held =
            stableYieldManager.getPoolInstruments(poolAddress);

        uint256 reserves = StableYieldEscrow(escrowAddress).getPoolReserves();
        uint256 undeployed = stableYieldManager.poolUndeployedCapital(poolAddress);
        uint256 faces;
        for (uint256 i = 0; i < held.length; i++) {
            if (held[i].isActive) faces += held[i].faceValue;
        }
        uint256 nav = stableYieldManager.calculatePoolNAV(poolAddress);

        emit log_named_uint("nav", nav);
        emit log_named_uint("pending", pending);
        emit log_named_uint("reserves", reserves);
        emit log_named_uint("undeployed", undeployed);
        emit log_named_uint("sum of active face", faces);
        emit log_named_uint("instruments", held.length);
        emit log_named_uint("nav + pending", nav + pending);
        emit log_named_uint("reserves + undeployed + face", reserves + undeployed + faces);

        assertLe(
            nav + pending,
            reserves + undeployed + faces,
            "NAV claims more than the holdings could ever return"
        );
    }
}
