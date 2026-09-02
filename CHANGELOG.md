# Changelog

Contract changes since the February 2026 MVP (`d8994ce`), which is the last state that
predates the current hardening pass. Everything below is on `v1.1` or in the open PR
against it.

Grouped by what it means for anyone integrating, because the ABI changes are the part that
breaks things silently.

---

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
