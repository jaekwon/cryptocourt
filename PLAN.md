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

## 1a. The design at a glance (v0.13 shape — ten invariant bullets)

1. **Stake, don't bet**: back YES or NO with CC; **losers always withdraw 1×**;
   principal is never at risk on any outcome.
2. **Conviction pays**: rewards weight by ∫stake·dt on the winning side —
   early, sustained, correct positions earn most; last-second capital earns ~0.
3. **Emission, not extraction**: winners are paid by new issuance from a
   reservoir accruing on a deploy-frozen, stepped-down **rate schedule**
   (`rate_n = 0.85·y*(n)`) sized so matched-stake farming never enters; total
   emission is finite and invariant-checked against the supply ceiling.
4. **Quality gates value**: low 0× / mid 1× / high 2×; high needs ⅔ + full-bar
   turnout; anyone can flag a claim into a quality vote (slot reopens if the
   vote is inconclusive); junk pays nobody.
5. **The verdict machine is V1's, untouched**: answer bond → 72h → dispute →
   sealed 7-day votes → escrow windows → 3-round close. Verdict security
   *improved*: a flipped verdict no longer moves any staker principal.
6. **Forfeitures burn; compensation mints**: every bond/deposit forfeiture is
   burned; every prevailing-party compensation is a capped emission slice — no
   value ever moves between adversaries on any outcome.
7. **GNOT is burned at Buy**: one-way curve in, nothing ever out; no treasury,
   no backing, no redemption — CC is participation, not a claim on assets.
8. **Reputation is earned, not bought**: a non-transferable, difficulty-
   weighted answer record gates a 24h priority window on the answer slot;
   lying burns the credential.
9. **Every number is a formula**: no discretionary payment votes, no runtime
   knobs, frozen constants + deploy-checked invariants (nine and counting).
10. **The product is the record**: the claim page — three ratio series, the
    verdict, its route, its quality tier — reproducible from public reads.

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

### 3.1 Claim lifecycle — `VETTED (econ, mech); 2A pending on Finalize gating`

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
   emission slices. The deposit refunds to the author **unless the quality vote
   landed low — then it is slashed and burned** (v0.11, §3.4). Finalize is
   participant-only for its first week of eligibility, permissionless after
   (v0.11, §3.3). **Losers may withdraw 1× immediately after any DECIDED
   dispute round** (econ vet F7) — their outcome cannot improve, and releasing
   them defuses the multi-round freeze-hostage (up to ~8 weeks of locked
   capital across 3 rounds).
6. **Dead claim.** Corrected v0.15: pre-answer stakes are never locked (unstake
   is free until an answer posts), so the 12-week timeout on a never-answered
   claim disposes only the **deposit and fee** — deposit refunds, fee burns
   (§3.8, "dies dead") — and closes the claim to new stakes. Nothing else was
   ever held. (Fixes V1 residual O6; the earlier "unlocks fully" wording
   implied a lock that doesn't exist.)
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

### 3.3 Emission — **reservoir drip, rate-based** — `VETTED (reservoir vet: KEEP w/ tweaks, adopted v0.11)`

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
  Honest stakers with accuracy p profit iff `y > y*·(1/2p)`.
- **v0.11 (reservoir vet F-R1, BREAKS-AS-SPECCED — fixed): the rate is a frozen
  SCHEDULE, not a frozen scalar.** A scalar is *scheduled to self-defeat*: `d`
  decays deterministically (the budget halves while supply only grows), so y*
  sinks below any fixed rate by ~the second halving and farming turns on with
  no adversary at all. Fix: at deploy, compute `rate_n` per period from the
  known halving path and the ceiling-supply d(n) (r frozen at the launch
  estimate) — still a pure constant table, zero governance surface, V1
  discipline intact. With the deterministic decay handled, a **thinner
  anti-farm margin is safe: `rate_n = 0.85·y*(n)`** (reservoir vet F-R5),
  which pays honest stakers down to p ≈ 0.59 instead of amputating the
  0.5–0.67 calibration population. Residual r-drift is accepted and one
  incentive-safe lever is noted for the wrapper entity: a **decrease-only**
  ratchet (capture wants the rate *up*; a monotone-down lever is
  extraction-proof). No increase lever, ever.
- Calibration is a protocol constant; **public documents never express it as a
  rate of return** (legal vet: our own §3.3 "APR-equivalent" language violated
  §7.4's hygiene inside the same file — struck; yield calibration lives in
  [ECONOMICS.md](./ECONOMICS.md), the private memo, created v0.17).
- **Multi-court pin (v0.15)**: the rate schedule is ONE realm-level constant
  table shared by every court, computed at deploy from the ceiling-supply path
  — never from a court's live supply. Per-court live-supply schedules would
  differ by court age and size, turning d(n) into a manipulable, court-shaped
  runtime artifact; the ceiling-supply basis is conservative for every court
  (real d ≥ ceiling-based d ⇒ real y* ≥ scheduled y* ⇒ the 0.85 anti-farm
  margin holds everywhere). And the symmetric worry — tiny young courts being
  over-diluted by a fixed absolute budget — dissolves on inspection: draws are
  conviction-based, so minted ≤ rate × Σconviction ≤ rate × (staked fraction ×
  supply) per unit time. **A court can never be diluted faster than its own
  participation earns** (d ≤ rate × staked-fraction, any size); B only caps
  throughput, it never forces emission.
- **Ceiling, not floor**: unearned budget is never minted; the reservoir cap
  banks at most 4 quiet weeks.
- **Deploy-time invariants** (checked in code, V1-style): `curveCap + Σemission
  ≤ MaxInt64/Bps` with ≥20% headroom; conviction fits int64 in stake-hours; and
  per-claim `Σg` is **clamped** (never aborted) at a `G_MAX` so no crafted
  position can poison a shared settlement path (econ vet F4: checked-abort on a
  shared path is a settlement DoS — clamp instead).
- **v0.11 (reservoir vet F-R3): Finalize is participant-gated for a grace
  week.** Permissionless-Finalize at an empty reservoir was an adversary's
  button: finalize a rival's claim the moment it's eligible while R ≈ 0 →
  their draw = min(Σg, 0) = 0, *forever*, at gas cost. Now only a claim's
  participants (staker/author/answerer) may Finalize for the first week of
  eligibility; permissionless after (liveness preserved). The accrual-interval
  queue (entitlements reserved on the cumulative-emission number line, paid as
  accrual covers them) is recorded as the upgrade path if scarcity becomes
  chronic despite the rate schedule.
- Pins (reservoir vet F-R4): `R_max` is defined against the *current* period's
  budget, and R may transiently exceed it at a step-down boundary (pause
  accrual; never clamp R down). Public copy advertises `min(rate,
  availability)` — never a fixed return. Cross-claim coupling is not "gone",
  it is **intermittent and bounded**: under scarcity your draw depends on
  rivals' prior draws, by design, failing in the right order (farmers exit
  first, then the least-confident stakers; the most accurate capital is the
  last standing).
- Residual (accepted): FCFS when the reservoir runs dry — bounded by `R_max`
  and the individual caps; draining R requires *real winning conviction*, so it
  cannot be griefed for free (and the grace-gate above removes the third-party
  variant).

### 3.4 Resolution: verdict + quality — `VETTED ×3 (econ F1–F3, reservoir F-R2, mech R1–R4); 2A pending on the reopen chain`

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
- **Window (hardened v0.12, mech vet R1/R2)**: flags are allowed from the
  answer until the settle tx lands, and **settle is disallowed outright for the
  first 24h after the answer** (the flag-open sub-window) — without it,
  permissionless settle turns the "≥72h of exposure" into a *1-block ordering
  race* the mill times (spam settle from 72h+1; the flagger must win strict
  block priority). A flag **pauses settlement** until its vote closes.
- **The flag slot is consumed only by a CONCLUSIVE vote** (v0.12, mech vet R1 —
  this was a launch-blocking hole): an outcome of mid with turnout **below**
  the ¼-bar floor is *inconclusive* and REOPENS the slot. Otherwise the mill's
  own sybil flags instantly at answer+1 with a dust vote destined for
  low-turnout mid — burning one small bond to consume the only flag and immunize
  the claim; the turnout floor added against dust-griefers would have protected
  exactly the wrong party. Re-flags post an escalating bond (dispute-style
  doubling) so genuine serial re-flagging stays spam-priced.
- **The emission rate is sampled at answer-freeze, never at settle** (v0.12,
  mech vet R2a): a 7-day flag pause (or an honest 8-week dispute) must not drag
  a claim across a rate step-down — `rateAtFreeze` is stored in the claim at
  the freeze and used for its draws. This kills the halving-boundary delay
  grief (burn a 2%·X̄ flag bond to halve a rival's entire draw) and quietly
  fixes an unprompted bug: honest long disputes were already crossing
  step-downs and silently halving winners' draws.
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
  timing games); **a flag must close before the draw** — the tier crystallizes
  before D is computed, and the flag window ends at the settle tx (reservoir
  vet pin: the earlier text never excluded a post-payment flag).
- **v0.11 — policing must be PAID (reservoir vet F-R2, reversing v0.7's
  no-reward stance).** Under pro-rata, junk claims diluted every other claim's
  yield, so the crowd had a diffuse selfish motive to flag; the reservoir
  deleted it (in under-demand a mill harms no identifiable party), and
  bond-return-only flagging is pure altruism — the author-mill re-arms as
  *single-sided p=1 farming*, which sits INSIDE the anti-farm band (it locks
  1×, not 2×). Fix, harmonized with the v0.11 burn rule: on a low outcome the
  author's **deposit is slashed and burned**, and the successful flagger is
  compensated by a **formulaic emission slice ≈ deposit/2** (mint, not
  transfer — no bilateral flow). Kill threshold for the mill drops from
  q ≈ 0.65 to q ≈ 0.2, which a paid flagger community credibly supplies. The
  v0.7 worry (paid flagging recreates F2 in miniature) is bounded: the bounty
  pays ONLY on a real vote landing low with the ¼-bar turnout floor, and a
  wrong flag burns the flag bond. Register note: this puts a small bounded
  prize on low-median capture against honest claims — acceptable because
  principal is untouched, the prize ≪ the capture cost, and the asymmetric
  ratchet caps the blast radius.
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

### 3.5 Reward split — `VETTED ×2 (econ F1/F2/F8, legal #4)`

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
- **v0.11 additions**: two further formulaic mint-slices exist under the
  "forfeitures burn; compensation mints" rule — prevailing-party bond
  compensation (§3.6) and the flag bounty (§3.4) — both capped, both computed
  from tallies, both subject to reservoir availability like everything else.
  **Public naming** (legal vet): the winner slice is called **accuracy
  rewards**, the cap is stated as "reward ≤ 0.5× (mid) / 1.0× (high) of locked
  stake" — never as an "up to 2×" multiplier headline; all contributor slices
  are described as *reasonable compensation for services rendered, including
  voting or participation* (deliberately the Wyoming DUNA act's own permitted
  category, W.S. 17-32-104(c)(i)); the emission step-down is public-copy
  language for what the math calls halving.

### 3.6 Bonds and deposits — `REVISED v0.11 (forfeitures burn); 2A pending on comp EV`

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

Bond revisions, in two stages:
- **Dispute bond is capped**: `min(20%·X̄, 2 × answer-bond cap)` (econ vet F5).
  X̄ counts *refundable* stake now, so matched capital inflates it for free —
  an uncapped 20%·X̄ would let a farmer price honest policing out of its own
  claim. The doubling schedule still deters serial disputes.
- **v0.11 — "FORFEITURES BURN; COMPENSATION MINTS" (legal vet + econ vet,
  jointly).** The legal vet found the fatal sentence in our own corpus: V1's
  tokenomics doc §4 says the bonds are *"a bet between two people. The loser's
  bond goes to the winner, whole."* — a literal, self-described, loser-pays-
  winner bilateral transfer on a vote outcome, i.e. the exact structure every
  other part of V2 exists to delete, quotable by any adversary, and the #1
  residual on BOTH the gambling and CFTC axes. The econ vet had independently
  shown the whole-bond transfer makes self-dispute free (wallet A answers,
  wallet B disputes, A pockets B's bond). One rule now fixes both, everywhere:
  **a forfeited bond is burned in full, never paid to any party; the
  prevailing party is made whole by a formulaic emission slice sized to V1's
  compensation schedule and capped like every other slice.** The loser still
  loses exactly as much (deterrence unchanged); the winner is still
  compensated (incentive unchanged); no value ever moves *between* adversaries
  on any outcome — punishment is deflation, reward is issuance. This
  supersedes v0.6's partial 20%-burn rule, prices self-dispute at 100% (not
  20%) of the sacrificed bond, shrinks vote-capture loot to capped emission
  only (F6 margin improves again), and makes §7.1's "no bilateral
  event-contingent payment" claim TRUE rather than aspirational. Cost
  accepted: prevailing-party comp now depends on reservoir availability
  (scaled in exhaustion like all slices) — noted in the register.
- **Prose correction (reservoir vet F-R6)**: the §3.6 bond-sizing argument
  above overstated itself — under the reservoir, `50%·X̄` does not *equal* the
  maximum undisputed extraction; it **upper-bounds it with ~5× slack**
  (rate-based extraction over a ≤12-week claim life ≈ 9%·X̄, vs the winner-cap
  ceiling the invariant was derived from). Keep the invariant exactly as
  written — a conservative cap-based bound survives rate/duration drift — and
  note the lie is EV-negative at detection ≥ ~15%, not the 50% claimed before,
  which comfortably absorbs the flag lane's imperfect detection.
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

### 3.7 GNOT: burn — **the call** — `VETTED (legal #3: confirmed, under-argued upside)`

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
  bond and deposit forfeitures) use `grc20votes.Burn`, which V1 already
  exercises — audited code, no new machinery.
- **Legal-vet wording corrections (v0.11)**: the burn is described publicly as
  *legible and verifiable on-chain* — never as a scarcity feature or a
  "monetary meme" (the SEC's Munchee order cited a token-burn-for-appreciation
  pitch as Howey evidence; the mechanism is fine, the marketing frame is the
  hazard). And "zero compliance machinery" was an overclaim: burning defeats
  the money-*transmission* leg, but the seller-of-own-convertible-token (ICO)
  MSB characterization of one-way curve sales gets an explicit counsel
  checkbox (§7.5) — likely fine for an operatorless immutable contract, not
  free to assert.

### 3.8 Brainstorm outcomes (iteration-4 step-back pass) — `DRAFT`

Assumption questioned: **capital is the only credential.** The answer slot is
V2's most abusable scarce resource (one per claim; verdict-by-default when
undisputed), and it is currently first-come-first-served to anyone with a bond.

**ADOPTED (vetted v0.12, mech vet: ADOPT-WITH-FIXES): track-record answer
priority.** The court keeps a per-address, non-transferable answer record;
when a claim becomes answerable, the first `priorityWindow` (24h) accepts
answers only from qualified addresses; after that, anyone. The credential is
earned by the behavior we want and destroyed by the behavior we fear (an
overturn burns it); non-transferable, mints nothing, newcomers delayed never
excluded. The vet confirmed farming it is UNPROFITABLE (3× deposits + burned
fees + bond locks + 72h waits for a credential that dies on first misuse) —
and added three fixes, adopted:
- **Difficulty-weighted record (R6 — the sharpest cross-interaction found)**:
  an *undisputed* stand counts ~0 toward priority; a **contested-and-upheld**
  answer counts full. Raw stood-counting is maximized by cherry-picking
  trivially-true claims — the author-mill's exact habitat — so the naive
  credential and the mill would COMPOUND. Difficulty-weighting de-aligns them:
  mill claims (undisputed by construction) grant no priority.
- **Cold-start guard (R5e)**: the priority gate is disabled until ≥N addresses
  qualify — otherwise launch imposes a court-wide 24h latency tax while nobody
  can qualify.
- **Flywheel limiter (R5b)**: one active priority claim per address at a time —
  a qualified answerer can't blanket every juicy claim's 24h window at once.
Cost: one bptree + a phase check in PostAnswer. Complements — not replaces —
the bond (§3.6): the bond prices one lie, the record prices a *career* of them.
Register (R6 residual): the overturn-decrement still mildly chills answering
genuine 50/50 claims; difficulty-weighting compensates by making contested
wins the only path to the credential.

**ADOPTED (vetted v0.12, mech vet: ADOPT-WITH-FIXES): claim fee.** 10% of the
claim deposit, escrowed at open; **burned when the claim dies unanswered or
resolves LOW; refunded when it resolves mid/high with the turnout floor met**
(R7b). The vet's numbers showed the original always-burn was *regressive*: it
barely dents a mill claim that attracts real conviction, while making the
honest low-conviction long-tail net-negative (author slice on a thin claim <
the fee). The conditional refund keeps the CC sink exactly where it belongs
(junk and dead claims) and stops taxing honest experimentation. It also raises
the mill's break-even life to ~13+ weeks against the 12-week dead-claim
ceiling — a real complement to the flag lane, not a substitute. Register
trade-off (recorded honestly): a conditionally-refunded fee is weaker on
*Humphrey* factor 1 ("fees paid unconditionally") than the original — accepted,
because the fee was never the load-bearing legal element (the lead argument is
risk-on-outcome, §7.1) and the refund condition is contribution-quality, not a
wager's win/lose.

**REJECTED: continuous-probability verdicts** (voters submit probabilities;
payout by closeness — a scoring-rule court). The division of labor is already
right: the *market* (stake ratio) prices belief continuously; the *vote*
decides truth discretely, where 5001 bps and sealed tallies are battle-tested.
A numeric verdict would hand adjudicators a knob attackers can nudge and
dissolve the crisp "the record says YES/NO" product. Recorded so it isn't
re-derived.

**Pass 2 (iteration 8) — assumption questioned: does the one-way curve still
earn its place, now that emission also mints and GNOT is burned?**

- **KEPT — the curve, with a sharpened job description.** In V2 the curve is
  the only GNOT→CC gate: it prices Sybil capital (every voting/staking unit
  traces to burned GNOT or earned emission), its monotone price still rewards
  early belief *in the court itself*, and its cap co-anchors the supply
  invariant. What it no longer is: a value floor.
- **CATCH (real, actionable): "backing" must be deleted from the product.**
  V1 rendered `backing = treasury/supply` and told buyers they pay ~2×
  backing. Under burn there is no treasury: **nothing backs CC and nothing
  ever redeems it**. Any surviving "backing" figure in render/docs/wireframe
  would be an implied redemption promise — legally the *opposite* of the
  §3.7 consumption story, and factually false. V2 renders the curve price
  (cost of the next unit) and supply only. Added to Appendix A (render row)
  and the diff table.
- **CHECKED — cold start under the reservoir is benign.** A new court has tiny
  supply and tiny conviction; because draws are *rate-based*, early
  participants earn the same per-conviction rate as anyone later — no
  early-APR spike, no mercenary rush; the unearned budget accrues to R_max and
  is then simply forgone (ceiling-not-floor working as intended). The curve
  starting near zero makes early CC cheap — that, not emission, is the
  bootstrap subsidy, and it pays only people who commit capital to a brand-new
  court.
- **KEPT — per-court coins** (vs one shared coin): fragmented liquidity is the
  honest cost, but isolation is the product — each court is its own failure
  domain, its own credibility ledger, and its own securities-analysis unit; a
  shared coin couples every court's legal and economic fate.
- **REJECTED — batch weekly quality votes** (one proposal covering all claims
  settled that week): cheaper turnout arithmetic, but list-voting invites
  rubber-stamping, and the flag lane already makes standalone quality votes
  rare (only flagged, undisputed claims). Not worth the attention dilution.

**Pass 3 (iteration 12) — assumption questioned: claims are isolated.** The
court vision's four core actions were answer / answerDispute / **support** /
**counter** — argument EDGES between claims — and V2's tokenomics has silently
ignored the edge layer. Should edges join the money loop?

- **DECIDED — edges stay OUT of the V2 money loop, deliberately and on the
  record.** Value-coupled edges (a supporting claim's stake/quality feeding
  the supported claim's economics) would create exactly the surfaces five vets
  never examined: cascade draws (one resolution triggering payouts across a
  graph), circular-support rings, edge-spam as an emission vector, and a
  cross-claim denominator sneaking back in through the graph. The V2 economy
  is *per-claim by construction* — every invariant in §10 depends on it.
  Edges ship (V3) as **curation metadata**: anyone may link claims
  support/counter, rendered on the claim page, zero economic weight. If they
  are ever value-coupled, that is a NEW tokenomics design with its own full
  vet cycle — this paragraph is the tripwire.
- **REJECTED — sortition juror panels** (random subsets instead of the whole
  electorate per dispute): attention-cheaper at scale, but small panels make
  bribery cheap (buy k jurors, not 50% of a bar-clearing turnout), gno's
  determinism makes unpredictable, unbiasable juror randomness its own hard
  project, and the full-electorate quorum machinery is the single
  most-battle-tested part of V1. Revisit only if vote fatigue is observed
  (V3+, with a randomness design in hand).
- **KEPT — quality as one dimension.** Low/mid/high conflates rigor, novelty,
  and importance; a multi-axis score would be more expressive and much worse:
  each axis is a new capture surface (A4 per axis), the Schelling convergence
  that makes the median honest depends on coarse, common-knowledge buckets,
  and the tier's only job is gating emission — one dimension suffices for
  that. Sub-dimensions belong in render (voters' free-text rationales, V3).
- **NOTED — courts die clean.** No wind-down mechanism is needed, by
  construction: stakes are always withdrawable (no-loss), claims die at the
  timeout with deposits refunded, and — because GNOT is burned — **there is no
  treasury to fight over in an abandoned court**. Death = the render going
  quiet. The absence of an end-of-life capture surface is a direct dividend
  of the burn decision (§3.7).

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
| rate schedule (CC per conviction stake-hour, per period) | `rate_n = 0.85 × y*(n)`; `y*(n) = 2(r₀+d(n))·T_L/T_c`, d(n) from the deploy-known step-down + ceiling-supply path | v0.11: frozen SCHEDULE not scalar (A14); pays p ≳ 0.59; decrease-only ratchet optional, never an increase lever |
| Finalize authorization | participant-only first week of eligibility, then permissionless | v0.11 (A13) |
| bond/deposit forfeitures | 100% BURNED, never paid to a party; prevailing-party comp + flag bounty are capped emission slices | v0.11 "forfeitures burn; compensation mints" |
| flag bounty | ≈ deposit/2, minted on a low outcome | v0.11 (A15) |
| B₀ (weekly accrual) / R_max | `b·120,960` / `4 × B_period` | reservoir cap banks ≤ 4 quiet weeks |
| halving interval | 104 periods | total emission ≤ 2·B₀·104, finite |
| supply invariant | curveCap + Σemission ≤ MaxInt64/Bps, ≥20% headroom | checked at deploy |
| conviction unit | stake × hours | fits int64 ~5× (F4); draws via mulDiv128 |
| G_MAX | per-claim Σg clamp | clamp, never abort, on shared settle paths (F4) |
| tiers | low 0× · mid 1× · high 2×; **high needs ⅔ + bar turnout** | §3.4 asymmetric ratchet (F3) |
| winner cap | (tier/2) × time-averaged stake | flash-proof base (F9) |
| author/answerer slice caps | ≤ (tier/2) × own stake | no capital-free rake (F1) |
| split | 80/8/7/5; **voter slice tier-invariant, paid even at low, with-verdict only** | F2/F3 |
| quality-flag bond | max(flagMin, 2%·X̄); returns iff low, else burns; doubles per re-flag; slot reopens on inconclusive mid | spam price only — the WINDOW and SLOT rules are the security (mech vet R4) |
| flag-open sub-window | settle disallowed first 24h post-answer | v0.12 (A17) |
| rateAtFreeze | emission rate sampled at answer-freeze | v0.12 (A17) |
| answer priority | difficulty-weighted record (contested-and-upheld only), ≥3 → 24h window; gate off until N addresses qualify; 1 active priority claim/address | v0.12 (A18) |
| claim fee | 10% of deposit; burned on dead/low, refunded on mid/high with turnout floor | v0.12 (R7b) |
| dispute bond | min(20%·X̄, 2 × answer-bond cap), doubling kept; **20% of losing bond burns on decided votes** | F5 cap; F3/F6 burn |
| minAnswerX | re-derive in V2 units (trailing total STAKE, no sets exist; placeholder 100 CC) | §8.8 — V1's "100 sets' worth" is meaningless in V2 |
| answer bond, escrow windows, 5001 bps, 72h delay | V1 values | unchanged |
| dead-claim timeout | 12 weeks | new (O6 fix) |
| bond–tier coupling | `answerBondBps ≥ maxUndisputedTier/2` | frozen invariant, §3.6; deploy refuses otherwise |

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
| A10 | Cross-claim pro-rata: period-assignment timing + slowest-dispute payout coupling (self-found) | Reservoir drip adopted (§3.3) — no cross-claim *denominator* exists to time; coupling through R is **intermittent and bounded** under scarcity, failing farmers-first (F-R4), not "gone" | `CLOSED (reservoir, wording per F-R4)` |
| A11 | Voter-carrot tier-coupling → electorate-wide drift to "high"; policing junk is unpaid (CRITICAL) | Voter slice tier-invariant, paid even at low, with-verdict only | `CLOSED (F2)` |
| A12 | provClose freeze-hostage: push a rival claim through 3 failed rounds; stakers frozen ~8 weeks, conviction pays zero | Losers exit 1× after each decided round; the self-dispute variant now sacrifices 100% of the bond (v0.11 burn rule); a griefer cannot force votes to fail on any claim with motivated stakers | `MITIGATED (F7+v0.11); residual: orphan claims, low damage` |
| A13 | Adversary-timed zero-draw: third party Finalizes a rival's claim while R ≈ 0 → their draw = 0 forever, at gas cost (reservoir vet F-R3) | Finalize participant-only for a 1-week grace, permissionless after; accrual-interval queue recorded as the upgrade path | `CLOSED (v0.11)` |
| A14 | Scheduled self-defeat of a frozen scalar rate: d decays by the halving path → y* sinks below rate by ~the 2nd halving → farming turns on with no adversary (reservoir vet F-R1) | Rate is a deploy-frozen SCHEDULE tracking y*(n)'s deterministic component at 0.85·y*(n); decrease-only ratchet noted for r-drift; no increase lever | `CLOSED (v0.11)` |
| A15 | Author-mill v2 — single-sided p=1 farming inside the anti-farm band, re-armed because the reservoir deleted the crowd's selfish flag motive (reservoir vet F-R2) | Low-tier deposit slash (burned) + flag bounty minted (≈ deposit/2) → mill kill threshold drops to q ≈ 0.2 | `CLOSED (v0.11)` |
| A16 | **Self-flag slot squat** (mech vet R1, launch-blocking): mill's sybil flags its own claim instantly with a dust vote destined for low-turnout mid — one burned bond consumes the only flag slot and immunizes the claim; the ¼-bar floor shields the mill, not honest claims | The slot is consumed only by a CONCLUSIVE vote; inconclusive (mid under the turnout floor) REOPENS it; re-flags post doubling bonds | `CLOSED (v0.12)` |
| A17 | **Settle/flag ordering race + step-down delay grief** (mech vet R2): permissionless settle at 72h+1 turns the flag window into a 1-block race; and a 7d flag pause could drag a rival's claim across a rate step-down, halving their draw for one 2%·X̄ bond | Settle disallowed for the first 24h post-answer (guaranteed flag-open interval); emission rate sampled at answer-freeze (`rateAtFreeze`), so no pause or honest long dispute changes a claim's rate | `CLOSED (v0.12)` |
| A18 | Credential × mill habitat overlap (mech vet R6): raw stood-counting is maximized by cherry-picking trivially-true claims — the credential would compound the mill instead of checking it | Difficulty-weighted record: undisputed stands ≈ 0, contested-and-upheld = full credit; plus cold-start guard and one-active-priority-claim limiter | `CLOSED (v0.12)` |

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
- **The mid-confidence band (reservoir vet F-R5).** Any anti-farm margin
  (rate < y*) prices out stakers whose true edge is below y*/(2·rate). At the
  v0.11 schedule (0.85·y*) that's p < ~0.59: the 55–58% crowd — real signal —
  rationally sits out, a genuine calibration cost of excluding farmers. The
  schedule fix is what let the margin be this thin; thinner still would re-admit
  farmers under drift. Owned, not hidden.
- **Hard emission answers.** Dilution is a real cost borne by all holders;
  the budget makes it bounded and legible, not free.

## 7. Regulatory rationale (see REGULATIONS.md for the full DD)

### 7.1 What V2 changes, per axis (rewritten v0.11 per the legal vet — every
sentence now survives its overclaim scan)

- **Gambling (state law)**: loser-pays-winner is gone from staking, and — after
  the v0.11 bond rule — from the bond machine too: **no value moves between
  adversaries on any outcome, anywhere** (forfeitures burn; compensation
  mints). The LEAD argument is textual, not consideration: nothing is *staked
  or risked upon the outcome* (e.g., N.Y. Penal Law §225.00(2)) — a staker's
  principal returns unconditionally; the contingency is upside-only. Do NOT
  lean on "no consideration": the prize-linked-savings history shows returnable
  principal routinely IS consideration (the American Savings Promotion Act had
  to statutorily carve out raffles whose "sole consideration" was a returnable
  deposit). Kent v. PoolTogether (E.D.N.Y. 2023) de-fangs *private* suits (a
  no-loss participant has no injury) but is standing-only — state AGs need no
  injury. Residual theories: prize-via-dilution (diffuse, untested) and
  purchase-gated eligibility in broad-consideration / any-chance states —
  geofence lever if counsel advises.
- **CFTC**: after v0.11, no bilateral payment contingent on an event remains —
  the only outcome-contingent flows are one-sided protocol issuance
  (structurally akin to protocol-staking rewards) and burns (nobody's gain).
  "Delivery" of minted CC is still *colorably* within §1a(47)(A)(ii)'s words
  (the 3d Cir. read the clause broadly in Flaherty), but the defense is
  structural: no party takes the other side, no one's obligation is
  contingent, nothing is exchanged. One wrinkle to keep visible: the
  "excluded commodity" definition wants an occurrence *beyond the control of
  the parties*, and V2's trigger is the participants' own vote — cuts both
  ways. Gray, accepted; re-read the pending 2026 rulemakings at final.
- **Securities**: the pressure concentrated HERE, knowingly — the accepted
  risk. Precisely stated: rewards require *taking a position and being right*
  (or doing compensated work); they scale with locked capital-time, which is
  capped per person and never framed as yield. CC is **non-redeemable
  in-protocol but transferable** (say it exactly this way — "non-cashable" was
  an overclaim; OTC exit exists and is the profit-realization path a
  hypothetical SEC case would build on). The burn strengthens Buy's
  consumption story doubly: no pooling (nothing for anyone's efforts to
  deploy — the SG Ltd. flip cannot happen) and no redemption. Cheapest
  hardening, adopted: no APR/return language anywhere public, "step-down" not
  "halving", "accuracy rewards" not multipliers, slices = compensation for
  services. The one severable design lever left on the table: time-vesting
  transfers of *reward-earned* CC only (purchased CC stays liquid) — §8.10.
- **Ooki / voter liability**: no vote directs GNOT or any treasury — votes
  only select among formulaic, pre-committed CC outcomes (verdict, tier, bond
  disposition), and after v0.11 none of those outcomes transfers value between
  parties. Remaining exposure: voters collectively operate a system that mints
  transferable value. Mitigation: the DUNA wrapper (§7.3) with its
  express compensation-for-voting authorization.

### 7.2 Explicitly accepted gray areas (owner sign-off)
1. Inflation-funded winner rewards could be recharacterized as a common-pool prize
   (form-over-substance risk consciously taken).
2. Forfeitable answer/dispute/flag bonds and the low-tier deposit slash (§3.6,
   §3.4) — all forfeitures BURN (v0.11), so no adversary is ever paid by a
   loser, but conduct-priced loss on a vote outcome remains.
3. CC transferability stays ON (OTC secondary value → Howey profit-expectation
   pressure) — product choice; the off switch is noted as the single biggest
   securities lever if ever needed; the severable middle option (vesting on
   reward-earned CC only) is §8.10.
4. Emission rewards are pro-rata-variable under reservoir scarcity — weaker on
   *Humphrey*'s "amounts certain" factor than a fixed-prize design (legal vet).
   Compensating controls: the fixed published rate (a *rate* is more
   amount-certain than a contested pool share — the reservoir swap actively
   helped here), the per-person caps, and scarcity-scaling being availability,
   not competition.
5. Prevailing-party bond compensation and the flag bounty depend on reservoir
   availability (scaled under exhaustion) — a winner can be made *mostly*
   whole in a busy stretch (v0.11 cost).
6. A small bounded prize now rides low-median capture (the flag bounty) and
   carrot-only voting mildly subsidizes P+ε coordination — both registered,
   both bounded by caps and the ratchet.

### 7.3 Structural mitigations to build/do
- **Entity wrapper**: form a **Wyoming DUNA** (2024 act, verified from the
  enrolled statute by the legal vet) around governance — separate legal entity,
  member-liability shield aimed at exactly the Ooki theory (§107/§109), DLT
  governance and DLT-ascertained membership expressly contemplated
  (§121–122, §102), **and "reasonable compensation for services rendered,
  including voting or participation" expressly permitted** (§104(c)(i)) — our
  emission slices are drafted in that category's own words. Limits to plan
  around: **≥100 members** (auto-conversion below — launch cohort may not
  clear it; sequence formation accordingly); membership-consent mechanics must
  be defined (voting = consent by conduct, or an opt-in registry — don't
  conscript every CC holder silently); the shield is state-law and **untested
  against federal enforcement** (§118(b) preserves other law), and it creates
  a servable US defendant — that's the point, not immunity; tax treatment
  unresolved (counsel).
- Deployer/ops separation; no admin keys (already true: frozen params).
- Optional geofence list for "any-chance"/"material-element" states if counsel
  advises at launch.

### 7.4 Comms hygiene (Munchee lesson: marketing makes the security)
Never describe CC as an investment, never quote APR/returns in marketing, never
promise appreciation; describe emission as *participation rewards*; the public
docs lead with the verdict/record product, not the token.

### 7.5 Counsel checkpoints
Pre-launch opinion on: the no-loss+emission structure (gambling/CFTC), CC under
Howey with emission, DUNA fit + formation sequencing (100-member floor, consent
mechanics, tax), the **MSB / seller-of-own-convertible-token characterization
of one-way curve sales** (v0.11), and the reward-CC transfer-vesting option
(§8.10). Re-check at final: the 2026 CFTC "Prediction Markets" rule AND the
**event-contract data-reporting NPRM (proposed 7/1/2026)** the original DD
missed.

### 7.6 Post-launch mechanisms — RECONCILED at v0.11
The legal vet read the evolving plan and its findings covered these; outcomes:
- **Quality-flag bond** → same conduct-bond bucket; now burns like all
  forfeitures; flag bounty mints (no bilateral flow).
- **20% decided-vote bond burn** → SUPERSEDED by the 100% rule ("forfeitures
  burn; compensation mints"), which the legal vet's bond finding demanded and
  the econ vet's self-dispute finding independently supported.
- **Burned claim fee** → confirmed helpful (*Humphrey* factor 1); note the
  vet's precision: Humphrey factor 2 is "amounts certain and guaranteed", not
  merely "not funded by entries" — see register item 4.
- **Track-record answer priority** → no legal exposure noted.
- **Reservoir rate** → confirmed the friendlier frame (a published rate reads
  closer to protocol-staking rewards AND scores better on "amounts certain"
  than a contested pool), with the F-R1 schedule fix adopted.

## 8. Open questions / vet queue

1. ~~A1/A2 economics~~ — RESOLVED (F5): profitability condition `y > y* =
   2(r+d)·T_L/T_c`; the fixed reservoir rate sits below y*, so farming never
   enters; netting deleted as theater.
2. ~~A6 smoother~~ — RESOLVED (F8): nothing; linear is the unique
   splitting-neutral rule.
3. ~~Undisputed default-mid~~ — RESOLVED (F1): farmable and CRITICAL as it
   stood; closed by the mandatory quality-flag lane + author/answerer slice
   caps.
3b. ~~Reservoir-vs-pro-rata follow-up vet~~ — LANDED: **KEEP RESERVOIR** with
   mandatory tweaks, all adopted v0.11 (rate schedule A14; participant-gated
   Finalize A13; paid flagging via deposit-slash-burn + minted bounty A15;
   prose corrections F-R6/F-R4; the p-exclusion owned in §6). The
   accrual-interval queue is the recorded upgrade path if scarcity turns
   chronic anyway.
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

8. ~~minAnswerX re-derivation~~ — RESOLVED (v0.13, provisional pending round-2
   vet): **minAnswerX = 100 CC** of trailing total stake. The three-way sizing:
   (a) *answerability floor* — 100 CC of sustained third-party interest is a
   real bar for a thin honest claim but not a wall (one interested staker
   clears it); (b) *bond base* — the minimum answer bond becomes 50 CC, large
   enough that a wrong answer at minimum scale risks 50× the claim fee; (c)
   *mill floor* — a minimum-scale mill must self-stake ≥100 CC for ≥ the
   trailing window to even answer, making its maximum 12-week draw (~10 CC at
   the schedule rate) comparable to its at-risk deposit + fee + flag exposure —
   thin mills are noise, not profit. The minimum flag bond at this scale is
   2 CC (2%·X̄), consistent with spam-pricing. All three constants move
   together or the deploy invariants complain (§3.6 coupling).
9. **v0.8 answerer-cap refinement** (bond-based, not stake-based — §3.5) rides
   the next vet round alongside 8.
10. **Severable securities lever (legal vet #2)**: time-vest transfers of
   *reward-earned* CC only (in-protocol use immediate; transferable after N
   months or one full participation cycle). Purchased CC stays liquid, so
   Buy's consumption story is untouched. The single highest-leverage
   securities hardening short of the full transferability off-switch. OPEN —
   owner's product call; default OFF at launch.
## 10. Implementation & verification plan

- **No migration problem exists**: V1 never launched; V2 is the launch target.
  V1 stays fully audited in git history (branch `court-realm`, base `5d2c4ef`).
- **Build order (refreshed v0.13 for the v0.10–v0.12 mechanics)** — all /p/
  packages untouched except deleting the court's dependency on
  tickbook/cshares: (1) `stake.gno` (pools, conviction-128, freeze atomicity)
  + `emission.gno` (reservoir accrual, the deploy-frozen rate SCHEDULE,
  `rateAtFreeze`, entitlements, pull-claims, participant-gated Finalize);
  (2) adapt `claim/answer/session/dispute` per Appendix A (+ the conditional
  fee escrow, the burn sink, bond-comp-as-mint); (3) `quality.gno` (3-bucket
  sealed median + the FLAG state machine: open-window guard, conclusive-vs-
  inconclusive slot rule, doubling re-flag bonds, settlement pause);
  (4) `records.gno` (difficulty-weighted answer records, priority gate with
  cold-start + one-active limiter); (5) render (three ratio series, no
  "backing"); (6) delete `book/market/fees`.
- **Net size**: roughly –570 LOC removed vs ~+600 new (the flag machine and
  records added ~150 over the v0.4 estimate) — still ≈ V1's size, with all
  hard machinery (governor, grc20votes, twap, curve, checked math) reused
  untouched.
- **New deploy/test invariants accumulated through v0.12** (each gets a
  mustSane-style check or a dedicated test): `curveCap + Σemission ≤
  MaxInt64/Bps`; conviction fits int64 in stake-hours; per-claim Σg clamped
  (never abort); `answerBondBps ≥ maxUndisputedTier/2`; Σminted ≤ Σaccrued;
  rateAtFreeze immutable per claim; the flag-slot state machine (open →
  flagged → conclusive|inconclusive-reopen) never double-pauses or
  double-pays; forfeitures strictly burn (no transfer path exists to an
  adversary); escrow conservation with the conditional fee (refund XOR burn,
  exactly once).
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

## 11. Product surface — the V1 wireframe under V2 (v0.14)

The V1 web overlay (10 screens, previously reconciled to V1 code) changes
shape: the order book is gone, so the trading screens become staking screens.
Delta map for whoever revises `web/index.html`:

| V1 screen | V2 change |
|---|---|
| Directory / a court | Keep; **delete the backing stat** (§3.8 pass-2); curve price + supply + total staked |
| Claim + market (order book, best bid/ask) | **Becomes the stake panel**: YES/NO pools, three ratio series (§3.9), stake/unstake, conviction preview ("your stake × time so far") |
| Order ticket (RestBid/Take) | **Deleted** — replaced by a two-button stake ticket with the freeze warning ("staking locks at the answer") |
| Answer flow | Keep bond math display; add the 24h priority-window badge and the answerer's difficulty-weighted record |
| Dispute / vote | Keep sealed-tally rules; add the quality question (low/mid/high) and the ⅔-for-high note |
| NEW: flag control | One button + bond quote on every answered-unsettled claim; shows the 24h flag-open window countdown and slot state (open / pending vote / consumed / reopened) |
| Your page | Positions become stakes + accrued conviction + pull-claims (accuracy rewards, comps, bounty); show the record (stood-contested / overturned) |
| Chain render | The claim page is the product (§3.9); every figure reproducible from public reads |

UX copy rules carried from §7.4: no APR/return language, "accuracy rewards"
not multipliers, "step-down" not halving, never "backing"/"redeem"/"cash out".

## 12. Owner decision index (v0.15)

Every judgment call the loop made autonomously, consolidated for override.
"Override cost" = what changes if you reverse it.

| # | Decision | My call & where argued | Override cost |
|---|---|---|---|
| 1 | GNOT: burn vs work-pool | **Burn** (§3.7) — capture honeypot, Ooki, AML/tax | Rebuild pool + entity + payment compliance; re-arms three legal hooks |
| 2 | Emission model | **Reservoir drip** over pro-rata (§3.3, vetted KEEP) | Pro-rata + F11 fix works but pays farmers to equilibrium and re-couples payouts |
| 3 | Rate | **Frozen schedule 0.85·y*(n)** (§3.3) | Scalar self-defeats by schedule (A14); richer rate re-admits farming; leaner excludes more honest mid-p |
| 4 | Voting discipline | **Carrot-only, no slashing** (§3.5, your lean) | Slashing hardens against large-value bribery; costs honest-minority chill |
| 5 | CC transferability | **ON**; reward-vesting lever OFF (§7.2, §8.10) | Vesting = the cheapest big securities cut; OFF-entirely kills OTC + product |
| 6 | Bonds | **Forfeitable; burn-not-transfer** (§3.6) | Time-lock-only invites answer-slot squatting DoS |
| 7 | Undisputed quality default | **Mid + flag lane** (§3.4) | Low punishes the healthy path; high is free money |
| 8 | Tier gates | **Median mid↔low; ⅔+bar for high** (§3.4) | Symmetric median is whale-capturable at ~29% turnout |
| 9 | Split 80/8/7/5 | Reasoned-provisional (§3.5; rationale in ECONOMICS.md v0.19: winners must dominate; author capped by claim-spam pressure; voter slice deliberately token-sized; every answerer point is a mill point) | Retune freely within the ordering + caps; crossing either re-opens A15/F2 and needs a fresh vet |
| 10 | Claim fee | **10%, conditional refund** (§3.8) | Always-burn is regressive on honest thin claims; no-fee removes CC's only sink |
| 11 | Answer priority | **ON, difficulty-weighted, cold-start-gated** (§3.8) | OFF = pure first-come answers; naive counting re-aligns with the mill (A18) |
| 12 | Court topology | **Per-court coins** (§3.8 pass 2) | Shared coin pools liquidity but couples every court's legal+economic fate |
| 13 | minAnswerX | **100 CC** (§8.8) | Lower invites micro-mills; higher walls off the honest long tail |
| 14 | provClose payout | **1× everyone, no price** (§3.1) | Any price-based close re-opens the V1 O5 manipulation surface |
| 15 | Entity | **Wyoming DUNA recommended** (§7.3) | Alternatives: DAO LLC (profit OK, weaker fit), Cayman/RMI (offshore optics); none = Ooki exposure stays raw |
| 16 | Verdict form | **Binary, sealed** (§3.8 pass 1) | Probability verdicts hand adjudicators a nudgeable knob |
| 17 | Emission cadence | Weekly period, R_max = 4B, step-down every 104 (§3.3/§4) | Cosmetic within bounds; total-emission invariant must re-check |
| 18 | Round-2 fixes | Slot-reopen, 24h flag-open, rateAtFreeze, participant Finalize (v0.12) | Each reverts to a named, vetted attack (A13, A16, A17) |

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
| `render.gno` | ADAPT. Sparkline = stake-ratio series; drop BestBid/BestAsk; show tier, route, emission drawn. Sealed-tally rule extends to the quality tally. **Delete "backing" everywhere** (pass-2 catch): burned GNOT backs nothing; rendering a backing figure would imply a redemption value that does not exist. Curve price + supply only. |
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

## 13. Changelog

Newest first.

- **v0.19** — (iteration 16) the 80/8/7/5 split upgraded from "provisional" to
  **reasoned-provisional**: tuning rationale added to ECONOMICS.md (winners
  must dominate or staking becomes a side-show; author bounded 5–10% by
  thin-claim viability vs claim-spam pressure; the voter slice is deliberately
  token-sized — a primary-income carrot would recreate F2/F3; every answerer
  point is a mill point, so it stays smallest). Decision-index row 9 updated
  with the retune boundary (ordering + caps free; rule changes re-vet).
- **v0.18** — (iterations 14–15, process note) the monolithic round-2 holistic
  vet ran ~4× longer than any prior vet with no output despite a nudge —
  treated as lost and SUPERSEDED by two tight splits now running: **2A**
  (mechanism fixes under attack: burn-comp dispute EV incl. scarcity-window
  lying, flag-reopen chains incl. the per-claim-vs-per-flagger doubling-base
  pin, rateAtFreeze boundary games) and **2B** (full stale-text/consistency
  checklist — Appendix B is known-stale — plus the ten-role incentive audit).
  If the original ever reports, it becomes confirmation. Also v0.17.5: README
  status pointer to the design set.
- **v0.17** — (iteration 13) created **ECONOMICS.md**, the private calibration
  memo §3.3 referenced but which didn't exist: symbols, the y*/p_min results,
  the deploy-computable d(n) ceiling path that makes the rate schedule
  possible (and shows why a scalar self-defeats), reference launch numbers,
  the actor-margin table (farmer negative, p=0.59 break-even, p=0.7 ≈
  +0.10%/wk, mill negative at q ≥ 0.2), and B/R_max sizing. Marked INTERNAL
  per §7.4 — none of its rates may appear in public copy.
- **v0.16** — (iteration 12) brainstorm pass 3: **edges (support/counter) stay
  out of the V2 money loop, on the record with a tripwire** — value-coupled
  edges would open cascade draws, support rings, and a graph-shaped cross-claim
  denominator no vet has examined; they ship V3 as zero-weight curation
  metadata. Rejected sortition panels (cheap bribery + hard determinism-safe
  randomness vs battle-tested full-electorate quorum). Kept 1-D quality (each
  extra axis is a new A4). Noted: courts die clean — no treasury exists to
  fight over, a direct dividend of the burn. Notably, pass 3 produced zero
  design changes — convergence evidence.
- **v0.15** — (iteration 11, round-2 vet pending) §12 owner decision index: all
  18 autonomous judgment calls consolidated with override costs. Corrected the
  dead-claim wording (nothing is locked pre-answer; the timeout disposes only
  deposit+fee). Pinned the rate schedule as ONE realm-level table from the
  ceiling-supply path (per-court live-supply schedules would be manipulable),
  and closed the young-court dilution worry it raised: draws are conviction-
  based, so **no court can be diluted faster than its own participation earns**
  (d ≤ rate × staked-fraction, any court size; B caps throughput, never forces
  emission).
- **v0.14** — (iteration 10, round-2 vet pending) added §1a "the design at a
  glance" (ten invariant bullets — the doc's top now reflects the v0.13 shape
  without reading the changelog) and §11 product-surface delta map (the V1
  wireframe under V2: order-book screens become the stake panel, the new flag
  control, record badges, pull-claims; UX copy rules consolidated).
- **v0.13** — (iteration 9, round-2 vet pending) resolved §8.8: **minAnswerX =
  100 CC** with the three-way sizing (answerability floor / bond base 50 CC /
  mill floor making thin mills noise). Refreshed §10 for the v0.10–v0.12
  mechanics (flag state machine, records.gno, rateAtFreeze, burn sink,
  conditional fee; +150 LOC over the v0.4 estimate) and consolidated the nine
  deploy/test invariants accumulated so far. Synced REGULATIONS.md §7's bond
  entry to the burn rule.
- **v0.12** — (iteration 8c) **third vet (new mechanisms) ingested — all three
  verdicts ADOPT-WITH-FIXES, fixes applied.** Launch-blocking flag-lane hole
  closed: the self-flag slot squat (A16 — one burned sybil bond consumed the
  only flag and immunized a mill; the slot now only burns on a CONCLUSIVE
  vote, inconclusive low-turnout mid reopens it, re-flags double) and the
  settle/flag ordering race (A17 — settle now disallowed for the first 24h
  post-answer). Emission `rateAtFreeze` (A17): a flag pause or an honest
  8-week dispute can no longer drag a claim across a rate step-down — also
  fixed an unprompted latent bug (long disputes silently halving winners'
  draws). Credential de-aligned from the mill (A18): difficulty-weighted
  record (undisputed ≈ 0, contested-and-upheld full), cold-start gate,
  one-active-priority-claim limiter. Claim fee made conditionally refundable
  (burn on dead/low, refund on real resolution) — the always-burn was
  regressive against the honest thin-claim long-tail; Humphrey factor-1
  trade-off registered honestly. Confirmed UNPROFITABLE by the vet: credential
  farming, collusive demotion (the fixed linear rate kills the relative-share
  motive — keep linear forever).
- **v0.11** — (iteration 8b) **reservoir vet AND legal vet ingested together —
  the joint fix is the design rule "FORFEITURES BURN; COMPENSATION MINTS."**
  Legal vet found V1's own doc calling bonds "a bet between two people. The
  loser's bond goes to the winner, whole" — the last loser-pays-winner
  bilateral transfer, falsifying §7.1's headline claims on both gambling and
  CFTC axes; the econ vet had independently shown whole-bond transfers make
  self-dispute free. Now every forfeiture (bonds, low-tier deposit slash)
  burns in full and every prevailing-party compensation (answerer-comp,
  disputer-comp, flag bounty) is a capped emission slice — deterrence and
  incentives unchanged, zero adversary-to-adversary flows anywhere.
  Reservoir vet: KEEP with tweaks, all adopted — rate becomes a deploy-frozen
  SCHEDULE at 0.85·y*(n) (a frozen scalar was *scheduled to self-defeat* as d
  decays with halvings — A14); Finalize participant-gated for a grace week
  (zero-draw grief — A13); flagging must be paid (the reservoir deleted
  pro-rata's diffuse flag motive; the author-mill re-armed as in-band
  single-sided p=1 farming — A15); §3.6 prose corrected (the bond invariant is
  a conservative ~5× upper bound; detection threshold ~15%); coupling wording
  fixed (intermittent and bounded, F-R4); the p<0.59 mid-confidence exclusion
  owned in §6 (F-R5). Legal vet's argument hierarchy adopted in §7.1: LEAD
  with "nothing staked or risked UPON THE OUTCOME" (NY §225.00(2)), never
  with "no consideration" (the prize-linked-savings history defeats it —
  returnable deposits WERE consideration, Pub. L. 113-251); Kent v.
  PoolTogether = standing-only; "non-cashable" corrected to "non-redeemable
  in-protocol, transferable"; APR language struck from §3.3 (it violated our
  own §7.4); "monetary meme" struck from §3.7 (Munchee); MSB counsel checkbox;
  DUNA verified from the enrolled act (≥100 members, consent mechanics,
  compensation-for-voting expressly permitted — slices drafted in the
  statute's own words); register items 4–6 added; §8.10 severable
  reward-CC-vesting lever recorded. REGULATIONS.md §9 gains eight dated
  primary-sourced findings + the missed 7/1/2026 data-reporting NPRM.
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
