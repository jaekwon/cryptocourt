# cryptocourt `/p/` — systematic audit

One adversarial pass per package, hunting the failure modes money and authority
primitives actually have: conservation/solvency, integer rounding direction,
overflow, accumulator precision, `/p/`-safety (borrow rule #2 — no interior
pointer, no laundering callback), and whether the documented realm contract holds.
A finding is **CONFIRMED** only with a concrete failing input; otherwise
**PLAUSIBLE** with the reasoning. Each package also gets a plain-English-docs and
test-coverage check.

Packages: `checkpoint`, `grc20votes`, `governor` (the governance half the court
consumes), and the three new ones, `twap`, `cshares`, `tickbook`.

## Status

| Package | Auditor | State |
|---|---|---|
| checkpoint | direct read | ✅ done — sound |
| grc20votes | direct read | ✅ done — sound |
| twap | adversarial agent | ✅ 3 findings, all fixed (+5 tests) |
| cshares | adversarial agent | ✅ 3 findings, all fixed (+2 tests) |
| tickbook | adversarial agent | ✅ 2 CRITICAL, both fixed (+4 tests) |
| governor | adversarial agent | ✅ 2 fixes applied with the 3 additive changes (+6 tests) |

---

## checkpoint — SOUND

`Series` is a value field holding a number's history: two points inline (`cur@e0`,
`prev@e1`), older points paged into a shared `Archive`. The court reaches it only
through `grc20votes`, but it is the base of the whole snapshot story.

- **Value semantics resolved.** Every method (`SetAt`, `Value`, `ValueAt`,
  `Since`) has a POINTER receiver, so `a.votes.SetAt(...)` called without
  assignment mutates the field in place (the field is addressable through
  `*account`). The plausible "value receiver silently discards the checkpoint"
  bug does not exist.
- **Roll/floor logic correct.** Traced first-write, same-epoch coalesce, the
  `e1==0` sentinel path, and the roll into the archive; `ValueAt` returns `cur`
  for `at>=e0`, `prev` for `at>=e1` (covering the `e1==0 → 0` case exactly), and a
  reverse-scan floor query otherwise. Each checked with concrete epochs.
- **Key isolation is prefix-safe.** A key's page range is `[key+Sep,
  key+Sep+be32(page)]`. Because `Sep` (`\x00`) is refused inside any key
  (`mustBeUsable`), a longer key `key+x` always sorts ABOVE the range end (its
  byte at that position is > 0), so one series' floor scan can never read another's
  pages. Verified against both `key` ⊃ prefix and `key` ⊂ prefix cases.
- **Sentinels defended loudly.** Epoch 0 refused (the unused-slot sentinel);
  backwards clock refused (a test-harness height reset is the only real trigger).
- **Contract dependency to lock in tests:** correctness rests on bptree
  `ReverseIterate(start, end)` being descending with `end` inclusive. The test
  suite (523 lines) should assert this directly so a bptree change can't silently
  shift the floor query.
- **Minor (not a bug):** `page` holds parallel `[]uint32`/`[]int64`. If gno stores
  these as TypedValue arrays (~40 B/elem) rather than packed runs, the archive
  (cold path, ≤32 entries/page) costs more than the doc implies. Worth confirming;
  a `[]byte` pack is the fallback. No correctness impact.

## grc20votes — SOUND

The voting-token ledger: GRC20 balances plus a self-defaulting delegation and a
per-holder checkpointed voting series.

- **Conservation holds.** Σ votes = Σ balances = `total` across every mutation:
  mint credits the delegatee, burn debits it, transfer moves both legs by the same
  amount, and delegation moves `balance` from old delegatee to new — each
  conserves the sum. So the doc's load-bearing claim — Σ `PastVotes` = `PastTotal`
  at any sealed epoch — actually holds (supply is checkpointed on mint/burn;
  transfers leave it unchanged and don't need to).
- **Anti-flash-loan is an invariant, not a convention.** `mustBeSealed` panics for
  `at==0` or `at>=Epoch()`, so weight can never be read for the epoch a vote is
  cast in; a balance borrowed within a block can't be voted and returned.
- **`/p/`-clean.** Every field unexported; no method returns a `*account`, the
  `*bptree`, or any interior pointer (borrow rule #2 respected); no method takes a
  callback (nothing to launder). Authentication is correctly pushed to the realm,
  which passes the acting address.
- **Overflow capped at the source.** `MaxSupply = MaxInt64/Bps` enforced at mint,
  so a governor's `yes*Bps` tally cannot overflow — the reason the cap exists.
- **Minor (harmless):** `TransferFrom` writes the reduced allowance before `move`
  validates `amount>0`; a non-positive amount panics in `move` and the atomic
  revert rolls the allowance write back, so no allowance is lost or doubled. Could
  validate earlier for cleanliness; not a defect.

Docs for both packages are exemplary plain English — they explain the *why* (the
gno storage model, the OZ contrast, the sentinel hazards) at the point a reader
meets each decision. No rewrites needed.

---

## twap — 3 findings, all fixed

A fixed-window trailing average used to gate votes and price payouts, so a wrong
answer is a money/authority bug.

- **F2 (HIGH) — window wider than the ring fabricated maturity. FIXED.** Maturity
  was measured against the window *capped* to the ring, so `Average(_, 2·window)`
  on a full ring returned the 1-window average stamped mature. Now measured
  against the uncapped `want`, so an uncoverable window reads immature.
  Regression: `TestWindowWiderThanRingIsImmature`.
- **F3 (MEDIUM) — the window sum could wrap to a negative average, stamped mature.
  FIXED.** The sum is now `overflow.Add64`-checked and panics loudly (a negative
  "average" handed to a quorum is the dangerous failure). Trips only under a large
  ring of large values (per-minute buckets at the supply cap). Regression:
  `TestOverflowingSumIsRefused`.
- **F1 (HIGH) — a stale tail lets a lone last-spike become the whole average while
  `mature` stays true. FIXED via contract + tool.** The primitive is correct
  *under a freshness contract*: an empty tail carries the last value forward, so
  the caller must Observe on every change (or at the read height). That contract
  is now stated hard in the package and `Average` docs, and a new `StaleBy(height)`
  reports how far a read has drifted from the newest observation so a caller can
  gate on recency. Regression: `TestStaleTailIsFlaggedByStaleBy`.
  **Court obligation (enforce when building `r/cryptocourt/court`):** Observe OI
  and price on every change, or immediately before any gating read.
- Coverage added: aliasing (value-semantics), `width>1` bucketing, boundary
  maturity. Docs: the oversold flash-resistance claim now carries its precondition.
- **Verdict:** the maturity flag is trustworthy *iff* the caller honors the
  freshness contract — now documented and checkable, not assumed.

## cshares — 3 findings, all fixed

The collateral-conserving conditional-share ledger.

- **F1 (CONFIRMED) — MintSet credited before validating. FIXED.** It wrote every
  outcome's balance, then checked supply overflow — so a caller with a recover in
  its stack could commit a half-credited claim and break conservation. The
  overflow check is hoisted above the credit loop (RedeemSet's discipline), which
  also covers every per-outcome credit for free. Bounded to unreachable magnitudes
  and a misbehaving realm, but a real atomicity defect. Regression:
  `TestMintSetIsAtomicOnSupplyOverflow`.
- **F2 (CONFIRMED collision) — approval-key delimiter forgeable. FIXED.** The
  `owner+"\x00"+operator` key collided if an address held a NUL
  (`("a\x00b","c")` == `("a","b\x00c")`). The owner is now length-prefixed, so the
  split is unambiguous for any bytes — no trust in address content. Regression:
  `TestApprovalKeyNulBoundaryDoesNotForge`.
- **F3 (footgun) — `Transfer(from,…)` authenticates nothing. FIXED via doc.** This
  is the intended /p/ split, but the per-method doc now says plainly that the realm
  MUST verify `from` before calling.
- Clean (agent-probed): conservation across mint/transfer/partial-redeem/resolve/
  redeem-winning; no double-pay; key encoding; borrow-rule-#2 encapsulation;
  lifecycle guards; the `winner=-1` sentinel.
- **Verdict:** conservation airtight in the pure-logic path; the atomicity crack
  closed; genuinely /p/-clean.

## tickbook — 2 CRITICAL, both fixed

The no-custody order book — the most intricate package.

- **F1 (CRITICAL) — Cancel over-refunded and drained the escrow pool. FIXED.**
  `refund = qty − floor(fill)`, uncapped: a sub-share fill floored to 0 refunded
  the whole order while a taker had already taken shares
  (`Place(3)/Take(1)/Cancel` → refund 3 out of a 3-escrow after 1 was taken → pool
  −1; a single actor drained 1 share/cycle). The refund is now capped at the
  resting the book tracks exactly, so taker + refund never exceeds escrow; the
  floored dust stays in the pool (safe direction). Regression:
  `TestCancelCannotOverRefund`.
- **F2 (CRITICAL) — the survival fraction froze past 1e9, unbounding F1. FIXED.**
  `surv` was a uint32 scaled by 1e9, so a one-share fill on a tick larger than 1e9
  shares left it unmoved — every maker read `filled=0` (coin stranded) and the
  over-refund became the whole taken amount. `surv` is now a uint64 at 1e18 scale,
  and a tick's resting is capped at `accScale`, which guarantees the fraction
  always resolves a one-share fill (surv ≥ resting by construction). Regressions:
  `TestLargeTickDoesNotFreezeSurv`, plus a pool-solvency invariant across
  interleaved place/take/cancel (`TestAskPoolSharesStaySolvent`) and a
  resting-bound guard.
- Clean (agent-probed): pure Take→Collect conservation, epoch reuse, the
  non-crossing guard, overflow (128-bit MulDiv), /p/-safety, DoS bound.
- **Verdict:** solvency now airtight (refund capped + no freeze) and genuinely
  /p/-clean. A consuming realm should set a minimum order size so the ≤1-share
  dust is negligible.

## governor — audited; 2 fixes APPLIED with the 3 additive changes

The vote engine the court consumes as final arbiter. Both audit fixes were applied
together with the three additive changes (they touch the same code), +6 governor
tests, all green. The one behaviour change (clamp) required updating one govern
test that had asserted the old refusal.

- **F1 (PLAUSIBLE) — tally overflow with a custom electorate. FIXED.** The Propose
  door bounded `engaged≤total` but not `total ≤ MaxInt64/bps`; `grc20votes` caps
  mint at exactly that, so it was latent for the real consumer, but a *custom*
  electorate (which change #2 encourages) could overflow `yes·bps` and flip an
  outcome. Now bounds `total ≤ maxWeighable` (= MaxInt64/bps) at the door and
  states the ceiling in the `Electorate` contract. Regression:
  `TestSupplyPastTheCeilingIsRefused`.
- **F2 (config footgun) — a 50-50 tie PASSES at `ThresholdBps=5000`. FIXED (doc +
  test).** Correct by the documented inclusive `≥`, but undocumented; a court
  wanting a strict majority must set 5001+. Documented on the `ThresholdBps` field.
  Regression: `TestTieBoundaryAtThreshold` (and the all-abstain bug now has
  `TestAllAbstainDefeats`).
- **The three additive changes — IMPLEMENTED, all additive:** (1) clamp
  `engaged>total` (was a panic); (2) `ProposeWithQuorum(…, quorumFloor)` — an
  optional absolute bar, snapshotted at Propose, with `Propose` passing 0 and
  Render showing the count; (3) `Snapshot(id) → (engaged, epoch)`, a scalar copy.
  govern/offerer behaviour is unchanged (one govern test updated to assert the
  clamp). Regressions: `TestEngagedAboveSupplyIsClamped`,
  `TestProposeWithQuorumRaisesTheBar`.
- Clean (agent-probed): quorum/threshold boundaries, all-abstain guard, no
  double-vote, atomic anti-flash-loan snapshot, sub-realm Kind dispatch (no
  `chain/runtime/unsafe`, no `*Governor` escape, unexported-`builtin` gate),
  reentrancy latch, lifecycle, batch atomicity via abort-rollback.
- Coverage to add in the changes phase: tally boundaries (tie/quorum), all-abstain
  (a past bug with no regression test), `batch.gno` (untested), the latch.
- **Verdict:** safe for the court to consume with `grc20votes` and
  `ThresholdBps>5000`; the three changes are safe with the noted constraints.

## Round 2 — security / gas / docs (five adversarial agents, all six packages)

A second pass on a different lens than round 1 (which was correctness/
conservation): gno-interrealm-v2 + security-guide compliance, gas efficiency
(per-op object/key counts against the storage model), and plain-English docs.

**Security: no vulnerabilities in any package.** All six confirmed clean — no
crossing functions, no interior-pointer leaks (borrow rule #2), no Apply-class
callback surface, correct value-typed `address`, no `chain/runtime/unsafe`. The
no-custody contracts (tickbook escrow pools, cshares "realm settles coin")
verified airtight for a compliant realm; governor's just-added code
(ProposeWithQuorum/Snapshot/clamp) verified safe at every boundary.

**Gas fixes applied:**
- **cshares** — repacked a holder's whole per-claim position into ONE key
  (`(id,holder) → packed []int64`) instead of one key per outcome, so a binary
  MintSet dirties **1** share leaf, not 2 (~247,600 gas saved per mint on
  high-holder claims — the court's common case). Plus a `from==to` self-transfer
  short-circuit. +2 tests (self-transfer no-op, per-outcome independence).
- **checkpoint** — repacked the archive `page` from `[]uint32`+`[]int64` (gno
  stores these at ~40 B/elem) to one packed string at **12 B/entry** (~3× smaller
  locked deposit), keeping the one-object-dirty append. Matters for long-lived
  high-frequency keys (supply, heavy accounts).
- **twap** — `Average` now reads the `buf` string directly instead of allocating a
  `[]byte` copy, so the Render/read hot path is allocation-free.
- **tickbook** — added a `Side` validation guard (a bad side was silently coerced
  to Ask); gas re-confirmed optimal (Take dirties exactly one object). +1 test.
- **governor** — added `QuorumFloor(id)` getter (the website needs it to render a
  floored proposal's bar); the new `quorumFloor` field confirmed free (rides the
  proposal object).

**Docs sharpened** across all packages — most notably two comments that actively
contradicted the code (tickbook `maxLevels` "combined visit budget" → it's a
FILLED-level budget; checkpoint `page` "two packed runs" → it was 40 B/elem
TypedValues, now genuinely packed) and several that assumed hidden context
(twap value-not-object is a GAS choice not a safety one; `Load`'s validate-shape/
trust-base-last contract; cshares uniform auth + return-value contracts).

**Verification:** `make check` green — 34 citations, doc-numbers, storage ceilings,
all six packages + both realms, gofmt + vet. COURTS_STRUCTURE.md storage numbers
updated (tick 16→20 B, checkpoint entry 16→12 B). A convergence pass adversarially
re-verifies the two repacks (the only new logic).

## Cross-cutting obligations for `r/cryptocourt/court`

Carried forward from the audit so they are not lost:
1. **Observe twap on every OI/price change** (or immediately before a gating
   read), and gate flash-sensitive reads on `StaleBy` — the freshness contract.
2. **Set a minimum order size** on tickbook so ≤1-share dust is negligible.
3. **Drive the governor only with `grc20votes`** (or an electorate that caps supply
   at `MaxInt64/Bps` and keeps `engaged≤total`), and set `ThresholdBps>5000` for a
   true majority.
4. **Escrow pools:** the court owns the ask/bid pools; a periodic sweep of the
   accrued (safe-direction) dust to the treasury keeps them tidy.

## Money-conservation audit of `r/cryptocourt/court`

An adversarial two-ledger audit of the court's money flows (GNOT treasury + CC
escrow), run with probe tests against every branch. **Verdict: conservation is
fundamentally sound** — no path creates CC or GNOT; the escrow **cannot go
insolvent** because every payout is ≤ a matching prior inflow and the `/p/`
primitives enforce global conservation structurally (grc20votes Transfer/Mint/Burn,
cshares set/redeem, the monotonic curve). GNOT is strictly one-way (Buy is the only
intake, the court's own address is barred), bonds net to zero on every dispute
branch (overturn / uphold / failed-quorum), and burns respect the curve.

The weakness was never leakage but **stranding** — value that should return to a
user got trapped in the (always over-funded) escrow. All three findings fail
CLOSED, so none is a theft; each is a real loss of funds or of liveness, and each
is fixed with a regression test (26 court tests, green).

- **[HIGH] Book positions stranded once a claim finalizes.** The share-settlement
  legs in `Collect`/`CancelOrder` used `cshares.Transfer`, which refuses a resolved
  claim (`mustOpen`). `Finalize` is permissionless, so the instant it resolved a
  claim a bid-maker's *filled winning* shares (sitting in escrow, uncollected) could
  never be pulled out — `Collect` aborted and `RedeemWinning` paid 0; ask-makers'
  unsold shares stranded identically. **Fix:** added `cshares.Reclaim` — a
  settlement move that is status-agnostic (`mustGet`, not `mustOpen`) — and routed
  the escrow→maker share legs through it. `Transfer` stays open-only, so it still
  blocks post-resolution *trading* (Rest/Take); only settlement crosses the line.
  Regressions: `TestFilledBidRedeemsAfterFinalize`, `TestUnsoldAskReclaimsAfterFinalize`.
- **[MED] Court-wide OI counter never released.** `c.oi` rose on `MintSet` and fell
  only on `RedeemSet` — resolution never dropped it, so a resolved-and-redeemed
  claim kept consuming the court-wide OI ceiling forever, eventually bricking mints
  on *every* claim. **Fix:** `Finalize` releases the claim's OI (`c.oi -= claimX`)
  before locking the shares. Regressions: `TestFinalizeReleasesOIAndRefundsDeposit`,
  `TestMintUnbricksAfterFinalize`.
- **[MED] Claim deposit had no return path.** `OpenClaim` escrowed the anti-spam
  deposit against the depositor, but nothing ever refunded it. **Fix:** `Finalize`
  refunds it to the depositor (out of escrow, where it sat untouched). Regression:
  `TestFinalizeReleasesOIAndRefundsDeposit`.
- **[false alarm] "use `banker.OriginSend()`" in buy.gno.** That symbol does not
  exist — `OriginSend()` lives only in `chain/runtime/unsafe`, and reading it under
  `IsUserCall`+`IsCurrent` is the sanctioned payment pattern (what AGENTS.md flags is
  `unsafe.PreviousRealm`, which buy.gno does not use). Left as-is with a note so it is
  not re-flagged.

**Verification:** `make check` green — citations, doc-numbers, storage ceilings, all
seven packages + three realms (court now 27 tests), gofmt + vet. The one primitive
touched (cshares gained `Reclaim`; `move` no longer self-checks status, its two
callers `Transfer`/`TransferFrom` now guard `mustOpen`) re-passes cshares' own
no-trading-after-resolve tests.

**Re-verified to convergence.** A second, independent adversarial pass targeted only
this diff (8 probes: double-finalize, OI over-release, `Reclaim`-as-trading-bypass,
double-collect, claimX=0 finalize, and end-to-end escrow solvency on both the
undisputed and disputed→overturn paths). All behaved exactly as the fixes intend;
escrow drains to exactly 0 and ΣCC is conserved on every path. It confirmed the OI
release is exactly-once and exactly-right (only Mint/Redeem/Finalize write `c.oi`;
`mustOpen` stops both post-resolve, so no double-touch; the ≥0 clamp is
safe-direction), the deposit refund exactly-once and solvent (escrowed only at
`OpenClaim`, refunded only at `Finalize`, then zeroed; `Finalize` is the sole caller
of `Resolve`/`CloseAt`), and that `Reclaim` cannot become a trading move (every
call-site pins `from = c.escrow`; it fails closed if escrow lacks the shares). One
benign, pre-existing observation — `RestBid` had no status check, so a bid could rest
(inertly, fully refundable) on a resolved claim — was hardened out with an explicit
`mustTradeable` guard on all four trading entrypoints (+1 test), making the closed
market one obvious check rather than an emergent property of each leg.

## The fee split (adjudication + settlement) — design & implementation

The two fees (`adjFeeBps`, `adjFeeCapGNOT`, `settleFeeBps`) were dead params; this
increment wires them in. Design **converged across three independent passes** (the
prescribed process for money-critical work): all three produced the same architecture
and the same conservation proof; three judgment calls were settled from the spec.

**The mechanism.** A DISPUTED claim that reaches a decision pays an adjudication fee —
`min(adjFeeBps·collateral, adjFeeCapGNOT/CoinPrice)` — split 60% to everyone who voted
(by weight) and 40% to the weight that voted with the verdict. An UNDISPUTED claim pays
a settlement fee — the answerer's half of `settleFeeBps·collateral` — to the answerer.
A claim pays exactly one, or none (failed-quorum and close-without-decision pay
nothing). Both are skimmed from the WINNING side's collateral, held in the same escrow,
and PULLED (`ClaimAdjFee` per voter, `ClaimSettleFee` by the answerer) — resolution
never iterates a holder set. `RedeemWinning` now pays `floor(won·(S·priceScale −
feePool)/S)`; the fee is computed ONCE at the resolution step from the winning-share
supply `S` frozen there (`market.gno` freezes mint/redeem the moment a verdict is
provisional — the spec's "the money is slow / collateral unlocks after escrow").

**Load-bearing correctness.** Every value leaving escrow floors, so rounding dust only
ever stays in the pool. Each voter's weight comes from `governor.VoteOf`, whose stored
weight is exactly what the tally summed — that equality is what makes `Σ floor(pool·w/W)
≤ pool` airtight. New invariant: escrow drains to bounded dust ≥ 0 and is never
insolvent, on any interleaving of redeems and claims. Not farmable: a self-dealer gets
their own collateral back minus dust, and the flat GNOT cap drives a third-party skim's
yield → 0 as the court grows (price rises monotonically on the one-way curve, so the cap
only shrinks while the coin needed to sole-vote grows).

**Three judgment calls, settled from the spec.** (1) The cap converts at the curve's
MARGINAL price (`CoinPrice`, tokenomics §9 line 693-694 — "flat GNOT-equivalent figures
convert at the marginal price"), not `Backing` (= half of it). (2) Mint/redeem freeze
at the provisional verdict (§3.6 "collateral unlocks after an escrow period"), which
also stops a matched-set holder exiting at par to dodge the fee. (3) The settlement fee
is the answerer's HALF of ~1% (§3.6a "half to the answerer, half to the roll"; §9 defers
the roll's rail), so winners keep the roll's half — forward-compatible, no V2 regression.

**Adversarially audited — SOUND.** An independent 11-probe audit of the new fee flows
found NO conservation, authorization, or overflow defect: escrow stays solvent on every
interleaving of redeems and claims (winners + fees ≤ collateral), the pull bound is
airtight (`VoteOf` returns exactly the weight the tally summed, and `packBallot`
round-trips it for weight < 2⁶¹ ≫ MaxSupply), no fee path mints or burns CC, the cap
binds and shrinks as the court grows, and the self-pay faucet nets exactly zero. It
surfaced ONE low-severity value-stranding: an all-abstain **uphold** (quorum met purely
by abstentions, yes = no = 0) charged the full fee but left the 40% verdict pool with no
possible claimant. **Fixed:** when no weight voted with the verdict, the 40% folds into
participation, so the whole fee is distributed to those who turned up (regression
`TestAllAbstainUpholdDistributesWholeFee`). The young-court no-cap path was verified safe
(uncapped 3% is < 6 GNOT-equiv while `minted < curveDenom`), not a bug.

**Verification:** `make check` green — court now **32 tests**, including
`TestAdjudicationFeeSplitAndConservation` (3-voter 60/40 split + escrow-drains-to-dust
conservation), `TestAllAbstainUpholdDistributesWholeFee`, `TestFeeGuards`
(one-fee-never-both, double-claim, non-answerer, not-finalized), `TestFailedQuorumChargesNoFee`
(self-pay faucet stays shut), and `TestSetsFreezeAtProvisional`.

## The reopen / bond-doubling / 3-round-close machine (V2)

The last economics increment: a provisional verdict can be **reopened** during its escrow
window, each failed reopen **doubles** the disputer's bond, and **three failed rounds**
close the claim without a decision at the pre-answer price. Design **converged across
three independent passes**; the two genuine forks were settled by majority + spec:

- **Reopen gate** = `now < escrowUntil` (2 of 3; spec-literal §3.6). Consequence: the
  3-round close is reachable only for high-value claims whose escrow window spans multiple
  voting periods — coherent, since the escalating-bond close is for big claims.
- **Reopen scope** = any provisional verdict, per C's design (the most complete). C caught
  a **latent bug** in A's proposal: `ClaimAdjFee` read `cs.proposalID`, which a later
  reopen clobbers — so a new `feeProposalID` field pins the fee to the last *decided*
  round's electorate.

**Load-bearing choices** (all three agreed): two distinct counters — `round` (payload
nonce, never resets) and `failedRounds` (bond exponent + close trigger, resets on a
decision); bond `base << failedRounds` read **before** the increment (sybil-proof — a
fresh disputer can't reset the multiplier); the escrow clock set **once**, never reset by
a reopen; a failed reopen does **not** overwrite a standing decided verdict (only the
first resolution defaults it); the answer bond disposed **exactly once** then zeroed; the
adjudication fee charged **once** (`chargeAdjFee` idempotent, flips a prior `feeSettle`);
the 3rd failed round **voids the fee** (mandatory for solvency — otherwise voters could
claim it on top of a full `CloseAt` redemption); never-traded → `preAnswerPrice=50` =
equal split.

**Critical mechanical catch** (all three flagged): `grc20votes` panics on a non-positive
transfer, so every bond/answer-bond disposal is guarded `if x > 0` — a reopen legitimately
reaches these branches with a spent (zero) answer bond, and an unguarded `Transfer(…,0)`
would brick `ResolveDispute` for the claim.

**Verification:** `make check` green — court now **37 tests**, adding
`TestReopenDoublesBondAndKeepsEscrowClock` (doubling + sybil-proof + clock-not-reset),
`TestReopenOverturnsSettledClaim` (the optimistic-path safety net: `feeSettle`→`feeAdj`
flip, answer bond not double-paid), `TestThreeFailedRoundsCloseAtPreAnswer` (griefer →
close at the pre-answer price, no fee), and `TestReopenRefusedOutsideWindow`.

**Adversarially audited — SOUND.** A 9-probe audit of the reopen flows found NO
conservation, authorization, overflow, or bricking defect. It confirmed the invariant
empirically and by argument: escrow ≥ 0 at every step; each round's bond self-nets
(`half→answerer + burn == bond`, guarded so `half==0`/odd cases skip rather than panic);
the answer bond and the fee are each disposed exactly once; `provClose` voids the fee
(the flagged decide→3-fails→close insolvency confirmed *closed* — fee voided, redemption
≤ escrow); ΣCC falls only by the legitimate failed-round burn (no bond/fee path mints);
`params` is immutable (no retune entrypoint), so `base ≥ 1e6` and `base<<2 ≪ MaxInt64`.
Four conservation-neutral observations, all documented as residuals, none a bug:
**O1** the bond `base` is recomputed live each round (stable once frozen / floor-dominated),
so escalation is guaranteed by the shift + min-floor, not a fixed geometric base —
comment corrected. **O2** an answer bond returned on a failed round is not clawed back on
a later overturn (spec §3.7 literal; conserved, weakens the deterrent). **O3** a
decide→3-fails→close voids the earned adjudication fee (returns to holders via the full
`CloseAt`; costly griefing by design). **O4** `ReleaseRoll` before `ClaimAdjFee` strands
the fee (fails closed; pre-existing).

## Convergence round — systematic bottom-up re-sweep

A fixpoint sweep: one adversarial pass per unit, bottom-up (leaves first), re-running
until a whole pass finds nothing and changes nothing. Every money/behaviour change was
vetted by an independent adversarial subagent before commit; `make check` + `make
txtar-test` stayed green throughout. It found **two real bugs the earlier rounds missed**
— both in court/tickbook money math, which is where every confirmed bug in this project
has been.

**CRITICAL — integer-overflow theft in the court's coin legs (FIXED).** gno's int64
arithmetic WRAPS silently (it does not trap). `MintSet` and `RestBid` multiplied a
caller-controlled quantity by a price with a bare `*`, so a huge quantity wrapped to a
tiny coin leg — mint many shares (or rest a large order) for almost nothing. Confirmed
with a failing regression (a mint credited ~1.8e17 shares for 84 CC). **Fix:** a checked
`ccMul` (`overflow.Mul64`, panics on overflow) now guards every court coin-leg multiply
(`MintSet`/`RedeemSet`/`claimX`/`RestBid`/`CancelOrder`/`RedeemWinning`/`RedeemClosed`/the
fee products), plus a checked `overflow.Add64` on the open-interest ceiling. A full
money-path re-audit confirmed the fix is COMPLETE — every remaining bare multiply is
provably bounded by `grc20votes.MaxSupply` (= MaxInt64/Bps) and the frozen, sane-bounded
`Params` (there is no exported retune path). Regressions in `overflow_test.gno`.

**MED — tickbook survival-fraction freeze via join-after-fill (FIXED).** Distinct from
the round-1 tickbook `surv` scale freeze: when a maker JOINS a tick that has already been
partly filled, `surv` could shrink below the tracked resting, so later fills credited the
joined maker nothing and their coin stranded (fails safe — no insolvency). **Fix:** `Place`
guards `nrest > s0` so `surv >= resting` always holds. Vetted regression-free and
solvency-preserving.

**MED — pre-answer price TWAP manipulable (FIXED, with a documented residual).** The
3-failed-round `CloseAt` settles at a pre-answer price snapshotted from the claim's price
TWAP. That price was read over the same 3-bucket (3-hour) window as answerability. Open
interest is safe on a short window (it moves only on real mint/redeem), but the traded
price moves on every take, so a self-trader could wash-trade to pin a 3-hour window and
skew the close-price value transfer in a single session on any answerable claim. **Fix:**
split the window — answerability keeps the 3h `answerWindow`; the pre-answer price now
reads a new week-long `priceWindow` (the full ring the claim already allocates). Because
the snapshot is taken at `PostAnswer`, when a claim is typically only hours old, its price
ring is immature over a week and the price defaults to the safe, unmanipulable 50/50 split
— which closes the fast single-session pin. Regressions:
`TestPreAnswerPriceResistsShortWindowPin` (a 3-bucket pin that would have set 99 now yields
50/50) and `TestPreAnswerPriceUsesRealPriceWhenTheWeekIsMature` (a stable mature week
yields its real price — guards against an off-by-one silently forcing 50/50 forever).
Adversarially vetted SOUND. **O5 (residual):** the fix is not a mechanical block — the twap
carries the last value across idle buckets, so a determined actor can still mature a
week-long pin with as few as two wash-takes a week apart. What bounds it is economic, not
the TWAP: conservation (`CloseAt` settles the sides at p and 100−p, summing to 100, so a
pin only MISALLOCATES, never mints/insolvency), the need for real losing-side
counterparties (whose own takes are themselves observed into the same ring), and the week
of latency plus three failed dispute rounds (≥7×base bond) needed to reach `CloseAt`. The
fully-robust alternative — settle `provClose` at a flat 50/50 always — is a spec (§3.7)
change left to the owner.

**LOW — unanswered claim strands its deposit (O6, documented residual).** The anti-spam
deposit is escrowed at `OpenClaim` and refunded only at `Finalize`. A claim that never
reaches `minAnswerX` is never answerable, never settles, never finalizes — so the deposit
locks indefinitely. Self-inflicted (no attacker, no insolvency; the opener recovers it only
by minting enough sets to drive the full answer→settle→finalize cycle). A fix (a
timeout-gated depositor reclaim, or a refund folded into a `RedeemSet` that drops supply to
zero) adds a new fund-movement trigger with anti-spam/re-mint design questions, so it is
left to the owner rather than changed unilaterally.

**Everything else re-verified CLEAN.** The full `/p/` sweep (checkpoint, curve, twap,
cshares, tickbook, grc20votes, governor) came back sound; only test-coverage/doc gaps were
closed — a twap maturity-mutation test + `New`/`Load` validation, a checkpoint `be64`
negative-value round-trip (both were documented-but-unexercised contracts), and a curve
cost-refused/extremes pair. `grc20votes` and `checkpoint` were re-read directly (delegation
sum-invariant, epoch-seal anti-flash-loan, `~supply` key collision-safety, `MaxSupply`
tally bound; BE round-trip, prefix-safe floor query) and needed no change — a clean pass
with nothing to fix, which is the convergence signal. In the court, the directory's empty
state was dead code (the header made the length check always false) and is now reachable,
guarded end-to-end in the lifecycle txtar; the `ListCourts` ordering comment was corrected
(slug order, not age).

**Wireframe / tokenomics consistency.** A cross-check of `web/index.html` and the tokenomics
/ structure docs against the code found no wrong user-facing number and no phantom
entrypoint (every wireframe action resolves to a real exported func; "72h min" =
`settleDelay`, confirmed). The gaps are doc-honesty ones: the docs and wireframe describe
"weekly sessions" the V1 code does not implement (it uses a rolling 72h `settleDelay`; the
weekly boundary is a deferred refinement), and §9 states a 7-day trailing-X window where V1
uses 3h. One item is a genuine product call left to the owner: §3.4 says the ballot is "the
claim itself — never 'uphold the answer'", but the shipped governor vote (and the wireframe
faithfully) frames it as "OVERTURN the answer?" — code and doc-principle disagree, and which
should win is an epistemic-design decision, not a typo.

---

## `r/cryptocourt/courtv2` (V2) — economic hardening, v0.40–v0.49

**Scope note, so absence is not read as clearance.** Everything above audits the `/p/`
packages and the V1 `r/cryptocourt/court` realm. V2 lives under `realm/r/courtv2/` and its
decision record is `PLAN.md` §13, which carries the reasoning, the rejected alternatives and
the measured numbers. This section exists so that a reader of the authoritative audit record
does not conclude V2 was audited clean merely because it was not mentioned.

**Two CONFIRMED economic vulnerabilities, both reproduced with concrete numbers before any
fix was written, both now fixed.**

| # | Finding | Measured | Fix |
|---|---|---|---|
| V2-H1 | The anti-mill slash is sized off LIFETIME conviction but was collateralized by a bond sized off a 3-HOUR trailing stake average — and `Unstake` is free, permissionless, and KEEPS conviction (F9). Draining to `minAnswerX` two hours before answering nullified the v0.40 deterrent | bond **50 CC** against **11 220 CC** of earned slash exposure — a **224×** shortfall; break-even detection moved 0.385 → **0.99**, profitable at 90 % detection | v0.46: `xBarFrozen = max(3h trailing, lifetime time-averaged stake)` (the P6 base, drain-resistant), plus a collateralization floor in `PostAnswer` using the SAME sizer `ResolveFlag` later draws with |
| V2-H2 | `slashGrade` required `decidedRounds == 0`, so ONE decided dispute round retired the slash permanently. A sock-wallet dispute deliberately lost cost ~3–4 %·X̄ after comp — **below even the 4.5 %·X̄ flat slash floor**, so buying immunity dominated at every hold time | ~4 %·X̄ buys off up to **30.8 %·X̄**; the repo already contained the attack as a fixture (`TestWeightlessContestEarnsNoCredential`) which asserted only that the CREDENTIAL was denied while the same round granted the SHIELD | v0.47: clause deleted (it was redundant — `slotConsumed` and the overturn's `answerBond = 0` already cover every case v0.28 wrote it for); v0.48: `OpenDispute` no longer forgives an adjudicated slash, the round's OUTCOME disposes it |

**Structural fixes alongside.** A dead-claim answerability gate (conviction accrued
indefinitely on unclosed claims, so past ~19.5 weeks the draw arm crossed the bond **on a
perfectly constant pool**, no drain required); `mustInvariants` demoted from a safety proof
to a calibration, since a check over constants cannot carry a runtime guarantee; and
`Finalize`'s retention gate made character-identical to `SettleUndisputed`'s, closing the
sibling asymmetry that had produced two prior HIGHs (a guard added to one twin but not the
other — the recurring shape in this codebase).

**Method, for reproducibility.** Design decisions went to three subagents on identical
prompts, iterated to convergence (both V2-H2 and the X̄ base split 2–1 on the first round and
converged 3–0 on the second, in each case reversing the initial majority). Every guard is
mutation-verified: the guard is reverted and the test must fail, because a test that passes
with the guard deleted proves nothing. Where a "missing test" turned out to be an
unreachable code path (the F9 bonus cap needs ~91 weeks against a 12-week claim life), the
artifact is a test pinning the governing RELATIONSHIP rather than a contrived fixture that
would pass while proving nothing about the deployed configuration.

**Tooling defect found and fixed (v0.49).** `scripts/check-isolation.py` kept its package
list as a hand-maintained copy of the Makefile's; they had drifted, so the guard staged 5 of
11 packages and **never checked courtv2 at all** while printing "all 151 tests across 5
packages pass alone as well as together". The list is now read from the Makefile, coverage is
**343 tests across 11 packages**, and a `selftest` control breaks the coupling on purpose and
requires the guard to notice. The one order-dependent test it exposed was a vacuous assertion
in V1's `TestDirectoryTiers` (it depended on a neighbour creating the first court; run alone,
the address it called a non-admin *became* the admin, so its expected abort could never fire).

**Open, awaiting an owner decision.** §12 row 30's provClose-reachability premise is false on
any court past bootstrap: `escrowWindow` pins at its 3-week cap once `X̄·Price ≥ 7e9`, so
three failed rounds fit on essentially every claim and the ~70 CC "three quorum-less rounds →
draw zeroed" grief is live court-wide rather than rare. The row is corrected; the behaviour is
deliberately unchanged, because capping `extraDays` trades that against the "honest small
claims wait 3 weeks" cost the row exists to avoid.
