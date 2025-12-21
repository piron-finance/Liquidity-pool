CONTRACTS ISSUE:

- The StableYieldManager inherits from AccessControlUpgradeable (line 26), which means it has its own role storage. The onlyRole() modifier checks roles on the StableYieldManager contract, NOT on the external AccessManager! - Done
- Nav goes below 1 dollar. Shouldn’t be.
- Also, numbers seems inconsistent. We need a way to track allocated capital to spv and also invested capital et al.
- We need wallets. When spv (which also needs to be specified per pool) is allocated, the funds goes to their wallet. In order to add instruments, funds need to leave the wallet. Ie it has to be a withdrawal.
- refactor single asset pools to locked pools.
- Pool should have a threshold. Where a function can be called to check if a pool is in a position to be pulled from.
  -On maturity, funds should also move. Spv shouldn’t be able to call mature instrument without moving funds. The receive spv maturity must succeed for the parent to succeed.

- Todo

FE ISSUE:
Est yield of deposit modal calc
Auto refresh of data on deposit.
Fix constant block reads to something more efficient.
Portfolio page having outdated data. Data consistency?
Portfolio doesn’t segregate between users

FE CONSIDERATION:
Escrow calculates and allocates fees in the escrow. So maybe we query this, then return the value as unrealized fees
Refactor pool creator watcher to only be triggered for a while after pool creation activity.

Spv dash: activity should be admin emitted activity and also spv activity or alerts eg 1 week to maturity of an instrument
