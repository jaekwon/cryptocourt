# TODOs

Open items with enough detail to act on cold. Newest first. Each item records what
was *verified in the source* separately from what was *measured in a run*, because
the two rot at different rates.

---

## 1. LIVE BUG — `provClose` is unreachable on default params, so a false answer finalizes by apathy

**Severity: high.** This is the anti-apathy backstop, and on a default court it never
fires. The consequence is not a stuck claim — it is the wrong verdict becoming final,
with the honest challenger having paid for the privilege of finding out.

### The defect

`votingBlocks` and `escrowMinBlocks` are **the same number**:

```go
// realm/r/kourtv2/court.gno:283,288
votingBlocks:    120_960,   // one week
escrowMinBlocks: 120_960,   // one week
```

`escrowWindow` (dispute.gno:630-637) returns `escrowMinBlocks + extraDays*oneDayBlocks`,
where `extraDays = mulDiv128(cs.xBarFrozen, c.crv.Price(c.minted), 500_000_000)` and
`Price(s) = s / c.d` (p/curve/curve.gno:183). **So on any court with `minted == 0`,
`extraDays` is exactly 0 and `escrowWindow == votingBlocks` exactly.** More generally it
is 0 whenever `xBarFrozen × Price(minted) < 5×10^8`, which is most young courts.

`escrowUntil` is set **once, at the first resolution, and deliberately never recomputed**
(dispute.gno:344-349 — the comment says so, citing V1 §3.6). Every later round must
*open* before that fixed deadline (dispute.gno:99-102) and each round burns a full
`votingBlocks` to vote, because `ResolveDispute` refuses while the governor's proposal is
`"active"` (dispute.gno:216-218).

So round 3 needs `escrowWindow > votingBlocks`. At the defaults they are equal, and round
3 cannot open. `failedRounds` caps at **2**, but `provClose` only fires at
`failedRounds >= maxFailedRounds` where `maxFailedRounds = 3` (court.gno:76,
dispute.gno:266-268). **The branch is dead.**

Meanwhile the *first* failed round already did the damage:

```go
// dispute.gno:260-263 — only the FIRST failed round defaults the verdict
if firstResolution {
    cs.provisional = cs.answer
}
```

The false answer becomes the standing provisional verdict, nothing later dislodges it, and
`Finalize` lands on it. **Apathy resolves the claim in the liar's favour** — which is the
exact outcome the failed-quorum branch's own comment says must not happen ("apathy must
not resolve a claim").

### Measured

Confirmed **twice, independently**, by two separate staged copies that did not share
fixtures: one reported the round-count boundary below, the other hit it from the other
direction while measuring self-defence (`escrowUntil 727324` vs `now 727325`).

From the staged-copy run (`zz_measure_test.gno`, shadow root — full kourtv2 suite green):

| `escrowMinBlocks` | rounds that fit | `provClose` |
|---|---|---|
| 120_960 (**default**) | 2 | **false** — `provisional` = the answer |
| 120_961 | 2 | false |
| 120_962 | 3 | true |

So the threshold is `votingBlocks + 2`, and the default misses it by two blocks.

Cost to the honest side, same run: the disputer burned **210.000000 CC** across two failed
rounds (half of each of two doubling bonds) on a claim with `xBarFrozen ≈ 700 CC`, and the
false answer still won.

### Two comments that assert the opposite

Both are wrong as written and should be fixed with the code, since they are what a reader
would trust instead of re-deriving this:

- `dispute.gno:~128` — *"provClose bounds failedRounds ≤ 2 here"*. The bound is real but it
  comes from the **calendar**, not from `provClose`. On default params `provClose` never
  runs. (This is the highest-value lens in this repo — a comment asserting a property
  nothing enforces — and it caught this one.)
- The `escrowMinBlocks` default is documented as "the escrow window's floor: one week"
  (court.gno:275, pinned at court_test.gno:322) with no hint that being *equal* to
  `votingBlocks` is what disarms the backstop.

### Candidate fixes (not yet chosen)

1. **Raise `escrowMinBlocks`** to `votingBlocks*maxFailedRounds + slack` so
   `maxFailedRounds` rounds always fit. Simplest, and makes the constant mean what
   `maxFailedRounds` claims. Cost: lengthens every escrow, including honest ones.
2. **Derive `maxFailedRounds` from the window** rather than fixing it at 3, so the two
   constants cannot disagree.
3. **Extend `escrowUntil` per failed round** — but the "set once, never recomputed" rule at
   dispute.gno:344-349 is deliberate anti-manipulation design and must not be dropped
   casually. A failed-quorum-only extension is narrower and may be safe.
4. **Add a deploy invariant** in `mustInvariants` pinning
   `escrowMinBlocks > votingBlocks*(maxFailedRounds-1)`. Do this **regardless** of which
   of 1-3 lands — it is the check that stops this from silently returning.

Whichever lands, the test must assert the bystander: an ordinary claim with a *decided*
first round must still finalize on its old schedule.

---

## 1b. `quorumFloor`'s supply arm makes the robbed pool unable to defend itself

**Severity: high.** Same family as item 1 — this is *why* a bad verdict stands, and it is
the root cause behind the answer-snipe being profitable at all.

`quorumFloor` (dispute.gno:569-616) maxes the X̄ arm against `5% of court supply`
(dispute.gno:580-582). But the prize at stake is denominated in **claim stake**, while the
bar is denominated in **court supply**. Below `X̄ = 5%·supply` the robbed pool **cannot
reach the bar even voting unanimously, at any concentration**. Measured sweep (supply
40,000 CC):

| honest pool | % of supply | X̄ | quorumFloor | pool weight | clears alone? |
|---|---|---|---|---|---|
| 400 CC | 1% | 303 | 2,000 | 400 | **no — 6.6× short** |
| 1,200 | 3% | 1,103 | 2,000 | 1,200 | **no** |
| 2,000 | 5% | 1,903 | 2,000 | 2,000 | yes |
| 4,000 | 10% | 3,903 | 3,903 | 4,000 | yes |

**The threshold is exactly 5% of court supply, and it is entirely independent of the answer
bond** — which is the proof that the 50% bond buys nothing on this axis. dispute.gno:600-609
already states the consequence in its own words: *"an unreachable quorum does NOT mean 'no
verdict' … the bar hands the decision to the party it exists to police."* Combined with
item 1, that is the whole failure: the pool can't clear the bar, the round fails quorum,
`provisional = cs.answer`, and the defender forfeits half their bond for trying.

**Measured one-clause fix, zero test churn** (dispute.gno:580-582) — gate the supply arm on
the claim actually being that big:

```go
if fivePct := mulDiv128(supply, quorumSupplyBps, grc20votes.Bps); fivePct > floor && xbar >= fivePct {
```

Floor becomes exactly X̄ at every claim size; the robbed pool clears it alone in all five
sweep rows; **the entire existing suite passes unmodified (ok . 7.53s)**.

The trade, stated honestly: it lowers the weight needed for a *malicious* overturn of a
small claim from 5%·S to ~X̄/2 (~10× on a claim at 1% of supply). Not free — the attacker's
bond burns on an uphold and the answerer is comped 2× — and a whale at 5%·S can already do
it today, so the relaxation extends the capability to small honest *and* small malicious
coalitions symmetrically. Since the snipe is currently **free** while a false overturn costs
a bond, the trade favours relaxing it. But verify `qualityBars` (quality.gno:231-275) and
`mustElectionInvariants` first — they carry the same shape and were **not** tested against
this patch.

Knife edge: even patched, `floor = X̄` and a fully-staked pool's weight is `X̄ − ε`, so it
falls short by exactly the sniper's dust. One abstain from anyone fixes it (`cast = yes+no+
abstain`, dispute.gno:222). Useful corollary: **the coordination task is turnout, not
agreement** — a rescue needs one *yes* plus enough *abstains*, so an indifferent whale can
enable it without forming an opinion.

### Two adjacent measured facts worth not re-deriving

- **There is no free-rider problem in the verdict lane.** A volunteer's surplus is
  `b·(2q_o − q_u − q_f/2)`, and the 2:1 comp (`compAmount`, dispute.gno:372-381) is a
  private premium a free-rider does not get. Verified the `2b` arm binds at every bond level
  and every X̄ (12/12 cases). So the sign is independent of both `b` and the holder's stake
  share: **any holder of any size prefers to dispute** once overturn is >20% likely (>33% if
  the failure mode is uphold). The dilemma is already dissolved — the blocker is capital and
  turnout, not incentive.
- **A one-person rescue already works today.** `OpenDispute` bars only the answerer,
  `VoteDispute` only participants — so a disinterested holder can post the bond *and* vote
  in the round they opened. Measured end-to-end: one non-participant whale (13.9% of supply)
  opened, voted, resolved, overturned the snipe, recovered the bond and took 761.2 CC of
  comp — 2:1 on one transaction pair, permissionless, live. The snipe is *already* priced as
  a bounty; what fails is turnout, not the reward.

---

## 1c. The 50% answer bond is 2.59× oversized, and it makes self-defence 11× harder

**Severity: medium.** Not a bug — a calibration the repo has already partly retracted — but
it actively worsens items 1 and 1b, so it belongs with them.

**The flat bond that closes the snipe at every age is `maxMidGrossBps` = 1928 bps**, a
quantity `court.gno:224-226` **already computes**. Destruction leverage at the hot 12-week
maximum: 0.386 at 5000 bps, 1.000 at 1928. So `answerBondBps = 5000` exceeds the anti-snipe
requirement by **2.59×**, and `court.gno:194`'s bound carries the same slack because it is
sized against `capBonus`'s *cap* (tier/2 × stake = 50%·X̄) rather than the *realizable* draw
(19.278%·X̄) — measured, the cap never binds on the honest path. PLAN.md:718-725 already
concedes this in the repo's own words ("upper-bounds it with ~5× slack").

**And it is anti-correlated with self-defence.** The defender's price is
`min(20%·X̄, 40%×answerBond)` (dispute.gno:130-136) — 40% of the *answerer's* bond. So a 50%
answer bond makes disputing **11.1× more expensive** (380.60 CC vs 34.25 CC at 450 bps).
Measured: a victim holding **100% of the robbed pool** had 100 CC spendable against a
380.60 CC requirement and `OpenDispute` was **refused** by lock.gno:73 — because the bond
comes from *spendable* CC while the victim's capital is locked in the stake being defended.
Headroom rule: the largest honest staker must have committed ≤83.3% of their CC at 5000
bps, vs ≤98.2% at 450.

**The floor is also keyed to the wrong side.** `answer.gno:148` reads `cs.sideConv(verdict)`
— the *answered* side — so at an 11-week claim the sniper (dust declared) pays the 45 CC
flat arm while the honest majority answerer pays 101 CC. Today's keying taxes the person
declaring the well-funded side and exempts the one declaring dust. Keying it to
`max(yesConv, noConv)` is **bit-identical for majority and even-split answers** (measured)
and **~5× cheaper than today for an honest contrarian** (101 CC vs 500 CC), with an analytic
ceiling of 30.845%·X̄ — the exact quantity `court.gno:227` already evaluates.

**State plainly, because no formula fixes it:** an honest contrarian answer is
*indistinguishable in shape* from a snipe (dust on the declared side, large opposing pool).
No bond sizing can separate them. Max-keying is strictly cheaper than the status quo
everywhere, but it prices contrarian truth in proportion to how wrong the crowd is.

Costs if pursued: rescope `court.gno:194` and `:227` (both assert the floor is inert — that
stops being true by design), plus 5 shallow fixture edits. Use **600 bps**, not 450 — at
450 `court.gno:232` holds with *zero* margin and the settle-time reserve (session.gno:74-86)
equals the entire bond, so nothing returns at settle.

**Counterweight, and the reason not to just cut it:** measured cold-start snipe tolerance is
**8.82%** — roughly 1 snipe in 11 claims makes staking worse than the external rate on a
young court. And a young court is precisely the one with no 5%-of-supply holder watching.
The regimes are anti-correlated, which is the strongest argument against accepting snipe
risk at a low bond *without* fixing 1 and 1b first.

---

## 2. An overturn's free quality ride can zero the winners it just vindicated

**Severity: medium-high.** The one shape where a false answer really does destroy the
honest payout — and it is not the ordinary overturn.

An ordinary overturn pays honest winners **in full**: `Finalize` restores
`cs.tier = tierMidX` (dispute.gno:462-464), and measured, a 300 CC / 3-week winning
position draws **4.955068 CC** whether the answer stood or was overturned — bit-identical.
Only the answerer loses (5-point slice zeroed, bond burned, credential reset).

But `resolveQualityRide` (quality.gno:618) can set `tier = tierLowX = 0` on **the same
tally that overturned the answer**, and `crystallize.gno:83` (`want := mustMul(cs.tier,
midGross)`) then zeroes the entire draw. So the vote that proved the answer false
simultaneously declares the claim junk and pays the honest winners nothing. Measured: same
fixture, **0**.

quality.gno:24-28 and :639-641 argue at length that "was the answer right" and "is the
claim worth anything" are *different questions*. This path conflates them.

**Fix direction:** gate the *demotion* arm of `resolveQualityRide` on an overturn round, or
require its own mandate for it. A verdict round should not be able to zero the tier it just
vindicated.

---

## 3. `provClose` zeroes the draw while calling itself "not a conclusive low"

**Severity: medium.** Internal contradiction, and it strands honest stakers.

`provCloseClaim` (dispute.gno:386-413) refunds the deposit **and** the fee, with the
explicit comment *"provClose is not a conclusive low — §3.1.7"* (dispute.gno:385). Then it
sets `tier = tierLowX` and `tierFinal = true` (dispute.gno:390) — and `Crystallize` refuses
outright on top of that (`crystallize.gno:32-34`, "closed claims have no draw"). So it
treats itself as not-a-low for the deposit and as a low for the draw.

Honest winners get principal back at 1× and **no winnings**, on a claim where nobody was
found to have done anything wrong.

**Fix direction:** pay the winners at the default MID against the standing `provisional`,
consistent with how provClose already treats itself everywhere else.

*(Note: fixing item 1 makes this path reachable for the first time on a default court. Do
not fix 1 without deciding 3.)*

---

## 4. Dead-claim expiry evaporates conviction with no payout

Not a bug — designed — but recorded because it is the thing the owner cares most about and
the design work is unresolved.

A claim that dies unanswered at 12 weeks (`deadClaimSecs`, clock.gno:37) refunds principal
via `Unstake` and pays **nothing**: measured, **22.950015 CC of conviction evaporates** on
a 300 CC / 12-week position. `CloseDeadClaim` also burns the fee unconditionally
(claim.gno:368-378), which contradicts PLAN.md:989 (fee should burn only on
dead-with-no-stake) — though that predicate is farmable with a 1-unit self-stake, so the
spec may be the thing that is wrong.

**Reconciling two audits that look contradictory.** One found re-answerability unbuildable;
another recommended "make destruction recoverable" as the top fix. They agree, because an
**ordinary overturn already pays honest winners in full** (measured bit-identical, item 2) —
so most of the recoverability already exists. What is missing is not a second answer, it is
(1) the failed-quorum default that confirms the answer, (1b) the quorum bar the victims
cannot clear, and (2)/(3) the two paths that zero a draw nobody was found at fault for. Fix
those four and recoverability arrives without a new mechanism.

**Regulatory note, and it raises the priority of 1/1b/2/3 above any bond change.**
REGULATIONS.md:188-201 rests on Humphrey factor 2 — prizes "amounts certain and guaranteed",
with a fixed published rate scoring better than variable shares. **A snipe makes the
published rate a lie**: the prize goes to zero for reasons unrelated to the fact being
adjudicated. That is a defect in the regulatory posture, not only in the economics, and only
recoverability cures it — every bond-sizing fix leaves the prize destroyable and merely makes
destruction expensive. Constraint on any fix: the claim must *eventually mint the prize it
should have minted*. Never redistribute the sniper's bond to the stakers — that makes the
prize loser-funded and bilateral, which is the one thing escape (b) cannot survive. The
existing disputer comp is fine as-is: conduct-contingent, paid to whoever proved the
misconduct, burn-anchored and capped at 80% of the burn.

**Ruled out:** re-answerability. It cannot re-freeze the conviction pin without arming
three dormant clamps (answer.gno:130-147 names them), cannot reopen staking without making
one claim a ~51× risk-free emission faucet (measured: 297.982184 CC period budget vs
5.760267 CC honest draw), cannot get the calendar it needs (the 12-week clock never
pauses, and extending it panics at deploy per court.gno:224-229), and a second answer would
inherit answer #1's `slotConsumed`/`slashLevied` latches — making it **structurally
unflaggable and unslashable**.

---

## 5. Owner / other session

- Add `chat_all.js` to `CHECKS` in `web/tests/browser/run.js` (untracked, theirs).
