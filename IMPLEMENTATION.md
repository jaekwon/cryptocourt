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
