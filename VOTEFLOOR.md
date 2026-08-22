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
