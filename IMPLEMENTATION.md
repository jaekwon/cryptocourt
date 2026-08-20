# IMPLEMENTATION.md — landing the bond redesign

Derived from `GAMETHEORY.md` after seven audit passes. **Read §0 before doing anything**: one
decision is the owner's, and one step's ordering was changed from what `GAMETHEORY.md` §14.7 says.

Each step below states its **files**, **sites** (enumerated by grep, never estimated),
**invariants**, **fixtures to re-derive**, **bystander test**, and **exit criteria**. A step is not
done until its bystander test is bit-identical and every new guard has been shown to FIRE against a
deliberate mutation in its final registered form.

**`realm/` is owned by another session. Coordinate before editing it.** Nothing here is applied.

---

## 0. Before starting

### 0.1 One decision is the owner's, and it is not in any step below

**The cheapest way to destroy a claim's reward is not the answer bond.** It is a low-turnout
quality demotion: `demotionBar = min(X̄frozen, votable/3)/4` has **no supply floor**, so ~8 bps of
court supply zeroes a claim's entire payout, the flag bond is **returned whole**, and a senior
bounty **mints** — net profitable, and anchored on the *author's* burned deposit rather than on the
draw (36× the draw harm on a small claim). Voting consumes no weight, so one bloc does several
claims at once. **Measured; see §15.1.**

**No step in this plan touches it**, and `quality.gno:249-261` already calls the missing floor a
deliberate asymmetry and defers the fix. The two shapes of fix are: give `demotionBar` a supply
floor, or half-burn the sub-bar flag bond and pay no bounty. **This is a policy call about how
cheap a legitimate quality challenge should be, so it is the owner's, not the implementer's.**

Related: **Step 3 widens this path** (§3.6). If the decision is to close it, close it *with* or
*before* Step 3.

### 0.2 The reordering, and why

`GAMETHEORY.md` §14.7 says *draw cap → C0 → C6 → C1 → C5 → C2 → C3*. **This plan puts C0 last.**

C0's fix — make the junior draw *delayed rather than scaled* — is the **largest rework in the set
and the least specified**: it changes `bonusPaid` from a flag to an amount and needs the F9
`capBonus` interaction re-derived. Sequencing it second blocks four verified changes behind the one
unknown.

The cost of moving it is **bounded and known**: a `provClose` reached *after a decided round*
restores an entitlement worth nothing until C0 lands, because that claim's own overturn enqueued a
senior comp (§16.4). A failed-rounds-only provClose — the common shape — pays in full. So deferring
C0 leaves a **narrow incompleteness, not a regression**, and every other step is strictly positive
without it.

### 0.3 Ground truth to re-verify first

Three numbers this plan rests on were each measured by one agent in a shadow copy. **Re-measure
them in the owner's tree before writing code**, because a shadow can drift:

1. `maxMidGrossBps == 1927` (not 1928) and the ceiling is **30.83%·X̄**.
2. `votingBlocks == escrowMinBlocks == 120_960`, and round 3 opens at **`votingBlocks + 1`**.
3. The four-change patch round-trips: `git apply` onto baseline reproduces the tested tree
   byte-for-byte.

---

## 1. STEP 1 — the draw cap

**Ship first. It is one clause, suite-green standalone, and inert until Step 4.**

- **File:** `crystallize.gno`.
- **Site:** exactly one — `:83`, `want := mustMul(cs.tier, midGross)`.

```go
if capd := cs.answerBond0 - mulDiv128(midGross, splitCarrot, 100); want > capd {
    want = capd            // subtract 1 more if strict L < 1 is wanted
    if want < 0 { want = 0 }
}
```

Requires the carrot to be computed **before** `want`.

- **Do NOT touch** `crystallize.gno:265` (`AnswererBonus` cap) or `:276` (`capBonus`, F9). Lowering
  either independently strands coin. Lowering `:83` alone can only make them *less* binding —
  verified in the safe direction (`drawWinners / Σ capBonus bounds ≤ 0.254`).
- **Do NOT add a stored "frozen tier" field.** It would be dead state: `slashSizeAt` has no tier
  factor, so the value is `tierMidX` on every claim.
- **Invariant:** none new. The property (`L ≤ 1`) is arithmetic, not asserted.
- **Fixtures:** none. **Measured: full suite green, zero fixture edits, on today's constants.**
- **Bystander:** an ordinary MID claim's draw must be **bit-identical**. It provably is —
  `capd ≥ 1.53·mg_win > 1.00·mg_win = want@MID`, from `1.60 − 0.07 > 1` alone, with **0 MID
  bindings in a 500-point sweep** out to 5× `maxMidGrossBps`. Assert this rather than trusting it.
- **Mutation to prove the guard fires:** remove the clause and show a HIGH-tier claim's leverage
  exceeds 1.
- **Exit:** suite green, zero fixture churn, and a fixture showing the cap binds at HIGH and not at
  MID.

**Off-chain follow-up:** `web/index.html:1168` reads `QualityTier` beside `DrawSlices`. Adjudicated
and paid tier now differ at HIGH, so that page needs a second read exposing the effective
multiplier or it contradicts itself. **Other session owns `web/`.**

---

## 2. STEP 2 — the four structural fixes, as one batch

**A verified patch exists** (`SET-FINAL.patch`, 10 files, +1436/−82; production code 5 files, ~90
non-comment lines). **Verdict: GO. No pair needs splitting.** If ever split: **S3 before S2** —
S2 alone converts a claim paying 19,584 into one paying 0.

### 2.1 S1 — the quorum floor

- **DELETE** `dispute.gno:580-582` (the supply arm) and `:607-609` (the v0.29 clamp). Both are
  **provably dead** under the change — 88/88 rows, zero divergence — so gating them leaves two dead
  blocks and a page of prose describing behaviour that no longer runs.
- **Rewrite the function comment** as `floor = max(1, min(X̄frozen, votable/3))`.
- **Re-anchor the credential bar** — `dispute.gno:321`, `yes >= floor/4` → `yes >= credWeightFloor(c)/4`
  with `credWeightFloor = mulDiv128(PastTotal(Epoch()-1), quorumSupplyBps, Bps)`. **Without this the
  change silently cuts the documented 1.25%-of-supply price by 5.01×** — measured, two socks
  totalling 1.125% of supply mint an `AnswerRecord`, and three such points buy the 24h priority
  window.
- **`qualityBars` needs no change** and the **election lane cannot be reached** by this clause
  (`electionFloor` is 5% of *votable*, no X̄ arm; `mustElectionInvariants` reads only package
  constants). Both verified; all ten `TestElection*` pass.
- **Known consequence, accepted:** the verdict and quality lanes now disagree in the band this
  fixes (at X̄ = 1% of supply, quorum 399 CC vs `fullBar` 2000 CC). The slash deterrent **keeps** its
  supply anchor, which is the right side of that trade, but it makes `court.gno:250-254`'s comment
  ("prices filing above winning the vote") untrue of the verdict lane. **Fix the comment.**

### 2.2 S2 — reachable provClose, defaulted-verdict window only

- **Do NOT raise `escrowMinBlocks`.** Measured: it taxes an honest *disputed* claim from 14 to 21
  days of frozen winning-side principal — the exact objection §5 uses to reject a longer settle
  window — and it **doubles the reopen grind chain** (decided rounds 2 → 4).
- At the first resolution in `ResolveDispute`, if `cs.failedRounds > 0`, floor the window at
  `ladderWindow`. Keep **"set once, never recomputed"**.
- **`ladderWindow` as specified carries 34,560 blocks of slack** — the measured minimum is
  `votingBlocks + 1` = 120,961, because round 2 opens in the same block round 1 resolves. The
  `(maxFailedRounds−1)·graceBlocks` term is **conservatism, not necessity**. Keep it, and say so in
  the comment so nobody later "fixes" it as a bug.
- **Invariant in `Params.mustSane`, NOT `mustInvariants`** — all three terms are per-court params,
  which is precisely why `mustInvariants` never saw the coupling.

### 2.3 S3 — provClose pays the winners

- `provCloseClaim` sets the plain default MID against the standing provisional via the **guarded**
  predicate `if !cs.tierFinal && !cs.slotConsumed`, so an adjudicated low is never clobbered.
- `crystallize.gno:32` refuses only `cs.closed`.
- **`quality.gno:82` must drop its `provClose` arm**, or every claim that outlasted the ladder gets
  an **undemotable MID** — the failed-quorum branch deliberately never calls `resolveQualityRide`.
- **State plainly what this does not do:** on a provClose the standing provisional is **always**
  `cs.answer`, so S3 pays the **answer side**. On an honest-answer-plus-apathy claim that is right;
  on a **sniped** claim it pays the sniper's dust pool and **the robbed majority still gets
  nothing.** S3 does not rescue the robbed pool.

### 2.4 S4 — a verdict round must not zero the tier it vindicated

- In `resolveQualityRide`, after `if !conclusive { return }`, **re-classify as inconclusive** rather
  than exempting: require the demotion's own mandate (`turnout >= fullBar && qLowW*3 >= turnout*2`),
  gated on `cs.provisional >= 0 && cs.provisional != cs.answer`.
- **Re-classify, do not skip.** Skipping would forfeit `burnConclusiveLowDust` (the junk author
  keeps deposit and fee) and would latch `slotConsumed` on a tier it declined to set, permanently
  closing the flag lane.
- **`cs.provisional >= 0` is load-bearing.** `-1` also satisfies `!= answer`, and
  `TestRideRatchetAndSlashPredicate` drives that state. **It failed the first predicate and was NOT
  asserting the bug** — it caught a real over-reach.
- **The scoping is pinned by shipped code.** `TestUnmandatedDemotionRideStillLands` drives an
  *uphold*, so S4 must not fire. **Had this been written as "no demotion on any decided round"
  instead of "on an overturn round", that fixture would have failed.**

### 2.5 Fixtures — 3 shipped + 5 corpus rows. Churn is NOT zero.

| fixture | asserting the bug? |
|---|---|
| `TestCourtDepositLedgerMatchesItsClaims` | **Yes** — `!tierFinal \|\| tier != tierLowX` is the S3 defect. Re-derive. |
| `TestOpenFlagRefusesEveryClosedState` | **Yes** — pinned the `provClose` arm S3 deletes. Re-derive so provClose must NOT refuse, **paired with `closed`, which still must.** |
| `TestParamsMustSaneRefusesEachMalformedField` | **NO — this is the one real cost.** It asserted a fixed one-week window (`escrowMin == escrowMax == 120_960`) passes `mustSane`; S2's invariant now refuses it. Mitigated (no production path writes those params) but not free. |
| corpus rows 22, 335 | **No** — anchors became *ambiguous* because provClose now carries the identical guard, which is the v0.44 "two terminal paths share ONE predicate" goal arriving. Widen upward. |
| corpus row 41 | **No** — anchor moved with the credential bar. |
| corpus rows 351, 352 | **Yes, both** — each pinned pre-S3 behaviour, so both **invert**. |

### 2.6 Exit criteria

- Every package green, `r/kourtv2` included.
- **Correctness target:** a provClosed claim pays **bit-identically** to today's Finalize path, with
  the pool figure identical across runs so it is structural equality and not two clamps agreeing.
- **Bystander:** undisputed *and* one-decided-round shapes bit-identical, **character for
  character**, with preconditions asserted (`SettleUndisputed` refused at `settleDelay − 1` then
  accepted; `Finalize` refused at `escrowUntil − 1` then accepted on the boundary).
- **Mutation:** 12/12 caught, 0 survivors, **0 invalid builds** (a build failure is not a survivor).
- Every new fixture passes **in isolation**, so none depends on suite ordering.
- Python guards green. **Two need the owner's tree** (they shell out to `git ls-files`):
  `check-paths.py`, `check-guards-armed.py`. Currently **unverified**.

---

## 3. STEP 3 — C3, the bond itself

**This is the change the owner asked for: 50% → 6%.**

### 3.1 The change

- `answerBondBps: 5000 → 600` (`court.gno:71`). **Derive it as `slashXBps * 4 / 3`** rather than
  hardcoding, so it tracks.
- **Re-key the collateralization FLOOR only** — `answer.gno:148`, `cs.sideConv(verdict)` → `max`
  over both sides.
- **Do NOT re-key the sizer** (`quality.gno:531`). §11.2 said to; **§13.1 withdrew that.** The
  answered-keyed sizer is *slash collateral* whose risk window runs to crystallize; the max-keyed
  excess is an *anti-snipe premium* whose window is the 72h dispute, where the whole bond burns
  anyway. Releasing the premium at settle is correct disposition, not a leak. Re-keying it withholds
  **100% of the bond until crystallize on the modal path** and breaks a fixture asserting the
  slash's **definition**.

### 3.2 Why 600 and not 450

Not game theory — leverage is **bond-independent**. At exactly 450 the settle refund is **zero**
(the whole bond is retained as reserve) and at **449 the realm refuses to deploy**. 600 gives back
25% at settle and leaves margin for any later `slashXBps` rise.

**Also tighten `court.gno:232` to a margined form** (`slashXBps*4/3 > answerBondBps`). Today
`450 == 450` passes, and 450 is exactly the value that zeroes the refund — the invariant is one step
short of catching what had to be caught by hand.

### 3.3 Deploy invariants — rescope, do not delete

- **`court.gno:194`** — `answerBondBps ≥ tierMidX*10000/2`. **Must NOT be relaxed before the
  re-keying lands.** Measured: deleting it first drops the snipe's break-even claim age from an
  unreachable **31 weeks** to a reachable **3.74** (at 600; 2.80 at 450). It is *mislabelled* — its
  comment says "maximum undisputed extraction", `PLAN.md:718-725` retracted that, and what it buys
  is **anti-snipe** cover.
- **`court.gno:227`** — **invert, do not delete.** It panics if the draw arm exceeds the base bond,
  premised on the floor staying inert. Under C3 the floor binding **is** the design, so it becomes a
  sanity bound. **It panics at both 600 and 450**, so this is a hard build failure, not optional.
- **`court.gno:199`** — drop the shared `answerBondBps` factor so it states what it constrains
  (`2*disputeBondOfAnswerBps > compOfBurnBps`). As written it is an **identity that certifies
  nothing while looking like it certifies something** — it holds with zero margin at 450, 600, 1928
  and 5000 alike.

### 3.4 Fixtures — exactly three

`TestEconomicConstantsAreTheCalibratedValues` (constant pin — its own message says edit it in the
same commit), `TestAnswerBondCapBindsWhenTheFloorIsBelowIt` (fixture scale: the cap no longer sits
between floor and uncapped), `TestSlashReserveDrawProportionalAtSettle` (its injected midGross now
exceeds the bond).

**`TestSlashIsLeviedAtMostOncePerClaim` and `TestOverturnBurnsTheSlashWithTheBond` PASS** — they
compare relative quantities. Confirmed three times, against §8's original claim of five.

### 3.5 Do NOT rework the dispute bond

§12.1 said to. **§14 lifted that** — it was a denominator artifact, and the brief that produced it
was wrong. The destroyed prize contains **no bond term** (1,728 grid points, zero divergences), so
no dispute-bond sizing reduces the harm. What the bond level moves is the **attacker's payoff**,
which falls **4.95×** under C3 — payoff-to-damage improves from 8,210× to 985×. Chasing `L < 1` in
that lane was built and priced: it needs a **51.5%–99.7%** answer bond, i.e. it reinstates the very
number being removed, **and** it refuses the same victim C3 rescues.

`disputeBondXBps`/`disputeBondOfAnswerBps` stay **2000/4000**.

**One trap to guard:** if the coupling is ever broken, `court.gno:199` **still passes at deploy
while the runtime form fails** — measured. Add a runtime assertion at `OpenDispute` that
`2*bond <= cs.answerBond0*compOfBurnBps/10000` if that day comes.

### 3.6 Consequence for §0.1

**C3 does not widen the quality-demotion path, but Step 2's S3 does** — dropping `OpenFlag`'s
provClose arm re-admits the same unfloored demotion, and `ResolveFlag` overwrites `cs.tier` with
**no `tierFinal` guard**, so `provCloseClaim`'s `tierFinal = true` does not protect the new payout.
A 200 CC dust flag zeroes a provClosed claim's whole payout for free. **If §0.1 is being closed, do
it with Step 2.**

### 3.7 Exit criteria

- Every package green with exactly the three fixtures re-derived.
- Destruction leverage in the answer lane **≤ 1 at every age, rate, tier and split** — analytically
  first, then swept. With Step 1 in place this holds with **no reliance on the `curPeriodBudget`
  clamp**, which matters because that clamp is §6's own defect.
- **Bystander:** an honest majority answerer's bond is **unchanged** (bit-identical for majority and
  even-split answers — the re-keying is the same tax with the sniper's exemption removed), and an
  honest contrarian's is **~5× cheaper** than today.
- A fixture proving the sniper's exemption is **gone**: dust-on-declared-side must now pay the
  max-keyed floor.

---

## 4. STEP 4 — C0, the comp drought

Deferred per §0.2. **The cap must NOT ship** (§11.8: strands 73% of a challenger's compensation,
moves their break-even from 20% to 46.7%, and its two constraints are mutually exclusive above
X̄/S ≈ 2.85%).

- **The fix:** make the junior draw **delayed rather than scaled** — `reserveJunior` reserves the
  full `want` on the accrual line and pulls become partially payable as coverage arrives, exactly as
  `PullSenior` already works. Satisfies both "the claim must eventually mint the prize it should
  have minted" *and* the challenger's 2:1 premium, which the cap could not do together, and it
  **removes the timing attack** because no crystallize moment is worse than another.
- **Cost:** `bonusPaid` becomes an amount rather than a flag, and the F9 `capBonus` interaction needs
  re-deriving. **This is the rework that justifies deferring it.**
- **Cheap interim if needed:** refuse `Crystallize` while `reservoirR() < want` and senior mass is
  unpaid. `Crystallize` is its own entrypoint and already panics on five preconditions, and
  principal is not gated on it. Needs a deadline so a griefer cannot block forever, and it withholds
  the author's deposit and fee during the wait.
- **Do NOT make `reservedTail` decrementable.** The accrual line is **exactly tiled**
  (`cumAccrual − emittedTotal − R = 0.000000`), so reclaiming a paid tail hands the junior lane coin
  **already minted to the senior** — a 75.7% overshoot of the emission ceiling. A straight
  double-spend.
- **Also fix the flag bounty** — same defect at 1/5 the magnitude (6 weeks of drought at 30% of
  supply), uncapped, and it can co-occur with a comp on the same claim. C0-as-drafted fixed one of
  three senior consumers.

---

## 5. Deferred, with reasons

| item | why deferred |
|---|---|
| **C4a — answer-bond syndication** | **CANCELLED.** Enables profitable self-dealing at any share ratio outside [0.8, 1.25], funded by co-funders, with **no sybil-proof fix**. And C3 delivers its benefit anyway: measured, the median per-address ask is 0.06–0.31% of supply. |
| **C4b — dispute-bond syndication** | Tail feature. C3 alone fixes the self-defence case §C4b claimed only it could — measured, the victim **can** self-defend under C3. Still wanted at the analytic ceiling. Needs: **uncapped** pool (a capped one is squattable), **round-scoped** contributions (a half-burned round-1 bond otherwise counts as round-2 collateral, leaving escrow short), **one** senior entitlement drawn down pro-rata (N entitlements is 12.7% of a block at N=2048), `isParticipant` **split** into `isExcludedVoter`/`isGraceInsider`, and credential to the **declarant only**. |
| **Conviction lever, answer lane** | Sound and straddle-proof at a derived threshold (`u* ≥ 1 − L0/k` = 25%; use 1/3). But worth only **8.3%** of what C3 already delivers, because 75% of the bond is non-discountable by construction. |
| **Conviction lever, dispute lane** | Looks **stronger** than the answer-lane one and is undesigned. At `OpenDispute` the disputer's frozen conviction on the side they are moving toward is **unbuyable** — a victim has it by construction, a griefer must have bought it before the answer, on a claim whose answer they could not predict. Own design pass. |
| **`provCloseClaim` retaining a slash reserve** | S3 opens a **demote-only, economically inert** flag lane on provClosed claims — every priced disposition is `answerBond`-gated and provClose returns the bond whole. Not an exploit (reaching provClose costs 70%·X̄ against a ≤19.27%·X̄ draw) but the lane has no teeth there. |
| **`answerBondCapCC`** | A real lever — a court with `answerBondCapCC < 2.07·mg` would have genuinely-HIGH prizes cut up to 26% **even at 5000 bps** — but **structurally unreachable**: no setter, `defaultParams()` sets 0, `court.gno:267` states no retune entrypoint exists, and a fixture pins the 0. **Flag for whoever wires that knob.** |
| **The 5-second-block premise** | `maxTcWeeks` is a *block* ratio while the gate that fires is *wall-clock*, and `blocksToSecs` hardcodes 5 s with **zero** references in `mustInvariants`. Divergence could not be demonstrated (gno advances at exactly 5.0 s/block), so this is a **deployment premise to pin**, not a live defect. |

---

## 6. What this whole set does and does not achieve

**Does:** cuts the answer bond **8.3×** (50% → 6%) while removing the sniper's exemption, so an
honest majority answerer pays what they pay today and an honest contrarian pays ~5× less; bounds
answer-lane destruction leverage at ≤ 1 without relying on a clamp that is itself a defect; makes a
provClosed claim pay what a finalized one pays; stops a verdict round zeroing the tier it just
vindicated; lets a small claim's verdict actually reach quorum; and improves the malicious
overturner's payoff-to-damage ratio **8.3×**.

**Does not:** bound destruction overall. **Two paths destroy the same prize for free and neither is
closed by anything here** — an unanswered claim expiring (structurally un-closable by these
changes: the gates are mutually exclusive), and the §0.1 quality demotion, which is *net
profitable* at 8 bps of supply. §14.4 claimed both were closed. **That claim was wrong**, and the
correction is the last thing the seventh audit pass found.

---

## 7. PLAN AUDIT — amendments. READ BEFORE IMPLEMENTING.

**Verdict: GO on the ordering. GO on Step 1 (verified green standalone). CONDITIONAL GO on Step 3
— two required additions. CONDITIONAL NO-GO on Step 2 as scoped.** Nothing invalidates the design;
what follows are landing defects, and **one of them looks exactly like success.**

### 7.1 REQUIRED — Step 3's two halves must land in ONE commit

**This is the highest implementation risk in the plan and §3.1 as written invites it.** §3.1 lists
the bps drop and the floor re-keying as two bullets with **no stated ordering between them**, and
§3.3 is ordering-aware about the *invariants* but silent about this.

**Step 1's MID-safety rests entirely on the max-keying, not on the bond level:**

```
cap inert  ⟺  answerBond0 ≥ 1.07·mg
max-keyed:      answerBond0 ≥ 1.6·mg_max ≥ 1.6·mg_win   ✓  1.60 > 1.07
answered-keyed: answerBond0 ≥ 1.6·mg_answered  — WORTHLESS when mg_win > mg_answered
```

**Measured**, on a tree with `answerBondBps = 600` and the `court.gno` invariants fixed but
**without** the re-keying, on an **overturned** claim (so `midGross` is the vindicated majority's
pool while the floor sees only the answerer's dust):

| mg/X̄ | correct draw | paid | % of correct |
|---|---|---|---|
| 500 bps | 50,000,000 | 50,000,000 | 100% (inert) |
| 900 bps | 90,000,000 | 53,700,000 | **59%** |
| 1200 bps | 120,000,000 | 51,600,000 | **43%** |
| 1927 bps | 192,700,000 | **46,511,000** | **24%** |

Binding starts at `mg > 5.607%·X̄` ≈ **3.5 weeks of claim age at the hot rate.**

> **AND THE SUITE CANNOT SEE IT.** The half-landed tree fails **exactly the same three fixtures
> with byte-identical messages** as the complete tree. An implementer who lands the bps drop first,
> re-derives the three fixtures §3.4 told them to re-derive, and sees green **has shipped a 76% cut
> to the vindicated majority's draw** — with `L ≤ 1` still holding, so the headline property looks
> intact, and `make check` fully green.

**Amendments:** (1) `court.gno:71` and `answer.gno:148` land in **one commit**, non-negotiable.
(2) Add a bystander asserting an **overturn winner's `drawWinners` is unchanged** — §3.7's
bystander tests the answerer's *bond*, not the overturn winner's *draw*, so it does not catch this.

### 7.2 REQUIRED — §0.1 becomes a GATE on Step 2, not a cross-reference

§3.6's claim is **verified in code**: `quality.gno:355` sets `cs.tier` with no `tierFinal` guard,
and `OpenFlag` checks seven conditions but **not `tierFinal`** — so `provCloseClaim`'s
`tierFinal = true` does not protect the payout. And it is free: provClose already zeroed
`cs.deposit`/`cs.fee` so the dust burn burns nothing and the bounty is 0, while `slashGrade`
requires `cs.answerBond > 0` which provClose also zeroed, so **the flag bond returns whole.**

> **§2.6's correctness target is satisfiable in test and defeated for free in production.** The
> plan knows this and files it in §3.6 while §2.6's criteria pass anyway. **Move it: Step 2 does
> not ship until §0.1 is decided.**

Per-step effect on §0.1, verified: **Step 1 neutral** (the free demotion sets `tier = 0`, so
`want = 0` and the cap never engages), **Step 2's S3 WORSE**, **Step 3 neutral** (`demotionBar`
has no bond term), **Step 4 neutral**. So Steps 1/3/4 are not a regression on a path that is
already open; **Step 2 is.**

### 7.3 REQUIRED — `court.gno:194`'s rescope target is unspecified, and it blocks deploy

At 600, `answerBondBps < tierMidX*10000/2` ⟹ `600 < 5000` ⟹ **init panics.** §3.3 says "rescope,
do not relax" and never says *to what*. **The least-specified line in the plan, and it is a hard
build failure.** Decide the replacement predicate before starting Step 3.

(§3.3's other two claims verify exactly: `:227` computes `16000*1927/10000 = 3083 > 600` so it
panics at both 600 and 450; `:199` is an identity — `480 > 480` is false at every bond level.)

### 7.4 The ordering claim is STRONGER than §0.2 states — the deferred-C0 cost is ZERO, not bounded

Derived from the gates rather than the prose: `escrowUntil` has one write site, reopens are refused
at `now >= escrowUntil`, round *k*≥2 opens at `T₁ + (k−2)·votingBlocks`, so

> **R(W) = 2 + floor((W − 1) / votingBlocks)**

which reproduces all three published measurements (W=120,960 → 2; 120,961 → 3; 241,921 → 4).
Applying it: `ladderWindow` = 155,521 → **R = 3 exactly**, provClose needs **three consecutive**
failures, and `failedRounds` resets on **every** decided round. Therefore **a decided round is
structurally impossible on any provClose that S2 newly enables** — so C0's deferral costs that
population **nothing**. The decided-then-provClose shape needs R = 4 (W ≥ 241,921, X̄frozen ≥ ~4,000
GNOT-equivalent) and **already exists today**, independent of S2.

**C0 last is correct, and §0.2 undersold it.**

### 7.5 Step 1 verified standalone — verbatim

```
p/checkpoint ok 0.56s   p/grc20votes ok 0.62s   p/governor ok 0.67s   p/twap    ok 0.53s
p/cshares    ok 0.52s   p/tickbook   ok 0.68s   p/curve    ok 1.86s   r/govern  ok 1.76s
r/offerer    ok 0.61s   r/kourtv1    ok 1.20s   r/kourtv2  ok 7.30s   REAL EXIT: 0
```

**Zero fixture edits, zero mutation anchors broken (0 bad of 593 rows).** And the inertness is
**provable, not lucky**: at 5000 bps the cap binds only when `mg > 2415.5 bps·X̄` while
`maxMidGrossBps = 1927` — **25% of margin.**

**Two corrections to §1:**

- **§1's exit criteria are self-contradictory.** They demand both "inert until Step 3" *and* "a
  fixture showing the cap binds at HIGH and not at MID." **Both cannot hold on today's constants** —
  the cap is inert on every row at both tiers at 5000 bps. The binding fixture must **inject**
  `cs.answerBond0` (the `crystallize_test.gno:715` idiom), not drive it. Say so, or the implementer
  chases an unreachable state.
- **§1's "requires the carrot computed before `want`" is FALSE** of the clause as written — it
  recomputes `mulDiv128(midGross, splitCarrot, 100)` inline from values already live at `:83`. The
  instruction invites a pointless code motion. **Delete it.**

### 7.6 Enumerations that were WRONG

1. **`web/index.html:1168` is not a read site — it is demo fixture data.** The real reads are
   `1249-1250` (`AnswerBond` + `QualityTier` adjacent) and `1266` (`DrawSlices`) at HEAD, plus
   `QuorumFloorOf` at `1373`. **And it is worse than §1 said:** nothing in `web/tests/*.js`
   references any of them, and `check-live-reads.py` — the only check that walks them — is
   **deliberately excluded from `make check`** because it needs a live node. **The off-chain
   contradiction is silent under the full gate.** (`web/` is the other session's — reported, not
   touched.)
2. **§3.3 is INCOMPLETE — two more `answerBondBps` readers**, in a plan whose preamble promises
   enumeration by grep:
   - `court.gno:251` — the appeals-lane filing loop. All three panics move **safe** at 600 (meta
     filing 75→53 against a bar of 500). But it is the *same block* §2.1 sends you to for a comment
     fix, so **Step 2 and Step 3 both touch it** and the plan never connects them.
   - **`court.gno:626` — `supplyFloor`'s runtime lid. A live behaviour change, not a deploy check.**
     The lid rises **1.415×**, so the answerability and deposit floors rise where it binds and its
     binding region shrinks from supply < ~30 CC to < ~21 CC. Tiny-court-only, but **unenumerated
     and money-adjacent.**
3. **Step 3 has no corpus-row list and it breaks FOUR anchors** — rows **116, 117, 118**
   (all anchored on the `cs.sideConv(verdict)` + floor block any re-keying must rewrite) and **426**
   (anchored on the literal `answerBondBps = int64(5000)`, which §3.1's "derive it as
   `slashXBps * 4 / 3`" necessarily deletes). `check-mutation-anchors.py` is wired into `make check`
   and fails on `count != 1`. **Step 3 as planned fails `make check` with four BAD ANCHOR errors the
   plan never mentions.** §2.5 does this job properly for Step 2; §3.4 stops at fixtures.
4. **§2.5 omits corpus row 786** (`quality.gno`, anchored on the exact `if !conclusive { return }`
   block S4 edits). Add as re-verify. Rows 21 and 323 share the predicate but live in `session.gno`,
   and the guard scopes per-file — so excluding those was **right**.
5. **`check-citations.py` forbids new `file:line` citations inside `realm/r/kourtv2`** — and this
   plan's entire prose is in that form while §2.1/§2.2 instruct comment rewrites. **An implementer
   transcribing the plan's reasoning into a code comment trips `make check`.**
6. **Step 1 shifts every citation below `crystallize.gno:83` by 7 lines** (`:113`, `:265`, `:276`,
   `:302`). §11.8 flagged exactly this hazard for C0 and prescribed end-of-file helpers; **the plan
   fails to apply its own rule to Step 1.**

### 7.7 Enumerations that were RIGHT (verified)

§1's "exactly one site"; `cs.tier`'s money readers `:83`/`:265`/`:276` plus authority
`quality.gno:613` and the `c.tier` naming trap; §2.1's `:580-582` and `:607-609`; the credential
bar at `dispute.gno:321` **and** its 5.01× claim; §2.1's election-lane unreachability; §2.3's
`quality.gno:82`; §0.3's ground truth (`maxMidGrossBps = 1927`, ceiling 3083 bps,
`votingBlocks == escrowMinBlocks == 120_960`).

**And §3.4's "exactly three" is confirmed by running it** — `TestAnswerBondCapBindsWhenTheFloorIsBelowIt`,
`TestEconomicConstantsAreTheCalibratedValues`, `TestSlashReserveDrawProportionalAtSettle`, and
nothing else. So §3.4 correctly resolved the contradiction between §14.6 ("a fourth") and
§11.7/§13.1/§15.5 ("exactly three") **in favour of three.**

### 7.8 The two "unverified" guards are now VERIFIED

Both are **read-only**, so they run in the owner's tree without touching it — which is precisely
what a shadow copy could not do, having no `.git`:

```
check-paths:        296 files scanned, 4 retired spellings, 23 fixtures hold, rc=0
check-guards-armed: 15 committed guards all named in selftest-checks.py,      rc=0
```

**Both baseline-green.** One live forward risk remains, and it is cheap to pre-empt: **if Step 2
adds a guard script for the new `mustSane` invariant, `check-guards-armed` will fire** unless it is
registered in `selftest-checks.py` in the same commit.

### 7.9 Scope correction worth reading before estimating

**No fixture in the suite reads `quorumFloor` or `QuorumFloorOf`** — zero hits across all
`*_test.gno`. S1 rewrites the verdict lane's turnout bar with **no shipped fixture asserting its
value**; the "88/88 provably dead" result came from an audit harness, not the suite.

And **§2.5's heading understates the work**: "3 shipped + 5 corpus rows" reads as the total, but the
real total is **12 new fixtures + 3 re-derived + 5 corpus rows**. Relabel it so nobody scopes from
that line.

---

## 8. THE FOUR STRUCTURAL FIXES — concrete solutions, for vetting

Written before the vet so it has a fixed target. **Status: PROPOSED. The bond work
(steps 1 and 3) has landed; this is what remains of the verified batch.**

Each solution states the sites, the invariant, what it deliberately does NOT do, and the
residual it leaves. Line references are given as anchors, not numbers — `check-citations`
forbids `file:line` inside `realm/r/kourtv2`, and step 3 already tripped it once.

---

### S1 — a small claim's verdict must be reachable

**The defect.** `quorumFloor` maxes its X̄ arm against `quorumSupplyBps` of *court supply*,
but the prize is denominated in *claim stake*. Below X̄ = 5%·supply the robbed pool cannot
clear the bar **even voting unanimously at any concentration** — measured 6.6× short at 1% of
supply. `dispute.gno`'s own comment states the consequence: *"an unreachable quorum does NOT
mean 'no verdict' … the bar hands the decision to the party it exists to police."*

**Solution.** **Delete** the supply arm and the now-dead v0.29 clamp below it — not gate them.
Measured across 88 rows, the gated form makes both blocks *provably dead* (zero divergence), so
gating leaves two unreachable blocks and a page of prose describing behaviour that no longer
runs. The function becomes, in full:

```
floor = max(1, min(X̄frozen, votable/3))
```

**And re-anchor the credential bar in the same commit.** `credEligible`'s test is `yes >=
floor/4`, documented as costing ~1.25% of supply. With the supply arm gone that becomes X̄/4 —
a **5.01×** cut, measured: two socks totalling 1.125% of supply mint an `AnswerRecord`, and
three such points buy the 24h answer-priority window. Replace with `yes >= credWeightFloor(c)/4`
where `credWeightFloor = mulDiv128(PastTotal(Epoch()-1), quorumSupplyBps, Bps)` — keeping the
documented price while the *verdict* bar relaxes.

**Deliberately NOT done.** `qualityBars` is left alone, and the election lane cannot be reached
by this clause at all (`electionFloor` is 5% of *votable*, no X̄ arm; `mustElectionInvariants`
reads only package constants). Both verified; all ten `TestElection*` pass.

**Residual, accepted and stated.** The verdict and quality lanes now disagree in exactly the
band this fixes — at X̄ = 1% of supply the verdict quorum is 399 CC while the quality full bar
stays 2000. The slash deterrent **keeps** its supply anchor, which is the right side of that
trade, but it makes `court.gno`'s "prices filing above winning the vote" comment untrue of the
verdict lane. **Fix that comment in the same commit.**

**Also stated because it is worse than the original draft admitted.** The relaxation lets an
attacker holding **1.25% of supply** flip a true answer to an overturn unopposed: cash swing
−39.90 → **+159.60 CC**, own bond returned whole, comp minted, the honest answerer's bond
burned. It is **not a gamble** — with `yes > 0, no = 0` the threshold is trivially met, and an
uphold requires an opponent to turn out, which is this item's own premise. The trade still
favours relaxing, because the snipe it fixes is currently **free** while a false overturn costs
a bond. But it is a trade, not a free win.

---

### S2 — a quorum-less verdict must not finalize by apathy

**The defect.** `votingBlocks == escrowMinBlocks == 120_960`, and `escrowWindow` returns
`escrowMinBlocks` exactly whenever `extraDays` rounds to zero — guaranteed on any court with
`minted == 0`. `escrowUntil` is set **once** at the first resolution and never recomputed, and
each round burns a full `votingBlocks`. So round 3 cannot open, `failedRounds` caps at **2**
against `maxFailedRounds = 3`, and `provCloseClaim` is **dead code**. Meanwhile the *first*
failed round already set `cs.provisional = cs.answer`. **Apathy resolves the claim in the liar's
favour** — the outcome that branch's own comment forbids. Three shipped fixtures already widen
the window in-test to reach provClose, one with a comment naming the bug.

**Solution — a defaulted-verdict-only window.** Keep "set once, never recomputed". At the first
resolution, if `cs.failedRounds > 0` (i.e. the standing verdict is a quorum-less **default**),
floor the window at

```
ladderWindow = (maxFailedRounds-2)*votingBlocks + (maxFailedRounds-1)*graceBlocks + 1
```

= 155,521 blocks (9 days) on defaults. A **decided** first round keeps today's window,
bit-identically.

**Do NOT raise `escrowMinBlocks`.** Measured: it taxes an honest *disputed* claim from 14 to 21
days of frozen winning-side principal — verbatim the objection used to reject a longer settle
window — and it **doubles the reopen grind chain** (decided rounds 2 → 4), because
`failedRounds` resets on every decided round so the doubling ladder is inert on a decided chain.

**Invariant, in `Params.mustSane` and NOT `mustInvariants`** — all three terms are per-court
params, which is exactly why `mustInvariants` never saw the coupling:

```
defaulted := max(ladderWindow(p), p.escrowMinBlocks)
if defaulted <= p.votingBlocks*(maxFailedRounds-2) { panic(...) }
```

**Known slack, kept deliberately.** The measured minimum for round 3 to open is `votingBlocks +
1` = 120,961, because round 2 opens in the same block round 1 resolves. `ladderWindow` carries
34,560 blocks more than that. **Keep it and say so in the comment**, or a later reader "fixes"
the conservatism as a bug.

---

### S3 — a claim that ends undecided must still pay

**The defect.** `provCloseClaim` refunds the deposit **and** fee with the explicit comment
*"provClose is not a conclusive low"*, then sets `tier = tierLowX` and `tierFinal = true`, and
`Crystallize` refuses on top. It treats itself as not-a-low for the deposit and as a low for the
draw. Honest winners get principal at 1× and nothing else, **on a claim where nobody was found
at fault** — measured, it converts a claim paying 19,584 into one paying 0.

**Solution.** Three edits, one commit:

1. `provCloseClaim` sets the plain default MID **through the same guarded predicate the other
   terminal paths use** — `if !cs.tierFinal && !cs.slotConsumed { cs.tier = tierMidX }` — so a
   genuinely adjudicated low is never clobbered.
2. `Crystallize`'s refusal narrows to `cs.closed` only.
3. **`OpenFlag`'s `provClose` arm must go too**, or every claim that outlasted the ladder gets an
   **undemotable MID**: the failed-quorum branch deliberately never calls `resolveQualityRide`,
   so the ladder's own rides cannot demote it either.

**Correctness target.** A provClosed claim pays **bit-identically** to today's 2-failed-round
Finalize path, with the reserved pool figure identical across runs — so it is structural
equality, not two clamps agreeing on zero.

**State plainly what it does NOT do.** On a provClose the standing provisional is **always**
`cs.answer` (set by the first failed round), so this pays the **answer side**. On an
honest-answer-plus-apathy claim that is right; on a **sniped** claim it pays the sniper's dust
pool and **the robbed majority still gets nothing.** S3 does not rescue the robbed pool.

**Two residuals, demonstrated rather than papered over.**

- **It opens a demote-only, economically inert flag lane on provClosed claims.** Every priced
  disposition on that lane is gated on `answerBond > 0`, and `provCloseClaim` returns the bond
  whole — so a full-bar ⅔-low flag demotes while levying **no slash**, burning **no dust**,
  paying **no bounty**, and returning the flagger's bond **whole**. Not an exploit (reaching
  provClose costs three half-burns, ~70%·X̄, against a draw bounded at 19.27%·X̄) but the lane
  has no teeth there. Fix if wanted: have `provCloseClaim` retain a `slashSizeFor` reserve as
  `Finalize` and `SettleUndisputed` do. **Not in this batch.**
- `provCloseClaim` still calls `stripExit`, so the claim leaves the policing strips while the
  flag lane is open. Its comment claims "unflaggable" — **correct the comment.**

**And it must ship with the §0.1 decision.** Dropping `OpenFlag`'s arm re-admits the
supply-floorless demotion, and `ResolveFlag` overwrites `cs.tier` with **no `tierFinal` guard**
while `OpenFlag` never checks it — so `provCloseClaim`'s `tierFinal = true` does not protect the
new payout. Measured: a 200 CC dust flag zeroes a provClosed claim's whole payout for free.

---

### S4 — a verdict round must not zero the tier it just vindicated

**The defect.** An ordinary overturn restores `cs.tier = tierMidX` and pays honest winners in
full. But `resolveQualityRide` can set `tier = tierLowX = 0` on **the same tally that overturned
the answer**, zeroing the entire draw — while `quality.gno` argues at length that "was the answer
right" and "is the claim worth anything" are *different questions*. And it is **cheap**:
`demotionBar = arm/4` has **no supply floor**, so a low bloc of **49 bps of court supply** zeroed
the whole draw of the pool the same tally had just vindicated, for the price of one `VoteQuality`.

**Solution — require the demotion's own mandate; do NOT exempt the round.** After
`if !conclusive { return }`, re-classify the tally as **inconclusive** when it would demote on a
round that overturned:

```
if tier == qualityLow && cs.provisional >= 0 && cs.provisional != cs.answer {
    if _, fb := qualityBars(c, cs); turnout < fb || cs.qLowW*3 < turnout*2 {
        return
    }
}
```

**Why re-classify rather than skip.** Skipping the demotion would forfeit
`burnConclusiveLowDust` (the junk author keeps deposit and fee) **and** latch `slotConsumed` on
a tier it declined to set, permanently closing the flag lane. Re-classifying as inconclusive
does neither: the slot stays open, so a real full-bar ⅔-low can still land later *with a bond*.
The bar chosen is `ResolveFlag`'s own `slashGrade` test — the lane already demands it before
destroying anything of comparable size.

**`cs.provisional >= 0` is load-bearing, not defensive.** `-1` also satisfies `!= answer`, and
`TestRideRatchetAndSlashPredicate` drives exactly that state. **It failed the first version of
this predicate and was NOT asserting the bug** — it caught a real over-reach.

**The scoping is pinned by shipped code.** `TestUnmandatedDemotionRideStillLands` drives an
*uphold*, so `provisional == answer` and S4 must **not** fire. Had this been written as "no
demotion on any decided round" instead of "on an overturn round", that fixture would have
failed.

**Known, and owner-flagged rather than fixed:** the reverse direction is also live — a
`reaskQualityTally` wipe lets a later, smaller poll **promote** a tier that a larger electorate
had adjudicated LOW. `quality.gno` admits this and defers it. Not in this batch.

---

### Ordering for the batch

**One commit for all four, with S3 before S2 if ever split** — S2 alone converts a claim paying
19,584 into one paying 0. **S1 and S4 are order-free.** And the standing dependency holds: the
comp drought must be fixed before S3 or S4 pays out on any claim with a *decided* round, since
that claim's own overturn reserves a senior comp ahead of the draw being restored.

---

## 9. VET ROUND 1 (S4 + S1) — S1 GO with an amendment; **S4 NO-GO as justified**

Independently implemented and measured against HEAD on shadow copies. 17/17 mutations caught,
0 survivors, 0 invalid builds.

### 9.1 §8's S1 JUSTIFICATION IS FALSE — the robbed pool cannot vote at all

§8 says *"the robbed pool cannot clear the bar even voting unanimously at any concentration."*
**That sentence presumes they can vote.** They cannot. `VoteDispute` refuses the author, the
answerer, and **any address with a staker row on either side** — and there is **no
`stakers.Remove` anywhere in the realm**, so the row that disqualifies them is permanent.

**M:** the robbed pool held **10,000 CC against a 2,000 CC bar — 5× the quorum floor — and was
refused at the door.** Staked CC is not escrowed (the coins never leave the staker), so the
weight genuinely exists and is genuinely rejected. On an answered claim `Unstake` is refused
outright, so the victim cannot even exit the role; and a staker who withdraws **100% before**
the answer is *still* a participant and still refused. An outsider who never staked is accepted.

> **So S1 lowers a bar only third parties can clear.** The robbed pool's problem was never the
> bar's HEIGHT — it was the FRANCHISE. The real benefit is that a verdict becomes **reachable at
> all**, so third-party jurors decide the claim instead of the failed-quorum branch defaulting to
> `cs.provisional = cs.answer`. That is genuine, but it is **entirely intermediated by
> outsiders**, and it is **symmetric**: the same relaxation is what makes §9.3's malicious
> overturn reachable, by the same outsiders.

Also worth stating: `OpenDispute` refuses only the answerer, so **a robbed staker can pay the
bond and then not vote in the round they paid for.**

### 9.2 S1's two other corrections

**Churn is one corpus row, not zero** — `M2-1: credEligible needs no adversarial weight` anchors
on the exact line being changed. One-line re-derive. Every other guard green, **including
`check-paths` and `check-guards-armed`**, which §16.6 had left unverified: both clean.

**The no-fixture gap is worse than stated.** Zero readers of `quorumFloor`/`QuorumFloorOf` across
all 64 `*_test.gno` — confirmed. **And the same is true of the credential bar:** its only shipped
fixture drives `yes == 0`, so **any positive bar passes it.** Both of §8's S1 numbers were
audit-harness results with nothing in the suite behind them.

**The 5.01× is not a constant.** It is `5% ÷ (X̄ as a share of supply)`: **10× at X̄ = 50 bps**,
5.01× at ~1%, and **50× at the ordinary answerability floor** — the smallest legal claim. §8
quoted the mid-band case as if it were the number.

### 9.3 REQUIRED AMENDMENT — the credential bar must read the TALLY'S OWN epoch

§8's `credWeightFloor(c)` is a **regression**, measured. `yes` is weighed at the *proposal's*
snapshot epoch; `credWeightFloor(c)` reads `Epoch()-1` at *resolve*, ~168 epochs later. **The bar
therefore moves under a frozen tally, and anyone may mint inside the 7-day window** to strip an
honest contested uphold of its difficulty credit. It cuts both ways — burns during the window
*lower* the bar, and `ResolveDispute` is permissionless, so a farmer picks the block.

| tree | sock 700 CC vs bars 125 / 1250 | supply doubled mid-window |
|---|---|---|
| baseline | refused | credential earned |
| S1, no re-anchor | **MINTED** — the silent cut | earned |
| S1 + §8's `credWeightFloor` | refused — price restored | **REFUSED — regression** |
| S1 + `credWeightFloorAt(proposal epoch)` | refused | earned — baseline-identical |

**Fix is one argument:** `credWeightFloorAt(c, c.gov.EpochOf(cs.proposalID))`.

### 9.4 The malicious overturn, repriced — §8 is stale by 8.33×

**§8's "+159.60 CC" is 50%-answer-bond arithmetic.** `76032ae` cut the bond to 600 bps, so the
dispute bond is 2.4%·X̄ and comp is 4.8%·X̄ (both `compAmount` arms exactly equal at 6%). The swing
is **−1.2%·X̄ → +4.8%·X̄**.

**And the minimum weight is not 1.25% of supply** — §8 conflated the quorum floor with the
credential bar. It is `min(X̄, votable/3)`, i.e. **the claim's own X̄**: 0.5% of supply measured,
**0.1% at the answerability floor**.

**It parallelises, which is the sharp part.** Voting consumes no weight. **M: one 600 CC bloc
overturned TWO claims in the same vote window** — both bonds returned whole, 48 CC of comp minted,
two honest answer bonds burned. The weight is a *stock* and the profit a *flow*, and S1
re-denominates the stock from supply to claim size — so claims-attackable-per-CC-held rises and
small claims become individually attackable. Wallet separation is free: `isParticipant` is
per-claim and per-address, so stake with A, dispute with B, vote with C.

**One consequence §8 missed:** `mustInvariants`' "prices filing above winning the vote" check is
not merely untrue-in-comment for the verdict lane, it is **inverted** — filing a floor-sized claim
costs `1.3083 × X̄floor` while the verdict bar is `1.0000 × X̄floor` of unspent, reusable weight.
It still passes numerically and still means something for `qualityBars`' full bar and the election
floor. **Retarget the comment at those two lanes and state the inversion deliberately.**

### 9.5 S4 — NO-GO AS JUSTIFIED. The mechanism works; both halves of its rationale are wrong.

**It is NOT `slashGrade`.** `slashGrade` has a third conjunct — `cs.answerBond > 0` — and that is
**identically false everywhere S4 applies**, because the overturn branch burns the bond to 0
*before* calling the ride (**M:** `answerBond == 0` on every overturn ride). So `slashGrade` is
**unsatisfiable** on an overturn round: the lane cannot "already demand it", because here the lane
can demand nothing.

**And the two prizes are not comparable** — the slash keys on the **answered** side, this draw on
the **winning** one, so neither bounds the other:

| regime | slash | draw S4 protects | ratio |
|---|---|---|---|
| 4 wk | 450 bps·X̄ | 145 bps·X̄ | **3.08×** |
| 11 wk | 481 | 400 | 1.20× |
| 11 wk, dust-answered | 450 | **694** | **0.64× — the draw is the LARGER prize** |

The slash has a hard 4.5%·X̄ floor; the draw has none. **Wrong bar** — over-tight by 3× on young
claims, and guarding *less* than the draw on the dust-answered ones that matter most.

**The price §8 does not state.** `fullBar = max(5%·supply, min(X̄, votable/3))`, so the mandate
demands 5% of court supply of quality turnout **plus a ⅔ supermajority**, where an ordinary
demotion needs `demotionBar/4` and no supply floor at all:

| X̄ as share of supply | 10 bps | 100 bps | 200 bps | ≥500 bps |
|---|---|---|---|---|
| fullBar ÷ demotionBar | **200×** | 20× | 10× | 4× |

It is also **two** upgrades, not one — `applyQualityTally` demotes on a weighted **median**, S4
demands **⅔**. **M:** a 60%-low bloc *above* the full bar is refused, restoring a draw from 0 to
17,548,387. Instrumented over the shipped suite: **67 quality tallies, 43 conclusive-LOW, 12
(28%) lack S4's mandate** — and fixtures over-represent 5%-sized whales, so 28% is a floor.
**S4 also does not bind a ≥5%-of-supply holder at all**: one whale wallet carries both the
overturn and a mandated ⅔ low.

**S1 × S4 is "order-free" in ordering and NOT in effect.** On the combined tree the mandate bar
becomes a *multiple* of the verdict bar exactly in the band S1 exists to fix — **5000% at X̄ = 10
bps**, 1000% at 50, 500% at 100, converging to 100% only above 5% of supply (on baseline
`fullBar == quorumFloor` identically). **S1 makes overturning a junk claim cheaper while S4 makes
demoting it on that round dearer.**

### 9.6 The finding that decides S4: it re-routes the hazard and PAYS the attacker

`ResolveFlag`'s conclusive-LOW threshold is **the same supply-floorless `demotionBar`**. So the
identical dust wallet re-lands the identical destruction one transaction later:

| | baseline (ride latches) | S4 (slot open, then one flag) |
|---|---|---|
| final tier / winners | LOW / **0** | LOW / **0 — bit-identical** |
| attacker weight | 500 CC (50 bps, 14× under fullBar) | **the same 500 CC** |
| attacker cash | 0 | **0** — flag bond **refunded whole** (`answerBond == 0` kills both the half-burn and slashGrade) |
| attacker revenue | none | **+0.88 CC bounty MINTED** |
| cost of the workaround | — | one tx, 7 days, 28 CC locked |

> **S4 converts a FREE destruction into a PAID one, delayed by a week.** §8's "the slot stays
> open, so a real full-bar ⅔-low can still land later *with a bond*" is half the story: a **dust**
> low also lands later, with a **refunded** bond and a **bounty**.

And with `slotConsumed` never latched, `reaskQualityTally` stays in its "nothing adjudicated yet"
branch forever, so the one-shot `qualityReasked` budget is **never spent** — every reopen round is
a fresh tally in which every address votes again (**M:** the same dust address re-voted).
**Defenders must win every round; the attacker needs one.**

### 9.7 The recommendation, and it changes the batch

> **Land S1 now, with the epoch amendment. HOLD S4 pending the owner's ruling on giving
> `demotionBar` a supply floor — because with that floor S4 becomes UNNECESSARY:** the cheap
> demotion disappears from the ride lane and the flag lane at once. Without it, S4 buys a
> seven-day delay and hands the attacker a bounty.

S4's code is correct and fully mutation-covered (7/7). If it lands anyway it must land with the
residual pinned and the rationale corrected, because §8 as written reads "hazard closed" and it
is not.

---

## 10. VET ROUND 2 (S2 + S3) — both GO, and **the batch is NOT blocked**

Independently implemented on six shadow trees. 16 hand-built mutations → 14 caught, 2 documented
structural survivors, 0 invalid builds. 894 corpus rows clean, all guards green.

### 10.1 THE HEADLINE — §7.2's gate is over-strong and S3 can land with §0.1 open

> **A dust flag can only return a provClosed claim's payout to ZERO — which is exactly what it is
> today.** So S3 is a **Pareto improvement with §0.1 wide open**: best case a full MID draw, worst
> case today's zero. **There is no new value at risk** — the lane destroys a *counterfactual*, not
> a realized draw.

§7.2's "satisfiable in test and defeated for free in production" is a true statement about the
*exit criterion*, not about a regression. Two supporting facts: on a provClosed claim the lane is
**unrewarded** (no bounty, no dust burn) where §0.1's own measurement shows it is **net profitable**
on ordinary claims — so no attacker prefers it; and the pre-existing lane already covers every
claim that actually draws.

**Change §7.2 from a GATE to a documented residual.** §0.1 stays exactly as urgent as it was, on
the claim class where it is actually profitable. The one thing S3 must do differently from §8 is
state the exposure as **inherited, not created**.

### 10.2 And KEEPING `OpenFlag`'s arm is strictly worse — the decisive argument, unstated until now

**M**, on a purpose-built tree: a sybil of the answerer runs the ladder back to back, and a
full-bar **30,000 CC** quality bloc is refused a window at *every* height ("a dispute is open" ×3,
then "closed without a draw"). provClose then shuts the lane for good and the claim crystallizes at
`tier=1, drawWinners=19,584, slotConsumed=FALSE`.

> **8.4%·X̄ buys total quality-lane immunity plus a full MID draw** — the purchasable-immunity shape
> v0.47 and v0.50 each closed. Neither §8 nor §16 states this, and it is the real reason the arm
> must go.

### 10.3 S2 — GO, with my invariant replaced because it was VACUOUS

**§8's `mustSane` check can never fire.** `ladderWindow ≥ votingBlocks + 2·graceBlocks + 1 >
votingBlocks` for every `p` clearing `graceBlocks ≥ 1`. Implemented verbatim: suite green and
`TestParamsMustSaneRefusesEachMalformedField` **unchanged** — which also **refutes §16.5's claim
that that fixture was a real cost of S2.** It breaks on the *corrected* invariant, not on mine.

**Corrected:** `escrowMaxBlocks < ladderWindow(p)` — it has a firing input, and that input is
exactly the `escrowMax == escrowMin == 120_960` case §16.5 described.

**And "floor the window" is singular where there are TWO arms.** `escrowUntilAt` is what actually
gates; **flooring only the height arm leaves the bug fully live.** Both single-arm mutations are
caught by the landed fixture. Unmentioned in §8 and §16.

**Item 3 confirmed, scoping made exact.** The floor is active only when `escrowWindow <
ladderWindow`, and then W = 155,521 ∈ (V, 2V] ⟹ capacity 3 ⟹ a provClose there is three
*consecutive* failures ⟹ `decidedRounds == 0` ⟹ **no comp. The comp-drought dependency for the
S2-enabled population is zero.** But **S3's C0 dependency does not go away**: the
decided-then-provClose shape was measured on the **baseline** tree at W = 259,200, no S2 involved.
What is zero is the *increment* S2 adds.

**The grind slack is NOT free.** §16.7 called it conservatism. Measured, the delay-maximising chain:

| tree | rounds | answer → settled | attacker cost |
|---|---|---|---|
| baseline | 2 | 414,718 (24.0 d) | 360 bps·X̄ |
| S2 | 2 | **449,279 (26.0 d)** | **360 bps·X̄ — identical** |

**S2 buys the attacker +2.0 days and no extra round, at the same price**, and those two days *are*
the grace term. Keep it — the minimal window needs every round opened and resolved in the same
block, which is unusable — but **price it in the comment rather than calling it necessity.** Note
also that `graceBlocks` is the governor's post-settle *execution* grace, dimensionally unrelated to
the ladder.

**Two corrections to my own arithmetic.** `R(W) = 2 + floor((W−1)/V)` is a **capacity** bound;
realized failed rounds are `min(N(W), maxFailedRounds)`, and §7.4's "reproduces all three
measurements" mixed failed-round with decided-round counts. And **"`provCloseClaim` is dead code"
is conditional** — only where `Price(minted) == 0` or `extraDays == 0`. It is **live today on any
court with a curve price**, which makes S3 a fix for a live state rather than a hypothetical one.

**A budget term neither doc mentions:** the height arm is dead for post-upgrade claims — the gates
read `escrowUntilAt` whenever the stamp exists, so the real budget is wall-clock **seconds** while
the vote closes on **height**, with 5 s/block hardcoded. At a 2.5 s cadence the **default** window
already admits 4 rounds. So the whole "dead code" finding is cadence-conditional.

### 10.4 S3 — GO. Correctness proven in ONE run, not across trees.

Two claims in one court, staked and answered in lockstep so their pools freeze with identical
conviction:

```
F (2 failed → Finalize)   pool=22767 w=19584 a=1958 n=1224 carrot=1593
P (3 failed → provClose)  pool=22767 w=19584 a=1958 n=1224 carrot=1593
```

**Non-clamping asserted per claim** as a precondition (the fixture fails otherwise): draw cap slack
1,317×, `SeniorOwed == 0 && decidedRounds == 0` on both.

**The guarded predicate, verified on money in the one state `!tierFinal` alone would miss** — a
full-bar ⅔-low landing *during* the ladder leaves `slotConsumed = true, tierFinal = false`. Both
"guard dropped" and "keeps only `!tierFinal`" are caught. **"Keeps only `!slotConsumed`" SURVIVES**:
`tierFinal == true ⟹ slotConsumed == true` at every writer, so `!tierFinal` is redundant *at this
site*. Keep it for the three-terminal-path symmetry and **document it as unmutatable** — §16 does
not report this survivor.

**Readers of `cs.provClose`: 12 grepped.** Needing change beyond `OpenFlag`: **three `render.gno`
lines, all of which describe MONEY** (the flag-slot line, the accuracy-pull hint, and
`claimStatus`'s text) — **two were mutation SURVIVORS until assertions were added**, so §16.7's
"render drift fixed" was true of the text and false of the guarding. Plus **`refundSlash`'s comment
is now FALSE**: its "Crystallize panics on provClose so the reserve must be paid straight back or
it strands forever" no longer holds. Unlisted by both §8 and §16.7.

**My price was stale by 8.3×.** Three half-burns are **8.4%·X̄**, not ~70% — the `20%·X̄` dispute
arm can **never** bind post-`76032ae`, because it needs `A ≥ 50%·X̄` while `A ≤ 30.83%·X̄`. The
*conclusion* survives structurally rather than by calibration: `cost = 1.4·A ≥ 2.24·mg` against a
MID prize of `1.07·mg` ⟹ **ratio ≥ 2.09**. But **my comparison was between the wrong parties** —
the half-burns are paid by the *disputer*, and the demotion benefits *nobody* on a provClosed claim.

**Unlisted consequence of S3:** pre-S3 the robbed majority had one lever — spend `1.4·A` to force
provClose and at least **deny** the sniper. **S3 removes it.** Neutral-to-good in cash, and
denial-by-burning is not worth preserving, but it is a change neither doc stated.

**Corpus impact understated.** Three rows broke, and one — `provCloseClaim: a closed claim is left
at the MID tier` — was **a mutation-tested lock on the very defect S3 fixes**, so it inverts.
§16.1's "5 corpus rows" is really **4 edits + 12 additions**.

### 10.5 Ordering, confirmed with a better reason

**S3 before S2** — not because S2 creates the population, but because **provClose is live today**
(§10.3), so S2 does not create it at all. The `mustSane` churn belongs with S2; **S3 alone touches
no params.**
