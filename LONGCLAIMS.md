# LONGCLAIMS.md — rewarding a five-year call

**Status: RECONSTRUCTED SPECIFICATION, NOT AUDITED, NOT IMPLEMENTED.**

An earlier version of this design was worked out in conversation and **never written down**; it
was dropped when attention moved to the answer bond. That was a mistake — the owner named this
the *primary* concern and the bond the secondary one. This file exists so it cannot be lost
again. Numbers here are **re-derived from scratch** and every one of them is marked as
**(D)** derived, **(S)** read from source, or **(A)** assumed and needing audit.

**Every (S) claim in this file has been re-verified against the tree** (round 3 — a source
re-verification pass; rounds 1 and 2 are §8 and §9), and all twelve hold on the substance:

- `deadClaimSecs = int64(12 * 7 * 86400)`, `priorityColdStartN = 3`,
  `priorityWindowBlocks = int64(17_280)` — all as stated.
- §8.1's "all **7** non-test sites touching `answerRecord.score`" measured at exactly 7, and
  every one of them still inside `records.gno`, which is what makes the "only authority"
  argument hold.
- `resetOverturned` still zeroes the whole score (`r.score = 0`).
- The fee still burns unconditionally when a claim dies (`c.coin.Burn(c.escrow, cs.fee)` in
  `CloseDeadClaim`), with the deposit refunded alongside it — §4.3's anti-spam floor.
- `PostAnswer`'s deadline refusal has no `cs.closed` dependency, so "whether or not anyone has
  closed the claim" is exact; its own comment gives the reason (closing is "permissionless but
  OPTIONAL").
- `WithdrawStake` (in `session.gno`, not `stake.gno`) returns principal "1× regardless" and is
  withdrawable at verdict-final on both sides — §4.2's straddle premise.
- Conviction is capital×time (`stake.gno`: "moving it costs capital × TIME, and past
  capital-time is immutable").
- **"Wordlocked" is this file's own jargon, not an identifier** — worth saying, because
  grepping for it finds nothing and a reader may conclude the mechanism is missing. It is
  `EditClaimTitle`'s polish window: the title freezes when that window closes, and
  independently the moment any stake lands ("staking has begun; the title is frozen"). So
  §4.1(d)'s premise holds, by a mechanism with a different name.

**But four of the nine ADDRESSES had rotted**, which is why they are all now written as
symbols rather than `file:line`. `claim.gno:368-378` pointed at the fee burn and now lands in
`EditClaimTitle`; `dispute.gno:312` at the uphold comp and now lands on `cs.answerBond = 0`;
`render.gno:378` at the record render, which moved about a hundred lines; `court.gno:227` at a
deploy ceiling, and now lands inside a comment explaining why a *different* check was removed
as tautological. Not one of the claims became false — only their addresses did, which is
exactly what `scripts/check-citations.py` says in its own header about why file:line citations
are banned. That guard's scope is source prose plus `docs/DESIGN.md`; this file was outside it,
and its own scope comment names that risk ("listed so that the first one somebody adds is
watched rather than discovered"). **Do not reintroduce a `file:line` here.** Extending the
guard over the working docs was measured and rejected: 312 such citations across the root
`.md` files, GAMETHEORY.md alone holding 103. Those are journals, where an address that
described the tree at the time of writing is a record rather than a defect. This file is an
active specification an implementer will follow, so it is held to the source-prose rule.

---

## 1. The requirement, in the owner's words

> *"If I knew with scant evidence that covid19 was lab leaked, I should be rewarded for staking
> on it the whole time, not be dismissed with a new claim."*

> *"I want to be able to claim rewards for 5 years, even if it doesn't give me the full inflation
> as if I had won several bets over those years — it should give me reputation or something and
> be > 0."*

Two things are conceded in the requirement itself and must stay conceded: **not** the full
inflation of five years of wins (that is a money printer), and **> 0** (today it is exactly zero).

## 2. What is already closed, so this does not reopen it

- **A claim cannot live five years.** `deadClaimSecs = 12 weeks` (S), keyed on `openedAtTime`,
  never paused. `PostAnswer` refuses past it whether or not anyone has closed the claim (S).
- **Re-answerability is dead, three independent ways** (`GAMETHEORY.md` §5). Resetting the
  verdict **bricks the claim 72h after any undisputed re-answer with no adversary at all** —
  7 of 7 exits refuse, principal locked forever, no admin path — and "nobody disputes" is the
  *modal* outcome. Keeping the verdict makes it a no-op. Resetting the whole round state hands a
  sniper 11 retries and takes per-claim destruction from 19% to 89.3%. **There is no fourth
  branch.** So "make the old claim answerable again" is not available and this design must not
  smuggle it back in.
- **Principal returns 1× and the prize is minted** (REGULATIONS.md's “Master finding”, escape (b)). Any
  reward here must not be funded by a counterparty.
- **An expired claim pays nothing today.** **M**, from `GAMETHEORY.md` item 4: a 300 CC position
  held 12 weeks evaporates **22.950015 CC of conviction** and receives principal only.

## 3. The shape: credit accrues ACROSS claims, and pays in cheaper answering

### 3.1 Why it cannot be conviction on one claim

Conviction is capital×time and accrues per block (S), but the claim dies at 12 weeks, so
conviction on any single expired claim is capped at 12 weeks' worth. **A five-year call is
therefore necessarily a sequence** — the COVID docket asks the laboratory question in 2020, 2023
and 2025, and that shape was *forced* by the rule, not chosen. So the unit of credit is
**one expired claim on which you held the eventually-vindicated side**, and a five-year call earns
credit repeatedly rather than continuously.

### 3.2 Why the payout should NOT be coin

Three reasons, and the third is the one that decides it:

1. **Regulatory.** A coin payout for a position on an *expired* claim is a payment contingent on
   an outcome the claim never adjudicated. Minting it re-opens exactly the question
   `REGULATIONS.md` escape (b) exists to close. A non-monetary credential is not a payment at all.
2. **The money printer the owner already named.** Any per-claim coin reward scaled to hold time
   is farmable by asking the same question repeatedly and holding both sides.
3. **There is a payout that is worth real money without being a payment: make answering
   cheaper for you.** The bond is the binding constraint on participation — `GAMETHEORY.md`
   measures the cost of a 50% bond as an ~8× restriction of the eligible answerer set. So:

> **The reward for being early and right is that your future answers cost less to bond, and you
> get first refusal on answering.**

That compounds in the direction you want — the person who was right early can act on their next
conviction more cheaply — and it mints nothing.

### 3.3 It reuses machinery that already exists

- `priorityNetRecord` and a 24h answer-priority window (S), gated at 3 qualified addresses
  (`priorityColdStartN`) (S).
- `credEligible` / `creditUpheld` / `resetOverturned` (S) — the existing credential already
  tracks *answer* accuracy. This adds a second source: *stake* accuracy on expired claims.
- **The deferred conviction lever** (`GAMETHEORY.md` §13.5) is a bond discount keyed to own
  conviction, already specced and straddle-proofed at `u* ≥ 1 − L0/k` = 25%. **A
  credential-keyed discount is the same machinery with a different key**, so these two should be
  designed together or one will foreclose the other.

## 4. The three hard problems, stated rather than hidden

### 4.1 LINKAGE — how does an expired claim connect to its successor? (the hardest)

Credit for holding "the eventually-vindicated side" requires knowing which later verdict
vindicated it. Options, with the objection to each:

- **(a) The author declares a parent claim ID at open.** Cheapest. But the author picks their own
  ancestry, so they can point a new claim at whichever expired claim makes their friends
  eligible. Needs the parent's *text* to be constrained, and Kourt has no semantic equality.
- **(b) Anyone proposes a link; it is voted.** Honest but expensive — a vote per link, on a
  system whose measured problem is already **turnout** (`GAMETHEORY.md` §4.2).
- **(c) Reuse the structure layer's argument edges.** **Blocked as stated:** the whitepaper
  commits that *"edges will be inert by design"* and that *"the chain does not infer."* A
  credential keyed on edges makes them non-inert, contradicting a published design decision. If
  this route is taken, that commitment must be revisited **explicitly**, not quietly.
- **(d) The claim's wordlock.** Claims are wordlocked (S). If two claims are *byte-identical* in
  their proposition, the link is mechanical and unforgeable. **This is the only option needing no
  new trust, and its limit is obvious:** re-asking the same question usually rewords it, and the
  COVID docket's three laboratory claims are **not** byte-identical.

**(A) My recommendation is (d) with (a) as a fallback**, precisely because (d) is
manipulation-proof and cheap where it applies. **This is the single biggest open question in the
design and it needs the audit's judgement, not mine.**

### 4.2 ANTI-STRADDLE — stake is no-loss, so why not hold both sides of everything?

`WithdrawStake` returns 1× on both sides (S), so holding both sides of a claim costs only carry.
If credit accrues to whichever side is later vindicated, **the dominant strategy is to straddle
every claim** and collect on all of them.

- Keying credit to **conviction** rather than stake presence raises the cost from zero to
  capital×time — this is the same fix that defeated the straddle in `GAMETHEORY.md` §13.5, where
  the threshold came out at `u* ≥ 1 − L0/k` = **25%** of the larger pool.
- **Netting the opposing position is the obvious next step and it was measured FATAL in the
  analogous case** (§13.5): with the self-tax removed, carry alone is 6.4× too cheap and no
  threshold ≤ 1 works. **(A) Whether that result transfers here is unknown and is the second
  question for the audit.**

### 4.3 ANTI-SPAM — what stops farming credit by asking questions nobody cares about?

Filing costs a deposit plus a fee (S), and **the fee burns unconditionally when a claim dies
unanswered** (S — `CloseDeadClaim`, claim.gno). So expiry is already not free. But:

- A self-answered pair of claims could farm credit at the cost of two fees.
- **(A) The floor is presumably that credit must require the claim to have carried *someone
  else's* conviction** — but `GAMETHEORY.md` already records that the "never carried stake"
  predicate is **farmable by a 1-unit self-stake**, so a naive version of this fails.

## 5. Draft numbers — ALL (A), for the audit to derive or refute

The earlier lost version had *~1 coin to file* and *~17 points for a five-year call*. I can
reconstruct the shape but **not** defend the constants, so they are stated as a starting point to
be replaced:

| quantity | draft | basis |
|---|---|---|
| credit per vindicated expired claim | 1 point × conviction weight | (A) |
| conviction weight | `min(1, ownConv / u*·mg_max)`, `u*` = 1/3 | (D) from §13.5's straddle threshold |
| five-year call, 5 re-askings, full weight | **5 points** | (D) — *not 17; I cannot reconstruct 17 and will not pretend to* |
| priority gate | 3 points (existing `priorityNetRecord`) | (S) |
| bond discount at full credential | ≤ 25% of the bond | (D) — §13.5 measured 75% of the price as non-discountable by construction |

**Note the honest discrepancy:** a five-year call earning ~5 points against a priority gate of 3
means the credential *saturates early* and the fifth year adds nothing. Either the gate rises,
the credit scales with hold time within each claim, or the reward has a second dimension. **(A) —
the audit should resolve which.**

## 6. What the audit must prove

1. **Linkage (§4.1).** Which of (a)–(d), or a fifth option? If (c), the whitepaper's inert-edges
   commitment must be revisited explicitly. If (d), how much of the real use case does
   byte-identity actually cover — the COVID docket is the test case and its three laboratory
   claims are **not** byte-identical.
2. **Straddle (§4.2).** Does §13.5's `u* ≥ 1 − L0/k` threshold transfer? Does netting fail here
   the same way?
3. **Spam (§4.3).** Is there a self-stake-proof predicate for "this claim carried real
   conviction"? The naive one is known farmable.
4. **Saturation (§5).** A five-year call must be worth measurably more than a one-year call, or
   the requirement is not met.
5. **Does a bond discount actually deliver "> 0" in the owner's sense?** It is worth money only
   if the holder answers again. Someone who was right once and never answers gets nothing. **Is
   that acceptable, or does the reward need to be claimable without further participation?** This
   is a question about the requirement, not the mechanism, and it should be surfaced rather than
   assumed.
6. **Interaction with the settled bond work.** The discount keys on the same floor C3 re-keys
   (`PostAnswer`'s bond floor) and draws on the same budget §13.2 shows is spendable only once. **Can the
   credential discount and C3 coexist, or does one foreclose the other?**
7. **Does any of this smuggle re-answerability back in?** §5's trichotomy is exhaustive; a design
   that effectively re-opens an expired claim inherits all three failures.

## 7. What this design does NOT do

It does not make an expired claim answerable, pay coin for an expired position, or give the
five-year holder anything approaching five years of inflation. **It converts being early and
right into cheaper future participation.** Whether that satisfies "reputation or something and
be > 0" is the owner's call, and §6.5 is where it gets decided.

---

## 8. AUDIT ROUND 1 — the payout was wrong; the fix is better and needs no linkage

**The bond discount is dead. The credential survives, in a different unit, with a payout that
sidesteps §4.1 entirely.**

### 8.1 The saturation is worse than §5 admitted — it is a step, not a curve

Enumerated, all **7** non-test sites touching `answerRecord.score` (S). **The only authority
reader is `mayAnswerInPriority` (records.gno), a boolean:** `score >= 3 && activePriority == 0`. Everything else is
threshold bookkeeping or display. `creditUpheld` increments by exactly **1** — no magnitude, no
time — despite the file header calling it "difficulty-weighted."

```
1-yr call → 1 pt → not qualified → payout 0
3-yr call → 3 pts → qualified    → payout = the WHOLE thing
5-yr call → 5 pts → qualified    → payout = the SAME whole thing
```

**Marginal value of point 3 is everything; points 1, 2, 4 and 5 are worth zero.** Not "saturates
early" — it is a Heaviside step and **four of the five years land on flat parts.**

**Two hazards §5 did not name:**

1. **A second credit source arms a court-wide lockout.** `creditUpheld` also increments
   `c.qualifiedCount`, and at 3 qualified addresses `priorityGateActive` turns on and
   `PostAnswer`'s priority gate **panics for everyone else for 24h**. So a cheaper second source lets **three
   addresses** lock the whole court out of answering. A reward that inflicts a refusal on
   non-recipients.
2. **`resetOverturned` zeroes the WHOLE score** (S). One wrong answer years later would burn the
   five-year call's entire reward. The comment says the record "prices a CAREER of honesty" —
   correct for answers, wrong for a durable stake credential.

> **Do not write the new credit into `score`. It needs its own field, and the existing step at 3
> must not be moved** — raising `priorityNetRecord` only relocates the step and also disturbs
> `priorityColdStartN`'s cold-start calibration.

### 8.2 §5's "scale credit with hold time within each claim" is NOT AVAILABLE

A derivation, not a preference. §13.5's straddle-proof weight is `u = ownConv / mg_max`, and
§13.5 **measured it age-invariant** — 11.1100% at the 3h maturity minimum, *bit-identical* to
11.1100% at 11 weeks. **A ratio of two conviction integrals over the same window cancels time
exactly**, so the straddle-proof weight is *mathematically incapable* of carrying hold time. And
the alternative was already refuted there: own-stake (average hold time) is scale-free, so one
base unit held for the claim's life scores maximal.

**So the two properties must be split across different factors:** a **gate** that costs capital
(`u ≥ u* = 1/3`) and a **magnitude** that carries time — safe *only because* the gate is
capital-priced.

### 8.3 The UNIT was wrong, which is why nothing worked

Sharper than saturation. §3.1 made the unit "one expired claim" — but **the number of re-askings
is exogenous.** The COVID docket asks the laboratory question in 2020, 2023 and 2025: **three
claims over five years.** Someone right on three rapid re-askings of a three-month controversy
earns the identical three. **A claim count cannot measure years.**

> **Denominate the credential in wall-clock coverage, UNIONED:**
> `coverage(addr) = |⋃ᵢ [holdStartᵢ, claimEndᵢ]|` over expired claims where `uᵢ ≥ 1/3`.

**The union is the load-bearing word** — summing overlapping claims lets 15 concurrent claims
manufacture 180 weeks inside one year. It is O(1) state and O(1) work: store `lastCreditedUntil`
and credit `max(0, end − max(start, lastCreditedUntil))`.

Three properties follow **by construction**:

1. **Monotone in years** — the measure *is* the requirement.
2. **Bounded, provably, with no economics needed.** Coverage cannot exceed wall-clock elapsed
   since the address's first stake — **one second per second, regardless of claims, straddles or
   sybils.** That is the money-printer proof, and it holds because the quantity is denominated in
   *time* rather than coin, with the calendar as its ceiling.
3. **The unscoped variant needs NO LINKAGE AT ALL** — union across all expired claims, no
   lineage. It rewards *tenure-weighted accuracy* rather than one specific five-year call. **This
   is the honest reduction if §4.1 turns out unsolvable**, and it dissolves the hardest problem in
   the design.

### 8.4 The reader must be hyperbolic, not capped-linear

Capped-linear re-saturates: `min(1, cov/156wk)` gives 33% / 100% / 100%, so five years and three
years **tie again**. Boundedness and strict monotonicity coexist only if the bound is approached
and never attained:

```
payout(cov) = P_max · cov / (cov + h),    h = 156 weeks
```

| call | coverage | share of `P_max` | vs 1-yr |
|---|---|---|---|
| 1 year | 52 wk | **25.00%** | 1.00× |
| 3 years | 156 wk | **50.00%** | 2.00× |
| **5 years** | 260 wk | **62.50%** | **2.50×** |
| 10 years | 520 wk | 76.9% | 3.08× |
| ∞ | — | → 100%, never reached | — |

Every additional week is worth something, forever, and `P_max` is never attained. `h` is the one
knob (h = 260 gives 16.7 / 37.5 / 50.0%, better top-end separation, thinner reward for one year).

### 8.5 THE PAYOUT: a bond discount fails, three independent ways

**(a) It pays ~0.16 CC.** The bond is **refunded** — §13.1 measured 91% back at settle, and §14.1
records the attacker's net bond outlay as **0, returned whole**. So a discount *frees capital*; it
does not pay coin. Its value is carry over the 72h lock at `r0WeeklyBps = 25`:

| discount | freed | carry over 72h |
|---|---|---|
| 30% of a 500 CC bond (today) | 150.00 CC | **0.1607 CC** |
| 8.125% of a 308.45 CC bond (post-C3 share) | 25.06 CC | **0.0269 CC** |

**0.016%–0.003% of X̄ per claim answered.**

**(b) It pays NEGATIVE 48 CC on the credential's own qualifying path.** `answerBond0` is the base
for the answerer's **uphold comp** (`ResolveDispute`'s uphold comp, which reads `answerBond0`), and at today's constants the dispute
arms **tie exactly** (`min(20%·X̄, 40%·A)` = `min(200, 200)`), so a discount bites from the first
basis point:

| d | bond | answerer's comp **if upheld** | burned **if overturned** |
|---|---|---|---|
| 0% | 500.00 | **160.00** | 500.00 |
| 30% | 350.00 | **112.00** | 350.00 |

> **A bond is a punishment instrument, so discounting it rewards the punished state.** The
> discount is worth **3.125× more to a liar (who forfeits) than it costs an honest answerer (who
> is comped)** — and `creditUpheld` fires *only* on contested-and-upheld, so the cost lands on
> exactly the outcome the credential exists to certify. Net: **−48 CC of comp to buy +0.16 CC of
> carry.**

The obvious dodge — discount the escrow but keep `answerBond0` at full magnitude — is precisely
§12.6's bug: *"the escrow asserts a bond it does not hold"*, which invariant I4 exists to forbid.

**(c) Its one real component already FAILED for the archetypal recipient.** §13.5 measured the
contrarian's spendable at **0.000000** with `PostAnswer` refusing, and **129 CC short** of the
discounted bond even after F9 frees their principal. **The five-year holder is capital-poor and
stake-locked by construction — that is what a five-year conviction *is*.** The payout was
denominated in the one resource they have least of.

### 8.6 Q3 answered: it does not foreclose the draw cap. C3 pre-empts it instead.

**The draw cap self-adjusts.** It keys on `cs.answerBond0`, which has exactly one write site, so
`L ≤ 1` survives at every discount level. **No foreclosure in either direction.**

**But the 33.125% surplus is an IDENTITY, not a measurement:** `1 − (tierMid + splitCarrot/100)/k
= 1 − 1.07/1.6`. It reproduces §13.2's `102.1734` / `90.6066` and §13.3's `53.0%` to four
decimals. And the two *discounts* conflict with each other **additively**:

> **`d_conviction + d_credential ≤ 33.125%`.** The conviction lever is specced at 25%, so the
> credential's honest share is **8.125 pp**. Past 33.125% the cap starts cutting **MID** draws —
> §13.4's "the published rate is a lie" defect, arriving through the door the cap was built to
> close.

**Correction to §13.5:** its "75% non-discountable / 25% ceiling" is a **straddle** bound, not a
structural one. The structural bound is **66.875% / 33.125%**, and the two budgets compose by
**sum**, not max. §13.5 does not say this.

**And a dependency, not merely compatibility:** without the draw cap, a credential discount is a
*destruction amplifier* — at d = 25% and HIGH, `L = 2.07/1.2 = 1.725`. **The discount requires the
draw cap as a hard precondition.**

**There is a free discount lane, and C3 destroys it.** The bond is computed base arm → court cap →
floor, with the floor applied last and dominating. A discount inserted *before* the floor can
never breach it, so it never touches collateralization, never touches `L`, and never draws the
budget. Free headroom at the 12-week corner: **38.3% today at 5000 bps → 0.000% under C3 at 600.**
The ceiling even falls out of `maxAnswerBondBps` (pinned at deploy by `mustInvariants`), a check the realm already runs at deploy.

> **So C3 pre-empts the credential's entire payout, because C3 spends the same currency on
> everyone.** §13.5's own table: 500.0000 → 249.7357 is a **250.26 CC** give-back, unconditional,
> to *every* answerer; the conviction lever adds 20.81; a credential lever is the same order,
> ~25 CC. **The credential would be worth 8–10% of what C3 gives away for free.** If a bond
> discount ships at all it must ship **before** C3 — which inverts the natural ordering — and §8.5
> argues it should not ship at all.

### 8.7 What CAN be paid — one recommendation, four rejections on evidence

| candidate | verdict |
|---|---|
| **Published standing / docket visibility** | **RECOMMENDED.** `renderClaim`'s answerer-record line already renders the record when `> 0`, so the surface exists. Mints nothing. Non-transferable by construction. **Accrues and displays with no further participation — the only candidate that clears that bar**, and the only thing a stake-locked five-year holder can actually receive. Coin value 0, but "reputation" is the owner's own named acceptable payout. |
| Claim-filing discount | **REJECT — circular.** Tempting, because the fee **burns unconditionally** on expiry, making it *real* coin (~2.4 CC, ~15× the bond discount's carry). But that same unconditional burn **is** the anti-spam floor §4.3 relies on. Discounting it funds the farm it exists to deter. |
| Voting weight | **REJECT + counsel flag.** REGULATIONS.md is direct: DAO Report "voting doesn't help"; governance + utility + yield "all three pull back toward Howey"; and **Ooki** reaches "members = token-holders who **VOTED**", so it *expands the personal-liability cohort*. |
| Waiver of `mustSpendable` | **REJECT on source.** `disposable` (lock.gno): only Stake, Unstake and the settlement withdrawal may touch that tree and **"no other path may touch this tree."** And it would not help — the contrarian is 129 CC short *after* F9. |
| Graded answer priority | **REJECT.** Participation-contingent (same failure), and it gates only ~10.4 CC — the answerer's real prize is the 160 CC uphold comp, which a discount *reduces*. |

### 8.8 Regulatory — §3.2's argument partly INVERTS

- **Howey prong 2 (common enterprise): clean.** A per-address, non-fungible, non-poolable
  credential adds no horizontal commonality.
- **Prong 3 (profit expectation): the strongest defence is precisely §8.5's weakness.** *Forman* —
  consumption defeats profit expectation. A credential redeemable **only by consuming the
  protocol's service** is a consumption right, not a return. **The participation-contingency that
  makes a discount fail the owner's "> 0" test is exactly what makes it regulatorily clean, and
  every fix that repairs "> 0" removes that defence.** That trade-off is the real §3.2 finding and
  it was not in the document. Counterweight: *Edwards* — fixed returns count, and a formulaic
  discount is fixed.
- **State gambling is the sharpest hazard and §3.2 never reaches it.** Elements are consideration
  + chance + **prize**. A credential with measurable cash value — the whole point of §3.2's reason
  #3, "worth real money" — is *something of value received upon the outcome of a future contingent
  event not under the actor's control*. **It weakens the "no prize" leg specifically, on the one
  axis REGULATIONS.md says relabeling has never survived on the merits.** §3.2's reasons #1 and #3
  are in **direct tension** and the document presented them as mutually supporting.
- **The "designed to evade" carve-out** plausibly describes a non-monetary credential structured
  *specifically so it is not a payment*. **Counsel flag, prominently** — §3.2 currently asserts the
  opposite.
- **Humphrey factor 2: split.** The discount is formulaic and fixed at answer time (scores well),
  but the credit-*earning* event depends on a linkage rule and a later vote (fails).

**Non-transferable by construction, verified:** `c.records` has exactly **three** access sites and
**no code path assigns one address's record to another.** **But the tripwire does not cover it** —
`check-nontransferable.py` matches coin-transfer verb names, so an entrypoint called
`AssignRecord`, `MigrateCredential` or `SetStanding` would **not trip it**, while violating the
principle its own docstring states. **Extend that guard before any credential field lands.**

**And crediting an unadjudicated position is a NEW CATEGORY.** `creditUpheld` is reachable from
exactly one site, gated on a **decided** vote. Nothing in the realm today credits anything on a
claim the court never ruled on. REGULATIONS.md already concedes kourt is "further from ministerial
validation than PoS" because it rewards **adjudicated** correctness — crediting an *unadjudicated*
position moves further in the direction already flagged as the weak fit, and makes the reward
"profit from the efforts of others" in the most literal sense: *other voters, on another claim,
deciding a question yours never reached.* **Sharpest counsel flag in the design.**

### 8.9 Revised recommendation

1. **Do not build a bond discount.** §8.5.
2. **Build the credential as published standing, denominated in unioned coverage-weeks, in a new
   field** — never in `score` — read through `P_max · cov/(cov + 156wk)`. Bounded by the calendar,
   mints nothing, monotone in years at 25% / 50% / 62.5% for 1 / 3 / 5 years, and **collectable by
   someone who never answers again.**
3. **Prefer the unscoped variant** (§8.3, property 3) unless §4.1's linkage question resolves
   cleanly — it needs **no linkage at all**.
4. **Extend `check-nontransferable.py`** before any credential field lands.
5. **Two new counsel flags:** an economically-valuable credential on an unadjudicated position
   weakens the gambling-axis "no prize" leg; and the "designed to evade" carve-out plausibly
   describes this shape.

---

## 9. AUDIT ROUND 2 — linkage is the wrong problem, and the measurement proves it

### 9.1 A perfect linkage mechanism pays ZERO on the owner's own test case

The COVID docket enumerated byte-exactly (11 titles, 123–153 bytes each):

| predicate | classes | covers | expired w/ later sibling | **expired w/ a sibling that reached a VERDICT** |
|---|---|---|---|---|
| **(d)** literal byte-identity | 0 | 0/11 | 0/5 | **0/5** |
| **(e)** identity after stripping one trailing `[…]` | 3 | 8/11 | **5/5** | **0/5** |
| (a) author-declared parent | — | any | 5/5 | **0/5** |
| (b) voted link | — | any | 5/5 | **0/5** |
| (c) argument edges | — | any | 5/5 | **0/5** |

**(e) is the fifth option §4.1 asked for and it works** — the three laboratory claims differ *only*
by a trailing `[asked Feb 2020]` / `[asked Feb 2023]` / `[asked Jan 2025]`, cores byte-identical at
123 bytes. Same for the GOF and testimony families. **100% of the linkage need, no vote, no
moderator, no new trust.**

**But the last column is 0 for every option.** Every same-core successor of an expired claim is one
of the three still **OPEN**. The three claims that reached verdicts are all **singletons — never
re-asked**, because they were answerable the first time.

```
P(verdict | claim is in a re-asked class) = 0 / 8
P(verdict | claim is a singleton)         = 3 / 3
claims ever disputed: 1 of 11  (and it is a singleton)
```

**This is structural, not an artifact.** A claim is re-asked *because* it expired; it expired
*because* nobody would post a bonded answer; the successor asks the same unanswerable proposition.

> **A perfect, free, unforgeable linkage mechanism pays the owner exactly 0 CC on his own docket —
> the same as today. Vindication, not linkage, is the binding constraint.**

### 9.2 And self-vindication is FREE — measured at NEGATIVE cost

Every option constrains *which* claim vindicates you. **None constrains who supplies the verdict.**
Measured end to end (1.02M CC court): re-ask the same canonical core, stake the minimum,
self-answer, let 72h of silence settle:

```
bond posted 510.166666   deposit+fee 112.200000   slash reserve 45.914999   (all return)
attacker CC delta after Crystallize and all pulls:   +0.116651 CC   <-- NET GAIN
```

**Manufacturing the verdict that "vindicates" a 22,950 CC expired position pays the attacker
0.117 CC** — author 8/93 + answerer 5/93 + winner 80/93 of a draw he minted himself — against ~1.7
CC of external carry. **And the policing lanes do not reach it:** a conclusive quality LOW scales
`cs.tier` and therefore the *money*, but `cs.provisional` — what `Verdict()` returns — is set by
`SettleUndisputed`. **A LOW zeroes the draw and leaves the vindication standing.**

The only capital-keyed gate that *is* priced is already shipped: `credEligible` requires the
overturn side to carry **≥ 1.25% of court supply**. Applied to this docket it leaves **1 of 11
claims eligible ever** — a singleton. **So verdict-keyed credit pays zero twice over.**

### 9.2b §9.1's table REPRODUCES independently — and the 0/5 is structural, not a fixture accident

Every number in §9.1 was re-derived from `scenarios/covid.py` by parsing it (`ast`, not a regex —
two hand-rolled parsers gave wrong answers first) and counting:

    11 titles, byte lengths 123..153            — as stated
    (d) literal byte-identity  0 classes, 0/11  — as stated
    (e) strip one trailing [..] 3 classes, 8/11 — as stated
    expired with a LATER sibling                          5
    expired with a sibling that reached a VERDICT         0

**But the reason for the 0 is worth stating, because it is stronger than the count.** The three
claims that were answered — `FUNDING`, `PROXIMAL`, `REPORTING` — are *exactly* the three
SINGLETONS, the ones with no sibling under (e). And all three families are entirely unanswered:

    family     LAB20, LAB23, LAB25        answered: none
    family     TEST21, TEST23, TEST25     answered: none
    family     GOF21, GOF25               answered: none
    singleton  FUNDING                    answered: FUNDING
    singleton  PROXIMAL                   answered: PROXIMAL
    singleton  REPORTING                  answered: REPORTING

So in this docket **linkage and adjudication are disjoint sets**. The 0/5 is not "the fixture
happened to leave five stragglers" — it is that the repeatedly-asked question is the one nobody
will answer, and the answerable question is the one nobody needs to re-ask. That is the same
selection pressure the design already knows about from the other side (a claim is answered when
X̄ matures and someone will post a bond; the hard open questions are precisely the ones where
neither happens), and it means **no improvement to the linkage predicate can rescue a
verdict-keyed credit.** §9.1 concluded that from a count; it holds for a reason.

The one caveat, stated so it is not mistaken for more than it is: this is ONE docket, hand-built
to represent the owner's own test case. It cannot establish a frequency. What it does establish
is that the mechanism pays zero on the motivating example, which is sufficient to reject it.

### 9.3 Build this instead: credit for conviction that was never REFUTED

Accrues at `CloseDeadClaim`, from the claim's own state. **No parent, no vote, no edge, no text
match.** Six rules, each measured:

1. **Pin the accrual window at 12 weeks — today it is UNBOUNDED.** **M:** a 300 CC position reads
   **22.950000** at 12 weeks and **68.850000** at 36 (**×3.000000 exactly**), and it *banks* on
   `Unstake`. `CloseDeadClaim` never sets `frozenAt` and nothing else caps a closed claim. On this
   docket: LAB23 lived **35.4 weeks** → **×2.988** inflation.
   > **Implementation warning: do NOT pin by setting `frozenAt` on close.** `Unstake` refuses when
   > `frozenAt != 0` and `WithdrawStake` requires `verdictAt != 0`, which a closed claim never has
   > — **that combination bricks the principal**, which is §5's exact failure mode. Pin instead by
   > giving `rawHeight` a `closed` arm capping at `openedAt + deadClaimTimeout`. Every consumer of
   > the raw integral was checked: `lifeAvgStake` is read only by `PostAnswer` (refuses `closed`)
   > and `capBonus` only via paths that refuse `closed` or require `crystallized`. **Touches no
   > live money path.**
2. **Key on the RAW `∫stake·dt`, not rate-weighted conviction** — raw is `d_eff`-invariant, so the
   straddle-safe exchange rate is a frozen constant instead of one that moves with the emission
   rate. `d_eff` has no retune path.
3. **Credit = NET capital-time per (address, claim)**, signed to the larger side. **M:** a symmetric
   300/300 straddle nets **0.000000**; one block of entry asymmetry on 600 CC nets **0.000015**; a
   directional 300 CC nets **22.950000**.
4. **Credit is SPENT, not standing.** `answerRecord`'s shape does not transfer — its `score` is
   farmable only by winning contested disputes, whereas capital-time is farmable in *size*, so a
   standing credential means one farm buys an unbounded stream.
5. **The debit (if wanted) uses (e) plus `decidedRounds > 0 && credEligible`.** Under-inclusive by
   design: (e) is free to evade by rewording, but an evaded *debit* only under-punishes. Without
   `credEligible` the debit is as forgeable as §9.2's credit — a ~0-CC DoS on every honest holder.
6. **Prefer PRIORITY over discount.** The 24h window is not fungible and is rate-limited to one
   active claim per address, so a hedged position **cannot monetize it**. A discount is money and is
   therefore straddle-priced.

**§6.4's saturation dissolves by construction** — credit is continuous in capital×time, so five
expiries are worth five times one, with no integer gate at 3 points.

**The owner's five-year call, measured:**

```
LAB20  EXPIRED  12 CC from 2020-02-01  ->  0.9180 CC
LAB23  EXPIRED  40 CC from 2023-02-26  ->  3.0600 CC
LAB23  EXPIRED  20 CC from 2023-03-01  ->  1.4754 CC
LAB25  OPEN     24 CC from 2025-01-25  ->  0.8961 CC
                                 total    6.3495 CC   (today: 0)
carry paid to earn it  2.4900 CC     credit/carry = 2.5500 exactly
```

### 9.4 State plainly what this is — it does NOT measure being right

**M**, the five expired claims:

```
biosafety 6.6774    virology 6.5817    oversight 6.4260    epi 4.3687
trader    4.1310    foia     1.6830    skeptic   1.1311    journo 0.9180
```

**`virology`, who held the natural-origin side throughout, earns within 1.5% of `biosafety`, who
held the lab-leak side.** On an unresolved question there is no right side and both earn. It is a
measure of **capital committed at time-risk to unresolved propositions**, purchasable by anyone at
2.55× carry (cold) / 6.43× (hot).

That is capital-keyed, which is this repo's own doctrine, and it *is* literally what was asked for —
*"rewarded for staking on it the whole time."* **But it is not "rewarded for being right," and that
is the owner's call to accept or reject.**

**And a deeper limit no credential fixes:** a laboratory claim existed to be staked for only
**29.9 of the docket's 265 weeks (11.3%)**. You cannot stake on a claim that does not exist.
*"Rewarded the whole time"* is bounded by how often somebody re-files.

### 9.5 §13.5's threshold does NOT transfer — and transplanting it is ANTI-conservative

§13.5's straddle bites because own stake enters `mg_max`, which **is the bond base**. Here it does
not. **M:** two twin claims, one whose straddler was loaded on an earlier claim and one not —

```
bond floor, straddler idle   = 100.980000
bond floor, straddler LOADED = 100.980000     delta = 0.000000  (bit-identical)
```

So the cost ratio collapses to `(1 − d·min(1, u/u*)) ≤ 1` for **every** stake and **every** `u*`.
**There is no threshold.** Worse, with `u = s/(P+s)` the whale saturates at full discount while the
small honest contrarian gets nearly none: **the threshold is regressive here — it defeats the small
straddler and licenses the large one**, the exact inverse of §13.5.

**Netting transfers a fortiori** — §13.5's fatal netting removed a self-tax from the bond
denominator, and here that self-tax is **structurally absent already**, so this design is *born* in
the post-netting regime. §13.5's "6.4× too cheap" reproduces as a pure constant with no topology
term: `2.55·(r0+d_eff)/r0` = 2.5500 cold, **6.4260** at the ceiling.

**But a different netting does work, and it is not the one §13.5 refuted:** net the **credit
numerator** within the credited claim (§9.3 rule 3). `credit ≤ ρ|s| ≤ ρ·gross = (ρ/r)·carry`, with
equality only for a one-sided position — so **any opposing leg costs carry and cannot raise credit,
strictly dominated at every size and every N. No threshold needed.**

**Its exact limit, and it is irreducible:** netting is per (address, claim), and CC is purchasable to
any number of addresses. A 2-address sybil restores the un-netted straddle at 2× carry for 1× credit
→ credit/carry **1.275 cold / 3.213 hot**. Two addresses on opposite sides are observationally
identical to two people who disagree. **Netting buys exactly a factor of 2 and no more.**

### 9.6 The safe exchange rate is scale-free — there is no N

```
profit/claim = X·(v·ρ − 2·r0·T)        — LINEAR in stake and in claim count
v* = 2·r0·T/ρ = 0.784314 (cold)   0.311236 (hot, at the ceiling)  <-- binding
```

`d_eff` moves at runtime with no retune path, **so the safe constant is the ceiling value: v ≤
0.3112; take v = 1/4 for margin.** Equivalently **≤ 0.06 CC of relief per CC held 12 weeks**. Without
netting, halve it. At `v = 1` the straddle is risk-free **+3.58%/yr cold, +28.8%/yr at the ceiling**,
at every size and count.

### 9.7 A credential discount is more dangerous than the conviction lever

`bond ≥ 1.2·mg_max` against `k = 1.6` ⇒ **total discount ≤ 25%, ONE budget** — §13.5's conviction
lever and a credential discount **cannot stack**; whichever applies first exhausts it.

| | δ = 0 | δ = 25% credential discount |
|---|---|---|
| MID | 0.66875 | 0.891667 (still < 1) |
| **HIGH** | **1.29375** | **1.725 (+33.3%)** |

So it coexists with C3 **only** under §13.3's draw cap. **And it carries a hazard the conviction
lever does not:** a conviction-keyed discount requires holding a third of the majority pool on the
minority side, which a sniper will not do — but a **credential**-keyed discount is **earned on
unrelated claims and spent on the snipe.** It decouples the discount from the claim being answered.
**Another reason to pay in priority, not discount.**

### 9.8 Residuals, stated rather than papered over

1. **§4.3 spam is NOT closed by netting.** The burned fee is a per-*claim* constant against a
   quantity that scales with *capital*, so it bounds claim count, not credit magnitude. A
   self-opened claim expiring with net capital-time is **indistinguishable on-chain** from an honest
   one — the farm and the honest five-year call are the same act at the same price. The only
   difference is whether anyone else cared, which is not on-chain.
2. The pre-existing **answered-claim straddle leak** (now `TODOs.md` §0a), which this design
   inherits and enlarges.
3. The **sybil-split straddle** — irreducible; netting is worth exactly ×2.
4. **(e) is free to evade** by rewording or moving the dateline to the front. Acceptable for the
   debit (it under-punishes); fatal if load-bearing for the credit — which is why §9.3 does not use
   it there.
5. **`v = 1/4` delivers modestly.** biosafety's 6.3495 CC of credit → **1.587 CC of relief**, ≈86% of
   one maximum discount on a claim the size of his own largest position, **over five years**. That
   is `> 0` and it is the owner's own concession — but it is small, and 75% of every bond is
   non-discountable by construction, so no calibration makes it large. **If more is wanted the lever
   is priority, not discount.**
