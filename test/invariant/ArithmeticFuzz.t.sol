// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/libraries/LockedPoolLibrary.sol";
import "../../src/libraries/CalculationLibrary.sol";
import "../../src/types/ILockedPoolTypes.sol";

/// The protocol's arithmetic, fuzzed.
///
/// These are the pure functions every payout is derived from. The example-based suite
/// pins a handful of values; what matters for money is the properties that must hold for
/// *all* inputs — monotonicity, that rounding only ever favours the pool, and that no
/// input in the admissible range reverts or overflows.
contract ArithmeticFuzz is Test {
    uint256 constant BPS = 10_000;
    uint256 constant MAX_APY = 5_000;          // protocol ceiling, 50%
    uint256 constant MAX_DAYS = 3_650;         // ten years
    uint256 constant MAX_PRINCIPAL = 1e15;     // a billion at 6dp

    // ------------------------------------------------------------ interest

    /// Simple interest, so doubling the principal doubles the interest. Any deviation
    /// beyond a wei of truncation means the formula is not linear in principal, which is
    /// what "simple, not compound" is supposed to guarantee.
    function testFuzz_interestIsLinearInPrincipal(
        uint256 principal,
        uint256 apyBps,
        uint256 durationDays
    ) public pure {
        principal = bound(principal, 1e6, MAX_PRINCIPAL / 2);
        apyBps = bound(apyBps, 1, MAX_APY);
        durationDays = bound(durationDays, 1, MAX_DAYS);

        uint256 one = LockedPoolLibrary.calculateInterest(principal, apyBps, durationDays);
        uint256 two = LockedPoolLibrary.calculateInterest(principal * 2, apyBps, durationDays);

        // Truncation can lose at most one unit per division.
        assertApproxEqAbs(two, one * 2, 2, "interest is not linear in principal");
    }

    /// A longer term never pays less, and a higher rate never pays less. A payout curve
    /// that dips somewhere is an arbitrage.
    function testFuzz_interestIsMonotonic(
        uint256 principal,
        uint256 apyBps,
        uint256 durationDays
    ) public pure {
        principal = bound(principal, 1e6, MAX_PRINCIPAL);
        apyBps = bound(apyBps, 1, MAX_APY - 1);
        durationDays = bound(durationDays, 1, MAX_DAYS - 1);

        uint256 base = LockedPoolLibrary.calculateInterest(principal, apyBps, durationDays);
        assertGe(
            LockedPoolLibrary.calculateInterest(principal, apyBps, durationDays + 1),
            base,
            "a longer term paid less"
        );
        assertGe(
            LockedPoolLibrary.calculateInterest(principal, apyBps + 1, durationDays),
            base,
            "a higher rate paid less"
        );
    }

    /// Within the protocol's own ceilings, interest can never exceed principal — which is
    /// what makes an upfront-interest position fundable at all, since it pays the interest
    /// out of the principal on day one.
    function testFuzz_interestStaysFundableForUpfrontTerms(
        uint256 principal,
        uint256 apyBps,
        uint256 durationDays
    ) public pure {
        principal = bound(principal, 1e6, MAX_PRINCIPAL);
        apyBps = bound(apyBps, 1, MAX_APY);
        // Two years at the 50% ceiling is exactly 100%, so stay inside it.
        durationDays = bound(durationDays, 1, 700);

        uint256 interest = LockedPoolLibrary.calculateInterest(principal, apyBps, durationDays);
        assertLt(interest, principal, "upfront interest would exceed the principal funding it");
    }

    // ------------------------------------------------------------ pro-rata

    /// Accrued interest never exceeds the full term's interest, and equals it at term end.
    function testFuzz_proRataNeverExceedsTheWholeTerm(
        uint256 fullInterest,
        uint256 elapsed,
        uint256 duration
    ) public pure {
        fullInterest = bound(fullInterest, 0, MAX_PRINCIPAL);
        duration = bound(duration, 1, MAX_DAYS * 1 days);
        elapsed = bound(elapsed, 0, duration);

        uint256 accrued = LockedPoolLibrary.calculateProRataInterest(fullInterest, elapsed, duration);
        assertLe(accrued, fullInterest, "accrued more than the term pays");

        if (elapsed == duration) {
            assertEq(accrued, fullInterest, "a completed term did not accrue in full");
        }
    }

    /// Time only ever adds. A holder who waits cannot be worse off.
    function testFuzz_proRataIsMonotonicInTime(
        uint256 fullInterest,
        uint256 elapsed,
        uint256 duration
    ) public pure {
        fullInterest = bound(fullInterest, 0, MAX_PRINCIPAL);
        duration = bound(duration, 2, MAX_DAYS * 1 days);
        elapsed = bound(elapsed, 0, duration - 1);

        assertGe(
            LockedPoolLibrary.calculateProRataInterest(fullInterest, elapsed + 1, duration),
            LockedPoolLibrary.calculateProRataInterest(fullInterest, elapsed, duration),
            "waiting longer accrued less"
        );
    }

    // ------------------------------------------------------------ face value

    /// Face value is what the pool expects back, so it must always be at least what was
    /// raised — a discount that produced a face below par would book a guaranteed loss.
    function testFuzz_faceValueIsNeverBelowTheRaise(
        uint256 raised,
        uint256 discountRate
    ) public pure {
        raised = bound(raised, 1e6, MAX_PRINCIPAL);
        discountRate = bound(discountRate, 0, BPS - 1);

        uint256 face = CalculationLibrary.calculateFaceValue(raised, discountRate);
        assertGe(face, raised, "face value came out below the amount raised");
    }

    /// A deeper discount implies a larger face value for the same money in.
    function testFuzz_deeperDiscountMeansHigherFace(
        uint256 raised,
        uint256 discountRate
    ) public pure {
        raised = bound(raised, 1e6, MAX_PRINCIPAL);
        discountRate = bound(discountRate, 0, BPS - 2);

        assertGe(
            CalculationLibrary.calculateFaceValue(raised, discountRate + 1),
            CalculationLibrary.calculateFaceValue(raised, discountRate),
            "a deeper discount implied a smaller face value"
        );
    }

    // ------------------------------------------------------------ splitting a pot

    /// Splitting a pot pro-rata must never distribute more than the pot. Truncation has to
    /// leave dust behind in the escrow, never hand out more than exists — the direction of
    /// rounding is the whole point.
    function testFuzz_proRataSplitNeverOverDistributes(
        uint256 total,
        uint256 shareA,
        uint256 shareB,
        uint256 shareC
    ) public pure {
        total = bound(total, 0, MAX_PRINCIPAL);
        shareA = bound(shareA, 1, 1e12);
        shareB = bound(shareB, 1, 1e12);
        shareC = bound(shareC, 1, 1e12);
        uint256 supply = shareA + shareB + shareC;

        uint256 paid = (shareA * total) / supply
            + (shareB * total) / supply
            + (shareC * total) / supply;

        assertLe(paid, total, "a pro-rata split handed out more than the pot held");
    }
}
