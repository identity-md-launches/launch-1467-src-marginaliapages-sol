# MarginaliaPages v0.10 supplemental tests

These tests extend the existing `Pages.t.sol`, `PagesAudit.t.sol`, and `PagesDeployment.t.sol` suites without changing application code or configuration. They use the repository's local Marginalia hook, actual Uniswap v4 PoolManager, and seeded liquidity. No RPC, FFI, new dependencies, or environment mutations are required.

| File | Added coverage |
| --- | --- |
| `PagesProperties.t.sol` | Capped marginal prices against an iterative reference, partitioning across the cap, uint64 supply quotes, repeated buy/sell cycles including self-issued pages, atomic rejection of invalid trades and payments, nontransferability, every possible handle byte, exact Intake allowance/payment, request failure and duplicate/zero ID rollback. |
| `PagesOracleBoundaries.t.sol` | Tampering with each of the 15 signed fields, wrong signer, malformed signatures/answers, consumer and chain domain separation, independent panel minimums, inclusive expiry and clock tolerance, payout failure rollback, exact reimbursement boundary, pre-buy claims, and successive escrow recycling windows. A separate setup tests two fresh recipient balances under the actual 200,000-gas callback call limit. |
| `PagesReentrancy.t.sol` | An explicitly adversarial token probes all guarded entry points during buys, sells, requests, callbacks, recycling, and deferred burns. Nested calls must return the reentrancy guard error, and outer accounting remains consistent. The token behavior is test instrumentation, not a claim about live IMD. |
| `PagesInvariant.t.sol` | Random sequences of 13 handler actions with 24 readers, one address subject and three registered handles. The initial state includes 210 pages on one curve and reimbursable handle escrow on another. |

The invariant campaign uses 256 runs of depth 96 with `fail-on-revert = true`, set inline. Expected rejection paths assert their errors explicitly; unexpected failures are not swallowed. The handler varies buys, partial sells, full ungated exits, repeated round trips, eligibility, oracle prices, successful/zero answers, abandonment, elapsed EVM time, recycling, pool liquidity, burn retries, and direct IMD donations. The deterministic handler scenario exercises every major lifecycle so that coverage does not depend on a lucky random sequence.

After each handler action the invariant checks:

- Each holder's balance matches the independent ledger and stays at or below ten; summed holdings equal supply and net purchases.
- Each subject's reserve equals both recorded net principal flows and the sum of marginal redemption prices.
- Every IMD held by Pages belongs to reserve, escrow, deferred burns, or an explicitly tracked donation.
- The issuer's 80% fee share is conserved across direct payments, claim payouts, reimbursements, recycling, and remaining escrow. The two 10% shares match burns/deferred burns and actual Hook PoolManager claims.
- Escrow clocks, pending request details, permanent payees, and consumed oracle UUIDs match the modeled lifecycle. Pages retains no MARG and leaves no Hook/Intake allowance.

`afterInvariant` removes launch liquidity, removes every reader's eligibility, and actually sells every page. This tests withdrawal liveness and final collateral accounting rather than merely comparing quotes. EVM time is advanced with cheatcodes; there are no real-time waits.

Run from the repository root:

```sh
forge test --match-path test/Pages.t.sol
forge test --match-path 'test/Pages*.t.sol'
forge build
forge test
```

The oracle's signed request UUID intentionally differs from the Intake callback ID. The supplied oracle reference assigns their pairing to the Intake writer and defines a relative-window question hash that cannot be precomputed by Pages. Tests preserve those protocol semantics; they do not assume UUID equality or treat a raw body hash as the signed question hash.

The suite proves local behavior, not live dependency state or offchain panel truth. Existing mainnet fork tests remain optional and require an RPC; they are not needed for offline verification.

Validation completed on 2026-10-12: `forge build` succeeded, and the full `forge test` run reported **373 passed, 0 failed, 2 skipped** across 34 suites. The skips are the existing optional mainnet fork suites. All 28 new checks passed; each of the six new fuzz properties ran 1,000 cases. The final Pages invariant campaign ran **256 sequences / 24,576 handler calls**, with zero unexpected reverts or discarded calls, and completed every final sell-out. No application defect was confirmed by this work.
