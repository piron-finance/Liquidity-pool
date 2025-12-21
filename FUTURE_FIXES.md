CONTRACTS ISSUE:
The StableYieldManager inherits from AccessControlUpgradeable (line 26), which means it has its own role storage. The onlyRole() modifier checks roles on the StableYieldManager contract, NOT on the external AccessManager!
The external AccessManager contract at 0x05b32... has the roles, but the StableYieldManager at 0xE756E... is checking its own internal AccessControl, which probably doesn't have any roles granted!
The fix: The StableYieldManager needs to have OPERATOR_ROLE granted on the StableYieldManager contract itself, not just on the AccessManager contract. Check if there's an initialization function that grants these roles, or they need to be manually granted to the StableYieldManager.
Your 0xfeed... address needs OPERATOR_ROLE granted on StableYieldManager contract (0xE756E61e69cd090Cfe7bF0648c6f488c47629a80), not the AccessManager.

Todo

Est yield of deposit modal calc
Auto refresh of data on deposit.
Fix constant block reads to something more efficient.
Portfolio page having outdated data. Data consistency?
Portfolio doesn’t segregate between users
Investigate money going to fee manager or treasury

Escrow calculates and allocates fees in the escrow. So maybe we query this, then return the value as unrealized fees

Refactor pool creator watcher to only be triggered for a while after pool creation activity.

Operator collects fees to treasury. Check where the call is made. Add to operator card

Test pool admins and spv actiions

Nav goes below 1 dollar. Shouldn’t be.

Also, numbers seems inconsistent. We need a way to track allocated capital to spv and also invested capital et al.

Also, we need a single way to validate role access manager not stable manager

We need wallets. When spv (which also needs to be specified per pool) is allocated, the funds goes to their wallet. In order to add instruments, funds need to leave the wallet. Ie it has to be a withdrawal.

Pool should have a threshold. Where a function can be called to check if a pool is in a position to be pulled from.

On click instruments, we should see details. Ie what it is, details, docs maybe, when it matures, what lifecycle it’s at

On maturity, funds should also move. Spv shouldn’t be able to call mature instrument without moving funds. The receive spv maturity must succeed for the parent to succeed.

Spv dash: activity should be admin emitted activity and also spv activity or alerts eg 1 week to maturity of an instrument

Contract: maybe have states for stable yield pools? Does that make sense?
