# CLAIM_BOARDS — per-claim comments, standing, and the freeze

> **v1.2 — two orderings.** Supersedes v1.1 after a fourth review round. Owner
> rulings settled: the level ladder tops out at **10×** entry; moderators get the
> top rung free but stay throttled; the claim's author gets a **reserved slot**,
> not unlimited posting; comments **nest one level**; an **undisputed** claim's
> winners earn **half** what an adjudicated one's do; and comments are served in
> **two orderings — Top and Newest — neither of which is the only page one.**
>
> The single ranked list v1.1 proposed is withdrawn. `MODERATION.md` §3.2 already
> refused it in as many words, about the directory: *"This deliberately avoids an
> auto-ranking on any address-keyed or vote-keyed signal (a capture surface); the
> only rank is curation + burned capital + age."* An upvote is address-keyed and
> vote-keyed. Review reached the same place by arithmetic — because votes are
> free and never consumed, one address could own 23 of 25 slots on every claim in
> a court, permanently, for the price of storage deposits.
>
> ---
>
> **STATUS (2026-08-25). Build steps 1–7 are complete and green.** The header
> above is the v1.2 DESIGN record and is kept as written; what follows is where
> the code actually is.
>
> | step | state |
> |---|---|
> | 1 standing ledger + four credit hooks | built |
> | 2 pass, levels, rate, standing page | built |
> | 3 comments: tree, depth 1, row caps, sanitize | built |
> | 4 ranking: upvotes, score index, two orderings | built |
> | 5 legal lane + the closed code set (§7.6) | built |
> | 6 per-court act log (by reuse, §11) | built |
> | 7 slash, freeze, restore, `speechM`, the global backstops (§7.7) | built, minus the election window |
>
> Gates: the twelve non-web check targets green; **851 tests pass alone as well
> as together**; every one of 131 selftest controls fires; ~1,436 mutation rows
> and 33 recorded-equivalent gaps. `make check` stays red only on `web/`, which
> is a separate workstream.
>
> **FOUR OWNER RULINGS BLOCK THE REST**, each written up where it bites:
>
> 1. **§7.7** — is the election-window refusal actor-scoped or target-scoped?
>    Both readings break, in opposite directions.
> 2. **§7.7** — should a live slash or freeze lapse at `OpenElection` at all?
>    As specified it is a permissionless self-release for ~0.4 CC net.
> 3. **§4** — moderators' free top rung is a stated v1.2 ruling and `postLevel`
>    does not implement it. The code may be right; that paragraph's own last
>    sentence argues against the rule it is attached to.
> 4. **§13** — a frozen address may still `OpenClaimP`, so the freeze reaches the
>    surface a person answers on and not the one they are attacked from. Both
>    repairs change what a freeze is.
>
> **OWED AND NOT BLOCKED**, in descending order of value: the two earning-base
> re-bases (§13 — the conviction one multiplies its row by up to 78×, so it
> cannot ship without `standingConvictionBps` falling by the same factor, which
> is a calibration call); the meta court's own board, whose 1-of-1 set is where
> appeals against the deployer would be argued; and the per-address half of
> global slash recovery (§13).
>
> **This text has still had no adversarial pass as a whole.** Three reviewers went
> over the SHIPPED CODE on 2026-08-25 (§7.8) and found three exploitable bugs, a
> 1-of-any court-wide speech throttle, and six wiring defects — all fixed — but
> the design document itself has not been re-reviewed since v1.2. §13 carries the
> round-4 remainder, and §7.1's withdrawn `n < 2` claim is the reminder that a
> finding can outlive the code it was about.
>
> Companions: `MODERATION.md` (the constitution), `PLAN.md` §3 (the tokenomics
> this must not touch), `docs/ASSOCIATIONS.md` (the sibling speech surface).

---

## 0. The system in one page

A claim gets a comment thread. Comments nest one level: a flat list of top-level
comments, each with replies underneath.

**To comment at all** you need a level. Two roads:

- **Earn standing** — reputation from things the court has adjudicated. The main
  road.
- **Burn CC once** — a one-time entry pass for someone with no standing yet. A
  bootstrap, not the main road.

**Your level sets your rate.** Nothing else does. The ladder tops out at 10× the
entry rate, deliberately short (§4).

**Each comment costs the ordinary GNOT storage deposit** and nothing else. No CC
per comment, no credit balance, no bucket.

**Comments are served two ways: Top and Newest.** Top ranks by the standing of
whoever upvoted; Newest is chronological, newest first. Both are paginated and
both are one click apart, so being outranked is never being hidden. The claim's
author and answerer hold reserved slots on Top.

**Moderators** may hide a comment, slash standing, and freeze an address off the
board. None of those move a coin.

## 1. Constitution

> **The only CC this lane moves is the entry burn: the poster's own coin, by
> their own act, destroyed. No moderator, DAO, or verdict ever moves a coin
> here.**

No escrow, no refunds, no transfers, no bounty for reporting spam — so nobody can
be paid for *finding* it. `moderation.gno`'s "even a fully captured moderator is
harmless to funds" stays true.

The lane never gates a lifecycle transition and never touches `answerRecord`.

**ARM 7.** `check-epoch-coherence.py` requires every non-escrow-sourced
`coin.Burn(` to sit within three lines below a `mustSpendable`. `BuyCommentPass`
satisfies that by construction — a `COIN_OUT_N` bump and a census row, not an
exemption. It is the first path in the realm that burns from a user balance,
which falsifies `lock.gno`'s standing comment ("nothing burns a user's balance");
correct it in the same change. `check-spend-paths.py` also needs an entry **and a
named test**, which the previous revision missed.

**Supply.** The entry burn reduces `PastTotal`, moving `votableAt`,
`quorumFloor`, `electionFloor`'s margin arm and `supplyFloor`. Self-defeating:
burning X destroys X of your own weight to move a 5%-of-votable bar by 0.05X, and
the `votable/3` clamp makes that 3:1 against you at best. Recorded, not
mechanised.

## 2. Standing — the input

### 2.1 Two ledgers, never merged

| | earned how | mods may slash? | gates |
|---|---|---|---|
| **Answer record** (`answerRecord.score`) | contested-and-upheld answers; zeroed on overturn | **never** | the 24h answer-priority window |
| **Standing** | §2.2 | **yes** | the comment level, and upvote weight |

`score` gates who may answer a claim. A moderator able to slash it would shape
the answer lane.

### 2.2 Earning — one rule, four rows

> **You earn standing in proportion to your own capital that the act committed or
> destroyed, and only where the court adjudicated something.**

| activity | base | gate |
|---|---|---|
| a slash that **settled** | what it destroyed (`dustBurns + slash`) | `slashGrade`: full bar, ⅔-low, survived the counter-window |
| **prevailed in a dispute** | that party's **own** posted bond | `credEligible` on an uphold; an overturn is quorum-gated by construction |
| authored a claim rated **HIGH** | the author's own time-averaged stake | ⅔ at full turnout; **seeded earns zero** (I5) |
| **winning conviction** | the staker's own time-averaged stake | tier ≥ MID; **full rate if a quality vote concluded, half if it did not** |

The conviction row is **rated, not gated**, and both halves of that landed this
revision after review broke the first attempt twice.

A conclusive LOW earns nothing: the tier is zero, the draw is zero, the record
follows the money. Without that arm a claim the court rated junk still paid in
full — 4.5× the mill's entire money punishment on a young court, 22.7× on a
mature one.

But the first version *also* refused every undisputed claim, on the reasoning
that a default mid is what a claim nobody looked at receives. That is right about
the mill and wrong about everyone else: it makes the credit turn on whether
somebody chose to dispute you, a dispute is partly noise, and most claims settle
undisputed **by design** — so the row would have paid almost never. An undisputed
stand is worth something and worth less. What prices the mill on that path is the
**flag lane**, which any address may open and which zeroes the tier on a
conclusive low; standing leans on the lane the money already leans on rather than
inventing a second, stricter gate of its own.

The residual is therefore a flag-probability question — ECONOMICS.md's `q` — and
belongs in that memo beside the money mill's, not here.

**Never credited:** commenting or being upvoted (circular — standing is what buys
commenting); buying CC, or burning it for the pass; an answer that merely stood
undisputed (A18).

**BLOCKER on the re-basing below, found while pinning the constants.**
`standing.gno` states the ordering *"policing ≥ authorship > staking"* and calls
it "the part that must not move, because it is what stops standing becoming a
yield on holding rather than a record of work." In raw bps it is already false:
authorship is 500, staking is 1,000.

Today that is not yet a defect — the two rows read different bases (authorship
scales on the claim's X̄, staking on a conviction integral), so their bps are
not comparable and the effective ordering can still hold. **It becomes one the
moment both move onto the earner's own time-averaged stake**, which is exactly
the correction owed below: on one shared base, 500 against 1,000 means
authorship pays *half* what staking pays — and authorship is the strictly harder
gate (⅔ at the full bar, seeded excluded), so it should pay more, not less.

So the re-basing may not land without raising `standingAuthorHighBps` above
`standingConvictionBps` in the same commit. That is a calibration change and
therefore an owner call. `court_test.gno` carries the absent assertion with this
reasoning beside it, so the trap is visible at the place someone would trip it.

**The two traps in the re-basing, verified against source rather than taken
from the review.** Both are correctness issues independent of the calibration
ruling, so they are settled here and the implementation is ready when the ruling
comes:

1. **At the author hook, the author's own position has NOT been accrued.**
   `Crystallize` calls `advancePools`, and that settles the *side* integrals
   only — `cs.yesRawHi/Lo` and `cs.noRawHi/Lo` — never a per-position
   `p.rawHi/p.rawLo`. `AuthorBonus` knows this and calls
   `accrue(c, cs, p, int(cs.provisional))` explicitly before reading them. So a
   naive re-base that reads `p.rawHi` at the hook gets a figure stale as of the
   author's last stake event; review measured the understatement at **7.9×**.
   The fix is one line — call `accrue` at the hook, which is legal there because
   it is a write path — but it must be *written*, not assumed.

2. **The conversion would put a new panic arm on `Crystallize`.** Time-averaged
   stake is `raw / openBlocks`, and that divide currently lives inside
   `capBonus` via `div128`, which panics on `hi >= den`. Today `div128` runs only
   inside the *pull* functions, where a panic strands one address. Moving it into
   `Crystallize` widens the blast radius to the whole claim's draw — the exact
   outcome `satAdd` and `scaleBps` were written to avoid on these paths. So the
   re-base needs a clamped helper that returns 0 rather than panicking, and the
   divide has to be extracted from `capBonus` rather than duplicated beside it,
   or the realm gains an eleventh copy of one rule.

**Two bases are still wrong in the shipped code** and owed: the author row reads
`xBarFrozen` (the crowd's money, not the author's) and the conviction row reads
`convCC`, a *flow* measured against three *stocks* — measured ~15,000× out of
proportion on a short claim. Both move to the earner's own time-averaged stake.

### 2.3 Monotone

Standing never decays. It falls only by a logged moderator slash.

**The justification changed and then partly changed back.** v1.0 argued no-decay
was safe *because standing allocated nothing scarce*. v1.1's single ranked list
made that false — one page one is zero-sum. **Two orderings (§5) restore most of
it**: Top is still contestable and still favours the earliest cohort, but Newest
is not, so nothing is denied and the scarce good is one *view*, not the surface.
What remains is a preference, not an exclusion. Named again in §13.

## 3. The entry pass

`BuyCommentPass` — burn CC once, hold the entry level.

    passPrice = clamp( max(passPriceMinCC, passPriceBps × PastTotal(epoch−1)) )

`PastTotal(epoch−1)`, never `TotalSupply()`: live supply is griefable in the same
block.

**The clamp is not optional.** `supplyFloor` and `electionBond` both carry one for
the same reason: at `passPriceMinCC = 1 CC` on a 15 CC court the speech door
costs 6.7% of supply — above the turnout bar, i.e. speaking priced above winning
an election, on the surface where a campaign to unseat a captured set happens.
Lid it below `quorumSupplyBps × PastTotal`, matching `supplyFloor`'s form.

**Per-court, not realm-wide.** `StartCourt` is permissionless and free, and the
curve integral for 1 CC on a virgin court is 500 ugnot — so a realm-wide pass
would cost half a millicent from a throwaway court.

The pass is not standing, earns no standing, is not transferable, and buys the
entry rung only.

## 4. Levels and rate

    level(who) = 0                      if frozen
               = top rung               if an active moderator
               = max(fromStanding, 1)   if the pass is held
               = fromStanding           otherwise

**The ladder tops out at 10× the entry rate** (owner call). Short on purpose: the
top-to-entry ratio is exactly what a splitter gains and exactly what farming
standing is worth in throughput, so it is the number that bounds both.

**The rungs must be convex in standing**, and v1.0 had this backwards. Splitting
is weakly worse only if `rate(ℓ)/threshold(ℓ) ≥ rate(1)/threshold(1)` for every
rung — otherwise `⌊S/τ₁⌋` entry-level addresses out-post one top-level address,
by a factor linear in standing and unbounded. This is a constant-space relation
and belongs in `mustInvariants`.

**Moderators get the top rung free but stay throttled.** Not unlimited: a
captured set flooding is the case the moderation design exists for; moderators
are *elected* and the board is where a campaign to replace them happens, so an
unlimited incumbent against a throttled challenger is a thumb on that scale; and
a meta-installed set would hand an attacker the same. They do not need it — their
job is hiding and slashing, not posting.

> **NOT BUILT, AND THE CODE MAY BE RIGHT — OWNER RULING NEEDED.** `postLevel`
> (posting.gno) implements the third and fourth arms of the formula above and
> neither of the first two. The frozen arm is delivered more strongly elsewhere —
> `mustBoardWritable` refuses the write outright rather than dropping the rate —
> so nothing is missing there. The **moderator arm is simply absent**: a
> moderator earns and buys their way up the ladder exactly like anyone else.
>
> The argument for leaving it absent is the same one this paragraph already
> makes, one step further. The ruling's own reasoning is that the board is where
> a campaign to unseat a set happens, so an incumbent must not out-post a
> challenger. But the free top rung IS that advantage, just bounded: 30 posts a
> day against a new challenger's 3, on exactly that surface, for the whole
> election. "They do not need it — their job is hiding and slashing, not posting"
> is the sentence that decides it, and it argues against the rule it is attached
> to.
>
> This is your call, not mine, because the free top rung is a stated v1.2 ruling.
> Building it is a small change to `postLevel`; leaving it out is the status quo
> and needs only this paragraph rewritten. **Until you rule, the code stays as it
> is and this note is the record that it diverges from the header.**

Two cosmetic consequences of the absent frozen arm, worth stating so nobody
"fixes" them into a bug: `PostLevel`, `PostsPerDay` and the standing page report
a frozen address's full rate, and `bucketAt` keeps refilling during a freeze, so
an address thaws with a full day banked. Both are consistent with a freeze being
a time-out rather than a rate cut, and the bucket caps at one day either way.

**The author is not unlimited either.** They get a reserved slot (§5), which is
what the need actually is: be visible, answer questions about your own claim.
Unlimited would let the one person most motivated to shape the record bury every
criticism of it.

Rate gates on **wall-clock**, never height. A slash lowers standing → lowers the
level → lowers the rate **in the same block**; there is no banked balance a
sanction fails to reach.

**Sybil, stated honestly.** The rate is address-keyed, so n addresses get n
rates. What bounds a flood is an entry burn per address plus a GNOT storage
deposit on every comment forever. Priced, not prevented — the same standard every
other flood surface here meets.

## 5. Two orderings

Comments are served two ways, both paginated, both reachable from the claim page:

- **Newest** — chronological, newest first. Cheap, monotone, needs no index of
  its own beyond the row key, and **nothing can be pushed off it**.
- **Top** — ranked by `score`, the sum of the standing of everyone who upvoted.

**Neither is the only page one, and that is the whole design.** A single ranked
list makes position zero-sum, so it is worth capturing, and review priced the
capture at storage deposits: one address with modest standing could hold 23 of 25
slots on every claim in a court, permanently, because votes are free and never
consumed. With Newest always beside it, capturing Top buys a *view* rather than
the surface — being outranked is never being hidden, and the guarantee the board
owes (§5.3's enumeration) is discharged by an ordering nobody can contest.

This is not a novel arrangement here. `MODERATION.md` §3.2 gives the directory
exactly two orderings — GNOT-burn descending and creation-order newest-first,
each from its own monotone index — and says why: *"deliberately avoids an
auto-ranking on any address-keyed or vote-keyed signal (a capture surface)."*
v1.1 proposed exactly that signal as a sole ordering. Withdrawn.

**Upvotes**, which now feed one ordering rather than the ordering:

- **Upvote only.** A downvote is burial handed to anyone with standing, and
  burial already belongs to moderators with a threshold behind it.
- **One vote per address**, deduped.
- **Weight linear in standing** — any cap or curve is concave, and concave means
  splitting your standing across addresses beats holding it in one.
- **Snapshotted at vote time**, so one slash does not re-sort every board in the
  court. **Known cost, and it is real:** a cast vote is a banked effect a slash
  cannot reach, so §4's "no banked balance a sanction fails to reach" is true of
  throughput and false of rank. Bounded, not fixed, by Top not being the only
  view. If it needs fixing, the bound is per-voter — re-key only the slashed
  address's own votes, which their rate bucket already caps — not a court-wide
  re-sort.
- **A vote is a state write**, therefore its own flood surface: it draws on the
  same rate bucket as a comment.

**The Top index** is keyed `score|rowID`, re-keyed on each vote, reverse-
iterated, **per claim** — a court-wide tree cannot be offset-paged, because
`bptree`'s offset iteration takes no start/end bound. Three further things review
established that the implementation must carry:

- **`IterateByOffset`'s `count` is a visit budget, not a yield budget** — the
  callback's return does not stop the counter — so a page that filters hidden
  rows short-pages, by an amount an adversary chooses. Either the index holds
  **only visible rows** (remove on hide, re-insert on clear) or the page cost is
  O(offset + hidden) and must be capped and stated as such. The first is better
  and also fixes a tombstone holding position.
- **Re-keying breaks offset pagination across pages**, which `stakeindex.gno`
  rejects in as many words for its own index ("any prefix of a holder's list is
  stable across reads"). One upvote between a reader's page 1 and page 2
  duplicates one row and hides another. Newest, being append-only, does not have
  this — a second reason it is the guarantee-bearing ordering.
- The row must store **its own current key** and the re-key must `Remove` that
  stored value, never a recomputed one — `reindexBurn`'s shape. And the score
  must accumulate through `satAdd`: a sum over upvoters is unbounded, and a wrap
  puts a row at one end of the order or the other permanently.

**Reserved slots** on Top for the claim's author and answerer, so the parties to
the question are visible without needing rank. **Cold start** is unnecessary as a
separate rule: with every un-voted row at `score = 0` and ties by row id,
descending iteration is already newest-first, so Top degenerates gracefully to
Newest until standing exists.

## 6. The comment tree

- **Depth 1.** A flat top-level list; each comment carries its direct replies.
  Deeper nesting breaks pagination (you cannot say "25 per page" when a subtree is
  200 deep) and gives a flooder a way to push things around by replying deep.
- **A flat index beside the tree**, so every reply is addressable by id and the
  whole set enumerable without walking. This is the one idea worth taking from
  `p/gnoland/boards`, whose `AllReplies` does exactly this.
- **Rows are immutable.** No edit (a text mutation outside purge breaks I4), no
  author delete. An author may self-hide, which is a discovery bit.
- One text field, **~2 KB hard cap**.
- **Per-claim tree**, lazily created — a court-wide tree keyed by claim pages in
  O(offset), because `bptree` offset iteration works only over a whole tree.
- **Mandatory per-row route** `/<slug>/<claimID>/board/<rowID>` — the I3 analog,
  since courtMod bits may not remove text from a deep link. Note `render()`
  splits the path into three, so this needs a parser change, and the new route
  must pass the text gate: the 3-segment route was once the one render path that
  bypassed it, and purge did not reach it.
- Closes for new rows at the terminal predicate the realm already uses
  (`verdictAt != 0 || closed`, plus provClose) — not `crystallized`, which
  `CloseDeadClaim` and provClose never reach.

**Build it in kourt's own bptree idiom rather than importing
`p/gnoland/boards`.** The package is 1,061 lines and the subset kourt would use
is 491 — real, but mostly storage a realm with strong existing conventions
already knows how to write, against a dependency whose upgrade path kourt does
not control, on a chain where its presence would need checking, for a page
attached to money. Its permissions hook is a clean interface and its grief model
lives entirely in the realm, so importing *would* work; the reason not to is
taste about dependencies, and it is reversible.

## 7. Moderator powers

Money-free. Logged, evented (actor, act code, target, height), and category-coded
**from a closed set**.

**`mustBoardCode`, not `mustCategoryCode`.** The existing helper bounds a code by
*length only* and its own comment argues against an alphabet — so "category-coded
with no free text" is false against shipped code, and a moderator could write a
200-character sentence about a named person that the realm renders on that
person's page. The board lane needs its own closed `switch`, panicking on
default, with the page rendering the **enum's static string**, never the stored
value. The full set — hide, batch-hide, slash, freeze, board-freeze, purge-row,
global-hide-row — must land **before deploy**; realms are write-once.

A **per-court act log** with stable row ids and its own purge verb. The existing
log is claim-keyed, so a slash or address freeze has nowhere purgeable to land.

### 7.1 `speechM`

    speechM = min(n, max(2, m))       computed at the act site

Never below the set's own `m`, and never above `n`. v1.0 proposed
`max(2, ceil(m/2))` and it was wrong twice: at `n = 1` it demanded two approvals
from a one-member set, which `approveAction` answers by returning false while the
entrypoint returns normally — a successful transaction that does nothing — and it
was not strictly monotone, so it did not close the suspension-escape it was
introduced for.

**The `min(n, …)` arm closes both, and this document spent several revisions
saying otherwise.** Computed across the range: `n=1,m=1 → 1`; `n=2 → 2`;
`n=3,m=1 → 2`; `n=9,m=4 → 4`; `n=32,m=32 → 32`. It is capped by `n` by
construction, so it is satisfiable at every configuration the realm permits, and
the "board ships unpoliceable on the modal court" claim carried forward from the
round-4 review **is false against the formula this plan actually specifies**. It
was true of the formula that review was reviewing.

What survives is much smaller, and is not new: on a 1-of-1 court the creator can
hide a row, slash and freeze alone. They can already `HideItem` alone — that
fires at `cm.m`, which is 1 on a fresh court — and a claim hide removes the whole
claim from discovery, board included. So the board hands a solo set no unilateral
power it did not already hold over the same content. That is the accepted §13.7
decoy residual, unchanged.

`mustElectionInvariants` is an `init()` over package constants and structurally
cannot see per-court `m`/`n`, so this is computed at the act site, not at deploy.

### 7.2 The four powers

- **Hide a row** — speechM-of-n. Discovery only; the deep link still serves.
  Not 1-of-n: the realm's own precedent for the identical act, `HideItem`, is
  m-of-n.
- **Slash standing** — speechM-of-n. Ratchets down by whole levels. `highWater`
  on the row, rising only with earnings, never with a moderator act;
  `RestoreStanding` raises `score` toward it and never past.
- **Freeze an address** — speechM-of-n, **board writes only**. A frozen address
  still stakes, votes, answers, disputes, flags, opens claims, withdraws, draws
  emission, **and takes every election action** — that allowlist is explicit
  because the election is the remedy. Duration below the **1-day nomination
  window**, not the 7-day vote.
- **Freeze one claim's board** — speechM-of-n, auto-expiring.

### 7.3 Election windows

Hides, batch hides, slashes and freezes are refused, and **live freezes and
recent slashes both lapse** at `OpenElection`. v1.0 lapsed freezes and left
slashes standing — the same asymmetry it had just diagnosed.

**Scoped to the parties of the contest, not court-wide.** Court-wide was itself a
capture path: `OpenElection` is permissionless and the bond floors at ~1 CC, so
anyone could buy a court-wide moderation blackout for ~0.5 CC net every
fortnight, and a frozen harasser could self-release in the same block.

Note the premise v1.0 leaned on is false: the board is **not** the only
user-writable text surface — `OpenClaimP` takes a free-text body, and `HideItem`
stays available throughout an election. State which verbs the refusal covers.

### 7.4 Recovery

**Replacement, not appeal.** The election, plus two meta verbs that are
**court-keyed and need no `meta.gno` change**: `mod:suspend:<court>` and
`mod:setmods:<court>/<candidateID>`. `setmods` is the answer for the case local
replacement cannot reach — a court whose electorate is one whale, where retain
always wins.

- **No board act may write `setActHeight`, `lastElectionAt`, `suspendActByGlobal`,
  `suspendedM`, `suspendedSetID`, `creatorUnseated`, `installedByMeta`,
  `clm.executedAt`, `clm.globalClearedAt` or `electionCooldownUntil`.** Stated as
  an **allowlist** — a board act writes board state and the act log, nothing
  else. `meta.gno` refuses a `setmods` verdict when `setActHeight > verdictAt`,
  so one board hide after each verdict would permanently veto the remedy.
- **Global backstop**, which v1.0 asserted and did not have: `ClearAnyBit` is
  claim-keyed and reaches no board sanction. Add `GlobalClearBoardBits(court)`
  and `GlobalRestoreStanding(court, addr)` (clamped to `highWater`), and have
  `ResetModSet` clear live freezes — a reset to `n = 0` otherwise leaves everyone
  frozen with nobody able to unfreeze.
- **Deploy precondition: `d.n ≥ 3` and `d.purgeM ≥ 2`.** Every "global-DAO
  m-of-n" here is a single key at bootstrap.
- **The meta court has a board too**, and its own 1-of-1 set — so the remedy
  would be discussable only on a surface the body being appealed to may sanction.
  Bind meta-board sanctions to the global DAO only.
- **Suspension** masks hides and freezes; the freeze clock is masked, **never
  paused**. `RestoreStanding` and unfreeze take `requireMod`, not
  `requireActiveMod`, so a suspended set can still de-escalate.

### 7.5 No reclaim crank

Hidden rows persist. Deleting them on a timer would be a third constitutional
bend (the count is pinned at two, both legal-hold), it would delete the evidence
a successor set needs while the clock runs against a row the electorate cannot
see, and — verified — the chain refunds a storage deposit to **whoever frees the
state**, so a permissionless deletion crank is a standing bounty for censorship.

Consequence carried, and now answered. Whole-court purge is vacuous for a board
— it stops new rows, it does not touch existing ones — and one row at a time
cannot answer a hosting-is-offence order against a 400-row board inside 72 hours.
**`PurgeBoardRange` (BUILT 2026-08-25)** destroys a claim's whole board 64 rows
at a time, resumable by cursor. Three things it settles:

- **The decision is voted once; the completion is not.** The first call takes
  `d.purgeM` and sets `boardPurgeAll`; after that any global DAO member advances
  the cursor. m-of-n per batch would make a 500-row board eight coordinated votes
  against a clock, and the second vote decides nothing the first did not.
- **The order is visible from the first batch**, not the last — `BoardPurgeOrdered`
  and a `board-purge-all` log row — so a page never shows the material an order
  named while the remaining batches run.
- **The batch bound counts WORK, not visits.** Counting visits looks equivalent
  and is not: a re-run over an already-purged board hits the bound at row 65 and
  reports a resume cursor forever, so "done" is unreachable for any board over
  one batch. Skipping a purged row costs a visit and no write, and the walk is
  bounded regardless — `maxBoardRowsPerClaim` caps a board at 512.

### 7.6 Legal lane — **BUILT** (2026-08-25, `boardlegal.gno`)

Three verbs, all global DAO, none reachable by a court moderator — pinned by a
loop that refuses the court's own 1-of-1 mod as well as a stranger.

- **`GlobalHideRow`** — single key, category code, all-surface. Unlike the
  editorial hide, the deep link withholds too; that is the whole difference and
  the reason the verb exists, since the courtMod row hide does not "disable
  access" and so is not the act a notice asks for.
- **`GlobalClearRow`** — the per-row put-back §512(g) actually requires.
  `GlobalClearBoardBits` (§7.4) is court-wide and answers capture, not a
  counter-notice; without this verb a wrongly-redacted row could only be restored
  by clearing every redaction in the court.
- **`PurgeBoardRow`** — global DAO at `d.purgeM`, m-of-n, irreversible. **It
  zeroes `r.text`.** Every other purge in this realm sets a tombstone and leaves
  the bytes in state, which is tolerable for a title; a board is an unbounded
  2 KB-per-row surface under a hosting-is-offence-remove-within-72h runbook, and
  a bit over bytes still in state does not discharge that. Row id, author and
  height survive, so the record still says a comment was here and who wrote it.
  No hash of the removed text is kept: a digest that lets a third party confirm
  what was there is not something this realm should hold.

**The re-set window.** Re-setting a redaction that a global act cleared inside
`reSetWindowBlocks` takes m-of-n, exactly as `GlobalHide` does, so one rogue key
cannot win the reversal race and camp a row redacted. Both halves are pinned:
inside the window a single key does not fire, past it a single key does — which
is what makes it a window rather than a permanent escalation.

**Two code sets, and the split is deliberate.**

| | codes | shape | why |
|---|---|---|---|
| editorial (hide, slash, freeze) | `mustBoardCode` | **closed switch**, five codes | targets a person; MODERATION §6's mod-copy rule forbids assertions of fact about one, and there is no claim-about-the-claim phrasing available for "this address was slashed" |
| legal (redact, purge) | `checkReason` / `mustCategoryCode` | length-bounded, extensible | I11 requires the purge code set shape-extensible before deploy, and a write-once realm cannot record the first statutory category nobody anticipated |

The closed set is `spam, off-topic, abuse, impersonation, illegal-referred`,
readable at `BoardCodes()`. It landed now rather than with its first consumer
because a realm is write-once and the vocabulary must be complete at deploy.
**Nothing emits an editorial code yet** — the acts that do are step 7.

**The withholding bits live ON the row, not in a side tree.** `boardTextFor` (the
wire) and `boardTextVisible` (the page) are the whole guarantee, and a rule they
cannot see is not a chokepoint. One helper, `boardMark`, turns the four states
into one character — `.` readable, `h` hidden by its author or a court mod, `g`
withheld, `x` purged — and three wire paths read it, because a client that
rendered "withdrawn by its author" over a statutory redaction would be stating
something false about a person.

`hidden` stays a separate field from `global`. They are different acts by
different authorities: clearing one must not clear the other, and a clear must
not re-index a row the other authority still hides.

- **Board writes refused on a purged court.** This makes the purged-court gate a
  four-entry list; the build guardrail names two and has already drifted to
  three, so restate it as a predicate rather than an enumeration.

### 7.7 Step 7 split — **the buildable half is BUILT** (2026-08-25, `boardmod.gno`)

Everything in §7.2–7.4 was specified tightly enough to build **except the
election window**, which carries two open questions. Rather than hold the whole
step, the build split, and the first half has shipped:

| verb | authority | note |
|---|---|---|
| `HideBoardRow` | `speechM`-of-n | discovery only; deep link serves. `HideItem`'s precedent |
| `SlashStanding` | `speechM`-of-n | ratchets by whole levels; never below 0, never touches `highWater` |
| `FreezeBoard(addr)` | `speechM`-of-n | board writes only, `< freezeMaxBlocks`; the allowlist is everything else |
| `FreezeClaimBoard` | `speechM`-of-n | auto-expiring, lazily |
| `RestoreStanding` | `requireMod` | raises toward `highWater`, never past |
| `UnfreezeBoard` | `requireMod` | de-escalation must survive suspension |
| `GlobalClearBoardBits(court)` | global DAO | the per-batch backstop `ClearAnyBit` cannot reach |
| `GlobalRestoreStanding(court, addr)` | global DAO | clamped to `highWater` |
| `ResetModSet` clears live freezes | existing verb | a reset to `n = 0` otherwise leaves everyone frozen with nobody able to unfreeze |
| `PurgeCourtLogRow` | global DAO at `d.purgeM` | its own verb: the court log's ids are a separate sequence |
| `PurgeBoardRange` | global DAO at `d.purgeM` | **BUILT** — 64 rows a batch, resumable, voted once |

All of these are lazy-expiry by construction, matching every other clock in the
realm. Suspension masks the four sanctions and leaves all six undos reachable;
the freeze clock is masked, never paused.

**Three things the build settled that the plan had not.**

1. **The sanction epoch.** `GlobalClearBoardBits` and `ResetModSet` clear every
   freeze in a court by incrementing one integer on `courtMod`; a freeze records
   the epoch it was set under and is live only while the two match. §7.5 refuses
   unbounded walks on a remedy path everywhere else, and "clear two hundred
   freezes" is exactly that walk. Slashes are not covered — a slash is a changed
   number, not a bit, so it takes the per-address restore.

2. **A slash to level 0 forfeits the entry pass**, and without it the whole
   sanction was defeatable for 0.1 CC. `postLevel` floors a pass-holder at
   level 1, so a zeroed address kept posting at entry rate forever and the only
   remaining sanction was the 12 h freeze — which with its 12 h gap is a 50 %
   duty cycle no court can close. The burn is never refunded; the entitlement is
   forfeit, which is the realm's own rule for a misused stake. A *partial* slash
   leaves the pass alone: silently destroying a purchase is a bigger act than
   the one the set voted for. **This reverses a documented property** —
   `passHeld` was described as never-cleared — so it is the one item here an
   owner may want to look at.

3. **The court-level log.** A board sanction is keyed to an ADDRESS, so it has no
   claim to hang off; `claimMod`'s log could not hold it. `courtMod` gained one,
   with its own sequence and its own purge verb, and `renderModLog` reads both
   through a single `modActLine`. The verb goes in the act's `code` and the voted
   category in its `reason`, matching the claim log — folding both into one
   string left `reason` permanently empty and made the purge verb's own
   "the reason leaves state" line dead code.

**Rulings still outstanding.**

**RULING NEEDED — 0b. Should an author be able to re-order a SETTLED board?**
(comment audit D4.) A settled claim takes no new comments, and as of D3 it takes
no new votes either — the reason being that a standing-weighted vote re-ranks a
record nobody can reply to. `HideOwnComment` has no such gate, so the order of a
settled board stays editable by its authors, indefinitely, after the verdict is
known. `TestASettledBoardsOrderIsStillEditableByItsAuthors` shows the vote
aborting and the hide landing on the same board in the same moment.

For the two MODERATOR hide verbs the absence is correct — an abusive comment on a
settled claim must stay moderatable. The question is only about the author's own.

- **Gate it on `boardOpen`**: the record's presentation freezes when the record
  does, and the two halves of "what is here stays" finally agree.
- **Leave it**: the row serves at its own link throughout, so this is curation of
  the listing rather than destruction of evidence, and someone who regrets a
  remark on a settled matter has a fair claim to take it off the front page.

I lean to gating it, on the D3 principle. Not built either way.

**RULING NEEDED — 0c. Should suspension actually MASK a set's hides?** (comment
audit D9.) §7.4 says "suspension masks hides and freezes". Nothing implements it:
no visibility predicate in the realm reads `cm.suspended` — `HiddenFromListing`
is `court || meta || global`, `boardMark` reads the row's own bits, and
`boardFrozen` reads the freeze stamp. Every reader of the flag is an authority
gate or a state transition. The court page claimed the masking and has been
corrected to describe what actually happens.

So the question is whether to build it:

- **Mask on suspension.** The remedy against a captured set becomes immediate:
  suspend them and their curation stops mattering the same block. This is what
  §7.4 assumed.
- **Leave it.** Unmasking republishes everything the set hid — including content
  hidden for cause — at the exact moment nobody is authorised to re-hide it, and
  a suspension is often about one act rather than all of them. The existing
  answer is already available and targeted: `ClearAnyBit` per claim,
  `GlobalClearBoardBits` for every board freeze in one write, `GlobalClearRow`
  per comment.

I lean to leaving it and deleting the §7.4 sentence, because the targeted verbs
already cover the case and mass-unhiding has no undo. Either way the doc and the
code should agree, and today they do not.

**RULING NEEDED — 0d. Should a claim-level legal act cascade to its board?**
(comment audit D10.) §7.6 settles the upward direction — a notice about one
comment must not force the whole claim to be redacted, which is why the row-level
verbs exist. The downward direction is unaddressed and unimplemented: `board.gno`
reads no claim-level legal state, so a claim redacted or purged under a notice
keeps a fully readable board, and the infringing text may be quoted there.

- **Cascade.** A `GlobalHide` or `PurgeClaim` reaches the board too, so answering
  a notice is one act. Fast, and over-redacts by design — the objection §7.6
  raises about the other direction applies here in reverse.
- **Leave it, and say so.** The row verbs and `PurgeBoardRange` already cover the
  board, and the operator is told the board is a second surface. **Built**: the
  board page now carries that notice, which is informational and holds under
  either ruling.

I lean to leaving it: cascading makes the fast lane the over-broad one, and the
72-hour runbook already has `PurgeBoardRange` for the whole-board case.

**RULING NEEDED — 0e. The ladder rewards splitting by up to 2x.** (comment audit
D11, measured.) §4 asks that concentrating standing be at least as good as
splitting it, which requires `rate(l)/tau(l)` non-decreasing in the rung. Shipped
it is strictly decreasing:

| rung | tau (bps) | rate/day | rate/tau | split into | posts/day | vs concentrated |
|---|---|---|---|---|---|---|
| 1 | 5 | 3 | 0.600 | 20 | 60 | **2.00x** |
| 2 | 25 | 10 | 0.400 | 4 | 40 | **1.33x** |
| 3 | 100 | 30 | 0.300 | 1 | 30 | 1.00x |

So twenty addresses at the entry rung out-post one address at the top rung, on
the same total standing, by a factor of two. §13 already said the condition as
written was unsatisfiable; this is the number.

Two ways to satisfy it, and both touch settled rulings:

- **Compress the thresholds.** Convexity needs `tau(3)/tau(1) <= rate(3)/rate(1)`,
  i.e. `t3 <= 50 bps` with `t1 = 5` and the frozen 10x rate ratio. That changes
  the ruled 5/25/100.
- **Widen the rate ratio.** `rate(3)/rate(1) >= 20` satisfies it at the current
  thresholds, which changes the ruled "tops out at 10x entry".

A third option is to accept it and say so: the splitter still pays a pass per
address, so the 2x costs 20 passes, and the per-claim caps (8 per author) mean
extra throughput only helps ACROSS claims. That may be the honest answer, but §4's
convexity paragraph should then be deleted rather than left as a requirement the
code does not meet.

`TestWhatThroughputCosts` pins the current factor and fails if the ladder ever
becomes convex, so whichever way this goes the test says so.

**RULING NEEDED — 0. Should the per-author cap count REPLIES?** (raised by the
comment audit, `docs/COMMENT_AUDIT.md` D1.) `maxBoardRowsPerAuthor` counts every
row an address wrote on a claim, replies included. Its stated rationale is page
composition — *"a top-rung poster has no more right to fill a single page than an
entry-rung one"* — and a reply fills no page slot, it renders under its parent.

The cost lands on exactly the wrong participant. The claim's author is the most
replied-to address on their own claim, and §5 gives them a reserved slot so they
can answer and be seen. `TestTheAuthorIsSilencedByAnsweringQuestions` shows the
slot going empty: one top-level comment, seven questions answered, and the author
can no longer post anything — while each questioner has spent one row of eight.

Three ways out, and they are not equivalent:

- **count only top-level rows toward the cap**, and bound replies by the daily
  throttle alone. Cleanest against the stated rationale; raises the worst-case
  rows per author per claim from 8 to the throttle's limit.
- **a separate, larger reply budget** — keeps a bound on both, adds a constant.
- **leave it**, and accept that answering is rationed at the same rate as
  originating. Free, and the current behaviour.

The first looks right to me on the design's own terms. Nothing is built either
way; the test pins today's behaviour so the choice is visible.

**RULING NEEDED — 1. Who does the election-window refusal cover?** §7.3 says
"parties of the contest" and round-4 found that undefined between two readings
that break in opposite directions:

- *actor-scoped* (a moderator standing for re-election cannot sanction): a
  moderator not on the ballot sanctions freely through the window, so a set of
  three where one abstains from the election keeps full powers.
- *target-scoped* (a candidate cannot be sanctioned): anyone who registers as a
  candidate buys immunity for the window, and the bond floors near 1 CC.

**RULING NEEDED — 2. Should a live slash or freeze lapse at all?** §7.3 lapses
both at `OpenElection`, and that is a **permissionless self-release**: registering
a candidate set containing yourself costs ~0.4 CC net and clears your own
sanction. Three ways out, and they are not equivalent:

- lapse only when the election **concludes** with the set replaced — the sanction
  survives a contest its author wins;
- lapse on `OpenElection` but refuse it to the address that opened it — cheap, and
  a sybil opens it for you;
- do not lapse; rely on the incoming set's `RestoreStanding`/`UnfreezeBoard`,
  which is `requireMod` and therefore reachable by a set that has just won.

The third is the smallest mechanism and needs no new clock. It is not the default
because it makes the remedy require an act by the new set rather than happening
by rule, and §7.3 chose the rule deliberately.

Until 1 and 2 are answered, the verbs above ship **without** any
election-window refusal or lapse. That is the honest partial: a court can police
its board, and the election-time carve-out arrives with the ruling. Nothing built
so far forecloses either reading — no board act writes `setActHeight`,
`lastElectionAt`, `electionCooldownUntil` or any other election field, which is
the allowlist §7.4 demands.

### 7.8 The simplification pass (2026-08-25): what went, what stayed, what was wrong to propose

Three reviewers went over the lane looking for complexity. Their verdicts did not
agree, and the disagreements were the useful part.

**Deleted, because nothing read them.**

- `boardRow.atTime` — a second clock in unix seconds beside `at`. Height is what
  every other record in this realm cites by, so it was a duplicate with no
  consumer.
- `boardRow.legalCode` — written by all three legal verbs, read by nothing.
  `boardActCode` already writes the category into the moderation log, and that
  copy is the durable one: `PurgeModLogRow` destroys reasons, not codes. A second
  home for a fact that already has a durable one is a divergence risk with no
  reader.

**Kept and put to work rather than deleted.** `boardRow.at` was on the same
write-only list. But a deep link is a citation handle and a citation without a
date is half a citation on a claim whose market moves under it, so the fix was to
render it, not to drop it.

**Kept and made honest.** The four earning categories were proposed for deletion
on the grounds that one write and one read produce only a display string. That
display string is the owner's stated ask — *"a page where i can learn about how to
earn reputation and see my score"* — so the categories stay. What went is the
`StandingBreakdown` wire format being printed verbatim onto a human page: it now
names the categories in words and lists only the ones an address actually earned
in, because "flag: 0, dispute: 0, author: 0, conviction: 0" tells a new
participant four things that are not true of them. The packed read is untouched;
it is the qeval surface a client parses.

**Proposed and WRONG: deleting `boardPartyRows` and the reserved slot.** The
argument was that `boardBadges` already labels a party wherever they appear, so
the section is duplication. It is not: the slot exists for the case where the
author commented FIRST and volume arrived after, which is exactly what buries
them on both orderings. An intermediate version of the render fix moved the block
to the ranked page only, on the same mistaken reasoning that recency surfaces a
party on Newest, and the existing test caught it. The block renders on both
orderings, deduped.

**Proposed and REVERSED: deleting `FreezeClaimBoard`.** The case against it was
that it has no re-freeze gap — so a set could hold one claim's board frozen at a
100 % duty cycle — that its state was rendered nowhere, and that the row caps
already bound a flood. Two of those three were defects rather than arguments: the
freeze is now rendered, and it now carries the same `boardFrozenGapUntil` stamp
an address freeze does, cleared by neither the undo nor the sanction epoch and
stamped at the full ceiling. The verb reaches a coordinated pile-on of
individually unpurgeable comments on one claim, which `HideItem` does not — a
hidden claim still accepts comments.

**The six trees: two of the three proposed changes taken, the third declined.**

*Taken.* The indexes now hold the **row itself** rather than `true`. Every reader
used to do a second descent into `board` to fetch what the index had just walked
past — six redundant descents on a page render — and a pointer is the same width
as the bool it replaced, so the second lookup bought nothing.

*Taken.* `boardKids`, `boardScore` and `boardVoted` are **allocated when first
written**, not with the other three. A claim with one top-level comment, no
replies and no upvotes — most of them — used to carry three permanently empty
trees forever. The standing argument against lazy allocation in this realm is
that it gives readers a second branch which must agree with the write path; here
every reader already nil-checks, because these were nil until the first comment
regardless. The branch existed either way; only the allocation moved.

*Declined: merging them into one tagged keyspace.* It would save three bptree
objects per claim-with-comments and nothing else, now that the descents are gone
and the empty trees are not allocated. Against that, `boardKeyMine` stops being
redundant and becomes load-bearing the moment the keyspaces are shared — `be(N)`
is a prefix of row N's own key — and the failure it guards against is a prefix
scan silently returning a row it does not own, which is the shape `pruneVoteLocks`
already produced once in this realm by reading an unparseable prefix match as
permission to *delete*. The remaining prize is not worth introducing that class
of bug on a write-once realm. Recorded rather than done, so a later reader knows
it was weighed and not overlooked.

## 8. The standing page

`/<slug>/me/<addr>`, carved before the numeric claim-id parse as `mod` is; handle
`/<slug>/me` too. Standing, level, what the level allows, `highWater`, pass held,
the four category subtotals, the earning rules as static text, the answer record
labelled *adjudicated — moderators cannot change this*, freeze state, slashes by
code.

Slashes render **from the act-log rows**, so a purge reaches the page. Both go in
the §2 user-text inventory, and the mod-copy rule extends to the page's own
static copy. Note this is an address-keyed aggregation, which `MODERATION.md`
declined to build for claims — the departure needs stating with its reason.

Read path allocates nothing, and both exported reads go in `z_read_filetest.gno`,
which is budgeted to write nothing.

## 9. Parameters

| parameter | shape | guard |
|---|---|---|
| `passPriceMinCC`, `passPriceBps` | floor + fraction of `PastTotal(epoch−1)`, **lidded** | never above the turnout bar |
| level thresholds and rates | short ladder, **top = 10× entry** | convex: `rate(ℓ)/τ(ℓ) ≥ rate(1)/τ(1)` |
| `rankColdStartN` | addresses holding standing before ranking engages | newest-first below it |
| per-claim per-address row cap | small, flat | page composition |
| slash step | whole levels | uniform across court sizes |
| `freezeMaxBlocks` | **< nomination window (1 day)** | plus a minimum gap between freezes |
| `maxBatchRows` | 64 | must fit one tx |
| row body cap | ~2 KB | render + legal surface |

Frozen constants, no runtime knob. Each needs a mutation-corpus row labelled by
the defect it catches — the four standing bps constants still have none.

## 10. Invariants

- **S1** no money path reads board, standing, level, pass, vote or freeze state.
  **Now guarded** — `check-epoch-coherence` arm 17 derives the money lane from
  every file that calls `coin.Transfer/Mint/Burn` and refuses a read of board or
  standing state from any of them, while counting the four permitted credit-hook
  WRITES. The coupling is one-way by census rather than by inspection
- **S2** no moderation path reads or writes `answerRecord`
- **S3** the only coin movement is `Burn(poster, passPrice)` in `BuyCommentPass`,
  guarded by an adjacent `mustSpendable`
- **S4** no moderator, DAO or verdict path moves a coin in this lane
- **S5** a claim settles identically to the same claim with the same board and no
  bits set *(not "with a flooded board" — the flood's burns move four
  supply-derived bars)*
- **S6** every row is purge-reachable; purge zeroes its bytes; byte-zeroing is
  resumable and eventually total
- **S7** every batch act is bounded and resumable
- **S8** standing is monotone except by logged slash; `score ≤ highWater`;
  `highWater` rises only from §2.2
- **S9** ~~for any partition of a holder's standing and CC across addresses,
  neither total posts/day nor total upvote weight increases~~ **FALSE FOR
  THROUGHPUT, MEASURED** (audit D11). Upvote weight holds — it is linear in score,
  so a partition sums to the same total. Throughput does not: the ladder is
  strictly anti-convex, and twenty addresses at the entry rung out-post one at the
  top rung by **2.00x** on the same standing. See ruling 0e; the invariant cannot
  be restored without changing either the ruled thresholds or the ruled 10x rate
  ratio. `TestWhatThroughputCosts` pins the current factor
- **S10** every sanction is reversible by a successor set **and** by the global
  DAO
- **S11** ~~suspension masks hides and freezes~~ **FALSE, UNIMPLEMENTED** (audit
  D9). No visibility predicate in the realm reads `cm.suspended`:
  `HiddenFromListing` is `court || meta || global`, `boardMark` reads the row's
  own bits, `boardFrozen` reads the freeze stamp. A suspended set's sanctions all
  stand. See ruling 0c. The second and third clauses ARE true and hold: the freeze
  clock is never paused, and `RestoreStanding`/unfreeze take `requireMod` so a
  suspended set can still de-escalate
- **S12** a board act writes board state and the act log, **nothing else**
  (allowlist)
- **S13** `speechM = min(n, max(2, m))`, computed at the act site. Capped by `n`
  by construction, so it is satisfiable at every configuration — there is no
  `n < 2` refusal, and there must not be one: it would leave a solo court unable
  to police a board it can already hide wholesale via `HideItem`
- **S14** election-window refusals and lapses cover hides, slashes and freezes

## 11. Build order

1. ~~Standing ledger + credit hooks~~ **BUILT**. Owed: the two earning-base
   corrections (`xBarFrozen` → the author's own time-averaged stake; `convCC` →
   time-averaged stake).
2. ~~Pass, levels, rate, and the standing page~~ **BUILT**.
3. ~~Comments: per-claim tree, depth 1, flat index, immutable rows, per-row
   route, sanitize arm, row cap~~ **BUILT**.
4. ~~Ranking: upvotes, the score index, cold-start fallback, reserved slots~~
   **BUILT**.
5. ~~Legal lane and the closed code set~~ **BUILT** (§7.6). 26 mutation rows, all
   caught; five of them were gaps the probe pass closed.
6. ~~Per-court act log~~ **BUILT — by reuse, not by a second log.** `claimMod`
   already carries an append-only log with stable row ids, a purge verb
   (`PurgeModLogRow`) and a court-wide render, so the three legal verbs write
   into that rather than standing up a parallel one. The comment id rides in the
   act CODE, not the reason, because `PurgeModLogRow` destroys reasons and a log
   that says a comment was redacted without saying which is not a record.
7. **Slash, freeze, `RestoreStanding`, `speechM`, suspension masking, the two
   global verbs** — **BUILT** (§7.7), 44 mutation rows caught and 1 recorded as
   unreachable-by-proof. Still owed, and each for its own reason:
   - **election windows** — blocked on the two rulings in §7.7;
   - **the deploy precondition `d.n ≥ 3 && d.purgeM ≥ 2`** — cannot be checked at
     deploy, since the DAO is created lazily 1-of-1 from the deployer; it is an
     operational step, not a code one, and belongs in the runbook;
   - **the meta court's own board** — its 1-of-1 set is where appeals against the
     deployer would be argued, so its sanctions must bind to the global DAO
     rather than to that set. Needs a design pass of its own.

## 12. Bugs review found in shipped code (fixed)

- The dispute credit paid **whoever opened the most recent round**, not the
  winner — a stranger could open a losing round and take it. Fixed with
  `cs.overturnBy`.
- The fix was **incomplete**: a *winning* second overturn re-stamped the field at
  zero cost, since the answer bond is already gone by then. Now stamped only
  inside the forfeiture.
- The `default:` branch **lowered a saturated score** — `satAdd` is not
  invertible. Now the category is validated before anything is allocated.
- The flag credit was paid **at reservation**, on a branch where the bond returns
  whole, survived repudiation, and had a base inflatable ×4 by free inconclusive
  cycles. Moved to `settleSlash`, scaled on what actually burned.
- The conviction credit had **no quality gate**, so a claim rated LOW paid
  standing in full at 4.5–22.7× the mill's total burn.
- The first gate for it was then **wrong in both arms**. It refused `provClose`
  on the stated grounds that there is "no draw and no verdict" — `crystallize.gno`
  says the opposite in as many words, *"provClose now DRAWS"* — so it withheld a
  credit on a path that pays MID emission. And it admitted `tier == MID`, which
  is the **default an unadjudicated claim receives**, i.e. exactly the mill's
  habitat. Now rated on `slotConsumed` (set only where a quality tally
  concluded), with `provClose` needing no arm of its own.
- Also: `scaleBps`'s non-panic guarantee depended on `bps ≤ 10_000` with two
  constants on the boundary (clamped); the dispute credit paid both sides on the
  answerer's bond, 2.5× what a disputer risks (split by side); `getStanding` and
  the pre-existing `getRecord` were missing from the allocator census.
- **A slash was defeatable for 0.1 CC.** `passHeld` floors the posting level at
  1 and was documented as never-cleared, so an address slashed to zero standing
  kept posting at entry rate forever — leaving only the 12 h freeze, which with
  its 12 h gap is a 50 % duty cycle. A slash to level 0 now forfeits the pass;
  a partial slash does not (§7.7).
- **The court-level log's purge verb had a dead line.** Every sanction folded its
  category into the act `code` and passed `""` as the reason, so
  `PurgeCourtLogRow`'s `reason = ""` destroyed nothing. Split, matching the claim
  log's shape. Found because the mutant survived — and then survived *again*
  behind a test that read the RENDER, which hides a purged row's reason on the
  `purged` bit alone. Only a read of state distinguishes the two.
- **Two moderator-perimeter tests asserted the reverse of their names.**
  `directoryAdmin` is the first court creator in the package, so a test that ran
  before any other made its own moderator the bootstrap global-DAO member, and
  every "a court moderator is not enough" arm passed by being *allowed*. Both
  were invisible with neighbours and caught by `check-isolation`. Fixed in the
  fixture rather than per test: it establishes the admin on a throwaway court and
  refuses to run if a subject of the test is it.
- **`courtIsPurged`'s guardrail was an enumeration that had already drifted.**
  The comment named two readers; there were five. Restated as a predicate — read
  it on a path that BEGINS a commitment, never on one that settles or releases
  one — and given a census (`check-epoch-coherence` arm 16) that pins the count
  and the enclosing function of every reader.
- **The board was half-wired to the site, and none of it was a design choice.**
  `renderClaim` carried **no link to `/board` at all** — the route existed and the
  only way to reach it was to type the URL. `BoardReplies` had **no caller on any
  render path**, so the second level of the tree was write-only in gnoweb: the
  page printed `_1 reply._` and stopped, and the count was not even a link.
  `BoardFrozenUntil` and `ClaimBoardFrozenUntil` had **no callers at all**, so
  both freezes were silent walls that announced themselves only as a panic on
  somebody's write. `SpeechThreshold` had no caller either, and the mod page
  printed `m of n` — which is the wrong rule for every court where `speechM`
  differs, i.e. every 1-of-n set. All four are now rendered, each pinned by a
  row that fails with the call deleted.
- **The board page rendered each comment two or three times.** Parties, then Top,
  then Newest, with no dedup — and because cold start puts every un-upvoted row
  in the score index at score 0, on any board with no upvotes Top and Newest were
  byte-identical lists printed back to back. Now one list per page, `Top` its own
  route at `/board/top`, the two linking to each other, and a `seen` set so a
  reserved slot is a slot rather than a second copy. The parties block stays on
  **both** orderings: an earlier version of this fix moved it to the ranked page
  only, reasoning that recency surfaces a party on Newest — which is false the
  moment the party commented first and volume arrived after, and that is the
  burial case the slot exists for.
- **The standing page sold a pass to someone it would not help.** A slashed and
  frozen address read "you cannot comment here **yet** — buy an entry pass",
  which invited a purchase that could not work while the freeze held, never
  mentioned the freeze, and never said the pass they already held had been
  forfeited by the slash. The only trace of what had happened to them was a bare
  integer on the high-water line. Now: the freeze is named with its deadline and
  its allowlist, the slash is named with its remedy, and the purchase is offered
  only when it would actually do something. Both facts render — suppressing the
  slash line while a freeze is live means a thawed user discovers their standing
  is gone with nothing having said so.
- **An author could reverse a moderator's `speechM`-of-n hide with one call.**
  `HideBoardRow` and `HideOwnComment` wrote the same `r.hidden` field, so the
  sanctioned author called their own verb with `hide=false` and the row
  re-entered the ranked index. Symmetrically, `UnhideBoardRow` exposed rows their
  authors had withdrawn. Neither direction had a test. Split into
  `hiddenByAuthor` / `hiddenByMod`, read as a disjunction by `boardMark` — the
  argument this file already made for `hidden` vs `global`, applied one step
  further than it had been. The listing notice now says WHICH authority acted;
  "withdrawn by its author" over a moderator removal is an assertion about a
  person MODERATION §6 forbids.
- **`freezeGapBlocks` did not bind against the set it aims at.** `UnfreezeBoard`
  zeroes `frozenUntil`, which the gap test read — so freeze → unfreeze → freeze
  slipped the gap for one extra `speechM` round, indefinitely, defeating the 12 h
  ceiling entirely. The gap test also required a matching sanction epoch, so
  `GlobalClearBoardBits` — a *recovery* verb — handed the set an immediate
  re-freeze. Now a separate `frozenGapUntil` stamp that neither the undo nor the
  epoch clears, stamped at the full ceiling rather than the length asked for, so
  a set cannot buy the gap off one block at a time.
- **A comment could forge a wire row.** `PostComment` did `TrimSpace` plus a
  length check; every wire read packs rows as `…|…|text\n` with text last. So a
  comment of `x\n999|g1attacker|0|.|forged` closed its own row and opened another
  with an attacker-chosen id and author, in `BoardNewest`, `BoardTop` and
  `BoardReplies` alike. Escaped at `boardTextFor` — the single wire gate — rather
  than refused at input, because comments are multi-line **by design** (that is
  why the display gate uses `sanitize.Block` and not `InlineText`). Backslash is
  escaped first, or the escape is itself forgeable.
- **A brand-new court's board panicked on an internal message, and every unit
  test was structurally blind to it.** Every board threshold is quoted against
  `PastTotal(Epoch()-1)`, and grc20votes' `mustBeSealed` panics on `at == 0` — so
  a court whose coin has not reached epoch 2 aborted with *"grc20votes: that
  epoch has not been sealed yet"* on `PostComment`, and `PassPrice`, `PostLevel`
  and the whole `/me` page — all **reads** — panicked outright. The realm already
  lives with the same expression on the dispute and election paths, but those are
  unreachable until a claim has been answered and disputed, by which time epochs
  have rolled; the board is reachable in the first block.
  **No unit test could see it**: `postingFixture` skips two epochs, and says so
  in its own comment. `z_read_filetest` found it on the first run after the board
  reads were added there — which is precisely the defect class that file was
  written for. Now one `boardSupply(c) (int64, bool)` is the single sealed read;
  the reads answer 0, the writes refuse naming the real reason rather than
  advising a purchase the court cannot sell, and the board opens by itself when
  an epoch seals.
- **Two render copies of one log line.** The court log's rows duplicated the
  claim log's four formatting lines, which immediately made two existing
  mutation-corpus anchors ambiguous. Collapsed into `modActLine`; the corpus
  caught the duplication before a divergence could.

## 13. Round-4 review findings still open

Three diverse passes over v1.1. The two-orderings ruling (§5) closes the ranking
cluster — the constitutional conflict with §3.2, the unstated §5.3 gap, the
subject-can-never-reach-page-one problem, and the O(1) page-one capture. What
follows is the remainder, unfolded.

**Economics.** Standing's CC value `V` is the design's one unpriced parameter,
and four named invariants break at `V` between 0.05 and 0.94 — the dispute lane's
bound is exactly 0.5 at every court size, because comp already consumes 80% of
the burn. **Two of the four rows mint against zero burn** (author-HIGH and
winning conviction refund everything), so burn-domination there does not weaken,
it does not exist. Matched-farming break-even on the standing leg alone is
`V > 0.10`, independent of emission. And the owed conviction re-base multiplies
that row by up to 78× — it must not ship in the same release as the ranking
without `standingConvictionBps` falling by the same factor.

**The ladder.** The convexity condition in §4 is evaluated at the wrong point;
corrected, it demands `τ(2) ≤ τ(1)` and is unsatisfiable by any multi-rung
ladder. Worse, the pass makes it moot — `level = max(fromStanding, 1)` means a
splitter allocates no standing at all to sybils and buys `n × rate(1)` directly.
S9's "for any partition of standing **and CC**" is false by construction. Restate
the honest priced bound instead: `passPrice / rate(1)` CC per post/day.

**Moderation.** `speechM` is weaker than `HideItem` — a 1-of-1 creator set can
still remove the whole claim, and its board with it, at `cm.m`. *(The companion
claim, that an `n < 2` refusal leaves the modal court unable to police its board,
was **withdrawn at v1.2**: it applied to the `max(2, ceil(m/2))` formula this
review was reviewing, not to the `min(n, …)` one the plan adopted in response.
See §7.1.)* The
election-window lapse is a permissionless self-release (register a candidate set
containing yourself for ~0.4 CC net and your slash lapses). "Parties of the
contest" is undefined between actor- and target-scoped and breaks both ways.
Eager lapse at `OpenElection` puts an unbounded walk on the remedy path — it must
be lazy, like every other expiry here. *(The principle is now built even though
the lapse is not: `boardSanctionEpoch` clears every freeze in a court in ONE
write, and every freeze expiry is lazy. Whatever the ruling in §7.7 decides,
there is no longer a walk available to put on that path.)* ~~The closed `mustBoardCode` contradicts I11's *shape-extensible* requirement for
the legal codes; split editorial (closed) from legal (extensible).~~ **CLOSED at
§7.6**: the split is the shipped shape — `mustBoardCode` is a closed switch and
governs only the acts that name a person, while the legal verbs keep
`checkReason`/`mustCategoryCode` and stay extensible. ~~Global recovery is per-address against per-batch harm.~~ **HALF CLOSED**: the
BIT half is now O(1) court-wide — `GlobalClearBoardBits` clears every freeze by
incrementing one integer, `GlobalClearCourtParams` drops both parameter
overrides, and `PurgeBoardRange` answers a whole board 64 rows at a time. The
SCORE half is still per-address: a slash is a changed number, not a bit, so
`GlobalRestoreStanding` remains one call per victim. A set that slashed two
hundred addresses still costs two hundred transactions to undo. Fixable with the
same epoch trick if a `slashEpoch` were carried on the row and every read of
`score` routed through a resolver — recorded, not built, because that touches
every score read in the lane for a harm nobody has yet suffered.
`d.purgeM` is admin-settable to 1. The "deploy precondition" cannot be checked at
deploy — the DAO is created lazily, 1-of-1, from the deployer.

**Seeding.** I5 zeroes the seeded *author*; the seeded claim's answerer and
winning stakers are untouched, and the deposit and fee are waived. A creator-
appointed set can seed, self-answer, self-stake and harvest.

**The freeze allowlist** blocks the reply channel and permits the abuse channel:
a frozen address may still `OpenClaimP`, which takes a free-text body and lands
on the pending list, while the person it names cannot reply on the board.

> **STILL OPEN, AND NOW CONFIRMED AGAINST SHIPPED CODE.** `mustBoardWritable` is
> read by `PostComment` and `UpvoteComment` and by nothing else — that is the
> allowlist, delivered by omission and pinned by check-epoch-coherence arm 16.
> `OpenClaimP` is an ENTRY verb and reads only `courtIsPurged`. So the asymmetry
> is real and deliberate-by-accident: the freeze reaches the 2,000-character
> surface a person uses to answer, and not the free-text surface they can be
> attacked from.
>
> **OWNER RULING NEEDED**, because both repairs change what a freeze IS:
> - extend the freeze to the claim BODY — but a claim is how you participate in
>   the market, and §7.2's allowlist exists precisely so a set cannot silence the
>   election that removes it. A body-freeze is one step from a claim-freeze.
> - leave the freeze alone and treat an abusive claim body as what it already is
>   — a claim, reachable by `HideItem` at `cm.m` and by the global redaction
>   verbs. This is the status quo and costs nothing to keep.
>
> The second looks right to me and I have not built either. Recorded here rather
> than folded in.

~~**The standing page** publishes a per-person punishment dossier — address-keyed,
in the realm's own voice, which §6's mod-copy rule forbids for moderator speech.~~
**CLOSED at build step 2**: `renderStanding` publishes capability facts — score,
level, what the level allows, `highWater`, pass held, the four category subtotals
— and no slash history. The act log carries the sanctions, in the moderator's
voice rather than the realm's, which is what §6 asks for.

**The meta court has a board**, its own 1-of-1 set, and is where appeals against
the deployer would be argued. Binding its sanctions to the global DAO makes that
DAO an editorial moderator, which §3.2 forbids.

**I2, I5, I9, I10 and I11 are false against this plan** and need amendment text,
which no revision has yet written.

## 14. Residuals, published

- **Ranking makes standing allocate something scarce**, which is the premise
  no-decay rested on. Veterans permanently outrank newcomers. Owner call.
- **Standing is a yield on staking that no deploy gate prices.** Principal returns
  1× and recycles through fresh addresses, so a unit of stake earns permanent
  entitlement every cycle. The 10× ladder bounds its throughput value; its
  *ranking* value is not bounded by anything yet, and that is the open question
  §5 creates.
- **Throughput and rank are address-keyed and priced, not immune.**
- **Freeze is sybil-defeated**; a slashed abuser can abandon the address.
- **Recovery is court-wide for an individual harm.**
- **Voting locks the coin you would spend on a pass**, so an elector cannot buy in
  during the 7-day window — exactly when a campaign needs speech.
- **Purge does not reach quotations**, and a purged row's hash survives in its
  event forever.
- **`maxBallotLines = 64` is a scarce excludable slot** — 64 sybil nominations
  shut a challenger off a ballot for ~15 days.
- **The board is an on-chain bribery channel**, and now upvotes have value, so
  there is something to buy. Standing cannot be transferred, so only the act can
  be rented, not the weight.
- **A court whose capital sits on one side will have a one-sided board.**
- **This text has had no adversarial pass.** v0.7, v0.9 and v1.0 each had three.

## 15. Parameterization: which knobs, whose, and where they live

Owner proposal (2026-08-24): make these realm-global defaults, settable by meta,
with courts inheriting unless they override. Two findings, one of which settles
the storage question outright.

### 15.1 `chain/params` has no reader yet — the PR is open, not merged

`gnovm/stdlibs/chain/params/params.gno` on **master today** exposes only
`SetString`, `SetBool`, `SetInt64`, `SetUint64`, `SetBytes`, `SetStrings` and
`UpdateParamStrings`. Values land under a `vm:<realm>:` prefix in the Params
Keeper, which the node and off-chain readers can see; Gno code cannot read them
back.

That is a missing **binding**, not a missing capability, and the distinction
matters. `tm2/pkg/sdk/params/keeper.go` already implements `GetString`,
`GetInt64`, `GetUint64`, `GetBool` and `GetBytes` on the keeper interface — the
storage layer reads fine, nobody wired the read side through to the VM.
**gnolang/gno PR #5698, "feat(gnovm): add chain params reader API"**, does
exactly that (typed `Get*` plus native gas entries). Opened 2026-05-21, last
touched 2026-05-27, **open and unmerged**, out of an IBC need
(`onbloc/gno-ibc#43`). Companion #5699 adds raw byte-key access.

So the recommendation stands but on weaker grounds than "impossible":

- **Today** it cannot back a value the realm reads, and building on an unmerged
  three-month-old PR would make this realm undeployable until it lands.
- **If it merges**, migration is mechanical — the values sit behind
  `assocBondFor`-shaped accessors either way, so the backing store is one
  function per parameter.
- **Even then, cost is unproven.** The new getters carry native gas entries and
  these values are read on every credit and every render; a bptree row in realm
  state is plausibly cheaper than a keeper lookup at that frequency. The argument
  for moving would be governance reach, not price, and the price claim should be
  measured rather than assumed in either direction.

Related: `r/sys/params` is a different thing again — it builds GovDAO *proposals*
to set gno.land system parameters. Nothing to do with realm-local config.

**Conclusion: these live in realm state, as `assocBond` already does.**

### 15.2 The test for which tier a parameter belongs in

`COURTS_TOKENOMICS.md` §9a already settled this, and the proposal matches its
shape. Its test, verbatim: *could a founder who set this maliciously harm someone
who did not read the charter? If yes, it is bounded by the realm or made a
constant; if a bad setting only makes the founder's own court unattractive
(self-punishing), it stays a court-governed knob with its terms on display.*

`association.gno`'s `assocBond` is the live template: a realm default the global
DAO admin sets so a new court is never unpriced, and a per-court override,
with `0` meaning *unset* rather than *free*.

### 15.3 Applying it

| parameter | tier | why |
|---|---|---|
| the four earning rates + `standingUnadjudicatedBps` — **BUILT** as `creditRates` | **realm default + court override, bounded by the ORDERING not by absolute values** | standing is per-court, so a bad setting is self-contained — a court that zeroes them makes its own board unusable and harms nobody else. The bound that matters is the relation `policing ≥ authorship > staking`, which `standing.gno` calls the part that must not move; enforce that as a runtime check on any override, not a range on each number |
| `standingUnadjudicatedBps` | same | must stay strictly between 0 and par, or the `slotConsumed` distinction is either decorative or confiscatory |
| `passPrice` floor and bps | **realm ceiling, court may lower** | this one *does* harm a stranger: at the wrong setting the speech door costs more than winning an election, on the surface where a campaign to unseat a captured set happens. Exactly §9a's "a minimum has a ceiling" |
| level thresholds | **court override** | absolute values are self-punishing to get wrong |
| the 10× top-to-entry ratio | **realm constant** | it is the number that bounds both the splitter's gain and what farming standing is worth; a court that raises it re-opens both, and the harm lands on readers of that court's board |
| row body cap, per-claim row cap | **realm ceiling, court may lower** | render budget and legal surface are platform-wide, not court-local |
| `freezeMaxBlocks` | **realm ceiling, court may lower**, and the ceiling stays below the nomination window | an unbounded freeze is a censorship tool, and the bound is what keeps it from spanning the election that is the only remedy |

### 15.4 What must NOT move, and why the question has already been answered

The emission and conduct constants — `budgetWeeklyBps`, `stepDownPeriods`, the
80/8/5/7 split, the tier multipliers, `answerBondBps`, `disputeBondXBps`,
`slashXBps`, `compOfBurnBps`, `quorumSupplyBps` — stay frozen. `PLAN.md` §0 is
explicit: *"no mechanism may depend on a tunable-at-runtime knob (frozen
constants killed a whole class of capture and overflow attacks in the V1 audit;
V2 keeps that discipline)"*, and `court.gno` says the absence of a retune path is
load-bearing for **every overflow and capture bound in the audit**.

The speech-layer parameters are a different case precisely because they are new:
no audit bound rests on them, no arithmetic overflow depends on them, and
standing is not money. That is the argument for parameterizing these and not
those — not that runtime knobs are fine now.

### 15.5 Who sets the default — not meta, on current evidence

The proposal says meta. `meta.gno` has a fixed verb table and a `target uint64`,
so a parameter-setting verb means changing the parse struct, the per-target latch
key space and `verbIsAggressive` — in the module that has already had its
three-way vet, to gain something the existing pattern already provides.

`SetAssociationBondDefault` is that pattern: global DAO admin sets the realm
default, an active court moderator overrides per court. It is one function, it is
audited, and it is already in the tree. Recommend reusing it and leaving
`meta.gno` alone.

### 15.6 Built (2026-08-24)

`creditRates` — a five-tuple, a realm default the global DAO admin sets, a
per-court override an active moderator sets, and `ClearCourtCreditRates` to
return to the default. `nil` means inherit; **not** all-zero, which for a
five-tuple is a court that deliberately zeroed its own board.

Two things worth recording:

- **Set as a tuple, never one at a time.** The bound is the ordering, so five
  independent setters would leave a window between two calls where the ordering
  is violated and credits are being paid through it. One setter, one check, no
  window.
- **Named `creditRates`, not `standingRates`, because the guard said so.**
  `check-nontransferable.py` refused `Set…Standing…(cur realm` — its census
  exists precisely so that "an entrypoint called AssignRecord,
  MigrateCredential, SetStanding, Bequeath or MoveScore" cannot sail through.
  These set what a credit is *worth*, never anyone's score, and a name that reads
  like the second is a name to change rather than a guard to exempt.

The range check refuses rather than clamps: `scaleBps` clamps at 10,000 too, but
silently, so a court setting 12,000 would get 10,000 with no sign its intent had
been discarded.

**Correction (2026-08-25).** This section previously claimed "four new corpus
rows, each verified CAUGHT". That was false against the shipped corpus:
`standing.gno` and `posting.gno` had **zero** rows between them. The rows were
probed and seen caught, and then never persisted into
`scripts/mutations-kourtv2.json` — so nothing stopped a regression in the
earning ledger, the pass, the levels or the throttle, and the doc asserted a
guarantee that did not exist. The lesson is the session's recurring one: a probe
that is not written to the corpus is a thing you once knew, not a thing the repo
knows. Both files now carry rows.

**And the authority was wrong, which the corpus gap is why nobody noticed.**
`SetCourtLadder` and `SetCourtCreditRates` shipped as `requireActiveMod` alone —
membership, not suspended, and nothing else. So **any single member of any set**
could call `SetCourtLadder(slug, 9998, 9999, 10000, 1, 2)`, which `mustLadder`
accepts, and put every address below 99.98 % of supply at level 0: a permanent,
court-wide, unlogged speech throttle with no recovery path, twenty lines from a
`FreezeBoard` that silences one address for twelve hours behind m-of-n, a
ceiling, a gap, a log row, an event and an O(1) backstop. `SetCourtCreditRates(slug, 2, 2, 2, 1, 1)`
passes its ordering check and cuts every earning rate ~5000×, so nobody ever
climbs off level 0 again. Neither `Clear` verb helped: both were
`requireActiveMod` too, so a *suspended* set could not undo its own act, and no
global verb reached either.

Fixed, keeping the per-court override itself — that is the owner's §15 ruling, and
what was missing was the authority, not the lever:

- both setters now take **`speechM`-of-n**, with the **tuple values in the action
  key** so two members approving different tuples cannot combine into one act;
- both write a **court-log row naming what was set**, and emit;
- both `Clear` verbs move to **`requireMod`**, so returning to the realm default
  survives a suspension, and refuse when there is nothing to clear;
- new **`GlobalClearCourtParams`** drops both overrides — the S10 backstop these
  two powers never had.

Still owed here: the realm **ceilings** for `passPrice`, the row caps and
`freezeMaxBlocks` — those attach to parameters whose surfaces are not built yet.

## 16. What a unit of standing is worth, and the one relation that pins it

Review's sharpest open finding was that standing has an implied CC price `V`
which appears in no deploy gate, while every inequality in `ECONOMICS.md`
silently assumes it is zero. It is computable, and it turns out to pin a
relation between two numbers this plan was about to choose independently.

**The upper bound on `V`, from substitutability.** `t3` standing buys 10× the
entry posting rate; ten addresses each holding a pass buy the same 10×. So `t3`
standing is worth at most ten passes — less in practice, because ten addresses
carry ten storage deposits and split their standing:

    V ≤ 10 × passPrice / t3

**What `V` must satisfy, from two directions.**

*A19, burn domination.* Total value out of an event may not exceed what the event
destroyed, or policing is a faucet. Per row, with `B` the burns and `A` the
answer bond:

| row | out | bound |
|---|---|---|
| flag | `0.8·B + V·(1.0·B) ≤ B` | **V ≤ 0.20** |
| dispute (overturn) | `0.8·A + V·(0.4·A) ≤ A` | V ≤ 0.50 |

The flag row binds, because its credit is scaled at par with what burned while
its bounty already takes 80%.

*The anti-farm margin.* Staking must not pay on carry alone. An undisputed win
credits `0.05 × stake` (1,000 bps × 5,000 bps); the differential carry of staking
rather than holding is `r₀ · T = 0.005 × stake` over a two-week cycle. So
standing alone makes staking profitable iff `0.05·V > 0.005`, i.e. **V > 0.10**.

**Both hold only in `0 < V ≤ 0.10`**, and substituting the upper bound gives the
relation:

    t3 ≥ 100 × passPrice

| `t3` | implied ceiling on `passPrice` |
|---|---|
| 50 bps of supply | 0.5 bps of supply |
| **100 bps of supply** | **1.0 bps of supply** |
| 200 bps of supply | 2.0 bps of supply |

At `t3 = 100` bps: a 1,000 CC court has `t3` at 10 CC-equiv of standing and a
pass at ≤ 0.1 CC; a 100,000 CC court has 1,000 and ≤ 10 CC. Scale-invariant,
because both sides are fractions of supply.

**Consequences for the plan.**

- The ladder thresholds (§4) and the pass price (§3) **cannot be chosen
  independently**. Picking `t3` fixes the pass ceiling.
- This is a constant-space relation over frozen constants, so it belongs in
  `mustInvariants` beside the existing couplings — the realm should refuse to
  deploy a calibration where standing is worth more than the flag lane's burn can
  cover.
- `ECONOMICS.md` needs a `V` row in its symbol table beside ρ and y\*, and the
  memo's farming margins recomputed with the standing term present rather than
  assumed zero.
- The two zero-burn rows (author, staking) are **outside A19 by construction** —
  nothing burns, so there is no domination to satisfy. A19 is a rule about
  policing pay and applying it to a participation credit is a category error. The
  bound that governs those rows is the anti-farm one above, which is exactly why
  it, and not A19, is what makes `V ≤ 0.10` rather than `≤ 0.20`.


## 17. The site domain, and why it is the admin's alone

gnoweb serves this realm's own `Render()` and always will. But most readers
should be on the overlay, so every rendered page carries one line pointing at
the same thing over there. `sitelink.gno` holds the value and builds the link.

**One realm-wide value, set by the global DAO admin, and by nobody else.** Not
the meta court, not a court's moderators, and there is no per-court override.
This deliberately does *not* take the `ladder`/`creditRates` shape of "realm
default, court may override": a court that could point its own pages at a domain
of its choosing could route its readers anywhere while wearing the platform's
name, and the meta court exists to review claims rather than to own the front
door. All three refusals are held by test — a moderator, a stranger, and a
global DAO member who is not the admin — against a control that proves the
admin's own call lands.

**The realm owns the path.** What is stored is a HOST, never a base URL.
`sitePath` maps a gnoweb route onto the overlay's own routing, so the link on a
claim page can only ever point at that same claim. Store a base URL instead and
an admin could set `evil.example/#/c/other/1?` and every page in the realm would
deep-link somewhere it does not say it goes. The admin chooses the house; the
realm still writes the address on the envelope.

Routes the overlay has no page for resolve to the nearest thing it does: a board
or a single comment goes to its CLAIM, a moderation log to its COURT. That beats
linking to a route that does not exist, and it stays right after the overlay
learns to render comments.

### 17.1 The escaper that was the wrong escaper

The first version ran the domain through `sanitize.InlineText` at render "because
a validator and an escaper failing together is how the interesting bugs happen".
It was wrong, and the test that caught it was the one asserting a reader sees the
domain: `InlineText` backslash-escapes `.` and `-`, so `kourt.xyz` became
`kourt\.xyz` — correct as link *text*, and a broken *destination*.

The lesson is not "don't defend in depth". It is that an escaper defends a
CONTEXT, and this value goes into two at once. What makes it safe in both is the
character set the validator already enforces: every byte it permits is inert as
markdown link text and inert in a link destination. So the banner uses no escaper
at all, and the defence in depth is **fail-closed** instead —
`siteBanner` re-asks `siteDomainFault` and prints nothing if the stored value
does not validate. A value that reaches the variable without passing the setter
costs a missing header rather than a malformed page. That guard is white-box
tested by assigning the variable directly, which is the only way it is reachable
and the exact situation it exists for.

### 17.2 A second events filetest, rather than a wider ceiling

`z_events_filetest.gno` measured 58,874b against a 60,000b ceiling, and its note
in `scripts/check-storage.py` said what the next act had to choose: a deliberate
ceiling raise with a reason, or a second events filetest — "do not raise it to
make room without saying which". This chose the second filetest.
`z_sitedomain_filetest.gno` costs 42,853b against its own 50,000b ceiling, nearly
all of it the court it has to start, and the older ceiling keeps meaning exactly
what it said.

Both events are held by mutation: renaming the act inside `chain.Emit` fails the
filetest, and restoring it passes. An event nobody asserts is an audit trail
nobody has checked exists — and these two are the only record there can be that
a domain was ever set, since a realm-wide act has no court to log against.

### 17.3 The seat mutant that never compiled

The two seat guards were first mutated by replacing the condition with `false`,
and the probe reported both CAUGHT. Both were INVALID: the mutant orphaned the
`d := ensureGlobalDAO()` above it, and **gno reports "declared and not used" as a
TEST error, not a build error** — so a harness keying on `0 build errors` reads
an unbuildable mutant as a caught one. `check-mutant-collisions.py` flagged the
same two rows from static analysis, which is what made it visible.

Fixed in both places: the harness now treats `gnoTypeCheckError` as INVALID
whatever gno files it under, and the corpus rows invert the comparison
(`!=` → `==`, admitting everyone except the admin) so the mutant compiles and
the guard is genuinely measured.

## 18. The page that explains the thing

Read the front page as a stranger: a one-line lede — "Stake on claims of fact.
Your principal always returns 1×" — and then a list of court names and coin
symbols. Nothing on any rendered page said what a court is, what a claim is,
what staking does, or why the strangest and most important property here is
true. All of it lived in `docs/` or in the overlay, neither of which a gnoweb
reader can reach. A realm whose explanation is off-chain is a realm you have to
be told about before you can use it.

`help.gno` renders it at `/r/kourt/kourtv2:how-it-works`, linked from the
directory, every court page, and every comment board.

**The 1× guarantee goes first**, because it is the load-bearing surprise. Every
reader arrives with a model built from prediction markets, where the losing side
funds the winning one. Leave that model in place and nothing below reads
correctly — "stake NO" sounds like a bet they can lose.

**The route cannot collide with a court, structurally.** A slug is 1..11
characters and `how-it-works` is 12, so the two sets are disjoint by
construction. No entry in `reservedSlugs` has to be maintained, and no court
registered earlier can shadow it. `reservedSlugs` is for symbols that could
impersonate an asset in a wallet; a path that is simply too long to be a slug
needs nothing there. The test asserts `len(helpPath) > maxSlugLen` rather than
assuming it, because that inequality is what the carve rests on.

### 18.1 The court page led with its plumbing

Four lines of coin accounting — coin, price, supply/emitted, reservoir/senior
queue owed — sat between the reader and the only thing on the page they came
for. Read cold, `supply: 5108592379 · emitted: 0` is not an introduction to a
court; it is the accounting of one, which is what you want *after* deciding to
care.

The claims now come first and the accounting follows them, with every house term
glossed in the same sentence it is printed in: `reward reservoir: 0 waiting to be
earned · 0 already owed to earlier earners`. A number whose name you do not know
is worse than no number — it reads as something you are failing to understand
rather than something nobody told you.

Nothing was dropped in the move, and a test asserts each figure is still on the
page, because a reordering that quietly becomes a deletion is the easy mistake
here. An empty court still shows its coin: somebody deciding whether to be early
is exactly who wants the price.

### 18.2 Folders rendered nowhere

`folders.gno` has seven moderator verbs, a nesting model with ordering, a
purge lane with statutory category codes, an events filetest and its own
mutation rows. No page in this realm ever drew one. A court's moderators could
build an entire filing tree and a gnoweb reader could not see that it existed —
the same defect the comment board had, where the route worked and nothing linked
to it. Both are the same failure: a feature that is written to, gated, tested,
and unreachable by anybody not running the overlay.

The court page now carries **one line** — `Filed under: Document trail · Fauci`
— rather than a section, because the filing tree is navigation *into* the claims
and putting a section there would recreate the problem §18.1 moved the coin block
out of the way to fix. Root headings only; retired and purged ones are skipped,
since a retired heading is one a moderator struck from the tree and a purged
one's name was erased rather than flagged.

`<court>/folder/<id>` draws the heading, its description, the headings under it,
the claims filed in it, and a breadcrumb up. Every claim uses the court's own
status wording — a reader who learned what "open — stake YES or NO" means on one
page should not meet a synonym on another.

**A retired folder still resolves**, saying it was retired, instead of 404ing:
the row survives so links do not rot, and a 404 would make "retired" and "never
existed" look identical. **A purged folder renders a tombstone** naming the
category, the posture a purged claim's own page already takes.

**The page says the promise out loud** — "a folder curates and can never bury:
every claim above is also on the court's own newest-first list, and nothing is
reachable only from here". A reader looking at somebody else's organisation of a
contested subject is entitled to know it is not the only way in.

Two of the fourteen mutation rows survived at first, and both were the test's
fault rather than the code's. The route test asserted the string "Not found",
which all four refusals share — so deleting the id parse left `fid` at zero,
landed on the no-such-folder branch, and still said "Not found". And it used a
court with no folders at all, where `c.mod == nil` short-circuits before the
missing-folder branch is ever reached. Each refusal is now asserted by its own
message, against a court that has a real folder.

## 19. RULING NEEDED — the moderation log's universal claim is false

`renderModLog` opens with:

> Every moderation act on this court is recorded here: who acted, what they did,
> and when.

It is not. **Eleven acts emit a `ModAct` event and write no log row at all:**
`folder-create` (×2 call sites), `folder-move`, `folder-add`, `folder-remove`,
`folder-rename`, `folder-retire`, `folder-restore`, `folder-order`,
`folder-sort`, and `court-desc`. Neither `folders.gno` nor `court.gno` calls
`appendLog` anywhere. Observed rather than inferred: the demo court had three
folders created and five claims filed into them, and its log said "No moderation
acts yet."

This matters more now than it did last week, because §18.2 made the filing tree
**visible**. A reader can now see that somebody organised a contested docket and
cannot see who, or when, or that it changed — on the page whose whole purpose is
to answer exactly that, and which tells them it does.

**The ruling.** Two ways to make the sentence true, and which one is right is a
product decision, not a rendering one:

- **Log the curation.** `cm.log` already exists — it is the court-level log board
  sanctions land in, because a sanction is keyed to an address and has no claim
  to hang off. Folder acts have the same shape, so this is an append and not a
  new structure. It costs a row of storage per curation act and it widens what
  `PurgeCourtLogRow` has to be able to reach. It also makes a busy curator able
  to push sanctions off the log's first page, which is the page bound
  (`renderPageSize`) doing what it was built to do to the wrong content.
- **Narrow the sentence.** Say the log covers acts on claims and comments, and
  that curation is visible as the tree itself plus the chain's event stream.
  Costs nothing, and leaves "who filed this claim under Fauci, and when"
  answerable only by an indexer.

I have taken the second, as the smaller and reversible change, and because the
first alters what the log IS. **It is recorded here so that it is a decision
rather than a default.** If curation should be logged, the change is an
`appendLog` in each of the eleven sites and a widened purge test; the sentence
then goes back to what it said.

### 19.1 Four surfaces a stranger could not follow

Read cold, each of these failed a reader who had not been told something first.

**The comment count undercounted.** `writeBoardLink` counted `cs.boardTop` — the
pagination index, which holds only rows with no parent — so a board with three
threads and two replies advertised "3 comments" and then showed five things to
read. `BoardSize`, the read a client uses, has always returned `cs.board.Size()`:
the realm was telling a page and an API different numbers about the same board.
A reply is a comment. It is written by a person, charged against their daily
allowance, hideable, upvotable and purgeable like any other row, and it occupies
a line on the page the reader is about to open.

**The pass price had no unit.** All three places that quote it printed a bare
`190585`. Each court's coin is its own and interchangeable with nothing — the
fact the court page and the help page both go out of their way to state — which
makes a bare number on the one action a newcomer is invited to take the last
place a unit can be left to inference. A reader cannot tell 190585 ugnot from
190585 of a coin they have never heard of.

The stranger's sentence and the **slashed** user's are different sentences, and
only the stranger's was covered: the mutant stripping the unit from the slashed
line survived a full round. That user has already burned a pass once and had it
taken by a slash, so they are the reader for whom an unlabelled second price
matters most.

**A shared comment arrived with no proposition.** A single row is the most-shared
unit in the realm — somebody quotes an argument and sends the link — and the page
opened `# Comment 1` over `← the board` and said nothing else. Not which claim,
not which court, and no way to find out but to click a link labelled with a word
that tells them nothing either. The claim's title is now the heading, because
that is the thing being argued about, and the comment number is a subtitle where
an ordinal belongs. The title goes through `claimTitleFor`, so a redacted or
purged claim does not leak its text through this route.

**The moderation log promised more than it holds** — §19 above.

## 20. RULING NEEDED — the realm addresses a reader it cannot identify

`Render(path string) string` receives **no caller**. gnoweb serves the same
bytes to everyone, so the realm has no way to know whether the person reading
`<slug>/me/<addr>` is the owner of that address. It nonetheless writes in the
second person:

> **This court's moderators have frozen you out of its boards** until block N.
>
> A moderator slash took your standing to zero, and with it the entry pass…
>
> You cannot comment here yet. Earn standing below, or buy an entry pass…

Every one of those is a statement about the SUBJECT address, delivered to
whoever loaded the page. A moderator checking somebody before acting, a
counterparty checking who they are staking against, or anyone following a link
is told that *they* are frozen, *their* standing was slashed, *they* may not
comment.

`renderPositions` had the same shape and is fixed (§19.1), because its two
offenders were headings — "# Your positions", "## Your CC in this court" — and
rewriting a heading is not a change of voice.

**Why this is a ruling and not a fix.** The scope is 39 second-person lines
across four render files, **16 corpus rows** anchored on that text and **18 test
assertions** that quote it. And the information is not wrong — only the
addressee is presumed. Tone at that scale is an owner's decision, and there is a
real argument on both sides:

- **Third person** ("this address cannot comment here yet") is always true, and
  is the only voice a page with no viewer identity can strictly justify.
- **Second person** is warmer, and the page is in fact most often reached by its
  own owner, from the board's "Where you stand" link.

**Not urgent, and here is why.** The page prints the address in a code span
directly under its heading and above every one of those sentences, so a reader
who is paying attention already knows whose page it is. The failure is one of
first impression rather than of fact.

**If the ruling is third person**, the edit is mechanical but wide: the 39 lines,
then repoint the 16 corpus rows and rewrite the 18 assertions — and note that
some second-person text is CORRECT and must stay, because it addresses the
reader rather than the subject: "put your address on the end of this page's
path" is an instruction to whoever is reading, and true for all of them.

### 20.1 The help page taught the wrong currency

The page I wrote to explain the system opened its load-bearing section with:

> Stake GNOT on YES or NO and the stake stays yours.

**You stake the court's coin, not GNOT.** `stake.gno`'s `Stake` says so in its
own first line — "Stake backs one side of a claim with CC" — and GNOT only ever
buys that coin, one way, through the curve. This is the worst sentence on that
surface to get wrong: a reader who believes they are staking GNOT has the model
inverted before paragraph two, and every later sentence about 1× and about
earning reads against the wrong asset.

Two more errors sat in the same paragraph:

- It said the coin **"is what gives you a voice here."** It is not. **Standing**
  is, and standing is a score that cannot be bought. Coin and standing touch at
  exactly one point — the entry pass — and telling a reader a balance buys a
  voice is the single claim this design exists to falsify.
- It repeated the moderation log's false universal ("every act is written to
  that court's moderation log"), which §19 had just corrected on the log itself.
  Worse here: on the log an empty list contradicts the promise, and on the help
  page nothing does.

The page now states the order of operations before anything else — GNOT buys a
court's coin, one way; that coin is what you stake — and separates the two
things being right earns: more coin out of the reserve, and standing.

**How it happened, because the mechanism matters more than the instance.** The
page was written from a mental model assembled by reading *render* code, and the
staking entrypoint was never opened. Render surfaces describe state; they do not
define it, and a explanation built only from them inherits every ambiguity in
the descriptions. It surfaced by reading a rendered claim page as a stranger and
asking what `staked now: 84000000` was denominated in — a question the page
still does not answer, which is the next thing to fix.

**The rule this earns:** a page that makes a factual claim about what the realm
does is checked against the entrypoint that does it, not against another page.

### 20.2 Units: the sweep that missed, and the test that only rendered one branch

Every money figure on a human-facing page now names the court's coin through
`qualifiedSymbol`. Eight of them did not: the live stake, the answered stake,
the unwithdrawn remainder, the answer bond, the dispute bond, the flag bond, the
reward pools, and the "never earned" list's "buying CC".

`staked now: 84000000` was the first number on the first page most readers see,
and nothing on it said what 84000000 counted. Asking that question is what
surfaced §20.1 — the help page teaching the wrong currency — so the gap was
load-bearing twice.

**A sweep that misses is worse than no sweep**, because it reads as coverage.
The first pass scanned for a `WriteString` and a `FormatInt` **on the same
line**, which multi-line concatenations escape — and three of the eight were
exactly that shape. It also found, and correctly left alone, the two categories
that must NOT carry units: the `qeval` wire formats (`BoardNewest`,
`StandingBreakdown`, `FolderTree`, the association and supersede edge lists),
which a client parses, and the ids and counts, where no unit applies.

**Four mutants survived the first round because the test rendered only an OPEN
claim.** The answered figures, the flag bond and the reward pools are on
lifecycle branches a live open claim never takes, so stripping their units cost
nothing a test could see. The test now drives all four states by setting
`claimState` fields directly, the way `TestRenderLifecycleLines` already did.
A page with a `switch` over its subject's state needs a case per arm; asserting
against one arm and calling the page covered is how a whole branch goes unheld.

And one existing assertion **hard-coded `CC units`**, which pinned the defect
rather than the behaviour. It now derives the unit from
`qualifiedSymbol(mustCourt(slug))`, so it follows the rule instead of a literal.

## 21. Elections render nowhere — the third instance of one pattern

`modvote.gno` exports five election verbs — `RegisterModCandidate`,
`OpenElection`, `NominateCandidate`, `ApproveCandidate`, `ApproveRetain`,
`ResolveElection` — and nine reads: `ElectionOpen`, `ElectionWindows`,
`ElectionFloorOf`, `ElectionBondOf`, `ElectionTally`, `CandidateMembers`,
`CandidateThreshold`, `ElectionCooldownUntil`, plus the candidate registry.

**No render path shows any of it.** A court's holders cannot learn from any page
in this realm that an election is open, who is standing, what the tally is, what
the bond costs, or when the window shuts. The help page tells them "each court
elects its own moderators" — a promise with no surface.

This is the **third** instance of one pattern: the comment board had a working
route and no link (§18-era), the filing tree had seven verbs and no page
(§18.2), and elections have fourteen entrypoints and no page. In every case the
writes were gated, tested and mutation-covered, and the read side existed —
what was missing was only the rendering. The realm's tests prove the machinery
works; nothing proved anybody could see it.

`ElectionTally`'s own doc comment says it "exposes a line's approving weight and
retain's, **for render**" — a read written for a surface never built.

### 21.1 The hazard the surface must respect

`ElectionFloorOf` carries a warning that an election page has to honour, and it
is worth quoting because it inverts the obvious design:

> `install` requires `e.turnout >= e.floor`, and below it nothing installs and
> the CURRENT moderator set stands. So an over-read of achievable turnout —
> mobilising to what looks like the bar and falling short — hands the election
> to the incumbents by apathy.

The floor is 5% of `votable`, and `votable` nets out only the court escrow: coin
at a wrapper's address counts toward the pool and **no key can vote it**. So a
page that prints the floor beside the pool invites a coalition to reason about a
share of a pool part of which cannot turn out. Whatever the surface says about
the bar, it must not let a reader infer that reaching it is easier than it is —
and the direction of the error matters, because falling short is not a neutral
outcome but a win for the incumbents.

The same comment notes this is currently harmless — "nothing renders this today"
— which stops being true the moment the surface exists.

### 21.2 The ballot page

`/<court>/election`, linked from every court's moderation log.

**It renders whether or not a ballot is open.** "None is open" is the state a
holder is usually in and the one they can act from, so a page that 404s there
would tell somebody looking for their remedy that the remedy does not exist. The
closed state names the seats held now, the cooldown deadline if there is one, and
the two calls that open a ballot — `RegisterModCandidate` then `OpenElection` —
because the failure otherwise is a panic with no page to explain it.

**The phase is derived, not left to arithmetic.** Nominating in the vote window
or voting during nomination both panic, and a reader handed three block numbers
has to work out which is which.

**Retain is a line on the ballot**, listed beside the challengers rather than
under them: it is what wins if nobody clears the bar, so it belongs in the list a
reader is comparing.

**The turnout bar carries its warning.** Two facts a reader can get wrong in the
incumbents' favour, both printed rather than left to be derived, because the
error has a direction: falling short is *the same outcome as a vote to retain*,
and the bar's pool includes coin no key can vote, so the share of castable weight
actually needed is larger than the bar looks.

Sixteen rows, all CAUGHT — two of them ablating the hazard copy specifically.

**One INVALID first, and a new instance of an old trap.** Deleting the member
loop orphaned the `sanitize` **import** — `InlineText` is used nowhere else in
the file — so the mutant never compiled. Previous instances of this orphaned a
*variable*; an import is the same failure through a different door, and the
harness's "did not build ≠ CAUGHT" rule caught it either way. The row now keeps
the call alive inside a loop that writes nothing, which preserves the intent
exactly.

**And a lazily-created `courtMod` bit the first draft.** A court that has never
had a moderation act has `c.mod == nil`, so `renderModLog` takes an early return
— and the link to this page had been put in the branch below it, along with the
"how to open one" text on the ballot page itself. A court with no moderator set
is precisely the one where both matter most. Both now sit on paths that always
run.

## 22. An unrated claim was reported as rated LOW

`cs.tier`'s zero value **is** `tierLowX`. Nothing writes mid until a settle or a
finalize does, so every answered-but-unsettled claim rendered:

> - quality: low (default; the flag lane may re-vote it)

And the tier is a **payout multiplier** — `crystallize` computes
`want := mustMul(cs.tier, midGross)`, with low/mid/high at 0/1/2. So low pays
**nothing**, and the page was telling the answerer and every staker that this
claim currently pays nothing, when its outcome absent a flag vote is mid: full
pay. The word "default" made it worse by reading as "low is the default value"
when it meant "this rating is not settled yet".

**A genuine low is distinguishable.** `quality.gno` lands a voted tier and sets
`slotConsumed` in the same block, so `tier == low && !slotConsumed` can only be
the untouched zero. The page now has three cases — final, voted, and never
rated — instead of two.

**And it says what the rating is for**, which no surface did: low pays nothing,
mid the full amount, high double. Without that, "low" reads as an editorial
opinion of the claim rather than as the difference between being paid and not.

### 22.1 Two more terms a stranger could not act on

`- flag slot open — bond 1266666 KOURT:COVID` is two pieces of house vocabulary
and a price, and says neither what flagging is nor what the bond buys. It now
reads: *anyone may challenge that rating once, by posting a bond of N and
calling a vote on it.*

`- answerer's difficulty record (this court): 0` is a bare integer with no scale.
The code knew what it counted — contested-and-upheld answers only, so a high
number is hard-won signal rather than volume — and the page did not say. It now
reads: *the answerer has been challenged and upheld 0 time(s) in this court —
answers nobody contested do not count.*

Seven rows, all CAUGHT, including one that hides a voted low behind "not yet
rated" and one that merely softens "low pays nothing". Four existing
`render_test` assertions quoted the old wording and were updated; two corpus
rows anchored on the flag-slot line and were repointed with their intent intact.

**The general lesson, which is worth more than this instance:** a zero value that
coincides with a meaningful state will render as that state. `tierLowX = 0` is
the one found here; the same shape is worth looking for wherever a render reads
an enum that state does not always initialise.

### 22.2 The sweep the zero-value lesson earned

§22 fixed one field. The lesson generalises — *a zero value that coincides with a
meaningful state will render as that state* — so the right follow-up was to ask
which other enums in this realm have a meaningful zero, rather than to wait for
the next instance.

Two answers, and neither was a second bug:

**`cs.provisional` was already guarded**, and its comment names the hazard
exactly: `provisional: -1, // int8 zero is sideYES — the sentinel must be
explicit`. The author knew this class and defended against it there; `tier` went
through the same net unprotected. That is worth stating plainly, because it means
the failure was not ignorance of the pattern but an incomplete application of it.

**`tierHidden = 0`, and a court's tier IS set explicitly at creation**
(`tier: tierListed`), so no court renders as hidden by accident.

But asking the question surfaced a different gap. `SetTier` lets a global DAO
member move a court to `tierHidden`, which removes it from the directory and from
every listing read — **and no page said so**. A hidden CLAIM gets one of four
banners naming the authority that hid it. A hidden COURT got silence: its creator
and its holders watch it disappear from the front page with nothing anywhere to
distinguish a deliberate act from a fault.

The court page now carries the equivalent banner, worded after the claim's meta
case because the situation is the same one — listed nowhere, reachable here,
lifecycle untouched. The last clause is the one that matters to a holder: a
delisted court still stakes, answers, settles and pays out, and without saying so
a delisting reads as a freeze on their money.

**Two test bugs of mine on the way, both the same shape — an assertion matching
more than it meant.** `modFixture` bootstraps a court named `<slug>+"z"`, so
`"…:hp11"` is a prefix of `"…:hp11z"` and a bare `Contains` matched the
neighbour. And asking `Render("")` whether a court is listed asks a page capped
at `renderPageSize`, so the test passed alone and failed in company, where the
package holds more courts than fit. It asks `ListByTier` now — the listing fact
itself, uncapped.
