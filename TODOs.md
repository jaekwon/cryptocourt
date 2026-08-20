# TODOs

Open items with enough detail to act on cold. Newest first. Each item records what
was *verified in the source* separately from what was *measured in a run*, because
the two rot at different rates.

> **`GAMETHEORY.md` is newer than this file and supersedes it wherever they disagree.** Six
> audit passes since these items were written falsified four claims below — the comp starvation
> is a drought rather than a permanent tax, its proposed cap must not ship, the dispute-round
> boundary is one block rather than two, and the quorum relaxation is 5.01× rather than ~10×.
> Every one is corrected inline in a quoted block, with a pointer to the section that did it.
> **Nothing here is implemented; `realm/` is untouched.**

---

## 0a. LIVE BUG — straddling a claim is RISK-FREE YIELD today, no credential needed

**Shipped behaviour, exploitable now, and it was found while pricing an unrelated design.** Not
recorded anywhere in `GAMETHEORY.md`, which is why it sits above everything else.

Stake **both sides** of one claim and you are paid for it. Measured (`TestP6`, 11-week claim, cold
rate, MID tier, no proposed change anywhere in the tree):

```
straddler: 300 YES + 300 NO, 600 CC locked   winning-side draw = 18.096774 CC
carry (25 bps/wk x 11 wk on 600 CC)                            = 16.500000 CC
NET                                                            = +1.596774 CC  ->  +1.26%/yr RISK-FREE

honest:    901 CC one side                   draw 54.290322     net +29.512822  ->  +15.5%/yr WITH risk
```

**Why it pays.** The straddler's winning leg draws from emission **he caused to exist**: his own
conviction raises `midGross`, and he then collects exactly his pro-rata share of the increment —
measured `18.0968 / 72.3871 = 0.250000` exactly. The losing leg returns 1× (principal always does),
so the only cost is carry on the loser. `capBonus` does not bind (the cap is `tier/2 × 300 CC`,
far above 18.1).

**It gets worse with the parameters the design is moving toward:**

| | multiplier | risk-free yield |
|---|---|---|
| MID, cold (measured) | 1× | **+1.26%/yr** |
| HIGH tier | ×2 | **+15.5%/yr** |
| hot emission rate | ×2.52 | **+22.9%/yr** |

**Why this matters beyond itself.** `LONGCLAIMS.md` §4.2 worried that a *proposed* credential would
create a straddle incentive. It would only **enlarge an existing one**. Any design that pays for
held positions inherits this, so this is upstream of that work and should be fixed first or priced
into it.

**Fix direction — not chosen, and it needs care.** The obvious move is to make the winning draw net
of the same holder's losing position, but `GAMETHEORY.md` §13.5 measured netting **fatal** in the
bond-floor case (it removes a self-tax that was doing real work). Note the shape differs here: this
nets a *payout numerator*, not a bond denominator. Also note **the sybil floor**: two addresses on
opposite sides are observationally identical to two people who disagree, so netting buys a factor of
**2** in the safe rate and no more.

---

## 0. LIVE BUG, HIGHEST SEVERITY — one dispute round starves a court's junior draw for weeks

> **CORRECTED — see `GAMETHEORY.md` §11.8, which falsified two things below.** The starvation
> is a **drought**, not a permanent tax: `cumAccrual` is monotone and *unbounded*, and
> `reservedTail` is a high-water **cursor**, not a balance. **M:** a bystander claim
> crystallizing *after* the drought is paid bit-identically to the control. So this is a
> **timing** bug, and `Crystallize` being permissionless is the whole of it rather than an
> aggravating detail. Drought length at 1/5/10/30% of supply: 2/6/11/36 weeks.
>
> **And the fix proposed at the bottom of this item must NOT ship.** Capping comp strands
> **73% of a prevailing challenger's compensation** and moves their break-even overturn
> probability from 20% to 46.7%, destroying the argument that holders will defend themselves.
> The real fix is to make the junior draw *delayed rather than scaled*. Details in §11.8.

**This is the actual mechanism by which a disputed claim's draw is destroyed today.** No
attacker required, no proposal involved, and it invalidates the reassuring measurement in
item 2 on any claim that is large relative to its court.

### The defect

`reservedTail` and `juniorReserved` are **strictly monotone**. Verified exhaustively — each
has exactly **one write site in the entire non-test realm, and both are additions**:

```go
// emission.gno:172 — the only write to reservedTail, anywhere
c.reservedTail = mustAdd(c.reservedTail, amount)
// emission.gno:197 — the only write to juniorReserved, anywhere
c.juniorReserved = mustAdd(c.juniorReserved, want)
```

The junior pool is `reservoirR() = cumAccrual − reservedTail − juniorReserved`, floored at
zero (emission.gno:140-150). `comp` is enqueued as a **senior** entitlement
(`enqueueSenior`, emission.gno:157-183), so **every comp ever paid pushes the cursor ahead of
the junior pool until accrual catches up** — a drought whose length is the comp divided by the
budget. *(This sentence originally read "permanently and irreversibly shrinks the reservoir for
every later claim"; that was wrong, because `cumAccrual` is unbounded. See §11.8.)*

And `comp` is unbounded relative to the court's emission budget.
`compAmount = min(2×ownBond, 80%×burned)` (dispute.gno:370-381) — and the two arms are
**exactly equal by construction**, since `2 × disputeBondOfAnswerBps = compOfBurnBps`
(2×4000 = 8000), so both land at **40%·X̄** at a 50% answer bond. Measured, 300,000 CC court
with `curPeriodBudget` = 1,132 CC/week:

```
reservedTail   0 → 12,001,200,000     (ONE overturn round)
reservoir      13,481,280 → 0
weeks of the WHOLE court's emission consumed by that single comp:  10
```

Then `reserveJunior` **silently clamps** the draw to the empty reservoir — its own comment
says why: *"Clamps to R — never aborts a shared settlement path (F4)"* (emission.gno:186-199).
So the honest winners' draw comes out **0**, and because `cs.crystallized` is a one-way
latch and `Crystallize` is **permissionless** after the grace week, **an attacker chooses the
moment** at which that zero is made permanent.

### Why this corrects item 2's headline

Item 2 records that an ordinary overturn pays honest winners in full — measured 4.955068 CC,
bit-identical to the answer standing. **That measurement is correct but does not generalize.**
It was taken on a claim tiny relative to its court (~51× reservoir headroom). A second
independent audit measured `drawWinners = 0` after an overturn on a claim at ~10% of supply —
same tier (mid, correctly restored), zero payout, because comp had eaten the reservoir.

**So the honest statement is: the tier path is fine; the funding path is not.** Whether an
overturn actually pays depends on the claim's size relative to its court, and the dependence
is a cliff, not a slope.

### Fix direction — SUPERSEDED

**The cap below must not ship.** `GAMETHEORY.md` §11.8 measured it: capping comp strands
**73% of a prevailing challenger's compensation** (8,757 of 11,999 CC simply vanishes — there is
one `enqueueSenior` per disposition, the round's bonds are zeroed on the same tally, and nothing
queues or expires), and it moves the challenger's break-even overturn probability from **20% to
46.7%**. The senior lane otherwise **pays in full, time-delayed, never scaled** — so capping is
the *only* thing that would strand anyone. Worse, the two constraints on the constant are
**mutually exclusive** above X̄/S ≈ 2.85%, and the cliff moves with court age (3.77% of supply at
week 1 → 0.95% at week 208), so any fixed constant drives comp → 0 asymptotically.

> **The real fix: make the junior draw DELAYED rather than SCALED.** `reserveJunior` reserves
> the full `want` on the accrual line and the pulls become partially payable as coverage
> arrives, exactly as `PullSenior` already works. That satisfies both "the claim must eventually
> mint the prize it should have minted" *and* the challenger's 2:1 premium, which the cap could
> not do together — and it removes the timing attack entirely, because no crystallize moment is
> worse than another.
>
> **Cheap interim:** refuse `Crystallize` while `reservoirR() < want` and the senior queue still
> has unpaid mass. Needs a deadline so a griefer cannot block forever, and it withholds the
> author's deposit and fee during the wait.
>
> **Also fix the flag bounty** — same defect at 1/5 the magnitude (6 weeks of drought at 30% of
> supply), uncapped, and it can co-occur with a comp on the same claim.

~~Cap comp against the court's own budget — `min(comp, k·curPeriodBudget)`~~ — and decide
whether `reservedTail` should be reclaimable at all once an entitlement is fully pulled.
**It should not**, and for a sharper reason than the M3-CRITICAL-1 overlap I originally cited:
**M:** the accrual line is *exactly tiled* (`cumAccrual − emittedTotal − R = 0.000000`), so
reclaiming a fully-paid tail hands the junior lane coin **already minted to the senior** — a
75.7% overshoot of the emission ceiling, i.e. a straight double-spend. And there is nothing to
reclaim anyway: once `cumAccrual` passes `reservedTail` the offset costs the reservoir nothing.

**The interaction with item 1c is much weaker than stated here.** That "**11.1× improvement**"
is the **450 bps** figure with the collateralization floor *inert*. At the 600 bps actually
proposed it is 8.33× inert, and **with the floor binding — the large-draw regime, i.e. the one
that matters — it is 1.78×** (**M:** comp 22.4%·X̄). So cutting the bond does **not** fix most of
this for free, and this item is *more* necessary than the original text implied, not less.

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
| 120_961 | 2 → **3** | false → **true** |
| 120_962 | 3 | true |

> **CORRECTED — `GAMETHEORY.md` §12.10.** The threshold is **`votingBlocks + 1`**, not `+2`,
> so the default misses it by **one** block. My 120_961 row was a **fixture artifact**: both my
> fixture and the shipped idiom resolve at `SkipHeights(votingBlocks + 1)`, but the *earliest
> legal* resolution is `+votingBlocks`, since the governor closes at `opened + VotingBlocks`.
> A later audit pinned the window directly and measured 120_961 → 3 rounds.
>
> **Consequence for the fix:** the deploy invariant proposed below is **over-strong by a full
> `votingBlocks`**. The real requirement is `W > votingBlocks·(maxFailedRounds − 2)` — 120_961
> blocks (~7 days), not 241_921 (14 days). And raising `escrowMinBlocks` at all is now the
> **rejected** lever, because it taxes an honest *disputed* claim from 14 to 21 days of frozen
> winning-side principal. Use the defaulted-verdict-only window in §12.10 instead.

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

Floor becomes exactly X̄ at every claim size; **the entire existing suite passes unmodified
(ok . 7.53s)**, confirmed twice.

> **THREE CORRECTIONS — `GAMETHEORY.md` §12 and the C2 audit.**
>
> 1. **"The robbed pool clears it alone" is unreachable by construction.** `VoteDispute`
>    refuses every *participant*, and a staker record persists across withdrawal — **M:** a
>    victim holding **100% of the robbed pool** is refused outright. The quorum can only ever
>    be met by **non-participant** weight. Victims can *fund* a defence and never *vote* one.
>    (Independently confirmed by the COVID scenario, whose first draft the node rejected for
>    exactly this — see `scenarios/covid.py`.)
> 2. **The relaxation is 5.01×, not ~10×, and the landing point is X̄, not X̄/2.** **M:** at 1%
>    of supply the floor goes 2000.000000 → 399.000000 CC. An attacker voting `yes` unopposed
>    needs `cast ≥ floor = X̄`. I overstated my own trade by 2×.
> 3. **"The attacker's bond burns on an uphold" mis-prices the trade — it is not a gamble.**
>    With `yes > 0, no = 0` the threshold is trivially met, and an uphold requires an opponent
>    to turn out, which is this item's own premise. **M:** an attacker holding **1.25% of
>    supply** flips a true answer to an overturn with a cash swing of **−39.90 → +159.60 CC**,
>    bond returned whole, comp minted, the honest answerer's bond burned. Profit per unit of
>    required weight is a flat 0.4 at every claim size and repeats on every claim.
>
> **The trade still favours relaxing** — the snipe it fixes is currently *free* — but it is
> bigger than stated. **And the patch must ship with a second change:** it silently re-keys the
> credential bar (`yes >= floor/4`, dispute.gno:321) from a documented ~1.25% of supply to X̄/4,
> a 5.01× cut. **M:** two socks totalling 1.125% of supply mint an `AnswerRecord`; three such
> points buy the 24h answer-priority window. Re-anchor that bar to supply.
>
> **Also:** delete the arm rather than gate it (the gated form makes both `:580-582` and the
> `:607-609` clamp provably dead, 88/88 rows), and **`mustElectionInvariants` cannot be reached
> by this clause at all** — `electionFloor` is 5% of *votable* with no X̄ arm. `qualityBars`
> needs no change either, though the two lanes then genuinely disagree in the band this fixes.

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

**Ruled out: re-answerability.** Three independent audits, and the third reason is decisive.

It cannot re-freeze the conviction pin without arming three dormant clamps
(answer.gno:130-147 names them); measured, a re-freeze would let the incumbent frozen pool
farm conviction **1009× over six weeks on a pool nobody can enter to dilute or exit to
escape**, re-pinning `xBarFrozen` off a ring `staleBy = 2016` buckets that still reports
`mature = true` (**+50% from staleness alone**). It cannot reopen staking without making one
claim a ~51× risk-free emission faucet. It cannot get the calendar it needs (the 12-week
clock never pauses, and extending it panics at deploy per court.gno:224-229). A second
answer inherits answer #1's `slotConsumed`/`slashLevied` latches, making every answer after
the first **structurally unflaggable and unslashable** — the exact immunity purchase v0.47
and v0.50 closed.

**And the trichotomy is exhaustive — there is no correct implementation.** Either the
re-answer resets `provisional`, in which case the claim is **permanently bricked 72 hours
after any undisputed re-answer, with no adversary at all**: measured 7 of 7 exits refuse
(`OpenDispute`, `SettleUndisputed`, `Finalize`, `CloseDeadClaim`, `Crystallize`,
`WithdrawStake`, `Unstake`), 30,000 CC of honest principal locked in `c.locked` forever, no
admin and no upgrade path (court.gno:266-267) — and "nobody disputes" is the **modal**
outcome, which dispute.gno:519-521 names as the lane's known failure mode. Or it keeps the
old `provisional`, in which case it is a no-op that only burns the new answerer's record. Or
it resets `provisional`/`round`/`failedRounds`/`escrowUntil` together, in which case it
works — and hands a sniper **unlimited retries**: 11 rounds fit inside a 12-week life, so
per-claim destruction probability goes from 19% to **89.3%**.

There is no fourth option, and none of the three is shippable.

### Sequencing constraint — do not reorder these

**`court.gno:194` must not be deleted before the collateralization floor is re-keyed to both
sides.** Measured: as written, deleting it drops the snipe's break-even claim age from **31
weeks** (unreachable inside a 12-week life, so harmless) to **2.80 weeks** (reachable on most
claims). The invariant is mislabelled — its comment says it covers "maximum undisputed
extraction", but PLAN.md:718-725 already retracted that derivation; what it actually buys is
**anti-snipe** cover, and via dispute.gno:131 it is also what makes the dispute bond
independent of the answerer. Re-key the floor first (item 1c), then rescope `:194` and `:227`
in the same commit.

---

## 5. Owner / other session

- Add `chat_all.js` to `CHECKS` in `web/tests/browser/run.js` (untracked, theirs).
