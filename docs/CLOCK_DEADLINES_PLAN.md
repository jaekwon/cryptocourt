# Deadlines in seconds, accounting in blocks

**Status:** complete, and the completeness is measured rather than asserted — see "The sweep is clean". Every gate is converted — the order list's, plus the two it omitted. the stored-future-height batch is done (5 real ones; the 6th was a mis-classified projection, now also done); the rest of the remaining work is stored future heights, projections, and the governor.

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
| `boardmod.gno:107,373` | address freeze + its re-freeze gap | `frozenUntilTime`/`frozenGapUntilTime` (added) | **converted** |
| `boardmod.gno:137,433` | claim-board freeze + its gap | `boardFrozenUntilTime`/`boardFrozenGapUntilTime` (added) | **converted** |
| `meta.gno:366` | `votingBlocks` after verdict | `verdictAtTime` | **converted** |
| `p/governor` proposal `closes` | vote window | `closesTime` (added) | **converted**, consumers included |

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

### The governor's consumers — bug 1, closed

`TimingsAt(id) (openedTime, closesTime)` lands with its first reader, per the
ADR: a sibling rather than a wider `Timings`, because `Timings` is consumed by
two realms and arity should arrive with its readers. `ClaimTimeline` publishes
`voteclose:<unix>:<height>`, and the web reads it.

**This is the line the report was about.** The page derived the close date as
`nowT + (voteEndsAt - nowH) * BLOCK_SECS` — a projection at an assumed cadence,
which is exactly why a vote showed "closing in ~7 days" beside an answer dated
2021. It reads the published moment now and drops the `est` marker; the estimate
survives only as the fallback for a dispute opened before the stamps, where a
height genuinely is all there is.

`DisputeVoteCloses` deliberately stays a HEIGHT: it is a positional field in the
packed claim head, where a change of unit is invisible to every reader. Its
comment argued "A HEIGHT, NOT A TIME, because that is what the governor gates
on" — true when written, false since the governor was converted, and now
corrected to point at the timeline.

**A CIRCULAR ASSERTION, CAUGHT BY MUTATION.** The first version of the realm test
compared the timeline against `TimingsAt` — the same accessor the timeline is
built from. Mutating `TimingsAt` to return `closesTime + 1` moved both sides
equally and SURVIVED. The fix is a second assertion in `p/governor`, against the
field `wouldBe` actually reads: comparing a publisher to itself proves only that
it is consistent, never that it is right.

Verified: all four packages green; three realm mutants and two web mutants
killed; `make anchors collisions staleguards guards`, `web-test` and
`web-visual` pass.

### `modrender.gno:528` — the pending list read blocks while the rule read seconds

**I called this plan complete last iteration. It was not**, and the sweep that
should have preceded that claim is what found this: the moderation page filtered
its pending list on `heightNow() < a.openedAt+pendingTTLBlocks` while
approveAction, the bulk-act bound and the exported read had all moved to
`approvalStale`. Off 5s a block the page offers a set an entry the chain has
already discarded — the reopen link's bug on a third surface. One predicate now.

**A test that passed against the bug.** The first version asserted the row count
after the second signature, which is 1 either way because approveAction
OVERWRITES at the same key. Reverting the filter left it green. The discriminating
moment is BEFORE that signature, while the chain has discarded the entry and the
page is still offering it — measured, not reasoned: the corrected test kills the
revert.

### `p/governor` `ready` and `expiresAt` — the timelock and the grace window

Converted, and together: both are measured from `p.ready`, so converting one
would let a proposal leave its delay on one clock and expire on the other — a gap
where it is neither waiting nor executable, or an overlap where it is both.
`readyTime` joins `ready`, `inDelay` and `expired` became stamp-preferring
methods, `expiresAtTime` is `expiresAt`'s wall-clock twin, and the page and the
Execute refusal both state the moment in seconds with the block beside it.

**A ONE-SECOND ERROR HIDES BETWEEN WHOLE BLOCKS.** `advanceTo` steps five seconds
at a time, so shifting the delay or the grace by a single second SURVIVED
block-stepped assertions. Both edges are now driven on the wall clock directly.

I guessed the earlier edges "were lucky" and then checked, because a guess about
coverage is worth exactly nothing: **all 13 seconds-edge mutants in kourtv2 were
re-run against the full suite and every one is killed.** The reason is a real
asymmetry rather than luck. A test that samples EXACTLY the boundary catches a
shift in either direction. The governor's survived because it sampled
`ready - 1 block` and `ready` — five seconds apart — and the mutation moved the
boundary EARLIER by one second, into the gap between the samples, where nothing
looks. A later shift would have been caught at the boundary sample.

**So the rule is about sampling, not units:** an edge is pinned when a test stands
ON it, and a block-stepped test stands on it only when the deadline is
block-aligned. Every kourtv2 deadline is, because each seconds constant is its
block constant times five.

**And the circularity again**, in the same shape as `TimingsAt` a commit ago: the
expiry assertion took its target from `expiresAtTime`, the function under test, so
a `+1` moved both sides and survived. The expected moment is computed from the
stamp and the rule independently now.

Four pre-existing rows went stale on these lines and were repointed; two of them
looked like survivors until they were run against `r/govern` as well as
`p/governor` — **a mutant is only dead when every suite that covers it has run.**

`meta.gno:319/325/335` are NOT deadlines: they compare two stored heights for
ordering ("the target must strictly predate the appeal"), with no duration
involved. They stay.

### The sweep is clean — every package, not two

Block arithmetic in `r/kourtv2` and `p/governor` returns only the `!known`
fallback arms of converted gates, and comments.

The first version of this section swept those two packages and claimed the plan
complete. `r/govern`, `p/grc20votes`, `p/twap`, `p/cshares`, `p/tickbook`,
`p/curve` and `p/checkpoint` were not looked at. They have since been swept for
deadline-shaped height arithmetic and carry NONE — what they hold is the
accounting this plan never touches: epoch quantisation, twap buckets, checkpoint
epochs. **Two packages is not "the realm", and the difference is a sweep that
takes a minute.**

No deadline is left on blocks.

## Done so far

11 gates in the order list, 2 more the order omitted, 5 stored future heights,
7 projections, and the governor's `closes` with its consumers. Every one keeps
the `(known && passed) || (!known && <blocks>)` fallback, so a record written
before its stamp existed still behaves exactly as it did.

### `p/governor` — converted on the second attempt

The gate reads `closesTime`, the page states a countdown in SECONDS beside the
absolute moment and the block, and `Electorate`/`grc20votes.Clock` carry `Now()`
through all seven implementers.

**The obstacle was never the conversion.** Both failures the first attempt
recorded came from TEST HARNESSES DRIVING ONE CLOCK — `testing.SetHeight` moves
height and leaves block time alone, so fixtures advanced past a deadline in
blocks while `closesTime` stood still. Both harnesses now derive time from
height, which makes the lockstep structural. Underneath that sat a sharper one:
the VM's default test context starts at **height 123 with the time at genesis**,
so anything stamped before the first advance carries a deadline 615 seconds
behind its own height. `p/governor` gained `resumeClock()` for it.

**Writing the ADR first paid for itself.** Its instruction was to isolate the
r/govern failure before rewriting anything; following that found a fixture bug in
two packages instead of producing a second wrong theory about the gate.

Verified: `p/governor`, `p/grc20votes`, `r/kourtv2`, `r/govern` all green; five
mutants killed (exact second, pre-stamp fallback, stamp not written, wrong window
length, render falls back always); two pre-existing corpus rows repointed and two
added; `make anchors collisions staleguards guards` and `web-test` pass.

**Remaining:** the consumers. `DisputeVoteCloses` and `ClaimTimeline`'s dispute
row still publish heights, and the web still estimates a date from one — which is
the half of bug 1 a reader actually sees. The governor now knows the answer; the
next commit is teaching those three to ask for it.

### `p/governor` — designed, attempted, reverted; see ADR_GOVERNOR_CLOCK.md

The last site, and the only one that produced a document instead of a commit.

The plan called it "the hard one" because `p/governor` is a `/p/` package shared
with other consumers. That understated it: the change is not to the governor's
own signature but to **an interface it consumes** — `Electorate`, and through it
`grc20votes.Clock` — so every implementer of a clock moves with it, including
test fakes in `r/govern`, a realm with nothing to do with kourtv2. Seven
implementers in total.

The full implementation was written and REVERTED rather than left half-applied
in a shared package. `p/grc20votes` and `r/kourtv2` passed with it;
`p/governor`'s countdown test failed on text I had deliberately changed (expected,
and it must be rewritten rather than deleted), and `r/govern` failed two tests
with proposals not closing at all — a real failure whose cause is NOT isolated.
The patch is kept and the ADR records exactly where to resume.

**Stopping was the call.** A shared `/p/` package left half-converted, with two
unexplained failures in a realm downstream of it, is worse than a documented
design and a green tree.

### The freeze projections — two reads, two banners, and the web

`BoardFrozenUntil` and `ClaimBoardFrozenUntil` now return `(at, atHeight)`: the
moment the gate reads, with its reference height beside it. Both banners lead
with the date and fall back to the bare block for a freeze set before the stamps.
The composer said *"paused until block 123456"* to a person, which is the whole
complaint this plan started from, one screen from where a moderator acts.

**The web reads both of these**, unlike the TTL pair, so this is the first
iteration to touch `web/`. `one()` silently takes `[0]`, so reordering alone
would have fed it a unix timestamp where it expected a height — a wrong number
that renders without erroring. The two call sites use `tup()`, which already
existed; a `pair()` helper I added first was redundant and is gone.

**A CONCURRENT PROCESS'S UNCOMMITTED WORK IS IN web/index.html, and it broke
`make web-test` in a way that looked like mine.** Two harnesses failed with
`Identifier 'CONV_UNIT' has already been declared`. The A/B that should have
settled it — `git checkout` the file, re-run — reported PASS and so accused my
change, because the checkout discarded THEIR work as well as mine. What actually
identified it was reading every hunk in `git diff`: hunks at 3546 and 10987 that
I never wrote, one of them a new `const CONV_UNIT` sitting inside a region two
polish_test slices both span.

Verified by building an index.html of HEAD **plus my edits only** — `make
web-test` and `make web-visual` both pass on it — and that blob is what was
committed, staged with `git hash-object -w` + `git update-index --cacheinfo` so
the working tree keeps their changes untouched.

**A/B BY `git checkout` IS UNSOUND IN A SHARED WORKING TREE.** It answers "does
the file without ANY uncommitted work behave", not "does it without MINE". When a
diff contains hunks you did not write, reconstruct your own version from HEAD and
test that.

Verified: full kourtv2 suite green; six mutants compile and are killed (four only
after the realm gained a test asserting the published DATE, not merely a number);
`make anchors collisions staleguards guards`, check-read-purity/check-storage/
check-render-text/check-web-selectors, and web-test + web-visual on the
mine-only tree.

### `moderation.gno:1190` — the approval TTL's two projections (the inventory was wrong here)

**This entry is not a stored future height.** The inventory listed it as one —
"compute a block number in the future and persist it" — but `a.openedAt +
pendingTTLBlocks` is computed at READ time in `PendingApproval` and never stored.
It is a projection, and it is one of the two this plan deferred in iteration 5.
Both are done here.

`PendingApproval` now returns `(approvals, expiresAt, expiresAtHeight)`: the date
the write path actually gates on, with its reference height beside it — the
pairing `ClaimTimeline` already publishes. The third value is why the signature
grew rather than the second one quietly changing units, which is the failure this
whole plan exists to remove. A caller telling "nothing pending" from "no stamp"
reads `approvals`: it is 0 only in the first case. Twelve call sites and the
filetest golden updated; no web or txtar consumer exists, so the API change is
contained to this package.

The render row now reads `expires at <unix> (block <height>)`, date first, and
falls back to the bare block for an entry opened before the stamps.

**A test that named the right thing and still could not see it.** The render
assertion checked for `"approved, expires at "` and `"(block "`. Suppress the date
and the row reads `expires at (block N)` — which contains both fragments, so the
mutant SURVIVED. Fixed by asserting the absent-date form is NOT present.
**Two substring checks that each pass do not prove the thing between them exists.**

Verified: full kourtv2 suite green including the filetest golden; three mutants
compile and are killed, one only after the render assertion was sharpened; `make
anchors collisions staleguards guards` and
check-read-purity/check-storage/check-render-text pass. (`check-live-reads` needs
a running node and is not part of this loop's set.)

### `modvote.gno:563` — the post-election cooldown

Converted. `electionCooldownUntilTime` beside its height, one predicate
(`electionCooldownOpen`) read by the gate and by the render's cooldown banner —
the banner follows the gate for the same reason the ballot's phase banner does.
The duration is `decideWindowBlocks` reused, so it converts at the write site.

A zero cooldown means "never set", and both arms answer that without a special
case: with no stamp the height arm asks `heightNow() < 0`, which is false.

**The gate was covered but had NO corpus row.** Disabling it is caught by the
suite, so the rule was held — but nothing pinned its LENGTH, and
`TestElectionBelowQuorumRetains` proves only that the cooldown blocks a re-open,
never when it lifts. Four rows added (not enforced, one second late, height
fallback lost, stamp not written), all killed.

**The stale-anchor list worked as the index, in the negative.** Last commit's
lesson was that `make anchors` is a more reliable guide to what the corpus
already covers than grepping by symbol. Here it reported NOTHING stale after the
change — which correctly meant no row had ever anchored on these lines, not that
the rows were fine. A silent anchors run is a coverage question, not an all-clear.

Verified: full kourtv2 suite green; four mutants compile and are killed; `make
anchors collisions staleguards guards` and check-read-purity/check-storage pass.

### `boardmod.gno:442,444` — the claim-board freeze and its gap (the mirror)

Converted, as an exact mirror of the address half: same pair of stored future
moments, same reason for moving them together, same ordering assertion in the
test. Two near-identical predicate pairs rather than one generic pair — the
records have no common type, and inventing one to share four lines would put a
shape in the type system to serve a comment.

**The row flagged last iteration was widened here, as promised.** `FreezeClaimBoard:
the gap is stamped at the full ceiling` mutated only the height line; with the
seconds twin beside it the mutant would have been invisible. Widened to the pair
and confirmed killed. The defang sweep now returns NOTHING for the whole corpus:
no row mutates a height assignment that has since gained a `…Time` twin.

**And two rows I nearly duplicated.** My first draft added
`claimBoardFrozen: the lazy expiry (a board freeze that never lifts)` and
`FreezeClaimBoard: the re-freeze gap is not enforced` — both of which the corpus
ALREADY had under slightly different labels. `make anchors` caught it, because the
originals had gone stale on the same lines. Removed mine and repointed the
originals. Grepping the corpus by SYMBOL before adding a row is not enough when
the rule already has a row under a name you did not guess; the stale-anchor list
is the more reliable index of what already exists.

Verified: full kourtv2 suite green; six mutants compile and are killed, four
repointed or widened and two new; `make anchors collisions staleguards guards`
and check-read-purity/check-storage pass.

### `boardmod.gno:382,387` — the address board freeze and its re-freeze gap

Converted together, and the together is the point. `freezeGapBlocks` EQUALS
`freezeMaxBlocks` precisely so a set cannot hold an address frozen indefinitely
in twelve-hour increments — an argument about the two windows' RELATIVE lengths.
Convert one and not the other and on a drifting chain the gap lapses while the
freeze is still live, which is the stacking the ceiling exists to prevent,
reachable without a single suspicious call. So the test drives the wall clock
alone and asserts the ORDERING: freeze lifts, gap still bites, then a re-freeze
becomes possible.

The freeze's length is CALLER-SUPPLIED in blocks (`FreezeBoard(…, blocks, …)`,
bounded by `freezeMaxBlocks`), so it converts at the write site.

**The presence check stays on the height.** `boardFrozen` returns false on
`frozenUntil == 0` before consulting either clock — that zero means "there is no
freeze", not "the freeze expired", and it is what lets `UnfreezeBoard` lift one
with a single assignment. The stamp is cleared beside it for tidiness, which no
test can see; that row is recorded in KNOWN-GAPS with its reasoning rather than
left in the main corpus pretending to measure something.

**A NEW WAY TO SILENTLY DEFANG THE CORPUS, and this time it cost real coverage.**
Two pre-existing rows mutate `r.frozenGapUntil = now + …`. Their anchors still
matched after I added the seconds twin on the next line, so `make anchors` was
silent — but the mutants now changed only the height while the untouched stamp
kept the gap correct, and both SURVIVED. Iteration 9 recorded the shape of this
("an anchor that still matches is not proof a row still means what it said");
here it actually removed coverage rather than merely narrowing it. Both widened
to mutate the pair, both confirmed killed.

Swept the whole corpus for the same pattern afterwards — rows whose `find`
touches a height assignment that has since gained a `…Time` twin. Exactly one
more: `FreezeClaimBoard: the gap is stamped at the full ceiling`, which is still
honest today because the claim-board half is not converted yet. **It must be
widened in the same commit as that half.**

Verified: full kourtv2 suite green; nine mutants run, seven killed, the two
survivors chased to ground — one a defanged pre-existing row (fixed) and one a
deliberate survivor (moved to KNOWN-GAPS); `make anchors collisions staleguards
guards` and check-read-purity/check-storage pass.

### `meta.gno:366` — the meta-verdict execution expiry (the last gate)

Converted, and extracted to `metaVerdictExpired`.

**The `>` was carrying real behaviour with nothing holding it.** Execution expiry
had exactly one kind of coverage: deleting the guard was caught. Shortening the
window by ONE UNIT survived on BOTH arms — measured by mutating it before writing
anything. So the inclusive edge, which lets a verdict execute exactly AT
`verdictAt+votingBlocks`, was unpinned, and converting to seconds could have moved
it a second either way with the suite still green. `pastDeadline` answers `>=`, so
the seconds arm asks for `blocksToSecs(votingBlocks)+1` to keep that last instant —
a `+1` that is the edge, not a longer window, and is commented as such.

**Pinned on the predicate, and that was a retreat.** The first test drove the real
`ExecuteMetaVerdict` path — court, hidden target, matured ring, answer,
settlement, four appeals because execution is exactly-once. It failed on state
belonging to the meta lane rather than on anything this window does: first a
deposit drawn from an address that turned out to be the REALM's own
(`g1ulvf0h…`, the KOURTV2 address from the txtars) rather than the caller, then
`checkpoint: the clock went backwards` once it ran after other tests. Two
restructurings did not shift it.

Extracting the rule made it directly testable with a hand-built `claimState` and
no fixture at all. The wiring — that the guard is reached — stays held by the
existing corpus row `meta: an expired verdict may still execute`, which the suite
kills. What was missing, and is now pinned, is the edge.

**WHEN A FIXTURE FIGHTS BACK, ASK WHETHER THE RULE WANTS TO BE A FUNCTION.** Three
of these conversions ended in a shared predicate (`approvalStale`,
`reSetWindowOpen`, `escrowPassed`) because two callers had drifted. This one ended
in a predicate because one caller was unreachable from a test.

### Gates: complete

A sweep for block arithmetic now returns only reads of STORED FUTURE HEIGHTS —
`frozenUntil`, `boardFrozenUntil`, `frozenGapUntil`, `boardFrozenGapUntil`,
`electionCooldownUntil` — which is the next batch, plus the fallback arms of
converted gates. No plain gate is left on blocks.

Verified: full kourtv2 suite green; four mutants compile and are killed, including
the two edges that survived beforehand; `make anchors collisions staleguards
guards` and check-read-purity/check-storage pass.

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
