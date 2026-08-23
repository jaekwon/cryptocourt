# Vote weight: snapshot ceiling, live floor

**SHIPPED 2026-08-20, on panel 3's ordering. Revision 4 was the plan; this header
records what actually happened, including the three places the plan was wrong.**

| step | commit | what landed |
|---|---|---|
| 1 | (earlier) | the two fixture mints, post-seal |
| 2 | `769dcc5` | `VoteWithCap` + the clamp + arm 1/arm 3 retarget + a raising-cap control + four governor tests + rows 1–3 |
| 3 | `5ecf469` | quality-lane floor + paired test + `check-nodelegate.py` + rows 4, 4b |
| 4 | `e05fee7` | election floor AND the first-approval freeze together + `e.voters` `bool→int64` + two tests + rows 5–8 |
| 5 | `1387839` | dispute lane via `VoteWithCap`, row #171 re-anchored, `rentedweight_test.gno` flipped, 2 new rows |
| 6 | `122df45` | the four stale rentability comments, `RENTEDWEIGHT.md` → CLOSED, whitepaper erratum |
| 7 | `82f3c96` | the vote lock: coin voted with cannot leave until the question resolves, + 3 tests + 6 rows |
| 8 | `665d16d` | correcting step 6's own overstatement (see below) |
| 9 | `1c54fd9` | the quality lane locked (it was never an owner decision), and voteLockedOf fixed from SUM to MAX |
| 10 | `5a947e4` | retiring the "quality lane is an owner decision" claims |
| 11 | `cbbfe32` | the bond haircut measured, refuted as a hazard, pinned as intended behaviour |
| 12 | `32384b2` | ccwrap's vault capped so liquidity cannot strand governance |
| 13 | `8bf4770` | one vote-weight expression (`voteweight.gno`), quoted to the elector as well as charged; arm 4 |
| 14 | `20e440e` | the lock can never strand a voter; arm 5 pins claim terminality |
| 15 | `14f487e` | the three 5% bars do not share a denominator; `credWeightFloor`'s base pinned |
| 16 | `c4980eb` | the wrap cap was a precondition claiming to be an invariant: 60% → 35%, derived with escrow in it |
| 17 | `11ac0b9` | prose sweep — three false countable claims of my own; arm 6 pins the lock's one exemption |
| 18 | `310542d` | a permissionless prune for dead vote-lock rows |

**THE PATTERN ACROSS 11-18, stated because it is the most useful thing this file
has learned.** Every one of those commits fixed something in work that had already
passed a full gate — suites green, guards green, mutation rows caught. None was
found by review. They came from three moves, in descending yield:

1. **Probing a claim I had written down.** The wrap cap said "by construction"; it
   held for one block. The netting rejection cited an attack that does not work.
   `voteLockedOf` summed where it had to take a max, twice, two commits apart.
2. **Ablating each guard arm SEPARATELY.** Three ablations this session passed for
   the wrong reason — arm 1 firing where arm 4 was meant to, one precondition
   catching both directions of a bound, a planted body tripping a different arm than
   intended. An ablation that fires is not evidence until you know WHICH arm fired.
3. **Asking what has no symptom.** `lockVote` no longer pruning left the whole suite
   green: the failure mode was a bill, not a wrong answer. Those are the ones review
   cannot see, because there is nothing to look at.

The claims that go unpinned are the ones that sound obvious.

### A SURFACE OBLIGATION THIS DESIGN CREATED, and the web client has not met it

**The vote lock is a new user obligation with no disclosure on the web client.**
`web/index.html` is 5,483 lines and mentions it nowhere: no "committed until", no
"cannot sell", no `VoteLockedOf` read. Meanwhile it ships open-ballot copy that
invites holders to vote — the sealed-means-un-summed line, the snapshot hedge
("buying now adds nothing"), realm-refuses-at-signing. A holder who votes through
that surface and later tries to sell, bond, deposit or wrap is refused, having been
told nothing.

**Two things make this smaller than it sounds, and one keeps it real.** The realm's
refusal is legible at signing time — *"not enough uncommitted CC — coin you voted
with stays in your balance and keeps voting, but it is committed until that question
resolves"* — so nobody loses coin, they lose an expectation. And the CHAIN's own page
already discloses it: `render.gno`'s wallet panel now carries "committed by voting: N
— until each question resolves" plus the two separate free figures. So the chain is
honest and only the overlay is behind. What keeps it real is that the overlay is
where people will actually vote.

**What the site needs, stated so it can be implemented without re-deriving any of
it.** Before a vote: that casting commits this much coin until the question resolves,
with the per-lane difference (a verdict vote until its round resolves, an election
vote until the election resolves, and a quality vote until it can no longer decide
anything — its own question ending, in the ordinary case, or the claim ending if its
weights are the frozen total that later rounds keep voting). Do NOT implement "until
the tally is superseded": that was the first version of the rule and it was wrong,
because a tally is superseded only by a NEW ROUND and nothing makes a round open.
`VoteLockedOf` answers this without the client having to model any of it.

The shipped condition, quoted from `votelock.gno` so the two cannot drift apart — a
release rule stated in prose has now gone stale in three documents, and
check-epoch-coherence arm 11 fails the build if this line and the code's own summary stop
agreeing:

> open iff the claim is not terminal AND `cs.qVoteSeq` is still the seq voted in AND
> (some question is open now OR these weights carry forward). After a vote: the committed figure, from `VoteLockedOf(slug, who)`. On
any sell/bond/deposit/wrap affordance: the binding limit, which is NOT `SpendableOf`
— that one is stake-only and will over-promise. Use `DisposableOf(slug, who)`, which
is the figure the realm actually enforces. (It did not exist when this note was first
written, which made the note unactionable; exporting it was the fix.) `WrapRoom` is
also a court-level bound, not a personal allowance. The realm exposes
`ClaimVoteWeightOf`, `ElectionVoteWeightOf` and `VoteWeightWhy` for the weight side,
and `VoteLockedOf` plus `DisposableOf` for the commitment side. `VoteWeightWhy` returns TWO strings, one per lane — a claim
with a dispute open has two live questions at two different epochs, and a single
answer for both is wrong in a reachable state.

**MET.** `web/index.html` now carries the disclosure, on the owner's instruction. The
row sits on both vote panels — the dispute ballot and the quality lane — because that is
where the commitment is created, and it states the per-lane release rule statically so a
disconnected visitor or a failed read still sees the rule rather than nothing. Three live
figures fill in behind it when an address is connected: what this vote would commit
(`ClaimVoteWeightOf`, the verdict half to the ballot and the quality half to the quality
panel, never crossed), what is already committed (`VoteLockedOf`), and what is free to
bond or deposit (`DisposableOf`, never `SpendableOf`).

Three details were decided rather than deferred. The copy says the coin **can still be
staked** — `mustStakable` ignores the vote lock deliberately, so "your coin is locked"
would be false in the direction that costs a holder a legitimate action, and the wording
is the realm's own. A missing read prints nothing rather than a zero, because "commits 0"
is a claim and a wrong one; a zero FREE figure does print, because "nothing is free" is
the disclosure. And the binding limit went in the vote row rather than on each of the four
bond and deposit panels: the commitment is created at the vote, and adding a read to the
me-page's batched per-court loop is a larger change to someone else's pipeline for a
weaker gain.

**AND A ME-PAGE THAT SHOWS EVERYTHING, for one read per court and no new storage.**
`CommitmentsOf(courtSlug, who)` returns a holder's whole commitment picture in the
format `ClaimTimeline` established: the stake total, the vote total, the enforced free
figure, and one row per open commitment.

It costs nothing to add because the realm had already keyed the index the right way:
`c.voteLocks` is `addr|kind|id|sub`, so one holder's commitments are a CONTIGUOUS RANGE
and this is the same scan `voteLockedOf` already does, and `c.locked` is already
`addr -> int64`. No tree was added, so no vote and no stake pays storage for a page.
What it removes is query fan-out — the me-page's positions probe costs four reads per
claim id, and this is one read per court however many claims the holder is in.

Stake POSITIONS are deliberately not enumerated, and the asymmetry is structural:
`cs.stakers` is keyed `addr|side` on each claim, so it is claim-first, and listing one
holder's positions means visiting every claim. Making that cheap needs a second index
keyed address-first, which would tax every stake with storage for the benefit of a
page. The stake TOTAL is included because `c.locked` already holds it for free, and the
total is the figure that actually constrains the holder.

The trap, stated in the code and asserted on both sides: THE ROWS MAY SUM TO MORE THAN
THE TOTAL, because the total is a MAX — the locks overlap, so one pile of coin honours
several commitments. The client says so in the copy wherever more than one row shows,
and its parser is tested against a string the realm actually produced rather than an
invented one.

`web/tests/votelock_test.js` asserts the copy, the figures and the wiring — 30
assertions, and every property ablated: the lanes crossed, the stake exemption dropped,
`SpendableOf` substituted, the row unwired, a zero printed, and the forbidden phrasing
reintroduced. `dispute_test.js` gained one line, the pure helper its ticket now depends
on.

### The mutation verification, and what it does and does not say

**441 of 441 caught, zero not-caught, across the whole corpus of rows touching any
file this work changed.** Run in four chunks of ~110 against the eight changed files
(`ccwrap`, `dispute`, `governor`, `modvote`, `quality`, `render`, `votelock`,
`voteweight`):

| chunk | rows | caught | not caught |
|---|---|---|---|
| 1 | 111 | 111 | 0 |
| 2 | 110 | 110 | 0 |
| 3 | 110 | 110 | 0 |
| 4 | 110 | 110 | 0 |

The not-caught column is mutate's own bucket, and its label matters: *"survived,
invalid, or never applied"*. Zero means no row survived, none failed to BUILD, and
none failed to anchor — the last of which retroactively clears the mid-run edits.
Chunks 1 and 2 ran while `realm/` files were being committed (each checked for
anchor overlap first, one of them checked afterwards by mistake); chunks 3 and 4 ran
against a tree touched only under `scripts/`, which mutate does not stage, so those
two are pristine measurements.

### And then the complement, partly — with the split stated exactly

The first pass covered rows over CHANGED files. The rest were skipped on an argument:
*a row can only stop being caught if either its target or its catching test moved.*
That is reasoning, not measurement, so it was labelled as such — and then narrowed
rather than left standing.

**All 921 distinct rows measured, all caught, zero not-caught.** Two rows survive by
design and say so, both covered by txtar suites this harness does not run (`Buy`'s
IsUserCall downgrade, and meta's COIN usage gate).

This started as 636 of 918 with the remaining 282 resting on an argument, and the
argument is left standing below because it was a real choice and it turned out to be
right — but it is no longer what covers those rows. A number replaced it in five
foreground slices of 50-65 rows: `stake.gno` + `session.gno` first, since Stake is the
one deliberate exemption from the vote lock and `session.gno` holds the claim-terminal
writers the quality lock releases on. Both came back clean, including
`Stake: a pending vote blocks staking (over-restrictive)` — the direction that is easy
to leave untested, because an over-restrictive gate refuses something rather than
allowing it.

The narrowing is the part worth defending. The argument is strong where this work
changed neither the code nor its tests, which is all of the untouched `kourtv2`
files. It is WEAKER for `grc20votes`, `checkpoint` and `governor`, because the
coherence case names them by hand:

    Σ min(PastVotes, BalanceOf)  ≤  Σ PastVotes  =  PastTotal

That middle EQUALITY is a property of the ledger and its archive, not of anything
written here — asserted in `voteweight.gno`'s header and in
`TestPastVotesSumToPastTotal`. So all 102 rows across those three packages were run
(51 + 51, both clean) on the principle that measurement should go where the argument
leans on someone else's invariant. That ordering is still the right one; the rest were
simply measured afterwards rather than left to it.

**Operational notes, since four attempts were lost to learn them.** Background
mutate runs get reaped; foreground with ~60-row slices returns its result and cannot
be lost, while 102 rows exceeds the window. Mutate is safe to interrupt — it stages
copies, so five consecutive kills left the tree with no stray `.mutate-backup` and a
clean `git status`. `selftest-checks.py` is NOT safe to interrupt: it rewrites files
in place, and one kill left `check-storage.py` carrying a budget mutation that then
read as a real guard failure. The abandoned full-corpus run failed for a different
reason worth remembering: 8 shards saturated the machine, no shard reported for ~1.5
hours, and `realm/` was edited under it twice before I understood that mutate
re-stages per row.

**A SHARDED RUN IS SILENT BY CONSTRUCTION, so do not read silence as a hang.**
mutate-parallel spawns each shard with `capture_output=True` and stores
`(returncode, stdout, stderr)`, so a shard's rows are printed only when that WHOLE shard
exits — the docstring's "prints every row as its shard reports it" means per shard, not
per row. Measured on a 382-row regression batch over 4 shards: one header line and
nothing else for 45 minutes, with four `gno test` processes working the whole time.
Confirm progress by counting those processes (`ps -eo command | grep -c "[g]no test"`
should equal the shard count), not by reading the log.

**THROUGHPUT, MEASURED, so a batch size can be chosen deliberately:** about 75 seconds
per row per shard, which is one staged GNOROOT plus one full kourtv2 suite under 4-way
contention. That puts 96 rows per shard at roughly two hours, and it is consistent with
the recorded full pass — 983 rows in 5½ hours is the same ~75s/row. So the arithmetic for
any batch is `rows / shards * 75s`, and the reason to keep foreground slices at 50-65
rows is that they finish inside the tool-call window while a 96-row shard cannot.

**AND THE GAP FILE WAS CHECKED THE OTHER WAY ROUND, which is the half a full pass cannot
see.** A main-corpus row is wrong if it stops being caught; a KNOWN-GAPS row is wrong if it
STARTS being caught, because then the gap has closed and nobody noticed. `make gaps` asks
exactly that, and it had not been run since the file churned today.

    21 rows run (2 skipped as `slow`), 17 surviving + 4 by-design `elsewhere` = 21
    ZERO caught

So no recorded gap is stale: every one still genuinely survives, and the four with an
`elsewhere` are covered by the harness each names — two txtar scripts, check-read-purity,
and the seeded-realm txtar. The two skipped rows are the documented non-results, a
non-terminating mutant and a timeout, both marked `slow` precisely so a pass does not spend
ten minutes re-observing a bound selftest-checks already holds.

Together with the full pass this is a complete statement about the corpus, both halves:
1,186 main rows observed caught or by-design, and 21 gap rows observed still-surviving. The
main corpus was an assembled claim; the gap file was an assembled claim too, and neither is
now.

**THE SECOND FULL PASS RAN, AND THIS ONE WAS ALL GREEN.** 1,174 rows in 20 slices of 60 at
5 shards, from a clone pinned at 39a8c4f, 10:17:20 to 13:32:42 — three hours fifteen. Every
slice clean:

    20/20 slices, 0 not caught
    1,171 caught + 3 surviving BY DESIGN with an `elsewhere` = 1,174
    the three: Buy's IsUserCall downgrade, and the two arming rows (nextID,
    TotalSupply) — all txtar-backed, and `make check` now runs txtar-test

Then the delta: 12 rows had been added while it ran, so they were observed the same way from
a SECOND clone at HEAD, 12/12 caught. Together 1,186 rows observed green in one coherent
effort, which is what ranked item 2 asked for — "an assembled claim, not an observed one" is
no longer true of this corpus.

**THE CONTRAST WITH THE FIRST PASS IS THE POINT.** That one (983 rows) found one EXPIRED row
— `folders: a court may hold unlimited folders`, verified caught when written and not caught
983 rows later, because its catching test had moved out from under it. This pass found none.
The difference is not luck: between the two, the corpus grew by 191 rows and every batch
added since has been measured on the FULL suite rather than on the filter that found it,
which is the practice that first pass's failure bought.

**SLICE TIMINGS, and the honest accounting of them.** Fastest 308s, slowest 1,356s, mean
586s. That spread is almost entirely MY doing: the slow tail lines up with the slices during
which I was running guard targets, realm-test and small mutation batches on the same machine.
A slice is ~5 minutes on a quiet box and up to 22 when something else is working. So the
`rows / shards * 75s` arithmetic recorded above holds only for a quiet machine; budget double
if you intend to keep working alongside it.

**VERIFYING SOMEBODY ELSE'S REFACTOR, and the hole that showed up while doing it.** Two
refactors landed from another session on money-path code — `settleAnswerBond` collapsing
Finalize's and SettleUndisputed's identical ten lines into one helper, and a second
consolidating the edge-removal gates. Both were carefully done and carefully verified;
what they verified was **one** row by measurement and the rest by anchors-plus-clean-suite.
An anchor resolving is not the same as a mutation being caught, and that difference is
exactly what expired the `folders` row in the first full pass. So the 12 rows those two
commits added or re-pointed were measured:

    12 row(s) added or re-pointed across ea0394c and 35434e0
    12/12 caught, harness mtime checked either side

Coverage held, and the catching tests are pleasingly diverse —
`TestDecidedRoundBuysNoSlashImmunity`, `TestCrystallizeMidHappyPathDrainsEscrow`,
`TestSlashSurvivesSettle`, `TestCrystallizeLowTierZeroDrawCarrotStillPays` — which is what
a helper reached through many paths should look like.

**FOUR HYPOTHESES, ALL REFUTED BY READING, and none of them written up as a finding.** The
refactor moved a `Transfer` out of two functions, so: (1) does `check-spend-paths`' census
now describe a tree that moved? No — it counts GUARD CALLERS, not transfers, and says so in
its own docstring; an escrow→answerer refund needs no spendability guard. (2) Does ARM 7's
`COIN_OUT_N` still hold? Yes, and by construction: `ESCROW_SRC` excludes escrow-sourced
lines, so the count is of USER-sourced movement and refunds were never in it. (3)
`settleAnswerBond` deliberately retains a reserve while a future flag could still slash,
and Crystallize returns the WHOLE bond — can a flag land after crystallize and find nothing
to take? No: `OpenFlag` refuses outright on `cs.crystallized`. (4) Is that refusal pinned?
Yes, by `TestOpenFlagRefusesEveryClosedState`, which constructs each terminal state,
restores between arms, and even carries a positive arm (a `provClose`d claim must NOT be
refused). A grep for the panic's first half missed it because the assertion uses its
second half.

Four dead ends is the correct outcome of an audit on well-covered code, and the discipline
that matters is that none of them reached a document.

**AND THE GAP FILE'S CHECK WAS NOT A CHECK.** `make gaps` reads the corpus the other way
round — a KNOWN-GAPS row is wrong when it STARTS being caught — and it printed its verdict
and **exited 0 either way**. Found by reading the exit code and then remembering that this
tool's exit code says only "the run is a result": the verdict line is unconditional. The
answer had to be computed by hand:

    21 sent, 17 surviving + 4 by-design = 21  ->  0 caught
    had it been 16 and 4, exit=0 all the same

`--expect-survive` now inverts the verdict for that batch, ablated three ways (a caught row
with the flag exits 1 and names it; the same row without the flag still exits 0; a
surviving gap row with the flag exits 0 and says so), with a control arm on the same
governor anchor two neighbouring arms already use.

**One observation recorded without an explanation, because it is a measurement and not a
guess.** Two `make gaps` runs minutes apart split the same 21 rows differently — `17`
not-caught + `4` by-design, then `18` + `3`. The total, and therefore the verdict, is
identical both times and correct. But one row moved category, so the by-design/ordinary
split is not stable run to run. It costs six minutes a sample to chase and does not affect
whether a gap has closed, so it is written down rather than investigated: if a future
reader sees an excused row reported as an ordinary survivor, this is why, and it is not new.

**A RED GUARD WHOSE CAUSE BELONGED TO SOMEBODY ELSE — and the same exit code, twice, for
entirely different reasons.** `make anchors` went red with three broken rows, all in
`moderation.gno`, all broken by another session's 39 uncommitted lines sitting in the working
tree. Re-pointing them was the obvious move and it was the wrong one: their edit was mid-flight,
so any anchor I wrote would re-break on their next keystroke. They were left alone and the
red was recorded as theirs to settle. It then settled itself — `5b7068d refactor(kourtv2): the
two paths that seat a global member share the block` landed, which is the AddGlobalMod /
TransferGlobalAdmin duplication an earlier firing had already named as the only genuinely
identical pair left, and the corpus moved with the code:

    3 rows removed, 2 added, main corpus 1190 -> 1189
    the two duplicated-block rows collapsed into one at the shared site
    plus a new row for what is unique to TransferGlobalAdmin
    both new rows measured: 2/2 caught (harness mtime checked either side)

Net minus one because the duplication is gone, and coverage is not merely preserved but
slightly better — the second row pins a leg that had no row before. Same shape as this
firing's own `mustCategoryCode` and `disputeBond0` collapses, arrived at independently.

**THE LESSON IS ABOUT READING THE MESSAGE, NOT THE EXIT CODE.** On re-check, anchors still
exited 2 — with ZERO `BAD ANCHOR` lines. The cause was now a REPOLOCK: *"process 97216 is
rewriting the working tree (a selftest run … breaks guards on purpose and restores them).
Reading the sources now would report ITS mutation as MY finding."* Identical exit code,
completely unrelated cause, and the correct response to each is the opposite of the other —
one says fix an anchor, the other says fix nothing and wait. Had I gated on `rc != 0` and gone
looking for anchors to repair, I would have "fixed" rows against a tree that was mid-mutation.
Waiting for PID 97216 gave `anchors exit=0`, 1212 rows across 2 corpus files. A guard that
distinguishes its own failure modes in PROSE is worth the extra lines; a caller that reads only
the number throws that away.

**THEN THE SAME CLASS TURNED UP IN THE HARNESS ITSELF, WHICH IS WHERE IT COSTS MOST.** Having
made the mistake three times in one session — an `&&` chain carrying past a failure, a `;` where
a gate belonged, and `${PIPESTATUS[0]}` which is EMPTY in zsh so the gate never gated at all —
the question worth asking was whether the repo's own build swallows status the same way. Two
candidates, and the interesting part is that they went opposite ways.

**`mutate-parallel.py` reported a green verdict over ZERO measurements.** `[]` is valid JSON, so
it survives the decoder, no shard dies, and the run prints `0 not caught (survived, invalid, or
never applied), of 0` and exits **0**. Its own docstring forbids exactly this — *"a shard whose
rows never ran must not be able to look like a shard whose rows all passed"* — and the file
already carried a fix for the neighbouring case (empty stdin surfacing as a clean exit under
`| tail`), which is what makes the residual worth naming rather than shrugging at: the author
had seen the class, closed one instance, and left the one next door.

The live way to reach it is A FILTER THAT MATCHED NOTHING, which is how every ad-hoc batch in
this session was built — a list comprehension over the corpus keyed on `label`, against a corpus
that renames labels as the code moves. Every filtered batch all session could have measured zero
rows and printed a pass. They did not, because each filter carried a hand-written
`assert len(rows) == N`; but that was my discipline, not the tool's, and the tool is what the
next person will trust. Zero rows is now refused, with a message that names the likely cause.

    empty batch  ->  exit 2, "would measure nothing and still exit 0"
    one row      ->  exit 1, past the guard, failing for its own reason (no over-fire)

**`scenarios-check` was the hypothesis, and it was REFUTED.** Its work is driven by
`for f in $$(python3 scripts/scenario.py --list-ci)`, and a dead generator gives zero iterations
at exit 0 — the pattern, exactly. But the recipe has a SECOND loop that walks the existing
txtars and requires each to appear in the list, so a dead generator makes all four fail that
test and `rc=1` carries out. Measured on a scratch copy of the recipe with both call sites
replaced by `false`: **exit 1 with 4 complaints**, against the real target's exit 0. It fails
loudly, merely with a misleading message ("which is now CI = False" when the truth is that the
generator died). Written up as a refutation rather than quietly dropped, because the reasoning
that predicted a hole was sound and only the second loop saved it.

**THEN THE CLASS TURNED UP IN THE FAST LOOP ITSELF — `gno test -run` EXITS 0 WHEN THE
FILTER MATCHES NOTHING.** This is the one that matters most, because `t.sh kourtv2
<TestName>` is the instrument every increment in this session was checked with. Measured
side by side, a real name and a typo:

    real name:  === RUN / --- PASS / ok . 3.49s   exit 0
    typo:                             ok . 3.76s   exit 0

`-run` does not suppress filetests, so a name that selects NO test still prints a screen
of GAS lines and then `ok`. There is no discriminator without `-v`; with it, `=== RUN` is
the only one. So every green from that loop was formally ambiguous between "the test
passed" and "the test never ran". The greens themselves survive — the transcripts show
`--- PASS: <name>` each time, which is the RUN line — but the loop could not have told me
otherwise, and that is the same defect as a gate that never gates. `t.sh` now requires at
least one `=== RUN` and says so loudly when there is none, buffered rather than piped so
`gno test`'s real status is not replaced by `tee`'s. Truth table measured over all four
quadrants: rc=0+ran → pass, rc=0+none → NO TEST MATCHED, rc≠0 either way → the real code.

**AND THE SAME HOLE WAS IN A GUARD, WHERE IT WAS WORSE.** `check-isolation.py` runs each
test alone via `gno test -run ^name$` and concluded "passes alone" from the return code
only — so a test whose filter selected nothing was counted in `total` and asserted to pass
under the summary line *"all N tests across M packages pass alone as well as together"*.
The file had already been bitten by this exact class once, and says so in its own comment
about the together-run. It is LATENT rather than live, and that was measured rather than
assumed: all 751 `func Test*` declarations in the tree have a real test signature (564
crossing, 187 plain), and the zero-tests-harvested case was already refused at the outer
level. The residual was the per-test case. Now `-v` is load-bearing and a miss reports as
NEVER, a category distinct from ALONE and BROKEN.

The crossing case had to be measured separately and nearly was not: the first ablation
used a plain `func Test(t *testing.T)`, but 564 of 751 tests are `func Test(cur realm, t
*testing.T)`. If gno named those differently in its RUN line, the new arm would report
NEVER for three quarters of the suite. It does not — verified on a crossing test before
the commit, not after.

**AND THE TILING TEST SHOWED WHY "WHICH ARM FIRED" IS THE WHOLE QUESTION.** An unlanded
fixture for the entitlement queue (M3-CRITICAL-1: a senior must be seated past every
junior draw already minted) turned out to fail under the M3 mutation — but via its
setup guard, reporting *"this fixture cannot tell disjoint from contiguous"*. It asserted
senior-vs-senior disjointness, and M3 does not break that: with `start = reservedTail` the
seniors tile CONTIGUOUSLY, `start == prevEnd` exactly, and what overlaps is the
senior/JUNIOR boundary the walk never looked at. A fixture complaint for a money-path
defect is a pass for the wrong reason wearing a red coat. Rewritten as the arithmetic the
invariant actually claims — `start_i == Σ(prior senior amounts) + juniorReserved at i` —
it now reports *entitlement 2 short by 1500000*, which is `j1` exactly.

Then the disjointness walk was CUT rather than kept alongside it: once every start is
pinned to an exact value, the walk can never be the assertion that goes red. An assertion
that cannot fail on its own is the test-side twin of a mutation that cannot change
behaviour — it reads as coverage and measures nothing. And the honest note about what the
whole fixture buys: no new mutation coverage at all. The corpus already carries five
caught rows over those cursors. What it buys is a direct assertion that holds for enqueue
paths which do not exist yet.

**A HARNESS THAT DIES IS NOT A HARNESS THAT OBJECTS**, which is the same class one
level up. `check-elsewhere` asks whether the harness a row names FAILS under the
mutation — and a mutation that merely stops the realm building satisfies that without
the property ever being evaluated. The first attempt to close it guessed the failure's
shape and was wrong: it scanned for compiler text ("build error", "undefined:",
"syntax error"), and an ablation planting an unclosed paren in emission.gno went
straight through. Measured, an unbuildable realm produces no compiler message at all —
it kills the in-memory node during genesis and the output is a tm2 goroutine dump
ending in a bare `FAIL`, with the realm never mentioned and the txtar never run. So the
discriminator is not the failure's TEXT but whether it named a LOCATION: a real
objection points at `testdata/x.txtar:82`, a death points at nothing. Ablated 7/7
accepted, 6/7 flagged when every mutation is made unbuildable — the seventh being the
python text scanner, which legitimately still names a line in a file that will not
build. The guard was also computing the complaint line and throwing it away; printing
it is what made all of this visible in the first place.

**AND THEN THE SWEEP STOPPED, BECAUSE THE CENSUS INSTRUMENT WAS UNRELIABLE.** The
obvious next question was whether the other guards refuse a zero-item scan, so all 26
were grepped for the idiom. It reported 10 without one. Reading two of those 10 refuted
it immediately: `check-abort-assertions` says *"found no abort assertions at all"* and
returns 1, `check-height-shim` says *"clock.gno holds NO raw height read"* and returns
1. Both refuse; the grep simply did not know their spellings. Publishing "10 guards
lack a zero-refusal" would have been a false finding of exactly the kind this file keeps
recording — and the fix for it is not a better regex, because the property is
behavioural and each guard's empty input is a different shape.

So the honest statement is the narrow one: this class is substantially already handled
here. Two marginal residuals were recorded at this point — and **BOTH WERE FALSE, and
the correction is the more useful entry.**

They were written up as: `check-live-reads` printing `0 live read(s)` followed by "every
read answered" if every read is skipped, and `check-storage` reporting an observation
with no budget (`UNKNOWN`) but never the reverse. Checked properly on the next firing,
neither exists:

    check-storage    has all THREE directions already — UNWATCHED (a realm with
                     filetests and no entry), MISSING (a budget whose filetest did
                     not run), UNKNOWN (a filetest with no budget). MISSING is the
                     check claimed absent, and selftest even carries an arm whose
                     comment distinguishes it: "UNKNOWN, not MISSING."
    check-live-reads 56 probes, 49 of them UNCONDITIONAL (guard is probe[2] if
                     len(probe) > 2). `checked == 0` needs every probe guarded and
                     every guard false, which cannot happen unless the table is
                     edited — and that edit is already armed as "a gutted probe
                     table", explicitly because it "would otherwise report a clean
                     scan having asked nothing."

**THE FAILURE MODE WAS IDENTICAL IN BOTH, and it is the one this file keeps recording
in other people's work.** Each time I read the guard's TAIL — the success print and
`return 1 if bad else 0` — and inferred the absence of a check I had not gone looking
for. Both times the check was about twenty lines above where I stopped reading. And
both were published in the same firing that recorded "GREP BEFORE HYPOTHESISING. Do not
write up a hazard you could not demonstrate", which is exactly what a hazard written up
from a partial read is.

Worth being precise about the cost, because it is not zero and it is not a crisis: no
code was changed on the strength of either, so nothing broke. What they cost is the
document's credibility — a reader budgeting work off that paragraph would have gone
looking for two holes that were never there, in guards that were already doing the job.
A false hazard is as expensive as a missed one, and cheaper to prevent: read the whole
function before writing down what it does not do.

With those struck, the class closes cleanly. The four instances found and fixed —
mutate-parallel's empty batch, `gno test -run`'s empty selection, check-isolation's
per-test run, check-elsewhere's dead harness — appear to be the whole of it here.

**AND THE CONTROL FOR THE NEW ARM WAS BRIEFLY WRONG IN THE FAMILIAR WAY.** First attempt ran the
pre-fix copy from the scratchpad: SILENT, as wanted — but at exit **1** with no verdict line,
because a copy outside the repo cannot resolve its relative path to `scripts/mutate.py`. It was
silent because it was broken, not because it tolerated zero rows. Re-run from inside `scripts/`
it gave the real control: **SILENT at exit 0, printing `0 not caught … of 0`**. That is the third
time this session an ablation passed for the wrong reason, and the tell each time was a detail
that did not fit — here, an exit code of 1 where the hole predicts 0.

**THE FULL-CORPUS PASS RAN, AND IT WAS NOT ALL GREEN — which is the whole reason to run
one.** 983 rows in 17 slices of 60, 19:48 to 01:17, five and a half hours from an
isolated clone at one commit: **979 caught, 3 surviving by design with an `elsewhere`
annotation, and 1 SURVIVOR.**

The survivor is `folders: a court may hold unlimited folders` — the maxFolders cap. That
row was verified caught when it was written, and 983 rows later it is not: its catching
test moved out from under it while the folder work grew. Re-measured against HEAD, not
just against the pinned clone, and it survives there too, so it was a live hole and not
an artefact of the older tree. Now pinned by TestACourtStopsAtItsFolderCap.

That is exactly the failure a per-row check at insertion time CANNOT find: a row's
verdict is a fact about a moment, and the corpus was an assembled claim of 983 such
moments. One had expired. The pass is worth repeating after any large refactor, and the
cost is known now — five and a half hours of wall clock while other work continues, at
one 60-row slice per 11-19 minutes depending on what else is running.

**AND THEN THE DELTA PASS FOUND A SECOND ONE, of a different kind.** The corpus grew by
114 rows while the full pass ran, so those were observed the same way afterwards, in three
slices from their own clone: 113 caught, 1 not — `EnableTestClock: a realm with one user
court may still be armed`.

That row is not expired. It was MIS-ATTRIBUTED at birth: I measured it caught on a
FILTERED run, where the only courts in existence were meta and the one the test made, so
`CourtCount() > 1` and `> 2` genuinely differ. In the whole suite the realm holds dozens
of courts, every small threshold is already exceeded, and both versions refuse — so the
test still asserts the refusal truthfully while discriminating nothing about the
threshold. Measured: the mutation passes the whole kourtv2 suite (44.6s, ok) and fails
`kourtv2_usedrealm_seeded.txtar:123` with *no match for `this realm already has courts`*,
because that harness holds exactly two courts. Reclassified to KNOWN-GAPS with the txtar
as its `elsewhere`.

**THE RULE THAT FALLS OUT: verify a new row on the FULL suite, never on the filter used to
find it.** A filtered run is for triage. It over-reports survivors (three sweeps running,
most filtered survivors were the filter) and — this is the new half — it can also
over-report CATCHES, because a small fixture can make a threshold discriminable that the
real suite never will.

**How to run the full corpus while somebody else is editing the tree — run it from a
CLONE.** mutate stages the realm sources from the repo it is invoked in, per row, so a
concurrent session's commits land inside a long run and produce rows that report `INVALID
(did not build)` for no reason. A `git clone --depth 1` of HEAD into the scratchpad is
immune, and it also frees the working tree for ordinary work while the run proceeds:

    git clone -q --depth 1 --no-hardlinks file:///…/cryptocourt-mod $S/corpusrun
    cd $S/corpusrun
    export GNOROOT=/Users/jk/gopath/src/github.com/gnolang/gno   # REQUIRED, see below
    for f in $S/slices/s*.json; do python3 scripts/mutate-parallel.py "$f" --shards 5; done

The GNOROOT export is not optional and the failure is obscure: `gno env GNOROOT` derives
its answer from the CURRENT DIRECTORY, so inside the scratchpad it returns a plausible
path that does not exist, `gnoroot.real_root()` turns that into `""`, and every shard
dies with `FileNotFoundError: ''` from `os.listdir("")`. Set it to the real gno checkout
and the clone behaves exactly like the repo. Slice into 60-row files and append each
slice's verdict to a log as it finishes, so a reaped run loses at most the slice in
flight and the log says where to resume. Measured cadence on this machine, with another
session working: **11 minutes per 60-row slice at 5 shards**, so a 983-row pass is about
three hours.

**A transient staging failure that looks exactly like a broken tree.** `t.sh` and
`realm-test` occasionally fail with `package "gno.land/p/kourt/bptree/v0" is not
available` and `[setup failed]` against a path in the module cache. That package does not
exist in this repo, in the gno tree, or in the cache — the error is a race in shadow-root
staging, most likely when a mutate run or another session is touching the same GNOROOT.
It cost twenty minutes once: the suite went red immediately after a new test file landed,
removing the file did not fix it, and the same suite passed on the next run with no change
at all. RE-RUN BEFORE INVESTIGATING, and if it clears, it was never real.

**An operator-level sweep of the three core files, and what it found.** The corpus
catches the mutations somebody thought of, which is not the same as the mutations that
matter: the last-open-row-instead-of-the-largest under-lock was not in it, and survived
everything. So voteweight.gno, votelock.gno and lock.gno were swept mechanically instead —
every comparison and boolean operator on the weight and lock decision path, flipped or
nudged by one, eleven mutations in all. Ten are caught, including both gate boundaries
(an exact-amount spend and an exact-amount stake), all three escrow-endpoint guards, and
all three `&&` predicates turned into `||`. The single survivor is lockVote's
`amount <= 0`, which cannot fire because every call site refuses a non-positive weight
first; it is recorded in KNOWN-GAPS with that reason. Worth repeating after any change to
those three files, since it costs about two minutes and does not depend on guessing.

**THREE KINDS OF PASS, and the third is the cheap one that finds the most.** The full pass
observes everything and costs five and a half hours. The delta pass observes the rows added
since, and cost thirty-four minutes to find a row mis-attributed at birth. The third is
narrower and sharper: **every row whose TARGET FILE has changed.** That is where a catcher
can have drifted, and it is a small fraction of the corpus — 482 of 1,147 rows after one
busy session, against 1,147 for the full sweep.

**RUN, AND CLEAN: 482 rows in 9 slices, 04:26 to 05:40, 0 not caught — no survivor, no bad
anchor, no timeout.** One hour fourteen against five and a half hours for the full pass,
over the set where the risk actually is. A clean result here is worth as much as a dirty
one: it says the fifteen source files that changed in a busy session, three of mine and a
dozen of another session's, did not orphan a single catcher.

**And `make gaps` exists now**, because the audit that found the RestoreFolder row was one I
ran by hand and would not have run again. 21 rows in four shards, two skipped by an explicit
`"slow": true` on the rows whose own notes say they burn a SUITE_TIMEOUT — marked rather
than rediscovered by waiting twenty minutes. First run of the target: 17 survive as
documented, 4 reported as covered elsewhere with every annotation resolving, exit 0.

The reason to run it is not theoretical. In one tick my own edit to StakedPage broke two
rows outright (the anchors guard caught those before the commit, which is what it is for),
and the two rows the two big passes found wrong were both of this shape — a row that still
ANCHORS while the test that caught it has moved out from under it. Anchoring is checked on
every commit; catching is not.

**THE KNOWN-GAPS FILE IS ITSELF A SET OF UNTESTED CLAIMS, so run it.** Every row in it says
some version of "no test can catch this, and IF IT COMES BACK CAUGHT, read X before
promoting it" — and nothing was running them. `make anchors` checks their anchors resolve;
no pass checks that they still survive. A gap closed by somebody else's new test would sit
there asserting the opposite for ever, which is exactly the stale-claim class this file
exists to hunt. mutate.py already has the machinery: a row carrying `elsewhere` that turns
out to be caught HERE is reported as an error telling you to drop the annotation. Passing
the gaps file to mutate-parallel is the whole audit.

BUDGET FORTY MINUTES, NOT TWENTY, and the reason is worth knowing before you start: two of
the gaps are rows the file itself describes as non-terminating or pathologically slow —
`ClaimSeries: the merge advances the side that did NOT change`, whose flipped advance guard
loops for ever, and `Cost: the slope is d, not 2d`, which doubles the span the curve's
one-unit correction loops must climb. Each burns a full SUITE_TIMEOUT (600s) every time the
audit runs, measured. Filtering those two out by label makes the audit twenty minutes and
loses nothing, because what they assert is a property of the harness's bound rather than of
any test.

**WHERE THE CORPUS ACTUALLY IS, measured, because a density scan by realm file misses it
entirely.** Rows per 100 code lines, per package: kourtv2 is thoroughly covered and the
LIBRARIES underneath it are not — and the libraries are where the arithmetic lives.

| package | rows | code | per 100 |
|---|---|---|---|
| cshares | 0 | 273 | 0.0 |
| tickbook | 0 | 363 | 0.0 |
| twap | 8 → 10 | 161 | 5.0 → 6.2 |
| curve | 5 → 10 | 108 | 4.6 → 9.3 |
| grc20votes | 38 | 289 | 13.1 |
| governor | 199 | 1327 | 15.0 |
| checkpoint | 24 | 145 | 16.6 |

cshares and tickbook are the two zeros and they stay zero DELIBERATELY: both are imported
only by `realm/r/kourtv1`, and V1 is untouched by owner ruling. Neither has a PKGS entry in
mutate.py, which is why they were never swept — the absence is a scope decision, not an
oversight, and a future density scan should not chase them. What is left worth sweeping is
grc20votes (the ledger and its voting snapshots) and checkpoint.

**A KILLED PARALLEL RUN LEAVES SHARDS BEHIND, and one of mine stole a core for six hours
and twenty-four minutes.** `pkill -f "<batch>.json"` matches the mutate-parallel DRIVER,
whose argv carries the batch path — it does NOT match the per-shard `scripts/mutate.py`
children, which read their rows from stdin and carry no batch name at all. One shard from
a sweep killed at 20:35 was still running at 02:27, re-spawning a fresh `gno test` each
time I killed its current one, and it had been competing with every measurement since:
the corpus slices drifted from 11 to 19 minutes, and the "109s vs 54s" whole-package
timing I correctly diagnosed as load noise was partly this.

To kill a parallel run: `pkill -f mutate-parallel` AND `pkill -f mutate.py`, then
`ps -eo pid,ppid,etime,command | grep -E "mutate.py|gno test"` and look for a PPID of 1
and an elapsed time older than the run. An orphan re-parents to init and keeps going;
nothing in the harness times it out, because the harness that would have is the one that
died. No correctness risk — a shard mutates its own staged root, never the repo — but
every timing number taken while one is alive is wrong.

**A MUTANT'S OUTPUT IS NOT TEXT.** Decoding a packed index one byte at a time printed
a raw `0xff` into a failure message and killed the ablation driver with
`UnicodeDecodeError`, mid-mutation. The file was restored only because the restore sits
in a `finally` — which is the whole argument for putting it there. Capture subprocess
output with `errors='replace'`; a mutant can emit any bytes at all.

**THE MONEY PATHS ARE NO LONGER THE THIN SURFACE — MEASURE BEFORE PICKING A TARGET.**
The standing backlog calls them "the weakest surface in the repo", which was true when it
was written and is now inverted by the sweeps it asked for. emission.gno alone carries 40
rows over 185 lines of code, so "emission, crystallize and the senior queue are
essentially unswept" is stale.

**COUNT CODE LINES, NOT FILE LINES — 45% OF THIS SOURCE IS COMMENTARY.** The first version
of this table divided rows by raw line count and got a materially different ranking,
because the comment share is nowhere near uniform: votelock.gno is 141 lines of code under
a 160-line header, lock.gno 150 of 361. Corpus rows per 100 CODE lines (blank and
comment-only lines dropped), thinnest first:

    folders.gno 4.9   supersede.gno 5.0   modrender.gno 5.3   moderation.gno 6.5
    directory.gno 6.5   stakeseries.gno 7.3   modvote.gno 8.1   argument.gno 8.9
    lock.gno 10.0   ...   stake.gno 20.0   emission.gno 21.6   quality.gno 26.5
    answer.gno 27.4   session.gno 30.3   records.gno 34.6

On the raw metric lock.gno looked like the thinnest file in the realm at 2.8, which is
what sent the operator sweep there; on code lines it is NINTH at 10.0, and the genuinely
thin files are the curation surfaces — folders, supersede, modrender. The sweep was still
worth doing, because lock.gno decides whether a coin may move at all and it turned up a
whole class of mis-asserted refusals, but the reason given for choosing it was not the true
one. Density is not coverage; it is the cheapest proxy for where to look next, and it is
only as good as its denominator.

**A SENTENCE ADDRESSED TO THE NEXT CONTRIBUTOR IS NOT AN ENFORCEMENT MECHANISM.**
lock.gno's header ends its account of the double-commit risk with "If a new spend path
is ever added, it belongs in that test too" — and measured, the promise was being kept
perfectly: eight spend paths, all five holder-to-escrow transfers guarded on the
IMMEDIATELY preceding line, six of the paths carrying a `// PATH n` arm in
TestLockedStakeCannotBeSpentTwice and the other two proved by tests of their own. Nothing
was broken. What was missing was any way for the NINTH path to be noticed, because a test
can only assert about the paths it names and the suite cannot go red for one nobody wrote
a test for. Custody used to make that structural: the coins left the balance, so the
LEDGER refused the second spend on every path including the ones nobody thought about.
A lock cannot do that, so scripts/check-spend-paths.py does.

**GREP THE GUARDS BEFORE WRITING A GUARD.** The adjacency half of
check-spend-paths.py — every user-to-escrow transfer must be preceded by a spend gate —
already existed as check-epoch-coherence.py ARM 7, with the same
`must(?:Spendable|Stakable)\(` regex and the same three-line lookback, plus a pinned count
of seven user-sourced movements. I wrote the copy after grepping lock.gno for the policy
and the Makefile for how guards are wired, but never the guards themselves for whether the
rule was already enforced.

The copy was also WORSE, in exactly the two ways ARM 7 records having been fixed: it
matched only `c.coin.Transfer(`, so it was blind to Burn (eleven sites) and to every other
Court receiver — mc, c2, m, c3, of which mc is "sixteen lines away doing Mint". ARM 7's
comment names that mistake: "the regex assumed a spelling the file already contradicts
elsewhere." Two implementations of one rule is how the second comes to disagree with the
first — stakeindex.gno's stakeIdxMine comment says the same thing about two readers of one
tree — so the duplicate was deleted and the rule left where it was already enforced.

What survived is the half nothing else pins: ARM 7 makes a new outflow get LOOKED AT by
failing its count; it does not make the new path get a TEST, which is what lock.gno's
header actually promises. Cross-check found while reading for this: votelock.gno's header
states the same census independently — "All SEVEN mustSpendable call sites move coin OUT of
the holder's balance", enumerated, with Stake the single mustStakable exemption — so seven
plus one is the eight the guard pins, a number the design commits to in two places.

**PREFER A NAMED CENSUS TO A COUNT.** The first version counted spend guards against
`// PATH n` arms in the one test the header names, and it fired on correct code: two of
the eight paths (TransferCC, TransferFromCC) move coin holder-to-holder rather than into
the escrow and are proved elsewhere, so the counts were 8 against 6 and the honest tree
looked broken. A map from path to the test that proves it fixes the false positive AND
says more than the count could — where each proof actually lives. The same shape as
check-storage.py's per-realm budget list, and it fails closed both ways: a path missing
from the map is "a NEW spend path", a map entry naming a test that no longer exists is a
census pointing at nothing.

**THE GUARD'S OWN ARMS, ablated separately, each firing its own complaint:** deleting a
mustSpendable trips BOTH adjacency and census (the transfer is now unguarded and the
function no longer calls a guard); moving that same guard five lines further up trips
adjacency ALONE (the caller is still a caller); a planted new spend path trips the census
alone; renaming a covering test to one that does not exist trips its own arm. Control
green before and after. Distances measured while setting LOOKBACK: all five real
transfers sit exactly ONE line below their guard, so the window of 3 has two lines of
slack and is not near its own boundary.

**A NAME CAN UNDERSTATE A CHECK, and reading the definition is the only way to know.**
`mustSpendable` sounds like it enforces `spendable` (stake-only), and both transfer paths
call it while AllowanceCC's comment promises the spend is "additionally capped by
disposable(owner)". That looked exactly like a comment asserting a property the code does
not implement — the most productive lens firing on a money path. It is not: mustSpendable
calls `disposable` internally, so it enforces the MAX of the stake and vote locks and the
comment is accurate. Recorded because the refutation is the useful part; the hazard was
hypothesised from a name and died on reading four lines of the function.

**A GUARD CAN BE THE CATCHER, and `elsewhere` is how to say so.** The mutation harness
runs SUITES, so a defect that only a `scripts/check-*.py` guard sees reports as a
survivor. Measured example: making `StakedPage` call `getPos` (a read that allocates)
survives every suite and fails `check-read-purity.py` with
`stakeindex.gno:StakedPage calls getPos`, exit 1. That row belongs in KNOWN-GAPS with
`elsewhere` naming the guard's path — and check-mutation-anchors verifies the path
resolves, so the annotation cannot rot into a shrug.

**THE CAP SWEEP, MECHANISED — AND THE FIRST VERSION OF THE QUERY WAS TOO LOOSE.** The
boundary lesson below generalises into a query: for every cap-like constant in the realm,
does any corpus row mutate the OPERATOR of a comparison against it? The first cut asked
whether any row's `find` CONTAINED the comparison, and that is not the same question — the
cap-DROP rows ("the folder cap is dropped") contain the text while changing something else
entirely, so a boundary with a drop row looked covered. Requiring the row to keep the
comparison and change its operator (`ops_of(find) != ops_of(replace)`) raised the unswept
count from 9 to 13. Both numbers came from the same tree ten minutes apart; the difference
is entirely in what was asked. Measured: 18 cap constants, 29 comparisons, and 13 of the 29
with no row mutating their operator. Two of those nine were the folders walks already argued
invalid, leaving seven to sweep — 3 caught by tests that had no rows, 2 INVALID, 2 real.
Worth repeating whenever a cap is added, because it costs one query and it found a read
that exceeds its own documented bound.

**twap SWEPT, AND TWO CANDIDATES KILLED BY READING THEM.** The ring is money-adjacent —
kourtv2 reads it for open interest and for X-bar, the answerability floor that gates
PostAnswer and sizes a flag bond — and it sat at 8.7 rows per 100 code lines with 31
comparisons, 20 of them unrowed. Most of those are serialisation guards, nil checks and
clamps. Two looked consequential and both are INVALID:

  `Average`'s `if bkt > r.base { v = r.last }` narrowed to `>=` looks like it would use the
  persisted value for the head bucket instead of reading the stored one — except Observe's
  last-value-in-bucket posture means bucket[base] IS r.last. Same program.

  `StaleBy`'s `if bn <= r.base { return 0 }` narrowed to `<` looks like it changes the
  answer at bn == base, and does not: the fall-through returns `bn - r.base`, which is 0.

Two suite runs saved by classifying before running, which is the whole point of the rule.

The four that were real are the CONSTRUCTOR and encoder guards, all caught: a zero width
(every bucket index is `height / r.width`, so zero is division by zero on the first read), a
zero bucket count, the 8-byte upper bound the encoder actually supports, and a zero
observation being refused as negative — zero is what the ring holds when nobody is staked,
so refusing it would panic on the first empty epoch. twap 14 -> 18 rows.

**THE UNUSED-PARAMETER CLASS, BOUNDED.** Having found three dead `who` parameters by hand,
the general question is worth one query: across 868 functions in the realm, which take a
NAMED parameter the body never mentions (comments stripped, `_` excluded)? Thirty-eight.
The breakdown is what matters:

  ~30 are INTERFACE IMPLEMENTATIONS and cannot be otherwise — Describe(payload),
  Check(payload), Do(rlm, payload) implement the governor Kind interface, and a kind that
  ignores its payload still has to accept one. checkpoint's WalkDesc(v) is a callback
  signature. Nothing to fix and nothing to row.

  3 are the governor `who` parameters already resolved (Settle, ReleaseRoll, Execute).

  2 are `run`'s dispatch and `describe`'s g inside the governor's own rules plumbing.

  3 are vestigial *Court/*courtMod parameters in kourtv2: unslash(c, cs) works entirely
  on cs, addNomination ignores its cm, installModSet ignores its c.

The three kourtv2 ones are HARMLESS in the way the `who` ones were not: an unused *Court
cannot be the wrong court, because nothing reads it. They are the same misleading-signature
shape one notch down — a reader may assume unslash touches court-level state, and it does
not — and removing them would ripple through call sites for a cosmetic gain, so they stay.

**What the sweep buys is the bound.** "Are there other misleading signatures on an authority
surface?" now has an answer with a number behind it: no, the address case was the whole of
it. The instrument was validated against realm code before the claim — unslash's body was
read and confirmed to use only `cs`.

**THE govern REALM'S CALLER-IDENTITY SURFACE: EIGHT ENTRYPOINTS, THREE ROWED.** govern.gno
has eight crossing entrypoints and every one passes `cur.Previous().Address()` into the
engine. Three carried the "the REALM, not the caller" row — Propose, Vote, Cancel — the
substitution that AGENTS.md names as the primary gno hazard. Five did not. Sweeping them
gave 1 caught, 4 surviving, and the four resolve into two quite different things.

**THREE OF THEM ARE DEAD PARAMETERS.** Governor.Settle's body is `g.settle(g.mustProposal(id))`
— `who` unused. ReleaseRoll's uses it nowhere either. Execute mentions `who` only in its
signature and in a comment ("a caller who forgot one"). So substituting any address cannot
change anything: INVALID, not survivors, and the correct classification for three rows that
look exactly like caller-authentication holes.

**AND THE MONEY READING OF THEM IS REFUTED — TWICE, THE SECOND TIME AGAINST MY OWN FIRST
ANSWER.** govern.gno says Settle is "Permissionless, and the freed deposit goes to whoever
calls", and ReleaseRoll "refunds its deposit to whoever calls" — with `who` dead, that reads
as a comment promising a refund the code cannot make, on a money path. First measurement:
**the governor package and govern.gno contain ZERO Transfer/Mint/Burn calls, in any file.**
No coin moves on these paths. From which I concluded that "deposit" was metaphor for the
proposal SLOT. THAT WAS WRONG.

It is gno's STORAGE deposit, and governor.gno says so forty lines away: the per-proposal
tree "buys a whole node on the first vote (~4,500 bytes) where a shared tree would cost one
entry, but dropping it is one assignment and the deposit goes back to whoever settles."
Allocating state costs a storage deposit; freeing it refunds that deposit to the
transaction's caller. votelock.gno:329 uses the same notion — "state paying a storage
deposit for nothing".

So the comments are ACCURATE, and the dead `who` is explained rather than excused: the
refund is the CHAIN's doing, so the code needs no address to make it happen. The absence of
Transfer/Mint/Burn is consistent with that, not evidence against it — a storage refund is
not a coin transfer written in realm code. The verdict never moved (no defect, three invalid
mutations); the REASON was wrong for one commit, which is the same right-verdict-wrong-reason
failure this file keeps finding in other people's records.

**THE FOURTH IS A REAL GAP, of a class already in the file.** Governor.Offer uses `who`
exactly once, at `"offerer", who.String()` inside an event emission, and nothing reads it —
a name once offered is bound to its code forever regardless of who offered it. So the
mutation changes one attribute of one event and no state, which no `_test.gno` can observe.
Same shape as PullSenior's zero payment, recorded with the same promotion trigger: an
`Events:` block on the offer filetest would pin it.

**RANKED ITEM 3 VERIFIED COMPLETE, AND ITS OWN PARENTHETICAL IS STALE.** The item asks for
"a message naming both on a tie, with its own test" and adds "the tie-break itself is in
KNOWN-GAPS as something that should stay unpinned". Both halves check out, but not the way
the sentence reads: there is NO KNOWN-GAPS row for the tie-break, and there should not be.
The four-case rewrite of mustSpendable made the tie DIRECTLY assertable, so it moved from
unpinnable to pinned instead of into the gap file — `mustSpendable: a tie names the stake
instead of naming both locks` sits in the main corpus, caught. An item's parenthetical
describes the plan at the time it was written; the fix can overtake it.

**A MESSAGE'S PREFIX IS THE WRONG THING TO GREP FOR.** Checking whether each of the four
lock messages is asserted, by counting test references to its opening words: "not enough
uncommitted CC" 14, "not enough unstaked CC" 10, and **"not enough free CC" — the tie
message — ZERO**. That reads as the tie wording being unasserted, and would have been a
finding worth writing up.

It is not. lockmessage_test.gno asserts "releasing either one" and "frees nothing" — the
DISTINCTIVE INTERIOR of the tie message, not its prefix. Tests here quote the middle
precisely so a reworded prefix does not break them, which is good practice and makes a
prefix grep useless as a coverage instrument. Grep an interior fragment, or grep several
and take the union. Same class as the earlier `grep | head` truncation: the instrument
answered a narrower question than the one asked, and its answer looked like an
answer to the broad one.

**RANKED ITEM 1(b) VERIFIED COMPLETE, AND THE QUESTION IT RAISES REFUTED.** The backlog
asks for ONE test covering both participant-only windows, because Crystallize's
`now < verdictAt+finalizeGraceBlocks` shares its shape with Finalize's in dispute.gno.
TestTheParticipantOnlyWindowsEndOnTheirExactBlock does exactly that — it drives Finalize
at dispute.gno:554 and Crystallize at crystallize.gno:44 in one test, each at its edge.

Reading the two together raises an obvious suspicion: the SAME constant on DIFFERENT
anchors, `escrowUntil + finalizeGraceBlocks` against `verdictAt + finalizeGraceBlocks`.
That looks like one site having copied the other and kept the wrong base. It is correct.
Each window is a week of participant-only measured from the moment its own call becomes
available: Finalize's from the escrow window lapsing ("a stranger must not pick the settle
block", v0.11 A13), Crystallize's from the verdict existing. Shared policy, shared
constant, different triggers.

The only thing left is a naming smell worth nobody's time to fix: `finalizeGraceBlocks` is
named for one of its two callers, so at the Crystallize site the constant reads as if it
were borrowed. Recorded rather than renamed — a rename touches two money paths to make a
comment read better.

**THE CLONE PROTECTS THE LONG PASS AND LEAVES THE SHORT BATCHES EXPOSED.** Running the
full corpus from a pinned clone is recorded above as the way to keep the working tree free.
What that recipe does NOT cover is the handful of one-to-five-row verification batches run
between commits, because those go through the LIVE scripts/mutate.py — and another session
edits that file. Measured today: a five-row ccwrap batch ran at 11:28, and at 11:34
mutate.py, gnoroot.py, check-storage.py and check-isolation.py all changed underneath from
another session. Six minutes of margin, entirely by luck.

The failure this invites is the dangerous direction. A half-edited harness does not usually
report nonsense; it reports rows as CAUGHT, because anything that makes the staged suite
fail to build or run looks exactly like an objection. So the practice is: **run verification
batches from the clone too, or check `stat` on scripts/mutate.py against the batch's start
time before believing an all-caught result.** `git status` before a commit already catches
the tree being shared; this is the same discipline one layer down, for the harness rather
than the sources.

**CORPUS DENSITY PER PACKAGE, AND WHAT THE ZEROES MEAN.** Rows per 100 code lines across
every tree the harness can stage: checkpoint 16.6, grc20votes 15.2, governor 15.0,
curve 13.9, kourtv2 13.2, govern 9.0, twap 8.7, **ccwrap 2.2**, and three at ZERO —
offerer (49 lines), cshares (273), tickbook (363). Six hundred and eighty-five lines with
no coverage at all looks alarming and is not:

  offerer is DOCUMENTED as staged-but-never-mutated, in mutate.py's own PKGS comment —
  "the govern realm's offer filetest imports it, so leaving it out makes the baseline red
  for a staging reason and every mutation reads as caught. That is the same lie as a build
  failure counted as a catch, told by omission."

  cshares and tickbook are imported ONLY by realm/r/kourtv1 — V1 support, and V1 is out
  of scope.

**AND ccwrap's 2.2 WAS A THIN CORPUS, NOT THIN TESTS — density measures the wrong thing.**
It holds Wrap and Unwrap, which move CC, so it read as the thinnest live money surface in
the repo. Five mutations written for it — both orderings, both amount guards, and the room
check moved after the transfer — and ALL FIVE were already caught. Nothing about the realm
needed changing; five properties simply had no rows.

The one worth naming is Unwrap's ordering, which its comment calls load-bearing: "BURN
BEFORE THE RELEASE ... releasing first would let a reentrant caller — or simply a bug in a
future edit here — draw twice against one balance." I expected that to need an adversarial
realm to observe, and it does not: TestUnwrapCannotOverdraw catches it by MESSAGE
SPECIFICITY, because an overdraw in the right order fails at the burn with the ledger's
error and swapped fails at the transfer with kourtv2's. Same mechanism as the transfer-guard
finding earlier — the assertion that names its message is the one with teeth.

So: density points at where the CORPUS is thin, which is worth rowing for its own sake (a
property with no row is a property nobody will notice losing), but it says nothing about
whether the tests are there. Only the sweep says that.

**THE ADJACENCY LESSON, APPLIED BACKWARDS TO AN OLDER GAP.** `Minted: the down-correction
overshoots` says "MASKED BY THE OTHER LOOP, and no single-mutation row can be written", and
that is true — the down-loop's `cst <= coin` and the up-loop's `cst > coin` repair each
other, so nudging either alone survives. But the same row already recorded the joint
measurement: nudging BOTH fails three curve tests. And the two loops sit next to each
other, separated by one comment line.

So the pair takes ONE `find`, exactly like the quality-bar clamps: added as `Minted: BOTH
correction loops are nudged, so the buyer is short-changed`, measured caught, 0 not caught
of 1. The surviving half stays in KNOWN-GAPS with a cross-reference, because it carries
information the joint row does not — WHY that half cannot be pinned alone.

**Two records that name different tests can both be right.** The gap row quotes
TestMintedIsMaximalAndNeverShortChangesTheBuyer; the harness reported
TestLargeValuesStayInside128Bits. Three tests fail on this mutation and a shard reports the
first it hits, so neither record is wrong — but a reader comparing them would think one was,
which is why the row now says so.

**The rule to carry forward: "no single-mutation row can be written" is a statement about
the halves, never about the pair.** Whenever that phrase appears in a gap's reason, check
whether the overlapping checks are CONTIGUOUS — two of today's four masking pairs were.

**AUDIT THE AUDIT RECORD: A GAP THAT INVITED CONSTRUCTION, CONSTRUCTED.** The 23
KNOWN-GAPS rows each claim to be unpinnable, and those claims age. Re-reading them all,
one carried an explicit invitation — `Cost: the int64 ceiling is off by one`, "NOT
CONSTRUCTED, and recorded as that rather than as unreachable ... IF SOMEONE CONSTRUCTS the
exact case, promote it."

The case exists. Its own argument was INCOMPLETE rather than wrong about the difficulty:
it searched d = 1, said the numerator must be 2^64-2 whose factor pairs have opposite
parity, and stopped there. The window is ((q-1)m, qm], so at d = 1 the numerator may also
be 2^64-3 — odd, factoring as 1 x (2^64-3), same parity, integral from and s1. That
solution dies on the CAP (New refuses cap > 2^50 and it needs s1 = 2^63-1), which is the
real obstruction and not parity.

Searching under the cap instead: diff = k*Q with Q = 2^63-1 = 7^2 x 73 x 127 x 337 x
92737 x 649657 makes m = k exactly, so any even k whose k*Q factors as
(s1-from)(s1+from) with s1 <= 2^50 lands the quotient ON the ceiling. 74 solutions; the
first is d=2, from=994862694074946, delta=18542, where q = 9223372036854775807 exactly,
guard 1 does not fire because hi2 = 1 < m = 4, and Cost returns (MaxInt64, true) intact
against (0, false) mutated. Promoted, and caught by TestCostPricesACostOfExactlyMaxInt64.

**Two lessons, and the second is the reusable one.** A gap's REASON is a claim like any
other and can be wrong in a way the verdict is not — this row's verdict (survives) was
right the whole time, its explanation was not. And a search that reports "no solution"
should say what it searched: "d = 1" was doing the work in that sentence, and nothing
flagged that the other d values were never tried except the row's own honesty.

**A COMMENT SAYING SOMETHING IS UNTESTED IS A LEAD, NOT A MEASUREMENT.** render_test.gno
states it plainly — "TestDirectoryRanksByBurn tests the INDEX (ListedCourtsBy) and never
the PAGE" — and an operator inventory of modrender.gno agreed: three boundaries in
listedPage with no corpus row at all (the zero-limit contract, the offset skip, the
length stop). Both existing callers pass offset 0, so I predicted two survivors and wrote
a paging-consistency test for them.

Measured: all three rows caught, and only ONE of them by the new test. The zero-limit
contract needed it; the offset skip is caught by TestFrontPageRanksByBurnAndSkipsHidden
and the length stop by TestDirectoryRanksByBurn, both of which exercise the page
incidentally while pointing at something else. So the comment was right that no test
NAMES the page and wrong that nothing covers it, and my prediction of two survivors was
half wrong. The corpus is three rows better either way — the boundaries are now pinned
BY NAME instead of by accident — and the test earns its keep for exactly one of them.

**Assert paging as a RELATIONSHIP when the fixture cannot own the data.** Suites share one
realm, so by the time this test runs the directory holds courts from every other test and
no slug sits at a fixed index. Absolute positions are untestable; `page(k) == all[k:]` and
`page(0,n) == all[:n]` are not, and they are exactly what an off-by-one breaks.

**THE SANITISE POLICY HOLDS, AND THREE HYPOTHESES ABOUT IT DIED ON A GREP.** Render
receives attacker-controlled input, and the house rule is that markdown output sanitises
while exported READS return raw for the overlay to sanitise itself — stated in
modrender.gno ("the ClaimBody read -> sanitize.Block ... Render's markdown ->
sanitize.Blockquote"), enforced by nothing. Enumerating every non-comment line in the five
markdown-building files that touches a user-text field (title, body, desc, name, tombstone,
reason, code) gives 19 hits, 8 sanitised and 11 raw. Each of the three ways that looked like
a hole was refuted:

  UNSANITISED TEXT IN MARKDOWN. No. The raw hits are field ASSIGNMENTS, emptiness tests,
  and the documented raw reads. FolderTree emits only ids, parents and flags.

  AN INCONSISTENT PAIR. claimTitleFor wraps a tombstone as `"[removed · " +
  sanitize.InlineText(...) + "]"` while FolderName wraps a purge code as `"[purged:" +
  f.code + "]"`, raw — the same shape, one sanitised. Different CONTEXTS, both correct:
  claimTitleFor feeds Render, FolderName is an exported read. Reading the enclosing
  function is what settles it, not the line.

  RENDER CONSUMING THE RAW READ. That would be the actual defect — raw text re-entering
  markdown through the read. FolderName and FolderDesc have NO callers outside their own
  definitions.

NO GUARD WAS BUILT, and the enumeration above is why: a naive "user field on a line must be
sanitised" check has 11 legitimate raw hits to allowlist, which is the nuisance shape that
gets a check switched off. The policy is currently kept and the dataflow is shallow enough
to re-run this enumeration by hand after any render work.

**AN ABSENT AGGREGATE TEST IS NOT A GAP IF EVERY BREAKAGE IS INDIVIDUALLY CAUGHT.** The
backlog says the senior queue is "essentially unswept", and one measurement seems to agree:
NO test walks c.queue at all — grepped the suite for c.queue, .queue.Iterate and queueSeq,
nothing. enqueueSenior's tiling invariant (seniors and juniors occupy disjoint stretches of
the accrual line, the audit M3-CRITICAL-1 repair) therefore looked unpinned, and a
queue-walking test with disjointness and conservation arms was written.

It was then thrown away, because it caught nothing new. Every single mutation that breaks
the tiling already has a caught row: the start cursor ignoring juniorReserved, the senior
tail never advancing, the queue seq not advancing so entitlements overwrite. The one
accumulation with no row of its own — reserveJunior's `c.juniorReserved = mustAdd(...)` —
is caught anyway by TestTheReservoirPauseHoldsAtExactlyTheCap, which asserts
`reservoirR() == rMax()` after drawing exactly the overshoot, so a reservation that never
lands leaves R above the cap. Counted: 21 caught rows across the queue and the reservoir,
plus 2 gaps that carry derivations. Conservation is rowed three ways (seniorOwed grows, is
reduced, seniorPaid advances).

So the ABSENCE of a walker was not evidence of a gap. The lesson generalises: when the
invariant is a conjunction of per-site facts and every site is pinned, an aggregate test
adds coverage only against code shapes that do not exist yet — and for THAT, the
instrument is a census, not a test. Which is what ARM 15 is.

**THE LONG-ANCHOR QUERY, MECHANISED — AND THE THIRD ANSWER WAS "DO NOT REFACTOR".**
Both duplications above were found through anchors needing absurd context, so the signal
is worth measuring directly: corpus rows sorted by `len(find)`. Median is 49 characters,
p90 is 94, and the top twelve run 200-326 — every one of them a place where the code says
the same thing more than once. That query is cheap and should be re-run after any batch of
rows.

**THE QUERY HAS FALSE POSITIVES, AND THEY ARE THE OPPOSITE OF THE FINDING.** A long
`find` can also mean one long STATEMENT rather than repeated code: lock.gno's
`mustSpendable: a tie names the stake instead of naming both locks` row is 308 characters
over four lines, third-longest in the corpus, and it is nothing to fix — the anchor is a
single multi-line panic message, which is the whole point of that switch. Read the anchor
before believing the query. Duplication looks like N copies of a BLOCK; a long message
looks like one string.

Its next real answer was the global-DAO purge gate: `ensureGlobalDAO()` plus a members.Has
check, FOUR byte-identical copies, one per purge verb. Same shape as the two just
collapsed, on the most authority-sensitive path in the realm — and the right call was to
LEAVE IT ALONE.

Why, because "we single-sited the last two" is not an argument: `ensureGlobalDAO` is in
check-read-purity's ALLOCATORS, and that guard greps function BODIES for allocator calls.
Hiding the gate behind a helper takes it out of that guard's sight, so an exported read
reaching the helper would stop being flagged — the fix would have to be paired with adding
the helper to ALLOCATORS, which is more moving parts than the duplication costs. And each
of the four copies is already pinned by its own caught row.

What the duplication actually risks is a FIFTH verb that forgets a gate, and no corpus row
can cover code nobody has written. So check-epoch-coherence gained ARM 14 instead: every
`^func Purge\w*(cur realm` must carry the authority gate AND mustCategoryCode, count
pinned at 4. Ablated four ways — a verb losing either gate names that verb and that gate, a
planted fifth verb trips both, and a drifted verb pattern reports "0 purge verb(s),
expected 4". **A census is the answer when the risk is the NEXT caller, not the current
ones.**

**A THIRD CANDIDATE, REFUTED BY READING IT.** supersedeOrdered's own comment says its
wall-clock-preferred/height-fallback shape is "exactly how CloseDeadClaim decides the same
question about the same claim", which reads like a third copy of the deadline arithmetic.
It is not. CloseDeadClaim asks an ABSOLUTE question — has this claim's deadline passed by
NOW — and already factors its clock preference through `pastDeadline(openedAtTime,
deadClaimSecs)`. supersedeOrdered asks a RELATIVE one: is `from` at least deadClaimSecs
after `to`. Two claims against each other cannot use a helper written for one claim against
now, so there is nothing to single-site. And the redundancy that remains is deliberate:
SupersedeClaim requires `to.closed` before it ever consults the ordering, so the two
predicates are belt and braces rather than a quote and a charge. CloseDeadClaim carries
FOURTEEN corpus rows including both clocks' boundaries; it is the best-pinned function this
query pointed at.

**AND THE ADMIN GATE IS NOT THE SAME CASE, which is why the query needs reading rather
than obeying.** `cur.Previous().Address() != d.admin` appears FOUR times in
moderation.gno, which looks like the purge gate all over again. It is not: the four carry
THREE different messages — "manages membership" (AddGlobalMod and RemoveGlobalMod, the
only genuinely identical pair), "sets the purge threshold", "transfers the seat" — and
naming the specific power is the value, exactly as mustSpendable's four cases are. One
condition with three deliberate messages is not four copies of one check. Left alone, and
the same check-read-purity argument would apply anyway.

**THE DISPUTE BOND WAS QUOTED AND CHARGED FROM TWO COPIES OF ONE FORMULA.** Following the
purge duplication out of the same cap sweep found the sharper case. `disputeBond0`'s doc
read "OpenDispute's formula, factored for DisputeBondNext" — and OpenDispute went on
computing the same ELEVEN LINES itself, byte for byte. The comment asserted a relationship
the code did not have, which is the most productive lens firing on a money path.

What each copy is for: `disputeBond0` is the QUOTE — DisputeBondNext returns it and
render.gno prints it on the claim page as "N CC units (doubles per failed round)".
OpenDispute's copy is the CHARGE — `mustSpendable` then `Transfer(who, c.escrow, bond)`.
So a drift between them shows the user one number and takes another. That is precisely the
shape check-epoch-coherence's one-weight arm exists to prevent for vote weight ("a quote
that can drift from the charge", its own words), unguarded here for money.

Nothing had drifted, so this is a refactor: OpenDispute now charges `cs.disputeBond0()`,
full suite green either side because the formula was identical. What it bought, measured:
four broken anchors reported by `make anchors` and re-pointed from ~13-line blocks to
single lines (three of them had needed the whole inline block PLUS the two lines after it,
purely to pick one of the two identical copies), and one row that could not have been
written while the duplication stood — `OpenDispute: the bond CHARGED is not the bond
QUOTED`, doubling the charge to ask whether anything compares the two. Caught by
TestDisputeBondTakesTheSmallerArmOnACappedCourt. Six rows, 0 not caught of 6.

**TWO DUPLICATIONS, ONE SWEEP, AND NEITHER WAS THE THING BEING SWEPT.** Both came out of a
cap-boundary inventory, via anchors that needed absurd amounts of context. A long `find` is
evidence about the CODE, not just an inconvenience for the corpus.

**AN UNPINNABLE BOUNDARY CAN BE A CODE SMELL, NOT A TESTING PROBLEM.** Three of the
thirteen unswept cap comparisons could not be given a corpus row at all: `if
len(categoryCode) == 0 || len(categoryCode) > maxReasonLen` appeared THREE times in
moderation.gno, byte-identical, so no `find` matched once. The existing rows for them had
solved that by anchoring on each verb's ENTIRE prologue — signature, stale-realm check,
caller lookup, global-DAO membership, then the block — a ~10-line anchor that any edit
anywhere in the prologue breaks.

The anchor problem was the symptom. Four byte-identical copies of one check (PurgeClaim,
PurgeCourt, PurgeModLogRow in moderation.gno and PurgeFolder in folders.gno) sit on the
realm's most authority-sensitive path: purge is the LEGAL removal, it erases text behind a
statutory code, and it takes a global-DAO threshold to fire. None had drifted yet, which is
the only reason collapsing them is a refactor rather than a bug fix — and it is exactly the
hazard stakeIdxMine's comment names about two readers of one tree, at four copies.

Collapsed to `mustCategoryCode`, beside checkReason which is the same species of gate. What
that bought, measured: the full suite green before and after (the condition and message are
unchanged, only the frame moved); five broken anchors reported by `make anchors` and
re-pointed to short stable ones; the length boundary rowable for the first time; and a
SECOND row that had never been writable — the empty-code half of the same line, caught by
TestFolderRulesAreEnforced. Six rows, `0 not caught of 6`.

**When a boundary resists being rowed, ask why before reaching for a longer anchor.** A
`find` that needs ten lines of context is telling you the code says the same thing in
several places.

**THE SECOND CAP BATCH: 5 caught, 5 surviving, all five closed.** maxSlugLen,
maxFailedRounds, maxSupInPerAuthor, maxHeightStep and maxHeightTotal were already held by
tests that had no rows. The five survivors were maxReasonLen at both its sites, maxSupIn,
and supersedeOrdered's deadline on BOTH clocks. Two of them are worth their own lines:

- **checkReason's cap contradicted its own message.** It panics "a moderation reason is at
  most 200 characters", and with `>=` a 200-character reason is refused — the guard
  disagreeing with the sentence it prints. Pure function of one string, so it is tested as
  one; a court fixture would only add setup between the bound and the assertion.
- **supersedeOrdered has TWO branches and they are chosen, not both run.** The time clock
  is used only when both claims carry an openedAtTime; the height fallback covers
  pre-upgrade claims. The same off-by-one lives in each, and a test of one leaves the
  other's arithmetic free. Its comment also claims the twelve-week gap is what makes
  re-filing cycles UNREPRESENTABLE rather than refused — so the boundary is load-bearing
  for a structural property, not just a date.

**A HYPOTHESIS I PROBED AND HAD REFUTED, recorded because the wrong explanation nearly
went into a comment.** The maxSupIn fixture first failed with "not enough CC ... more than
you hold" from a helper CLOSURE that captured `cur` and called `OpenClaim(cross(cur), ...)`
— the deposit charged to an address with no coin. Restructuring to a top-level helper
taking `cur realm` as a parameter (the shape stakeAnswerDispute uses) fixed it, and the
obvious story was that a captured realm does not carry through the extra frame. That story
is FALSE: a probe doing exactly that — one inline crossing call, then the identical call
from a closure capturing `cur` — succeeded on both (`id=1`, `id=2`). So the closure was not
the cause, the real cause is unestablished, and the comment in the test now claims only
that the helper matches the suite's shape. Two changes went in together (closure to
function, and `alice` to `c.admin`) which is exactly the one-thing-at-a-time rule broken;
the probe is what caught it before the false claim was committed.

**A FIXTURE THAT WRITES N POINTS MAY NOT STORE N POINTS.** The seriesRowCap test failed on
its first run against CORRECT code: 401 change points came back with the cap flag clear.
checkpoint.Series keeps its two newest values in inline slots and only rolls older ones
into the archive — measured at 20 written, 18 archived — and the cap governs the ARCHIVED
population only. So writing exactly seriesRowCap+1 archived two fewer than intended and
left the cap slack. The fix is not to hardcode "+2": the test COUNTS the archived entries
and refuses to run unless they sit exactly on the two sides of the cap, so it cannot
silently drift off the boundary if the inline split ever changes. Same discipline as
asserting `maxFolderDepth == 4` before building a chain by hand — **a fixture that assumes
where the boundary is should assert it.**

**WHEN THE OBSERVABLE CANNOT DISTINGUISH THE TWO CASES, RECORD IT RATHER THAN CONTRIVE.**
The other seriesRowCap site — ClaimSeries's trim, `if len(rows) > seriesRowCap` narrowed to
`>=` — is valid and stays unpinned. Its only observable is the `more` flag, which needs the
union of the two sides to be EXACTLY the cap; but the intact code trims any larger union
down to the cap, so a returned count of 400 cannot be told apart from "was 401, trimmed".
A fixture could not prove it hit the boundary, and computing the pre-trim union in the test
would restate the formula. Recorded in KNOWN-GAPS with the promotion trigger (make the
union size observable) instead.

**PAIR THE REFUSAL AT THE BOUNDARY, NOT MERELY SOMEWHERE LEGAL.** The standing rule is
to pair every "must be refused" with the ordinary input it must NOT refuse, and
TestFolderNesting obeyed it — a cycle refused, a self-parent refused, a too-tall subtree
refused, and "a leaf still moves" as the paired success. But the cap is 4 and that success
sits at depth 2, so the cap's arithmetic was unconstrained within two levels of its own
edge. An operator sweep of the nesting code measured what that cost: 5 mutations, 2 caught
and 2 surviving, and BOTH survivors were off-by-ones at the untested boundary — `>`
narrowed to `>=` on the cap, and folderDepth's `d := 0` started at 1. Either one leaves a
court able to nest only 3 deep while the panic message goes on promising 4.

One test closed both (measured: SURVIVED before, `0 not caught of 2` after) because both
make an exactly-at-cap nesting fail. The lesson is the placement, not the pairing: **the
success case has to be the LAST LEGAL VALUE, not a comfortable one.** A pair at depth 2
against a cap of 4 tests that the feature works; a pair at 4 and 5 tests the cap.

Corollary worth the line: assert the constant too. This fixture builds a chain by hand and
opens with `if maxFolderDepth != 4 { t.Fatalf(...) }`, because if the cap ever moves the
chain silently stops being "exactly at the cap" and the test goes on passing while
measuring the wrong depth.

**A SUBSTRING ASSERTION CAN BE SATISFIED BY A LAYER YOU ARE NOT TESTING.** The masking
layers found so far were all in the CODE; this one is in the test. TransferCC and
TransferFromCC both open `if amount <= 0 { panic("kourtv2: transfer amount must be
positive") }`, and both had a test passing 0 and asserting
`AbortsContains(..., "must be positive")` — which looks like the guard is pinned. It was
not. grc20votes carries its own `mustBePositive` panicking "grc20votes: amount must be
positive", so the substring is satisfied by EITHER layer, and the operator sweep reported
both rows SURVIVED. Measured directly rather than argued: with the realm guard weakened to
`< 0`, a zero-amount TransferCC still aborts, with `panic: grc20votes: amount must be
positive`.

The fix costs nothing and turns two unpinnable rows into two caught ones — assert the
realm's OWN full message, "kourtv2: transfer amount must be positive". Both rows went from
SURVIVED to caught (TestTransferRefusesNonsense, TestTransferFromRefusesTheSameNonsense),
0 not caught of 2, with the control green either side. So: **when an AbortsContains
substring would also match an inner layer's refusal, it is not testing the outer guard.**
Prefer the full message wherever a deeper layer refuses the same input — and note that the
outer guard still earns its place, because it refuses before `touch(c)` and it says which
realm refused.

Not every loose assertion is wrong for this reason: stake_test's `Stake(..., 0)` asserting
"must be positive" is sound, because a zero stake reaches no ledger call at all (lockStake
returns early and nothing transfers), so no second layer can satisfy it.

**THE SUBSTRING CLASS, SWEPT.** Having found one instance the expensive way, the
question "how many other assertions could an inner layer satisfy" is mechanical: collect
every `panic("…")` in the realm and in the p/ packages the realm imports, collect every
`AbortsContains`/`mustPanicWith` substring in the suite, and flag a substring matched by
BOTH. The first cut of that instrument was too blunt and said 37 — it counted kourtv1 and
ccwrap, which share dozens of messages with kourtv2 because one is its ancestor and the
other its wrapper, and which the kourtv2 suite never calls. Restricted to IMPORTED
packages it said 16; requiring a competing kourtv2 message as well, 15. That last
refinement matters: `'allowance exceeded'` is produced ONLY by grc20votes, and kourtv2
delegates allowance enforcement to the ledger, so asserting the ledger's message there is
correct rather than ambiguous.

All 15 tightened to the realm's own full message, full suite green — so none of them was
matching something other than the message named, and the tightening was free. Only the
transfer pair is known to have been hiding a live survivor; the other 13 are hygiene, and
saying otherwise would be claiming 13 closures nobody measured. `scripts/
check-abort-assertions.py` now keeps the class at zero: 347 assertions, none satisfiable
by a p/ layer that also has a kourtv2 counterpart.

**NOT GATED, AND MEASURED SO THE DECISION IS ON THE RECORD:** a substring can be loose
WITHIN kourtv2 too, and 46 assertions match more than one kourtv2 message — `'moderator'`
matches fifteen. Almost all are harmless, because the other messages are unreachable from
the call under assertion, and a guard reporting 46 findings against a correct tree is the
nuisance that gets switched off. The cross-layer rule is the one with a demonstrated
failure behind it, so that is the one with teeth.

**THE GUARD'S FIRST VERSION WAS VACUOUS, and only the ablation said so.** It scanned test
files LINE BY LINE, so an assertion whose message sits on the line below its call — which
gofmt produces as soon as the message is long enough to wrap — was structurally invisible.
It reported 345 assertions and a clean tree while being blind to the two transfer
assertions the whole check was written for, because tightening them had wrapped them.
Reverting one to its loose form produced NO complaint. Scanning the file text instead (the
`\s*` in the pattern already spanned newlines) found 347 and both arms then fired. Twice
now a new check has been vacuous on its first run — the `elsewhere` reachability rule and
this one — so treat "my new guard passes" as an untested claim until an ablation makes it
fail.

**A MASKING PAIR DOES NOT ALWAYS MEAN NO ROW CAN BE WRITTEN — CHECK ADJACENCY.** The
standing rule for overlapping checks is "ablate jointly to prove teeth, then record that
no single-mutation row can be written", and the second half is too pessimistic. A corpus
row is a text substitution, so when the overlapping checks are CONTIGUOUS in the source
the joint deletion is a single `find`. The full-bar clamps are two adjacent lines, each
occurring once, so two false gap rows collapsed into one real caught row. Measured, full
kourtv2 suite per arm: ordering clamp alone PASS, unit floor alone PASS, both deleted
FAIL at `TestTheQualityBarsNeverReachZeroOnAMicroCourt` ("the full bar is 0; an EMPTY
tally clears a bar of zero"), control green either side. Ask where the checks SIT before
concluding a pair is unpinnable.

**`head` TRUNCATES EVIDENCE, AND A TRUNCATED GREP READS EXACTLY LIKE A COMPLETE ONE.** I
went looking for a test pinning the bars, ran `grep -rn qualityBars realm/r/kourtv2/
*_test.gno | head`, saw hits from two files, and concluded the third regime was unpinned
— then designed a fixture for it. `TestTheQualityBarsNeverReachZeroOnAMicroCourt` was
already there, in a file whose match sat below the cut, asserting the same property with
the same derivation in its comment. Same failure as `grep -h` defeating a path filter:
the instrument quietly answered a narrower question than the one asked. When the
conclusion is "nothing covers this", COUNT the matches (`grep -c`, or no pipe at all)
before believing it.

**I COMMITTED WITH `make anchors` RED, WHICH IS THE ONE PROCESS RULE WRITTEN DOWN IN
CAPITALS.** The rule exists because it happened before: "a commit went in with `make anchors`
already failing because an `&&` chain carried on past the error. Check the guard result
before committing, not alongside it." I wrote `out=$(make anchors); rc=$?; echo "ANCHORS
EXIT=$rc"; git status && git add … && git commit …` — the `;` after the echo means the commit
never consults `rc`. Printing the exit code is not gating on it. The commit message then
asserted "anchors green" while anchors had exited 2.

The commit's CONTENT was harmless — VOTEFLOOR.md, 22 insertions, nothing else — and the
failure was not mine: another session has 39 uncommitted lines in moderation.gno, which
leaves three corpus rows' `find` matching 0x ("mod: AddGlobalMod keeps stale approvals" and
two TransferGlobalAdmin rows). That is theirs to settle when their edit lands, and
re-pointing those anchors now would only re-break as they iterate, so they are left alone.

Not amended away. The false claim is corrected here and in the commit that follows, because
erasing it would hide the process failure, and the failure is the more useful record: the
gate has to be `make anchors || exit`, or a separate command whose result is read before the
commit is typed. Every other commit today ran anchors as its own step and read the number;
this one folded it into the same command as the commit and got away with it until it did
not.

**THE WHOLE ROUTINE, RUN ONCE, END TO END — and the check on the check.** Every target had
been run piecemeal today; `make check` itself had not. It passes in **1 minute 57**, which
is worth knowing on its own: the routine is cheap enough that there is no excuse for
skipping it.

    gofmt clean; vet; gotest (6 Go packages)
    anchors 1,213 rows / 24 fixtures; paths; guards 26 committed / all armed;
    staleguards 125 entrypoints; demo-physics; nodelegate; scenarios-check
    web-test (10 JS suites); height-shim
    realm-test: 8 python guards + 12 gno suites
    txtar-test 39s; elsewhere-test 7 rows
    exit 0

**A GREEN `make check` IS NOT SELF-EVIDENTLY A FULL RUN, and that is the trap here.**
realm-test opens with `if ! command -v gno >/dev/null; then ... echo "gno not installed -
skipping realm tests"; exit 0; fi` — it SKIPS, silently and successfully, unless REQUIRE_GNO
is set. So on a machine without the toolchain the heaviest third of the routine evaporates
and `check` still exits 0. Verified rather than assumed this time: `command -v gno` resolves
to /Users/jk/gopath/bin/gno, and the log carries 12 `ok  .` lines — 7 p/ packages and 5 r/
realms, the kourtv2 suite among them at 12.73s. Count those lines, or set REQUIRE_GNO, or
the exit code is telling you less than it appears to.

**AND THE THIRD LEVEL: DOES THE NAMED HARNESS ACTUALLY ASSERT IT?** The `elsewhere`
question has three levels, and this file has now answered all three.

  1. Does the path RESOLVE? check-mutation-anchors has always asked that.
  2. Does anything in `make check` RUN it? Added this morning — six of seven rows named
     txtar scripts while txtar-test sat outside check.
  3. Does the harness ASSERT the property? A txtar that runs and says nothing about the
     mutation leaves the excuse exactly as hollow as an unrun one.

Level 3 measured, all SEVEN elsewhere rows, by applying each mutation and running only the
harness it names:

    StakedPage -> getPos            check-read-purity.py  exit 1,
                                    "stakeindex.gno:StakedPage calls getPos"
    Buy IsUserCall -> IsUser        paymentauth.txtar:37  no match for `direct user call`
    arming `||` -> `&&`             seeded.txtar:82       unexpected "gnokey" success
    arming nextID arm dropped       seeded.txtar:82       unexpected "gnokey" success
    arming TotalSupply arm dropped  coin.txtar:59         unexpected "gnokey" success
    CourtCount > 1 -> > 2           seeded.txtar:123      no match for `this realm
                                                          already has courts`
    tcEverArmed never set           testclock.txtar:80    no match for `true` in stdout

Every one honest, each failing at a specific line with a specific complaint.

**THE ROT PATH IS NOW WATCHED, and the reason first given for leaving it alone was
wrong.** That reason was: the two harness kinds need different plumbing, because a txtar
runs against a staged GNOROOT while check-read-purity reads the REPO. They do not. The txtar
harness stages realms into GNOROOT/examples FROM THE REPO, and the guards read the repo
directly, so BOTH kinds see a mutation applied to realm/ in place. One code path serves
both: mutate the repo, run the named harness, require failure, restore. The whole sweep is
25 seconds, not the afternoon it was estimated at — wrong on the plumbing and wrong on the
cost.

`scripts/check-elsewhere.py` (target `elsewhere-test`, in `make check`) does it, and the
rot it closes has no other watcher: if a txtar loses one of those assertions the row keeps
surviving in `make gaps`, which is the EXPECTED result there, so nothing else can tell.
Ablated both ways — weakening the assertion inside kourtv2_paymentauth.txtar makes it name
the row and say "the harness PASSED under the mutation, so it does not assert this
property", and renaming the `elsewhere` key makes it report "measuring nothing" rather than
a clean tree.

**IT MUTATES THE REPO IN PLACE, which mutate.py refuses to do for a good reason** — a killed
run leaves a mutation behind, invisible in `git status` if the file was already dirty. So
every write is paired with a restore in a `finally`, and the bytes are compared afterwards;
a mismatch is reported as a failure OF THIS SCRIPT rather than as a finding about the row.
Run it on a clean tree.

**AN `elsewhere` IS A PROMISE ABOUT A ROUTINE, so check the routine and not just the
path.** Resolving was never the whole question. The annotation says "that harness covers
this", which is worth exactly as much as the chance anybody runs that harness — and
measured on the target graph, six of the seven `elsewhere` rows named `.txtar` scripts
while `make check` did not reach `txtar-test` at all. Six rows excused by a suite the
routine never ran. `txtar-test` is now in `check`: it is 36s of the several minutes
`check` already costs, and it is the only harness where the deployer is the caller, so
several arming gates are unreachable anywhere else. check-mutation-anchors now requires
each `elsewhere` to be EXECUTED by something reachable from `check`.

**A REACHABILITY CHECK THAT ASKS "IS IT MENTIONED" IS VACUOUS.** The first version of
that rule looked for the path, or any ancestor directory of it, in the recipes `check`
reaches. It passed — and it passed identically with `txtar-test` REMOVED, because
`gnoland/testdata` appears in `scenarios-check`, which regenerates the scenario txtars
and `cmp`s them for staleness and never runs one. Both arms of the ablation reported
"covered", which is the only reason the vacuity was visible at all: **run the ablation
even when the check is already green, because green is what a vacuous check returns.**
The rule now asks about EXECUTION and answers per kind of harness — `go test -tags
txtar` for a txtar, `python3 <path>` for a guard — and an extension it does not
recognise is a FAILURE, since not knowing what runs a harness is precisely the case
where nobody has checked that anything does. Its seven fixtures include the unreached
runner and the mentioned-but-not-run directory, the two shapes that fooled it.

**Operator classes that are INVALID BY CONSTRUCTION — do not spend a suite run on
them.** A sweep of emission.gno flipped every comparison in the file and most of them
cannot change the program at all. Recognise these on sight rather than measuring them:

- **A clamp's own operator.** `if x > lim { x = lim }` and `if x >= lim { x = lim }`
  are the same program, and so are a zero floor's two forms, `if p < 0 { p = 0 }` and
  `<= 0`. Four of ten rows in the first money sweep were this.
- **An early return whose body is already a no-op for the boundary value.**
  accrueSegment's `blocks <= 0 || curPeriodBudget <= 0` looks like two guards worth
  pinning and neither can be: at zero, `num` collapses to the carried remainder, and
  `rem / periodBlocks` is 0 because `rem` is a modulus of `periodBlocks`, so cumAccrual
  and the carry both come out unchanged. advanceRateAcc's `blocks <= 0` is the same
  shape — `blocks` is never negative and multiplying by zero adds zero — which its own
  comment argues while still calling it a survivor.
- **A conjunct implied by the conjunct before it.** See the R_max pause, whose second
  half is provably entailed by its first; recorded in KNOWN-GAPS with the derivation.
- **A counting loop's early EXIT, when the count is only ever compared against the same
  threshold.** argument.gno counts a claim's out-edges with `return outN > maxArgOut` as
  the walk's stop condition and then decides with `if outN >= maxArgOut { panic }`.
  Narrowing the stop to `>=` makes the walk halt at 32 instead of 33 — and the decision
  panics either way, because it only asks whether the count reached the cap. The row I
  wrote for it was mislabelled as well as invalid: it claimed "exactly 32 is refused",
  which is what the intact code does anyway. The cap DECISION on the next line is the
  thing worth a row, and it already had one.
- **A loop bound set far above any reachable iteration count.** folders.gno's cycle walk
  runs `for up, n := parent, 0; up != 0 && n <= maxFolders; n++` with maxFolders = 100,
  and narrowing it to `<` survives. It cannot do otherwise: the only two writes to a
  folder's `parent` (the creation at folders.gno:281 and the move at :299) are each
  immediately preceded by mustNestable, so no chain exceeds maxFolderDepth = 4 and no
  cycle can be created — n never passes 4, and 99 versus 100 is unobservable. The bound's
  own comment says it exists for "state which somehow holds a cycle", i.e. for state the
  code prevents; keep it, do not row it.
- **A defensive guard on an internal helper whose every caller has already refused the
  value.** lockStake and releaseStake both open `if amount <= 0 { return }`, and
  narrowing either to `< 0` survives — but all three call sites provably pass a positive:
  Stake panics on `amount <= 0` before lockStake, Unstake panics the same way before
  releaseStake, and session.gno's release takes `p.stake` after refusing `p.stake <= 0`.
  Unreachable, so not a survivor. Worth keeping as belt-and-braces on helpers whose
  contract is "paired one release per lock", but not worth a row.
- **A floor standing next to a clamp that already delivers it.** qualityBars ends with
  `if fullBar < demotionBar { fullBar = demotionBar }` then `if fullBar < 1 { fullBar =
  1 }`, and demotionBar was floored to 1 earlier — so the ordering clamp can only fire
  when fullBar would be 0, and demotionBar is EXACTLY 1 there. Both lines yield
  `fullBar == 1`; deleting either ALONE cannot change the program. KNOWN-GAPS carried
  both single deletions as survivors, with consequences ("the full bar may be zero",
  "the ladder may invert") that neither mutation can actually produce.
- **A comparison against a value the code has just clamped.** touch's `boundary <
  segEnd` and `segEnd == boundary` both sit under `segEnd = min(now, boundary)`, so the
  equality cases are no-ops and `<=`/`>=` are the same program.
- **A mutant that does not terminate**, e.g. touch's `for lastAccrual < now` flipped to
  `<=`, which never advances lastAccrual. Its catch is guaranteed and worthless, and it
  HANGS the shard rather than failing it, so the harness cannot classify it. Skip
  deliberately and say so.

What was left after removing those was six rows worth running, and it found one real
gap (a zero-supply court's first roll) plus one valid-but-unpinnable (a zero-payment
event, since no event accessor exists anywhere in the gno stdlib).

**Another session may be editing the same tree, and treating that as a footnote cost
real work.** In one hour a concurrent session committed six times under me and twice
appended rows to `scripts/mutations-kourtv2.json`. Four distinct costs, in the order
they arrived:

1. A mutate batch reported EVERY row as `INVALID (did not build)` while their file was
   mid-commit — the same "re-run before investigating" shape as the staging transient
   above. It cleared on a re-run with nothing changed.
2. One of my corpus rows went in as part of THEIR commit, because we both had the
   shared JSON open and they wrote last.
3. Five rows I had just added and verified were CLOBBERED by their next write of that
   file: they had read it before my append and wrote back their own copy. A lost update,
   silent, no conflict, nothing in `git status` to see.
4. Then I made it worse. Trying to get a clean base I ran `git checkout --
   scripts/mutations-kourtv2.json`, which DESTROYED three uncommitted rows of theirs.
   They were never staged, so there was no blob to recover — `git fsck --lost-found`
   over every dangling blob found nothing, and their commit then shipped without them.
   I had the rule already ("restore from a scratch COPY, never `git checkout` a file
   with uncommitted work") and applied it only to my own edits.

What actually works: `git status` immediately before staging, never `git add -A`, and
for a shared JSON stage a version computed as `HEAD + my rows` rather than the working
file — otherwise their uncommitted rows ride along in your commit and their anchors will
not exist for anybody else. Append to a shared JSON at TEXT level, or at least match its
existing serialisation (this corpus is written with `indent=1` and ASCII-escaped, so a
`json.dump` with `ensure_ascii=False` rewrites every em-dash line and turns a one-row
addition into an 84-line diff that will lose a race). And treat a destroyed row as
recoverable ONLY from the tree it describes: the three lost ones were reconstructible
because their labels named their guards exactly, so each could be re-derived against the
committed source and re-verified as caught rather than guessed at.

Also: `nohup … &` inside a background shell makes the tool report "completed" the
instant the shell exits, with the real work still running and an empty output file —
run the command in the foreground of a background task instead.

**THE SHARED CORPUS FILE HAS NOW LOST UPDATES FOUR TIMES, so stop relying on care and
shrink the window instead.** Twice my rows rode into another session's commit; once I
destroyed three of theirs with `git checkout`; once they destroyed 84 uncommitted rows
including twelve of mine, and said so in their own commit subject. Every instance had the
same shape: rows appended to `scripts/mutations-kourtv2.json`, then MINUTES of guards and
suites, then a commit — with the whole verification window open for the other writer to
read-modify-write over.

The fix is ordering, not discipline. Verify the ROWS first, by ablating each mutation
directly (`scratchpad/ablate.py`) while the corpus file is untouched, and only then append
and commit in ONE command: append, run `make anchors` and read its exit status, stage,
commit. The window drops from minutes to seconds, and the batch survives in the scratchpad
either way — every sweep here kept its batch JSON, which is the only reason twelve
destroyed rows cost nothing but a re-append.

Rejected, deliberately: splitting the corpus per author or per topic.
`check-mutation-anchors.py` globs `scripts/mutations-*.json`, so a second file WOULD be
picked up with no tooling change — but a corpus that answers "what does this repo pin" out
of N files is worse for every future reader than a race that now closes in seconds, and
per-topic naming does not remove the race anyway, it just moves it to whoever else touches
that topic.

**ADDING CODE CAN BREAK AN EXISTING CORPUS ROW, which is not obvious and is the reason
`make anchors` belongs before every commit and not just the ones that touch a mutated
line.** A row anchors on source TEXT, so a new function that happens to reuse an
existing panic string retroactively makes that row ambiguous — it now matches twice, and
a row that matches twice measures nothing. That is exactly what landed: a new
`MoveItemInFolder` reused `panic("kourtv2: that claim is not in the folder")` from
`RemoveFromFolder`, and the older row for the remove-side guard went ambiguous in a
commit that never touched it. The fix is to widen the anchor upward until it is unique
(`if !found {` plus the panic), not to narrow the new code. Worth knowing that the guard
was already red at HEAD when I found it, in a commit whose own message says which guards
it closes — the check has to be READ, not merely run.

**How to measure gas here, since one attempt reported a 477x regression that does not
exist.** The harness's `--- GAS:` lines cannot be attributed to a crossing call, and
the reason the first attempt failed is worth stating precisely: one value per test is
the test TOTAL, and its POSITION in the stream varies between runs, so "the last line
is the call I made" gave two different answers for the same transfer. What is reliable
is that the total is the MAXIMUM of a single test's lines. So measure a call as a
DIFFERENCE of two totals over fixtures differing by exactly that call, run each test
alone, and take the max. Stable to the byte across repeated runs. Two preconditions,
both learned by getting them wrong: assert the test PASSED before reading any number
(a refused transfer yielded a negative marginal cost, which is what exposed it), and
hold total SUPPLY constant between the two fixtures — the answer bar is a
`supplyFloor`, so minting more to afford a bigger fixture raises the bar the fixture
must clear. The scaffold was deliberately not committed: a gas assertion in the suite
breaks on any recalibration, and the figures now live in votelock.gno where the design
decision they support is argued.

**AND A NINETEENTH COMMIT ADDS A FOURTH MOVE: check the algebra of a mechanism you
are describing.** Four files and a dozen commit messages said the reverted design
made the early-succeed arm "reduce to `yes*bps >= (total - abstain)*T`, dropping
`no` out of the test entirely". Turnout is `yes+no+abstain` and `rest` is
`total-cast`, so `yes+no+rest` is identically `total-abstain`: that reduction holds
under every version of the code, and `no` was never in the comparison. The real
defect was an inflated NUMERATOR against a snapshotted denominator, plus a negative
`rest` letting the DEFEAT arm fire on an open question. The conclusion — that a
ceiling is safe where a supplied weight was not — survives intact; the reason given
for it did not. Nothing had checked it because it read like a restatement of the
code rather than a claim about it.

**A FIFTH CORRECTION, and it is the same mistake twice.** `voteLockedOf` summed a
holder's open lock rows, double-counting the same coins: a holder who voted a verdict
and then its quality ride — which P11 makes an ordinary two-transaction act — had
40 B committed against a 20 B balance and could move nothing. Each row is a FLOOR
("at least this much must stay"), so one pile of `max(rows)` honours all of them.
This is the identical sum-vs-max error already fixed between the stake lock and the
vote lock in `disposable()`, written two commits apart by the same hand. Generalised
in the code comment: **a "total locked" quantity built by addition is worth
distrusting on sight.**

**And the quality lane was not an owner decision.** Three documents said it was
unlockable because its tally accumulates and there is no single instant to release
at. Looking for an instant was the error; the release is a CONDITION, not a moment.

**The first condition was wrong and a later probe found it.** It read *not terminal AND
the tally seq voted in is still live*, on the reasoning that a superseded tally counts
toward nothing — with the claim that the ordinary case therefore "releases immediately".
The seq moves when a round OPENS, and nothing makes a round open: a failed-quorum dispute
parks the claim with nothing open and no seq movement, and that state held a voter's
ENTIRE balance, measured at 20,000,000,000 of 20,000,000,000 with disposable 0. The
shipped condition asks whether the vote can still DECIDE anything, which is a different
question: *not terminal AND the seq is still the one voted in AND (some question is open
now OR these weights carry forward into later rounds)*. An ordinary flag voter now
releases when the flag resolves, and only the frozen-accumulating case waits for the
claim to end.

**AND A FOURTH CORRECTION, this one to my own step 6.** Step 6 declared the rental
closed on the strength of the floor. It was not. Probed on the four landed commits:
the floor asks what you hold at the MOMENT of voting and nothing about the moment
after, and a cast ballot is never undone — so borrow-seal-open-VOTE-repay measured
**599× the quorum floor with a final balance of zero**, against the 600× measured
before any of the work. The floor reordered the attack; it did not price it. That is
exactly what revision 3 said when it put the lock back in scope, and step 7 is that
lock. `RENTEDWEIGHT.md` and the whitepaper erratum have both been corrected, because
a document claiming a closure that does not hold is worse than one that says nothing.

The lesson is the one this file keeps re-learning: **measure the closure, do not
reason about it.** Every closure claim in this project that went unmeasured has been
wrong, and this one was mine, written in a commit message, one commit after I had
finished congratulating the harness for catching the same class of error.

**THREE CORRECTIONS THE PLAN NEEDED, found while implementing:**

1. **Step 6's copy sweep was mostly moot, and doing it would have introduced
   errors.** The plan listed seven comments saying staked coin keeps voting
   (`lock.gno:54/:74`, `stake.gno:167`, `court.gno:437`, `render.gno:373/:386`,
   `stake_test.gno:141`) as needing correction. That list was written when the floor
   was `spendable()`. With `BalanceOf` every one of them is still **true** — staked
   coin is in the balance and does vote — so they were left alone. What was actually
   stale was the opposite class: four comments asserting the rental was OPEN
   (`governor.gno` ×2, `electorate.gno`, `crystallize.gno`).

2. **`ResolveElection` PASS 2's second install condition was already covered.** The
   plan said to add a row because nothing pinned it; the row is caught by the
   existing `TestElectionZeroApprovalCandidateCannotInstall`. The row still earns
   its place — the coverage is now measured rather than assumed — but the premise
   was wrong.

3. **Arm 3's first retarget was worse than the thing it replaced.** Matching a
   trailing `int64` fired on `ReleaseRoll`, `Settle` and `Cancel`, because `id
   int64` is an identifier and not a quantity. It is now an exact allowlist of
   parameter names (`id`, `cap`, `quorumFloor`) that fails closed on a fourth.

**And one hole the harness found that review did not:** `check-nodelegate.py`'s
export arm could not match a bare `func Delegate(` — the pattern consumed the `D`
and left seven characters for an eight-character `[Dd]elegate`. My own ablation had
reported that arm green because the body I planted also *called* `.Delegate()` and
fired a different arm. An ablation that passes for the wrong reason is not
evidence; each half is now ablated separately.

---

### Revision 4 — panel 3's checklist

`spendable` docking the staker was found **independently by all three panels**.
Panel 3 measured the consequence I had not: at 94.8% of supply staked the entire
electorate voting unanimously produces 47,000,000 against a 50,000,000 election
floor, so **the creator cannot be unseated by anyone** — the "incumbency lock by
price" `electionFloor`'s own comments exist to prevent. Break-even ≈95% staked. Both
of panel 3's blocking findings are against `spendable` and dissolve under revision
2's `BalanceOf`; it says so explicitly.

**THE FINDING THAT CHANGES THE WORK: four of five mechanisms are invisible to the
suite.** Panel 3 ablated each in turn against all 293 tests:

| mechanism deleted | suite |
|---|---|
| `VoteWithCap` refuses `cap <= 0` | **caught** (by the flipped characterization test, and only that) |
| the `min` clamp in `castVote` | **green — not caught** |
| the quality-lane clamp | **green — not caught** |
| the election-lane clamp | **green — not caught** |
| the first-approval weight reuse | **green — not caught** |

And the floor **binds 22 times** across the suite (dispute 9, election 7, quality 6)
— it is driven constantly and asserted nowhere. Deleting only the `min` while
keeping the zero-cap refusal is a **silent revert to snapshot-only weight**. So four
new tests are mandatory work, not polish, and each ships in the commit that adds its
mechanism.

**Exact fixture amounts, measured to the unit, and the obvious alternative is
wrong.** Mint post-seal so `e.epoch` cannot see it: `4_500_000` to ev6's `voter`,
`5_000_000` to ev7's `small`. At one unit less each fails. Minting **pre-seal**
instead makes ev7 *pass and go vacuous* — proven in three runs: ev7 exists to pin
`ResolveElection` PASS 2's second install condition, which is only load-bearing when
`maxW == e.floor` exactly. There is **no mutation row for that condition**, so
`make mutate` would not catch its removal either — a pre-existing gap to close while
here.

**My own guard does not fire on this plan.** Arm 1 matches `.BalanceOf(` but
revision 1 wrote `spendable(`, which lives in an allowlisted file — so the tripwire
passed vacuously, and the guard's docstring claim that it "would have tripped on its
first commit" was false for this class. A false safety claim inside the guard built
to prevent false safety claims. Revision 2's `BalanceOf` makes Arm 1 fire, so it
needs pinned per-file counts rather than zero, and Arm 3 needs to become
shape-sensitive rather than parameter-name-sensitive.

**Also:** exactly **one** mutation row breaks (#171, re-anchorable, meaning
preserved) and seven should be added; `check-nodelegate.py` **does not exist at
HEAD** — my own revert removed it — and it matters more here, because the ceiling
is delegation-aware while the floor is own-balance-only.

### Panel 3's ordering, green at every step (measured)

1. `test`: the two fixture mints only — no-ops today, since post-seal coin is
   invisible to `e.epoch`.
2. `feat(governor)`: `VoteWithCap` + the clamp + Arm 1/Arm 3 retarget + the second
   selftest control + three governor tests + mutation rows 1–3. Nobody calls it yet.
3. `feat(kourtv2)`: quality clamp + its test + row 4.
4. `feat(kourtv2)`: election clamp **and** first-approval reuse together — splitting
   them opens the `max(line.weight) ≤ turnout` hole in the interval — plus
   `e.voters` `bool→int64`, two tests, rows 5–7.
5. `feat(kourtv2)`: dispute call site, row #171 re-anchored **in the same commit**
   (the `anchors` target needs no toolchain, so it fails otherwise), and the
   characterization flip, which cannot be split.
6. `docs/fix`: every comment saying staked coin keeps voting — including a
   user-visible panic string and a rendered line. Panel 3's note: fold these into
   step 3 rather than ship a tree whose panic text contradicts its own rule.

Steps 2–4 commute; 5 follows 2; only 1 must precede 4.

### Revision 3 — panel 2, and the scoping decision it reversed

**THE LOCK IS BACK IN SCOPE. Deferring it was wrong.** Panel 2 measured that
`mustBeSealed` refuses only `at >= Epoch()`, so a buyer in the last block of an
epoch can read that epoch as sealed **one block later**. My "wait an epoch, about an
hour" was the *worst* case; an attacker picks the best, which is one block. So the
whole sequence — buy, open the question, vote, sell — fits in a single block, and
the floor alone changes the verdict-lane rental from **600× the bar to 599×**.

The floor catches sell-then-vote. The lock catches vote-then-sell. The same-block
attack is vote-then-sell, so **the lock is the load-bearing half for it** and the
plan without one buys the election lane (24 h, because `approve` refuses before
`nominateEnd`) and nothing else. `EXACTANCHOR.md` said this in as many words and I
scoped it out anyway.

**MY JUSTIFICATION FOR THE HAIRCUT WAS FALSE, and the codebase already corrected
the same error once.** Revision 2 claimed *"`votableAt` nets the escrow out of every
denominator."* Measured: only `electionFloor` nets. `credWeightFloor` reads raw
`PastTotal`; `qualityBars`' 5% and 1.25% arms read `PastTotal(cs.qualityEpoch)` raw.
And `court.gno:418` says so directly — *"It is NOT 'netted out of the quorum floor',
which this comment used to claim (v0.29) … the 5%-of-supply arm that usually
dominates reads RAW supply."* I re-made a documented v0.29 mistake.

**Superseded — see "RESOLVED" below; the cost is bounded at 2x the floor and the
asymmetry is answered by the lock.**

**So the haircut has no coherence argument, and panel 2's framing is the right
one:** the alternative to "escrowed coin *adds* weight" is not "escrowed coin
*subtracts* weight" — it is **escrowing is irrelevant to the vote**, which is
exactly what a snapshot already delivers. Crediting the bond produced the zero-cost
coup in attempt 2. Docking it is this plan. **Neutral is correct and neutral is the
status quo.** The haircut is therefore a real, unjustified cost, carried below as a
cost rather than defended.

### Revision 2 — what panel 1 changed, and both were my errors

**The floor was the wrong quantity.** Revision 1 said `spendable`, and asserted
*"it does NOT dock a staker."* That is false and I verified it: `spendable` is
`BalanceOf − lockedOf`, `lockedOf` IS the stake, and `spendable`'s own comment says
*"Locked CC is still in the holder's balance and still votes."* Using it would have
re-imposed the **court-wide disenfranchisement** `court.gno:428` records v0.34
deleting — *"it bought exactly one thing: disenfranchisement … removing the
staker's vote COURT-WIDE when the design only ever wanted it CLAIM-SCOPED."*
Measured by the panel: at 84% of votable staked, `votable/3` becomes unreachable,
and an unreachable quorum hands the claim to the answerer by apathy. **The floor is
`BalanceOf`** — which is what revision 1's own prose described when it said "only
coin that actually left for the escrow is excluded".

**The `cap == 0` sentinel reopened the exploit verbatim.** Revision 1 contradicted
itself: the change table said *"`cap == 0` means uncapped"*, the prose said
*"`cap <= 0` is refused."* Under the first reading the renter sells everything, the
floor is 0, the cap is 0, the governor reads "uncapped", and the full rented weight
lands. Confirmed by execution — the characterization test still passed. **Zero is
not an edge case; it is the exploit's terminal state.** No sentinel: `cap <= 0` is
refused and `Vote` remains the uncapped path.

## The rule

```
w = min( PastVotes(who, Q) , c.coin.BalanceOf(who) )
```

`Q` is the question's **own already-frozen** anchor — `p.epoch` for a dispute,
`cs.qualityEpoch` for a quality tally, `e.epoch` for an election. Nothing new is
frozen and no anchor moves.

- **Ceiling = the snapshot.** You cannot buy in after the question was asked.
- **Floor = what you still hold.** You cannot vote weight you have given back.
  `BalanceOf`, so staked coin still votes (stake is a lock in place) and only coin
  that genuinely left for the escrow is excluded.

Neither half works alone, and that is the whole history: attempt 1 (snapshot only)
was rentable — buy, wait an epoch, open the question yourself, sell, vote. Attempt 2
(live only) broke every frozen bar and voided the governor's parts-vs-whole
contract. This is the intersection.

## Why it is coherent, structurally

`w ≤ PastVotes(who, Q)` for every voter, so

```
Σ w  ≤  Σ PastVotes(·, Q)  ≤  PastTotal(Q)  =  p.total
```

`rest := p.total - cast` therefore cannot go negative, `wouldBe` is untouched, both
early-decide arms stay sound, and every absolute bar (`credWeightFloor`, both
quality bars) is compared against a numerator bounded by its own instant. **This is
the property the last two attempts each broke, and here it is an inequality, not a
discipline.**

## The governor seam — the part that must not repeat

Attempt 2 added `VoteWithWeight(who, id, choice, weight)`. A supplied weight is not
drawn from `p.total`, so `cast` could exceed it — a permissionless verdict flip.

**This plan supplies a CEILING, never a weight:**

```go
func (g *Governor) VoteWithCap(who address, id int64, choice string, cap int64) {
    // w = min(what the engine derives, what the caller will allow)
    ...
}
```

The engine still reads `g.voters.PastVotes(who, p.epoch)` itself. A consumer can
only ever *lower* the figure. A buggy or hostile consumer cannot raise `cast` above
`p.total`, so the bound is enforced where the quantity that depends on it lives.
`cap <= 0` is refused — **no sentinel, no "0 means uncapped"** — and `Vote` /
`VoteWithReason` are untouched, so `r/govern` keeps today's behaviour exactly.
The realm pre-checks the floor too, so the refusal names the live floor rather than
surfacing as the governor's "no voting power at that epoch".

Panel 1 verified the cap is safe by exhaustive sweep — 6 thresholds × every
(yes,no,abstain) triple × every capped triple beneath it — and found **no case where
capping turns an early-decide arm ON**. Analytically the arms reduce to
`yes·bps ≥ (total − abstain)·T`, so shrinking any component only raises the bar.
That refutes the "a smaller cast raises rest" worry revision 1 raised against
itself.

## Changes, in order

| # | file | change |
|---|---|---|
| 1 | `p/governor/governor.gno` | add `VoteWithCap`; `castVoteAt(..., cap)` takes `w = min(PastVotes(who, p.epoch), cap)`; `cap == 0` means uncapped (today's path) |
| 2 | `r/kourtv2/dispute.gno` | `VoteDispute` → `c.gov.VoteWithCap(who, cs.proposalID, choice, c.coin.BalanceOf(who))`; keep recording the resulting weight for the carrot |
| 3 | `r/kourtv2/quality.gno` | `VoteQuality` → `w = min(c.coin.PastVotes(who, cs.qualityEpoch), c.coin.BalanceOf(who))` |
| 4 | `r/kourtv2/modvote.gno` | `approve` → same shape on `e.epoch`, **plus** record the voter's weight at their FIRST approval and reuse it for the rest of the ballot. Panel 1 measured this fix sufficient and complete, including the `retain` line, and confirmed `e.voters` has only two other touch points so a `bool → int64` value change breaks no reader |
| 4b | `r/kourtv2/modvote.gno` | **`electionBond` clamped to at most `electionFloor/2`** instead of to the floor itself — see the bond double-duty finding |
| 5 | `scripts/check-epoch-coherence.py` | Two corrections, opposite to what revision 1 said. **Arm 1 is BLIND to this plan** (`LIVE` matches `.BalanceOf(` but revision 1 used `spendable(`, so the tripwire would have passed vacuously); it needs pinned counts in the tally files rather than zero. **Arm 3 does not need relaxing** — it only matches parameters literally named `weight`/`w`, so `cap int64` already passes; it needs *strengthening* to be name-independent, because today a re-introduced raw weight under any other name would slip through |
| 5b | `r/kourtv2/render.gno` + 4 comment sites | `render.gno:386` tells a voter *"every unit votes, committed or not"* — false under this plan. Same phrase at `lock.gno:54`, `lock.gno:74`, `stake.gno:167`, `court.gno:437`. Add a `VoteWeightOf` read so a voter can see their effective weight before spending a transaction |
| 5c | `p/grc20votes` test | Add the **past-epoch** assertion `Σ PastVotes(·, E) == PastTotal(E)`. Panel 1 measured it true but found nothing pins it: the existing test pins the LIVE form, and the governor's parts-vs-whole test runs against a synthetic electorate that never touches a checkpoint. It is the load-bearing inequality and it is unguarded |
| 6 | fixtures | the two election tests that sit at exactly the floor need rebalancing — see "the haircut" |
| 7 | `rentedweight_test.gno` | its characterization assertions must FLIP: the exploit must now be refused |
| 8 | `r/kourtv2/lock.gno` + 3 lanes | **the lock, back in scope.** Amount-keyed (the weight actually cast, which the ceiling makes known at vote time), held until RESOLUTION not the ballot close, gating `TransferCC`/`TransferFromCC` only so staking and bonding stay free. Panel findings it must respect: no bond credit; lock after the ballot is recorded, not before; and `max()` vs `sum()` across lanes must be decided explicitly — `sum` re-creates "one dust abstain freezes the whole inventory", `max` means one unit of coin backs votes in several lanes at once |
| 9 | `ApproveCC` comment | a live floor lets a spender front-run the owner's vote with `TransferFromCC` and zero their weight, which falsifies *"an approved spender can do strictly less than the owner could do themselves"*. Correct the comment; the hazard itself is not closed |

## A hole I found while writing this, and the fix

`approve` credits `e.turnout` **once**, at the voter's first approval, but sets
`line.weight += w` on every approval with a fresh read. Under a live floor,
`spendable` can *rise* between approvals (unstake, or a bond returns). So a later
approval could carry more weight than the turnout credited for that voter, and
`max(line.weight) ≤ e.turnout` — arithmetic today — would stop holding.

**Fix:** store the voter's weight at first approval and reuse it for the whole
election. That is one weight per voter per ballot, which is the property an earlier
panel identified as correct, and it makes the inequality a theorem rather than a
coincidence.

## The haircut — narrowed by revision 2

`BalanceOf` excludes only coin that has genuinely left the balance for the escrow —
a bond or a claim deposit. A voter who has paid to participate votes with less.
**Staked coin is unaffected**, which is the correction panel 1 forced.

`RENTEDWEIGHT.md` rejected this design for exactly that reason. That rejection was
inconsistent with reasoning I wrote later the same day: `votableAt` nets the escrow
out of **every denominator**, so escrowed coin voting was the incoherence, not its
exclusion. A nominator holding exactly the 5% floor who then pays a fee genuinely
holds 4.57% of votable and is correctly refused.

So: accepted. The two fixtures that sat exactly on the boundary get rebalanced, not
the mechanism.

### The haircut is a COST, not a correctness fix

Withdrawn: the claim that docking escrowed coin restores coherence. It does not —
three of the five denominators never netted the escrow in the first place. What
remains is a straight price, and panel 2 measured who pays it, as a fraction of the
bar each payer must clear:

| payer | escrowed | of the bar they face |
|---|---|---|
| claim author (deposit + fee) | 33 CC | 0.2% of the quorum floor |
| answerer, aged claim | 10,125 CC | **11.2%** of quorum, **40.5%** of the demotion bar |
| disputer, round 3 | 1,120 CC | **9.5%** of quorum |
| flagger, 4× frozen | 933 CC | **24.8%** of the demotion bar |
| election nominator | 1,500 CC | **10.0%** of the election floor (exactly β/q) |
| nominator, small court | 0.75 CC of 15 CC | **100%** of the floor |

**RESOLVED, and the resolution came from the lock rather than from anything in this
section.** Two measurements, both against the shipped tree:

**1. The cost is bounded at 2x the floor, and it is 1.1x on any real court.** To
nominate a line AND remain a sufficient approver of it you need `floor + bond`.
Measured across four court sizes:

| votable | floor | bond | bond/floor | self-carry needs |
|---|---|---|---|---|
| 10 CC | 500,000 | 500,000 | 100% | **200% of the floor** |
| 100 CC | 5,000,000 | 1,000,000 | 20% | 120% |
| 1,000 CC | 50,000,000 | 5,000,000 | 10% | 110% |
| 100,000 CC | 5,000,000,000 | 500,000,000 | 10% | 110% |

2x is a CEILING and not an observation: `mustElectionInvariants` panics unless
`electionBondBps < quorumSupplyBps`, and the `flagMinCC` clamp pins `bond <= floor`.
The 100% row is the clamp binding on courts under ~50 CC votable; everywhere else
the ratio is exactly β/q = 10%, fixed because `electionFloor` and the bond are both
quoted on `votableAt` — which `TestElectionBondNeverExceedsTheFloor` ARM 2 already
pins by putting 99% of supply in escrow.

**2. The asymmetry is answered by the vote lock, not by the bond.** This section's
objection rested on "the attacker's carry is 0.0000021% of their position for one
block." That is no longer true: the lock commits a voter's whole voting position for
the round, so the attacker now carries **100% of the position they are attacking
with, for the full voting-and-resolution window.** The dominant cost stopped being
the bond — flat, and therefore regressive — and became the position hold, which is
proportional and identical for attacker and defender. A flat bond against unequal
wealth is still regressive, but it is now a rounding error next to the carry, and it
is the same property every bond in the system has rather than anything the vote
floor introduced.

**And the residual cost is the INTENDED property.** Whoever pays for a ballot line
cannot also be its sole sufficient approver, so a self-approved set always needs one
other holder — which is what "self-approved junk always costs" was asking for.
`TestPayingForALineCostsTheBondItVotesWith` pins both arms, and it exists mostly to
stop the obvious "fix": crediting the nominator's own bond back as weight was
implemented once and reverted, because at low votable `bond == floor` makes that
credit alone clear the bar from a zero balance — a free moderator coup. Ablated: the
credit is caught, and `TestElectionZeroApprovalCandidateCannotInstall` does NOT
catch it, so the new test is real coverage rather than a duplicate.

So no per-address "committed to this court" figure is needed, and the ~35-site
refactor this section proposed as the honest follow-up is not owed.

Also new from panel 2, and created by this plan: a mill self-stakes its own claim to
inflate X̄ for free (principal returns 1×), which inflates the flag bond, which docks
the flagger's weight **below the bar they just opened**. That attack does not exist
today because a snapshot is untouched by a bond.

### The bond double duty — bounded, not solved

Panel 1: under any live floor a nominator's own election bond is docked from their
vote. With β/q = 1/10 a coalition holding exactly the floor lands **1000 bps
short** (measured: floor 50,000,000, post-bond weight 45,000,000). Worse, in the
clamped regime (`votable < 20 CC`, where `electionBond == electionFloor` exactly)
the nominator is refused outright and the court becomes **challenge-proof by
price** — the exact condition `mustElectionInvariants` forbids and structurally
cannot see, since its three panics compare package constants.

Crediting the bond back is NOT available: that is precisely what produced the
zero-cost moderator coup in the reverted attempt. **Proposed instead: clamp
`electionBond` to at most `electionFloor/2`.** Then the electorate's remedy costs at
most 1.5× the floor instead of 2× or infinity, the haircut can never be decisive,
and the fix is one line rather than a carve-out. Flagged for panels 2 and 3.

## What this does NOT do — deliberately out of scope

- ~~No lock.~~ **REVERSED in revision 3 — the lock is in scope**, amount-keyed,
  until resolution. Without it the floor is a single-block test and the verdict
  rental is unpriced (600× → 599×, measured). With both halves: the floor refuses a
  renter who returned the coin *before* voting, and the lock refuses one who tries
  to return it *after*, so the attacker must hold from the anchor through
  resolution. That is the whole point and it needs both.
- **Two hazards panel 1 raised that this plan does not close**, recorded so they are
  not mistaken for oversights. A live floor makes an **allowance** a
  vote-suppression instrument: a spender can front-run the owner's vote with
  `TransferFromCC` and zero their weight, which falsifies `ApproveCC`'s promise that
  *"an approved spender can do strictly less than the owner could do themselves"* —
  at minimum that comment must be corrected. And `ccwrap`'s vault is not the escrow,
  so wrapped coin stays in every denominator while being castable by nobody, and a
  live floor removes the one party who could still cast it. Both grow with DEX
  adoption.
- **No checkpoint or epoch change.** `epochBlocks` stays 720. "Immediate" therefore
  means "within one epoch", and that is a dial for later, not part of this.
- **No `rest` early-decide deletion.** Two panels recommended it and Cosmos removed
  the identical construct; it is independent and can follow.
- **No quality-lane accumulation fix.** A divested voter's banked weight still
  decides later rounds. That is TODAY's behaviour, unchanged by this plan, and the
  fix is a product decision.

## What the reviewers must decide

1. Is the coherence inequality actually airtight at every comparison site, or is
   there a lane where the numerator is not bounded by `PastVotes(·, Q)`?
2. Is `VoteWithCap` safe in the way `VoteWithWeight` was not — including for a
   hostile consumer, and including `cap` interacting with the early-decide arms?
3. What is the rental worth now, in real units, and is "must hold at Q and at the
   vote" enough given that selling afterwards is free?
4. Is the haircut acceptable, and does it break an honest path that is not a
   knife-edge fixture?
5. Does the carrot still pay the weight that was tallied?
6. What breaks, exhaustively.
