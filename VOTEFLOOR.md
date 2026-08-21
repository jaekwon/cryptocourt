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
at. Looking for an instant was the error; the release is a CONDITION, not a moment —
the claim is not terminal AND the tally seq voted in is still live. Both the easy and
the hard case fall out of it, and the easy case releases immediately.

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
