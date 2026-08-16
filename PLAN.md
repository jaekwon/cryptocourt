# PLAN — cryptocourt tokenomics V2: no-loss conviction staking

> Living design document. Branch `tokenomics-v2`, base `5d2c4ef` (the fully-audited V1).
> Standalone: this file is readable without the V1 docs; §2 is the explicit diff.
> Every mechanism carries a VET status: `DRAFT` → `VETTING` → `ACCEPTED` / `REVISED`.
> Regulatory grounding lives in [REGULATIONS.md](./REGULATIONS.md). Not legal advice.

## 0. Posture

Owner is a risk-tolerant US founder. The goal is an interesting, working product with
*managed* gray areas, not a maximally-defensive one. Accepted risks are enumerated
(§7.4) — everything else gets designed around. Two hard constraints survive from V1:
arithmetic can never wrap (checked multiplies + a provable supply ceiling), and no
mechanism may depend on a tunable-at-runtime knob (frozen constants killed a whole
class of capture and overflow attacks in the V1 audit; V2 keeps that discipline).

## 1. The change in one paragraph

V1 is a prediction market: mint matched YES+NO share sets against collateral, trade
them on an order book, and at resolution the losing side's collateral pays the
winning side. That loser-pays-winner core is what makes it legally a wager and a
CFTC-style binary event contract, no matter what we call it. V2 deletes that core.
Stakers back YES or NO directly; **losers get their entire stake back**; winners
share a **bounded, halving emission of new CC**, weighted by how much and how long
they staked ("conviction") and by an adjudicated **quality tier**. Real money (GNOT)
enters exactly once, through the one-way bonding curve, and is **burned** — no real
money ever exits the system, contingent on anything. The order book, matched sets,
share ledger, and price TWAP all become unnecessary and are removed. The product is
the **verdict, the calibrated probability signal (the stake ratio), and the public
record** — CC is the internal participation economy that meters and rewards it.

## 2. Diff from V1

| | V1 | V2 |
|---|---|---|
| Position | Buy YES/NO shares (matched sets, order book) | Stake CC into a claim's YES or NO pool |
| Loser outcome | Shares worth 0 (collateral → winners) | **Full principal back** |
| Winner outcome | 100 CC per share from loser collateral | Principal + emission bonus (conviction × quality) |
| Price signal | Last-trade tick + week TWAP | Stake ratio YES/(YES+NO), hourly series |
| Funding of rewards | Losing side (zero-sum) | New issuance, hard-bounded budget (positive-sum, diluting) |
| GNOT | Treasury, unspendable "for now" | **Burned at Buy** (explicit, irreversible) |
| Order book (tickbook) | Core | **Removed** |
| Share ledger (cshares) | Core | **Removed** (two stake tallies per claim) |
| Price TWAP + preAnswerPrice | Core, manipulation-hardened | **Removed** (provClose pays 1× to everyone — no price needed) |
| OI ceiling (20% supply), per-claim caps | Core safety | **Removed** — replaced by the emission cap + checked arithmetic |
| Fees (adjFee/settleFee skimmed from winners) | Core | **Removed** — voter/answerer/author rewards are emission slices |
| Answer/dispute machine (bonds, doubling, 3 rounds, escrow windows) | Core | **Kept** unchanged (see §3.6 for the bond gray area) |
| Governor + grc20votes (weighted vote, epochs, anti-flash-loan) | Core | **Kept**; + a new 3-bucket quality tally (§3.4) |
| One-way bonding curve (GNOT→CC) | Core | **Kept** (destination now burn) |
| Claim deposit (anti-spam, refundable) | Refund only at Finalize (stranding residual O6) | Refundable after timeout on dead claims (O6 fixed) |

Audit residuals that simply evaporate in V2: **O5** (pre-answer-price pin — no price
exists), **O6** (deposit stranding — dead claims unlock), the whole overflow-bomb
class around `qty·priceScale` (no shares), and the tickbook survival-fraction
machinery (no book). O2 (answer bond not clawed back on reopen-overturn) remains,
unchanged from V1.

## 3. Mechanics

### 3.1 Claim lifecycle — `VETTING`

1. **Open.** Author posts a falsifiable factual claim + evidence, escrows the CC
   deposit (refundable; never zero).
2. **Stake window.** Anyone stakes CC on YES or NO. Unstaking is free until an
   answer is posted (the signal stays live). Per-staker, per-side
   **conviction** accrues: `conviction = ∫ stake dt` (stake × blocks held),
   tracked with the same epoch-bucket machinery V1 used for TWAPs.
3. **Answer.** As V1: answerability requires the trailing average of *total stake*
   X̄ ≥ `minAnswerX`; answer bond = min(50%·X̄, cap); 72h settle delay; the full
   dispute machine (bond doubling per failed round, max 3, escrow windows, sealed
   tallies) is unchanged. Posting an answer **freezes staking and unstaking** on
   the claim.
4. **Resolution.** Verdict = the existing binary governor vote (5001 bps), or the
   answer standing undisputed. NEW: a **quality tier** (§3.4).
5. **Settle.** Losers withdraw principal 1×. Winners withdraw principal 1× + the
   emission bonus (§3.5). Author, with-verdict voters, and the answerer draw their
   emission slices. Deposit refunds to the author. **Losers may withdraw 1×
   immediately after any DECIDED dispute round** (econ vet F7) — their outcome
   cannot improve, and releasing them defuses the multi-round freeze-hostage
   (up to ~8 weeks of locked capital across 3 rounds).
6. **Dead claim.** A claim that never reaches an answer unlocks fully after a
   timeout: all stakes 1×, deposit back (fixes V1 residual O6).
7. **provClose** (3 failed dispute rounds): everyone 1×, no bonus, no author
   reward, deposit back. No price needed — the V1 O5 manipulation surface is gone.

### 3.2 Conviction (time-weighted stake) — `ACCEPTED (econ vet F9/F4)`

The bonus weight is not the stake, it is the **time-integral of the stake on the
winning side**, from stake-time until the answer freeze. This does three jobs at
once: (a) rewards *early* information — the whole point of a forecasting signal —
(b) makes last-second stake-flooding worthless, and (c) prices the lock: a farmer
must actually commit capital-time, not just capital.

Exact semantics (per the econ vet):
- Per (staker, claim, side): `accrued += stake · Δt` at every stake change and at
  the freeze; conviction is the exact integral ∫stake dt, **denominated in
  stake × hours** (720-block units) — raw block units overflow int64 by ~145× at
  uncapped stakes; hours fit with ~5× headroom (9.2e14 × 2016h < MaxInt64), and
  all downstream draws go through the audited 128-bit `mulDivFloor`.
- **Unstake stops accrual on the removed portion; history is kept; restake
  resumes; nothing ever resets.** Capital conservation makes the integral
  game-proof — one CC-week staked anywhere earns exactly one CC-week of
  conviction, so unstake→restake cycles cannot manufacture weight, and honest
  belief-updating (the reason free unstake exists) is never punished.
- **Freeze is atomic with the answer**: same-block stake/unstake ordered after
  the answer reverts — else a matched farmer front-runs the answer to pull the
  about-to-lose side out of the settlement lock.
- Bonus caps use **time-averaged stake** (`conviction / claim-open-hours`) as
  the base, never stake-at-freeze, which a 1-block flash could inflate.

### 3.3 Emission — **reservoir drip, rate-based** — `REVISED (post econ vet); follow-up vet running`

Adopted the §8.7 reservoir over per-period pro-rata. Deciding argument, from the
econ vet's own F5 equilibrium math: pro-rata reaches farming-break-even *by
paying matched farmers until they compress the yield to y\**, i.e. it spends
emission on non-informative capital along the way, and (A10) it couples every
payout to the period's slowest dispute. A **fixed rate set below the
matched-farming threshold** means farmers never enter at all, and no cross-claim
denominator exists to time or to hold hostage.

- **Accrual**: `R += b` per block, `b = B_period / 120,960`; halving every 104
  periods (~2 years) applies to `b`; accrual pauses while `R ≥ R_max = 4 ×
  B_period`. Total emission ≤ 2·B₀·104 — finite geometric sum.
- **Rate, not share**: a winner's gross bonus is `g_i = tier × rate ×
  conviction_i`, capped at `(tier/2) × time-averaged stake`. The claim draws
  `D = min(Σg, R)`, scaling within-claim pro-rata if `R < Σg`; `R -= D`.
- **The sizing band (econ vet F5, closed form)**: matched-stake farming profits
  iff yield-per-conviction `y > y* = 2(r+d)·T_L/T_c` (r = external opportunity
  rate, d = dilution rate, T_L/T_c = lock-to-conviction time ratio ≈ 1.5).
  Honest stakers with accuracy p profit iff `y > y*·(1/2p)`. So set
  **`rate` in the band `(y*/2, y*)`** — e.g. `0.75·y*` ≈ 0.8%/week on conviction
  at reference numbers: matched farming strictly unprofitable, any staker with
  p ≳ 0.67 clearly profitable, coin-flippers lose to lock cost. Deploy-time
  constant; published.
- **Ceiling, not floor**: unearned budget is never minted; the reservoir cap
  banks at most 4 quiet weeks.
- **Deploy-time invariants** (checked in code, V1-style): `curveCap + Σemission
  ≤ MaxInt64/Bps` with ≥20% headroom; conviction fits int64 in stake-hours; and
  per-claim `Σg` is **clamped** (never aborted) at a `G_MAX` so no crafted
  position can poison a shared settlement path (econ vet F4: checked-abort on a
  shared path is a settlement DoS — clamp instead).
- Residual (accepted): FCFS when the reservoir runs dry — bounded by `R_max`
  and the individual caps; draining R requires *real winning conviction*, so it
  cannot be griefed for free.

### 3.4 Resolution: verdict + quality — `VETTING`

- **Verdict**: unchanged binary machine. Winners = stakers on the side matching
  the final verdict.
- **Quality**: a second question on the same dispute proposal — was this claim
  **low / mid / high** information? Resolved by **weighted median** over
  `grc20votes` snapshots (the bucket where cumulative weight crosses 50%): a whale
  can pull the median one bucket at most, never to an extreme; three buckets give
  voters a Schelling point so honest votes converge.
- **Undisputed claims** default to **mid**, and — econ vet F1, CRITICAL, now
  closed — that default alone was a pump: trivially-TRUE claims are undisputable
  (disputing a true claim loses your bond), so an author-mill could farm
  default-mid emission with zero information content. Mandatory fix adopted:
  the **quality-flag lane**, fully specced below (iteration 5).

**Flag-lane spec — `DRAFT, attack-vet launched`:**
- **Window**: one flag per claim, allowed from the answer until the settle tx
  lands. The 72h settle delay guarantees ≥72h of flag exposure on every claim;
  a flag **pauses settlement** until its vote closes.
- **Bond**: `max(flagMin, 2%·X̄)`, escrowed. Returned iff the outcome is
  **low**; burned otherwise — including when the electorate promotes to high
  (flag risk cuts both ways; a bad flag against a genuinely good claim pays for
  the delay it caused).
- **Vote**: the same court-local 3-bucket tally as the dispute-ride version;
  snapshot = the last sealed `grc20votes` epoch at flag height (identical
  anti-flash-loan posture to `Propose`); window = `votingBlocks` (7d); sealed
  until close; one vote per address, weight = `PastVotes`.
- **Outcome rules (consistent with the F3 ratchet)**: median decides low vs
  mid; **demotion to low additionally requires turnout ≥ ¼ of the claim's
  verdict bar** — a lone griefer with dust turnout cannot zero an honest
  claim's emission; **promotion to high keeps its own gate** (≥⅔ of turnout
  AND turnout ≥ the full verdict bar).
- **Incentive geometry worth recording**: the claim's own stakers are biased
  voters (their bonus rides on ≥mid), but the natural anti-junk constituency
  is *every other CC holder* — dilution pays for junk emission, so the
  electorate that funds the draw is exactly the one empowered to zero it. In a
  healthy court the dilution-payers outweigh any mill's stakers.
- **Interactions**: a flag during an open dispute is refused (the dispute vote
  already carries quality); a flag cannot be withdrawn (no flag-then-retract
  timing games); the flagger gets no reward beyond bond return (policing is
  spam-priced, not yield-bearing — a paid-flagger lane would recreate F2's
  problem in miniature).
- **Tier ratchet is asymmetric (econ vet F3)**: the median can only move
  **mid ↔ low**; **high requires ≥ ⅔ of turnout AND turnout ≥ the claim's
  verdict bar**. A whale with ~29% of a thin turnout could capture a median;
  demoting junk stays cheap, promoting to double-draw is expensive and
  quorum-gated.
- Tier multipliers: **low = 0×, mid = 1×, high = 2×**. Low zeroes every slice —
  junk is pure cost (deposit + lock + dilution) for all involved.
- **Implementation shape** (from the §Appendix A sweep): quality does NOT touch
  `/p/governor`. It is a court-local 3-bucket tally: `VoteQuality(claimID,
  bucket)` weighs the voter by `PastVotes` at the **same sealed snapshot epoch as
  the dispute proposal** (same anti-flash-loan property, no second snapshot);
  state is three weight counters + a voter→(bucket,weight) record (double-vote
  guard, and the record the voter carrot pays from); the median is computed at
  close and never rendered before it (sealed, like the verdict tally). No new
  governor lane, no /p/ change.

### 3.5 Reward split — `VETTING`

Per claim, drawn from the reservoir (§3.3) at settlement:

```
gross          Σg   = Σ_winners tier × rate × conviction_i
claim's draw   D    = min(Σg, R)        (within-claim scaling if R < Σg)
split of D:    winners 80% (pro-rata by conviction)
               author 8% · with-verdict voters 7% · answerer 5%
caps:          winner_i  ≤ (tier/2) × time-averaged stake_i
               author slice   ≤ (tier/2) × author's own stake        (F1)
               answerer slice ≤ (tier/2) × the answer BOND           (F1 refined, v0.8)
voter slice:   TIER-INVARIANT — computed at mid-weight and paid even when the
               tier lands low  (F2)
```

- **Slice caps close the capital-free rake (econ vet F1, CRITICAL)**: without
  them, author + answerer skimmed 13% of the draw with no stake of their own —
  the crowd's risk-free capital did the earning. Capped remainder is not minted.
- **v0.8 refinement (found by working Appendix B; `DRAFT`, rides the next vet)**:
  the answerer's cap references the **answer bond**, not their stake — F1's
  rationale is "no capital-free rake", and the answerer is *never* capital-free:
  the bond (50%·X̄) is the largest single skin in the claim. A stake-based cap
  would zero the slice for the natural non-staking answerer and kill the answer
  incentive; a bond-based cap (`≤ (tier/2) × bond`) preserves the rationale and
  effectively never binds. The *author* keeps the stake-based cap (their deposit
  is small and refundable — stake is their only real skin).
- **The voter slice must not scale with the tier (econ vet F2, CRITICAL)**: if
  it does, every voter's pay doubles at high and zeroes at low → "everything is
  high" becomes the electorate's Nash equilibrium and junk-policing is unpaid
  work. Tier-invariant, paid-even-at-low makes truthful quality reporting weakly
  dominant. And the carrot is **with-verdict only** — a with-*median* carrot
  funds a Keynesian beauty contest (whale pre-announces a bucket off-band;
  matching it pays), which sealing cannot prevent (F3).
- Carrot-only stays (wrong-side voters lose nothing). Register note (F6): a
  successful bribe's voters keep the carrot, so carrot-only mildly subsidizes
  P+ε coordination — acceptable while CC is OTC-thin; transferability is the
  emergency lever.
- All slices are **computed by formula from the tallies** — no discretionary
  "pay X" votes anywhere (Ooki surface minimization, §7.3).
- Whale-hogging (old A6) is RESOLVED as a non-attack (econ vet F8): under a
  linear rate nobody's per-conviction yield depends on anyone else's claim, and
  linear is the unique splitting-neutral rule — sqrt gifts claim-splitting
  sybils a √k multiplier; per-claim caps punish exactly the flagship big-claim
  moments. No smoother.

### 3.6 Bonds and deposits — `DRAFT`

Answer bonds and dispute bonds stay forfeitable exactly as V1 (bond doubling is
what makes the adjudication game honest; without loss, wrong answers are free).

**Bond sizing survives V2 — by a new argument (iteration 3).** V1 sized the
answer bond at `min(50%·X̄, cap)` against V1's theft surface (a lie that stands
steals the losing side's collateral, ~X̄-scale). That surface is gone; the new
one is the emission draw. Work the self-deal: attacker stakes S on their own
claim, posts a wrong answer, hopes nobody disputes. If undisputed, quality
defaults to **mid** (high requires a vote — the undisputed path structurally
cannot reach it), so extraction caps at `midTier/2 × S = 0.5×S` of minted CC,
while the bond at risk is `0.5×X̄ ≈ 0.5×S`. Detection probability ≥ 50% makes
the lie EV-negative; any dispute also flips the verdict and re-votes quality.
So `50%·X̄` remains exactly right — but now **because** it equals the maximum
undisputed extraction. That coupling becomes a frozen invariant, V1-mustSane
style: `answerBondBps ≥ maxUndisputedTier/2` (in bps of X̄), checked at deploy —
if tier multipliers or the undisputed default ever change, the bond floor moves
with them or the deploy refuses. (The econ vet's F1/F10 confirmed the self-deal
arithmetic; with the flag lane and slice caps the undisputed path nets ≤ 0
against the bond at detection ≥ 50%.)

Two bond revisions from the econ vet:
- **Dispute bond is capped**: `min(20%·X̄, 2 × answer-bond cap)` (F5). X̄ counts
  *refundable* stake now, so matched capital inflates it for free — an uncapped
  20%·X̄ would let a farmer price honest policing out of its own claim. The
  doubling schedule still deters serial disputes.
- **20% of the losing bond burns even on DECIDED votes** (F3/F6). V1 paid the
  loser's bond whole to the winner, which made **self-dispute free** (answer
  from wallet A, dispute from wallet B, the upheld answerer pockets B's bond —
  net ≈ gas) — a free trigger for vote machinery and a bribery-loot maximizer.
  A 20% burn prices the trigger at ~4%·X̄ per pull and shaves vote-capture loot,
  while an honest winning party still nets 80% of the loser's bond.
This is a **deliberately retained gray area**: a forfeitable bond is stake lost on
a vote outcome. The distinction we rely on: it prices *your own conduct* (posting
an answer, filing a dispute) like a court's frivolous-filing sanction or an appeal
bond — not a wager on someone else's event. Flagged for the legal vet.

**Fallback considered and REJECTED — time-lock instead of forfeiture.** Sketch: an
overturned answerer / failed disputer gets the bond back after an extended unbond
(say 8× the escrow window) with no emission eligibility. Why it fails: PostAnswer
is one-per-claim, so answering wrong must be *expensive*, not merely slow. With
loss capped at time-value, a griefer instantly posts a junk answer on every
answerable claim (first-answerer squat), forcing every claim into dispute votes —
the adjudication economy DoSes itself for the price of some locked liquidity, and
honest answerers are crowded out of the slot. Forfeiture is load-bearing for the
answer game in a way it no longer is for staking (stakers are many per side;
answerers are one per claim). Recorded here so the next reader doesn't re-derive
it; the legal exposure of retaining forfeiture stays in §7.2 as accepted.

### 3.7 GNOT: burn — **the call** — `VETTING`

GNOT paid into the curve is **burned** (sent to an unrecoverable sink), not pooled.
Considered and rejected: a GNOT work-pool paying moderators/authors.

- A real-money pool directed by token votes is a **capture honeypot**: collusion
  rings (junk claim → allied "high" quality votes → GNOT out) get paid in the one
  asset that matters, and every such flow re-arms the exact hooks V2 disarms
  (real-money prize contingent on votes ≈ wager payout; CFTC cash-out; Ooki
  personal liability for the voters directing it; AML/tax on pseudonymous payees).
- Burn is capture-proof, needs zero compliance machinery, makes the existing truth
  explicit (V1's treasury was already unspendable), strengthens the
  consumption-purchase story for Buy (you spend GNOT to participate; nothing to
  redeem, no dividend to expect), and is a legible monetary meme.
- Moderation/authorship is instead paid in **CC emission slices** (§3.5): the
  reward asset's value is the court's own credibility — capturing the court to
  farm it debases exactly what you captured. Incentive-aligned by construction.
- Cost accepted: contributors can't pay rent in CC. That professional-payout
  economy is precisely the regulated surface we're declining to build in-protocol.
  (A future off-protocol grants entity can pay people; see §7.3.)
- **Burn mechanics (implementation note)**: GNOT is native coin — burn = banker
  send to a provably keyless sink (a derived unspendable address, V1
  `DerivePkgBech32Addr`-style with a dead path, or the chain's designated burn
  address if one exists; pin at implementation). CC burns (the 10% claim fee,
  losing-bond burns) use `grc20votes.Burn`, which V1 already exercises on the
  failed-quorum path — audited code, no new machinery.

### 3.8 Brainstorm outcomes (iteration-4 step-back pass) — `DRAFT`

Assumption questioned: **capital is the only credential.** The answer slot is
V2's most abusable scarce resource (one per claim; verdict-by-default when
undisputed), and it is currently first-come-first-served to anyone with a bond.

**ADOPTED (draft, needs attack-vet): track-record answer priority.** The court
keeps a per-address, non-transferable answer record: `stood` / `overturned`
counters (data it already produces). When a claim becomes answerable, the first
`priorityWindow` (24h) accepts answers only from addresses with net record
`stood − overturned ≥ 3`; after that, anyone. Properties: the credential is
*earned by the exact behavior we want* and destroyed by the exact behavior we
fear (an overturned answer burns it — lying spends the credential); it is
non-transferable and mints nothing (zero new legal surface); newcomers are
delayed 24h, never excluded; farming it costs real deposits, bond locks, and
72h+ waits per unit, and the farmed credential still dies on first misuse.
Cost: one bptree + a phase check in PostAnswer. Complements — not replaces —
the bond (§3.6): the bond prices one lie, the record prices a *career* of them.

**ADOPTED (draft, needs vets): claim fee, burned.** 10% of the claim deposit is
non-refundable and burned (the other 90% stays a refundable deposit). Gives CC
its only sink (emission otherwise inflates monotonically against a one-way
curve), prices claim creation honestly, and — usefully — an entry fee paid
win-or-lose is the *Humphrey* non-wager pattern (fees regardless of outcome,
prizes not funded by entries), so it slightly strengthens the legal posture
rather than weakening it. Author economics stay positive for good claims (the
8% author slice at mid/high tier ≫ the fee).

**REJECTED: continuous-probability verdicts** (voters submit probabilities;
payout by closeness — a scoring-rule court). The division of labor is already
right: the *market* (stake ratio) prices belief continuously; the *vote*
decides truth discretely, where 5001 bps and sealed tallies are battle-tested.
A numeric verdict would hand adjudicators a knob attackers can nudge and
dissolve the crisp "the record says YES/NO" product. Recorded so it isn't
re-derived.

### 3.9 Signal & render — `SPECCED (v0.9)`

Three ratio series, and none of them needs new state:

1. **Instantaneous ratio** `yes/(yes+no)` from the two live pool totals — what
   the sparkline draws at the current bucket.
2. **Trailing-week ratio** = trailing average of the YES-pool ring ÷ trailing
   average of the total-pool ring, both hourly rings on the V1 twap machinery
   (two rings per claim, storing pool sizes on every stake/unstake — the same
   objects that feed X̄). Flash-resistant; what an integrating consumer should
   read.
3. **Conviction-weighted lifetime ratio** = `convYES / (convYES + convNO)` —
   and this is free: the per-side conviction totals ARE the time-integrals
   ∫pool dt, already maintained for the reward math. This is the F9
   manipulation-resistant series: the only way to move it is to pay
   capital-time on a side.

Render per claim: sparkline (1), the week and lifetime ratios (2, 3) side by
side — divergence between them is itself signal (a recent swing vs a long-held
consensus) — total staked, X̄, verdict + tier + route ("undisputed" / "by vote
71%, quality: high (⅔)"), emission drawn vs caps, and the flag/dispute status.
Sealed-tally rules apply to BOTH open tallies (verdict and quality): while
either vote is open, render shows only that it is open and its close height —
never a running count (V1 §3.4 discipline, unchanged). The claim page is the
product; every number on it must be reproducible from public reads.

## 4. Parameters (deploy-time constants)

| Constant | Value (post econ vet) | Note |
|---|---|---|
| period | 120,960 blocks (1 wk) | halving bookkeeping only — claims have no period under the reservoir |
| rate (CC per conviction stake-hour) | `0.75 × y*`, `y* = 2(r+d)·T_L/T_c` at launch estimates (≈0.8%/wk on conviction) | F5 band `(y*/2, y*)`: farming unprofitable, p ≳ 0.67 profitable |
| B₀ (weekly accrual) / R_max | `b·120,960` / `4 × B_period` | reservoir cap banks ≤ 4 quiet weeks |
| halving interval | 104 periods | total emission ≤ 2·B₀·104, finite |
| supply invariant | curveCap + Σemission ≤ MaxInt64/Bps, ≥20% headroom | checked at deploy |
| conviction unit | stake × hours | fits int64 ~5× (F4); draws via mulDiv128 |
| G_MAX | per-claim Σg clamp | clamp, never abort, on shared settle paths (F4) |
| tiers | low 0× · mid 1× · high 2×; **high needs ⅔ + bar turnout** | §3.4 asymmetric ratchet (F3) |
| winner cap | (tier/2) × time-averaged stake | flash-proof base (F9) |
| author/answerer slice caps | ≤ (tier/2) × own stake | no capital-free rake (F1) |
| split | 80/8/7/5; **voter slice tier-invariant, paid even at low, with-verdict only** | F2/F3 |
| quality-flag bond | max(flagMin, 2%·X̄); returns iff median = low, else burns | the F1 flag lane |
| dispute bond | min(20%·X̄, 2 × answer-bond cap), doubling kept; **20% of losing bond burns on decided votes** | F5 cap; F3/F6 burn |
| minAnswerX | re-derive in V2 units (trailing total STAKE, no sets exist; placeholder 100 CC) | §8.8 — V1's "100 sets' worth" is meaningless in V2 |
| answer bond, escrow windows, 5001 bps, 72h delay | V1 values | unchanged |
| dead-claim timeout | 12 weeks | new (O6 fix) |
| bond–tier coupling | `answerBondBps ≥ maxUndisputedTier/2` | frozen invariant, §3.6; deploy refuses otherwise |
| claim fee (burned) | 10% of deposit | §3.8 brainstorm; CC's only sink |
| answer priority | net record ≥ 3 → 24h priority window | §3.8 brainstorm, needs vet |

## 5. Attacks & mitigations

All statuses reflect the econ vet's findings (F1–F11), ingested v0.6.

| # | Attack | Resolution | Status |
|---|---|---|---|
| A1/A2 | **Matched-stake farming** (one wallet or a sybil pair): stake both sides, harvest the winner bonus risklessly | Closed form (F5): profitable iff rate `y > y* = 2(r+d)·T_L/T_c`. The reservoir rate is FIXED inside `(y*/2, y*)` → farming strictly unprofitable; honest p ≳ 0.67 stakers profit. Per-address netting DELETED — the vet showed my "sybil doubles lock cost" claim was arithmetically false (a lone matched farmer already locks 2X) and netting breaks custodial wallets while stopping nobody | `CLOSED (F5)` |
| A3 | Last-second stake flood | Conviction ≈ 0 for late stake; cap base is time-averaged stake (flash-proof) | `ACCEPTED` |
| A4 | Quality capture: whale median-push (needs only ~29% of a thin turnout), off-band pre-announcement herding, free self-dispute trigger | High needs ⅔ of turnout + turnout ≥ the verdict bar; the median only moves mid↔low; with-median carrot dropped; the 20% decided-vote bond burn prices the trigger | `CLOSED (F3)` |
| A5 | **Author-mill on undisputed default-mid** (CRITICAL): trivially-true claims are undisputable → default mid → uncapped 13% author+answerer skim of a crowd-earned draw, ~6× on lock cost, self-reinforcing | Quality-flag lane (bond returns iff median = low, else burns) + author/answerer slices capped at (tier/2) × own stake | `CLOSED (F1)` |
| A6 | Whale claim hogs the pool | Non-attack under a linear rate (equal yield per conviction by construction); sqrt and per-claim caps are WORSE (√k to claim-splitters / punishes flagship claims). No smoother | `CLOSED (F8)` |
| A7 | Emission-lever capture | No lever exists (frozen constants) | `ACCEPTED (V1 discipline)` |
| A8 | Unstake games: paint the ratio, unstake→restake cycling, freeze front-running | Exact-integral conviction (never resets; capital-conserving); freeze atomic with the answer (same-block-later unstakes revert); publish the conviction-weighted ratio alongside the instantaneous one — the only series you can move is the one you pay capital-time for | `CLOSED (F9)` |
| A9 | Arithmetic: conviction overflow; **checked-abort on a shared settle path = settlement DoS** | Stake×hour units (fit int64 with ~5× headroom); 128-bit `mulDivFloor` for draws; per-claim Σg CLAMPED at G_MAX — never aborted — so no crafted position poisons settlement for others | `CLOSED (F4)` |
| A10 | Cross-claim pro-rata: period-assignment timing + slowest-dispute payout coupling (self-found) | Reservoir drip adopted (§3.3) — no cross-claim denominator exists; the vet's in-model fix (assign claims to their answer-freeze period, F11) recorded but moot | `CLOSED (reservoir)` |
| A11 | Voter-carrot tier-coupling → electorate-wide drift to "high"; policing junk is unpaid (CRITICAL) | Voter slice tier-invariant, paid even at low, with-verdict only | `CLOSED (F2)` |
| A12 | provClose freeze-hostage: push a rival claim through 3 failed rounds; stakers frozen ~8 weeks, conviction pays zero | Losers exit 1× after each decided round; the self-dispute variant is taxed by the 20% burn; a griefer cannot force votes to fail on any claim with motivated stakers | `MITIGATED (F7); residual: orphan claims, low damage` |

**The F6 insight, recorded:** in V2 a flipped verdict moves **no staker
principal** — staker-level harm from a wrong verdict is purely epistemic. The
only financial prizes riding on any vote are the conduct bonds (present only
when contested) and a capped, dilution-funded emission draw. V1's quorum bar was
sized against a prize of X (the losing collateral); V2 keeps the same bar
against a prize of ≲1.4·X̄-in-bonds + (tier/2)·stake — **verdict security is
strictly improved**, and the soft underbelly moved to the quality tier, which
A4/A5/A11 close. Vote-buying at launch scale is unprofitable (the loot is
non-cashable CC whose value the attack itself debases); it degrades only as OTC
depth grows — transferability-off remains the emergency lever.

## 6. What V2 deliberately gives up

- **Price discovery by trading.** A stake ratio is a coarser signal than an order
  book price (no shorting the margin, no limit orders). Accepted: the product is
  calibrated crowd probability + adjudication, not a trading venue.
- **Zero-sum sharpness.** No-loss staking attracts softer opinions than
  money-at-risk. Conviction weighting and quality tiers claw back some sharpness.
- **Hard emission answers.** Dilution is a real cost borne by all holders;
  the budget makes it bounded and legible, not free.

## 7. Regulatory rationale (see REGULATIONS.md for the full DD)

### 7.1 What V2 changes, per axis
- **Gambling (state law)**: the strongest hook — loser's stake pays the winner —
  is gone. No participant can lose principal on an outcome. Remaining theories are
  soft: consideration-as-lockup (symmetric, non-punitive) and prize-via-dilution
  (diffuse, untested). This is the main gain.
- **CFTC**: no bilateral payment contingent on an event (losers ≠ payors; the
  "payout" is protocol issuance of a non-cashable token). Materially weaker than a
  cash-settled binary; untested, and §1a(47)(A)(ii) is broad — gray, accepted.
- **Securities**: the pressure moved HERE, knowingly. Emission rewards look like
  yield; paid-in-CC contributors are "efforts of others." Mitigations: CC stays
  non-cashable in-protocol (one-way curve, GNOT burned, no protocol exit), rewards
  go to *work and correctness*, never to passive holding; comms hygiene (§7.5).
  Accepted residual per owner ("not afraid of SEC fines").
- **Ooki / voter liability**: no vote ever directs real money (GNOT burned;
  rewards formulaic). Remaining exposure: voters run the adjudication of a system
  that mints value. Mitigation below.

### 7.2 Explicitly accepted gray areas (owner sign-off)
1. Inflation-funded winner rewards could be recharacterized as a common-pool prize
   (form-over-substance risk consciously taken).
2. Forfeitable answer/dispute bonds (§3.6).
3. CC transferability stays ON (OTC secondary value → Howey profit-expectation
   pressure) — product choice; the off switch is noted as the single biggest
   securities lever if ever needed.

### 7.3 Structural mitigations to build/do
- **Entity wrapper**: form a **Wyoming DUNA** (Decentralized Unincorporated
  Nonprofit Association, 2024 act) around governance — member-liability shield
  aimed at exactly the Ooki theory, can hold assets/pay for services, tax
  identity. (Verify current status with counsel — flagged in REGULATIONS.md.)
- Deployer/ops separation; no admin keys (already true: frozen params).
- Optional geofence list for "any-chance"/"material-element" states if counsel
  advises at launch.

### 7.4 Comms hygiene (Munchee lesson: marketing makes the security)
Never describe CC as an investment, never quote APR/returns in marketing, never
promise appreciation; describe emission as *participation rewards*; the public
docs lead with the verdict/record product, not the token.

### 7.5 Counsel checkpoints
Pre-launch opinion on: the no-loss+emission structure (gambling/CFTC), CC under
Howey with emission, DUNA fit, state list. Re-check the 2026 CFTC "Prediction
Markets" rule when final.

### 7.6 Mechanisms added AFTER the legal vet launched (reconcile at ingestion)
The in-flight legal vet reviewed v0.1. Added since, all in the same legal
families it is already assessing — listed so its ingestion reconciles them
explicitly rather than silently:
- **Quality-flag bond** (v0.7): one more forfeitable *conduct* bond (same §7.2
  bucket as answer/dispute bonds; burns are nobody's prize).
- **20% burn of losing bonds on decided votes** (v0.6): reduces the
  winner-takes-loser's-bond flavor — post-burn, less of any vote outcome is a
  transfer between adversaries. Directionally helpful.
- **Burned claim fee** (v0.5): entry fee paid win-or-lose — the *Humphrey*
  non-wager factor, already argued in §3.8.
- **Track-record answer priority** (v0.5): non-transferable, non-monetary
  reputation — no new exposure expected.
- **Reservoir-drip emission at a fixed published rate** (v0.6): replaces the
  cross-claim contested pool with a per-conviction rate — *more* like protocol
  staking rewards (the friendliest analogy in REGULATIONS.md §4), *less* like a
  prize pool competed for across claims. Directionally helpful; needs the vet's
  read.

## 8. Open questions / vet queue

1. ~~A1/A2 economics~~ — RESOLVED (F5): profitability condition `y > y* =
   2(r+d)·T_L/T_c`; the fixed reservoir rate sits below y*, so farming never
   enters; netting deleted as theater.
2. ~~A6 smoother~~ — RESOLVED (F8): nothing; linear is the unique
   splitting-neutral rule.
3. ~~Undisputed default-mid~~ — RESOLVED (F1): farmable and CRITICAL as it
   stood; closed by the mandatory quality-flag lane + author/answerer slice
   caps.
3b. **Reservoir-vs-pro-rata follow-up vet** (launched v0.6): the econ vet's
   fixes assumed the pro-rata model; I adopted the reservoir using its own F5
   math (fixed rate below y* beats equilibrium-by-farmer-entry, and A10's
   couplings vanish). A targeted vet is checking that swap for anything the
   translation missed (e.g. FCFS drain races, rate staleness as r and d drift).
8. **minAnswerX re-derivation** (found writing Appendix B): V1's value is "100
   sets' worth" — meaningless without sets. Re-derive as a CC floor on trailing
   total stake (placeholder 100 CC); interacts with the flag bond and the
   demotion turnout floor, so size the three together next vet round.
9. **v0.8 answerer-cap refinement** (bond-based, not stake-based — §3.5) rides
   the next vet round alongside 8.
4. ~~Bond-forfeiture fallback~~ — RESOLVED (rejected; §3.6: time-lock-only bonds
   invite first-answerer squatting/DoS; forfeiture is load-bearing for the
   one-per-claim answer slot). Legal color still pending from the legal vet.
5. ~~Conviction decay~~ — RESOLVED: monotone linear, no decay. A claim's life
   bounds its own conviction window naturally: stakes freeze at the answer,
   disputes run on fixed vote clocks, and a claim that never gets answered
   unlocks at the dead-claim timeout (12 weeks) — so conviction per claim is
   bounded by claim lifetime (months, not years), you cannot fake time, and
   linear is the 128-bit-simplest thing that rewards persistent early conviction.
   Decay would add a knob with no attack it closes.
6. ~~Removal-impact sweep~~ — DONE (Appendix A). Load-bearing catches: X̄ feed
   must switch to Stake/Unstake events; conviction needs 128-bit accumulators
   (A9); emission mints at pull-time and never transits escrow, preserving the
   V1 escrow-conservation invariant and its txtar checks.
7. **Reservoir drip — ADOPTED v0.6, now normative in §3.3** (kept here as the
   original working; the live spec is §3.3):
   - Emission accrues per block into a reservoir: `R += b` where `b = B_period /
     120,960`, halving applies to `b`; accrual stops while `R ≥ R_max = 4 ×
     B_period` (banked quiet weeks, capped; the un-accrued excess is never
     minted — the ceiling-not-floor rule survives).
   - At Finalize of claim c, each winner's gross bonus is **rate-based, not
     share-of-pool**: `g_i = tier_c × rate × conviction_i`, with the individual
     cap `g_i ≤ (tier_c / 2) × stake_i` unchanged. `rate` is a deploy-time
     constant (CC per conviction-unit) sized so a mid-tier winner holding
     through a typical claim sees the §3.3 target (~15–30% APR-equivalent).
   - The claim draws `D_c = min(Σ g, R)`; if `R < Σ g`, everyone in the claim
     scales pro-rata by `R / Σ g` (within-claim only); `R -= D_c`. The
     80/8/7/5 slices apply to `D_c`.
   - Properties: a staker's expected bonus is a *known rate with known caps*
     (legible, and reads as participation yield rather than a contested prize
     pool); total emission stays halving-bounded; there is **no cross-claim
     denominator**, so no period-assignment game and no slowest-claim coupling;
     busy stretches degrade gracefully (partial fills while the reservoir
     refills). Residual: finalize-order FCFS when R runs low — bounded by
     R_max and the individual caps, and draining R requires *real winning
     conviction*, so a griefer cannot burn the reservoir for free. `VETTING
     (pending econ vet)`.

## 10. Implementation & verification plan

- **No migration problem exists**: V1 never launched; V2 is the launch target.
  V1 stays fully audited in git history (branch `court-realm`, base `5d2c4ef`).
- **Build order** (all /p/ packages untouched except deleting the court's
  dependency on tickbook/cshares): (1) `stake.gno` (pools, conviction-128,
  freeze) + `emission.gno` (accrual, halvings, entitlements, pull-claims);
  (2) adapt `claim/answer/session/dispute` per Appendix A; (3) `quality.gno`
  (3-bucket sealed median); (4) render; (5) delete `book/market/fees`.
- **Net size**: roughly –570 LOC removed (book/market/fees) vs ~+450 new
  (stake/emission/quality) — V2 is *smaller* than V1, because the hard machinery
  (governor, grc20votes, twap, curve, checked math) is reused untouched.
- **Storage model (V1 discipline)**: one packed record per (claim, staker,
  side) in a bptree — `stake int64 · convHi/convLo (uint128 in stake-hours) ·
  lastUpdate int64` ≈ four words, one object; a stake/unstake dirties exactly
  two objects (the record + the claim's per-side totals, which ride the claim
  object being written anyway) plus the hourly ring on bucket boundaries —
  matching V1's transfer cost shape. No per-period ledgers exist (reservoir has
  a single accumulator + last-accrual height). Emission entitlements are
  computed at settle and stored per claimant as pull-claims (exactly V1's fee
  pull-claim pattern, audited there).
- **Verification ports the V1 discipline wholesale**: per-file unit suites;
  conservation invariants (escrow ≥ Σ obligations, drains to bounded dust;
  Σ minted ≤ Σ accrued budget — the new one); overflow regressions (128-bit
  conviction at MaxSupply × years); txtar coin-invariant runs on a real node
  (stake→answer→settle→withdraw+bonus; the dispute path; dead-claim unlock;
  reservoir exhaustion if §8.7 adopted); then the same per-unit adversarial
  audit loop to convergence that V1 got. Done means: full sweep, zero findings,
  `make check` + txtar green.

## Appendix A — V1 → V2 removal-impact map (the §8.6 sweep)

File-by-file disposition of the audited V1 realm, with the load-bearing couplings
that an order-book-ectomy could have silently broken:

| V1 file | V2 disposition |
|---|---|
| `court.gno` | ADAPT. Params: drop `oiCeilingBps`, `adjFeeBps`, `adjFeeCapGNOT`, `settleFeeBps`, `minOrderShares`; add emission constants (B₀, halving interval, tiers, split, bonus caps, dead-claim timeout). Keep escrow, curve, coin, gov, frozen `mustSane` discipline. |
| `buy.gno` | KEEP; destination of GNOT changes treasury → **burn sink**. The `IsUserCall` + `OriginSend` payment guard and self-buy ban survive unchanged. |
| `claim.gno` | ADAPT. `claimState` drops book/price-twap/preAnswerPrice/winShares/feePool; gains yes/no pool totals, per-staker stake + conviction records (bptree), the two pool-series rings (sparkline), quality fields. Deposit + dead-claim timeout reclaim. |
| `market.gno` | REPLACED by `stake.gno`: `Stake`/`Unstake` with conviction accounting and the answer-freeze guard. **Load-bearing catch:** the X̄ ring (`cs.oi`) survives — answerability (`answer.gno`) and dispute-bond sizing (`dispute.gno`) both read it — but its feed switches from mint/redeem to stake/unstake events. Same twap machinery, same windows. |
| `book.gno` | REMOVED. Only consumers of `observePrice` were preAnswerPrice (gone) and render (gone). Nothing else read the book. |
| `answer.gno` | ADAPT. Answerability gate + bond formula unchanged; DELETE `priceWindow` + the preAnswerPrice snapshot (provClose needs no price in V2). |
| `session.gno` | ADAPT. 72h `settleDelay` + exactly-once bond return unchanged; settle sets verdict=answer, quality=mid default; no fee skim. |
| `dispute.gno` | ADAPT. Bond doubling / 3 rounds / escrow windows / reopen / `quorumFloor` all KEPT. The dispute proposal's payload also opens the court-local quality tally (§3.4). `Finalize` computes entitlements and unlocks stakes; `RedeemWinning`/`RedeemClosed` become `WithdrawStake` (always 1×) + pull-claims for bonus slices. |
| `fees.gno` | REPLACED by `emission.gno`: period budget + halving accounting, entitlement math, pull-claims for the four slices. The audited 128-bit `mulDivFloor` and the `VoteOf`-based voter-split pattern carry over directly. |
| `directory.gno` | KEEP. |
| `render.gno` | ADAPT. Sparkline = stake-ratio series; drop BestBid/BestAsk; show tier, route, emission drawn. Sealed-tally rule extends to the quality tally. |
| `/p/tickbook`, `/p/cshares` | REMOVED from the court's dependency set (packages remain in-repo, unused by V2). |
| `/p/twap` | KEEP — repurposed: X̄ ring + the two pool-series rings. |
| `/p/grc20votes`, `/p/governor`, `/p/checkpoint`, `/p/curve` | KEEP unchanged. Quality deliberately avoids touching `/p/governor` (§3.4). |

Cross-cutting invariants preserved (these were the V1 audit's spine):
- **Escrow conservation**: stakes/deposits/bonds transfer user↔escrow; **emission
  is minted directly to claimants at pull-time and never transits escrow** — so
  "escrow balance ≥ Σ outstanding obligations, drains to bounded dust" survives
  verbatim, and the V1 txtar coin-invariant tests adapt with new names.
- **Checked arithmetic**: every coin-leg product through `ccMul`/128-bit paths;
  conviction is 128-bit (A9); the deploy-time supply invariant (§3.3) replaces
  the removed OI ceiling as the tally-overflow guarantee.
- **Exactly-once disposal** (bonds, deposits, entitlements) and **sealed tallies**
  carry over as design rules to every new V2 flow.

## Appendix B — worked end-to-end example (v0.8)

Numbers chosen realistic; doing this arithmetic is what surfaced the v0.8
answerer-cap refinement. Court supply S = 10,000,000 CC; emission constants:
r = 0.25%/wk, d = 0.1%/wk, T_L/T_c = 1.5 → y* = 1.05%/wk; **rate = 0.75·y* ≈
0.79%/wk ≈ 0.113%/day per CC of conviction**; B_period = 10,000 CC/wk;
R_max = 40,000 CC.

**Claim**: "Flight 171's fuel switches were cut off before impact." Author
Alice opens it: 1 CC deposit escrowed, 0.1 CC fee burned.

| Day | Event | Stake pools (YES/NO) | Ratio |
|---|---|---|---|
| 0 | Alice stakes 30,000 YES (author, has skin) | 30,000 / 0 | 100% |
| 7 | Bob stakes 20,000 NO | 30,000 / 20,000 | 60% |
| 14 | Carol stakes 10,000 YES | 40,000 / 20,000 | 66.7% |
| 21 | Dan (record net-4, priority window) answers YES; bond = 50%·X̄ ≈ 30,000 escrowed; **staking freezes** | frozen | 66.7% |
| 24 | 72h pass, no dispute, no flag → SettleUndisputed: verdict YES, quality mid (default), Dan's bond returns | — | — |

**Conviction at freeze** (CC-days): Alice 30,000×21 = 630,000; Carol
10,000×7 = 70,000; Bob 280,000 (losing side — irrelevant to draws).

**Draws at settle** (tier mid = 1×, rate 0.113%/day):
- Alice: 630,000 × 0.113% ≈ **712 CC** (cap 0.5 × 30,000 time-avg = 15,000 — slack).
- Carol: 70,000 × 0.113% ≈ **79 CC** (cap 1,667 — slack).
- Σ winners 791 = 80% of the draw → D̂ ≈ 989 CC; reservoir has ~34,000 accrued — pays in full.
- Author slice 8% ≈ **79 CC** to Alice (cap 15,000 via her stake — slack).
- Voter slice 7% ≈ 69 CC — **not minted** (no vote occurred).
- Answerer slice 5% ≈ **49 CC** to Dan — under the v0.8 bond-based cap
  (0.5 × 30,000). *A stake-based cap would have zeroed this and killed the
  answerer incentive — the inconsistency this example caught.*
- **Total minted ≈ 919 CC ≈ 0.009% of supply.** Bob withdraws his 20,000
  whole. Escrow held 60,000 stakes + 1 deposit + 30,000 bond and returned
  every unit 1×; emission never touched it. Conservation ✓.

**Returns check**: Alice earned ~2.6% on 30,000 over ~24 days *by being right*
(~0.79%/wk on conviction — a p<1 staker's expected rate is p-scaled); a
coin-flipper nets negative against lock cost, per the F5 band. A matched
farmer staking both sides earns the winner leg's 0.79%/wk on half their
capital against 2× lock costs — negative, as designed.

**Alternative endings**:
- *Flagged and demoted*: flag bond posted day 22, quality vote (7d) lands
  **low** with ≥¼-bar turnout → tier 0×: **zero minted for anyone**, all
  principals 1×, flag bond returns, Dan's bond still returns (verdict stood;
  quality ≠ verdict).
- *Disputed and overturned*: verdict flips NO → Bob's 280,000 CC-days draw
  instead; Dan's bond: **80% (24,000) to the disputer, 20% (6,000) burned**
  (v0.6 rule); the 7% voter slice mints to with-verdict voters,
  tier-invariant; quality = the dispute vote's 3-bucket outcome under the
  ⅔-for-high gate.

## 9. Changelog

Newest first.

- **v0.9** — (iteration 7) §3.9 signal layer specced: three ratio series
  (instantaneous, trailing-week, conviction-weighted lifetime) — the third is
  free (the per-side conviction totals ARE ∫pool dt, already maintained for
  rewards); divergence between series is itself signal; sealed-tally discipline
  extended to the quality vote. §7.6 added: explicit reconcile-list of the five
  mechanisms added since the legal vet launched (so its ingestion addresses
  them rather than silently missing them). §10 storage model sketched: one
  packed record per (claim, staker, side), two dirtied objects per stake op,
  pull-claims reuse V1's audited fee pattern.
- **v0.8** — (iteration 6) **Appendix B: worked end-to-end example** with real
  numbers (30k/20k/10k stakes, 21-day life, bond 30k, draws 712/79/79/49,
  minted 919 ≈ 0.009% of supply, escrow conservation checked, both alternative
  endings). Working the arithmetic caught an F1-cap inconsistency: a
  stake-based answerer cap zeroes the slice for the natural non-staking
  answerer — refined to a **bond-based answerer cap** (the bond IS the skin;
  F1's rationale preserved). Also: minAnswerX must be re-derived in V2 units
  (V1's "100 sets" is meaningless without sets) — §8.8; both items ride the
  next vet round.
- **v0.7** — (iteration 5) specced the quality-flag lane in full (window =
  answer→settle with settlement pause; bond returns iff low; demotion needs
  ¼-bar turnout so dust griefing can't zero honest claims; promotion keeps the
  ⅔+bar gate; refused during disputes; flagger earns nothing — paid flagging
  would recreate F2 in miniature). Recorded the incentive geometry: dilution-
  payers, who fund every draw, are exactly the electorate empowered to zero
  junk. Pinned burn mechanics (keyless-sink send for GNOT; audited
  `grc20votes.Burn` for CC). Launched the combined attack-vet over the three
  new DRAFT mechanisms (flag lane, track-record answer priority, burned claim
  fee).
- **v0.6** — (iteration 4b) **econ vet ingested — 11 findings, 2 CRITICAL, all
  addressed.** F1 author-mill on undisputed-mid → mandatory quality-flag lane +
  author/answerer slice caps (A5 closed). F2 voter-carrot tier-coupling →
  tier-invariant, paid-even-at-low, with-verdict-only voter slice (A11 closed).
  F3 median capture + free self-dispute → ⅔-supermajority-for-high ratchet,
  with-median carrot dropped, 20% decided-vote bond burn (A4 closed). F4
  conviction overflow / settlement-DoS → stake×hour units + mulDiv128 + G_MAX
  clamp-never-abort (A9 closed). F5 matched-farming closed form → **reservoir
  adopted with rate fixed in (y*/2, y*)** so farming never enters (beats
  pro-rata's equilibrium-by-farmer-entry); per-address netting deleted — the
  vet caught my A2 lock-cost claim as arithmetically false. F6 verdict-prize-
  collapse insight recorded (verdict security strictly improved vs V1; P+ε
  caveat registered). F7 losers exit after decided rounds (A12 mitigated).
  F8 no pool smoother (A6 closed). F9 exact conviction semantics + freeze
  atomicity + conviction-weighted signal (A8 closed). F11 moot under the
  reservoir. Params table rewritten; targeted follow-up vet launched on the
  reservoir swap itself (§8.3b).
- **v0.5** — (iteration 4 brainstorm) questioned "capital is the only
  credential": ADOPTED (draft) track-record answer priority (non-transferable
  stood/overturned record gates a 24h priority window; lying burns the
  credential); ADOPTED (draft) a 10% burned claim fee (CC's only sink; Humphrey
  win-or-lose-fee pattern); REJECTED continuous-probability verdicts (market
  prices belief, vote decides truth).
- **v0.4** — (iteration 3) bond sizing re-derived for V2 (§3.6): the undisputed
  path structurally caps at mid tier, so max undisputed extraction =
  `midTier/2 × S` — exactly V1's `50%·X̄` bond, for a V2-native reason; frozen
  as `answerBondBps ≥ maxUndisputedTier/2`. Added §10 implementation &
  verification plan (no migration; V2 net smaller than V1; audit discipline
  ports with one new invariant Σminted ≤ Σaccrued).
- **v0.3** — (iteration 2) self-found A10: cross-claim per-period pro-rata is
  timeable and couples payouts to the slowest dispute; specced the reservoir
  drip as the candidate fix. Resolved §8.5: conviction monotone linear, no
  decay.
- **v0.2** — (iteration 1) bond-forfeiture fallback REJECTED (first-answerer
  squat DoS — §3.6); Appendix A removal-impact map (X̄ feed switch; 128-bit
  conviction; emission never transits escrow); quality tally specced
  court-local — no /p/governor change.
- **v0.1** — initial standalone draft: no-loss conviction staking, bounded
  halving emission, quality tiers, GNOT burn decision, bonds kept, diff table,
  attack table, regulatory rationale + accepted-risk register. Launched the
  economics and legal vets.
