# cryptocourt — the ultimate plan

The court system this repository is named for, built on the governance layer that
already lives here. This is the buildable plan: the economics are settled (see
`COURTS_TOKENOMICS.md` and `COURTS_STRUCTURE.md` — the converged V4 spec), and
this document is how it becomes gno code.

## The rule for every package

**A `/p/` package earns its place by being reusable by other projects.** If the
only conceivable importer is cryptocourt's own realm, it is not a library, it is
realm code in the wrong directory. Every `/p/` below is something a completely
different gno project would want: a conditional-share ledger, a tick order book,
a fixed-window average. The court-specific glue — bonds, sessions, escrow, the
fee split, the governance wiring — lives in `/r/cryptocourt/*`, which is the one
worked consumer.

Each package is also held to two more bars: **gas-efficient** (measured against
the storage rules in `COURTS_STRUCTURE.md` — object count dominates, `[]byte` not
`[]T`, bptree not avl on hot paths) and **`/p/`-clean** (no crossing functions,
no realm state, takes an acting address rather than reading one — the same split
`grc20votes` already uses).

## What already exists (the governance half)

    p/cryptocourt/checkpoint/v0    a number's history, as of a sealed epoch
    p/cryptocourt/grc20votes/v0    the voting-token ledger (balances, delegation, PastVotes)
    p/cryptocourt/governor/v0      the proposal/kind/vote engine
    r/cryptocourt/govern           a worked governance consumer
    r/cryptocourt/offerer          an example kind

The court consumes `grc20votes` (its coin) and `governor` (its answerDisputes go
through a governor Kind). Three small additive changes to `governor` are needed,
none breaking its existing users (from `COURTS_STRUCTURE.md`, "Building it on the
governor"):

1. **Clamp, don't panic**, when the engaged/turnout denominator exceeds supply —
   the court deliberately hosts claims too big to decide.
2. **An optional per-proposal turnout interface**, so the court can feed the
   governor `max(5% supply, min(1×X̄, ⅓ votable))` instead of a flat bps quorum.
3. **Expose the snapshot** (engaged figure + epoch) for rendering.

## The new packages, bottom-up

Built in dependency order; nothing above is started until the thing below it is
tested to convergence.

### 1. `p/cryptocourt/twap/v0` — a fixed-window trailing average

A ring of one-byte (or small-int) samples over a rolling window, giving a
manipulation-resistant average of a series (price, open interest). Distinct from
`checkpoint`, which answers "what was it at epoch N" from unbounded history; this
answers "what has it averaged over the last W" from a fixed, cheap ring.

- **Reusable?** Yes — any on-chain market wanting a TWAP oracle that a one-block
  spike can't move. This is the standard AMM-oracle primitive.
- **Court uses it for:** the trailing-average X that quorum and the answer
  threshold read (kills flash-inflation), and the pre-answer price for
  close-without-decision.

### 2. `p/cryptocourt/cshares/v0` — a conditional-share ledger

Binary (extensible to N-outcome) conditional shares over a collateral token: mint
a complete set for one unit of collateral, redeem a matched set back, transfer
shares, and pay out on resolution. Collateral conservation is the invariant.

- **Reusable?** Yes — this is the core of any prediction market or conditional
  token, independent of how outcomes get resolved.
- **Court uses it for:** every claim's YES/NO positions; "open interest X" is this
  package's outstanding-set count.

### 3. `p/cryptocourt/tickbook/v0` — a tick-quantised order book

100 price ticks on a 0.01 grid, one aggregated quantity per (side, tick), a pair
of 64-bit occupancy bitmaps per side, taker walks crossed levels by bitmap scan.
Integer-only, no LP, O(levels crossed). Pull-settled makers.

- **Reusable?** Yes — a gas-bounded CLOB for any two-sided market on a bounded
  price grid, the thing every gno market currently lacks.
- **Court uses it for:** the market on each claim (`COURTS_TOKENOMICS.md` §3.1).

### 4. `r/cryptocourt/court` — the court realm (the consumer)

Not a library. Ties the above to `grc20votes` and `governor`, and holds the
court-specific rules: the one-way curve, claims (title + append-only body),
answers and their `min(50%X, cap)` bond, answerDisputes and their
`max(gov-min, 20%X)` bond, weekly settlement sessions + escrow, the adjudication
and settlement fees, the directory, and `Render`. Governance-set parameters
(`COURTS_TOKENOMICS.md` §9a) with the realm's hard bounds.

## The web interface (parallel track)

An overlay outside gno.land that reads chain state and renders the polished view
(the ten wireframe screens: directory, court, map, folder, claim, vote, watching,
order ticket, portfolio, chain-render). The contract it may assume is fixed by
`COURTS_STRUCTURE.md` ("The chain render"): **the chain carries all the
information; the overlay only makes it prettier.** So the overlay is built against
the realm's read methods and every action is a `txlink`, never a private API.
Started alongside the packages, not after.

## Process for each `/p/` package

1. **Converge the design** with subagents, and answer *does this deserve its own
   `/p/`?* — if the honest answer is no, fold it into its consumer.
2. **Review the design** against `docs/resources/gno-interrealm-v2.md` and
   `gno-security-guide.md` before writing code.
3. **Implement**, gas-conscious, `/p/`-clean.
4. **Review and test to convergence** with subagents — filetests and `gno test`,
   adversarial where money or authority is involved.
5. Only then start the next package.

## Status

- [x] Governance layer (`checkpoint`, `grc20votes`, `governor`) — exists.
- [x] `p/cryptocourt/twap/v0` — built, 14 tests, adversarially reviewed (caught a mature-fabricated-zero bug)
- [x] `p/cryptocourt/cshares/v0` — built, 13 tests, reviewed (conservation airtight; 3 hygiene fixes: freeze-on-resolve, approval-key delimiter, range-check)
- [x] `p/cryptocourt/tickbook/v0` — built, 23 tests, design converged with a subagent. No-custody CLOB: realm escrows on Place, book records; Take dirties ONE packed object regardless of levels crossed; makers pull-settled by a per-tick multiplicative survival-fraction accumulator with an epoch counter for tick reuse (an additive per-original-unit accumulator over-credits the partially-filled — the bug the tests caught). Non-crossing guard forces Take-before-rest. Self-contained: the 128-bit MulDiv is inlined, so it depends only on bptree.
- [x] `p/cryptocourt/curve/v0` — built, 10 tests (incl. a 4000-case no-over-issue fuzz + the 128-bit large-value path). Linear one-way bonding curve with a **reciprocal slope** `p(s)=s/D` (a numerator slope overflows 128-bit at the supply cap — the 3-subagent plan review caught this). `Cost` rounds UP (128-bit via `bits.Mul64`); `Minted` floors via a binary-search 128-bit isqrt candidate then **re-verifies ±1 against `Cost`**, so an isqrt off-by-one can never mint below backing. The realm holds a monotonic `curveMinted` position; burns/redeems never move it.
- [x] governor's three additive changes — done, +6 tests. **#1** clamp
  `engaged>total` (was a panic) so a court can host claims too big to decide;
  **#2** `ProposeWithQuorum(…, quorumFloor)` for a consumer-computed absolute bar
  (`Propose` unchanged and passes 0; the floor is snapshotted at Propose and
  Render shows the count, not a bps %); **#3** `Snapshot(id) → (engaged, epoch)`.
  Plus the two deferred audit fixes: bound `total ≤ MaxInt64/bps` at the Propose
  door (F1), and document the inclusive-threshold tie-at-5000 (F2). All strictly
  additive — govern/offerer behaviour unchanged (one govern test updated to assert
  the new clamp instead of the old refusal).
- [x] `r/cryptocourt/court` — V1 BUILT, 10 files, 22 tests, make realm-test green.
  court/params + directory + StartCourt; buy (one-way curve); claim (append-only
  body + deposit-escrow); market (MintSet/RedeemSet, priceScale=100, 20% OI ceiling,
  OI-twap); book (RestSell/RestBid/TakeBuy/TakeSell/Collect/CancelOrder + ask/bid
  escrow pools + price-twap); answer (bond, answerability, pre-answer snapshot);
  dispute (Kind@5001, OpenDispute/VoteDispute/ResolveDispute-from-Tally/Finalize/
  RedeemWinning/RedeemClosed); session (undisputed settlement); directory (tiers,
  sanitized slugs); render (sanitized pages, sealed live tally).
- [x] **Fee split — BUILT** (`fees.gno`, +fields/wiring, 31 court tests, make check green).
  The adjudication fee (60% to all voters by weight, 40% to the verdict-side weight,
  `min(3% collateral, 200 GNOT/CoinPrice)`, pull-claimed per voter) and the settlement
  fee (the answerer's half of ~1%, pull-claimed), skimmed from the winning collateral so
  `RedeemWinning` pays `floor(won·(collateral−fee)/S)`; mint/redeem freeze at the
  provisional verdict. Design converged across 3 independent passes; 3 spec-settled
  judgment calls (marginal-price cap, freeze, answerer's-half). Adversarially audited
  SOUND (11 probes, no conservation/auth/overflow defect); one low value-stranding fixed
  (all-abstain-uphold folds the 40% into participation). 32 court tests, make check green.
- [x] **X̄-scaled escrow window — BUILT** (`escrowWindow` in dispute.gno, +1 test, 33 court
  tests, make check green). `clamp(1 week + 1 day per 500 GNOT-equivalent of the claim's
  open interest, 1 week, 3 weeks)`, set at resolution when the market is frozen (so it
  can't be gamed; the 1-week floor bounds any attempt). X converts to GNOT at the marginal
  price (same rule as the fee cap); 128-bit division, day-count clamped before scaling to
  blocks. Timing-only — no conservation impact.
- [x] **Reopen / bond-doubling / 3-round-close — BUILT** (dispute.gno reopen guard + `base
  << failedRounds` + failed-round/close machine, fees.gno idempotent charge + `feeProposalID`,
  session/render updates; 37 court tests, make check green). Design converged across 3
  independent passes; two forks settled by majority+spec (reopen gate = `now < escrowUntil`;
  reopen scope = any verdict, with `feeProposalID` fixing a latent fee-attribution bug C
  caught in A). A provisional verdict reopens during escrow; each failed reopen doubles the
  bond (sybil-proof); three failed rounds close at the pre-answer price (fee voided); escrow
  clock set-once; answer bond & adjudication fee each disposed once; every bond disposal
  guarded `>0` (grc20votes rejects a zero transfer). Adversarial reopen-flow audit in
  progress. **All four deferred economics increments are now built.**
- [x] **Conservation audit of the court money flows — DONE.** An adversarial two-ledger
  audit (probes run, ranked findings) confirmed the deep invariant: no path creates CC
  or GNOT, and the escrow **cannot go insolvent** — every payout is ≤ a matching prior
  inflow, GNOT is strictly one-way, bonds net to zero per branch, burns respect the
  monotonic curve. The weakness was never leakage but **stranding** (value trapped in the
  over-funded escrow), all failing CLOSED. Three fixed, each with a regression test (26
  court tests, green): **[HIGH]** book fills/rests stranded once `Finalize` resolves the
  claim — the share-settlement legs used `cshares.Transfer` (open-only), so a bid-maker's
  filled winning shares could not be collected post-resolution; added `cshares.Reclaim`
  (settlement, status-agnostic) and routed `Collect`/`CancelOrder` share legs through it
  (`Transfer` stays open-only, still blocking post-resolution *trading*). **[MED]** the
  court-wide OI counter only ratcheted up (RedeemSet dropped it, resolution never did) →
  `Finalize` now releases the claim's OI. **[MED]** the claim deposit had no return path →
  `Finalize` now refunds it to the depositor. **[false]** "use `banker.OriginSend()`" —
  that symbol does not exist; `unsafe.OriginSend()` under `IsUserCall`+`IsCurrent` is the
  sanctioned pattern (noted in buy.gno so it isn't re-flagged).
- [x] **web overlay — V1 BUILT** (`web/index.html`, self-contained, no build/deps). Reads a
  deployed court over ABCI (`vm/qrender` for the directory/docket — the chain's own lists —
  and `vm/qeval` for scalars/positions), with a faithful offline demo dataset so every screen
  and state renders without a node. Screens: directory · court (stats + the four-things primer
  + docket) · claim (market with CVD-safe YES-blue/NO-orange, price sparkline, and the order
  ticket that answers "what if it never resolves") · your page (positions by address) · what
  needs you (answers on claims you hold, flagged against your side) · the chain-render (screen
  10) · how-it-works. Honors the interface contract: titles verbatim, **live tally sealed while
  a vote is open**, verdict-route shown, backing beside price, wall-clock time, untrusted text
  framed/escaped, every action a gnoweb `$help` txlink. Theme-aware (both light and dark
  designed); rendering verified headless (no runtime errors, both themes). Deferred V2 screens
  (map, sections, in-session vote) await the realm exposing them.

## Systematic audit — DONE (see `AUDIT.md`)

All six `/p/` audited (checkpoint + grc20votes by direct read; twap, cshares,
tickbook, governor by adversarial agents that verified each finding with a
concrete failing input). Outcome:

- **checkpoint, grc20votes** — sound, no changes.
- **twap** — 3 findings fixed (maturity-against-uncapped-window, overflow-checked
  sum, a freshness contract + `StaleBy` for the persist-forward tail); +5 tests.
- **cshares** — 3 findings fixed (MintSet fail-atomic, length-prefixed approval
  key, `Transfer` auth note); +2 tests.
- **tickbook** — 2 CRITICAL fixed (Cancel over-refund capped at tracked resting;
  survival fraction widened to uint64@1e18 + tick-resting cap so it can't freeze);
  +4 tests. Also dropped the pmkt dependency.
- **governor** — audited safe to consume; 2 fixes (bound `total ≤ MaxInt64/Bps`;
  document the tie-at-5000) DEFERRED into the additive-changes phase below, since
  they touch the same code.

`make check` is green: 34 citations hold, doc-numbers match, storage ceilings
pass, all packages + the two consuming realms test clean, gofmt + vet clean.

Cross-cutting obligations the audit surfaced for `r/cryptocourt/court` are listed
at the end of `AUDIT.md` (observe-twap-on-every-change + `StaleBy` gating; a
tickbook minimum order size; drive the governor with `grc20votes` and
`ThresholdBps>5000`; sweep escrow-pool dust).
