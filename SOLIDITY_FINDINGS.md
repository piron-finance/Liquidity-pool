# Solidity findings

Pre-production review of the EVM contracts. Every contract under `src/` was read, and
each finding below was traced through the whole flow — the entry point, the manager, the
escrow and the accounting — before being called a defect. Where the flow turned out to
make something unreachable or deliberate, it is recorded that way rather than as a bug.

Reproductions live in `test/AuditLocked.t.sol`. They assert the *correct* behaviour, so
they fail while the defect stands and pass once it is fixed.

---

## S-1 · Critical · A position can be settled against another pool's escrow

**Where** `src/LockedPoolManager.sol:364` (`redeem`), `:526` (`earlyWithdraw`)

`positions` is a single global mapping keyed by `positionId`, and every position records
the `poolAddress` it belongs to. Both money-moving paths check that the *caller* is the
pool they were handed:

```solidity
if (msg.sender != poolAddress) revert OnlyPool();
```

Neither checks that the position actually belongs to that pool. So a holder with a
position in pool B can call pool A's `redeemPosition` or `earlyExitPosition` with that
position's id, and pool A settles it — out of pool A's escrow, against pool A's metrics,
and on the early-exit path priced against **pool A's tier terms**
(`poolTiers[poolAddress][position.tierIndex]`).

### Why this is an oversight rather than a design choice

Three pieces of evidence from the same file:

- `setAutoRollover` (`:435`) and `transferPositionOwnership` (`:452`) both bind correctly,
  with `if (msg.sender != position.poolAddress) revert OnlyPool();`
- The read-only `calculateEarlyExitPayout` (`:828`) prices against
  `poolTiers[position.poolAddress][position.tierIndex]` — so the view and the executing
  function disagree about whose terms apply.
- The error `InvalidPosition` is already declared and used by that view for exactly this
  kind of guard.

The escrow offers no second line of defence: `onlyLockedPoolOrManager` means it accepts
any instruction from the shared manager and cannot tell which pool an obligation is for.

### Evidence

```
test_locked_positionCannotBeRedeemedAgainstAnotherPool
  paid out of pool A's escrow   50,616.438356
  pool B's escrow, untouched             0

test_locked_positionCannotBeExitedAgainstAnotherPool
  paid out of pool A's escrow   45,184.931507
```

Pool A's holders are short by that amount, and pool A's `totalPrincipalLocked` and
`totalExpectedMaturityPayout` are decremented by another pool's figures — which either
underflows and permanently bricks the pool's redemptions, or silently corrupts the numbers
the SPV uses to size deployments.

The debt path compounds it: `poolDebtPositionIds[poolAddress].push(positionId)` files pool
B's debt under pool A.

### Fix

Bind both paths the way their neighbours already do:

```solidity
if (position.poolAddress != poolAddress) revert InvalidPosition();
```

In `earlyWithdraw`, also read the tier from `position.poolAddress`, matching the view.

---

## S-2 · High · Two money-holding contracts bypass the upgrade timelock

**Where** `src/escrows/YieldReserveEscrow.sol:212`, `src/FeeManager.sol:134`

Upgrade authority across the system falls into three groups:

| Contracts | Authority |
|---|---|
| `Manager`, `StableYieldManager`, `LockedPoolManager`, `PoolRegistry`, `ManagedPoolFactory`, `PoolFactory` | `msg.sender == timelockController` — 72h delay, grace period, guardian brake |
| `LiquidityPool`-side pools and their escrows | upgrades reverted outright |
| **`YieldReserveEscrow`, `FeeManager`** | **`MULTISIG_ADMIN_ROLE` directly** |

The two outliers are the contracts holding the protocol's backstop capital and its
undistributed fee revenue. They can have their implementation replaced in a single
transaction, with no delay for anyone to notice and no guardian able to intervene —
while every pool manager, the registry and both factories cannot.

A multisig is a high bar, but the timelock exists precisely so a compromised or coerced
multisig still cannot swap code on money-holding contracts instantly. The inconsistency
suggests this was not a deliberate exemption.

### Fix

Route both through `timelockController`, as the six other upgradeable contracts do. If an
exemption is genuinely wanted, state it in the contract with the reasoning, so it reads as
a decision rather than an omission.

---

## S-3 · Medium · The early-exit penalty is repriced retroactively

**Where** `src/LockedPoolManager.sol:531`, `configureLockTier` at `:220`

`buildPosition` captures the rate at deposit into `apyBpsAtDeposit`, so a position's
*interest* is fixed for its life. The exit *penalty* is not captured — `_calculateEarlyExit`
reads `tier.earlyExitPenaltyBps` live from the tier.

`configureLockTier` replaces a tier wholesale (`tiers[tierIndex] = tier`), so an operator
can raise the penalty on every open position in that tier after the fact. A holder who
locked capital under a 10% exit penalty can find it is 50% when they come to leave.

The design's own intent is visible in the field name `apyBpsAtDeposit`: terms are meant to
be fixed per position. The penalty was simply left out.

### Fix

Capture `earlyExitPenaltyBpsAtDeposit` on the position and price exits from it. That is a
struct change, so it needs the same migration treatment as any other position-field
addition.

---

## S-4 · Medium · Protocol capital can be booked to one pool and sent to another

**Where** `src/escrows/YieldReserveEscrow.sol:264` (`deployToPool`), and the same pattern
at `:466`

```solidity
require(authorizedEscrows[escrow], "YieldReserveEscrow/unauthorized escrow");
...
deployedToPool[pool] += amount;
asset.safeTransfer(escrow, amount);
```

The escrow must be *an* authorized escrow, but nothing requires it to be the escrow of
`pool`. The reserve holds only `mapping(address => bool) authorizedEscrows` — there is no
pool↔escrow mapping for it to check against, so it cannot bind them even in principle.

Both managers pass their own pool's escrow correctly. The exposure is the third caller:
`OPERATOR_ROLE` may call this directly. Capital booked against pool A but sent to escrow B
makes `deployedToPool` wrong, and since that figure gates both recall paths
(`require(deployedToPool[pool] >= amount)`), the funds become **unrecallable** — recall
against B fails on the reserve's books, recall against A fails at escrow A for want of
`protocolFundsFromReserve`. Money is not stolen; it is stranded.

### Fix

Simplest: drop `OPERATOR_ROLE` from `deployToPool` and leave it to the two managers, which
already derive the escrow from `poolEscrows[poolAddress]`. Alternatively give the reserve a
registry reference and check `registry.getPoolInfo(pool).escrow == escrow` —
`PoolInfo.escrow` already exists and is populated.

---

## S-5 · Medium · Fee revenue reaches the reserve but is not spendable

**Where** `src/FeeManager.sol:246`, `src/escrows/YieldReserveEscrow.sol:568`

`distributeFees` sends the reserve's share with a bare `safeTransfer`:

```solidity
if (r > 0) IERC20(asset).safeTransfer(yieldReserve, r);
```

The reserve tracks spendable funds in `totalBalance`, which a bare transfer does not
touch. The money is in the contract and invisible to every `require(totalBalance >= …)`
that governs loans, deployments and shortfall cover.

`syncUntrackedFunds()` exists to recover exactly this, and it is correct — but it is
`onlyOperator`, so the reserve's solvency depends on somebody remembering to call it after
each distribution. This is the same defect the audit record notes as already fixed once;
the sync was added, but the path that creates the condition still relies on a manual step.

### Fix

Either give the reserve a `receiveFees(asset, amount)` entry point that pulls and credits
in one call and have `distributeFees` use it, or make `syncUntrackedFunds` permissionless.
It only credits tokens already held, so anyone calling it is harmless.

---

## S-6 · Medium · Penalty revenue is reported even when it was not captured

**Where** `src/libraries/LockedPoolManagerLib.sol:43-58`, `:86-97`

When the escrow cannot cover payout plus penalty, the penalty is recorded only in part:

```solidity
} else if (available >= payout) {
    escrow.withdraw(user, payout);
    uint256 penaltyInEscrow = available - payout;   // less than `penalty`
    if (penaltyInEscrow > 0) escrow.recordPenalty(penaltyInEscrow);
}
...
if (penalty > 0) {
    poolAccounting[poolAddress].totalPenaltiesEarned += penalty;   // the full figure
}
```

`totalPenaltiesEarned` is credited the full penalty regardless of how much was actually
taken. The reserve-loan branch tracks the shortfall properly in `pendingPenalty`, which
shows the partial case was understood — the pool-level total just was not adjusted to
match.

### Fix

Credit `totalPenaltiesEarned` with the amount actually recorded, and let `pendingPenalty`
account for the rest as it already does on the loan branch.

---

## S-7 · Low · A pool cannot be given a zero deposit fee

**Where** `src/LockedPoolManager.sol:301` and `:752`

```solidity
uint256 feeBps = poolDepositFeeBps[poolAddress];
if (feeBps == 0) feeBps = defaultDepositFeeBps;
```

Zero is used as "unset", so `setPoolDepositFee(pool, 0)` appears to succeed and then has no
effect — the pool silently keeps charging the default. `getEffectiveDepositFee` reports the
same way, so the view agrees with the wrong behaviour.

### Fix

Track "is a pool override set" separately from its value, or store the fee as
`value + 1` internally. Either lets zero mean zero.

---

## S-8 · Low · Dead code that can move reserve funds

**Where** `src/escrows/YieldReserveEscrow.sol:379` (`payUser`)

No caller anywhere in `src/` or `test/`. It transfers reserve funds out and increments
`totalLoanedOut` without recording a pool or a position, so the resulting "loan" can never
be repaid through `recordLoanRepayment`, which needs a `positionId`. Reachable only by the
two manager contracts, so it is not a live hole — but it is an unaccounted outflow sitting
in a money-holding contract ahead of a production deploy.

### Fix

Remove it. If a direct-pay path is wanted later, it should record what it paid and against
what.

---

## S-9 · Low · latent · Partial loan repayment forgives the remainder

**Where** `src/escrows/YieldReserveEscrow.sol:417`

```solidity
uint256 repayAmount = amount > loanOwed ? loanOwed : amount;
if (repayAmount > 0) {
    totalLoanedOut -= repayAmount;
    poolLoans[pool]  -= repayAmount;
    positionLoans[positionId] = 0;      // zeroed even on a partial repayment
```

A partial repayment clears the position's loan entirely while `totalLoanedOut` and
`poolLoans` fall only by what was paid — so the position reads as settled and the
aggregates stay inflated.

**Not reachable today.** The only caller, `settlePoolDebt`, repays `debt.reserveLoan` in
full after checking the escrow holds it. Recorded as a robustness item, not a live bug.

### Fix

`positionLoans[positionId] -= repayAmount;`

---

## S-10 · Low · SPV allocation totals drift

**Where** `src/LockedPoolManager.sol:684-690`

```solidity
if (totalSPVAllocations[spv] >= returnedAmount) {
    totalSPVAllocations[spv] -= returnedAmount;
}
```

`returnedAmount` includes yield, but the counter tracks principal allocated, so a
profitable return over-reduces it. And when the subtraction would underflow the branch is
skipped entirely, leaving the figure permanently stale rather than clamping it to zero.

Neither counter gates anything — a search across `src/` finds no reads outside this file
and its own view functions. This is reporting accuracy, not a fund risk.

### Fix

Decrement by `min(allocationPrincipalReturned, outstanding)` rather than the gross return,
and clamp to zero instead of skipping.

---

## S-11 · Low · Allocation ids can collide

**Where** `src/LockedPoolManager.sol:615`

```solidity
allocationId = keccak256(abi.encodePacked(
    poolAddress, spvAddress, amount, block.timestamp, nextPositionId
));
```

Two allocations for the same pool, SPV and amount in one block, with no deposit in
between to move `nextPositionId`, produce the same id and the second reverts with
`AllocationExists`. A nuisance for batched operations rather than a security issue.

### Fix

Include a dedicated monotonic allocation counter in the hash.

---

# Checked and found sound

Recorded because an audit that lists only defects says nothing about where the auditor
looked.

- **`AccessManager`** is deliberately hardened and holds up: `grantRole` reverts in favour
  of `proposeRoleGrant` (delay + `MULTISIG_ADMIN_ROLE` execution), `renounceRole` is
  disabled, `revokeRole` is multisig-only, and the deployment-time bypass is gated on
  `deploymentComplete`. That gate is only as good as the call that closes it — and
  `script/DeployUpgradeable.s.sol:377` does call `finalizeDeployment()`.
- **`TimelockController`**: 72-hour delay, grace-period expiry, separate proposer /
  executor / canceller / guardian roles, and a guardian pause ahead of execution.
- **`loanToPool`'s caller-chosen recipient is correct here.** It looked like the defect
  already found in the Soroban reserve, but `onlyAuthorizedManager` restricts it to the two
  manager contracts — not an EOA role — and the single caller passes the exiting holder,
  which is the intended destination for an early-exit loan.
- **`recordLoanRepayment` credits `totalBalance`** for both the repayment and any excess,
  so the repayment path does not lose track of returning funds.
- **`FeeManager.authorizeCollector`** does check authority; the roles are verified in the
  body rather than by a modifier, which is why the signature looks bare.
- **`FeeManager.distributeFees`** zeroes the pending balances before transferring and is
  `nonReentrant`.
- **`LockedPoolEscrow._drawFunds`** debits principal, then reserve capital, then direct
  deposits, and reverts when the tracked balances do not cover the draw rather than
  zeroing a counter and transferring anyway.
- **Pools and pool escrows cannot be upgraded at all** — `_authorizeUpgrade` reverts. The
  strongest option, and the right one for the contracts holding user positions.

---

# Scope

Read in full: `Manager`, `StableYieldManager`, `LockedPoolManager`, `LiquidityPool`,
`managed/StableYieldPool`, `managed/LockedPool`, all four escrows, `FeeManager`,
`PoolRegistry`, both factories, `AccessManager`, `governance/TimelockController`,
`governance/UpgradeGuardian`, and every library under `src/libraries/`.

Not covered: gas optimisation, and the mid-deal SPV default mechanism, which is a known
gap with no implementation rather than a defect in one.
