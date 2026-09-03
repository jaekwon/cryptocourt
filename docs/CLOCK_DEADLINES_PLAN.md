# Deadlines in seconds, accounting in blocks

**Status:** in progress. Every gate in the order list is converted (plus one found already done), 2 of the 6 stored future heights, and one of the two gates the order omits. `meta.gno:366` is the last gate.

## The problem, as observed

Two separate reports on one claim page, both the same fault:

1. A dispute dated **11 Dec 2026** whose vote "closes in ~7 days" while the
   answer above it was dated **2021** — a five-year gap the countdown did not
   know about.
2. A claim settled **7 Apr 2022** still inside its participant-only week
   in December 2026.

The second, measured on the live chain:

```
verdict        7 Apr 2022    block  71,280
now           15 Dec 2026    block 124,560
elapsed        1,713 calendar days  =  53,280 blocks
FINALIZE_GRACE                         120,960 blocks   -> guard still fires
```

The realm is not wrong. It is answering in blocks, and 53,280 < 120,960. The
page is not wrong either. They disagree because **a block is not a fixed amount
of time**, and every window written in blocks silently means something different
whenever block cadence changes.

That is not hypothetical on this deployment. Turning off `timeout_commit`
padding took this chain from 0.2 to ~50 blocks/sec; at that rate a window of
120,960 blocks — meant as one week — elapses in **about forty minutes**.

## What already exists

This migration is half-done, and the pattern is set. `clock.gno`:

```go
func pastDeadline(stamp, secs int64) (passed, known bool) {
	if stamp == 0 {
		return false, false
	}
	return nowTime() >= stamp+secs, true
}
```

Callers prefer the stamp and fall back to blocks only when the record predates
it:

```go
if passed, known := pastDeadline(cs.answeredAtTime, settleSecs); (known && passed) ||
	(!known && now >= cs.answerHeight+settleDelay) {
```

`deadlineTime(stamp, secs)` is its sibling, answering the same question as a
date for display and returning 0 when the stamp is missing — so the rendering
half of this migration is built too.

Five sites are converted: the dead-claim timeout (answer.gno, claim.gno), the
settle delay (dispute.gno, session.gno), and the polish window (claim.gno).
Claims already carry `openedAtTime`, `answeredAtTime`, `verdictAtTime`,
`escrowUntilAt` and `disputeOpenedTime` beside their block fields.

**So this is a completion, not a redesign.** The remaining work is the sites that
were never converted — which is exactly where both reported bugs live.

The realm says so itself. `clock.gno` names the two gates left behind, and why
their seconds constants were removed rather than left sitting unused:

> ONLY THE TWO THAT ARE READ. Two more sat here for gates that never converted:
> the qualified-answerer head start (still `priorityWindowBlocks`) and Finalize's
> participant-only week (still `finalizeGraceBlocks`). Both were dead the whole
> time, and a seconds constant nothing reads is worse than absent — it asserts a
> deadline is wall-clock when the gate is height.

That is this plan's scope, written down before either bug was reported. It also
sets the order: the constant goes back only together with the gate that reads
it, never ahead of it.

And the fallback rule is already policy, not an invention of this plan:

> PRE-UPGRADE CLAIMS carry zero timestamps. Every gate below falls back to its
> original height arithmetic when the stamp is missing, so a claim opened before
> this change keeps exactly the deadline it was opened under.

## The boundary

Not everything should move. `clock.gno` already states the split, and the reason
it exists:

> heightNow is the ONLY height read in this realm. Everything accounting —
> conviction per block, emission periods, vote closes, twap maturity — reads it,
> so a test chain can advance them all together rather than mining.

**Deadlines move to seconds. Accounting stays on blocks.**

A deadline answers "may this happen yet". Its correctness is a human question —
72 hours to dispute, a week of participant priority — so it should be measured
in the units the promise was made in.

Accounting integrates over blocks. Conviction is stake × blocks; emission
accrues per period; the twap ring is block-bucketed. Converting these would not
merely be churn, it would break an invariant `grc20votes` depends on:

> a transaction cannot outlive its block and a block cannot outlive its epoch

That quantisation is what makes the anti-flash-loan property structural rather
than a discipline. Moving it to wall time — which a proposer influences —
trades a drift bug for a soundness hole. It stays.

## Inventory

A sweep for height arithmetic (`+ …Blocks|Delay|Timeout|Window|Grace`) finds
**34 sites across 16 files**, and reading each one gives FOUR kinds, not two.
The extra kind is the one that matters most:

| Kind | What it does | Count | Moves? |
|---|---|---|---|
| **Gate** | compares now against a deadline | 16 | yes |
| **Stored future height** | writes `now + window` into state | 6 | yes — and it is persisted |
| **Projection** | renders a deadline for display | 6 | follows its gate |
| **Comment** | prose only | 5 | no |
| **Accounting** | a duration used in arithmetic | 1 | no |

**Stored future heights are the hard part** and were missing from the first
draft. `boardmod.gno:387,444`, `modvote.gno:303,304,563` and
`moderation.gno:1190` compute a block number in the future and persist it —
`r.frozenGapUntil = now + freezeMaxBlocks + freezeGapBlocks`. A gate can be
converted in place because it reads two live values; a stored future height is
already wrong the moment cadence changes after it was written, and no fallback
can recover the intent because the original `now` is gone. These need the
timestamp written ALONGSIDE, at the same site, and the gate reading the pair.

The one accounting use hiding among them: `crystallize.gno:59`,
`cs.openBlocks = cs.frozenAt - (cs.openedAt + c.params.stakeOpenDelayBlocks)` —
a duration fed into the draw, not a deadline. It stays on blocks.

Classify by use, never by name: `answerWindow` looks like a deadline and is a
trailing ring; `pendingTTLBlocks` looks like accounting and is a deadline.

### Move to seconds (deadlines)

| Site | Window | Stamp to use | Status |
|---|---|---|---|
| `crystallize.gno:46` | `finalizeGraceBlocks` after verdict | `verdictAtTime` | **converted — bug 2 fixed** |
| `dispute.gno:652` | `finalizeGraceBlocks` after escrow | `escrowUntilAt` | **converted** |
| `dispute.gno:101,649` | escrow window | `escrowUntilAt` | half — stamp path exists |
| `answer.gno:69` | `stakeOpenDelay + answerWindow + priorityWindow`, summed | `openedAtTime` | **converted** — as one duration |
| `stake.gno:166` | `stakeOpenDelayBlocks` | `openedAtTime` | **converted** |
| `moderation.gno:620,664,1187` | `pendingTTLBlocks` | `approval.openedAtTime` (added) | **converted** |
| `moderation.gno:691` | `votingBlocks` after execute | `claimMod.executedAtTime` (added) | **converted** |
| `moderation.gno:755` | `reSetWindowBlocks` (DMCA §512(g)) | `globalClearedAtTime` (added) | **converted** |
| `modvote.gno:328,384,387,483` | `nominateEnd`, `voteEnd` | `nominateEndTime`/`voteEndTime` (added) | **converted** |
| `boardlegal.gno:100` | `reSetWindowBlocks` (board row) | `globalClearedAtTime` (added) | **converted** |
| `boardmod.gno:107,137` | `frozenUntil` | needs a stamp | unconverted |
| `meta.gno:366` | `votingBlocks` after verdict | `verdictAtTime` | unconverted |
| `p/governor` proposal `closes` | vote window | needs a stamp | unconverted — bug 1 |

### Stay on blocks (accounting)

`epochBlocks`, `periodBlocks`, `stepDownPeriods`, `rMaxPeriods`, conviction
accrual, twap buckets, `checkpoint` epochs, `grc20votes` epoch quantisation.

### Resolved while drafting

`decideWindowBlocks` is not a separate case: `pendingTTLBlocks =
decideWindowBlocks`, so it is the moderation TTL above and moves with it.

`answerWindow` reads as a deadline and is not one — `cs.oi.Average(now,
answerWindow)` makes it the width of a trailing ring. It is accounting and
stays on blocks. The name is the trap; check the use, not the suffix.

`deadClaimTimeout` and `settleDelay` are already converted.

## Plan

0. **Inventory — done.** All 34 sites read and classified above: 16 gates, 6
   stored future heights, 6 projections, 5 comments, 1 accounting use. Eleven
   gates are still unconverted; five already carry the stamp path.

1. **A stamp beside every deadline.** Four sites have no timestamp to read
   (`moderation`, `modvote`, `boardmod`, governor proposals). Each needs one
   written where the block field is written. This is the only state change, and
   it is additive.

2. **Convert site by site**, each keeping the `(known && passed) || (!known &&
   <blocks>)` shape, so a record written before its stamp existed still behaves.
   One commit per site with its own test.

3. **The governor is the hard one.** `Timings()` returns four heights and
   `DisputeVoteCloses` publishes one. Proposals are a `/p/` type shared with
   other consumers, so adding a stamp is an API change, not a local edit. It
   gets its own ADR.

4. **A seconds constant lands with its gate, never before it.** `clock.gno`
   deleted two that nothing read, on the grounds that an unread constant
   "asserts a deadline is wall-clock when the gate is height". So each commit
   adds the constant and the gate that reads it together, or neither.

5. **Retire the fallback** only when no live claim can still be missing a stamp
   — which for a chain that is reseeded is immediately, and for a persistent one
   is never, so the fallback likely stays forever. Say so rather than leaving it
   looking temporary.

## What this does not fix

The seeded chain's own skew. The scenario compresses 2,379 narrative days into
1,209,600 blocks of clock budget — a 34× squeeze — so on a test chain the two
clocks disagree by construction, whichever one a gate reads. Converting the
gates makes them agree with the **dates the fixture shows**, which is the half a
reader sees, and is why bug 2 disappears. It does not make the fixture's blocks
realistic, and nothing can: a realistic six years is 41M blocks against a budget
of 1.2M.

## Risks

- **Who controls the clock.** The usual objection is that wall time is softer
  than height, and on a multi-validator chain that is a real difference: block
  time is a median of proposers, height is constrained by production. On THIS
  deployment it is not a difference at all — kourt-1 runs a single validator
  (voting power 1), so both clocks are that one node's to choose. Moving
  deadlines to seconds therefore concedes nothing here, and the honest argument
  for it is not safety but cadence-independence: a second is a second whatever
  the block rate does.
  The accounting still stays on blocks, for the quantisation reason above rather
  than for a manipulation one.
- **Two clocks during migration.** Every half-converted gate reads both. The
  `(known && passed)` shape means the stamp wins whenever it exists, so the
  behaviour change lands the moment the stamp does, not when the block code is
  deleted.
- **`blocksToSecs` hardcodes 5.** Court parameters are configured in blocks, so
  conversion assumes a cadence — the very assumption this plan exists to remove.
  Court params should move to seconds too, or the conversion should be documented
  as a one-off for legacy params only.

## Log

### `supersede.gno:82` — already done, and the order list was pointing at a fallback

Nothing to convert. `supersedeOrdered` already prefers the wall clock and falls
back to height; line 82 is the FALLBACK arm of a converted predicate, not an
unconverted gate. The constants agree exactly (`deadClaimSecs` = 7,257,600 =
`deadClaimTimeout` × 5), it requires BOTH stamps before trusting either (mixing
units across two claims would be worse than falling back), and it is the one site
that already had a corpus row per arm — the discipline being retrofitted
elsewhere. `supEdge.at` is a height "for the record" that nothing reads and
nothing renders.

### `dispute.gno:986` — Reopenable, the read that contradicted its own gate

Converted, by collapsing three copies of one rule into `escrowPassed`. The escrow
window was asked in three places and answered in three ways: OpenDispute and
Finalize each wrote the stamp-then-height test out longhand in mirrored polarity,
and Reopenable read `heightNow() < cs.escrowUntil` and nothing else.

**Not drift — a live contradiction.** Reopenable is what "a client gates the
reopen txlink on", per its own comment. Off 5s a block there were instants where
the link was offered and the transaction refused, and instants where the link was
hidden and the transaction would have been accepted. Both directions, same claim,
same block. So the test asserts AGREEMENT between the read and the write path
rather than either answer alone; a test checking only "Reopenable is false past
the window" would have passed throughout the bug.

**Sharing a predicate merged two corpus rows into one.** The two "loses its
pre-stamp HEIGHT fallback" rows — one per call site — became the same mutation
once both call sites routed through `escrowPassed`. Kept one, deleted the other:
a duplicate triple is one mutation billed twice and reads as more coverage than
exists. Reopenable had no row at all and now has two.

**THE CORPUS CAN BE EDITED AS DATA.** `json.dumps(rows, indent=1,
ensure_ascii=True) + "\n"` round-trips `mutations-kourtv2.json` byte-identically
— verified against the file. Every earlier iteration did string surgery on the
raw JSON to avoid reformatting it, which is how this one briefly shipped a row
whose `replace` I had rewritten by accident: the OpenDispute row's replacement
keeps the brace that closes `if cs.provisional < 0`, and blanking it produced a
mutant that could not parse. `check-mutant-collisions` caught it. Repoint `find`
and LEAVE `replace` ALONE unless the mutation itself is meant to change.

**Still open, and now the last gate:** `meta.gno:366`, the meta-verdict execution
expiry.

Verified: full kourtv2 suite green; five mutants compile and are killed; `make
anchors collisions staleguards guards` and check-read-purity/check-storage pass.

### `boardlegal.gno:100` — the board row's counter-notice window (last in the order)

Converted. `globalClearedAtTime` on the board row, written where the height is,
and the gate calls `reSetWindowOpen` — the predicate iteration 7 built for the
claim-level twin. One statutory period now has one implementation, so it cannot
be retuned or converted in two halves.

**A corpus row that had quietly become half a mutation.** `GlobalClearRow: arming
the window` deleted the line that sets `globalClearedAt`. Its anchor still
matched after the stamp was added, so `make anchors` said nothing — but the
mutant now deleted only half the arming and left the stamp behind. It was still
caught, by luck: the gate short-circuits on `globalClearedAt != 0`. Widened to
delete both lines. **AN ANCHOR THAT STILL MATCHES IS NOT PROOF A ROW STILL MEANS
WHAT IT SAID** — adding a line next to a mutated one silently narrows it.

### Two gates the ORDER LIST does not name, found by sweeping after the last one

The order list is complete as written; it is not complete as a list of gates.
Sweeping for block arithmetic after finishing it turns up two more:

- **`meta.gno:366`** — `now > cs.verdictAt+mc.params.votingBlocks`, the
  meta-verdict execution expiry ("a verdict is not a sleeper round"). A real
  unconverted gate. It IS in this document's table and was simply absent from the
  order. `verdictAtTime` already exists, so it converts like the others.
- **`dispute.gno:986`** — `Reopenable`, which answers whether the escrow window
  is still open and which "a client gates the reopen txlink on". Its own gate
  (dispute.gno:649) reads `escrowUntilAt` already, so the READ and the GATE now
  disagree on a drifting chain: the button appears when the chain refuses, or
  hides when it would accept. Same class as the election render's phase banner,
  which is why that one was converted with its gates rather than deferred.

Neither is a projection in the "renders a number" sense, so neither belongs in
the projection pass. They are gates, and they should be done before the stored
future heights.

Verified: full kourtv2 suite green; six mutants compile and are killed, four
boardlegal and both shared-predicate rows; `make anchors collisions staleguards
guards` and check-read-purity/check-storage pass.

### `modvote.gno:328` — the ballot's phase clock (and the first stored future heights)

Converted, and it took `voteEnd` with it — two of the plan's six stored future
heights land here, ahead of their batch, for a reason worth stating.

**A half-converted phase machine has an incoherent middle.** `approve` tests both
boundaries back to back: voting is refused before `nominateEnd` and after
`voteEnd`. Convert one and not the other and a drifting chain gets instants where
neither window accepts anything, or where the ballot takes votes the render calls
closed. That is not a smaller version of the same bug, it is a new one — so the
two deadlines move together even though the order list separates them.

**This is the first kind that cannot be repaired afterwards.** A stored future
height is wrong the moment cadence changes after it was written, and the `now` it
came from is gone, so unlike an event stamp there is nothing a fallback could
reconstruct. The stamps are therefore written AT the same site, in the same struct
literal, and never derived later.

Six sites read the pair — three gates in modvote, one in ResolveElection, and the
two the render derives its phase banner from — and all six go through
`nominationClosed`/`votingClosed`. The render's PHASE follows the gates
deliberately: a banner reading "Nominating" while the chain refuses a nomination
is the reported bug wearing different clothes. The block numbers it prints are
still heights; converting what they SAY belongs to the projection pass.

**A survivor, and what it taught.** `votingClosed`'s height arm SURVIVED its
mutant while the pre-stamp test walked only the nomination seam. Two deadlines
sharing one shape do not share a test — the far seam had to be walked explicitly.
Fixed and re-measured; the row is killed now.

Also repointed three pre-existing rows whose anchors this rewrote (ResolveElection's
mod check and both render phase cases), and corrected a new row that had silently
inherited the previous row's `file` field — `make anchors` caught that, not review.

Verified: full kourtv2 suite green; eight mutants compile and are killed, five new
and three repointed; `make anchors collisions staleguards guards` and
check-read-purity/check-storage/check-render-text pass.

### `moderation.gno:755` — the DMCA §512(g) counter-notice window

Converted. Third new field: `globalClearedAtTime`. The gate now goes through
`reSetWindowOpen`, a shared predicate, because the SAME window is read by a
second gate on a different record — `boardlegal.gno:100`, the last item in the
order. One statutory period, one predicate, so the two cannot be converted
separately.

**A statutory period is the strongest case for the clock in the whole plan.**
§512(g) is written in days. Counted in blocks the legal window was fourteen days
only on a chain holding 5s a block; anywhere else the realm was enforcing a
period the statute does not name.

**And it is the strongest case AGAINST a seconds constant.** The constant's own
note says counsel must be able to retune this alone, and the neighbouring
`pendingTTLBlocks` note names the hazard exactly: "one of the two eventually gets
changed for the other's reasons". So there is no `reSetWindowSecs`; the gate
converts at the call site. That decision is now measured rather than argued — the
two pre-existing PARAM rows that halve and double `reSetWindowBlocks` are still
CAUGHT after the conversion, which is only true because one number still governs.
A seconds twin would have left those rows passing while changing nothing.

**The test finally asserts its own name.** `TestTheReSetWindowIsExactlyFourteenDaysLong`
bracketed 241_920 BLOCKS, which is fourteen days only at 5s — the wrong quantity
for a period borrowed from statute. It now brackets 1_209_600 seconds, mining no
blocks at all, and keeps the block bracket on a second record with no stamp where
the height arm is still the rule.

**The collision checker earned its keep.** My first `not enforced` row left `now`
declared and unused, so the mutant could never compile and would have measured
nothing while reading as coverage. `check-mutant-collisions` reported exactly
that, automatically — the same class of mistake iteration 2 caught only by hand.

Verified: full kourtv2 suite green; six mutants compile and are killed, including
both pre-existing PARAM rows; `make anchors collisions staleguards guards` and
check-read-purity/check-storage pass.

### `moderation.gno:691` — the I8 re-hide cooldown, which had no test at all

Converted. Second new field: `executedAtTime` beside `executedAt`, written at
both writers (`setMetaBit`, `clearCourtBitByMeta`). No new constant — the window
is `c.params.votingBlocks`, a court parameter, so it converts at the call site.

**The unit is the point here, not a nicety.** The cooldown is the VOTE'S OWN
LENGTH. Counted in blocks it is one vote long only at 5s a block; on a faster
chain the loser of an appeal waits less than the appeal itself took, which is
precisely the asymmetry the guard was written to remove.

**THE GUARD WAS COMPLETELY UNPINNED, and that is the bigger find.** No test in
the package produced its panic and neither corpus file carried a row for it. Not
inferred — measured: deleting the whole branch and running the full suite with
the new test excised comes back GREEN. A moderator who lost an unhide appeal
could have been let straight back in by a one-line edit and nothing would have
objected. It now has the first test it has ever had, plus four corpus rows (not
enforced, one second early, one block early, stamp not written), all confirmed
killed.

**A process note worth keeping.** Running that proof cost the new test: I used
`git checkout --` to undo a temporary excision, which also discarded the file's
other uncommitted changes. Re-added and re-verified from scratch — full suite and
all four mutants re-run against the restored tree rather than trusting the
earlier runs, which no longer described it. **`git checkout --` is not an undo
for a scripted edit when the file has uncommitted work in it; copy the file
aside first, as the mutation harness does.**

Verified: full kourtv2 suite green; four mutants compile and are killed; the
guard proven unpinned beforehand; `make anchors collisions staleguards guards`
and check-read-purity/check-storage pass.

### `moderation.gno:620,664,1187` — the m-of-n approval TTL (first new field)

Converted. The first site needing plan step 1: `approval` had no timestamp, so
`openedAtTime` is added beside `openedAt` and written at the single writer.

**No new constant, deliberately.** `pendingTTLBlocks` is not a number, it is
`decideWindowBlocks` — "the realm's unit for a body gets this long to decide". A
parallel `pendingTTLSecs` would keep its own copy of that duration and stop
tracking a tune of the original, which is the coupling the constant's own comment
already refuses ("one of the two eventually gets changed for the other's
reasons"). It converts at the call site through `blocksToSecs`, as the polish
window does.

**Three readers, one predicate.** approveAction, pendingOpenedAt and
PendingApproval each wrote the rule out. The file said so and named its guard:
adjacency, "the two tests are eight lines apart and a reader changing either sees
the other". That is sized for a one-line test; a stamp-then-height fallback in
three copies is three chances to convert two. They now share `approvalStale`, and
the test asserts the clock governs at all three.

**A gap closed by accident, and the checks caught it.** `make anchors` failed on
a SECOND corpus file — `mutations-kourtv2-KNOWN-GAPS.json`, which I had not been
grepping. Its rows assert that NO test catches them, so a row there is wrong when
it starts being caught. The row `pendingOpenedAt: a stale proposal still bounds
the burn` had a long recorded argument for why no fixture could reach the branch
(it needs the m-of-n threshold lowered between two calls). The wall-clock route
reaches it trivially — the new test reads pendingOpenedAt on a stale entry
directly — so the row is now caught and has been PROMOTED into the main corpus by
move, not copy, as check-mutation-anchors warns.

**Deferred, and tracked rather than silent:** two projections of this window
still publish blocks — `PendingApproval`'s `expiresAt` return and modrender's
"expires at block N". Completing them means publishing the timestamp WITH its
reference height, the pairing ClaimTimeline already uses, which changes a public
signature. Left for the projection pass rather than smuggled in as a silent
change of unit. They are 2 of the plan's 6 projections.

Verified: full kourtv2 suite green; five mutants compile and are killed (one
second late, one block late, TTL never reached, stamp not written, and the
promoted row); `make anchors collisions staleguards guards` and
check-read-purity/check-storage pass.

### `answer.gno:69` — the qualified-answerer head start (the composite)

Converted whole, from `openedAtTime`. `priorityWindowSecs = 24*3600` added to
`clock.gno`, which had explicitly reserved the right to it: *"If the gate does
move, put it back in the list and give it a constant then."* The header list and
the constant block both updated, since the file had been documenting this gate as
the one still counting blocks.

**Why converting the whole sum is right, and not a units error.** Three terms:
a court parameter, the trailing ring's width, and the 24h head start. The first
two are block-denominated and go through `blocksToSecs` at the call site; only
the third is a wall-clock promise. It looked at first like the anchor could not
move — the ring matures in blocks, so a naive conversion would let the window
expire before a claim was answerable at all, which is the exact bug the polish
re-anchoring already fixed once. But the anchor is NOT actual maturity. The
design comment says the window is keyed on claim AGE and runs from *"the earliest
the claim could have been answerable"*, adding that *"priority is a perk, not a
guarantee (a claim that matures late may have no priority phase left)"*. A
projection from opening converts whole; actual maturity would not have.

**What it gives up, recorded because it is a real trade.** In blocks the window
stretched with cadence, so a slow chain handed a late-maturing ring more room
inside the window. It no longer does — the same "may have no priority phase left"
the design already accepts, now reached by a clock rather than by a block rate.
In exchange the head start is 24 hours on every chain instead of on one holding
5s a block.

`answerWindow` is untouched as a constant. It appears at line 49 as the trailing
ring (accounting, stays blocks) and at line 69 as a duration; only the second is
converted, and at the call site.

**A third distinct corpus outcome.** Site 1 had a stale row, site 3 had no rows;
this one had TWO rows both anchored on the same line, plus no edge row. Both
repointed, one edge row added, all five mutants (never-expires, binds-early,
exact second, polarity, exact block) confirmed killed.

Verified: full kourtv2 suite green; five mutants compile and are killed; the new
test panics with the real message on the pre-conversion gate; `make anchors
collisions staleguards guards` pass.

### `stake.gno:166` — the polish window, second half of a window already half-converted

Converted. No new constant: the window is a COURT PARAMETER in blocks, so it goes
through `blocksToSecs` exactly as `claim.gno:497` already did for the other half
of the same window.

**That other half is the point.** `EditClaimTitle` asks whether the polish window
has CLOSED; `Stake` asks whether it is still OPEN. One window, two gates, opposite
polarity — and until this commit one read seconds and the other read blocks. On
any chain not running at 5s a block there was a spread of instants where a claim
could be both re-titled and staked, which is the exact race the window exists to
prevent. Converting the second half closed it, and the new test asserts the two
gates agree at the boundary rather than merely that each works alone.

**A different failure mode from the first two sites.** There was no stale anchor
here, because there was no corpus row to go stale: this gate had NO mutation
coverage at all. Grepping the corpus before editing (the lesson from the last
commit) is what surfaced that — the check suite cannot report a row that was never
written. Three rows added: exact second, exact block, not enforced. All killed.

The window is short (720 blocks = 3600s), so unlike the grace week its exact
second is cheap to pin, and the test does: refused at 3599, allowed at 3600, with
no block mined in between.

Verified: full kourtv2 suite green; all four mutants compile and are killed; the
new test panics with the real message on the pre-conversion gate; `make anchors
collisions staleguards guards` pass.

### `dispute.gno:652` — Finalize's grace, the twin

Converted. Same constant, same shape, different base — and no new constant, since
`finalizeGraceSecs` landed with its twin last commit.

One difference worth recording: `escrowUntilAt` is a **stored future timestamp**
(`nowTime() + blocksToSecs(w)`, written beside `escrowUntil` when the escrow
opens), where `verdictAtTime` stamps an event as it happens. `pastDeadline` takes
both without caring — it adds `secs` to whatever it is given — so the grace runs
from a deadline here and from an event there, and the call site reads identically.
That is worth knowing before the stored-future-height batch: those six sites are
this shape, and this one shows it already works.

**The trap from the last entry repeated exactly**, as predicted: HALF ONE of
`graceboundary_test.gno` pinned this gate's block edge and stopped pinning
anything the moment the stamp won. Same fix — corpus row split per arm, and the
new test's pre-stamp half sits on the height edge.

**And a second corpus row that the first conversion did not have.** Finalize
carried TWO rows, not one: an edge row and a `guard is not enforced` row whose
anchor was the whole `if` line. `make anchors` found it only after the edge row
was already fixed, so the lesson is to grep the corpus for every row naming a
site BEFORE editing it, rather than fixing the one the checker names first. Its
replacement also had to keep the `passed, known :=` init, or the mutant fails to
compile and silently measures nothing.

Crystallize had no such row — an asymmetry between twins that predates this work.
Added it in this commit and confirmed it is killed, so both gates now have three
rows: exact second, exact block, and not enforced at all.

Verified: full kourtv2 suite green; all four Finalize mutants (seconds edge, block
edge, polarity, guard disabled) compile and are killed, as is the new Crystallize
one; `make anchors collisions staleguards guards` pass.

### `crystallize.gno:46` — the participant-only week (bug 2)

Converted. `finalizeGraceSecs = 7*86400` added to `clock.gno` in the same commit,
per rule 4. Shape as planned, inverted because this gate asks whether the window
is still SHUT: `(known && !passed) || (!known && now < verdictAt+finalizeGraceBlocks)`.

**A test the old code cannot pass.** `testing.SkipHeights` moves height and time
together at exactly 5s a block, and `finalizeGraceSecs` is exactly
`finalizeGraceBlocks × 5` — so under SkipHeights the two clocks are the same clock
and no existing test could tell which one the gate read. The new test uses
`GetContext`/`SetContext` to move time WITHOUT height, reproducing the live
divergence directly: on the pre-conversion code it panics with the reported
message, on the converted code the stranger is let in.

**What the conversion cost, and what paid it back.** `graceboundary_test.gno`
HALF TWO pinned this gate's `<` against `<=`. A stamped claim no longer reaches
that comparison, so that coverage would have evaporated silently — the check
suite caught it as a stale mutation anchor rather than as a test failure, because
the test still passed for the wrong reason. Resolved by pinning each arm
separately: the corpus row became two (exact second, exact block), and the new
test's second half sits on the height edge with a zeroed stamp so the fallback
keeps its own killer. **Converting a gate can silently retire the test that
pinned it — check the mutation corpus, not just the suite.**

Verified: full kourtv2 suite green; both new mutants compile and are killed; the
polarity mutant is killed; `make anchors collisions staleguards guards` pass.
`make height-shim` fails on `check-curation-reachable` (Set/ClearCourtImage not
named by any web file) — confirmed pre-existing by re-running it on the
unmodified tree, unrelated to the clock.
