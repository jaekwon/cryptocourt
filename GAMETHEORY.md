# GAMETHEORY.md — the answer-bond redesign, stated for audit

**Status: PROPOSED, NOT AUDITED.** Written before the audit deliberately, so the audit has a
fixed target and cannot be accused of grading a moving one. Every number below is either
measured (marked **M**) or read out of the source (marked **S**). Nothing here is
implemented.

The document exists to be attacked. §9 lists what must be proven and §10 lists what I
already know is unresolved.

---

## 1. What problem this solves

Two owner constraints are fixed and non-negotiable:

1. **A 50% answer bond is unacceptable.** It is impossible to meet.
2. **A single address bonding an answer is unacceptable.**

Two regulatory constraints are equally fixed (`REGULATIONS.md:18-21` — no U.S. prediction
market has ever been held "not gambling" on the merits by relabeling; the two proven escapes
are (a) become a regulated derivative, or (b) remove the wager substance; **this design takes
(b)**):

3. **Staker principal returns 1×, always.** No consideration risked upon the outcome.
4. **The staker prize is MINTED, never counterparty-funded.** A bilateral event-contingent
   payment is a CEA swap in exclusive CFTC jurisdiction, and `REGULATIONS.md:36-38` records
   that pure P2P does not help — Intrade was killed anyway.

Constraint 4 forces a fifth, structurally: **minting must carry anti-fraud collateral**,
because the act of releasing minted coin is what a liar monetizes. So the bond cannot be
zero. The design space is therefore: *small, splittable, and correctly targeted.*

## 2. The diagnosis in one paragraph

The 50% bond is priced against the wrong quantity and defends against the wrong failure. It
was derived (`court.gno:194`) from `capBonus`'s **ceiling** — `tier/2 × stake` = 50%·X̄ —
rather than from the **realizable** draw, 19.278%·X̄. `PLAN.md:718-725` already retracted
that derivation in the repo's own words ("upper-bounds it with ~5× slack"). The bond level
that actually closes the snipe at every claim age is `maxMidGrossBps` = **1928 bps** — a
number `court.gno:224-226` **already computes** (S). So 5000 is **2.59× oversized** against
its real job. Meanwhile the snipe it is paying for is not an economic failure at all: it is a
**turnout** failure with a threshold at 5% of court supply (§4.2), and the bond does nothing
to that threshold.

## 3. The solution, as seven changes

Ordered by severity, not by build order. **Build order is §8 and it is not this order.**

### C0 — Cap senior comp against the court's budget

**The bug it fixes is the largest in the system and needs no attacker.** `reservedTail` and
`juniorReserved` are strictly monotone: each has **exactly one write site in the entire
non-test realm, and both are additions** (S — `emission.gno:172`, `emission.gno:197`).
`comp` is a *senior* entitlement, so every comp ever paid permanently shrinks
`reservoirR() = cumAccrual − reservedTail − juniorReserved` for every later claim in that
court. And comp is unbounded relative to the budget: `min(2×ownBond, 80%×burned)` lands at
**40%·X̄** at a 50% answer bond (S — `dispute.gno:370-381`).

**M:** 300,000 CC court, `curPeriodBudget` = 1,132 CC/week. One overturn round moved
`reservedTail` 0 → 12,001,200,000 and the reservoir 13,481,280 → **0** — **ten weeks of the
whole court's emission, consumed by one comp.** `reserveJunior` then clamps the draw to zero
*silently*, by design (S — "Clamps to R — never aborts a shared settlement path (F4)",
`emission.gno:186-199`), and `Crystallize` is permissionless after the grace week, so **an
attacker picks the moment** the zero becomes permanent.

**Change:** `comp = min(compAmount(ownBond, burned), compBudgetX · curPeriodBudget)` with
`compBudgetX` a new calibrated constant. Do **not** make `reservedTail` decrementable —
monotonicity is what keeps seniors and juniors tiling a disjoint number line, per the
M3-CRITICAL-1 comment at `emission.gno:162-170`.

**Interaction that matters:** comp scales with the answer bond, so C3 alone improves this
**11.1×** (40%·X̄ → 3.6%·X̄). C0 is still required, because a cap is the only thing that makes
the property hold *independently* of the bond constant.

### C1 — Make `provClose` reachable

`votingBlocks` and `escrowMinBlocks` are both **120_960** (S — `court.gno:283,288`), and
`escrowWindow` returns `escrowMinBlocks` exactly whenever `extraDays` rounds to zero —
guaranteed on any court with `minted == 0` (S — `dispute.gno:630-637`,
`p/curve/curve.gno:183`). `escrowUntil` is set once at the first resolution and never
recomputed (S — `dispute.gno:344-349`), and each round burns a full `votingBlocks` because
`ResolveDispute` refuses while the governor's proposal is active (S — `dispute.gno:216-218`).

So round 3 cannot open: `failedRounds` caps at **2** against `maxFailedRounds = 3`, and
`provCloseClaim` is **dead code** on a default court. Meanwhile the *first* failed round has
already set `cs.provisional = cs.answer` (S — `dispute.gno:260-263`), so **apathy resolves
the claim in the liar's favour** — the exact outcome that branch's own comment forbids.

**M, twice, by two independent staged copies with no shared fixtures:** 120_960 → 2 rounds;
120_961 → 2; 120_962 → 3. And from the other direction, `escrowUntil 727324` vs
`now 727325`. The default misses the threshold by two blocks.

**M cost:** the honest disputer burned **210.000000 CC** across two failed rounds on a claim
with X̄ ≈ 700 CC, and the false answer still stood.

**Change:** raise `escrowMinBlocks` so `maxFailedRounds` rounds fit, **and** add the deploy
invariant `escrowMinBlocks > votingBlocks·(maxFailedRounds−1)` regardless of which lever is
chosen. The invariant is the part that stops this from silently returning.

### C2 — Gate `quorumFloor`'s supply arm on the claim actually being that big

`quorumFloor` maxes its X̄ arm against **5% of court supply** (S — `dispute.gno:580-582`),
but the prize is denominated in **claim stake**. Below X̄ = 5%·supply the robbed pool
**cannot reach the bar even voting unanimously at any concentration**.

**M** (supply 40,000 CC):

| honest pool | % supply | X̄ | floor | pool weight | clears alone? |
|---|---|---|---|---|---|
| 400 | 1% | 303 | 2,000 | 400 | **no — 6.6× short** |
| 1,200 | 3% | 1,103 | 2,000 | 1,200 | **no** |
| 2,000 | 5% | 1,903 | 2,000 | 2,000 | yes |
| 4,000 | 10% | 3,903 | 3,903 | 4,000 | yes |

**The threshold is exactly 5% of supply and it is entirely independent of the answer bond** —
which is the proof that 50% buys nothing here. `dispute.gno:600-609` already states the
consequence in its own words: *"an unreachable quorum does NOT mean 'no verdict' … the bar
hands the decision to the party it exists to police."*

**Change**, one clause:

```go
if fivePct := mulDiv128(supply, quorumSupplyBps, grc20votes.Bps); fivePct > floor && xbar >= fivePct {
```

**M:** floor becomes exactly X̄ at every claim size; the robbed pool clears it alone in all
five rows; **the entire existing suite passes unmodified (ok . 7.53s), zero fixture edits.**

**The trade, stated rather than buried:** it lowers the weight for a *malicious* overturn of a
small claim from 5%·S to ~X̄/2 (~10× on a claim at 1% of supply). Not free — the attacker's
bond burns on an uphold and the answerer is comped 2× — and a whale at 5%·S can do it today
anyway. Since the snipe is currently **free** while a false overturn costs a bond, the trade
favours relaxing. But it is a trade.

**Knife edge:** even patched, `floor = X̄` while a fully-staked pool weighs `X̄ − ε`, so it
falls short by exactly the sniper's dust. One abstain from anyone fixes it
(`cast = yes+no+abstain`, S — `dispute.gno:222`). **Corollary: the coordination task is
turnout, not agreement** — a rescue needs one *yes* plus enough *abstains*, so an indifferent
whale can enable it without forming an opinion.

### C3 — Re-key the collateralization floor to BOTH sides, and drop the flat base to 600 bps

**This is the change that answers constraint 1, and the re-keying — not the number — is what
does the work.**

`answer.gno:148` reads `cs.sideConv(verdict)` — the **answered** side. So a sniper who stakes
dust on the side they declare has an inert draw arm and pays only the flat base.

**M** (X̄ ≈ 1001 CC, cold, 11-week claim, 450 bps base):

| scenario | declared conv | opposing conv | floor today (answered) | keyed `max` |
|---|---|---|---|---|
| **snipe** (dust declared) | 0.07 | 70.13 | **45.04** (flat only) | **112.20** |
| honest majority (90%) | 63.15 | 7.01 | **101.03** | **101.03** |
| honest contrarian (10%) | 7.02 | 63.11 | **45.00** | **100.98** |
| even split | 35.08 | 35.06 | **56.13** | **56.13** |

Three consequences:

- **Today's keying is backwards, not merely blind.** It taxes the honest majority answerer
  (101) and *exempts* the sniper (45).
- **`max(yesConv, noConv)` is free for every non-contrarian answer** — bit-identical for the
  majority and even-split rows (**M**). It is the same tax with the sniper's exemption removed.
- **It closes the snipe by construction**: the floor becomes 1.6× the *destroyable* draw, so
  destruction leverage is capped at **0.625 at every age and every rate**, with an analytic
  ceiling of **30.845%·X̄** = `slashDrawBps × maxMidGrossBps / 10000` — the quantity
  `court.gno:227` already evaluates (S).

**Why 600 bps and not 450:** at `answerBondBps == slashXBps == 450` exactly,
`court.gno:232` holds with **zero margin** and the settle-time reserve equals the *entire*
bond, so nothing returns at settle (**M**). 600 restores the settle refund and leaves margin
for any later `slashXBps` rise.

**Without re-keying, 450 makes the snipe profitable** — leverage **1.55×** (cold, 11wk) to
**4.28×** (hot, 12wk), break-even claim age 2.80 weeks (**M**). That is why C3 is one change
and not two.

**The honest limit, stated plainly because no formula fixes it:** an honest contrarian answer
is *indistinguishable in shape* from a snipe — dust on the declared side, large opposing
pool. **No bond sizing can separate them.** Max-keying is strictly cheaper than the status quo
everywhere (contrarian: 101 vs **500** today, ~5× better), but it prices contrarian truth in
proportion to how wrong the crowd is, up to 30.845%·X̄. That is the real cost of the
bond-sizing route and C2 is what makes it tolerable.

### C4 — Syndicate BOTH bonds

**Answers and disputes are each a single address today.** `cs.answerer = who` +
`mustSpendable(c, who, bond)` (S — `answer.gno:155-164`); `cs.disputer = who` +
`mustSpendable(c, who, bond)`, with refunds and the 2:1 comp all returning to that one
address (S — `dispute.gno:142-153, 234, 287`).

**The dispute side needs it more.** **M:** a victim holding **100% of the robbed pool** had
100 CC spendable against a 380.60 CC dispute bond and `OpenDispute` was **refused** by
`lock.gno:73` — because the bond comes from *spendable* CC while the victim's capital is
locked in the very stake being defended. And the defender's price is
`min(20%·X̄, 40%×answerBond)` (S — `dispute.gno:130-136`), i.e. 40% of the *answerer's* bond:
**a 50% answer bond makes self-defence 11.1× more expensive** (380.60 vs 34.25 CC).

**Change:** a per-claim pull-settled pool for **each** bond — one for the answer, one for the
dispute — modelled on the existing `carrotPool`/`PullCarrot` pattern (S —
`crystallize.gno:113,143,286-352`), which exists because `governor.gno:980-983` forbids
unbounded iteration. Declarant of record stays a single address in both lanes; the *funding*
becomes plural in both. **No path may iterate either pool.**

#### C4a — the answer bond

**Two one-liners without which this is worse than not doing it:**

1. **`isParticipant` must include co-funders** (S — `dispute.gno:558-564` checks author,
   answerer and staker records only; **M:** `isParticipant(co-funder) = false`). Otherwise
   backers vote on the verdict *and* the quality of the answer they funded, and pull the
   carrot.
2. **The answerer's slice and the credential must go pro-rata**, not to `cs.answerer` alone
   (S — `crystallize.gno:256`, `records.gno:31`). Otherwise the declarant keeps the 5-point
   slice, the credential and the 24h priority head start while backers carry 1/N of the bond
   — **reputation bought with other people's money.**

**Asymmetry to preserve deliberately:** credit the credential pro-rata on an uphold, but
`resetOverturned` **every** member on an overturn. That asymmetry is what stops rent-a-lead
credential laundering.

#### C4b — the dispute bond

Not symmetric with C4a, and the differences are where the bugs will be:

1. **Three disposition paths, not two.** A dispute bond can *half*-burn (failed quorum, S —
   `dispute.gno:232-239`), return whole (overturn, S — `:287`), or burn whole (uphold, S —
   `:310`). The half-burn is the novel one: **rounding must not let a syndicate extract by
   splitting.** `half := cs.disputeBond / 2` floors, so N members each halving their own
   contribution can recover more than half the pool unless the split is computed on the pool
   total and then apportioned. This is the sharpest arithmetic hazard in C4.
2. **`comp` must go pro-rata to funders, not to `cs.disputer`** (S — `dispute.gno:313`
   enqueues to `cs.disputer` alone). §4.1's entire argument is that the 2:1 comp is the
   private premium that dissolves the volunteer's dilemma — if the declarant captures it while
   funders carry the bond, C4b **inverts** §4.1 instead of extending it, and free-riding
   returns for every funder who is not the declarant.
3. **The doubling ladder is claim-scoped and must stay so.** `shift := cs.failedRounds` (S —
   `dispute.gno:137`) with the comment "a fresh disputer address cannot reset the multiplier".
   A syndicate must not become a way to re-enter at the base rate.
4. **`isParticipant` must include dispute co-funders too**, for the same reason as C4a — and
   note the existing bar is self-described as "HYGIENE, NOT A SECURITY GUARD" (S —
   `dispute.gno:176-187`), so this closes a hole that is already porous rather than a tight one.

**Why C4b is the higher-value half.** C4a lets more people *answer*; C4b lets the robbed pool
*defend itself*, which §4.2 identifies as the actual failure. The measured refusal — a victim
owning 100% of the robbed pool, unable to fund the bond because their capital is locked in the
stake being defended — is fixed by C4b and by nothing else in this document.

### C5 — A verdict round must not zero the tier it just vindicated

An ordinary overturn restores `cs.tier = tierMidX` (S — `dispute.gno:462-464`), so honest
winners are paid as if the answer had stood — **M: 4.955068 CC, bit-identical.** But
`resolveQualityRide` can set `tier = tierLowX = 0` on **the same tally that overturned the
answer** (S — `quality.gno:618`), and `crystallize.gno:83` then zeroes the entire draw
(**M: 0**). So the vote that proved the answer false simultaneously declares the claim junk.
`quality.gno:24-28` and `:639-641` argue at length that these are *different questions*.

**Change:** gate the *demotion* arm of `resolveQualityRide` on an overturn round, or require
its own mandate.

### C6 — `provClose` must pay the winners

`provCloseClaim` refunds the deposit **and** fee with the explicit comment *"provClose is not
a conclusive low — §3.1.7"* (S — `dispute.gno:385`), then sets `tier = tierLowX` and
`tierFinal = true` (S — `:390`), and `Crystallize` refuses on top (S —
`crystallize.gno:32-34`). It treats itself as not-a-low for the deposit and as a low for the
draw. Honest winners get principal at 1× and nothing else, on a claim where **nobody was found
at fault** (**M: 0**).

**Change:** pay the winners at the default MID against the standing `provisional`.

**C1 makes this path reachable for the first time on a default court, so C6 is not optional
if C1 ships.**

## 4. The game theory, as claims that can be falsified

### 4.1 There is no free-rider problem in the verdict lane

A volunteer's surplus over free-riding is `Δ = q_o·comp − q_u·b − q_f·(b/2)`. The restored
draw is common to volunteer and free-rider so it **cancels**; the 2:1 comp is a *private*
premium a free-rider does not get. The `2b` arm of `compAmount` binds at every bond level and
every X̄ (**M: 12/12 cases**), so `Δ = b·(2q_o − q_u − q_f/2)`.

**Therefore the sign of Δ is independent of both `b` and the holder's stake share.** Any
holder of any size prefers to dispute once overturn is >20% likely (>33% if the failure mode
is uphold rather than apathy — which is exactly `court.gno:75-77`'s stated "q > 1/3" bar).

**The volunteer's dilemma is already dissolved.** The blockers are capital (C4) and turnout
(C2), not incentive.

### 4.2 A one-person rescue already works today

`OpenDispute` bars only the answerer, `VoteDispute` only participants — so a disinterested
holder can post the bond **and vote in the round they opened**. **M, end to end:** one
non-participant whale (13.9% of a 72,000 CC supply) opened, voted, resolved, overturned the
snipe, recovered the bond and took **761.20 CC of comp** — 2:1 on one transaction pair,
permissionless, live today. The sniper's bond burned in full and their record reset to 0.

**So the snipe is already priced as a bounty. What fails is turnout, not the reward.**

### 4.3 The rescue reward is misallocated 99.56 / 0.44

**M:** comp to the disputer 761.20 CC; total carrot pot 3.39 CC (7%·midGross); one
20,000-CC voter's carrot 1.696 CC — a 0.0085% return on their weight. **The electorate whose
turnout makes the rescue possible splits 0.44%; the single address that posts the bond takes
99.56%.**

Structural, not a tuning miss: the pot is 7%·midGross = O(X̄) and the per-voter clamp is
`b₀/2−1` = 1%·X̄, while the bar is 5%·S = O(S). **For any claim small relative to court supply
the required turnout is unpayable by construction.** C3 improves the ratio to ~4.7% for free
(comp falls to 68.5 CC while the carrot is bond-independent); a real fix needs both the pot
and the clamp rescaled, which touches the P2 sybil-margin invariant
(`crystallize.gno:336-342`) and needs its own econ vet. **Deferred, not solved.**

### 4.4 What the bond level trades against

`CloseDeadClaim` + `crystallize.gno:32-34` mean an **unanswered** claim destroys exactly what
a **sniped** claim destroys — the whole draw, principal intact both ways (S). So:

> **The bond level trades snipe-destruction against timeout-destruction one-for-one.**

**M:** cold-start snipe tolerance is **8.82%** — roughly 1 snipe in 11 claims makes staking
worse than the external rate on a young court, because the entire cold risk premium is 9.65%
of r₀. And a young court is precisely the one with no 5%-of-supply holder watching: **the
regimes are anti-correlated.** This is the strongest argument against a low bond *without* C2
and C3, and the reason C3's re-keying is load-bearing rather than cosmetic.

Against that, the cost of 50% is **access**: an answerer must hold 50%·X̄ spendable rather
than 6%·X̄, an ~8× restriction of the eligible answerer set. Under any plausible holder
distribution that multiplies eligible answerers several-fold, so the bond is likely destroying
more via timeout than it saves via snipe on any court with a thin answerer bench.

## 5. What is explicitly NOT in the solution

- **Re-answerability / reopening a verdict. Dead, three independent reasons, trichotomy
  exhaustive.** Reset `provisional` → the claim **bricks 72h after any UNDISPUTED re-answer,
  with no adversary at all** (**M:** 7 of 7 exits refuse — `OpenDispute`,
  `SettleUndisputed`, `Finalize`, `CloseDeadClaim`, `Crystallize`, `WithdrawStake`,
  `Unstake`; 30,000 CC of principal locked in `c.locked` forever; no admin, no upgrade path,
  S — `court.gno:266-267`) — and "nobody disputes" is the **modal** outcome, which
  `dispute.gno:519-521` names as the lane's known failure mode. Keep `provisional` → no-op.
  Reset the whole round state → a sniper gets **11 retries** inside a 12-week life, taking
  per-claim destruction from 19% to **89.3%** (**M**). There is no fourth branch.
- **Loser-pays-winner, anywhere.** `REGULATIONS.md:153-160` banks "no loser-pays-winner
  transfer exists anywhere" as the fix that removed the #1 vet residual on **both** the
  gambling and CFTC axes. Every forfeiture **burns**; the prevailing party is **minted** a
  capped slice. Burn-anchored mints are self-collateralizing (nothing mints unless something
  burned, capped at 80% of it), which is why the collateral problem lives **only** in the
  junior draw.
- **Redistributing a sniper's bond to the stakers.** Makes the prize loser-funded and
  bilateral — the one thing escape (b) cannot survive.
- **A minimum stake on the declared side.** Free to a sniper: stake is no-loss, and stake
  posted at answer time accrues zero conviction before the freeze. **M: ~0.011%·X̄.** Also
  blocks the uncapitalized expert and creates the conflict `isParticipant` exists to prevent.
- **A longer settle window.** Closes nothing (detection is not the binding constraint) and
  *extends* the window during which victims' capital is frozen, since `session.gno:107` will
  not release them while `provisional < 0`.
- **A hard credential gate.** Deadlocks every new court — zero credentialed addresses, and
  `records.gno:41`'s cold-start guard covers *priority*, not eligibility.

## 6. The regulatory argument for fixing C0/C1/C2/C5/C6 before touching the bond

`REGULATIONS.md:188-201` rests on Humphrey factor 2 — prizes "amounts certain and
guaranteed" — noting variable pro-rata shares flunk it while a fixed published rate scores
better, plus *White v. Cuomo*'s predetermined-prize principle.

**A destroyed draw makes the published rate a lie**: the prize goes to zero for reasons
unrelated to the fact being adjudicated. That is a defect in the **regulatory posture**, not
only the economics, and **no bond sizing cures it** — every bond fix leaves the prize
destroyable and merely makes destruction expensive. C0, C1, C2, C5 and C6 are the ones that
make the rate true.

**Binding constraint on every fix:** the claim must *eventually mint the prize it should have
minted*. Never fund it from a forfeiture.

## 7. Sequencing — getting this backwards is worse than doing nothing

> **`court.gno:194` must NOT be deleted or relaxed before C3's re-keying lands.**

**M:** as written, deleting it drops the snipe's break-even claim age from **31 weeks**
(unreachable inside a 12-week life, hence harmless) to **2.80 weeks** (reachable on most
claims). The invariant is *mislabelled* — its comment says "maximum undisputed extraction",
`PLAN.md:718-725` retracted that, and what it actually buys is **anti-snipe** cover. Via
`dispute.gno:131` it is also what makes the dispute bond independent of the answerer.

`court.gno:227` must be **inverted, not deleted**: today it panics if the draw arm exceeds
the base bond, on the premise that the floor stays inert. Under C3 the floor binding **is**
the design, so the check becomes a sanity bound.

## 8. Build order

1. **C0** — standalone, no bond dependency, largest bug, needs no attacker.
2. **C2** — one clause, measured zero fixture churn. Verify `qualityBars`
   (`quality.gno:231-275`) and `mustElectionInvariants` first: they carry the same shape and
   were **not** tested against the patch.
3. **C1 + C6 together** — C1 makes C6's path reachable, so they must not be split.
4. **C5** — independent.
5. **C3** — re-key first, then rescope `court.gno:194` and `:227` in the same commit. 5
   shipped fixtures fail and must be re-derived, not deleted:
   `TestEconomicConstantsAreTheCalibratedValues`,
   `TestAnswerBondCapBindsWhenTheFloorIsBelowIt`,
   `TestSlashReserveDrawProportionalAtSettle`, `TestSlashIsLeviedAtMostOncePerClaim`,
   `TestOverturnBurnsTheSlashWithTheBond`.
6. **C4** — largest, last, and the only one needing new state.

## 9. What the audit must prove

1. **C3's re-keying really does bound destruction leverage below 1 at every age and rate** —
   analytically, not on one fixture. The claim is `slashDrawBps × maxMidGrossBps / 10000` =
   30.845%·X̄ is a true ceiling.
2. **C2 does not break `qualityBars` or the election lane.** Untested; same shape.
3. **C0's cap does not strand a prevailing challenger.** If comp is capped below what the
   burn justifies, does the remainder queue, expire, or vanish? An uncompensated challenger
   breaks §4.1.
4. **C4's pull settlement cannot be made to iterate**, and `Σ contribᵢ ≡ answerBond0` survives
   every partial disposition (slash carve, `unslash`, `refundSlash`, the two reserve
   retentions).
5. **C1's raised escrow does not lengthen honest claims' settlement** — the bystander test.
6. **C4 + C3 composed do not reintroduce the snipe** at 600 bps ÷ N per address. A syndicate
   is also a sybil surface: if one attacker can be N addresses, does anything in C4 give them
   something N separate answers would not?
7. **C4b's half-burn cannot be gamed by rounding.** `half := cs.disputeBond / 2` floors;
   prove a syndicate of N cannot recover more than the pool's half by splitting.
8. **C4b's pro-rata comp preserves §4.1 rather than inverting it.** If the declarant keeps the
   2:1 premium, every non-declarant funder is back in the volunteer's dilemma.
9. **Whether C2 + C3 together make C4a unnecessary**, leaving syndication needed only on the
   dispute side. C4b is wanted regardless — it is what lets the robbed pool defend itself.

## 10. Known unresolved

- **`q_o`, the probability an arbitrary court's electorate turns out.** §4.1 and §4.4 both
  hinge on it and there is no on-chain history to fit. Unmeasurable here.
- **§4.3's misallocation is deferred, not solved.** Both the pot and the clamp are O(X̄)
  against an O(S) bar; rescaling touches the P2 sybil-margin invariant.
- **The honest contrarian is unseparable from a sniper by any bond formula** (§C3). C2 is a
  mitigation, not a solution.
- **`d_eff` is a realized-mint EMA** (S — `emission.gno:117-122`), so young courts are cold
  and every alarming leverage figure presupposes a court already at its emission ceiling.
  The 8.82% cold tolerance and the 4.28× hot leverage are **never simultaneous**, which
  softens the worst case by an amount nobody has quantified.
- **`xBarFrozen` re-pins off a ring reporting `mature = true` while `staleBy = 2016`
  buckets** (**M: +50% from staleness alone**). Latent in the freshness contract,
  independent of everything above, and unowned.
- **Gas and attention cost of voting** — decides whether §4.3's 0.0085% carrot is fatal or
  merely ugly.
- **Whether the meta/appeals lane survives a 600 bps bond** end to end. The filing-vs-quorum
  invariants (`court.gno:243-261`) pass arithmetically, but the absolute-budget path was not
  exercised.
