// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../SingleAssetPool.t.sol";

/// Drives a single-asset deal through random orderings of its whole lifecycle: subscribing
/// and cancelling during funding, closing the epoch, the SPV drawing and confirming,
/// coupons arriving and being claimed, settlement, and redemption.
///
/// The lifecycle is a state machine, so most random orderings are rejected — that is the
/// point. The handler swallows those and keeps going; what matters is that no *accepted*
/// ordering leaves the deal able to pay out more than it took in.
contract SingleAssetHandler is Test {
    LiquidityPool public pool;
    PoolEscrow public escrow;
    Manager public manager;
    MockERC20 public token;
    address public poolAddr;
    address public operator;
    address public spv;

    address[] public actors;

    uint256 public subscribedIn;
    uint256 public couponsIn;
    uint256 public settledIn;
    uint256 public paidOut;
    uint256 public couponsClaimedOut;

    constructor(
        LiquidityPool pool_,
        PoolEscrow escrow_,
        Manager manager_,
        MockERC20 token_,
        address operator_,
        address spv_,
        address[] memory actors_
    ) {
        pool = pool_;
        escrow = escrow_;
        manager = manager_;
        token = token_;
        poolAddr = address(pool_);
        operator = operator_;
        spv = spv_;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function subscribe(uint256 actorSeed, uint256 amount) external {
        address who = _actor(actorSeed);
        amount = bound(amount, 1_000e6, 60_000e6);
        token.mint(who, amount);
        vm.startPrank(who);
        token.approve(poolAddr, amount);
        try pool.deposit(amount, who) {
            subscribedIn += amount;
        } catch {}
        vm.stopPrank();
    }

    /// Cancelling during the funding window is a refund at par.
    function cancel(uint256 actorSeed, uint256 amount) external {
        address who = _actor(actorSeed);
        uint256 held = pool.balanceOf(who);
        if (held == 0) return;
        amount = bound(amount, 1, held);

        uint256 before = token.balanceOf(who);
        vm.prank(who);
        try pool.withdraw(amount, who, who) {
            paidOut += token.balanceOf(who) - before;
        } catch {}
    }

    function closeEpoch() external {
        vm.prank(operator);
        try manager.closeEpoch(poolAddr) {} catch {}
    }

    function drawForInvestment(uint256 amount) external {
        amount = bound(amount, 1, 200_000e6);
        vm.prank(spv);
        try manager.withdrawFundsForInvestment(poolAddr, amount) {} catch {}
    }

    /// Must account for everything drawn, so the amount is read rather than fuzzed — the
    /// fuzzed version only ever exercises the rejection.
    function confirmInvestment() external {
        uint256 drawn = manager.poolFundsWithdrawnBySPV(poolAddr);
        if (drawn == 0) return;
        vm.prank(spv);
        try manager.processInvestment(poolAddr, drawn, "ipfs://fuzz") {} catch {}
    }

    function payCoupon(uint256 amount) external {
        amount = bound(amount, 100e6, 5_000e6);
        token.mint(spv, amount);
        vm.startPrank(spv);
        token.approve(address(manager), amount);
        try manager.processCouponPayment(poolAddr, amount) {
            couponsIn += amount;
        } catch {}
        vm.stopPrank();
    }

    function distributeCoupons() external {
        vm.prank(operator);
        try manager.distributeCouponPayment(poolAddr) {} catch {}
    }

    function claimCoupon(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        uint256 before = token.balanceOf(who);
        vm.prank(who);
        try pool.claimCoupon() {
            couponsClaimedOut += token.balanceOf(who) - before;
        } catch {}
    }

    function settle(uint256 recoveryBps) external {
        // A deal can settle short, on target, or above — all three must reconcile.
        recoveryBps = bound(recoveryBps, 5_000, 12_000);
        uint256 invested = manager.poolActualInvested(poolAddr);
        if (invested == 0) return;
        uint256 amount = (invested * recoveryBps) / 10_000;

        token.mint(spv, amount);
        vm.startPrank(spv);
        token.approve(address(manager), amount);
        try manager.processMaturity(poolAddr, amount) {
            settledIn += amount;
        } catch {}
        vm.stopPrank();
    }

    function redeem(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        uint256 held = pool.balanceOf(who);
        if (held == 0) return;

        uint256 before = token.balanceOf(who);
        vm.prank(who);
        try pool.withdraw(held, who, who) {
            paidOut += token.balanceOf(who) - before;
        } catch {}
    }

    function warp(uint256 days_) external {
        vm.warp(block.timestamp + bound(days_, 1, 40) * 1 days);
    }
}

contract SingleAssetInvariants is SingleAssetPoolTest {
    SingleAssetHandler internal handler;

    function setUp() public virtual override {
        super.setUp();
        (poolAddress, escrowAddress) = _createInterestBearingPool();

        address[] memory actors = new address[](3);
        actors[0] = user1;
        actors[1] = user2;
        actors[2] = user3;

        handler = new SingleAssetHandler(
            LiquidityPool(poolAddress),
            PoolEscrow(payable(escrowAddress)),
            manager,
            token,
            operator,
            spv,
            actors
        );

        targetContract(address(handler));
    }

    /// An interest-bearing deal, so the coupon paths are reachable. A discounted deal has
    /// no coupons at all, which would leave a third of this handler inert.
    function _createInterestBearingPool() internal returns (address, address) {
        uint256[] memory dates = new uint256[](2);
        dates[0] = block.timestamp + 30 days;
        dates[1] = block.timestamp + 60 days;
        uint256[] memory rates = new uint256[](2);
        rates[0] = 200;
        rates[1] = 200;

        IPoolFactory.PoolConfig memory config = IPoolFactory.PoolConfig({
            asset: address(token),
            instrumentType: IPoolTypes.InstrumentType.INTEREST_BEARING,
            instrumentName: "Fuzzed Deal",
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
        return factory.createPool(config);
    }

    /// The whole of solvency for a closed-end deal: everything paid out, to holders and as
    /// coupons, can never exceed what came in — subscriptions, coupons, and whatever the
    /// SPV returned at settlement.
    function invariant_nothingLeavesThatDidNotArrive() public view {
        assertLe(
            handler.paidOut() + handler.couponsClaimedOut(),
            handler.subscribedIn() + handler.couponsIn() + handler.settledIn(),
            "the deal paid out more than it ever took in"
        );
    }

    /// Coupons can only be claimed once each, in total. This is the invariant the
    /// double-claim defect broke: entitlement read the live token balance, so moving shares
    /// reset the claim and 2,000 distributed paid out 3,000.
    function invariant_couponsClaimedNeverExceedCouponsDistributed() public view {
        assertLe(
            _couponsClaimed(),
            manager.poolTotalCouponsDistributed(poolAddress),
            "more coupon was claimed than was ever distributed"
        );
    }

    /// And distribution can only ever mark what actually arrived.
    function invariant_couponsDistributedNeverExceedCouponsReceived() public view {
        assertLe(
            manager.poolTotalCouponsDistributed(poolAddress),
            manager.poolTotalCouponsReceived(poolAddress),
            "distributed coupon the SPV never paid"
        );
    }

    /// The escrow's tracked deposits are a claim on real tokens.
    function invariant_escrowHoldsWhatItClaims() public view {
        assertGe(
            token.balanceOf(escrowAddress),
            PoolEscrow(payable(escrowAddress)).getAvailableBalance(),
            "escrow reports more available than it holds"
        );
    }

    /// Shares are struck one-for-one with subscriptions during funding, so the supply can
    /// never exceed what was raised. A supply above it would mean shares minted against
    /// money that never arrived.
    function invariant_supplyNeverExceedsWhatWasRaised() public view {
        if (manager.poolStatus(poolAddress) != IPoolTypes.PoolStatus.FUNDING) return;
        assertLe(
            LiquidityPool(poolAddress).totalSupply(),
            manager.poolTotalRaised(poolAddress),
            "more shares outstanding than money raised"
        );
    }

    /// `pools(pool)` returns all twelve members of `PoolData`, config struct included.
    /// These two helpers name the fields this file needs so the positional destructuring
    /// lives in one place rather than at every use.
    function _couponsClaimed() internal view returns (uint256 claimed) {
        (, , , , , , , claimed, , , , ) = manager.pools(poolAddress);
    }

    function _sharesAtMaturity() internal view returns (uint256 frozen) {
        (, , , , , , , , , , , frozen) = manager.pools(poolAddress);
    }

    /// Once settled, the divisor is frozen. Every holder redeeming against the same pot
    /// must therefore be priced identically — if it were read live, each successive
    /// redemption would shrink the supply and pay the next holder more.
    function invariant_settlementDivisorStaysFrozen() public view {
        if (manager.poolStatus(poolAddress) != IPoolTypes.PoolStatus.MATURED) return;
        uint256 frozen = _sharesAtMaturity();
        assertGt(frozen, 0, "a matured deal has no divisor");
        assertGe(
            frozen,
            LiquidityPool(poolAddress).totalSupply(),
            "the frozen divisor fell below the shares still outstanding"
        );
    }
}
