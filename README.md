# Marginalia — notes in the margin of every trade

**What it is:** a bonded feed. Anyone who buys MARG can attach a note: a falsifiable call on any token (up or
down, by how much, by when), or a long-form thesis. The author puts an IMD bond behind it, the chain settles
whether it was right, and the record follows the wallet. **Not a perp DEX, not a prediction market.** There is
no leverage, no counterparty and no payout for being right: a right call only gets its own bond back, a wrong
one forfeits it to the writers' pools. The only money that moves is the author's own. Key holders read an
author's sealed notes before the crowd does; nobody trades against anyone.

This launch deploys **only MarginaliaPages v0.10** on Ethereum mainnet, replacing the unused v0.9 deployment from job `0925298b`. The existing MARG token, launch-1283 hook and launch-1384 Annex remain live. The hook uses the live launch-1240 Router, Judge, Treasury and Pricer; none is redeployed. Buying MARG through the
router with a note attached posts a falsifiable call on an ERC-20 other than IMD itself, backed by a flat 0.1 IMD stamp and an
IMD bond the author sizes between 0.25 and 10 IMD (every note also buys 0.25 IMD of MARG). Calls resolve against a manipulation-resistant settlement price built from permissionless
on-chain observations (v3/v2 TWAPs, the adverse extreme on v4); right calls get their deposit back,
everything else feeds the weekly pools, including thesis prizes ranked by the IMD oracle panel.
No owner, no pause, no upgrade. Spec: `SPEC.md`.

## Contracts

| Contract | Role |
|---|---|
| `Marginalia` | The launch ERC-20: 1,000,000,000 × 1e18 minted once to its deployer (the launch factory). |
| `MarginaliaHook` | The hook (flags `0x20cc`): binds the launch pool, takes the stamp and the IMD bond on noted buys and the 1%/3% fee on sells, holds notes, observations, records and the three pools, and pays out. Its constructor clones the three companions (EIP-1167) from the live launch-1240 implementations and initialises each once. Notes can be counters: a thesis may rebut another author's open thesis, a call may take the other side of another author's open call on the same token (`parentId` pointing at that note). |
| `MarginaliaRouter` | The only path that can attach a note; optionally trades X on Uniswap v4, v3 or v2 in the same transaction so the position is proven, and refuses a note about a token other than the one traded. Plain MARG buys and sells go through any v4 router. |
| `MarginaliaJudge` | The oracle consumer: once a week buys the panel's ranking of the week's long-form theses through the IMD Intake, verifies the EIP-712 attestation, tells the hook whom to pay. Short-form calls are never judged. |
| `MarginaliaTreasury` | Receives prizes and gifts in IMD; drips 2% of its IMD into the pools daily. No withdraw; refuses ETH. |
| `MarginaliaPages` | The page market (v0.10, launching after the Annex): pages of a writer on a CAPPED linear IMD curve (page n costs 0.05 IMD × n up to 10 IMD at page 200, then 10 IMD flat; sellable on the curve, never transferable; at most 10 pages of one writer per wallet); 10% fee per trade, 80% of it to the writer, 10% buys and burns MARG, 10% to the pools. Buying needs one of: identity.md's settled whitelist, 10,000 MARG held, or a note posted on the hook or the Annex; selling is never gated. Pages of an unclaimed X handle escrow the writer's share until the owner claims it through the IdentityMD oracle (they tweet the exact `claimMessage(wallet)` text, anyone pays the Intake's price to verify the explicit payout claim, the signed answer sets the payee, the price reimbursed from the escrow). No attester, no server of ours. Unclaimed escrow recycles into the pools after 90 days. Page holders get sealed notes first. |
| `MarginaliaAnnex` | Calls on the Uniswap v4 pools the router cannot accept (LIVE, launch 1384, `0xd0c0d97aebe9194606bcc46ce56524eee4615543`): a pool whose hook has no swap permission bits (the IMD launch guard on every launched token's pool) is a venue by arithmetic; a hook with swap permissions becomes one only when the IMD oracle panel admits it as open (anyone asks, `requestAdmission`, up to 4 hooks, the Intake's price). Same call, hold rule, observations, settlement and scoring as the hook through the same pricer; bonds in IMD, forfeits to the hook's pools; the 0.1 IMD stamp buys and burns MARG (one 0.35 IMD swap with the author's 0.25 purchase). No seals, no theses, no owner. |
| `MarginaliaPricer` | Stateless, ownerless helper the hook calls by staticcall (kept out of the hook for code size): score arithmetic (log2, sqrt, difficulty), price reads and the settlement rule: a prior-window baseline (v3/v2 accumulator TWAP, conservative v4/hub extreme); observation reads (v3 tick cumulative, v2 price cumulative, v4 spot, the ETH→IMD hub spot); settle price = TWAP first→last on v3/v2, the observation least favourable to the call on v4 and on the hub leg. An honest observation pins the extreme; the series must span at least one hour. |

## Pages v0.10 launch and integration

Deploy `src/MarginaliaPages.sol:MarginaliaPages` with the five nonpayable constructor arguments below.
The constructor stores configuration without reading any dependency. This deployment adds no token,
pool, owner, initializer or companion contract. The launch service supplies the resulting Pages address;
no Pages address is assumed here.

| Argument | Ethereum value |
|---|---|
| hook | `0xf0457dd0cf526686190e4f057ba19db14d34a0cc` |
| annex | `0xd0c0d97aebe9194606bcc46ce56524eee4615543` |
| intake | `0x1397434cd35e8a9C8aC312A61D3A285EB31dea56` |
| action | `bytes32("oracle.request@oracle-1")` (right-padded UTF-8, not a hash) |
| signer | `0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982` |

For an address writer, use `subjectOf(writer)`. For a handle, anyone first sends a
`registerHandle(handle)` transaction once; it validates and lower-cases the preimage, returning the same id as
`subjectOfHandle(handle)`. Registration grants no ownership and starts no clock. Buy with
`buy(subject, amount, maxCost)` after quoting `buyPrice`; approve the quoted IMD total. Zero ids
and unregistered hashes revert `BadSubject`. Sell with `sell(subject, amount, minOut)` after quoting
`sellPrice`; selling never checks eligibility.

The burn share still buys MARG during a trade when the pool can fill it. A failed burn swap leaves
that share in `pendingBurn` and emits `BurnDeferred`, while the trade, issuer fee and pool funding
complete. Anyone can retry any tranche with `burn(imdIn, minMargOut)`; quote a minimum output before
sending it. Failed or partial retries revert atomically. Pending burns cannot spend curve reserves
or handle escrow and wait for usable launch-pool liquidity; they are not swept to another recipient.

To claim a handle, tweet **exactly** the string returned by `claimMessage(wallet)` from that handle,
then call `requestClaim(handle, tweetId)`. The text explicitly assigns the payout wallet for this
Pages address and chain. An unrelated address mention, donation, warning, quote or retweet does not
qualify. The oracle still has five seats and quorum four; a valid answer pays escrow and reimburses
the asker if escrow covers the price, and a zero answer permits an immediate retry. A successful
claim is permanent. The panel and the specified signer remain trusted to read the tweet correctly.

Intake v1 has no failure callback: a refused or unanswered request spends the asker's price and
blocks another request until anyone abandons it after three days. Escrow recycling remains due
90 days after the first escrowed buy, including fees added just before that deadline, and never
runs while a claim is pending. After an expired claim is abandoned, recycling can run immediately
if the 90 days have passed. These are the specified deadlines, not rolling per-deposit windows.

Validation: `forge test --match-path 'test/Pages*.t.sol'`. The optional mainnet rehearsal is
`MAINNET_RPC_URL=<your RPC> forge test --match-path test/fork/PagesMainnet.t.sol`; it pins block
26178476 and uses a local Intake and signer solely for the live-IMD callback test. With no RPC
configured, fork suites explicitly skip and the rest of the repository tests run offline.

## Deployed (Ethereum mainnet, 2026-10-11)

IMD launch **#1283** (`univ4_hook`, job `9060a248-29ce-4683-b5d1-54fbc83cd49d`, deploy tx
`0x6ba7149c648529bdc043dae985611f827fbbe18e47b5dfd9add56a5e17a74e48`, block 26169583). All six audits,
the adapt step, the manifest and the Foundry tests were accepted; nothing parked.

| Contract | Address |
|---|---|
| `Marginalia` (MARG, 1,000,000,000 fixed) | `0xfa0efea559bde229031c2b0a219472316647759c` |
| `MarginaliaHook` (flags `0x20cc`, 23,916 B runtime) | `0xf0457dd0cf526686190e4f057ba19db14d34a0cc` |
| `MerkleDistributor` (swarm share) | `0x2d637b51f531fc408a079170832e91349c1eae18` |
| Router / Judge / Treasury / Pricer (launch #1240) | see `src/MarginaliaImpls.sol` |

Pool: MARG / IMD (`0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7`), fee 12500, tick spacing 60, on the canonical
v4 PoolManager. Launch record: `https://explorer.imd.fun/launches/01771823-5250-4aaa-a55e-da5c1afe1146`.

- **MarginaliaAnnex** (launch **#1384**, 2026-10-12): `0xd0c0d97aebe9194606bcc46ce56524eee4615543`, tx `0xd7a3ab9c6eec356c6655a6c70f36cc4810116672799403e30ca4510431442103`, block 26178192, deployed source commit `a0154db` of the launch repository `identity-md-launches/launch-1384-src-marginaliaannex-sol` (the swarm's adaptation of release snapshot `075adee1`; this tree carries that source and its three suites verbatim). Constructor wiring verified on-chain: hook, Intake, action and signer as above; STAMP 0.1, MARG_BUY 0.25, bond 0.25–10, MAX_ADMISSION_LIST 4; the IMD launch guard `0x784ff9a3…` is a venue by bits, the Kiln hook is not.

## How the pot pays

Every IMD accrual (stamps, sell fees, forfeits, treasury drips) splits at accrual time:

| Share | Pool | Paid to |
|---|---|---|
| 70% | the week's thesis prize | the panel's top three long-form theses, 50/30/20, after the week and its seven-day child grace, through `requestJudging(week)` and `payJudged(week)` |
| 30% | the day's writer refund | every non-retracted note of the day, equal split, capped at one stamp; `claimRefund(id)` after the day ends |

The score (difficulty-weighted, netted across right, wrong, broken, unproven and retracted calls, on every venue)
is reputation: no pool pays for it. That is deliberate. On any canonical pool an author can be the only LP and
trader and manufacture a right call for a stamp; a pool that paid by score would pay them (review finding
c7331916). With no such pool the number can be inflated but never cashed, and the venue is on every note for the
reader and the site to judge. A paid leaderboard, if one is ever run, is a campaign funded from the paying wallet's
retained MARG with published rules, outside the hook.

Unclaimed pools roll forward after 28 days (`sweep`). No pool pays for a price outcome or reputation score.
A week admits at most 120 theses and at most three per author (the size of the ranked head), including rebuttals.
A child call must arrive by its parent's seven-day deadline, even if nobody has settled the parent yet.
Judging can first draw its fee at `(week + 1) * 7 days + 7 days`, so every thesis gets its full grace.
The per-author cap limits one wallet's occupancy; it is not Sybil resistance.

## Deployment order

1. ✅ Contracts-only launch **#1240** (Ethereum mainnet, tx `0x93a1b0cce64e04d4bd7edd7b5fb6e6268b1fd5ab68fb5b990e66c56e972d71a3`,
   block 26163341): `MarginaliaRouter` `0x365CcB3cfBC430600485234F56FD5ECb23fd70D1`, `MarginaliaJudge`
   `0xC93460730a79a22282f063A0c6BA5E340Ac372b4`, `MarginaliaTreasury` `0xe2086012f5F9CC7cAECDBC70dE392e263aAe8481`
   (ownerless implementations that lock themselves in their constructors so only clones can be initialised, once,
   by the hook) plus the stateless `MarginaliaPricer` `0xEaff9B262341A0cB05579227e662BFE768A71cfb`. The on-chain
   runtime bytecode matches this tree's build (the judge differs only in its EIP-712 immutables).
2. ✅ The four addresses are pinned in `src/MarginaliaImpls.sol`.
3. Hook launch (`launch.json`, kind `univ4_hook`): the factory deploys the token and the hook; the hook's constructor
   clones the three implementations and initialises each with itself in the same transaction. The constructor is
   chain-state-free (the launcher rehearses constructors in an empty EVM): it reads no code at any address, and a
   codeless companion would revert on first use because every companion call expects return data.

Because the router is deployed, the `NoteParams` ABI it accepts is fixed; that is why a counter rides the existing
`parentId` field instead of a new one. `forge build --sizes` is the gate for the hook's runtime (EIP-170, 24,576) and
initcode (EIP-3860, 49,152) sizes; the mainnet-fork rehearsal (`test/fork`) runs against the live implementations
without etching.

## Build and test

Solidity 0.8.26, Cancun, via-IR, optimizer 200 runs, `bytecode_hash = "none"`. All dependencies are
vendored under `lib/` (versions in `dependencies.json`); no network is needed to build or run the unit tests.

```sh
forge build --sizes
forge test --no-match-path 'test/fork/*'
```

Without `MAINNET_RPC_URL`, the fork tests explicitly skip, including under plain `forge test`.
The fork rehearsal deploys through the real IMD LaunchFactory on an Ethereum mainnet fork, impersonating
the protocol's launch wallet, and then posts a note through the router:

```sh
MAINNET_RPC_URL=https://... forge test --match-path test/fork/MainnetLaunch.t.sol -vvv
```

## Launch

The implementations are live (launch #1240, above). The hook launch deploys `MarginaliaHook` with
`$poolManager, $token, $factory`, the `Marginalia` token, and the MARG/IMD pool at LP fee 12500; its `launch.json`
is written by the launch's manifest step. See `ADAPTATION.md` for the reproduced findings, changes and validation.

The Annex launch (kind `evm_contracts`) deploys one contract, `MarginaliaAnnex`, with the four static constructor
arguments the live hook already holds: the hook `0xf0457dd0cf526686190e4f057ba19db14d34a0cc`, the Intake
`0x1397434cd35e8a9C8aC312A61D3A285EB31dea56`, the action `bytes32("oracle.request@oracle-1")` and the oracle signer
`0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982`. The constructor stores them and reads no chain state. There is no
`launch.json` in this tree: the manifest step writes it. `test/Annex.t.sol` is the Annex suite. The independent review
of 2026-10-12 changed three rules there, all in `MarginaliaAnnex`: observations and checkpoints are refused while the
PoolManager is unlocked (no flash dump-observe-rebuy reading), a venue with no liquidity in range is read at its
standing price clamped to the pricer's range (no refund by pulling liquidity; the second review of 2026-10-12 replaced
the earlier priceless reading, which also forfeited a right call whose pool had sold out past its target, since v4's
`getLiquidity` is zero past the last tick of a range as much as on a pulled pool), and `post` takes a `baselineBound`
the author sets against a sandwiched baseline. The trust assumptions of the oracle-admission path (Intake v1, one
fixed signer, no failure callback) are stated in `AGENTS.md`.

Sealed notes: `seal(x, venue, hash)` commits to a note before it is posted. The seal pays one stamp up front
(non-refundable, so a seal is never a free option), prices the venue's BUY and SELL baselines at that moment, and
snapshots the author's X balance. The note is then posted through the router as usual, no sooner than 30 minutes
and no later than 6 hours after the seal (`SEAL_MIN`, `SEAL_MAX`); it settles against the sealed baseline, and a
sealed BUY call is refused if the author's X balance fell since the seal (position first, then seal). Between seal
and reveal, the author's key holders may read what was sealed off-chain; everyone else sees only the `Sealed`
event (author, X, venue). The hash is `sealHash(author, params)` over the router-derived venue, which is what the
hook receives (`router.validateVenue` gives it). A seal is stored per sealer, at `seals(sealKey(sealer, hash))`, and
records the X and venue it priced: a reveal uses only the author's own seal of the note's own X and venue, so nobody
else's seal can delay or price a note. A seal that lapses leaves its stamp in the pools and may be replaced by a fresh
seal of the same note; posting the note spends the seal, timely or lapsed.

Counters and duels: a thesis whose `parentId` is another author's open thesis is a rebuttal; it needs its own child
call like any thesis and then competes in the same weekly judged set. A call whose `parentId` is another author's
open call on the same token, from the opposite side, is a counter-call. No deposit moves between the two: each
settles on its own price and keeps or forfeits its own deposit, their scores move in opposite directions, and the
duel's outcome is the pair of `Settled` events (the link is in `NotePosted.parentId`), read off-chain. The keeper who
settles a wrong or broken call earns 10% of the forfeited deposit (`KEEPER_BPS`).

Before posting a price call, anyone calls `router.checkpointVenue(noteParams, venueKey)` for its
canonical venue. V3/v2 references must be the pool address zero-padded to 32 bytes; the hook refuses
high-byte aliases on both posts and seals. Its first checkpoint must be at least one hour old, from an earlier block, and at
most six hours old. Further checkpoints preserve the start and accumulate conservative extremes;
they cannot erase an honest reading. After expiry, checkpoint again and allow a new hour to elapse.
Theses (`targetBps == 0`) do not need price history. This warm-up uses on-chain timestamps; tests
advance the EVM clock and never wait in real time.

For v3/v2, the post baseline is the accumulator TWAP from the checkpoint to posting. For v4 and
the ETH/IMD hub leg, a BUY baseline uses the maximum of the window's readings and the current
price, and SELL uses the minimum. The immutable router/pricer store independent component extrema, so
a multi-leg baseline is a conservative bound and need not be a price observed at one instant.
At settlement the hook prices each complete v4 observation through the live pricer and takes the minimum
product for BUY or maximum product for SELL; it never combines legs from different observations.
V3/v2 still use the first-to-last accumulator TWAP multiplied by the adverse hub observation.
The one-hour minimum span is unchanged. Calls and checkpoint reads reject a v4 venue or hub with no active liquidity.

The oracle callback stores only the requested head of three ids, then filters and deduplicates them
when paid. A signed empty or entirely ineligible head pays no winners and rolls the whole remaining
thesis pool forward. Extra ranking entries beyond the requested head are ignored.

## Audit history

The swarm's four-specialist panel reviewed the whole repository during the first implementations launch
(job `0c08497a`, 2026-10-10) and merged 14 reproduced findings, led by a self-priced venue (any contract
answering `slot0()` could set a note's price) and a leaderboard sweep that paid twice. All are fixed in
commit `1e6388a`: every price venue and trade venue is now checked against the canonical Uniswap factories
(v3/v2) or recomputed from the full key with liquidity (v4) in the router, sweeps zero their pools, an
unanswered judging request can be retried after three days, quiet weeks' thesis pools sweep once the judge
confirms nothing is pending, implementations lock themselves against stray `init` calls, sells of pot MARG
require a whole fill with a slippage floor, and the Attested class can no longer be self-declared.

The relaunch of those fixes (launch 1217) was then parked by the audit judge on the one finding the first
round had not closed: `observe()` read spot, so a two-block pump → observe → unwind bought a settlement
for swap fees. v0.5 moved settlement into `MarginaliaPricer`: Uniswap v3 and v2 venues settle on the
time-weighted average between the first and last observation (their on-chain accumulators), v4 venues
and the ETH→IMD hub leg settle on the observation least favourable to the call, and the observations
must span at least an hour. Accumulator prices weight the elapsed time, and an honest observer can
pin the v4/hub extreme; sampled extremes do not measure prices between observations. Tests: `testTwoBlockPumpObserveUnwindSettlesWrong` (local),
`testTradeAndNoteOnUniswapV3` settles LINK on the live v3 accumulator (fork), `test/Pricer.t.sol`.

The second implementations review (2026-10-11) reopened the launch on eight reproduced findings; all are
answered in `.imd-responses.json` and listed in `ADAPTATION.md`. In short: a price that rounds to zero is
refused everywhere; forfeited MARG converts in tranches (`convertForfeits` sells the largest halving of the
pot the pool absorbs); a stranger's dust cannot void a SELL call (a tolerance rule, since replaced by no SELL
hold rule at all: see the third review below); an observation slot is never owned (a more adverse reading replaces the
latest entry; a favourable pump can be overwritten, while an adverse hostile reading remains); a note token whose `balanceOf` fails is "not
held" (VoidSold, never a refundable void); an unobserved call scores as wrong though its deposit returns;
a week holds at most 120 theses and refuses the 121st before taking anything; `abandonRequest` invalidates
an unanswered judging request after its deadline so a thesis pool is never swept from under a deliverable
answer; and an attestation must be about this chain. Two findings are disputed as design: any canonical
Uniswap pool is a venue (an author can be its only participant: see the limits below), and the adverse
extreme can be moved against a call by a paid round trip, which is the cost of the rule the launch asks for.

The third review (2026-10-10) reopened the launch on the self-priced venue, now reproduced as a loss path
(a wallet that is the only LP and trader of a hookless X/IMD pool settled a 100x call RIGHT at tier 3 and took
the capped 10% of the week's leaderboard pool for one stamp), and on the residual of the SELL hold rule (a
stranger's gift of the deposit's worth of X still voided a correct SELL call). Both are fixed: only a call
priced on the launch pool books a score (a call on any other venue still returns or forfeits its own deposit
and takes the writer refund, but books nothing and draws nothing from the leaderboard), and SELL calls have no
hold rule at all (any balance-growth rule is a stranger's transfer away from voiding a correct call; the BUY
hold rule is unchanged). The advisory `sqrt(2) == 2` is also fixed. See `ADAPTATION.md` and `.imd-responses.json`.

## v1 scope and known limits

- Price reads assume 18-decimal assets on both sides. Quotes other than IMD, ETH or WETH are refused.
  Calls and seals on IMD itself are refused: every price is denominated in IMD, so an IMD/IMD target is
  not falsifiable. Theses about IMD remain possible because they have no price target.
- v4 venues have no on-chain accumulator, so their baseline and settlement rely on sampled extremes rather than a TWAP. These require honest permissionless observations; time spacing alone cannot prove an unobserved price was held continuously. A
  single hostile observation can push a genuine call to WRONG by moving the pool against it, observing,
  and unwinding in one transaction. Later favourable readings do not remove it. On a thin pool, the
  swap cost may be below the keeper bounty. Replacements retain the slot's opening block, so they cannot
  continually postpone another observer's next slot; timestamps still record the actual reading time.
- Sells of MARG pay 3% through any router, or 1% plus the stamp through `sellWithNote` with a note and deposit attached.
  These are swap fees: single-sided liquidity that converts MARG into IMD as others buy is untaxed by
  the hook. Flags `0x20cc` deliberately have no liquidity callbacks. Third-party routers must send empty
  `hookData`; non-empty data is reserved for the Marginalia router's authenticated note format.
- Bonds are IMD, held as ERC-6909 claims: a noted buy sends `imdIn`, of which 0.1 is the stamp, 0.25 buys MARG and the
  rest (0.25 to 10 IMD) is the bond; a noted sell bonds the minimum off its IMD output. A right bond comes back as
  exactly that IMD; forfeits accrue to the pools at once (10% to the settling keeper). The hook never holds MARG
  claims and there is no pot sale: the deployed judge's `convertForfeits` finds `potMarg() == 0` and returns.
- The X trade leg supports v4 pools (including native-ETH pairs), v3 pools and v2 pairs; exact-input only.
- Quiet (un-noted) MARG sells are exact-input only: an exact-output sell through any router reverts
  (`NoteNeedsExactInput`). Exact-output buys are unaffected.
- `noteOf` returns a slim `NoteView`; the venue, text and timestamps are in the `NotePosted` event, which carries
  the ids, class, side, target, horizon, parent and text (price and deposit are read from `noteOf`).
- The implementation addresses in `MarginaliaImpls.sol` are the live launch-1240 deployments; the local tests etch
  rehearsal code at those same addresses, the fork tests use the live code.
- The action fee on follow trades, treasury conversion of ETH/USDC/USDT to IMD, the on-chain ERC-8004 agent
  badge (contract wallets are marked Agent), and attestation re-delivery are specified but not yet built.
- The judge binds an answer to the Intake request it paid for and to this chain id. The oracle's canonical
  question hash includes the resolved relative block window and is not `keccak256(questionBody(week))`;
  the immutable judge relies on the Intake to route the signed answer under the request it was bought for.
- Observations pay no reward. Only settling a forfeited bond earns 10%; absent sufficient observations,
  `VoidNoData` returns the bond and scores it as wrong. Mainnet gas can exceed that bounty.
- Refund eligibility is checked when claimed after the posting day. Retraction forfeits the entire bond
  and prevents a future refund claim, but does not claw back a refund already paid. Waiting until a
  90-day horizon to allow refunds would conflict with the daily refund and 28-day sweep schedule.
- Venue admission is "any canonical Uniswap pool with liquidity", and an author can be the only LP and trader
  of such a pool. A call priced there is a bonded claim that returns or forfeits the author's own deposit on
  price and moves a reputation score that no pool pays for. The site labels venues where the author is the
  dominant liquidity; the contract cannot see that and does not pretend to.
- SELL calls have no hold rule: they settle on price alone. BUY calls must keep their post balance.
- The hook's constructor reads no chain state (the launcher rehearses constructors in an empty EVM); the pinned
  implementation addresses are exercised by the mainnet-fork rehearsal instead.
