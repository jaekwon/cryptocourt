# GAMETHEORY.md — the answer-bond redesign, stated for audit

**Status: NOT CONVERGED. C3 does not work as drafted — see §12.1, the most important finding
in this document. C0's fix was also wrong (§11.8).** Written before the audit deliberately, so the audit had a fixed target and cannot be
accused of grading a moving one. Every number is either measured (marked **M**) or read out of
the source (marked **S**). Nothing here is implemented.

The document exists to be attacked. §9 lists what must be proven, §10 what is unresolved, and
**§11 records what the audit broke** — read that first if you read nothing else.

> ### Round-1 headline: three separate errors in §C3, all now corrected
>
> 1. **Leverage is not bounded below 1.** It is `(tier + carrot)/k`, so **0.669 at MID but
>    1.294 at HIGH** — measured end-to-end at 1.2937. HIGH is reachable *on the same round
>    that leaves a snipe standing*.
> 2. **I conflated two ceilings.** `slashDrawBps × maxMidGrossBps / 10000` = 30.845%·X̄ bounds
>    the **bond**, not the leverage. Leverage contains no X̄, no age, no rate, and **no
>    `answerBondBps`** — so 450 vs 600 buys nothing on the load-bearing property.
> 3. **Re-keying the floor without the sizer leaks the collateral.** `SettleUndisputed` would
>    refund **83.83% of the posted bond within 72 hours** (**M**), because `quality.gno:531`
>    still reads the answered side. C3 must re-key **both**.
>
> Also: C3 makes the deterrent **worse than today** on its own axis — required overturn
> probability rises from **29.2% to 40.1%** — which the original draft did not state.
>
> ### Round-1 headline, part 2: C0's fix is wrong and C2's framing is wrong
>
> 4. **"Every comp permanently shrinks the reservoir" is FALSE.** `cumAccrual` is monotone and
>    *unbounded*; `reservedTail` is a high-water **cursor**, not a balance. A comp is a
>    **drought**, not a permanent tax — **M:** a bystander crystallizing after the drought is
>    paid bit-identically to the control. The bug is **timing**, and `Crystallize` being
>    permissionless is now the whole of it.
> 5. **C0's proposed cap is the wrong lever and must not ship.** **M:** it strands **73% of the
>    challenger's compensation** and moves their break-even overturn probability from 20% to
>    46.7% — destroying §4.1, the argument that there is no free-rider problem. The two
>    constraints on the constant are **mutually exclusive** above X̄/S ≈ 2.85%, and my own
>    headline example (10% of supply) is well past it.
> 6. **"The robbed pool clears the quorum alone" is unreachable by construction.**
>    `VoteDispute` refuses every participant, and a staker record persists across withdrawal —
>    **M:** a victim holding **100% of the robbed pool** is refused. The quorum can *only* be
>    met by **non-participant** weight. Victims can **fund** a defence (C4b); they can never
>    **vote** one.

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

**Change — REVISED by audit; the original cap proposal must NOT ship.** See §11.8 for the
measurements. In short: capping comp strands 73% of a challenger's compensation and moves
their break-even from 20% to 46.7%, destroying §4.1. **The senior lane already pays in full,
time-delayed, never scaled** (**M:** a 12,000 CC comp pays out to 12,000.000000 over 11 weeks).
Capping is the *only* thing that would strand a challenger.

**The defect is on the JUNIOR side, not the senior side.** Seniors are *whole but late*;
juniors are *scaled once at crystallize and final*. So:

> **Make the junior draw delayed rather than scaled.** `reserveJunior` reserves the full `want`
> on the accrual line, and the pulls become partially payable as coverage arrives — exactly as
> `PullSenior` already works.

This satisfies **both** §6 ("the claim must eventually mint the prize it should have minted")
and §4.1 (the challenger keeps the 2:1 premium), which the cap could not do simultaneously. It
also **removes the timing attack entirely**, because no crystallize moment is worse than
another. Honest cost: `bonusPaid` becomes an amount rather than a flag, and the F9 `capBonus`
interaction needs re-derivation.

**Do not make `reservedTail` decrementable.** My original reason (M3-CRITICAL-1) was right but
weak; the real one is sharper. **M:** the accrual line is *exactly tiled* —
`cumAccrual − emittedTotal − R = 0.000000` — so reclaiming a fully-paid tail hands the junior
lane coin **already minted to the senior**, a 75.7% overshoot of the emission ceiling. That is
a straight double-spend. And there is nothing to reclaim anyway: once `cumAccrual` passes
`reservedTail` the offset costs the reservoir nothing forever.

**Interaction, corrected:** §C3 does *not* improve this 11.1×. That figure was computed at 450
bps with the floor inert. **With the floor binding — the regime with the largest draws, i.e.
the one that matters — the improvement is 1.78×** (**M:** comp 22.4%·X̄). So C3 barely helps
here and C0 is *more* necessary than the original draft implied, not less.

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

**M, confirmed twice:** floor becomes exactly X̄ at every claim size; **the entire existing
suite passes unmodified (`ok . 7.55s`), zero fixture edits**, and so do `govern`, `offerer`,
`kourtv1` and all seven `p/kourt/*`. **Bystander verified:** an ordinary undisputed claim at 1%
and 10% of supply settles with every schedule stamp and every payout **bit-identical** across
both trees; the fixture asserts its own precondition (`SettleUndisputed` refused at
`settleDelay − 1`), so it is not vacuous.

**Three corrections from the audit — the change is right, my description of it was not:**

1. **It DELETES the supply arm, it does not gate it.** **M:** across 88 rows the patched
   `quorumFloor` equals `max(1, min(X̄frozen, votable/3))` with **zero divergences**, and it
   holds analytically too. So **both `:580-582` and `:607-609` become provably dead code**.
   **Delete them and rewrite the comment** rather than adding a gate that leaves two dead
   blocks and a page of prose describing behaviour that no longer runs.
2. **"The robbed pool clears it alone" is unreachable by construction, and that column of the
   table above is wrong.** `VoteDispute` refuses every participant (S — `dispute.gno:188`) and
   `isParticipant` is true for anyone with a staker record on *either* side — records persist
   across withdrawal. **M:** a victim holding **100% of the robbed pool** is refused with *"a
   participant may not vote on their own claim's verdict"*. **The quorum can only ever be met
   by non-participant weight, whose size is unrelated to X̄.** So C2 lowers the bar *for
   outsiders*, which is still the fix — but victims **fund** a defence (C4b) and never **vote**
   one. §4.2's one-person rescue was already a *non-participant* whale; that is not an accident.
3. **The relaxation is 5.01×, not ~10×, and the landing point is X̄, not X̄/2.** **M:** at 1% of
   supply the floor goes 2000.000000 → 399.000000 CC. An attacker voting `yes` unopposed needs
   `cast ≥ floor = X̄`, full stop. I overstated my own trade by 2× — conservative direction, but
   wrong.

**The trade is WORSE than I stated.** **M:** an attacker holding **1.25% of supply** — a
*quarter* of the old 5% bar — flips a true answer at 1% of supply from failed-quorum to
**overturn**, unopposed: cash swing **−39.90 → +159.60 CC**, own bond returned whole, comp
minted, the honest answerer's 199.50 CC bond burned and their record reset. **And it is not a
gamble:** with `yes > 0, no = 0` the threshold is trivially met, so my "the attacker's bond
burns on an uphold" mis-priced it — an uphold requires an opponent to turn out, and *turnout
failing is this section's own premise*. Profit per unit of required weight is a flat 0.4 at
every claim size, and voting consumes no weight, so it repeats on every claim with X̄ ≤ the
attacker's holdings. Nobody is made whole: the answerer loses the bond, the true side's stakers
lose the draw, every holder pays the comp dilution. **The trade still favours relaxing — the
snipe it fixes is currently free — but it is bigger than the original draft admitted.**

**A hazard the original draft missed entirely: the patch silently re-keys the credential bar.**
`dispute.gno:321` is `yes >= floor/4`, documented as costing *"~1.25% of court supply"*.
Patched it becomes **X̄/4**. **M, end to end:** two socks totalling 450 CC of a 40,000 CC supply
(1.125%), with only 100 CC on the adversarial side, flip the branch from failed-quorum to
uphold and `credEligible` from false to **true**, minting an `AnswerRecord` of 1. Three such
points buy the 24h answer-priority window. **Fix, tested:** re-anchor the credential bar to
supply — `yes >= credWeightFloor(c)/4` with `credWeightFloor = mulDiv128(PastTotal(Epoch()-1),
quorumSupplyBps, Bps)` — keeping the documented 1.25% price while retaining the quorum
relaxation. Suite green, zero fixture edits.

**§8's claim that `qualityBars` and `mustElectionInvariants` share this shape is wrong for the
election lane.** `electionFloor` is 5% of *votable* with **no X̄ arm**, and
`mustElectionInvariants` compares only package constants and never reads a claim — the C2
clause cannot reach either. **M:** `qFullBar`, `qDemotionBar`, `electionFloor` and
`electionBond` are identical across trees; all ten `TestElection*` fixtures pass. But the two
lanes now **genuinely disagree in the band C2 exists to fix**: at X̄ = 1% of supply the verdict
quorum is 399 CC while the quality `fullBar` stays 2000 CC. That is defensible — the slash
deterrent *keeps* its 5%-of-supply anchor, which is good — but it makes
`court.gno:250-254`'s comment ("prices filing above winning the vote") stop being true of the
verdict lane.

**Knife edge: real, and the act it depends on is UNPAID.** **M:** X̄ = 399.000000, patched floor
= 399.000000, a rescuer at 398.999999 — one base unit short, the sniper's dust — plus **one
abstain of 0.000001 CC** lifts `cast` to exactly 399.000000 and the overturn lands
(`shortBy = 0.000001`; on baseline `shortBy = 1600.950001`, hopeless). **But `PullCarrot` pays
only voters whose choice equals `cs.carrotChoice`**, so the abstainer whose dust made the
quorum reachable is **REFUSED** — *"the carrot pays with-verdict voters of the deciding
round"*. The single action the knife edge depends on is the one action the incentive system
explicitly does not pay for, and it must come from a *second, non-participant* address. The
same fixture reproduces §4.3's misallocation at its extreme: **0.002117 CC to the voter against
159.60 CC of comp to the disputer — 75,400×.**

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
- **It closes the snipe at MID and NOT at HIGH.** ← *corrected by audit; original draft
  claimed "capped at 0.625 at every age and every rate", which was wrong twice.* The correct
  derivation is in §11.1. Leverage is `(tier + splitCarrot/100) / (slashDrawBps/10⁴)` =
  **0.669 at MID, 1.294 at HIGH** (**M: 1.2937 end-to-end**). The 30.845%·X̄ figure is the
  ceiling on the **bond**, not on leverage.

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

**Scope correction from the audit — this argument covers OPENING a dispute, not carrying it.**
`OpenDispute` bars only the answerer (S — `dispute.gno:79-83`), so a victim may post the bond.
But `VoteDispute` bars every *participant* (S — `:188`), and `isParticipant` is true for anyone
with a staker record on either side, which **persists across withdrawal**. **M:** a victim
holding 100% of the robbed pool is refused. So the quorum that decides the round can only be
met by **non-participant** weight. A victim can **fund** their own defence and never **vote**
it — which is why C4b matters and why §4.2's working rescue was a non-participant whale.

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

1. **C2 — promoted to first.** ← *reordered by audit.* Two measured patches, both green with
   zero fixture edits, and it no longer depends on anything. Ship as: **delete** `:580-582` and
   `:607-609` (provably dead under the patch, 88/88 rows) and rewrite the comment; **plus**
   re-anchor the credential bar to supply, or the patch silently cuts its documented
   1.25%-of-supply price by 5.01×. `qualityBars` needs no change and the election lane cannot
   be reached by the clause — both verified, all ten `TestElection*` green.
2. **C0 — demoted, and rescoped.** The cap must **not** ship (§11.8: it strands 73% of the
   challenger's comp and destroys §4.1). The real fix is *make the junior draw delayed rather
   than scaled*, which is a larger rework than the draft assumed. The **cheap interim** is to
   refuse `Crystallize` while the reservoir cannot cover `want` and senior mass is unpaid.
   Whichever ships, also cap or delay the **flag bounty** — it has the same defect at 1/5 the
   magnitude and C0-as-drafted missed it.
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

---

## 11. AUDIT ROUND 1 — what broke

Isolated shadow copy; the working tree was verified byte-identical before and after (133
files, `git status` empty both times). Baseline green at `ok . 7.17s` before patching.

### 11.1 The leverage ceiling — FALSIFIED, and the correct bound

**Counterexample, measured end to end.** Twin claims in one court, 11 weeks at the hot rate
ceiling, X̄ = 1001.67 CC, 100% NO / 0 YES, sniper declares YES. Honest twin promoted to
`tierHighX` by a 5%-of-supply flag vote; precondition `tier == tierHighX` asserted and the
budget clamp verified not binding:

```
DESTROYED = 361,015,973   bond posted = 279,046,163   LEVERAGE = 1.2937
```

**The correct derivation.** Destroyed prize (`crystallize.gno:63-90,113`; deposit and fee
refund on both paths, principal is 1× on both, `capBonus` never binds):

```
Destroyed ≤ (tier + splitCarrot/100) · mg_opposing
bond      ≥ (slashDrawBps/10⁴) · mg_max  ≥  1.6 · mg_opposing
L = Destroyed/bond ≤ (tier + splitCarrot/100)/(slashDrawBps/10⁴)
                   = 1.07/1.6 = 0.669  (MID)      = 2.07/1.6 = 1.294  (HIGH)
```

**Three things follow that the original draft got wrong:**

1. The bound contains **no X̄, no claim age, no rate, no d_eff, no pool split, and no
   `answerBondBps`**. It is `1/k`, tier- and carrot-adjusted. So "below 1 at every age and
   rate" is provable *at MID* — but for a reason unrelated to `court.gno:227`, which I cited
   as the proof.
2. My 0.625 **omitted the carrot**, which is tier-invariant `7%·midGross` and *is* destroyed.
   The real MID figure is 0.669, and the bound is **exactly attained**, not merely respected.
3. **HIGH is reachable on the same round that leaves the snipe standing** — the shipped
   `TestMandatedHighRidePromotesOverAStandingMid` promotes via a dispute **uphold** ride. The
   band X̄ ∈ [0.10%, ~1.3%] of supply reaches L > 1; above ~1.3% the `curPeriodBudget` clamp
   pulls it back under, which is luck rather than design.

**Fix (chosen): freeze the tier the floor was sized against**, so a post-answer promotion to
HIGH cannot double a prize the bond was never collateralized for. Rejected alternative:
`slashDrawBps > 20,700` bounds L below 1 at HIGH but costs a ~42.4%·X̄ worst-case bond,
undoing most of C3's access gain — which is the whole point of C3.

**Sweep, 864 points** (ages 1/2/4/8/11/12 wk × cold and hot-at-ceiling × splits 50/50, 90/10,
99/1, 9999/1 × X̄ ∈ {1 CC, 1k, 1M} × bps ∈ {450, 600, 5000} × tier), using the realm's own
`slashSizeAt`/`convToCC`/`mulDiv128`:

| bps | keying | tier | worst L | required overturn prob. |
|---|---|---|---|---|
| 5000 | answered (**today**) | MID | 0.413 | **29.2%** |
| 600 | answered | MID | 3.437 | 77.5% |
| 450 | answered | MID | 4.583 | 82.1% |
| **600** | **max(both)** | MID | **0.669** | **40.1%** |
| 450 | max(both) | MID | 0.669 | 40.1% — *bps-independent* |
| **600** | **max(both)** | **HIGH** | **1.294** | **56.4%** |

### 11.2 Re-keying the floor without the sizer leaks the collateral — NEW BUG, in my proposal

C3 as drafted re-keys the **floor** (`answer.gno:148`) but leaves the **sizer**
(`quality.gno:531`) reading `cs.sideConv(int(cs.answer))`. **M:** `SettleUndisputed`
(`session.gno:74-86`) then refunds **233,849,858 of a 278,924,857 bond — 83.83% — within
72 hours**, retaining only `slashSizeFor`. And `votingBlocks` (7 d) > `settleDelay` (72 h), so
no flag can have resolved by then.

This is precisely the drift `quality.gno:518-521` says `slashSizeAt` exists to prevent: *"two
parallel arithmetic paths that a drained pool can pull apart."* **C3 must re-key both, in one
commit**, or the collateral it appears to post evaporates before it can be forfeited.

### 11.3 The metric itself was wrong — the sharpest finding

**On every realized path, either destruction is zero or forfeiture is zero:**

| path | forfeited | destroyed |
|---|---|---|
| undisputed settle, no flag (**modal**) | **0** | 1.07·mg |
| undisputed + conclusive HIGH flag | **0** | 2.07·mg |
| dispute → failed quorum (×1–3) | **0** | 1.07·mg |
| dispute → **uphold** | **0, plus comp MINTED to the sniper** | 1.07–2.07·mg |
| dispute → overturn | whole bond (**M:** 280,953,112 of 280,953,112 burned) | **0 — draw restored** |
| undisputed + slash-grade LOW flag | 450 bps·X̄ | 0.07·mg (carrot only) |

So `destroyed/forfeited` is **0 or ∞, never a finite number > 0**. The only well-defined
quantity is destroyed / bond *posted* — a **collateralization ratio**, not a payoff ratio.

**Consequence: C3's deterrent routes entirely through the dispute lane's whole-bond burn**,
with expected value `P(overturn) × bond`. That independently confirms §4.2 and §4.4 — the
failure is **turnout, not incentive** — and it means **C1, C2 and C4b outrank the bond
constant.** It also means C3 is a **regression on the deterrent axis**: required overturn
probability rises from 29.2% today to 40.1%. Better than 600-unre-keyed by 37 points; worse
than the status quo.

### 11.4 Attacking `max` — no manipulation found, and it self-defends

`max ≥ mg_opposing` unconditionally, so the bound cannot be broken by choosing which side is
the max. **M**, five plays against an identical honest pool (8 wk, hot):

| play | bond | max side | L at MID |
|---|---|---|---|
| dust-declare | 200,410,022 = 1.6·mg_NO **exactly** | NO | 0.669 |
| 20k CC on the declared side, 1 block before | 460,099,999 | NO | 0.291 |
| 10k CC on **both** sides | 460,099,999 | NO | 0.291 |
| 20k declared, held 1 day, then **unstaked** | 860,119,999 | NO | 0.158 |
| 6k declared for the whole life → **max = sniper's side** | 1,227,686,571 | **YES** | 0.111 |

Every play *raises* the bond (2.3×–6.1×) and lowers leverage. Two structural reasons already
in source: `X̄ = max(3h trailing, lifeAvg)` is monotone in stake (S — `answer.gno:104-106`),
and conviction freezes at the answer while `Unstake` keeps it (S — `stake.gno:183-217`) — past
capital-time is not withdrawable.

### 11.5 Separability — §10 was half wrong, and the wrong half is actionable

**§10 is confirmed for any formula over (X̄, convYes, convNo).** Contrarian who staked 100 CC
early and held, vs sniper who dumps the same 100 CC one block before answering: bonds
203,117,809 vs 202,996,502 — **0.06% apart**, pure fixture noise. Unseparable, as claimed.

**But there is a fourth input no formula in the design reads: the answerer's own conviction on
the side they declare.** **M: 12,696,129 vs 13 — a factor of 976,625×, from identical
principal.** As a share of the opposing pool: 10.0% vs 0.00001%.

That signal is **capital×time-keyed** — the class `MODERATION.md`'s root principle says holds,
and `stake.gno:130-131` states it: *"moving it costs capital × TIME, and past capital-time is
immutable."*

**So §5's rejection of a declared-side requirement was wrong in two of its three reasons:**

1. *"Free to a sniper — M: ~0.011%·X̄"* — **that measurement is the reason a CONVICTION
   minimum is not free.** I measured the right quantity and drew the opposite conclusion. A
   *stake* minimum is free; a *conviction* minimum costs capital × time.
2. *"Blocks the uncapitalized expert"* — **stands.** Identical in kind to the cost max-keying
   already imposes on the contrarian.
3. *"Creates the conflict `isParticipant` exists to prevent"* — **flatly false, measured.**
   `isParticipant(answerer) = true` already, via `dispute.gno:558`'s first clause
   `who == cs.answerer`, with or without a stake record. The answerer is *already* barred from
   `VoteDispute`, `VoteQuality` and `PullCarrot`.

Other candidate signals, checked rather than assumed: **the claim's own dispute history is
definitively useless** — `cs.round`, `cs.failedRounds` and `cs.decidedRounds` are all 0 at
`PostAnswer`. **Credential works, but only across repeated play**, so §5's rejection of a hard
gate stands. **Stake-time profile is already in use** — the rings plus `lifeAvgStake` are what
make `mg` small and the floor inert after a recent pile-on.

**Revised position: an answerer-conviction minimum is the one lever that separates the honest
contrarian from a sniper.** Charging the contrarian up to 30.83%·X̄ for being right early is a
*chosen* cost, not a forced one. This is the most valuable thing round 1 produced and it needs
its own design pass.

### 11.6 The 600 bps choice — verified, three builds

- **449 bps: the realm refuses to deploy** — *"kourtv2: the flat slash arm exceeds the base
  answer bond"* (`court.gno:232`).
- **450 bps: the settle refund is exactly 0.** My claim was true in both directions.
- **600 bps: refund = 2500 bps of the bond** = (600−450)/600.

**No value dominates 600**, but two changes are recommended: **derive** it as
`answerBondBps = slashXBps * 4 / 3` rather than hardcoding, and **tighten `court.gno:232` to a
margined form** (`slashXBps*4/3 > answerBondBps`). Today `450 == 450` passes, and 450 is
exactly the value that zeroes the refund — so the invariant is one step short of catching what
I had to catch by hand.

### 11.7 Corrections to other sections

- **§C0's "11.1× improvement" is measured at 450 bps, not the 600 this settles on.** At 600
  with the floor inert it is 8.33×; **with the floor binding — the regime with the largest
  draws, i.e. the one that matters — comp is 22.4%·X̄ and the improvement is 1.78×, not 11.1×.**
  So **C3 barely helps C0 where it counts, and C0's cap is more necessary than §C0 implied.**
- **§C4b's implied 2.4%·X̄ dispute bond is 11.2%·X̄ with the floor binding** (**M:**
  112,381,244) — 1.78× cheaper than today's 20%·X̄, not 8.3×.
- **§8's "5 shipped fixtures fail" is over-inclusive by two.** Exactly three fail:
  `TestEconomicConstantsAreTheCalibratedValues`,
  `TestAnswerBondCapBindsWhenTheFloorIsBelowIt`, `TestSlashReserveDrawProportionalAtSettle`.
  `TestSlashIsLeviedAtMostOncePerClaim` and `TestOverturnBurnsTheSlashWithTheBond` **pass**.
- **§C3's "strictly cheaper than the status quo everywhere" is TRUE and provable:** C3's bond
  ≤ 3083 bps·X̄ < 5000 bps·X̄. Sweep max 3084 vs 5000.
- **`answerBondCapCC` is applied *before* the floor** (deliberate, S — `answer.gno:110-151`),
  so a court that caps to keep answers affordable has the cap silently overridden — up to
  30.83%·X̄ under re-keying, vs `max(4.5%·X̄, 1.6·mg_answered)` today. Same mechanism, larger
  magnitude. **New, unowned.**
- **A latent premise, not a demonstrated bug:** `maxTcWeeks = deadClaimTimeout/periodBlocks` is
  a *block* ratio, but the gate that fires at `answer.gno:40` is wall-clock
  (`openedAtTime + deadClaimSecs`), and `blocksToSecs` hardcodes 5 s/block with **zero**
  references to it in `mustInvariants`. The 12-week ceiling therefore scales as
  (5 s ÷ actual block time). The audit could not demonstrate divergence — gno's `SkipHeights`
  advances at exactly 5.0 s/block — so this is a **deployment premise that should be pinned**,
  not a live defect.

### 11.8 C0 — the diagnosis was half wrong and the fix was wrong

**The permanence claim is FALSE.** `reservoirR() = cumAccrual − reservedTail − juniorReserved`,
and `cumAccrual` is monotone and **unbounded**. `reservedTail` is a high-water **cursor**, not a
balance. A comp of size K is therefore a **drought of K/budget periods**, not a permanent tax.

**M**, 300,000 CC court, one real overturn at X̄ = 10% of supply (comp = 11,999.60 CC = 4000 bps
of X̄). Three structurally identical bystander claims, opened and settled together:

| bystander | winners / author / answerer |
|---|---|
| crystallized **before** the comp | `0.065186 / 0.006518 / 0.004074` |
| crystallized **inside** the drought | **`0 / 0 / 0`** |
| crystallized **after** the drought (8 wk) | `0.065186 / 0.006518 / 0.004074` — **bit-identical to control** |

So the destruction is real and *total*, but it is a **timing** bug — and `Crystallize` being
permissionless is now the entire attack, not an aggravating detail. Drought length at
1/5/10/30% of supply: **2/6/11/36 weeks** from an empty reservoir, 0/2/8/33 from a full one.

**The proposed cap works mechanically and is the wrong lever.** **M** with `compBudgetX = 3`:
the drought goes 8 weeks → 0 and the bystander is restored bit-identically. But:

| | uncapped | capped X=3 |
|---|---|---|
| comp queued to the disputer | 11,999.60 | 3,242.43 |
| ever paid | 11,999.60 | 3,242.43 |
| **LOST** | **0.000000** | **8,757.17 CC (73.0%)** |
| comp/bond | **2.000** | **0.540** |

**The remainder vanishes.** There is exactly one `enqueueSenior` per disposition and the round's
bonds are zeroed on the same tally — no residual state exists, nothing queues, nothing expires.
And the senior lane otherwise **pays in full, time-delayed, never scaled** (**M:** the 12,000 CC
comp pays out to 12,000.000000 over 11 weeks, `payableLeft = 0`). **Capping is the only thing
that strands a challenger.**

Challenger break-even under the cap, using §4.1's own algebra:

| X̄/S | comp/bond | q* (apathy) | q* (uphold) |
|---|---|---|---|
| no cap | 2.000 | **20.0%** | **33.3%** |
| 5% | 1.140 | 30.5% | 46.7% |
| 10% | 0.570 | **46.7%** | **63.7%** |
| 30% | 0.190 | **72.5%** | **84.0%** |

**Disputing stops being rational the moment the cap binds**, because the design's operating
point *is* `comp/bond = 2`. And **the two constraints on the constant are mutually exclusive**:
it must be ≤ `rMaxPeriods − 1 = 3` to protect a following claim, and ≥ `105.3·(X̄/S)/δ` to
preserve the 2:1 comp. Both hold only for X̄/S ≤ **2.85%** on a new court, **1.43%** at two
years, **0.71%** at four. No value does both for a larger claim.

**Court age moves the cliff, which the draft did not consider at all.** The budget halves every
104 weeks while comp stays 0.4·X̄, so total starvation arrives at **3.77%** of supply at week 1,
**2.68%** at 52, **1.90%** at 104, **0.95%** at 208 — so any fixed `compBudgetX` drives comp → 0
asymptotically.

**The existing suite cannot detect any of this**: every shipped dispute fixture runs at
X̄/S ≈ 0.68%, below the 2.85% cliff. The cap variant passes unmodified — which is exactly why it
looked safe.

**Two other senior consumers share the defect**, and C0-as-drafted fixed only one of three: the
**flag bounty** (up to 8%·X̄, uncapped, and it can co-occur with a comp on the same claim) has
the same shape at 1/5 the magnitude — **6 weeks of drought at 30% of supply**; the **carrot** is
~30× smaller than comp and negligible.

**Cheap interim if the junior-delay rework is deferred:** refuse `Crystallize` while
`reservoirR() < want` and the senior queue still has unpaid mass. F4's "never aborts a shared
settlement path" does **not** apply — `Crystallize` is its own entrypoint and already panics on
five preconditions, and **principal is not gated on it** (S — `session.gno:107` needs only
`verdictAt != 0`). Costs: it withholds the author's deposit and fee during the wait, and it
needs a deadline so a griefer cannot block forever.

**Operational note:** the C0 patch shifts every `dispute.gno:NNN` citation past line 397 — there
are **11 live ones** in this document (420, 440, 462, 519, 548, 550, 558, 569, 580, 600, 630).
Put new helpers at end-of-file or in `emission.gno`.

---

## 12. AUDIT ROUND 2 — the composition, and C4

Two independent shadow copies, both verified leaving the tree untouched. **The audit has NOT
converged: C3 does not work as drafted, and C4a should not be built at all.**

### 12.1 C3 does not close the snipe — it MOVES it to the dispute lane, and makes it worse

**The most important finding in this document.** Round 1 corrected the *answer* lane's bound to
`(tier + splitCarrot/100)/(slashDrawBps/10⁴)`. Round 2 applied that same corrected formula to
the lane nobody had examined. A disputer risks `min(20%·X̄, 40%·answerBond)`, and under C3 the
answer arm binds, so:

```
L_dispute = (tier + 0.07)·mg / (0.4 · 1.6 · mg_max) = (tier + 0.07)/0.64
          = 1.672  (MID)      3.234  (HIGH)
```

**No X̄, no age, no rate, no `answerBondBps`** — and **exactly 2.5× the answer lane's**, because
`disputeBondOfAnswerBps = 4000`. It holds in the flat-arm regime too (`< 1.5625`). Uniform.

**M**, on this document's own 11-week cold row (X̄ = 1000 CC, 900 YES / 100 NO, supply 70,000):

| | quorumFloor | answerBond | disputeBond | comp | `mg/disputeBond` | with carrot |
|---|---|---|---|---|---|---|
| today | 3,500 CC | 500 CC | 200 CC | 400 CC = 40%·X̄ | 0.31 | **0.338** |
| C2+C3 | **1,000 CC** | 101.03 | **40.41** | 80.83 | **1.56** | **1.672** |

**It crosses 1.** Today destruction leverage in the dispute lane is age-dependent and mostly
small; under C3 it is **constant and above 1 at every age and rate** — 5× worse on a young
claim. §11.1's tier-freeze fix does nothing here, because the disputer's bond is 40% of a bond
sized for *someone else's* exposure.

**So C3 as drafted defeats the set's headline goal.** It relocates the cheapest destruction
path, and C2 makes that lane 3.5× cheaper to enter.

**The honest fix, flagged rather than prescribed: stop keying the dispute bond on the answer
bond at all, and key it on the destroyable draw directly** — cheap on a young or small claim
where the robbed pool is poor and there is little to destroy, expensive on an old or large one.
That needs its own design pass. Note it collides with C4b: the same constant that makes
self-defence affordable is the one that makes griefing cheap.

**And §11.3's `0 or ∞` claim is wrong on one path.** **M:** a malicious overturn of a *true*
answer returned the attacker's bond **in full** (`bondDelta = 0`) and minted **400 CC of comp**
against 48.28 CC of destroyed draw. So `destroyed = 0 — draw restored` holds only when the
overturn is **correct**. On a malicious one, forfeited = 0 *and* destroyed > 0. **The malicious
overturn's payoff is the comp, not the destruction.**

### 12.2 C4a must not be built — syndication makes self-dealing profitable

**M:** `compAmount`'s two arms are not "the 2b arm binds" — they are **exactly equal by
construction**, since `2 × disputeBondOfAnswerBps = compOfBurnBps` (2×4000 = 8000). So
`comp = 0.8·A` on an overturn and `0.32·A` on an uphold, identically, at **every** bond level.

With α = the attacker's share of the answer pool, δ = their share of the dispute pool:

- overturn: net = `A(0.8δ − α)` → profitable iff **δ/α > 1.25**
- uphold: net = `A(0.32α − 0.4δ)` → profitable iff **α/δ > 1.25**

Today α, δ ∈ {0, 1}: at 1 both branches lose (**M:** −0.2A, −0.08A), and at 0 it is the intended
bounty. **Syndication opens the continuum, and every ratio outside [0.8, 1.25] is profitable
self-dealing paid for by the co-funders.** Concretely: fund half your own false answer, dupe
co-funders for the rest, overturn it yourself → **+0.3A**, with the co-funders' contributions
burning in full. The attacker picks the direction.

**There is no sybil-proof fix** — netting same-claim cross-side contributions is address-keyed,
and this repo's root principle is that address-keyed defences fall to sybils. This is enabled
specifically by **C4a**, whose benefit C3 already delivers (§12.3). **Recommendation: do not
build C4a.**

### 12.3 C3 alone fixes self-defence — §C4b's closing claim is FALSE

§C4b said the measured refusal is "fixed by C4b and by nothing else in this document." **Wrong.**
**M**, the same fixture, reproduced to the digit and then run against a real C3 prototype:

```
today:   xBar 1903.03  disputeBond 380.61  spendable 100.00  CAN SELF-DEFEND = false
C3:      answerBond0 212.36 (the FLOOR binds, not the 600)
         disputeBond  84.94                CAN SELF-DEFEND = true
```

The assertion that `OpenDispute` aborts now **fails because it succeeds**. C4b is a **tail
feature**: it is still needed at the analytic ceiling (dispute bond 234.68 CC > 100 spendable),
and nowhere else. Per-address ask at 600 bps re-keyed — median claim **0.06%–0.31% of supply** —
is a single-holder number on any real distribution.

**Also measured, against §C3's claim of universality: the re-keying is completely inert below
~4.4 weeks of claim age** (identical to the answered-side floor on a 2-hour claim, 2.48× on an
11-week one).

### 12.4 C4b has a squat attack that inverts its own purpose

**M**, against a prototype built exactly as §C4b specifies (per-claim, pull-settled, **capped at
the quoted bond**):

```
answerBond 250.00   dispute target 100.00 (4000 bps)
sniper's sybil fills the pool: total = 100.00
victim's contribution:            REFUSED (pool full)
OpenDisputeFromPool after 72h:    REFUSED
answer bond returned to sniper:   227.50
```

The answerer's second wallet fills the capped pool, never declares, and the 72h clock does the
rest. `disputeOpen` is one bool so there is no second slot; the deadline is hard;
`SettleUndisputed` is permissionless. **The trade is fixed at 4000 bps by
`disputeBondOfAnswerBps`, so C3 does not improve it at any bond level.** No such attack exists
today, because there is no pool to squat.

**Fix: the pool must be UNCAPPED**, with a bonded snapshot at commit, excess refundable at 1×,
and free pre-commit withdrawal. That converts the squat into paying for the dispute you are
trying to prevent.

### 12.5 C4b's "sharpest arithmetic hazard" — REFUTED

`Σ floor(K·cᵢ/B) ≤ K` is a theorem and `mulDiv128` floors. **M:** exhaustive over every
partition (B ≤ 30, N ≤ 4) plus **171,395** (B, ratio, partition) cases at five keep-ratios —
**zero over-recoveries** under either the per-member floor or the pool-total-then-apportion
rule. Every other partial disposition checked the same way: all safe. Error runs the *other*
way (under-payment), and the worst-case strand is N base units — a 1000-member syndicate
strands 0.000999 CC.

The only extraction is writing the refund as `cᵢ − cᵢ/2` (ceil), which lets N members each
contributing 1 unit recover 100%. **That is a one-character code-review item, not an arithmetic
subtlety**, and the existing code already has the safe form.

**But a different hazard is real:** the reserve retentions split the bond into refund + reserve
*now* and dispose the reserve *later*, so a funder's claim settles in **two tranches**. **M:** a
boolean pull latch locked funders out of the second. The latch must key on a **monotone
disposition counter**, not a bool and not the round.

### 12.6 C4b cross-round double count — the escrow asserts a bond it does not hold

**M:** round 1's already-half-burned 100 CC still counted as collateral for round 2's 200 CC
bond. `cs.disputeBond` claims 200.00, escrow backs 100.00, **short by 100.00** — and the second
funder's pull then dies on the token ledger's own floor at the exact predicted site
(`panic: grc20votes: insufficient balance`). A co-funder also **voted on the verdict it funded:
ACCEPTED.**

**Contributions must be round-scoped in the dispute lane.** This is the invariant with no
current expression anywhere in the realm:

> **I4 (escrow solvency)** `escrowBalance ≥ answerBond + pendingSlash + deposit + fee +
> Σ_open poolTotal + Σ_undisposed (refundPool + excess)`

### 12.7 `isParticipant` must be SPLIT, not extended — 5 sites, two meanings

**M:** `isParticipant(DISPUTER) = false` today — the address posting the *entire* dispute bond is
not a participant. Grepped, exactly **5** call sites, and they do not want the same predicate:

| site | function | with co-funders added |
|---|---|---|
| `dispute.gno:188` | `VoteDispute` | **must add** (exclusion) |
| `quality.gno:194` | `VoteQuality` | **must add** (exclusion) |
| `crystallize.gno:302` | `PullCarrot` | **must add** (exclusion) |
| `crystallize.gno:42` | `Crystallize` grace week | **grants** the A13 privilege |
| `dispute.gno:444` | `Finalize` grace week | **grants** the A13 privilege |

So: `isExcludedVoter` (add co-funders) and `isGraceInsider` (decide explicitly) — exactly the
split the `slotConsumed` comment warns about for its own seven readers. The election and meta
lanes have no `isParticipant` use and need nothing.

On "HYGIENE, NOT A SECURITY GUARD": that makes this **more** urgent, not less. Today the bar is
porous to a sybil who never staked — free but *weightless*. C4 makes it porous to addresses
holding real, at-risk capital pointed at one outcome. Different class.

### 12.8 §C4a's credential asymmetry is a court-wide DoS, and "pro-rata" is undefined for it

**M:** `priorityGateActive` requires `qualifiedCount >= 3`. After three members reach score 3 the
gate is on; **one reset turns it off for the entire court** (`qualifiedCount = 2`). So §C4a's
"`resetOverturned` every member" makes one overturn of a 3-qualified syndicate a **court-wide
DoS** — and per §12.2 the attacker can run it at a profit. Re-arming costs nine
contested-and-upheld wins.

And `score` is an `int` with a hard threshold at 3, so **"pro-rata" is not defined for it**. The
naive +1-to-everyone mints N qualified addresses off one uphold, and `mayAnswerInPriority`'s
one-active-claim rule is **per address**, so N members hold N simultaneous priority claims —
precisely the "no flywheel blanketing" `records.gno:8-9` exists to prevent.

**Revised recommendation, replacing §C4a's asymmetry: credential credit and reset both apply to
the DECLARANT ONLY; co-funding is credential-neutral in both directions.** That removes the DoS
and the inflation, and blocks rent-a-lead laundering *more* strongly than resetting does —
capital simply buys no credential.

### 12.9 Pro-rata comp must be one entitlement, not N — real gas measured

`enqueueSenior` does a bptree `Set` + a `chain.Emit` per beneficiary. Resolve-time fanout is the
forbidden shape. **M** (filetest-metered; the Test-function GAS sum was bit-identical at N=1 and
N=50000, so it cannot price this):

| N | gas | storage | marginal gas/member |
|---|---|---|---|
| 64 | 9,092,801 | 107,344 b | 150,849 |
| 1024 | 177,657,803 | 1,601,216 b | 179,282 |
| 2048 | 381,835,613 | 3,206,380 b | 199,392 |

Block `MaxGas` is 3,000,000,000, so N=2048 is **12.7% of an entire block**, and the repo's own
150M-gas discipline is exceeded at **N ≈ 900**. Storage is ~1,560 bytes/member **permanently** —
queue rows are never removed. Worse, pull-time `enqueueSenior` sets `start` **at pull time**, so
a slow funder queues behind every comp enqueued in the interim, and §11.8 measured one comp
consuming ten weeks of a court's emission. **A guaranteed senior entitlement becomes a
first-come queue race.**

**Fix: enqueue ONE entitlement per claim at resolve, owned by the pool, drawn down pro-rata at
pull.** O(1) resolve, O(1) pull, one queue row, resolve-time seniority preserved.

**Comp split:** strictly pro-rata to all funders, declarant included, **no premium**.
`Δᵢ = δᵢ·b·(2q_o − q_u − q_f/2)`, whose sign is independent of δᵢ — so §4.1 survives verbatim.
Declarant-only comp gives every non-declarant `Δᵢ < 0` **unconditionally**, so no rational
stranger ever co-funds and C4b delivers nothing. If a premium is ever wanted, take it from the
flooring dust, never from comp.

### 12.10 C1 — the boundary, the invariant, and the bystander were all wrong

1. **The boundary is `votingBlocks + 1`, not `+2`.** **M** with the window pinned: 120_960 → 2
   rounds; **120_961 → 3**; 120_962 → 3. My `+2` was a **fixture artifact** — both my fixture and
   the shipped idiom resolve at `votingBlocks + 1`, but the *earliest* legal resolution is
   `+votingBlocks`. The requirement is `W > votingBlocks·(maxFailedRounds − 2)`.
2. **So §9.4's proposed invariant is over-strong by one full `votingBlocks`** — it demands
   241,921 blocks (14 days) where 120,961 (~7 days) suffices.
3. **BYSTANDER FAILURE — and it is the objection §5 uses to reject a longer settle window.**
   **M**, ordinary claim, one *decided* round, earliest legal Finalize:

   | W | answer → finalizable | drawWinners |
   |---|---|---|
   | 120_960 (today) | 241,920 = **14 d** | 19,584 |
   | 241,921 (**my invariant**) | 362,881 = **21 d (+50%)** | 19,584 |

   The draw is bit-identical, so the tax is pure latency — and it lands on the **winning side's
   principal**, since `WithdrawStake` gates winners on `verdictAt`. C1 as drafted reintroduces
   exactly what §5 rejects. Undisputed claims are unaffected.
4. **Better lever: a defaulted-verdict-only window.** Keep "set once, never recomputed", but pick
   the value from the branch that just ran — if `failedRounds > 0` (a quorum-less default), use
   `ladderWindow = (maxFailedRounds−2)·votingBlocks + (maxFailedRounds−1)·graceBlocks + 1` =
   **155,521 blocks (9 days)**. **M: the default court now reaches `provClose`; a decided first
   round keeps 120,960 bit-identical; whole shipped suite green, zero fixture edits.**
5. **"Extend `escrowUntil` per failed round" is NOT safe as I stated it** — `failedRounds` resets
   to 0 on every *decided* round, so extensions bound per-decided-round, not per-claim: an
   unbounded chain.
6. **The invariant belongs in `Params.mustSane`, not `mustInvariants`** — all three terms are
   per-court params, which is exactly why `mustInvariants` never saw the coupling.
7. **My global lever doubles the reopen grind chain.** `failedRounds` resetting on decided rounds
   makes the doubling ladder **inert** on a decided chain, so cost is linear in rounds and the
   only bound is the window. **M:** decided rounds go 2 → **4** at 241,921; with C3 each round is
   8.3× cheaper, so the full chain falls 200 CC → **48 CC — 4.2× cheaper with double the slots.**
   The targeted lever leaves it at 2.
8. **Three shipped fixtures already work around this bug**, one with the comment *"small claims
   cap at failedRounds=2 and finalize the defaulted verdict"*. The bug was documented in the
   suite.

### 12.11 C6 — C1 without it is strictly WORSE than today, and it does not rescue the robbed pool

**M**, default court:

| shape | outcome | winners | author | answerer |
|---|---|---|---|---|
| 2 failed rounds → Finalize (**today's ceiling**) | tier 1 | **19,584** | 1,958 | 1,224 |
| 3 failed rounds → provClose (**C1, no C6**) | tier 0, final | **0** | 0 | 0 |

So "C6 is not optional if C1 ships" **understates it**: C1 alone converts a claim that today
finalizes at MID and pays in full into one that pays nothing. **Ship them in one commit; if ever
split, ship C6 FIRST.**

**A hole C6 opens that the draft missed:** `quality.gno:82` must drop its `provClose` arm too.
Once provClose pays, shutting the flag lane hands every claim that outlasted the ladder an
**undemotable MID** — because the failed-quorum branch deliberately does not call
`resolveQualityRide`, so the ladder's own rides cannot demote it either.

**And state plainly what C6 does not do:** on a provClose the standing provisional is **always
`cs.answer`** (set by the first failed round). So C6 pays the **answer side**. On an
honest-answer-plus-apathy claim that is right; on a **sniped** claim it pays the sniper's dust
pool, and **the robbed majority pool still gets nothing.** C6 does not rescue the robbed pool.
C1's own diagnosis — apathy resolves in the liar's favour — is untouched by it.

**The correct tier** is the plain default MID against the standing provisional, using the same
guarded predicate the other terminal paths use (`if !cs.tierFinal && !cs.slotConsumed`), so a
genuinely adjudicated low is never clobbered. **M** after the patch: bit-identical to the
2-failed-round Finalize path, which is the right target.

### 12.12 C5 is downstream of C0, and its demotion is cheap

**§8 lists C5 as "independent". It is not.** An overturn round enqueues a **senior** comp and
restores the junior draw *in the same call*, and `reservedTail` is monotone — so the comp is
reserved **ahead of** the draw C5 exists to restore. **M** immediately after an overturn:
`comp = 280 CC`, `cumAccrual = 3.6 CC`, **`reservoir = 0`**.

| X̄ as share of supply | comp in weeks of budget | reservoir at crystallize | winners |
|---|---|---|---|
| 0.87% | 0.94 | 25.5 CC | **19,584** |
| 3.56% | 3.80 | **0** | **0** |
| 15.05% | 16.06 | **0** | **0** |

Crossover ≈ **1.9% of court supply**. Above it, C5 restores an entitlement `reserveJunior` then
clamps to zero *silently, by design*. **Shipping C5 before C0 restores nothing where it
matters.** (C6 *is* genuinely independent of C0 — failed rounds mint no comp.)

**And the demotion C5 blocks is cheap.** **M:** `demotionBar = arm/4` has **no supply floor**, so
a low bloc of 400 CC — **49 bps of court supply** — zeroed the entire draw of the pool the same
tally had just vindicated, for the price of one `VoteQuality`. The priced bystander (20,000 CC,
⅔ low, above `fullBar`) correctly still demotes.

**Gate: require the demotion's own mandate, not a blanket exemption.** Skipping the demotion on
an overturn would forfeit `burnConclusiveLowDust` (the junk author keeps deposit and fee) and
would latch `slotConsumed` on a tier it declined to set, permanently closing the flag lane.
Re-classifying the tally as **inconclusive** does neither. `cs.provisional >= 0` is load-bearing,
not defensive — `-1` also satisfies `!= answer`, and an existing test drives that state. **It
failed on the first predicate and was NOT asserting the bug** — it caught a real over-reach.

### 12.13 §4.1 fails at nonzero fixed cost, and C3 multiplies the failure

`Δ = b·(2q_o − q_u − q_f/2)` is scale-free **only at zero fixed cost**. With gas and attention
`g`: `Δ = b·(…) − g`, so there is a **minimum claim size below which nobody disputes**, and it
scales as `1/b`. **C3 cuts `b` by 8.3×, so it multiplies that floor 8.3×.** §10 lists gas as
unresolved but never connects it to C3, and §4.1 states its headline unconditionally. At 600 bps
a 100 CC claim's entire comp is 4.8 CC.

### 12.14 Corrected build order

**C0 → C6 → C1 → C5 → C2 → C3 → C4b** — with C1+C6 in one commit, C6 first if ever split, and
**C3 blocked pending the dispute-bond rework of §12.1.** C4a is cancelled.

### 12.15 Further corrections

- **`maxMidGrossBps` is 1927, not 1928** (the code floors), so the analytic ceiling is
  **30.83%·X̄**, not 30.845%. Confirmed independently by two agents.
- **`dispute.gno:313` is the ANSWERER's comp (uphold branch), not the disputer's** — the
  disputer's is `:291`. §C4b cites `:313` wrongly, and it matters: `:313` is an unlisted **C4a**
  site and the **largest answer-side entitlement of all** — `0.32·A` = 16%·X̄ at 5000 bps, against
  an answerer slice of ≈1.04%·X̄. **~15× larger than the item §C4a does name.**
- **A second §C4a omission:** `quality.gno:736` — only `cs.answerer` may `CounterFlag`. With a
  syndicate, a declarant gone dark leaves the pool's reserve undefendable, and `counterUsed` is a
  one-shot latch, so any funder allowed in can burn the syndicate's single challenge.
- **`cs.answerer` has 23 address reads, 17 behaviour-bearing** (12 money, 5+ authority) and 6
  display that must move in step. `cs.disputer` has **4**, all behaviour-bearing, **zero
  display** — so a syndicated dispute pool has no render surface today.
- **`court.gno:199` is an identity in `answerBondBps`** — it holds with zero margin at 450, 600,
  1928 and 5000 alike, so it constrains only `2·disputeBondOfAnswerBps ≤ compOfBurnBps`. §C3's
  zero-margin argument for 600-over-450 rests on `court.gno:232`, which is correct.
- **`court.gno:227` panics at BOTH 600 and 450**, so §7's "must be inverted, not deleted" is
  exact. Break-even claim age: 5000 → **31.14 weeks** (unreachable in a 12-week life); 600 →
  **3.74 weeks**; 450 → **2.80**. Both low values are reachable, so §7's conclusion holds at
  either — but note 2.80 is the *450* number while C3 ships 600.
- **Two C4b fixtures pin the direct transfer to `cs.disputer`** and must be re-derived:
  `TestDisputeOverturnPath`, `TestDisputeFailedRoundsToProvClose`.
- **Not run, and required before landing:** the Python guards in `realm-test`
  (`check-citations.py`, `check-docnumbers.py`, `check-stale-guards.py`) need the owner's working
  tree, not a shadow.

---

## 13. AUDIT ROUND 2b — §11.2 WITHDRAWN, and the first shippable change

### 13.1 §11.2 is withdrawn — the number was right, the finding was wrong

I reported that re-keying the floor without the sizer "leaks the collateral," refunding 83.83%
of the bond at settle. **The number reproduces (83.78%). The finding does not survive**, three
independent ways:

```
c3    (floor re-keyed, sizer not): bond0 249.735907  refund 209.235907 = 83.78%  reserve 40.500000
today (5000 bps, unmodified):      bond0 450.000000  refund 409.500000 = 91.00%  reserve 40.500000
c3fix (sizer re-keyed too):        bond0 249.735907  refund   0.000000 =  0.00%  reserve 249.735907
```

1. **Today refunds a LARGER fraction (91.0%) and the IDENTICAL absolute amount** (40.500000 CC =
   4.5%·X̄). C3-as-drafted retains strictly *more* of the bond than the status quo, not less.
2. **The retained reserve exactly covers everything still forfeitable.** Driven end to end:
   `retained at settle 40.500000 | slash levied by ResolveFlag 40.500000 | answerBond left
   0.000000`. The only post-settle forfeiture is the flag-lane slash, and it shares the sizer.
   **Nothing leaks.**
3. **The prescribed fix costs more than the bug.** Re-keying `quality.gno:531` withholds **100%
   of the bond from settle until crystallize** on the *modal* path (undisputed, no flag, ≥1 week),
   and it breaks a shipped test asserting the slash's **definition, not a bug** —
   `TestSlashSizeForDrawProportional`: *"a NO answer must read the NO pool, not the (large) YES
   pool."* `quality.gno:510-517` defines the slash as 1.6× the **answered** side's forgone draw.

**The correct reading, which I had inverted.** The answered-keyed sizer is **slash collateral**,
whose risk window runs to crystallize — retain it. The max-keyed excess is an **anti-snipe
premium**, whose risk window is the 72h dispute window, where the *whole* bond burns on an
overturn (including the slash reserve via `unslash`). **Releasing the premium at settle is
correct disposition, not a leak.**

> **§11.2's "re-key both in one commit" instruction must NOT ship.** Re-key the floor only.

Preconditions were asserted rather than assumed: the bond was genuinely floor-raised
(`bond0 == max-keyed floor`, base arm 54.000000); `SettleUndisputed` **refused** before the delay;
`votingBlocks 120960 > settleDelay 51840`, so no flag could have resolved.

**Fixture count re-confirmed:** C3-as-drafted fails **exactly three**, matching §11.7. Re-keying
the sizer adds a **fourth**, which §11.2 did not state.

### 13.2 The spine — one budget, and you cannot spend it twice

At the extremal (12 wk, hot ceiling, X̄ = 1000 CC), measured with the realm's own arithmetic:

```
mg 192.78   max-keyed bond 308.448
prize@MID 206.2746   prize@HIGH 399.0546
surplus at MID (the discount budget)  102.1734 = 33.12% of the bond
deficit at HIGH (the §11.1 break)      90.6066 = 29.37% of the bond
```

`L = (tier + splitCarrot/100)/k`, so **L ≤ 1 ⟺ the effective draw multiplier T ≤ k − 0.07 = 1.53.**
Both `Destroyed` and `bond` are proportional to the same `mg`, so there is no third lever: either
raise *k* (bond cost) or cap *T* (the HIGH premium). **The conviction discount and the HIGH-tier
fix draw on the same 33.12%. You can have one, not both.**

**And today HIGH is safe** — **M:** an adjudicated-HIGH honest claim measures **L = 0.7179**
(grid worst 0.7980). **The HIGH break is CREATED by C3, not exposed by it.**

### 13.3 CHOSEN FIX for §11.1 — cap the draw, not the tier. And it ships alone, today.

The tier freeze is **strictly dominated** at every point of a 2,304-point grid. Because
`bond0 ≥ 1.6·mg` always, `bond0 − carrot ≥ 1.53·mg`, so **the cap never pays less than 1.53·mg
while the freeze always pays 1·mg** — the freeze is the cap evaluated at the extremal and then
applied everywhere.

| tree | prize | bond0 | L | HIGH premium kept |
|---|---|---|---|---|
| no fix | 323.0956 | 249.7357 | **1.2937** | 100% |
| **draw cap** | 249.7357 | 249.7357 | **0.9999** | **53.0%** |
| tier freeze | 167.0108 | 249.7357 | 0.6687 | **0%** |
| cap alone, today's 5000 bps | 323.0956 | 450.0000 | 0.7179 | 100% — **inert** |

| bps | worst L: no fix | tier freeze | **draw cap** |
|---|---|---|---|
| 450 | 1.2937 | 0.6687 | **1.0000** |
| 600 | 1.2937 | 0.6687 | **1.0000** |
| 5000 (today) | 0.7980 | 0.4125 | 0.7980 (inert) |

**One clause at `crystallize.gno:83`:**

```go
if capd := cs.answerBond0 - mulDiv128(midGross, splitCarrot, 100); want > capd {
    want = capd            // subtract 1 more for strict L < 1
    if want < 0 { want = 0 }
}
```

**No new constant, no new state, one reader changed — and on today's constants it passes the
entire suite unmodified (`ok . 24.44s`, zero fixture edits).** So **it can ship BEFORE C3 and
does nothing until C3 lands.** That makes it the first change out of this whole exercise that is
verified, standalone and safe.

**Why a stored "frozen tier" field would be dead state:** `slashSizeAt` has **no tier factor** —
it keys on the MID-weight gross. So "the tier the bond was sized against" is `tierMidX` on *every*
claim, and the freeze is arithmetically just `min(cs.tier, tierMidX)`.

**Every reader of `cs.tier`, by grep — money readers are exactly three, all in `crystallize.gno`:**
`:83` (the draw — **the only site the fix touches**), `:265` (the `AnswererBonus` cap) and `:276`
(`capBonus`, the F9 per-position cap). The latter two must **not** be lowered independently or
coin strands. One authority reader: `quality.gno:613`, the v0.54 promotion ratchet, must keep
reading the **live adjudicated** tier. Three display readers: `quality.gno:695`, `render.gno:279`,
`render.gno:409-411`. **Off-chain:** `web/index.html:1168` reads `QualityTier` beside `DrawSlices`,
so decoupling adjudicated from paid tier makes that page self-contradictory unless a second read
exposes the effective multiplier. **Naming trap:** `c.tier` (directory listing state) is a
*different field* — a grep for `.tier` conflates them.

**Cost, stated:** the winning stakers of genuinely-HIGH claims lose 47% of the premium, in the
draw-arm regime only (mg/X̄ > 2.899%). **But it is not the C0 problem** — C0 destroys the prize by
*availability* (unpredictable, and permissionlessly timed by an attacker), whereas the cap is
*definitional* and fully determined at answer time (`cs.answerBond0` has exactly one write site).
It therefore satisfies Humphrey factor 2 — "amounts certain and guaranteed" — **better than the
clamp it replaces.** Charging the promoter instead was priced and fails: the flag opener's bond is
2%·X̄, only 24.5% of the deficit, and the dispute-ride route to HIGH is free anyway.

### 13.4 §11.1's band is ~3× wider, and only a bug was closing it

Round 1 evaluated **only** the 12wk-hot corner and so reported the *narrowest* band:

```
12wk hot  -> L>1 for X̄/S in [0.1000%, 1.2800%]   (round 1's figure)
12wk cold -> L>1 for X̄/S in [0.1000%, 3.2400%]
4wk  hot  -> L>1 for X̄/S in [0.1000%, 3.8600%]   <- the TRUE worst case
4wk  cold, and 1wk at any rate -> nowhere
```

**And what closes it is the `curPeriodBudget` clamp**, isolated: at X̄/S = 1.29% it pulls L from
1.2937 to 0.9987. So the protection **is §6's own defect** — a destroyed draw making the published
rate a lie — and it "improves" over time only by making more claims' draws untrue. **Under the
draw cap, L ≤ 1 holds with no reliance on the clamp at any X̄/S, age or rate.**

### 13.5 The conviction lever works and is worth 8.3% of C3 — spec it, don't build it yet

The signal separates decisively (**M: 1,446,756×**) and **the straddle is defeated**, at a
derived threshold: `u* ≥ 1 − L0/k` = **25%**; take 1/3 for margin. **M**, monotone — the straddle
costs more at every size, and pool inflation alone suffices, with carry a second independent
margin:

| own stake per side | u | C3 bond | C3+discount | vs dust-snipe baseline |
|---|---|---|---|---|
| 0 (dust snipe) | 0 | 249.7359 | 249.7359 | — |
| 300 CC | 25.00% | 332.9810 | 270.5470 | **+37.31** |
| 900 CC | 50.00% | 499.4714 | 374.6036 | **+174.37** |

Threshold verified load-bearing: at u\* = 20% the cheapest straddle **wins** (234.360 vs 249.984);
at 25% it is exactly indifferent; at 1/3 it is defeated with margin.

**A counter-intuitive detail that must not be "corrected": do NOT net the answerer's own
opposing-side position out of `mg_max`.** Netting looks more principled and is fatal — carry alone
is 6.4× too cheap, and with the self-tax removed *no* `u* ≤ 1` works.

**Denominator: own conviction / `mg_max`.** Two candidates refuted by measurement — the
declared-side pool scores a lone late-staker at **100%** (the sniper *is* the declared pool), and
own-stake (average hold *time*) is scale-free, so 1 base unit held for the claim's life scores
maximal. Time alone is free; the signal must be capital×time.

**Conviction cannot be bought.** `cs.stakers.Set` has exactly **one** write site and there is **no
`Remove`**; CC is soulbound, with `scripts/check-nontransferable.py` existing to trip if that
changes — its own words: *"a coin that cannot change hands cannot have its accrued conviction
sold."* Selling the key transfers **non-exclusively** (the seller can still burn the bond), so it
is a lemons market, not a market.

**No cold-start problem:** `u` is a ratio of two convictions over the same window, so it is
age-invariant — **M:** 11.1100% at the 3h maturity minimum, *bit-identical* to 11.1100% at 11
weeks. At dust scale both premium and discount go inert together, so there is no brick.

**But the give-back is small.** **M**, contrarian holding 100 CC from open (u = 11.11%):

```
today            500.0000 = 50.00% of X̄
C3 max-keyed     249.7357 = 24.97% of X̄     <- C3's give-back: 250.26
C3 + conviction  228.9265 = 22.89% of X̄     <- the LEVER's give-back:  20.81
```

**The lever is worth 8.3% of what C3 alone delivers**, and it cannot be made larger: the bond may
never fall below `L0·mg_max`, so **75% of the price is non-discountable by construction**. Reaching
the full 25% needs u ≥ 1/3 — holding a third of the majority pool's conviction on the minority
side, which is not a contrarian.

**And C4a dominates it for the same beneficiary.** **M:** the contrarian's capital is locked, so
spendable is 0.000000 and `PostAnswer` refuses. F9 rescues them — unstaking first keeps conviction
bit-identically (17.342758 → 17.342758) and frees the principal — but they are still **129 CC
short** of the discounted 229 CC bond.

**Verdict: sound, straddle-proof, small. Spec it; do not build it before C1/C2/C4.**

### 13.6 A correction to §11.3 that cuts the other way

§11.3 said C3 is a "regression on the deterrent axis," 29.2% → 40.1%. Two corrections:

- **My table omitted today/HIGH: L = 0.7980, q\* = 44.38%.** So C3 is a regression at *both* tiers
  (44.38% → 56.40%), and HIGH is where it is largest.
- **But `q*` holds `q` fixed, and C3 moves `q`.** The dispute bond is `min(20%·X̄, 40%·answerBond)`,
  so **M** on the same claim: **180.000000 today vs 99.894362 under C3** — mounting the overturn
  gets **1.80× cheaper** at the extremal, and up to **8.3× cheaper** on a sniped claim in the
  base-arm regime. **The direction of the net effect is not established either way.** §11.3's
  regression claim is true only holding turnout exogenous, and the dispute bond is precisely what
  turnout responds to.

### 13.7 Build-order consequence

**The draw cap (§13.3) is promoted to FIRST** — ahead of C0, C2 and everything else. It is one
clause, no new state, suite-green standalone on today's constants, and inert until C3 lands. It is
the only change so far that is verified shippable in isolation.

Revised: **draw cap → C0 → C6 → C1 → C5 → C2 → C3 → C4b**, with the conviction lever specced and
deferred, C4a cancelled, and C3 still blocked pending §12.1's dispute-bond rework.
