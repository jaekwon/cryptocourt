# Deadlines in seconds, accounting in blocks

**Status:** in progress. 1 of 11 gates converted; see the log at the end.

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
| `dispute.gno:652` | `finalizeGraceBlocks` after escrow | `escrowUntilAt` | unconverted |
| `dispute.gno:101,649` | escrow window | `escrowUntilAt` | half — stamp path exists |
| `answer.gno:69` | `stakeOpenDelay + answerWindow + priorityWindow`, summed | `openedAtTime` | unconverted — composite, converts as one duration |
| `stake.gno:166` | `stakeOpenDelayBlocks` | `openedAtTime` | unconverted |
| `moderation.gno:664,1187` | `pendingTTLBlocks` | needs a stamp | unconverted |
| `moderation.gno:691` | `votingBlocks` after execute | needs a stamp | unconverted |
| `modvote.gno:328` | `nominateEnd` | needs a stamp | unconverted |
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
