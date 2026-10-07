# Changelog

Contract changes since the February 2026 MVP (`d8994ce`), which is the last state that
predates the current hardening pass. Everything below is on `v1.1` or in the open PR
against it.

Grouped by what it means for anyone integrating, because the ABI changes are the part that
breaks things silently.

---

## [Unreleased] — audit findings

Internal security review across all three runtimes. Everything here was reproduced by an
executable probe before being fixed, and each fix carries a regression test that asserts
the corrected behaviour — see `test/AuditProbe.t.sol` and `test/AuditEvm.t.sol`.

### Breaking — ABI

- **`IPoolTypes.UserPoolData` gains a `shares` field.** Coupon entitlement is now struck
  on shares subscribed through the pool rather than on the holder's live ERC-20 balance.
  Anyone decoding `poolUsers` needs updating.
- **`processInvestment` requires `actualAmount == fundsWithdrawnBySPV`.** Confirming a
  different figure now reverts rather than being accepted silently.
- **`settleWithdrawals` requires a contiguous run from the queue head.** An arbitrary
  selection of request ids now reverts.

### Fixed

- **A queued exit no longer reprices the pool.** `withdraw`/`redeem` burn shares on both
  the immediate and the queued branch, but `calculatePoolNAV` did not subtract
  `totalPendingValue` — so the instant a large exit queued, supply fell while NAV did not
  and every remaining share repriced upward by the size of the queue. A second holder
  whose inflated claim still fitted the free cash was then routed to the *immediate*
  branch and paid at that price, out of the cash standing against the queued request.
  Reproduced at 90,000 / 3,000 / 7,000 USDC with 50,000 allocated: the price rose 10.56x
  and a 3,000 deposit came back out as 29,040. NAV is now net of what the pool owes,
  pending carries the gross quote (the fee leaves the escrow too), and an immediate
  withdrawal is refused while anyone is waiting.
- **A coupon can no longer be claimed twice by moving shares.** Entitlement read the live
  balance and subtracted a per-address claim record, so shares moved to another holder
  reset the claim against them. Reproduced: 2,000 distributed, 3,000 paid, the excess
  taken from principal the SPV had not yet drawn.
- **The coupon divisor is fixed at settlement.** Once holders start burning shares to
  redeem, dividing the coupon pot by a live supply hands each successive holder a larger
  slice of the same money. Found while fixing the claim path, not in the original review.
- **Distributed coupons are no longer stranded at settlement.** Claiming required
  `INVESTED`, `distributeCoupons` marked the whole received balance distributed, and
  `calculateTotalReturns` counts only *undistributed* coupons — so any holder who had not
  claimed by settlement lost the entitlement outright, with no recovery path anywhere in
  the system. Claims are now permitted once matured, and the redemption path settles what
  is still owed alongside the principal.
- **The SPV must account for what it drew.** `processInvestment` accepted any amount up
  to `totalRaised` without consulting `fundsWithdrawnBySPV`, so drawing 100,000 and
  confirming 60,000 left 40,000 with the SPV and unrecorded as owed, while face value,
  expected settlement and every holder valuation were struck on the smaller figure.
- **An unpaid coupon stops accruing at its due date.** Accrual was uncapped, so a payment
  the SPV never made went on inflating NAV until maturity.
- **The withdrawal queue is served in order.** `settleWithdrawals` took an arbitrary array
  of request ids, which let an operator choose who got paid — the thing the ordering rule
  exists to prevent.
- **Lock tiers are bounded in duration.** `validateTier` capped APY and penalty at 50% but
  left `durationDays` unbounded.

### Known, unchanged

- **Interest-bearing instruments are marked at face from day one.** `purchase_price` is
  ignored, so an SPV buying below par books an instant gain it has not earned and may
  never realise. The behaviour is deliberate parity with the original design and
  reversing it changes the economics of every interest-bearing pool, so it is left as
  found pending a decision.

## [Unreleased] — PR #36

### Fixed

- **Emergency entry no longer reachable once the SPV holds the money.** `emergencyExit`
  had no status guard, so a pool could enter `EMERGENCY` from `INVESTED` — where refunds
  pay one unit per share against an escrow already drawn down, so the first claimants take
  par and the rest find nothing. Now requires `fundsWithdrawnBySPV == 0`. Nothing called
  it, so this closed a trap rather than a live bug.
- **`validateWithdrawal` no longer advertises a path the router rejects.** It admitted
  `INVESTED` once past the maturity date, but `handleWithdraw` has no `INVESTED` branch
  and reverts regardless. Settlement is what opens redemption.

### Removed

- `src/interfaces/IFeeManager 2.sol` — an untracked earlier draft carrying the superseded
  `FeeConfig`/`FeeDistribution` design, unreferenced and incompatible with the live
  `FeeSplit` interface.

---

## [v1.1] — 2026-08-24 — PR #34, #35

### Breaking — ABI

Anything calling these needs updating. The allocation lifecycle is gone entirely.

**`StableYieldManager`**

| Removed | Replacement |
| --- | --- |
| `createPendingAllocation(pool, spv, amount)` | `allocateCapital(pool, spv, amount)` — no return value, no allocation id |
| `returnUnusedFunds(allocationId, amount)` | `returnCapital(pool, amount)` — no status gate, no deadline |
| `getPendingAllocation(allocationId)` | `getPoolCapital(pool)` → `(deployed, reserves, undeployed)` |
| `getPoolPendingAllocations(pool)` | — reconstruct from `CapitalAllocated` / `CapitalDeployed` / `CapitalReturned` events |
| `getTotalSPVAllocation(spv)` | `spvUndeployedCapital(spv)` |
| `getPoolToSPVAllocation(pool, spv)` | `getUndeployedCapital(pool, spv)` |
| — | `writeOffInstrument(pool, instrumentId, reason)`, admin only |

`addInstrument` loses its `allocationId` parameter and is debited from the calling SPV's
undeployed balance.

**Events.** `AllocationCreated`, `AllocationInvested`, `AllocationReturned`,
`AllocationMatured` and `AllocationCancelled` are replaced by `CapitalAllocated`,
`CapitalDeployed` and `CapitalReturned`, each carrying the resulting undeployed balance.
`InstrumentWrittenOff` is new. `Manager.DiscountsDistributed` is gone — it was never
emitted.

**Errors.** The `Allocation*` family, `MaxAllocations`, `ExceedsAllocation`,
`NotAllocationSPV` and `InvalidStatus` are replaced by `ExceedsUndeployedCapital`,
`InvalidCouponRate` and `PoolNotActive`.

**Types.** `AllocationStatus` and `PendingAllocation` are removed.
`InstrumentHolding.allocationId` becomes `InstrumentHolding.spv`, keeping per-SPV
attribution. `PoolData` gains `sharesAtMaturity`.

**`LiquidityPool`.** `claimRefund`, `setUserRefund` and `setDiscountAccrued` are removed —
all three were unreachable. The `pendingRefunds` and discount-accrual state goes with them.

**Escrows.** `getSPVAllocation` is renamed `getLifetimeAllocatedToSPV` on both escrows: it
never decreases and reads as live exposure when it is cumulative.
`LockedPoolEscrow.transferPenaltiesToTreasury` is removed. `YieldReserveEscrow` gains
`syncUntrackedFunds` and `getUntrackedFunds`.

### Fixed — money

- **Redemption divided by live share supply.** Each holder claimed a larger slice of a
  draining pot, and the last one out was short. The divisor is now `sharesAtMaturity`,
  frozen at settlement.
- **The redemption pot was built from projections** — face value, scheduled coupons —
  rather than what the SPV actually returned. One formula now, from actuals.
- **Partially deployed capital was stranded.** A partially used allocation whose first
  instrument matured left the remainder out of NAV, un-investable and un-returnable.
  Measured at 18,500 lost on a profitable maturity. Unreachable under the capital model.
- **Interest accrued past maturity without bound**, so an unsettled instrument inflated NAV
  forever. Capped at the maturity date.
- **`LockedPoolEscrow.withdraw` paid principal plus interest while debiting only
  principal**, zeroing the shortfall. Every redemption spent protocol capital no counter
  recorded. `_drawFunds` now debits principal then the protocol capital that funds yield,
  and reverts when neither covers it.
- **`returnProtocolFundsToReserve` and `emergencyWithdraw` clamped counters to zero** while
  transferring in full, so depositor cash could leave with the accounting reading zero.
- **Fee revenue routed to the yield reserve was unusable.** Early-exit penalties default to
  100% to the reserve, and `distributeFees` sends it by bare transfer, which never credits
  `totalBalance` — so the income meant to keep the reserve solvent could not be lent,
  deployed or swept, with no path to credit it.

### Fixed — authority

- **`emergencyRedeem` let an operator burn any holder's shares and name themselves the
  recipient.** The `receiver` argument is gone; proceeds go to the holder.
- **`YieldReserveEscrow.deployToPool` and `investReserve` took the destination from the
  caller**, while the contract already maintained the set of valid escrows and enforced it
  on inbound paths. Now enforced outbound.
- **`transferPenaltiesToTreasury` let any operator send the penalty pot anywhere.** Removed;
  the reserve path uses the configured `yieldReserve` through a typed call.
- **Pause froze exits along with entries.** Deposits and mints stop; withdrawals, matured
  redemptions and rollover opt-out stay open. Unpause is admin-only so a compromised
  operator cannot undo a pause.

### Fixed — correctness

- `isInEmergency()` compared the status to `4`, which is `MATURED`; `EMERGENCY` is `6`.
- `initializePool` now rejects configs `PoolFactory` does not already catch: a discount rate
  at or above 100%, a minimum investment above the target, and mismatched coupon arrays.
- Coupon rate and frequency ceilings on instruments.
- Every withdrawal path emits `PoolWithdrawal`. The indexer read `WithdrawalFeeCollected`,
  which only fires on the matured path, silently dropping funding-phase and emergency exits.

### Removed — dead code

`distributeDiscount`, three unused validators, `handleMaturedWithdrawal`, a write-only
allocation array in `LockedPoolManager`, and two `StableYieldNAVLibrary` functions that
computed NAV by a different formula than the manager and had no callers.

### Deployment

Storage slots moved. **Deploy fresh proxies rather than upgrading existing ones** — pointing
an existing proxy at this code reads the old data through the new layout. Every deployment
at the time of the change was testnet, so the removed slots were not carried forward as
placeholders.

---

## [MVP] — 2026-02-23

Baseline. Three pool types — Single Asset, Locked, Stable Yield — with escrows, factories,
registry, fee manager, yield reserve and timelocked upgrades.
