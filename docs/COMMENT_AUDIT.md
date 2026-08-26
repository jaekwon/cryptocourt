# COMMENT_AUDIT — a systematic audit of the comment system

Scope: `board.gno`, `boardlegal.gno`, `boardmod.gno`, `posting.gno`,
`standing.gno` (3,311 lines), their render surfaces in `render.gno` and
`modrender.gno`, their state on `claimState`/`courtMod`/`claimMod`/`Court`, and
the guards that hold them. **26 write entrypoints, 23 exported reads.**

## How this audit works

One dimension per pass, depth over breadth. A dimension is DONE only when every
claim in it is *proved*: a defect by a failing test or a surviving mutant, a
guarantee by deleting the guard and watching a test fail. Reading the code and
finding it plausible is not an audit and does not earn DONE.

Four verdicts, never conflated — **CAUGHT**, **SURVIVED**, **INVALID** (the
mutant did not build), **ANCHOR-FAIL** (the anchor did not match exactly once).
Ten phantom verifications this session came from folding INVALID into CAUGHT.

Findings are graded:

- **BUG** — provable wrong behaviour. Fix and pin in the same pass.
- **GAP** — behaviour is right, nothing holds it. Pin it.
- **RULING** — needs an owner decision. Record in `CLAIM_BOARDS.md`, never fold in.
- **NOTE** — true and worth writing down; no action.

## Dimensions

| # | dimension | status |
|---|---|---|
| 1 | **State and storage** — `boardRow` fields, the six trees, what a comment costs to keep | **DONE** |
| 2 | **The write path** — `PostComment`: every gate, their ORDER, what a refusal costs | **DONE** |
| 3 | **The upvote path** — `UpvoteComment`, weight snapshotting, one-vote-per-address | **DONE** |
| 4 | **Author control** — `HideOwnComment`, and what an author may not do | **DONE** |
| 5 | **Text safety** — the two chokepoints, sanitize choice, wire escaping, length/empty | **DONE** |
| 6 | **Ordering and index integrity** — score index invariants, re-keying, pagination bounds | **DONE** |
| 7 | **The read/wire surface** — 23 reads: answer vs panic vs allocate, format stability | **DONE** |
| 8 | **The render surface** — every page, every branch, what a user is told and not told | **DONE** |
| 9 | **Court moderation** — hide/unhide, both freezes, slash interaction, suspension | **DONE** |
| 10 | **The legal lane** — redact, clear, purge row, purge range, the two code sets | **DONE** |
| 11 | **Economics** — cost of a comment, throttle arithmetic, pass, caps, §16 | **DONE** |
| 12 | **Lifecycle** — terminal states, purged court, fresh court, epoch boundaries | **DONE** |
| 13 | **Cross-cutting invariants** — S1–S14 and I1–I12 as they touch comments | **DONE** |
| 14 | **Authority perimeters** — all 26 write verbs: who, threshold, log, event, backstop | **DONE** |
| 15 | **Guard coverage** — is every guarantee above held by something in `make check`? | **DONE** |

## Findings

### D15 — Guard coverage

The question this audit had to end on: a green `make check` means what, exactly?

**THREE OF THE STRONGEST GUARDS ARE NOT IN IT.** `mutate`, `isolation-test` and
`selftest` are all separate targets, deliberately, because they cost roughly an
hour, forty minutes and twenty-five minutes. So:

| guarantee | held by | in `make check` |
|---|---|---|
| behaviour — every test in this audit | `realm-test` | **yes** |
| corpus rows still MATCH the code | `anchors` | **yes** |
| mutants are distinct, parse, and BUILD | `collisions` | **yes** |
| the censuses (S1 arm 17, purge verbs, render text, spend paths, read purity) | `realm-test`, `paths`, `rendertext` | **yes** |
| reads write nothing | `realm-test` (filetests) | **yes** |
| **mutants are still CAUGHT** | `mutate` | **no** |
| **tests pass ALONE** | `isolation-test` | **no** |
| **every guard's control still fires** | `selftest` | **no** |

So the ~150 corpus rows this audit added are held against *drift* — they still
match, still build, still differ — and not against *decay*: delete the covering
test and the row silently becomes a survivor that only an hour-long batch finds.
That is a real limit and it is structural, not a defect. What it means in practice:
**green is necessary and not sufficient**, and a change that touches this lane
wants `make mutate` before it is called done.

**FIXED — the directory-admin trap, at its root.** It inverted three
moderator-perimeter tests this session, each time invisible when the suite ran
together, each time caught only by `check-isolation` — which is one of the three
targets NOT in `check`. `directoryAdmin` is the first court creator in the package
and the global DAO's bootstrap member, so a fixture that creates the first court
makes its own subject the global DAO. `modFixture` bootstrapped a throwaway court
against this; `boardFixture` did not, and three tests spelled the workaround
locally. `boardFixture` now bootstraps too, the three local copies are gone, and
their assertions remain as tripwires. A trap that only an out-of-band target can
catch is better removed than watched.

**The audit's own additions to the gate.** Two guards were added while auditing,
both inside `make check`: `check-mutant-collisions`' fourth arm (a mutant that
parses but cannot BUILD — the flaw that produced ten phantom verifications), and
`check-epoch-coherence` arm 17 (S1: no money path reads board or standing state).
Both carry selftest controls, so they are covered by `selftest` even though
`selftest` is not in `check` — the same two-level structure as every other guard
here.

**AND THE FIXTURE FIX PRODUCED THE SAME BUG FROM THE OTHER SIDE.** Bootstrapping
inside `boardFixture` let me delete three local workarounds — and two of those
tests read `ensureGlobalDAO().admin` BEFORE calling the fixture, which had been
fine only because the deleted `testCourt` line came first. `ensureGlobalDAO`
panics outright when no court exists ("the global DAO has no admin"), so both
tests passed together and died alone: the identical run-alone/run-together split
the trap itself produces, arriving from the opposite direction. Caught by the
sweep I started to confirm the fix. Both now read the admin after the fixture.

The lesson is narrower than the trap and worth keeping separate: **anything that
reads package-global bootstrap state must run after something has created it**,
and "it worked" before a refactor can mean "a line I just deleted was carrying
it".

**What remains uncovered, stated plainly:** S5 has no differential test (D13),
`make check` does not run the mutation corpus, and four owner rulings plus the two
amended invariants are recorded rather than resolved.

### D14 — Authority perimeters

The matrix was built mechanically across all 26 write verbs — authority,
threshold, log row, event — because a defect here is an ASYMMETRY rather than a
single bad gate, and asymmetries are invisible one function at a time. Two showed
up immediately.

**BUG (fixed) — the two global RECOVERY verbs wrote no log row.** Every other
global verb in the lane writes one: `GlobalHideRow`, `GlobalClearRow`,
`PurgeBoardRow`, `PurgeBoardRange`, `PurgeCourtLogRow`, `GlobalClearCourtParams`.
`GlobalClearBoardBits` and `GlobalRestoreStanding` emitted an event and wrote
nothing to the court's own page. So `/mod` recorded the slash and the freeze and
carried no trace that the platform reversed them — **the accusation without the
acquittal**, on the surface whose whole job is making curation visible after the
fact. Worth noting how it happened: `GlobalClearCourtParams` is newer and does
log, so writing the newest verb correctly is what made its two older siblings
look wrong.

**GAP (closed) — the two realm-wide default setters were completely silent.**
`SetLadderDefault` and `SetCreditRatesDefault` move the floor under EVERY court at
once — the widest acts in the lane — and wrote no log and emitted no event, while
their per-court counterparts do both. There is no single court to log them
against, which makes the event the only record there can be, and only a
filetest's `Events:` directive can observe `chain.Emit`. Both now emit, and both
are asserted in `z_events_filetest.gno` — the file written for exactly this, whose
own note says *"an event nobody asserts is an audit trail nobody has checked
exists"*.

**NOTE — that filetest's headroom is nearly gone.** 58,874b against a 60,000
ceiling, about 1.1kb left, and `check-storage.py` now says so at the budget entry.
The next act added there needs a deliberate ceiling raise with a reason, or a
second events filetest. Raising it silently to make room would turn a budget into
a formality.

**VERIFIED — the rest of the matrix is coherent.** Sanctions take
`requireActiveMod` and their undos take `requireMod`, so de-escalation survives a
suspension, uniformly across all four pairs. Every court verb fires at `speechM`
and every global verb at `d.purgeM` or a single key, with no verb sitting at a
threshold weaker than its siblings. The three user verbs (`PostComment`,
`UpvoteComment`, `HideOwnComment`) correctly write no log: a comment is not a
moderation act, and the row is its own record.

### D13 — Cross-cutting invariants

Fourteen S-invariants, walked against what the audit proved. **Two are false, one
was unguarded and now is not, one is unbuilt pending a ruling, and ten hold.**

**S1 — now GUARDED, not merely true.** "No money path reads board, standing,
level, pass, vote or freeze state." It held on inspection: zero reads across every
file that moves coin, and exactly four credit-hook calls the other way. Nothing
enforced it, which for a ONE-WAY coupling is the whole risk — the first read looks
harmless at its call site and is invisible from the other side. `check-epoch-coherence`
arm 17 now derives the money lane from every file calling
`coin.Transfer/Mint/Burn` and refuses a board or standing read from any of them,
counting the four permitted writes. Its selftest control plants the realistic
first read — a settlement asking the author's level — and fires.

Why it matters beyond tidiness: if a payout could read a level or a vote, a
flooded board would move money, and **S5** ("a claim settles identically to the
same claim with no bits set") would be false. S1 is what makes S5 true by
construction.

**S9 — FALSE for throughput, measured (D11).** The rank half holds: upvote weight
is linear in score, so any partition sums to the same total. Throughput does not —
the ladder is strictly anti-convex and a 20-way split doubles posts/day. Amended
in `CLAIM_BOARDS.md` with the measurement and ruling 0e.

**S11 — FALSE, unimplemented (D9).** Nothing masks. Amended, keeping the two
clauses that ARE true: the freeze clock is never paused, and the undos take
`requireMod` so a suspended set can de-escalate.

**S14 — unbuilt**, blocked on rulings 1 and 2. Not a defect; recorded as pending.

**Holding, and covered by earlier dimensions:** S2 (no moderation path touches
`answerRecord` — verified by grep, the record is written only by the answer lane),
S3 and S4 (the single burn, guarded by `check-spend-paths` and arm 7's
`COIN_OUT_N`), S6 and S7 (D10's purge and range verbs), S8 (D1's `highWater`
rules and the standing rows), S10 (D9's backstops), S12 (D9 — a board act writes
board state and the log; no board verb touches an election field), S13 (the
`speechM` formula, killable at both ends).

**NOTE — S5 is the one invariant this audit did not test directly.** "A claim
settles identically to the same claim with the same board and no bits set" is now
true *by* S1's guard rather than by observation: no settlement code can read the
board, so no board state can reach a payout. A differential test — settle the same
claim twice, with and without comments, and compare every balance — would assert
it end to end. Recorded as the one gap D13 leaves open.

### D12 — Lifecycle

**GAP (closed) + copy fix — your LEVEL falls as the court grows, with no act by
anyone.** The rungs are bps of a sealed supply that only increases, so an
untouched score crosses back down a rung on its own. §2.3 says "standing never
decays; it falls only by a logged moderator slash" — true of the NUMBER, and
silent about the rung, which is what actually gates posting. The page printed
"25 bps of supply", the machinery, and never the consequence.

`TestALevelFallsAsTheCourtGrowsWithNoSlash` sits an address exactly on rung 2,
grows the court, and shows the level at 1 with the score and high-water mark
untouched. It also pins what a user in that position will reach for and not find:
`RestoreStanding` correctly refuses, because it raises score toward highWater and
the two are equal — the remedy for a slash cannot give back a rung the bar took.
The page now says the bar is a share of the court's supply and that a score which
does not move can still fall below a rung it used to clear.

**GAP (closed) — no legal act had ever been tested on a SETTLED claim**, which is
the ordinary case for a notice rather than the edge one. The board closes to
comments and votes at settlement (D3), and the legal verbs deliberately carry no
`boardOpen` gate: an obligation to remove material does not expire because a
market did. Nothing exercised that, so the absence of the gate was
indistinguishable from an oversight. Now redaction, its counter-notice put-back,
a single-row purge and the whole-board range purge are all exercised after
`verdictAt` is set, and adding a `boardOpen` gate to either verb is caught.

**VERIFIED — the terminal predicate and the fresh-court boundary** were already
covered by earlier passes: both terminal shapes and the purged court for writes
and votes (D3), and the sealed-epoch boundary that used to abort a brand-new
court's board (fixed and pinned earlier this session).

**NOTE — one more wrong expectation of mine, and the code was right.** I asserted
`RestoreStanding` would refuse on authority; it refuses on state, because the
fixture's address is the court's own 1-of-1 moderator. The corrected assertion is
the stronger one — it shows the remedy is absent rather than merely forbidden.

### D11 — Economics

**FINDING (measured, ruling recorded) — the shipped ladder REWARDS splitting, by
up to 2x.** §4 asks for convexity: concentrating standing must be at least as good
as splitting it, which requires `rate(l)/tau(l)` to be non-decreasing in the rung.
Shipped it is strictly decreasing, so every rung below the top pays better per
unit of standing:

	rung  tau(bps)  rate/day  rate/tau  split into  posts/day  vs concentrated
	 1        5         3       0.600      20          60          2.00x
	 2       25        10       0.400       4          40          1.33x
	 3      100        30       0.300       1          30          1.00x

§13 predicted this in words — "corrected, the condition demands tau(2) <= tau(1)
and is unsatisfiable by any multi-rung ladder" — and nothing had measured it.
`TestWhatThroughputCosts` now asserts the factor at both rungs and fails if the
ladder ever becomes convex, so a recalibration shows up as a change here rather
than as an argument. Ruling in `CLAIM_BOARDS.md`: satisfying convexity needs
`tau(3)/tau(1) <= 10` (so t3 at most 50 bps, not 100) or a rate ratio above the
frozen 10x — and both numbers are settled owner rulings.

**VERIFIED — the pass is the only purchasable throughput, and the burn is real.**
Standing cannot be bought; a pass buys exactly `rate(1)` a day for ever, and
supply falls by exactly the price, so throughput comes out of the court's float
rather than moving to anyone.

**RECORDED — the price of filling one claim's whole board.** The caps bound
concentration (512 rows, 8 per author) so it takes 64 addresses and 64 passes.
`TestThePriceOfFillingAYoungCourtsBoard` states that as basis points of the
court's own sealed supply and fails if the calibration moves it past 100 bps or
rounds it to free. The binding cost is time, not money: eight rows per address at
the entry rate.

**VERIFIED — the throttle arithmetic was already covered** (a full day, seven
days, and the remainder case that makes the rate independent of how often a
poster checks). No new work needed.

**METHOD — the third tautological assertion this session.** `passPriceFor`'s bps
line survived because the test compared `BuyCommentPass`'s return against
`passPriceFor(c)` — both sides run the same code, so any mutant inside it
satisfies both. The bps arithmetic is now written out in the test so the assertion
has something of its own to compare with. Together with D7 (a score field asserted
while every score was 0) and D8 (a badge's absence asserted while the field was
empty), the pattern is clear enough to state as a rule: **an assertion that
re-derives its expectation from the code under test measures nothing**, and a
surviving mutant is a reason to read the assertion before reading the code.

### D10 — The legal lane

Each verb's own gates were already tested. What nothing exercised was the STATES
MEETING EACH OTHER, and all three interactions were wrong in the same direction —
an act permitted where it can have no effect.

**BUG (fixed) — a second purge of the same row was a fresh act.** `PurgeModLogRow`
states the rule for its own log — *"already tombstoned; a second purge is a no-op,
not an error"* — and the board verb did not follow it. A repeat consumed an m-of-n
proposal, and at `purgeM > 1` that means coordinating signatures, to re-zero bytes
that were already gone and write a second log row for it. Now checked before the
vote.

**BUG (fixed) — a PURGED row could be REDACTED.** The bytes are gone and there is
no un-purge, so the act cannot change what anyone sees. It nevertheless set
`r.global`, armed the re-set window, recorded a redaction in the log and emitted
an event. Refused now, with the same reasoning as D3's purged upvote: this realm
does not charge for acts whose effect is unreachable by construction. Three
findings across two dimensions now share that shape, which suggests it is worth
checking at every new verb rather than case by case.

**BUG (fixed) — the board never said its CLAIM was under a legal act.** `board.gno`
read no claim-level legal state at all: not `clm.purged`, not `clm.global`, not
`TextRedacted`. A claim redacted under a notice kept a fully readable discussion
of itself, and neither a reader nor an operator answering that notice could tell
from the page. The separation is deliberate and stays — §7.6 exists precisely so
one infringing comment does not force the whole claim to be redacted — but it is
now stated on the page: *"The claim itself is withheld or removed on legal
grounds. These comments are a separate record and are not covered by that act."*

**RULING — should a claim-level legal act CASCADE to its board?** §7.6 settles the
upward direction (a comment must not redact its claim) and never addresses the
downward one. Recorded in `CLAIM_BOARDS.md`. The notice now on the page is
informational and changes no capability, so it holds either way.

### D9 — Court moderation

Most of this lane was built with tests and the earlier passes closed the
threshold gaps. What was left was suspension, and it does not do what the realm
says it does.

**BUG (fixed) — the moderation page promised a masking the realm does not
perform.** It printed *"suspended — their hides are masked and they cannot act"*.
The second half is true. The first is not: **no visibility predicate anywhere
consults `cm.suspended`.** Every reader of that flag is an authority gate
(`requireActiveMod`, `isActiveMod`, the `AppointMods` refusal), a state
transition, or meta's staleness stamp. `HiddenFromListing` is
`clm.court || clm.meta || clm.global`, and `boardMark` reads the row's own bits.
So a suspended set's hides keep hiding and its freezes keep freezing, and the
court's own page told a reader their content was back when it was not. The copy
now states what is true: they cannot take new acts, the sanctions already in place
stand until cleared, and any member may still lift their own.

**RULING — should suspension actually mask?** §7.4 asks for it. It is
unimplemented for claims and for the board alike, so this is realm-wide rather
than a board defect, but the board inherits it and the page that now renders the
board threshold is where the false claim sat. Recorded in `CLAIM_BOARDS.md`,
because it cuts both ways: unmasking on suspension republishes everything the set
had hidden — including content hidden for good reason — at the exact moment
nobody is authorised to re-hide it.

**VERIFIED — the sanctions are independent of the suspension, deliberately.** A
suspended set's hide and freeze both hold, a frozen address is still refused a
post end-to-end, and the de-escalation half is real: any member may still lift
their own acts while suspended.

**VERIFIED — a slash to zero silences VOTING as well as posting.** `w <= 0`
refuses an upvote, so the sanction reaches the ranked view and not only the
comment box. That is the intended reach of a slash and it was worth confirming
rather than assuming, since the two are gated in different files.

### D8 — The render surface

**The largest single gap in the audit: TEN of eleven render branches were
unheld.** Earlier work fixed four *wiring* defects here — pages that did not
exist, reads with no caller — but the CONTENT of the pages was asserted by almost
nothing. All ten are now caught.

**GAP (closed) — every one of the five badge behaviours was deletable.** The
badges are how a reader learns who has money on the question; `boardBadges`' own
note says the ordering deliberately does not rank by stake, "the reader is told
who has money on the question and decides for themselves". So a wrong badge
mis-attributes stake on a page people bet on, and all five were free to break:
the author badge, the answerer badge, the answerer badge's *freeze* precondition,
a position's SIDE, its AMOUNT, and the rule that a closed position earns no badge
at all. `TestTheBadgesNameWhoHasMoneyOnTheQuestion` puts real positions on both
sides, at different amounts, so side and amount are independently observable —
naming only one would have read the same as naming the wrong one.

**GAP (closed) — the page's counts and its copy.** The "N older comments" tail,
the "Nothing else upvoted yet" line, the invitation naming who may comment, and
the distinction between a MALFORMED comment id and a MISSING one — a client shows
different things for those two and the messages were interchangeable.

**NOTE — one assertion of mine was wrong about the page, not the page about
itself.** I expected "Nothing else upvoted yet" on a large cold-start board. It
does not fire there and should not: at cold start every row sits in the index at
score 0 and the ranked view lists them all (D6). The line fires when every
indexed row is already held by a reserved slot — a one-row board by the claim's
author. Fixture corrected to the real condition.

**NOTE — the same fixture mistake as D7, again.** The answerer badge's `frozenAt`
guard survived because I asserted the badge's absence while `cs.answerer` was
still empty: `who == cs.answerer` is false for everyone either way, so dropping
the freeze half read identically. A guard is only observable in the state where
its two halves disagree — here, "answerer known, claim not yet frozen". Twice now
the surviving mutant has been my fixture rather than the code; the rule is to
construct the state where the guard's clauses can differ, and to distrust an
assertion that passes against a zero or an empty.

### D7 — The read and wire surface

**GAP (closed) — the wire contract was published and pinned by nothing.** No test
split a row on `|` or counted a field. Add a column, reorder two, or change the
mark alphabet and every client breaks with the suite green — and these reads have
no alternative, because `Render()` cannot know who is asking. The contract, now
asserted:

	BoardNewest   id | author | replyCount | mark | text   (5 fields)
	BoardTop      id | author | score      | mark | text   (5 fields)
	BoardReplies  id | author | mark       | text          (4 fields)

**Text is always last, mark always second-to-last**, and that ordering is what
lets text carry a pipe unescaped — a bounded `SplitN` recovers it whole where a
naive `Split` over-counts. `TestTheWireContractIsFixed` posts a comment and a
reply that both CONTAIN pipes, which no test had ever produced, and walks the
mark alphabet `. h g x` through all four states checking the field count never
moves: a withheld row emits its mark and an EMPTY text field rather than dropping
the field. `BoardRowState` is checked to agree with the wire.

**GAP (closed) — `CommentsWrittenBy` was exported and never tested.** It is the
read a client shows as "N of 8"; returning a constant 0 left the suite green.

**VERIFIED — no derived read reimplements a rule.** `PostsPerDay` is
`postsPerDayAt(ladderFor, postLevel)`, `PostsAvailable` takes `bucketAt`'s answer
and discards the stamp, `Standing` reads the same field `StandingBreakdown`
packs, `BoardSize` reads the tree `PostComment`'s cap reads. Each killable
independently. This is the failure mode the realm has already suffered once —
`refill` and `PostsAvailable` were two copies of one arithmetic and three
mutations of the write path survived because every assertion read the other copy —
so the absence of a second copy is worth stating.

**NOTE — two of my three surviving probes were fixture mistakes, not gaps.** I
asserted `BoardTop`'s score field while every score was 0, so a mutant hardcoding
`"0"` read identically; and I checked a reply's mark only in the visible state. A
constant in a mutant that matches the fixture's value is a mutation that measures
nothing, and it looks exactly like a passing assertion. The rule that follows:
never assert a numeric field against a value the fixture leaves at zero.

### D6 — Ordering and index integrity

**GAP (closed) — at cold start the row-id half of the key was the only thing
keeping rows apart, and nothing tested it.** `boardScoreKey` is
`beInv(score) + beInv(rowID)`. Drop the id half and two rows with equal scores
produce the SAME key, so the second `Set` overwrites the first and a row
disappears from Top entirely. Every score is 0 before anything is upvoted, so the
whole board collapses to one entry — and every existing ranking test gave its rows
distinct scores, so none of them could see it.
`TestColdStartTopListsEveryRowNewestFirst` now asserts four unvoted rows produce
four lines, newest first, and that the two orderings agree exactly while nothing
is upvoted. That degeneracy was documented and never checked.

**GAP (closed) — neither ordering's page clamp was tested.** Both clamp `count`
to `maxBoardRepliesShown*8`; every existing read asks for 5 or 10, so deleting
both clamps left the suite green. The clamp is what bounds the response a single
query can demand, and `offset`/`count` arrive from a client.
`TestBothOrderingsClampThePageTheyWillServe` asks for 100,000 against a board of
65 and requires the clamp to bind.

**VERIFIED — hostile pagination is answered, not panicked on.** bptree clamps a
negative offset to 0 itself and returns nothing for `offset >= size`, so a client
cannot fault a read with either. Asserted rather than assumed.

**VERIFIED — the sort is descending by score, ties newest-first.** Both halves
killable independently: an ascending key gives a worst-first Top, and an
ascending tie-break breaks the cold-start degeneracy.

**VERIFIED — `IterateByOffset` counts rows VISITED, not kept.** Read from
bptree's source: `visited++` runs after the callback regardless of what it
returns. That is the whole reason the score index must hold only visible rows —
filtering at read time would short-page by an attacker-chosen amount — and it is
now a read fact rather than a comment.

**KNOWN GAPS (both proved equivalent, both kept) — the two `scoreIndexDrop`
guards.** Clearing `scoreKey` cannot matter, because keys are unique per row so a
stale key can only ever name this row's own absent entry. Removing the STORED key
rather than a recomputed one cannot matter *today*, because `r.score` has exactly
one writer and the drop there precedes the mutation. Both are the defence against
a future `r.score += w` placed before the drop — which would orphan the old entry
at a stale rank — and the second is the stated reason the field exists at all.
Recorded with the proofs rather than deleted.

### D5 — Text safety

The escape set was measured, not assumed, and **nothing had asserted any of it**.
`sanitize.Block` was chosen over `BlockRich` and `InlineText` for stated reasons
and a switch either way was silent. Now pinned, with the variant choice itself
killable three ways.

**What the display gate does, measured.** A comment's `# heading`, `---` setext,
`| a | b |` table row, `* list` and `> quote` all come back escaped, so a comment
cannot promote itself out of its own block or restructure the page outline. A
`[ref]: http://evil` link-reference definition is **removed entirely** rather than
escaped — it would otherwise bind a name realm chrome elsewhere on the page could
resolve.

**RESIDUAL (accepted, realm-wide, now measured for comments) — a comment can
render working HTML.** CommonMark HTML block types 6 and 7 — `<div>`, `<table>`,
`<form>`, any `<foo>` — are not escaped in any sanitiser mode. A comment of
`<form action="http://evil"><input name=p></form>` reaches the page intact. What
`Block` guarantees is *containment*: the symmetric `\n\n` envelope makes the
block close on a blank line, so it cannot extend into the realm's own output.
Verified both halves — the envelope is present and `renderBoardOne`'s own `---`
separator still stands alone after an unclosed `<div>`.

The realm knows: `check-render-text.py` says so in as many words. It is sharper on
a comment board than on a claim body, because comments are cheap, numerous and
written by strangers while a body costs a deposit and a claim — a `<form>` that
*looks* like realm chrome is a phishing surface inside its own paragraph. Nothing
in the realm can fix it; it is gnoweb's to escape or the sanitiser's to extend.

**VERIFIED — the two gates differ, deliberately, and the gap is now visible.** The
wire hands over the link-reference definition the page drops, because a client
sanitises for its own context. `TestTheWireGateCarriesWhatThePageDrops` asserts
both sides from the same row, so a client author can see the contract rather than
infer it.

**KNOWN GAP (proved equivalent) — the author-address escapes cannot be killed.** A
bech32 address is `g1` plus lowercase alphanumerics, so it holds no CommonMark
metacharacter and `InlineText` cannot change it. Kept rather than deleted: it
costs nothing and matches every other address print in the realm. Recorded with
the proof, and with the note that the *other* `InlineText` calls nearby — a claim
title, a moderation tombstone — are free text and their escapes ARE killable.

**TOOLING — `testing.SetRealm` does not work inside ANY closure**, not just a
deferred one. A `post := func(...)` helper made six escape assertions fail at
"level 0, cannot post": the caller identity belongs to the test frame, not the
closure. Recorded in `VERIFYING.md`, generalising the deferred-restore note.

### D4 — Author control

Six gates and one structural property, all proved by deletion.

**RULING — after settlement a vote cannot change the board's order, but the
author's own hide can.** None of the three hide verbs reads `boardOpen`. For the
two moderator verbs that is necessary: an abusive comment on a settled claim must
stay moderatable. For `HideOwnComment` it leaves the asymmetry D3 just closed on
the other side — a standing-weighted vote is refused after settlement *because* it
re-ranks a record nobody can reply to, and an author's hide does exactly that, by
the one participant with the most reason to, after the verdict is known.

`TestASettledBoardsOrderIsStillEditableByItsAuthors` shows both halves on one
board at one moment: the vote aborts, the hide lands and drops the row from Top,
and it stays reversible indefinitely.

The counter-argument is real, which is why this is a ruling and not a fix. The row
serves at its own link throughout, so this is curation of the LISTING, not
destruction of evidence — and an author who regrets a remark on a settled matter
has a legitimate claim to withdraw it from the front page. Recorded in
`CLAIM_BOARDS.md`; the test pins today's behaviour either way.

**VERIFIED — hiding is not a way around the per-author cap.** board.gno states it
("otherwise self-hide would be a way to post nine comments by hiding one") and
nothing tested it. `boardWrote` only ever increments, so the property is
structural; the mutant that expresses the defect directly — decrement on hide —
is now caught by `TestHidingDoesNotBuyAnExtraComment`, which hides all eight rows
and is still refused the ninth.

**VERIFIED — only the author, the row must exist, the bit follows the argument,
and the index moves both ways.** A hide drops the row from Top and an unhide
returns it, each caught independently, so the pair cannot half-rot.

**NOTE — `HideOwnComment` charges no allowance.** It is the only board write that
does not. Toggling is therefore free of the daily budget, though not of gas, and
it grows no state (one bool, one index key removed and re-added). Deliberate as
far as the design goes: withdrawing your own words should not be rationed. Worth
knowing it is the one exception.

**NOTE — two of my six mutants were wrong, not the code.** One orphaned `who` and
did not build; the other skipped the author counter only when a row was already
withheld, which at post time is never — a no-op dressed as a mutation. Both were
caught by the tool classifying INVALID and SURVIVED separately, which is the
reason that distinction exists.

### D3 — The upvote path

Fifteen gates, all now proved by deletion.

**BUG (fixed) — a PURGED row could be upvoted, and the vote could never do
anything.** `UpvoteComment` read the COURT's purge flag and never the ROW's.
Hidden and redacted rows banking score is deliberate: both states are reversible
and `scoreIndexPut` re-ranks them correctly on the way back. A purge is the one
state that never comes back — the bytes are gone and the row is out of the ranked
index for ever — so the vote spent a scarce daily allowance on an effect
unreachable by construction. That is the write path's own rule ("every refusal
before the throttle, so a rejected call costs no allowance") applied to a call
that was not refused and should have been. One gate, no capability lost;
`TestAPurgedCommentCannotBeUpvoted` pins both halves, including that a HIDDEN row
still banks score, so the distinction is the tested thing rather than a comment.

**GAP (closed) — voting on a SETTLED claim was unguarded by any test.** Deleting
`boardOpen` from the upvote path left the suite green; every vote test ran on a
live claim. It matters more than it looks: a settled board takes no new comments,
so a standing-weighted vote after settlement re-ranks a record nobody can reply
to. "What is here stays" has to include the order it is in. Both terminal shapes
— `closed` and `verdictAt` — plus the purged court are now pinned, with a
live-claim control so the refusals cannot pass for a voter who could never vote.

**VERIFIED — the vote key cannot collide.** `beClaimKey(rowID) + string(who)`
puts the fixed-width row key first, so the address is the unambiguous remainder
whatever its length; deleting the row half is caught.

**VERIFIED — a duplicate vote costs no allowance.** The once-per-address check
sits above `mustSpendPost`, the same ordering the write path keeps, and the
allowance draw itself is caught.

**VERIFIED — the weight is the voter's own standing**, not a constant, and an
upvote needs standing rather than a pass: a level-1 pass-holder with zero score
is refused. That is what keeps the ranking on earned signal.

**NOTE — one address may upvote every row on a claim.** The once-per-address rule
is per ROW, so 512 votes per claim per voter is the ceiling, each costing an
allowance draw. This is the `boardVoted` product D1 recorded; nothing else bounds
it.

### D2 — The write path

Eleven gates, in order: stale realm, purged court, claim exists, board open, both
freezes, empty text, byte cap, parent exists, depth one, per-author cap,
per-claim cap, throttle. **All eleven now proved by deletion.**

**GAP (closed) — the per-claim cap was untested.** Deleting
`cs.board.Size() >= maxBoardRowsPerClaim` left the suite green: no test had ever
filled a board. That is the number `renderBoardIn` pages against,
`boardPartyRows` scans and `BoardSize` reports, and D1 recorded it as the bound
the other five indexes inherit — so the one gate holding read cost was the one
nothing held. `TestThePerClaimCapBoundsWhatOneBoardCanCost` fills the tree
directly (the gate reads `Size()` and nothing else; 512 real posts would cost 64
primed authors and minutes of suite time to exercise one comparison) and asserts
the refusal, that a reply is refused by the same ceiling, and that the refusal
costs no allowance.

**HYPOTHESIS REFUTED — "every refusal before the throttle" is load-bearing after
all.** I expected it to be vacuous: an abort reverts state on chain, so a
throttle spent before a later refusal should un-spend itself. Moving
`mustSpendPost` ahead of every content and cap gate — a genuine move, spent
exactly once — was CAUGHT by `TestARefusedCommentCostsNoAllowance`, the test
whose name matches the claim. In the test VM a recovered abort leaves the write
visible, so the ordering is observable there; and on chain it still matters for a
reason the comment does not give — this realm is full of verbs that spend and
then `return` without firing when an m-of-n is short, and a `return` does not
revert. The ordering is the habit that makes those safe.

**NOTE — the 2,000 cap is BYTES and the refusal says "characters".** A comment in
a three-byte-per-rune script is cut off at ~666 of the 2,000 it was promised.
Consistent with every other length check in the realm, so not a defect, but the
asymmetry is now pinned by `TestTheCommentCapIsBytesNotCharacters` rather than
left to be rediscovered.

**NOTE — `mustBoardWritable` reports the claim-board freeze before the personal
one.** When both are live the poster is told the wrong thing: the claim freeze
lifts without them, the personal one is about them. One line to swap; not
touched because the ordering is a UX judgment, not a correctness one.

**VERIFIED — a refused comment allocates nothing.** `ensureBoard` runs after
every gate, so a refusal on text, on a missing parent, or on either cap leaves
all six indexes nil. Pinned by `TestARefusedCommentAllocatesNoIndex`, because
"after" is an ordering and orderings drift.

### D1 — State and storage

**RULING — the per-author cap counts replies, and it silences the party under
scrutiny.** `maxBoardRowsPerAuthor` (8) is checked against `boardWroteBy`, which
counts every row an address wrote on the claim including replies. The cap's own
documented rationale is *"a PAGE-COMPOSITION rule and not a rate limit"* — but a
reply is not a page-level row; it renders nested under its parent and occupies no
page slot. So the budget is spent on rows the cap does not exist to bound.

The consequence is asymmetric, and it works against §5. A claim's author is
structurally the most-replied-to participant, and the reserved slot exists so they
"can answer a question about their own claim and have the answer seen". Answer
eight questions and the slot is empty: `TestTheAuthorIsSilencedByAnsweringQuestions`
posts one top-level comment, takes seven questions, answers all seven, and the
author can then post nothing at all — while each questioner has spent 1 of 8.

Not folded in, because every repair is a design change: count only top-level rows
toward the page cap and bound replies separately; or give the parties a higher
cap; or leave it and accept that answering is rationed. Recorded in
`CLAIM_BOARDS.md`; the test asserts current behaviour so the choice is visible
either way.

**NOTE — `boardVoted` is the only unbounded term in a design that caps
everything else.** The per-claim growth, all of it:

| tree | bound |
|---|---|
| `board`, `boardTop`, `boardKids` | ≤ 512 rows (`maxBoardRowsPerClaim`) |
| `boardWrote` | ≤ 512 (an author needs ≥1 row to appear) |
| `boardScore` | ≤ 512 |
| `boardVoted` | **rows × distinct voters — uncapped** |

Text is bounded at 2 KB a row, so the row bytes cap near 1 MB a claim. The vote
index has no cap: 512 rows × V voters, and V is limited only by how many
addresses hold standing. It is self-limiting economically rather than by rule —
an upvote requires `score > 0` (earned, not bought), costs the voter an allowance
draw, and in gno the caller pays the storage deposit for state they create — so
the growth is paid for by whoever causes it. Worth knowing it is the one term
that scales as a product.

**VERIFIED — every `boardRow` field is read.** `atTime` and `legalCode` were
write-only and were deleted; `at` was on the same list and is now rendered as the
citation date. No field on the row is dead.

**VERIFIED — row ids are stable citations.** `boardNextID` only increments, per
claim, and nothing removes from `cs.board`, so a deep link never changes meaning
and `board.Size()` is the true row count. That is what lets the per-claim cap and
`BoardSize` read the same number.

**VERIFIED — no orphan rows.** A reply writes `board`, `boardKids` and
`boardWrote` and correctly touches neither `boardTop` nor `boardScore`; a
top-level row writes those two and not `boardKids`. `scoreIndexPut` refuses
`parent != 0` independently, so the two agree by construction rather than by
matching call sites.


