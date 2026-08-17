# PLAN — cryptocourt tokenomics V2: no-loss conviction staking

> **STATUS: DESIGN CONVERGED at v0.31 — no unvetted mechanism remains.**
> 14 adversarial vet passes; the 22-attack ledger (§5) holds zero DRAFTs and
> every rule in it was attacked, including the fixes (the T-series closed the
> fix-of-fix chain, source-verified against V1's code). Remaining surface:
> accepted-register grief (§7.2), the named V3 frontier (weight-at-risk), and
> owner calls (§12). Next phase: implementation (§10), then the same
> audit-to-convergence cycle on the code.
>
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
share a **bounded, stepped-down emission of new CC**, weighted by how much and how long
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
   reservoir on a stepped-down **rate rule** — the formula is frozen
   (`rate_n = 0.85·y*(n)`), its dilution input is read live from supply each
   period (every manipulation of it is self-costly) — sized so matched-stake
   farming never enters; total emission is finite and invariant-checked
   against the supply ceiling.
4. **Quality gates value**: low 0× / mid 1× / high 2×; high needs ⅔ + full-bar
   turnout; anyone can flag a claim into a quality vote (slot reopens if the
   vote is inconclusive); junk pays no author, answerer, or winner (the policing layer is
   deliberately still paid).
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
| Fees (adjFee/settleFee skimmed from winners) | Core | **Removed** — replaced by emission slices; NEW: 10% claim fee, conditionally refunded (v0.20) |
| "Backing" (treasury/supply stat) | Rendered, marketed | **Deleted** — burned GNOT backs nothing; showing it would imply redemption (§3.8 pass 2) |
| Answer/dispute machine (bonds, doubling, 3 rounds, escrow windows) | Core | **Kept**, with V2 dispositions: dispute-bond cap (F5), forfeitures burn + comp mints (v0.11/v0.20), loser early-exit (F7) |
| Governor + grc20votes (weighted vote, epochs, anti-flash-loan) | Core | **Kept**; + a new 3-bucket quality tally (§3.4) |
| One-way bonding curve (GNOT→CC) | Core | **Kept** (destination now burn) |
| Claim deposit (anti-spam, refundable) | Refund only at Finalize (stranding residual O6) | Refund after dead-claim timeout (O6 fixed); slashed+burned on conclusive LOW (v0.11); +10% conditionally-refundable fee (v0.20) |

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
   (v0.11, §3.3). **v0.20 SPLIT SETTLEMENT (round-2 V2-6): principal release
   is NEVER pausable** once the dispute window lapses — flags pause only
   draw-crystallization. A quality outcome can only move emission, so only
   emission may wait; both pools' principal exits regardless of any flag chain. **Losers may withdraw 1× immediately after any DECIDED
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
   reward, deposit back; the fee REFUNDS (provClose is not a conclusive low)
   and no voter carrot exists (failed rounds produce no verdict to match). No price needed — the V1 O5 manipulation surface is gone.

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
- **v0.20 (round-2 vet V2-7) — d comes from LIVE REALIZED SUPPLY, superseding
  the v0.15 ceiling pin.** The vet caught the ceiling pin's failure mode I
  missed: at 10% of ceiling supply, actual d is 10× the scheduled d, actual y*
  ≈ 3.75%/wk vs a 0.89%/wk rate — honest break-even needs p > 1, i.e. **nobody,
  including perfect stakers, clears cost in the early court**. Fix: each
  period's `d_n = B_n / S_live` (supply read once at the period boundary —
  deterministic on-chain data, not a lever). The v0.15 manipulation worry
  inverts on inspection: *buying* CC lowers everyone's rate including yours
  (self-defeating for a yield-seeker); *burning* your CC raises everyone's rate
  at your sole cost. Every manipulation is self-costly, and the 15% anti-farm
  margin now holds at every supply level and court age, because the rate tracks
  the true y*. (Decision-index row 19; the reversal is flagged for owner
  review.)
- **v0.20 (round-2 vet V2-8) — RATE-WEIGHTED CONVICTION replaces rateAtFreeze.**
  The accumulator integrates `rate(t) × stake × dt` (same storage, same 128-bit
  path) instead of `stake × dt` priced later. `rateAtFreeze` is deleted: there
  is no rate snapshot to race, so answer-timing rushes at step-down cliffs are
  impossible *exactly* (everyone crosses boundaries continuously, pre-freeze),
  and A17's intent survives for free (accrual stops at the freeze, so no pause
  can change anything after it).
- The young-court dilution self-bound survives both changes: draws are
  conviction-based, so minted ≤ rate × staked-fraction × supply per unit time —
  **a court can never be diluted faster than its own participation earns**; B
  caps throughput, never forces emission.
- **v0.20 (round-2 V2-3 + vet-2A T1, which found the same wound deeper) —
  policing pay is a QUEUED SENIOR ENTITLEMENT, never availability-scaled.**
  2A's structural point: a disputer's downside (bond burn) is hard,
  unconditional CC, while under scaling their entire upside was
  reservoir-contingent — at R ≈ 0, honest disputing was negative-EV *even for
  a certain winner*, engineering scarcity was positive-EV honest work, one
  global exhaustion was a court-wide policing holiday, and a liar could wait
  out the window as a grace-week participant. Fix: prevailing-party comps,
  flag bounties, and the flag-vote voter carrot are **reserved at
  verdict/flag-close as intervals on the cumulative-accrual number line and
  paid AHEAD of all §3.5 draws as accrual arrives — full amount, time-delayed
  under scarcity, never reduced.** Winner/author/answerer draws remain
  availability-scaled (they are the demand bulk; conduct comp is rare and
  bond-bounded, so seniority costs the main flow little). This adopts the
  accrual-interval queue §3.3 had recorded as the upgrade path, for the
  conduct layer only. Emission ceiling unchanged — this is ordering, not
  volume.
- **v0.20 (vet-2A T3) — the rate table is geometrically AMORTIZED**: instead of
  a 104-period cliff, each period multiplies by `2^(−1/104)` (≈ −0.66%/period)
  — same finite total, no boundary block to race. Composed with rate-weighted
  conviction (above), there is no rate snapshot anywhere and no cliff in
  rate(t): answer-timing games through the rate side are impossible by
  construction, not by deterrence. (2A verified the era-matching: accrual is
  always paid at the y* prevailing while it accrued, so the F5 band holds
  within every era.)
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
- **Window (corrected v0.20 — round-2 V2-5 caught v0.12's rule as VACUOUS)**:
  flags are allowed from the answer until the settle tx lands. The v0.12
  "no settle for 24h post-answer" added nothing (the retained 72h delay
  already forbids settle far past 24h). The rule that does real work is
  **reopen-relative**: settle is disallowed for **24h after every flag-vote
  close or slot reopen** — otherwise a re-flag must win a 1-block priority
  race against a settle bot at each vote close. A flag **pauses
  draw-crystallization** until its vote closes — but see §3.1: principal
  release is NEVER pausable (v0.20 split settlement); a flag can only delay
  emission, which is all a quality outcome can affect (the F6 insight,
  finally applied to its own machinery).
- **The flag slot is consumed only by a CONCLUSIVE vote** (v0.12, mech vet R1 —
  this was a launch-blocking hole): an outcome of mid with turnout **below**
  the ¼-bar floor is *inconclusive* and REOPENS the slot. Otherwise the mill's
  own sybil flags instantly at answer+1 with a dust vote destined for
  low-turnout mid — burning one small bond to consume the only flag and immunize
  the claim; the turnout floor added against dust-griefers would have protected
  exactly the wrong party. Three v0.20 pins (2A T2 + round-2 V2-6):
  **the doubling base is the SLOT — per-claim, monotone across flaggers**
  (per-flagger bases reset via sybils → linear-cost suppression chains; per-slot
  makes cycle k cost 2^(k−1)·b₀, exponentially self-limiting at ~2–4 cycles);
  **v0.24 (micro-vet-2 CONFIRMED the v0.23 self-finding and refined the fix)**:
  the K = 3 terminate-as-mid cap was a guaranteed mill immunization (3 dust
  self-flags = **7%·X̄** burned — v0.23's 3.5% figure conflated 3.5·b₀ with
  3.5% — + 21 days → permanent mid; EV-positive insurance for any mill with
  q ≳ 0.75). But v0.23's bare deletion had its own tail-failure: unbounded
  doubling re-immunizes by capital exhaustion around cycle 5 (a 32%·X̄ entry
  price kills honest flaggability as surely as a terminal state). Final rule:
  **after 3 inconclusive cycles the reopen chain ends but flaggability never
  does — the bond FREEZES at 2²·b₀ = 8%·X̄** (full-burn-unless-low, bounty =
  bond, one flag per 7-day cooldown, no further doubling). Nothing is ever
  immune; a mill's Route-B spend buys only a raised entry price; grief-delay
  costs a flat ~4%·X̄/week against ~0.06%·X̄/week of victim time-value
  (~120:1, X̄-invariant). Companion deploy invariant (micro-vet-2 item 2):
  **the flag-vote carrot per vote < b₀/2**, so idle sybils voting mid to farm
  the carrot net strictly negative (current margin ~2.2×);
  **an inconclusive outcome burns half the bond and returns half** (full return
  would make chains free — 2A; full burn punishes honest flaggers for the
  electorate's absenteeism — round-2 V2-1; half preserves the exponential
  chain cost while capping an honest flagger's turnout-failure loss at b₀/2);
  and **staked CC does not vote on quality** — staked CC sits at the escrow
  address, and V1's quorum design already nets escrow out of votable weight.
  This resolves the two vets' direct conflict the right way: the mill cannot
  vote its working capital toward a conclusive-mid self-immunization, and
  honest claims are defended not by their (disenfranchised-while-staked)
  stakers but by the now-PAID outside electorate (below).
- **v0.20 supersedes `rateAtFreeze` entirely**: conviction is **rate-weighted**
  (the accumulator integrates `rate(t)·stake·dt` — round-2 V2-8) over a
  **geometrically amortized** rate table (2A T3: `×2^(−1/104)` per period, no
  cliffs exist). Both v0.12 concerns are solved at the root: no pause or long
  dispute can reprice accrued conviction (it was priced as it accrued), and no
  boundary block exists to race — v0.12's snapshot had itself created a
  rush-to-freeze at each cliff (a one-block choice repricing the whole banked
  integral by ~2×, which 2A showed even rewards a *sacrificial wrong answer*
  to lock the rate).
- **Bond**: `max(flagMin, 2%·X̄)`, escrowed. Returned iff the outcome is
  **low**; burned otherwise — including when the electorate promotes to high
  (flag risk cuts both ways; a bad flag against a genuinely good claim pays for
  the delay it caused).
- **Vote**: the same court-local 3-bucket tally as the dispute-ride version;
  window = `votingBlocks` (7d); sealed until close; one vote per address,
  weight = `PastVotes`. **v0.23 snapshot pin: the quality-vote epoch is the
  last sealed epoch at the ANSWER height — one fixed epoch per claim, set
  before any flag can exist.** A flag-height snapshot would let the flagger
  shop epochs (time the flag to when the defender cohort's checkpointed
  weight is lowest), and the escrow-disenfranchisement would wobble (a
  staker's PastVotes at an epoch before they staked still shows the
  pre-stake balance). Anchoring at the answer height makes the electorate
  identical for every quality vote a claim ever has, seals it before the
  adversarial game starts, and keeps the rule: capital staked (at escrow) by
  the answer epoch cannot vote on its own payout multiplier; unstaked
  holdings can. (Pending micro-vet-3 confirmation.)
- **Outcome rules (consistent with the F3 ratchet)**: median decides low vs
  mid; **demotion to low additionally requires turnout ≥ ¼ of the claim's
  verdict bar** — a lone griefer with dust turnout cannot zero an honest
  claim's emission; **promotion to high keeps its own gate** (≥⅔ of turnout
  AND turnout ≥ the full verdict bar).
- **Incentive geometry (v0.7 text, SUPERSEDED)**: the "dilution-payers will
  police for free" argument below was pro-rata-era reasoning — F-R2 rejected
  it for flaggers and F-H4 for flag-voters (diffuse dilution motivates
  nobody). Kept struck-through in spirit as the record of why the policing
  layer is now PAID (bounty + carrot, senior-queued), not volunteered.
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
  paid a minted bounty. **v0.20 repricing (round-2 V2-1, CRITICAL — the v0.11
  arithmetic did not close):** a bounty of ≈ deposit/2 was ~10³× smaller than
  the flagger's risked bond (the 2%·X̄ bond scales with the claim; the deposit
  doesn't), so break-even needed q ≈ 99.96% — nobody polices at that price,
  and the "q ≈ 0.2 kill threshold" did not follow from any stated parameter
  (retracted). Repriced: **the bounty equals the flagger's own bond**, minted
  on a conclusive low and senior-queued (§3.3) → flagging is positive-EV at
  q > ½, a sane policing bar that scales with claim size. And F2's own logic
  finally reaches the flag-vote **voters**: standalone quality votes pay the
  tier-invariant participation carrot, senior-queued — conclusive turnout no
  longer depends on unpaid volunteers. The v0.7 worry (paid flagging = F2 in
  miniature) stays bounded: the bounty pays only on a conclusive low over the
  ¼-bar floor; a wrong flag still burns half (inconclusive) to all
  (conclusive mid/high) of an exponentially-doubling bond. Register note: the
  capture-prize on low-median against honest claims grows with the bounty —
  still far below the ¼-bar capture cost, principal untouched, ratchet caps
  the radius; and the honest mill-deterrence statement is now: mill EV goes
  negative at a modest flag probability the repriced lane economically
  supplies, with the deposit as the sizing lever if margins need more.
- **v0.25 — THE BOUNTY FAUCET (round-3 R3-1d + micro-vet-1 #4, independently:
  BREAKS).** Bounty = own bond was the one mint unbounded by its event's burn:
  a low outcome burned only deposit+fee (~1.1 CC, fixed) while minting 2%·X̄ —
  and X̄ is pumpable with REFUNDABLE stake. A sybil author+staker+flagger farm
  on deliberately-junk claims minted 2%·X̄ per cycle against ~1 CC of burn,
  with the honest electorate voting low *truthfully* as the trigger; at scale
  the senior-queued mints capture the head of the emission queue — recreating
  engineered scarcity from inside the 2A-T1 fix. Convergent fix, both vets:
  **the per-event invariant the comp rule already obeys, applied to the
  bounty — `bounty = min(flagger's bond, 80% × CC burned on the low outcome)`
  — plus a low-outcome burn that SCALES: conclusive low slashes 2.5%·X̄ from
  the ANSWER BOND** (answering junk is conduct — the §3.6 doctrine; 5% of the
  bond, mild for a real mistake, and it makes answerers the quality
  gatekeepers of the slot they occupy). Now bounty = 2%·X̄ ≤ 0.8 × 2.5%·X̄:
  V2-1's scaling preserved, q > ½ preserved at every ratchet level (burn base
  doubles alongside via cumulative slot half-burns), and every sybil
  arrangement is strictly negative — the junk-farm pair nets −0.5%·X̄ − 1.1 CC.
- **v0.25 — the idle-reserve squat (round-3 R3-2: "the squat is NOT dead").**
  A mill holding ¼-bar of UNSTAKED reserve could self-flag and self-vote a
  conclusive mid — consuming the slot permanently for +7%·X̄ if the one sealed
  vote wins, nearly free to try. Fixes: **a slot-consuming mid requires the
  FULL verdict bar** (symmetric with high's gate); a ¼-bar mid denies the
  demotion but the slot REOPENS at ×2 — immunity now costs bar-scale idle
  capital contested by paid outsiders. And the bounty fix above makes a failed
  squat genuinely negative.
- **v0.25 — the small-claim dead zone (round-3 R3-3b).** Below the 5%-supply
  quorum floor the demotion bar was fixed while the carrot scaled with X̄ —
  pay-per-weight collapsed to dust and nobody would police small claims,
  exactly where mills are viable from X̄ ≈ 12× deposit. Fix: the QUALITY
  ¼-bar drops the supply floor — `min(X̄, ⅓·votable)/4` — so required turnout
  scales with the claim exactly as the carrot does (uniform ≈2.5%
  pay-per-weight at every size). Verdict votes keep the full quorumFloor.
- **v0.26 (micro-vet-3): PARTICIPANT EXCLUSION** — a claim's participants
  (addresses staked at the freeze, the author, the answerer) neither vote nor
  earn the carrot in that claim's OWN quality lane, by rule rather than by the
  accident of escrow balances. Closes two gaps the answer-height snapshot
  alone leaves open: same-epoch enfranchisement (stake+answer inside one
  epoch → the sealed E−1 snapshot shows pre-stake balances → the mill's
  working capital votes) and post-release re-enfranchisement (split
  settlement returns principal while the flag window can still run). Sybil
  caveat, recorded honestly: exclusion is per-address and a mill can route an
  idle reserve through a non-participant wallet — the FULL-BAR gate on
  slot-consuming mid (v0.25/A20) remains the load-bearing defense; exclusion
  removes the cheap in-band paths and the carrot self-payment.
- **v0.28 — A21 FINAL (two composition vets, reconciled — each corrected the
  other).** Vet A rejected my supermajority draft but its mill arithmetic
  dropped the carry term on the flagged branch (a flagged mill still pays
  carry on ~1.5X̄ locked at zero yield); vet B restored it: **a median-low
  tier-0 kills the mill at flag-frequency q ≈ 12%, X̄-invariant** — my
  pre-analysis P1 was right via B's sharper mechanism, and the slash is
  police-FUNDING, never mill-killing. Vet B then showed the deeper truth that
  invalidates every reachable-bar slash design (mine AND vet A's
  undisputed-gate): **quality-vote weight is costless, reusable, and never
  escrowed by voting** — one weight pool services unlimited concurrent
  captures, so ANY claim-scaled bar that triggers an X̄-scaled slash+bounty
  is a faucet against innocent answerers (~3.4:1, parallelizable). Final
  rule, combining both vets' surviving pieces:
  - **Median-low (bar = min(X̄, ⅓·votable)/4)**: tier 0, deposit + fee
    burned, bounty ≤ 80% × (deposit+fee) ≈ dust. This ALONE kills mills at
    q ≈ 12% — reachable even from altruistic/competitor flagging.
  - **The answer-bond slash + full bounty fire ONLY at the supply-floored
    full verdict bar AND only on undisputed answers** (vet A's evidence-gate
    kept as belt: dispute-survived bonds are adjudicated-once and immune;
    A22's dispute-ride pin stands). Below whale scale this branch is simply
    OFF — a **bounded, accepted dead zone**: small-claim mills earn a thin
    ~0.2(r+d)·X̄ reservoir-capped spread, priced 1.1 CC + full carry per
    cycle, dead at 12% flag frequency.
  - **Upgrade path registered (vet B)**: escrow the slash one window and let
    the slashed answerer counter-flag at 2×b₀, forcing a re-vote at the
    supply-floored bar — makes small-claim slashes reachable later without
    ever freeing the faucet.
  - **v0.29 refinements (third composition report — validates the v0.28 gate,
    fixes its two soft spots):**
    **T1 — cheap-when-right flags**: an inconclusive-LOW (median low, turnout
    under ¼-bar) returns the FULL bond — no bounty, no mint, slot reopens,
    cooldown holds; the half-burn applies only to inconclusive MID/HIGH.
    Obvious-junk flags become ~free-when-right, so flag frequency → 1 in the
    mill band and tier-0 + deposit does the killing — robust to all three
    vets' divergent mill-margin estimates (kill thresholds 12%/48%/74%
    bracketed the truth; T1 makes it moot). No faucet possible: a bond
    return is not income. (Grief-pricing micro-pass running — the one check
    the third report requested.)
    **T2 FINAL (v0.31, its own micro-pass, source-verified against V1's
    checkpoints)**: at FULL-BAR turnout that fails ⅔, the flagger's bond
    burns HALF (kills the free-roll's downside floor). The v0.29 weight
    TIME-LOCK is **dropped as unimplementable** — an address-lock dies to
    one transfer (PastVotes re-enfranchises the recipient wallet at the next
    sealed epoch), and a balance-freeze would break the "grc20votes stays
    unchanged" pin while benching the paid police for weeks. The flat-8%·X̄
    entry alternative was REJECTED for re-creating V2-1 against honest
    flaggers (a CORRECT flag landing median-low would burn 2× its prize).
    The real price is the v0.28-registered **counter-flag window, now
    armed**: the slash + full bounty ESCROW for one challenge window; the
    slashed answerer may counter-flag at 2×b₀, forcing ONE re-vote at the
    supply-floored bar, outcome final; an inconclusive re-vote leaves the
    slash standing (the answerer's own mobilization is the re-vote's
    turnout engine — if even that misses the bar, the original full-bar low
    was sound). A capture-whale must now win ⅔ TWICE, the second against
    maximal mobilization (p² ≈ 0); a real mill won't pay 4%·X̄ to re-lose.
    Registered residual (A4-class): parallel reuse of one un-locked weight
    pool across concurrent flagship claims — priced by per-claim bond risk,
    the public alarm each 2%·X̄ posting raises, and the double-⅔ gauntlet.
    **T3 pin**: the dispute-ride quality vote inherits verdict quorum; the ⅔
    arm is checked on the QUALITY tally; no bounty exists on that path
    (no flag bond exists there — nothing to scale it from).
  - **Root cause, named for V3 (all three composition reports converge)**:
    A4→A20→A21 were one hole re-expressed — costless reusable voting weight
    triggering scaled value flows. It closes only by putting the triggering
    WEIGHT at risk (vote-bond escalation / appeals), which conflicts with
    carrot-only voting (decision #4, owner's lean) and is explicitly out of
    V2 scope. V2's containment: scaled flows are whale-priced or
    evidence-gated; unreachable-bar flows are dust-priced.
- **v0.25 pins**: no voter carrot on INCONCLUSIVE outcomes (else ratchet-spam
  gets ~3× cheaper and a carrot upsizing could flip it — micro-vet-2's
  carrot < b₀/2 invariant stays as belt); the "honest loss capped at b₀/2"
  claim holds only for the first slot cycle — at ratcheted levels the
  load-bearing property is that risk and reward double TOGETHER, keeping the
  q > ½ bar at every depth; the ANSWERER picks the quality epoch (they time
  the answer) — bounded, public before any vote, registered.
- **Tier ratchet is asymmetric (econ vet F3)**: the median can only move
  **mid ↔ low**; **high requires ≥ ⅔ of turnout AND turnout ≥ the claim's
  verdict bar**. A whale with ~29% of a thin turnout could capture a median;
  demoting junk stays cheap, promoting to double-draw is expensive and
  quorum-gated.
- Tier multipliers: **low = 0×, mid = 1×, high = 2×**. Low zeroes every
  TIER-SCALED slice (winner/author/answerer; the senior-queued policing layer
  is deliberately tier-invariant — §3.5) — junk is pure cost (deposit + lock + dilution) for all involved.
- **Implementation shape** (from the §Appendix A sweep): quality does NOT touch
  `/p/governor`. It is a court-local 3-bucket tally: `VoteQuality(claimID,
  bucket)` weighs the voter by `PastVotes` at the claim's **answer-height
  epoch — one fixed quality electorate per claim on BOTH paths** (v0.23
  extension: a disputer picks dispute timing exactly as a flagger picks flag
  timing, so the epoch-shopping attack applies to dispute-ride quality votes
  too; the verdict tally keeps the governor's own propose-time snapshot — two
  weight lookups on one ballot, each rule serving its own threat model);
  state is three weight counters + a voter→(bucket,weight) record (double-vote
  guard, and the record the voter carrot pays from); the median is computed at
  close and never rendered before it (sealed, like the verdict tally). No new
  governor lane, no /p/ change.

### 3.5 Reward split — `VETTED ×2 (econ F1/F2/F8, legal #4); code-vs-prose note v0.39`

> **v0.39 correction (econ-vet P7):** the prose below sizes `D = Σg·93/80` so a
> winner receives the full mid-weight gross with author/answerer added on top.
> The CODE does NOT do this — `crystallize.gno` sets `D = tier·midGross` and
> takes the 80/8/5 split OUT of that D, so a winner gets `80/93 = 0.860·midGross`.
> This is INTENTIONAL and ~16% more conservative (lower per-claim emission,
> ceiling-safer, worsens every mill q\*). Consequence: the honest sole-staker
> break-even is `p ≈ 0.68`, not the `0.59` in ECONOMICS.md's headline (now
> corrected there). Do not "fix" the code toward the prose — keep the split.

Per claim, drawn from the reservoir (§3.3) at settlement:

```
TIER-SCALED, availability-scaled against the main reservoir R (v0.20, V2-4 —
the old block could not pay its own tier-invariant voter slice at low):
  winners' gross  Σg = Σ_winners rate-weighted conviction_i × tier
  claim draw      D  = min(Σg × 93/80, R)   — split winners 80 : author 8 :
                       answerer 5 (of the original 93 points; low ⇒ Σg = 0 ⇒
                       these three slices are zero)
  caps:           winner_i ≤ (tier/2) × time-averaged stake_i
                  author   ≤ (tier/2) × author's own time-averaged stake, either side (F1)
                  answerer ≤ (tier/2) × the answer BOND        (v0.8)

SENIOR-QUEUED, TIER-INVARIANT, independent of D — reserved on the accrual
line, paid first, never scaled, never zeroed by a low outcome (§3.3):
  voter carrot   = 7% of the claim's MID-weight gross, split among
                   with-verdict voters (verdict votes) or among all voters of
                   a standalone quality vote (F2 + V2-1)
  conduct comps  = min(2 × own bond, 80% × loser's burned bond)   (§3.6)
  flag bounty    = the flagger's own bond, on conclusive low      (§3.4)
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
while the bond at risk is `0.5×X̄ ≈ 0.5×S`. Under the reservoir the lie is
EV-negative at detection ≥ ~15% (F-R6); any dispute also flips the verdict
and re-votes quality.
So `50%·X̄` remains right — as a **conservative upper bound** on undisputed
extraction (with ~5× slack under the reservoir; see the F-R6 correction below). That coupling becomes a frozen invariant, V1-mustSane
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
  prevailing party is compensated by a minted, senior-queued (§3.3) slice.**
  No value ever moves *between* adversaries on any outcome — punishment is
  deflation, reward is issuance — making §7.1's "no bilateral event-contingent
  payment" claim TRUE rather than aspirational.
  **v0.20 comp sizing (round-2 V2-2 caught v0.11's "prices self-dispute at
  100%" as arithmetically false — comp minted to a prevailing party is
  recapturable by the forfeiter's own sybil, and naive own-bond sizing makes
  self-UPHOLD a mint faucet):**
  `comp = min(2 × the prevailing party's own bond, 80% × the loser's burned
  bond)`, tier-invariant, reserved at the round's decision. Properties, each
  checked: an honest disputer's bar returns to `q > 1/3` (the 2×-own-bond arm
  binds: comp = 2·B_d against risk B_d); every self-X sybil pair is strictly
  NEGATIVE (any prevail-comp ≤ 80% of what the pair burned — self-dispute
  costs ≥ 20% of the answer bond, self-uphold ≥ 20% of the dispute bond);
  wrong-answer deterrence is unchanged (the bond burns in full regardless);
  and escalated rounds degrade gracefully (round-2's comp ratio falls toward
  1×, acceptable for rarer, higher-conviction fights). This is v0.6's 80%
  economics, minted instead of transferred, capped at 2× own risk — the k
  that v0.11 left unpinned, now pinned.
- **v0.25 refinements (round-3 R3-1 + micro-vet-1, convergent):**
  - **Rounding pin**: the 80% arm TRUNCATES (floor) — ceil at small numbers
    pushes comp above 80% of the burn and re-cracks the anti-recapture bound
    (both vets, same example).
  - **Capped-court fix**: with an answer-bond cap, B_d = 20%·X̄ grows past the
    capped B_a and the round-1 honest bar silently degrades toward ~0.71 on
    exactly the biggest claims. Fix: `B_d1 = min(20%·X̄, 0.4 × the ACTUAL
    answer bond)` — restores 2·B_d1 ≤ 0.8·B_a identically on every claim, so
    round 1 is q > 1/3 everywhere; the doubling then produces the designed
    degradation only at rounds 2–3.
  - **Failed (quorum-less) rounds burn HALF the disputer's bond, return half**
    — decided-against still burns 100%. The dispute lane had kept the exact
    disease V2-1 cured in the flag lane: full burn punished honest disputers
    for turnout they don't control, and conditioned on reaching round k,
    no-quorum is the likely branch. Serial-chain costs stay exponential
    (identical argument to the flag ratchet); sybil pairs stay pure-burn (no
    comp mints on failed rounds — pinned: the answerer is NOT comped on a
    failed round; their bond simply survives).
  - Register notes: escalation ordering is CORRECT (griefer's certain loss
    accelerates +0.2/+0.4/+0.8·X̄ while the honest bar decelerates
    1/3→1/2→2/3, micro-vet-1 #2); the machine progressively favors the
    incumbent answer as rounds climb (defender comp doubles, risk fixed) —
    fine for deterrence, recorded; answerer-prevails adequacy HOLDS (whole at
    verdict-error < 24%, micro-vet-1 #3 and round-3 agree).
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
  address if one exists; pin at implementation). CC burns (the conditionally-burned claim fee,
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
- **Cold-start guard (R5e)**: the priority gate is disabled until ≥3 addresses
  qualify (N pinned = 3, matching the §4 row) — otherwise launch imposes a court-wide 24h latency tax while nobody
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
(junk and dead claims) and stops taxing honest experimentation. Under the v0.20 refund rule the fee no longer taxes a mill at all
(mill claims resolve default-mid → refund) — anti-mill work belongs wholly to
the flag lane; the fee's jobs are spam-pricing dead claims and the CC sink. Register
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

**Pass 4 (iteration 22) — two structural assumptions of the post-round-2 design.**

- **QUESTIONED: is the emission machinery irreducible?** The design now carries
  a main reservoir + senior queue + amortized schedule + live-supply d +
  rate-weighted conviction + min-rule comps + caps. Could a radically simpler
  scheme (fixed rate, mint-on-demand, no reservoir) do 80% of the job? **No —
  each piece is load-bearing for a named invariant**: the budget+halving makes
  total emission FINITE (without it, Σemission grows with participation
  forever and the `curveCap + Σemission ≤ MaxInt64/Bps` overflow invariant is
  unprovable); the rate band is the farming-proof (F5); the senior queue is
  the policing-under-scarcity proof (2A-T1); amortization + rate-weighting
  delete the boundary races (V2-8/2A-T3); live-d keeps the early court
  payable (V2-7). The machinery count is the *price of the invariants*, and
  every component now has a vet finding that dies if it's removed. KEPT, with
  this paragraph as the tripwire against future "simplification".
- **QUESTIONED: is the quality layer worth being the largest attack surface?**
  (A4/A5/A15–A18 and half of round-2 live there.) Alternatives worked:
  no-tiers (every trivially-true claim earns the full rate — the mill IS the
  protocol); disputed-only rewards (kills the healthy undisputed path, which
  is most of a working court); fee-priced claims only (regressive, and F-R2
  showed in-band p=1 self-staking stays profitable regardless). None survives.
  The honest insight, recorded as the keystone: **the quality layer is the
  hidden price of no-loss staking itself.** V1 never needed one — losers'
  losses priced junk automatically. Once losers lose nothing, "junk pays
  nothing" requires someone to decide what junk is, and that decision must
  itself be incentivized and attack-priced. The flag lane's complexity is not
  a feature's cost; it is THE cost of the design's central legal-economic
  trade. KEPT; zero design changes from this pass — third consecutive
  no-change brainstorm (convergence evidence).

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
| rate schedule | `rate_n = 0.85 × y*(n)`; `y*(n) = 2(r₀+d_n)·T_L/T_c`; **d_n = B_n / S_live** read once at each period boundary; table amortized ×2^(−1/104)/period | v0.20 (V2-7 live-supply; V2-8/2A-T3 amortization) |
| **inflation ceiling (OWNER, v0.32)** | `B_n = (20%/52) × S_live × 2^(−n/104)` — worst-case dilution ≤ 20%/yr year one at any court size, halving-amortized; total supply provably < 1.78× curve-sold (Σ of the geometric exponent ≈ e^0.577); **curveCapV2 = (MaxInt64/Bps)/2** for overflow headroom | owner set the ceiling at 20% (overriding my conservative ~5%); the %-of-live-supply budget is self-costly to manipulate for the same reasons as live-d (buying is paid, burning is self-costly, minting is earned-only and ceiling-bounded); ECON VET RUNNING on this sizing |
| Finalize authorization | participant-only first week of eligibility, then permissionless | v0.11 (A13) |
| bond/deposit forfeitures | 100% BURNED on decided-against; **failed (quorum-less) dispute rounds burn HALF, return half**; comp = min(2×own bond, floor(80%×loser's burn)), tier-invariant, senior-queued, none on failed rounds | v0.11 + v0.20 + v0.25 |
| flag bounty | min(flagger's bond, 80% × CC burned on the low outcome), senior-queued | v0.25 faucet fix (R3-1d + MV1-4) |
| conclusive-low slash | 2.5%·X̄ from the ANSWER bond (burned) only at the SUPPLY-FLOORED full bar AND undisputed answers; upheld answers never slashable; median-low = tier-0 + deposit only | v0.28 (A21/A22 final) |
| slot-consuming mid | requires the FULL verdict bar; ¼-bar mid = demotion denied, slot reopens ×2 | v0.25 (idle-reserve squat) |
| bounty base | min(flagger's bond, 80% × event burns); the slash counts only when it burned | v0.27 — V2-1 in the mill band, ≤ dust for honest-claim captures that fail |
| quality demotion bar | min(X̄, ⅓·votable)/4 — no 5%-supply floor (verdict votes keep the full floor) | v0.25 dead-zone fix |
| B₀ (weekly accrual) / R_max | `b·120,960` / `4 × B_period` | reservoir cap banks ≤ 4 quiet weeks |
| halving interval | 104 periods | total emission ≤ 2·B₀·104, finite |
| supply invariant | curveCap + Σemission ≤ MaxInt64/Bps, ≥20% headroom | checked at deploy |
| conviction unit | stake × hours | fits int64 ~5× (F4); draws via mulDiv128 |
| G_MAX | per-claim Σg clamp | clamp, never abort, on shared settle paths (F4) |
| tiers | low 0× · mid 1× · high 2×; **high needs ⅔ + bar turnout** | §3.4 asymmetric ratchet (F3) |
| winner cap | (tier/2) × time-averaged stake | flash-proof base (F9) |
| author slice cap | ≤ (tier/2) × own stake | F1 |
| answerer slice cap | ≤ (tier/2) × the answer bond | v0.8 (stale #6 fixed) |
| split | 80/8/7/5; **voter slice tier-invariant, paid even at low, with-verdict only** | F2/F3 |
| quality-flag bond | max(flagMin, 2%·X̄); conclusive low → returned + bounty; inconclusive → half-burned, slot reopens; conclusive mid/high → burned; doubling PER-SLOT until cycle 3, then FROZEN at 8%·X̄ with a 7-day per-flag cooldown | v0.20 pins + v0.24 freeze (micro-vet-2) |
| no-settle window | 24h after every flag-vote close / slot reopen | v0.20 (V2-5: the post-answer version was vacuous under the 72h delay) |
| flag-vote carrot bound | carrot per flag-vote < b₀/2 | v0.24 deploy invariant (micro-vet-2: sybil mid-voters must net negative; margin ~2.2×) |
| conviction | rate-weighted: ∫rate(t)·stake·dt; amortized table ×2^(−1/104)/period | v0.20 (V2-8 + 2A-T3; rateAtFreeze deleted) |
| answer priority | difficulty-weighted record (contested-and-upheld only), ≥3 → 24h window; gate off until N addresses qualify; 1 active priority claim/address | v0.12 (A18) |
| claim fee | 10% of deposit; burned only on dead-with-no-stake or CONCLUSIVE low; refunded otherwise (incl. default-mid-no-vote) | v0.20 (V2-9: the old condition was undefined at the most common outcome) |
| dispute bond | `B_d1 = min(20%·X̄, 0.4 × the actual answer bond)`, doubling per round | v0.25 (R3-1a): keeps round-1 at q > 1/3 on every claim incl. capped courts; subsumes the v0.20 zero-case |
| minAnswerX | 100 CC of trailing total stake | resolved v0.13 (§8.8), provisional pending round-3 |
| answer bond, escrow windows, 5001 bps, 72h delay | V1 values | unchanged |
| dead-claim timeout | 12 weeks | new (O6 fix) |
| bond–tier coupling | `answerBondBps ≥ maxUndisputedTier/2` | frozen invariant, §3.6; deploy refuses otherwise |

## 5. Attacks & mitigations

All statuses reflect the econ vet's findings (F1–F11), ingested v0.6.

| # | Attack | Resolution | Status |
|---|---|---|---|
| A1/A2 | **Matched-stake farming** (one wallet or a sybil pair): stake both sides, harvest the winner bonus risklessly | Closed form (F5): profitable iff rate `y > y* = 2(r+d)·T_L/T_c`. The reservoir rate is a frozen SCHEDULE inside `(y*/2, y*)` (A14) → farming strictly unprofitable; honest p ≳ 0.67 stakers profit. Per-address netting DELETED — the vet showed my "sybil doubles lock cost" claim was arithmetically false (a lone matched farmer already locks 2X) and netting breaks custodial wallets while stopping nobody | `CLOSED (F5)` |
| A3 | Last-second stake flood | Conviction ≈ 0 for late stake; cap base is time-averaged stake (flash-proof) | `ACCEPTED` |
| A4 | Quality capture: whale median-push (needs only ~29% of a thin turnout), off-band pre-announcement herding, free self-dispute trigger | High needs ⅔ of turnout + turnout ≥ the verdict bar; the median only moves mid↔low; with-median carrot dropped; the v0.20 comp rule prices the trigger (every self-X pair burns ≥ 20% net) | `CLOSED (F3)` |
| A5 | **Author-mill on undisputed default-mid** (CRITICAL): trivially-true claims are undisputable → default mid → uncapped 13% author+answerer skim of a crowd-earned draw, ~6× on lock cost, self-reinforcing | Quality-flag lane + author slice capped at (tier/2)×own stake, answerer at (tier/2)×bond (v0.8) | `CLOSED (F1, repriced v0.20)` |
| A6 | Whale claim hogs the pool | Non-attack under a linear rate (equal yield per conviction by construction); sqrt and per-claim caps are WORSE (√k to claim-splitters / punishes flagship claims). No smoother | `CLOSED (F8)` |
| A7 | Emission-lever capture | No lever exists (frozen constants) | `ACCEPTED (V1 discipline)` |
| A8 | Unstake games: paint the ratio, unstake→restake cycling, freeze front-running | Exact-integral conviction (never resets; capital-conserving); freeze atomic with the answer (same-block-later unstakes revert); publish the conviction-weighted ratio alongside the instantaneous one — the only series you can move is the one you pay capital-time for | `CLOSED (F9)` |
| A9 | Arithmetic: conviction overflow; **checked-abort on a shared settle path = settlement DoS** | Stake×hour units (fit int64 with ~5× headroom); 128-bit `mulDivFloor` for draws; per-claim Σg CLAMPED at G_MAX — never aborted — so no crafted position poisons settlement for others | `CLOSED (F4)` |
| A10 | Cross-claim pro-rata: period-assignment timing + slowest-dispute payout coupling (self-found) | Reservoir drip adopted (§3.3) — no cross-claim *denominator* exists to time; coupling through R is **intermittent and bounded** under scarcity, failing farmers-first (F-R4), not "gone" | `CLOSED (reservoir, wording per F-R4)` |
| A11 | Voter-carrot tier-coupling → electorate-wide drift to "high"; policing junk is unpaid (CRITICAL) | Voter slice tier-invariant, paid even at low, with-verdict only | `CLOSED (F2)` |
| A12 | provClose freeze-hostage: push a rival claim through 3 failed rounds; stakers frozen ~8 weeks, conviction pays zero | Losers exit 1× after each decided round AND principal is never pausable (v0.20 split settlement); every self-X sybil pair is strictly negative under the v0.20 comp rule (≥20% of the paired bond burns — the v0.11 "100%" claim was false, V2-2); a griefer cannot force votes to fail on claims with motivated stakers | `MITIGATED (F7+v0.20)` |
| A13 | Adversary-timed zero-draw: third party Finalizes a rival's claim while R ≈ 0 → their draw = 0 forever, at gas cost (reservoir vet F-R3) | Finalize participant-only for a 1-week grace, permissionless after; accrual-interval queue recorded as the upgrade path | `CLOSED (v0.11)` |
| A14 | Scheduled self-defeat of a frozen scalar rate: d decays by the halving path → y* sinks below rate by ~the 2nd halving → farming turns on with no adversary (reservoir vet F-R1) | Rate is a deploy-frozen SCHEDULE tracking y*(n)'s deterministic component at 0.85·y*(n); decrease-only ratchet noted for r-drift; no increase lever | `CLOSED (v0.11)` |
| A15 | Author-mill v2 — single-sided p=1 farming inside the anti-farm band, re-armed because the reservoir deleted the crowd's selfish flag motive (reservoir vet F-R2) | Low-tier slash (deposit + 2.5%·X̄ of the answer bond, burned) + bounty = min(own bond, 80%×low-burns) + PAID flag-vote voters (senior-queued) → policing positive-EV at q > ½ AND every sybil farm burn-dominated | `CLOSED (v0.20, repriced v0.25)` |
| A19 | **Bounty mint faucet** (round-3 + micro-vet-1, independent BREAKS): bounty = own bond was unbounded by its event's burns — junk-farm sybils pumped X̄ with refundable stake and minted 2%·X̄ per ~1 CC burned, capturing the senior queue's head | Per-event burn-domination restored: bounty ≤ 80% of low-outcome burns, and the burns scale (the 2.5%·X̄ answer-bond slash) | `CLOSED (v0.25)` |
| A20 | Idle-reserve conclusive-mid squat: ¼-bar of unstaked mill reserve self-votes the slot closed | Slot-consuming mid needs the FULL bar; ¼-bar mid reopens at ×2; failed squats net negative post-A19; participants excluded from own-claim quality lanes (v0.26) | `CLOSED (v0.25/26)` |
| A21 | **Low-capture bounty faucet (self-found composition of three v0.25 fixes)**: slash-funded bounty + claim-scaled demotion bar made capturing an honest claim's low vote profitable (~50:1) with reusable weight | Two-tier low: median-low = draws zeroed + deposit-only economics; the answer-bond slash + full bounty need ⅔ + full-bar supermajority-low — same whale price as high-capture | `DRAFT (v0.26, final micro-vet running)` |
| A16 | **Self-flag slot squat** (mech vet R1, launch-blocking): mill's sybil flags its own claim instantly with a dust vote destined for low-turnout mid — one burned bond consumes the only flag slot and immunizes the claim; the ¼-bar floor shields the mill, not honest claims | The slot is consumed only by a CONCLUSIVE vote; inconclusive reopens it (half the bond burns); doubling is PER-SLOT, monotone across flaggers; staked CC cannot vote quality (escrow weight nets out) | `CLOSED (v0.12; pins v0.20)` |
| A17 | **Settle/flag ordering race + step-down delay grief** (mech vet R2): permissionless settle at 72h+1 turns the flag window into a 1-block race; and a 7d flag pause could drag a rival's claim across a rate step-down, halving their draw for one 2%·X̄ bond | No-settle window is reopen-relative (24h after each flag-vote close — the post-answer version was vacuous under the 72h delay, V2-5); conviction is rate-weighted over an amortized table, so no rate snapshot or boundary block exists to race (V2-8/2A-T3) | `CLOSED (v0.20)` |
| A18 | Credential × mill habitat overlap (mech vet R6): raw stood-counting is maximized by cherry-picking trivially-true claims — the credential would compound the mill instead of checking it | Difficulty-weighted record: undisputed stands ≈ 0, contested-and-upheld = full credit; plus cold-start guard and one-active-priority-claim limiter | `CLOSED (v0.12)` |

**The F6 insight, recorded:** in V2 a flipped verdict moves **no staker
principal** — staker-level harm from a wrong verdict is purely epistemic. The
only financial prizes riding on any vote are the conduct bonds (present only
when contested) and a capped, dilution-funded emission draw. V1's quorum bar was
sized against a prize of X (the losing collateral); V2 keeps the same bar
against a prize of capped emission comps only — bonds burn and are no longer capturable — plus (tier/2)·stake — **verdict security is
strictly improved**, and the soft underbelly moved to the quality tier, which
A4/A5/A11 close. Vote-buying at launch scale is unprofitable (the loot is CC —
non-redeemable in-protocol, transferable — whose value the attack debases); it degrades only as OTC
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
5. ~~Comp availability-scaling~~ — RESOLVED v0.20: conduct comps, bounties,
   and voter carrots are senior-queued entitlements (full amount, possibly
   time-delayed). Residual: the delay itself under sustained scarcity.
6. A small bounded prize now rides low-median capture (the flag bounty) and
   carrot-only voting mildly subsidizes P+ε coordination — both registered,
   both bounded by caps and the ratchet.
7. Queue-jamming via self-dispute chains: senior comp entitlements from a
   staged multi-round fight delay everyone else's policing pay. Bounded and
   costly by the min-rule — the pair burns ≥ 1.25× what it jams (comp ≤ 80%
   of the burn) with doubling bonds; net supply falls. Registered, accepted.

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
- **Claim fee** → confirmed helpful at v0.5 (*Humphrey* factor 1); since
  superseded by the v0.12/v0.20 conditional refund (factor-1 trade-off
  registered in §3.8); Humphrey factor 2 is "amounts certain and guaranteed" —
  see register item 4.
- **Track-record answer priority** → no legal exposure noted.
- **Reservoir rate** → confirmed the friendlier frame (a published rate reads
  closer to protocol-staking rewards AND scores better on "amounts certain"
  than a contested pool), with the F-R1 schedule fix adopted.

## 8. Open questions / vet queue

1. ~~A1/A2 economics~~ — RESOLVED (F5): profitability condition `y > y* =
   2(r+d)·T_L/T_c`; the frozen rate SCHEDULE sits below y*(n), so farming never
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
     through a typical claim sees the §3.3 target (the ECONOMICS.md calibration target).
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
9. ~~v0.8 answerer-cap refinement~~ — RESOLVED: the bond-based cap was
   validated by 2B's role audit (a stake-based cap would zero the natural
   non-staking answerer — 2B: "stale stake-cap would have zeroed it") and is
   exercised in Appendix B.
10. **Severable securities lever (legal vet #2)**: time-vest transfers of
   *reward-earned* CC only (in-protocol use immediate; transferable after N
   months or one full participation cycle). Purchased CC stays liquid, so
   Buy's consumption story is untouched. The single highest-leverage
   securities hardening short of the full transferability off-switch.
   **DECLINED by owner (2026-08-16)** — not built, not a launch toggle; all CC
   (earned or purchased) stays immediately transferable. Recorded closed.
## 10. Implementation & verification plan

- **STATUS (v0.37): BUILT.** All 13 modules exist on branch `courtv2`, V1
  untouched. Three code audits (money-core M1, dispute M2, quality/crystallize
  M3) plus the M2-1 design-follow-up landed and are ingested FIX-FIRST; every
  finding to date is fixed with a named regression. Green across `gno test`
  (staged), `REQUIRE_GNO=1 make check`, `make txtar-test` (courtv2 money-core
  script + V1 scripts), and `make isolation-test` (151 tests alone+together).
  The final full-system adversarial audit is the launch gate (running).
- **No migration problem exists**: V1 never launched; V2 is the launch target.
  V1 stays fully audited in git history (branch `court-realm`, base `5d2c4ef`).
- **Build order (refreshed v0.13 for the v0.10–v0.12 mechanics)** — all /p/
  packages untouched except deleting the court's dependency on
  tickbook/cshares: (1) `stake.gno` (pools, conviction-128, freeze atomicity)
  + `emission.gno` (reservoir accrual, the amortized step-down INSIDE B_n —
  one decay only, no separate halving — senior entitlement queue, pull-claims,
  participant-gated Finalize; rateAtFreeze does NOT exist — deleted v0.20);
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
  exactly once); the flag-vote carrot per vote < b₀/2 (v0.24).
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
  (stake→answer→settle→withdraw+bonus; the dispute path; dead-claim disposal;
  reservoir exhaustion if §8.7 adopted); then the same per-unit adversarial
  audit loop to convergence that V1 got. Done means: full sweep, zero findings,
  `make check` + txtar green.

## 10.1 Implementation pins (audit-15, adopted v0.33 — the coding spec)

- **P1 (BLOCKING, FIXED in code)**: the rate prices `d_eff = min(budget
  ceiling, 4-period EMA of realized minted/S_live)` — budget-d alone overpaid
  at thin participation (riskless farming below f ≈ 18%). Bootstrap property:
  the rate rises from the pure-r floor with real participation.
- **P2**: the voter carrot is clamped per claim: `min(7%·midGross, b₀/2 − 1)`
  (at the 20% rate the 7% crosses b₀/2 at T_c ≈ 8.8wk; micro-vet-2's sybil
  margin held only 1.2× — the clamp restores it).
- **P3**: actual headroom under the 20% bound is 10.8%, not the stated ≥20% —
  the invariant is AMENDED to ≥10% (owner-flagged, §12; the code's fit check
  passes; shrinking curveCap to 0.44× is the alternative).
- **P4 state machine**: VERDICT_FINAL (per-staker 1× withdrawals open, both
  sides, unpausable) → QUALITY_FINAL (last flag resolved + reopen-quiet) →
  CRYSTALLIZE (compute D, enqueue entitlements — this is what flag pauses and
  the reopen-relative 24h windows gate, never principal).
- **P5 senior queue**: FIFO bptree of (addr, amount, purpose) + cumulative
  counters (reservedTail, accrual A); entitlement i payable up to
  min(amt, A − start_i) − paid; per-tick order accrual → seniors → R;
  R_max pause only when seniors clear. Invariant: seniors-before-juniors.
- **P6**: every %·X̄ quantity (bonds, slash, bounty, flag bond) reads one
  `X̄frozen` snapshotted at the answer height.
- **P7 — RESOLVED (econ-vet, v0.39).** deposit = 1 CC, fee = 0.1 CC,
  flagMin = 1 CC, minAnswerX = 100 CC all stay. The vet reproduced the ~19%·X̄
  hot draw exactly (it is the **12-wk max gross draw**, not net mill profit) and
  found: (a) **minAnswerX is the wrong lever** — with S = X̄ the mill's gain,
  carry, and slash all scale with S, so the break-even detection q\* is
  ~invariant to minAnswerX; raising it only walls off honest thin claims. (b)
  The mill's **edge over honest staking is negligible** — the author+answerer
  top-up is cap-bounded to ≤ ~2.5 CC/claim (~0.01%/wk), erased at a detection
  probability of only q\* ≈ 0.045 (typical) → 0.10 (patient), well inside what
  the paid flag lane supplies; the rest of the "draw" is the *intended* p=1
  staker reward. (c) The remaining absolute-EV gap is the **patient /
  idle-capital** farmer (q\* ≈ 0.22 typical → 0.45 at the 12-wk edge), which is
  **structural and pre-existing** (≈0.44 at the old ceiling too): the draw
  scales with hold-time but the slash is X̄-scaled and the deposit fixed, so
  punishment can't track the prize. deposit 1→5 CC is an owner-available lever
  (typical q\* 0.22→0.15, patient 0.45→0.37, honest-claim-safe) but is NOT
  applied — it taxes honest thin-claim openers to chase a case that is
  economically the intended reward, and cannot close the patient gap without a
  wall (~18 CC). The real fix is a **draw-proportional deterrent** (owner row
  28, V3 frontier — fresh vet). Deploy invariants: none affected
  (answerBondBps ≥ tierMid/2 is X̄-relative and at equality; deposit/fee outside
  mustInvariants; A19 bounty stays flag-bond-capped).
- **P8**: G_MAX = one period's budget (clamp, never abort).
- **P9**: conviction units = stake × blocks × rateBpsFP (bps×1e6) in u128;
  draws divide by periodBlocks × 1e10 (implemented; supersedes the stale
  stake×hours prose).
- **P10 rounding**: floor everywhere; per-block accrual carries remainder so
  Σb = B; scale-then-cap per claimant; dust stays in R / unminted.
- **P11 two-epoch ballot**: VoteQuality is its own tx in the dispute window;
  verdict weight = propose-time snapshot, quality weight = answer-height
  epoch; participant exclusion filters quality only; the demotion bar uses
  votable-at-epoch NOT net of refused weight (conservative).
- **P12**: counter-flag window = votingBlocks (7d); slash burn + bounty
  enqueue deferred until it lapses unchallenged; exactly-once escrow.
- **P13 priority**: contested-and-upheld = 1 point, undisputed = 0, an
  overturn RESETS the record to 0; "one active priority claim" runs from the
  priority answer until that claim finalizes.
- **P14 misc**: dead-claim timeout counts only while unanswered (implemented);
  S_live via lazy period roll (implemented); comps enqueue at RoundDecided;
  standalone-quality carrot pays all non-participant voters weight-pro-rata
  regardless of bucket; the GNOT burn sink is a derived keyless address
  picked at deploy.

## 10.2 Quality + crystallize coding spec (v0.36 — pre-implementation pins)

Written before quality.gno so the intricate lane rules land as one coherent
machine. Sources: §3.4 (flag lane), §3.5 (draw), v0.24–v0.31 changelog, pins
P2/P4/P8/P10–P14.

**Q1 — the quality electorate is pinned at PostAnswer**: `cs.qualityEpoch =
coin.Epoch() − 1` stored on the claim when the answer lands (the last sealed
epoch at the answer height — set before any flag can exist, v0.23). Every
quality vote a claim ever has reads `PastVotes(voter, qualityEpoch)`. Escrowed
(staked) capital is thereby structurally disenfranchised on its own claim.

**Q2 — participant exclusion (v0.26)**: author, answerer, and any address with
a staker record on the claim may not VoteQuality and never receive the carrot.
Verdict (dispute) voting is unaffected (P11).

**Q3 — the flag slot machine** (per claim): fields `flagOpen, flagger,
flagBond, flagVoteEnd, flagCycles, slotConsumed, lastFlagEventAt, qVoteSeq` +
a court-local sealed 3-bucket tally keyed (claim, qVoteSeq). b₀ =
max(flagMinCC, X̄frozen×2%). Bond for cycle k: b₀×2^min(k,3) frozen at 4×b₀
after 3 inconclusives with a 7-day per-flag cooldown (v0.24). OpenFlag guards:
answered; no verdict-final crystallize yet; !disputeOpen (a flag during an
open dispute is refused — the dispute ride carries quality); slot not
consumed; cooldown honored; flag cannot be withdrawn.

**Q4 — vote + outcome table** (window = votingBlocks, sealed until close; one
vote per address; weight = Q1 epoch). Bars: demotionBar = min(X̄frozen,
votable/3)/4 (NO supply floor, v0.25); fullBar = the verdict quorum floor
(max(5%·supply, min(X̄frozen, votable/3))); votable at the Q1 epoch (P11:
NOT net of refused weight).
| Outcome | Condition | Tier | Flag bond | Extras |
|---|---|---|---|---|
| Conclusive LOW (dust) | median low ∧ turnout ≥ demotionBar ∧ (turnout < fullBar ∨ no ⅔-low) | low | **returned** | slot consumed; deposit slashed+burned, fee burned; bounty = min(bond, 80%×event burns) senior-queued; if turnout ≥ fullBar but < ⅔-low, the bond instead **half-burns** (the T2 free-roll price) |
| Slash LOW | median low ∧ turnout ≥ fullBar ∧ ≥⅔ of turnout low ∧ answer was UNDISPUTED | low | returned | as dust-low PLUS the 4.5%·X̄ answer-bond slash, **escrowed one counter-flag window** (Q5) |
| Conclusive MID | median mid ∧ turnout ≥ fullBar | mid | burned | slot consumed |
| Promotion HIGH | ≥⅔ of turnout high ∧ turnout ≥ fullBar | high | burned | slot consumed (flag risk cuts both ways) |
| Inconclusive-MID | median mid ∧ turnout < fullBar | unchanged | **half-burns** | slot REOPENS ×2 bond; no carrot |
| Inconclusive-LOW | median low ∧ turnout < demotionBar | unchanged | **returned in full** (T1) | slot REOPENS ×2 bond; no carrot |

**Q5 — counter-flag window (v0.31, P12)**: a slash outcome escrows the slash
burn + its bounty increment for one votingBlocks window; the slashed ANSWERER
may force exactly one re-vote at the supply-floored bar during it;
inconclusive re-vote → the slash stands; the re-vote's outcome is final
either way. Exactly-once: the slash amount moves answerBond→pendingSlash at
the vote, burns (or refunds) only at window close/re-vote resolution.

**Q6 — settlement gating (P4, v0.20 split settlement)**: principal
(WithdrawStake) is NEVER gated by any flag state. A flag pauses only
CRYSTALLIZE. Crystallize requires: verdictAt ≠ 0; !provClose; no open flag or
pending counter-flag window; now ≥ lastFlagEventAt + 24h (the reopen-relative
no-settle rule — every flag-vote close or slot reopen restamps it);
participant-only for its first week of eligibility (A13 — the zero-draw
timing attack targets the DRAW, so the gate lives here), permissionless
after.

**Q7 — the draw (one crystallize per claim, then pull-claims)**:
- Second accumulator: stake.gno adds `rawConvHi/Lo` per position and per side
  pool — ∫stake·dt in raw block units, u128 — the F9 flash-proof CAP base
  (time-averaged stake = rawConv/openBlocks). A money-path change: fold into
  the quality-milestone audit.
- Pool-level, walk-free: Σg = tier × convToCC(winning-side pool conviction);
  midGross = 1 × the same (tier-invariant carrot base). D = min(Σg, R, G_MAX
  = curPeriodBudget) drawn via reserveJunior (clamp, never abort).
- Split of D: winners 80/93, author 8/93, answerer 5/93 (court.gno split
  invariant); carrot = 7% × midGross, P2-clamped (min(7%·midGross, per-voter
  b₀/2−1)), senior-queued at crystallize, paid even at tier low; with-verdict
  dispute voters weight-pro-rata (P14 governs the standalone lane: all
  non-participant quality voters regardless of bucket).
- Pull-claims (per claimant, at their own tx): winner_i = min( D_w ×
  convCC_i/ΣconvCC_pool , (tier/2) × timeAvgStake_i ) — scale THEN cap
  (P10); author ≤ (tier/2)×own timeAvgStake; answerer ≤ (tier/2)×answerBond0.
  Cap dust stays unminted. Deposit refunds (unless slashed-low), fee refunds
  (unless dead/conclusive-low) at crystallize — their one disposition point.
- Tier low: D = 0 (winners/author/answerer draw nothing) but the carrot and
  comps still pay (senior lane) and principal was never touched.

**Q8 — provClose and dead claims** never crystallize: deposits/fees were
disposed at their own terminal events; a crystallize call on them refuses.

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
not multipliers, "step-down" not halving, never "backing"/"redeem"/"cash out",
and **never render the inflation ceiling or budget percentages** (audit-15).
Audit-15 additions: a persistent "principal always returns 1×" badge; the
stake ticket quantifies the freeze ("an answer can post once X̄ ≥ 100 CC; your
stake then locks until resolution — up to ~9 weeks if disputed") and notes
late stakes earn ~nothing; the flag control renders the OUTCOME TABLE with
the slot's live bond level and state; pull-claims show senior-queue position
("payable after ~N more accrual"); new rows: the counter-flag control for a
slashed answerer, participant-exclusion greying with the reason, the
"withdraw 1× now" nudge for losers after decided rounds, Finalize's
participant-only countdown; and the three quality buckets get frozen
canonical one-liners (low = no informational value; mid = a real falsifiable
question; high = unusually decision-relevant and rigorous) — Schelling
convergence needs common knowledge. Reward previews show absolute CC
("potential accuracy reward if correct: N CC, subject to availability"),
never percentages, never annualized. web/index.html still carries V1
"backing" copy 11× — swept when the V2 overlay is built.

## 12. Owner decision index (v0.15)

Every judgment call the loop made autonomously, consolidated for override.
"Override cost" = what changes if you reverse it.

| # | Decision | My call & where argued | Override cost |
|---|---|---|---|
| 1 | GNOT: burn vs work-pool | **Burn** (§3.7) — capture honeypot, Ooki, AML/tax | Rebuild pool + entity + payment compliance; re-arms three legal hooks |
| 2 | Emission model | **Reservoir drip** over pro-rata (§3.3, vetted KEEP) | Pro-rata + F11 fix works but pays farmers to equilibrium and re-couples payouts |
| 3 | Rate | **Frozen schedule 0.85·y*(n)** (§3.3) | Scalar self-defeats by schedule (A14); richer rate re-admits farming; leaner excludes more honest mid-p |
| 4 | Voting discipline | **Carrot-only, no slashing** (§3.5, your lean) | Slashing hardens against large-value bribery; costs honest-minority chill |
| 5 | CC transferability | **ON**; reward-vesting lever **DECLINED by owner (2026-08-16)** — all CC stays immediately transferable, no vesting toggle | Vesting was the cheapest securities cut but owner rejected it; OFF-entirely kills OTC + product |
| 6 | Bonds | **Forfeitable; burn-not-transfer** (§3.6) | Time-lock-only invites answer-slot squatting DoS |
| 7 | Undisputed quality default | **Mid + flag lane** (§3.4) | Low punishes the healthy path; high is free money |
| 8 | Tier gates | **Median mid↔low; ⅔+bar for high** (§3.4) | Symmetric median is whale-capturable at ~29% turnout |
| 9 | Split 80/8/7/5 | Reasoned-provisional (§3.5; rationale in ECONOMICS.md v0.19: winners must dominate; author capped by claim-spam pressure; voter slice deliberately token-sized; every answerer point is a mill point) | Retune freely within the ordering + caps; crossing either re-opens A15/F2 and needs a fresh vet |
| 10 | Claim fee | **10%, conditional refund** (§3.8) | Always-burn is regressive on honest thin claims; no-fee removes CC's only sink |
| 11 | Answer priority | **ON, difficulty-weighted, cold-start-gated** (§3.8) | OFF = pure first-come answers; naive counting re-aligns with the mill (A18) |
| 12 | Court topology | **Per-court coins** (§3.8 pass 2) | Shared coin pools liquidity but couples every court's legal+economic fate |
| 13 | minAnswerX | **100 CC** (§8.8; CONFIRMED no-change, econ-vet P7 v0.39 — q\* is ~invariant to it, the wrong lever) | Lower invites micro-mills; higher walls off the honest long tail for zero mill benefit |
| 14 | provClose payout | **1× everyone, no price** (§3.1) | Any price-based close re-opens the V1 O5 manipulation surface |
| 15 | Entity | **Wyoming DUNA recommended** (§7.3) | Alternatives: DAO LLC (profit OK, weaker fit), Cayman/RMI (offshore optics); none = Ooki exposure stays raw |
| 16 | Verdict form | **Binary, sealed** (§3.8 pass 1) | Probability verdicts hand adjudicators a nudgeable knob |
| 17 | Emission cadence | Weekly period, R_max = 4B, step-down every 104 (§3.3/§4) | Cosmetic within bounds; total-emission invariant must re-check |
| 18 | Round-2 fixes | Slot-reopen, participant Finalize (v0.12); reopen-relative no-settle (v0.20) | Each reverts to a named, vetted attack (A13, A16, A17) |
| 19 | d_n denominator | **Live realized supply** (v0.20) — REVERSES the v0.15 ceiling pin; ceiling made early courts unpayable (p_min > 1); all manipulations self-costly | Ceiling path = safe margins but a dead early court; modeled path risks farming re-entry |
| 20 | Comp sizing | min(2×own bond, 80%×loser's burn), tier-invariant, senior-queued (v0.20) | Any comp reachable above the pair's burn re-opens self-X recapture (V2-2) |
| 21 | Policing pay | Senior-queued entitlements, never scaled (v0.20) | Availability-scaling re-opens the scarcity-window lying meta (2A-T1 BREAKS) |
| 22 | Flag ratchet terminal | Bond freezes at 8%·X̄ after 3 inconclusives, 7d cooldown (v0.24) | A terminate-as-mid cap = mill immunization; bare unbounded doubling = immunization by capital exhaustion |
| 23 | Bounty base | ≤ 80% of the low outcome's burns, with the 2.5%·X̄ answer-bond slash as the scaling burn (v0.25) | Own-bond bounty was a mint faucet; deposit-only base un-pays policing (V2-1) |
| 24 | Slash gate (final) | Supply-floored full bar + undisputed-only (v0.28, two vets reconciled); median-low tier-0 alone kills mills at q ≈ 12%; bounded dead zone accepted; counter-flag upgrade path registered | Any reachable-bar X̄-scaled slash re-arms the faucet (costless reusable weight); weight-at-risk is the V3 frontier |
| 25 | Quality-lane participation | Participants excluded from own-claim quality votes and carrots (v0.26) | In-band self-defense via same-epoch/post-release enfranchisement; carrot self-payment |
| 26 | d_eff pricing (v0.33, FIXED in code) | rate prices min(budget ceiling, realized-EMA dilution) | Budget-d alone = riskless farming below ~18% participation (both v0.32 audits, convergent) |
| 27 | Headroom amendment (v0.33) | ≥10% actual (10.8%) under the 20% ceiling with curveCap = half | Alternative: curveCap = 0.44× restores ≥20%; owner may prefer it |
| 28 | Slash size (v0.33) | 4.5%·X̄ (was 2.5%) — mill-kill q ≈ 0.22 at the hot rate | 2.5% drifts the kill bar to ~0.30 at 20%; bounty ≤ 80%×burns holds at both |
| 28b | **Draw-proportional slash — ADOPTED v0.40** (three-designer convergence + code-audit) | `slash = min(bond, max(4.5%·X̄ floor, 1.6·midGross))`, midGross = winning-pool mid draw (the mill's would-be take). Drags the patient 12-wk mill q\* 0.45→0.22 and flattens the hold-time curve; floor keeps the fast-claim deterrent; clamped to the bond (invariant guarantees the draw arm fits at the hot-rate max) | Residual: idle-capital q\* floors at ~0.27 — the answer-bond ceiling structurally caps idle-capital deterrence (V3 weight-at-risk frontier); a bigger k would just permanently clamp |
| 37 | **deposit / fee (econ-vet P7 v0.39)** | **1 CC / 0.1 CC — no change.** Owner-available lever: 1→5 CC drops typical q\* 0.22→0.15, patient 0.45→0.37, honest-claim-safe (refunded on default-mid) | Not applied: it taxes honest thin-claim openers to chase a mill that is economically the intended p=1 reward, and can't close the patient gap without an ~18 CC wall. Pull it if tighter absolute-EV margins are wanted pre-launch |
| 29 | Answer-bond custody (v0.35) | Bond stays escrowed through UPHELD rounds, returning only at VERDICT_FINAL — reopens stay collateralized; comp arms read the posted magnitude | V1's return-at-each-decision frees honest capital ~1–3wk sooner but leaves reopen rounds with nothing at stake (comp anchor = 0) |
| 30 | provClose reachability (v0.35; **premise corrected v0.49**) | Kept V1's window geometry. The original rationale — "3 failed rounds fit only inside >2-week escrows (large claims); small claims cap at 2 failed rounds" — is **FALSE on any court past bootstrap**: `escrowWindow` adds `X̄·Price(minted)/5e8` days over a `room` of only (362880−120960)/17280 = **14 days**, so the window pins at the 3-week `escrowMaxBlocks` as soon as `X̄·Price ≥ 7e9` — which a modest claim clears once the curve has any real price. So three failed rounds fit on essentially EVERY claim, not just large ones, and provClose is correspondingly more reachable than this row claimed. The griefing path it dismisses as rare (≈3.5×base ≈ 70 CC of net burn buys three quorum-less rounds → provClose → the whole draw zeroed) is therefore live court-wide | Left as-is pending an owner decision: capping `extraDays` would restore the documented geometry but re-opens the "honest small claims wait 3 weeks" cost the row was written to avoid, and the fix belongs with the dispute-bond pricing rather than the window alone |
| 32 | Crystallize gating anchors (v0.36) | participant week anchored at verdictAt (flag chains can outlive it — participants had the whole flag period); 24h quiet anchored at lastFlagEventAt | Anchoring the week at "all-quiet" instead is unknowable in advance; anchoring quiet at verdictAt re-opens the settle-race the reopen-relative rule exists to kill |
| 33 | Cap-dust disposition (v0.36) | Scale-then-cap dust and cap-cut remainders stay juniorReserved and UNMINTED forever — economically a burn, always under the ceiling | Returning dust to R needs per-claim pull tracking (a walk) or a sweep entrypoint; the leak is bounded per claim by D and only reduces emission |
| 34 | Carrot enqueue ordering (v0.36) | Per-voter senior entitlements enqueue at PullCarrot time (FCFS by pull), not at crystallize — avoids walking the voter set | Earlier pullers sit earlier in the senior queue; amounts are unaffected (never scaled), only payout timing |
| 35 | Slash-reserve retention (v0.37, audit M3-HIGH; extended to Finalize v0.43) | BOTH terminal paths retain the draw-proportional slash size through the quality slot, returning the rest: SettleUndisputed (undisputed claims) and Finalize (claims that reached finality through FAILED rounds, which keep decidedRounds==0 and so stay slash-eligible). Retention is gated on "a slash can still land": `!slotConsumed` (the load-bearing clause — a consumed slot admits no future flag) plus `pendingSlash==0` as defence-in-depth (implied: the carve follows the latch), and on Finalize also `decidedRounds==0`; SettleUndisputed correctly omits that last clause, being unreachable with a decided round (it panics on `round > 0`). The reserve returns at crystallize if unslashed | Returning the whole bond (the old behavior on both paths) makes the mill-slash unreachable on exactly the claims it targets; on the Finalize path this was the common case, since votingBlocks (7d) exceeds the escrow window so the flag resolves after finality |
| 36 | Inconclusive re-flag cooldown (v0.37, audit M3-MED) | 7-day cooldown after EVERY inconclusive cycle, not just past the freeze | Immediate reopens let a dust-low chain block crystallize for free; the cost is a 7-day wait for honest re-flags after an absent-electorate inconclusive (bond already returned) |
| 31 | Credential weight bar (v0.35.1, audit M2-1) | contested-and-upheld credits only when an upheld round's overturn side carried ≥ ¼ × quorum floor — weightless (self-manufactured) contests mint nothing; near-unanimous upholds also credit nothing | Dropping the bar re-opens credential farming at ~20% of a dispute bond per point; softening to the unfloored demotion bar prices it at idle-mill scale (~25 CC) instead of whale scale |

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

## Appendix B — worked end-to-end example (recomputed v0.20)

Same scenario as the original v0.8 example, all figures updated to the v0.20
rules (live-supply d, 0.85·y* amortized rate, comp min-rule, senior queue,
conditional fee). Court supply S = 10,000,000 CC; B_period = 10,000 CC/wk →
live d = 0.1%/wk; r₀ = 0.25%/wk; T_L/T_c = 1.5 → y* = 1.05%/wk;
**rate ≈ 0.89%/wk ≈ 0.127%/day per CC of conviction**; R has ~34,000 accrued.

**Claim**: "Flight 171's fuel switches were cut off before impact." Author
Alice opens it: 1 CC deposit + 0.1 CC fee, both escrowed (fee refundable —
v0.20: burns only on dead-no-stake or conclusive low).

| Day | Event | Pools (YES/NO) | Ratio |
|---|---|---|---|
| 0 | Alice stakes 30,000 YES | 30,000 / 0 | 100% |
| 7 | Bob stakes 20,000 NO | 30,000 / 20,000 | 60% |
| 14 | Carol stakes 10,000 YES | 40,000 / 20,000 | 66.7% |
| 21 | Dan (qualified record) answers YES; bond 50%·X̄ ≈ 30,000; staking freezes | frozen | 66.7% |
| 24 | 72h pass, no dispute, no flag → settle: verdict YES, quality mid (default), Dan's bond returns | — | — |

**Rate-weighted conviction at freeze** (rate ~flat over 24 days, so ≈
CC-days × rate): Alice 630,000 CC-days; Carol 70,000; Bob 280,000 (losing —
principal only).

**Draws at settle** (tier mid = 1×):
- g_Alice ≈ 630,000 × 0.127% ≈ **803 CC** (cap 0.5 × 30,000 — slack).
- g_Carol ≈ 89 CC (cap 1,667 — slack).
- D = min(Σg × 93/80, R) ≈ 1,037: winners 892, **author 89** (Alice, stake-capped
  fine), **answerer 56** (Dan — bond-based cap, v0.8; a stake cap would zero it).
- Voter carrot: none minted (no vote occurred).
- Fee: **refunded** (default-mid is not a conclusive low). Deposit back.
- **Total minted ≈ 1,037 ≈ 0.010% of supply.** Bob withdraws 20,000 whole.
  Escrow held 60,000 stakes + 1 deposit + 0.1 fee + 30,000 bond and returned
  every unit; emission never touched it. Conservation ✓.

**Returns check**: Alice ≈ +2.7% on 30,000 over ~24 days *for being right*
(≈0.89%/wk on conviction; a p-accurate staker's expected rate is p-scaled —
break-even p ≈ 0.59). A matched farmer earns the winner leg on half their
capital against 2× lock: negative, as designed.

**Alternative endings (v0.20 rules)**:
- *Flagged, SUPERMAJORITY low* (≥⅔ of turnout at the full verdict bar — where
  real junk converges): every tier-scaled slice = 0; Alice's deposit + fee
  burned AND **2.5%·X̄ = 1,500 CC slashed from Dan's answer bond** (v0.25 —
  answering junk is conduct); the flagger's bond returns plus a senior-queued
  bounty = min(1,200, 80% × 1,501) = **1,200 CC**; non-participant flag-vote
  voters split the carrot; all principals exit 1× — **principal is never
  pausable** (split settlement). *(A median-only low — the two-tier rule,
  v0.26 — zeroes the draws and slashes only the deposit; the bounty is then
  ≤ 80% × 1.1 ≈ 0.9 CC and no answer-bond slash occurs.)*
- *Disputed and overturned* (verdict flips NO): Dan's 30,000 bond **burns in
  full**; the disputer risked B_d = 20%·X̄ = 12,000 (zero-case rule: the
  answer-bond cap is 0 = uncapped, so B_d is plain 20%·X̄), gets it back plus
  minted senior comp = min(2×12,000, 80%×30,000) = **24,000 CC**; Bob's
  280,000 CC-days now draw instead; the 7% mid-gross voter carrot ≈ 62 CC
  splits among with-verdict voters, senior-queued, tier-invariant.

## 13. Changelog

Newest first.

- **v0.54 — a tier PROMOTION now needs a ⅔ mandate (HIGH); three reviewers rejected my
  first predicate.** `resolveQualityRide` wrote `cs.tier` with no authority test, and MID
  is reachable as a bare RESIDUAL, not a plurality: `applyQualityTally` returns conclusive
  MID whenever the full bar is met and low misses the weighted median, so
  `qLowW=49, qMidW=0, qHighW=51` classifies MID on **zero mid weight**. A mid bloc that is
  merely the largest therefore overturned a conclusive ⅔-low and restored `cs.tier` — and
  with it the WHOLE draw, since `tierLowX = 0` zeroes D outright. Priced at ~4%·X̄ net (a
  20%·X̄ bond burns on UPHOLD while `compAmount` mints 16%·X̄ back to the answerer) against
  a draw bounded by `maxMidGrossBps = 1927`, i.e. 19.27%·X̄. All three reviewers
  independently traced it as reachable on DEFAULT params, and one supplied the argument
  that settles whether to gate anything at all: **a mill already buying the round to
  rescue its reserve gets the tier re-roll at ZERO marginal cost.** Shipped predicate:
  `if cs.slotConsumed && tier > int(cs.tier) && bucketW(cs, tier)*3 < turnout*2 { return }`
  — a promotion out of an adjudicated tier must carry ⅔ of turnout in its OWN bucket, the
  same F3 shape `applyQualityTally` already imposes on HIGH and `ResolveCounter` on the
  rescue.
  **My first predicate was `turnout <= cs.conclusiveTurnout`, and 3/3 rejected it for
  three independent reasons.** (1) It is BYPASSABLE: `resolveQualityRide` rewrites
  `cs.conclusiveTurnout` unconditionally on any non-gated conclusive ride, including a
  same-tier re-confirmation, so a throwaway wallet voting LOW at exactly `demotionBar`
  resets the mark DOWNWARD (30 000 CC → 50 CC in the worked case) and the promotion lands
  the next round for one extra bond — total cost one bond and one week, with the SAME
  ~1.25·fullBar of weight the attack always needed. My comment's claim that "a promotion
  must out-turnout the tally it overturns" was therefore not what the code enforced.
  (2) It refused HONEST paths: a conclusive HIGH already requires `qHighW*3 >= turnout*2`
  — a STRICTLY STRONGER mandate than the residual MID it overturns — yet was refused on
  raw turnout alone, and on a minimum-escrow claim only one reopen fits, making the
  refusal permanent (≤19.27%·X̄ lost). Worse, a full-bar Q5 counter-poll the answerer WINS
  still lost the tier, because `CounterFlag` spends the ride's one wipe while
  `ResolveCounter` never writes `conclusiveTurnout`, so the later ride was measured
  against the FLAG's stale total with every counter-poll voter locked out by `qVoted`.
  (3) It was UNOBSERVABLE and opposition-dependent: `conclusiveTurnout` has no exported
  read, so an honest promoter had to burn a 20%·X̄ bond to discover the bar — and because
  the bar counts all buckets, opposition that stays home RAISES it.
  **Three claims of mine to correct.** The reserve, at `max(4.5%·X̄, 1.6·midGross)`, is
  the LARGER prize — greater than `midGross` for every input, and the 50%·X̄ bond clamp
  does not change it (30.83% vs 19.27% at the ceiling). I had said the tier was the larger
  of the two; that is backwards. "A draw up to 31.25%·X̄" was also wrong: 3125 bps is
  `mustInvariants`' headroom (`answerBondBps/slashDrawBps`), reached through the SLASH arm,
  not an achievable `midGross` — and that stray 1.6× is almost certainly where the
  inversion came from. And my "no rescue is affected on any branch" OVER-CORRECTED v0.52:
  the SLASH rescue is unaffected (verified independently by all three), but the TIER rescue
  was refused in exactly the `[fullBar, conclusiveTurnout]` band, so v0.52's objection was
  **mis-scoped, not false** — I was wrong in both directions on the same question, and the
  mandate form is what actually keeps the tier rescue open (a mid-only counter poll has
  `qMidW == turnout` and clears ⅔ trivially).
  **Method lesson, and it is the sharper one.** Three clauses need three fixtures. My
  first round of mutation testing verified the guard's EXISTENCE and silently missed both
  qualifiers: gating demotions passed the whole suite, and tightening the mandate to 3/4
  passed the whole suite. Only `TestUnmandatedDemotionRideStillLands` (a demotion at a
  low share in [1/2, 2/3), which a sole-low-voter fixture cannot express because it
  satisfies the mandate trivially) and `TestMandatedHighRidePromotesOverAStandingMid` (a
  high share in [2/3, 3/4), below the standing turnout so the old form would have refused
  it) make those clauses fail-detectable. All three now mutation-verified independently.
  **OWNER DECISION — the mandate test TAXES the attack, it does not close it.** It can
  only see the surviving tally, and the ride's one permitted wipe ERASES adjudicated
  weight; where the honest low bloc was wiped rather than out-voted, the survivors
  genuinely do show a ⅔ mid mandate and the promotion is allowed. The root cause is
  upstream of any authority test, and the three reviewers split three ways on it: the
  mandate form (two of three), an absolute public bar such as `turnout < 2·fullBar` (one),
  and a monotone `tierAuthorityW` field that a dust round cannot reset (one, as an
  alternative to its own mandate proposal). The two real options are (a) stop wiping the
  tally after adjudication at all, which changes §3.4's "exactly one re-ask" doctrine, or
  (b) the monotone mark, against which the absolute-bar reviewer's objection stands: a
  whale can set the mark arbitrarily high FOR FREE (vote LOW alone at the full bar with ⅔,
  where `ResolveFlag` returns the bond whole and pays a bounty) and then go silent,
  blocking an uncontested honest promotion forever — while Q2 bars the parties who benefit
  from a promotion from voting quality at all. Not picked unilaterally.

- **Item 4 (policing pay on drained claims) — CONVERGED 2/3 on NO-CHANGE, and my framing
  of the question was wrong in three specific ways.** Three identical-prompt econ vets.
  All three refuted the premise: (1) `midGross` **is** X̄-bounded — conviction is
  rate-weighted and `PostAnswer` refuses past the 12-week dead-claim timeout, so
  `midGross ≤ 19.28%·X̄`, the court's own `maxMidGrossBps`; (2) therefore
  `carrotTotal = 7%·midGross ≤ 1.35%·X̄ = 0.675·b₀`, and the carrot is a **pot**, not a
  per-voter entitlement (`share > carrotPool ⇒ share = carrotPool`) — so the WHOLE
  electorate together is paid less than one flagger's own bond, and "~999 CC each" is
  arithmetically impossible; at most one dominant voter approaches `b₀/2`, and only on a
  ≥8.9-week claim; (3) the two states are **disjoint** — an overturn always sets
  `decidedPID`, and `PullCarrot`'s first branch routes the whole carrot to the *verdict*
  round's with-verdict voters, so wherever quality voters are paid (`decidedPID == 0`)
  `answerBond > 0` and the flagger receives the full `b₀`. My "voter out-earns flagger"
  comparison cannot occur. Two further corrections: the flagger is NOT excluded from the
  carrot (`isParticipant` covers author/answerer/stakers only), and the T2 half-burn is
  gated on `answerBond > 0`, so on a drained claim every low outcome returns the bond
  WHOLE. "Drained AND flaggable" is reachable only post-OVERTURN, by exhaustion:
  `SettleUndisputed` and `Finalize` both retain `min(slashSizeFor, answerBond)` while
  `!slotConsumed`, and PostAnswer's collateralization floor guarantees the bond covers
  it. Both candidate fixes are worse than the status quo — re-basing the bounty re-opens
  the v0.25 faucet (~1000 CC minted per claim against 1.1 CC burned, bond returned whole,
  weight reusable, and the base doubles free through T1 inconclusive-lows), and re-basing
  the carrot clamp inverts F2 into a demotion cartel while barely biting, since the clamp
  is a corner case. **Dissent recorded:** one reviewer argued REBASE-BOUNTY on `midGross`
  specifically (not `slashSizeFor`, which is 3h-pumpable), on the ground that the flag's
  real product is cancelling the DRAW, which survives the bond burn. **The residual that
  actually matters, reprioritized above this one:** the v0.48 dust-low residual has its
  CARROT LEG UNPRICED. `answer.gno` already records that ~25 CC of weight can force a
  conclusive LOW and zero a ~7,012 CC draw *at a profit* because the flag bond returns
  whole below the full bar — and that residual counted only the 0.88 CC bounty, while the
  same sock also pulls up to `b₀/2 − 1` of carrot, ~1000× larger. P2's "voting to farm is
  strictly negative" holds for MID/HIGH-voting sybils and **not** for a LOW-voting
  self-flagger. Also registered: on a decided-round claim the marginal quality-ride tx is
  entirely unpaid (`originateSlash` passes `""` on a ride, and `PullCarrot`'s `decidedPID`
  branch pays verdict voters whether or not they voted quality), so the "free ride is the
  substitute for the flag lane" argument has zero marginal incentive behind it.

- **v0.52 — v0.51's latch was one latch too wide (HIGH, caught in the post-commit
  vet); the answerer's Q5 challenge is an INDEPENDENT poll again.** Two independent
  reviewers converged on the same defect in v0.51 as committed: `qualityReasked` was a
  single per-claim latch shared by `OpenDispute` and `CounterFlag`, so whichever fired
  first spent it — and a third party always fires first, **race-free**. `ResolveFlag`
  is permissionless, so the flagger submits `ResolveFlag` and `OpenDispute` at the same
  height; `CounterFlag` panics on `pendingSlash <= 0` before the first and on
  `disputeOpen` after the second, so there is no block in between in which the answerer
  could have acted. The severity comes from a property I had treated purely as a
  virtue: `qVoted` keys on `qVoteSeq|addr`, so a frozen seq **locks out every address
  that already voted**. An honest elector who changes their mind cannot, and their
  earlier low keeps counting against the answerer. §3.4's "a capture-whale must win ⅔
  TWICE, the second against maximal mobilization (p² ≈ 0)" presupposes the counter
  re-vote is an independent second poll; inheriting the ride's tally collapses p² to p.
  A reviewer's worked case (low bloc 0.80·fullBar + 0.38·fullBar) burns the reserve
  where the pre-v0.51 code refunded it — **same electorate, same weight, same beliefs**,
  the only difference being that one honest voter's earlier ballot is frozen. Fix:
  `CounterFlag` re-opens the tally UNCONDITIONALLY **and latches**. **The reviewers'
  literal one-line fix — wipe without latching — reintroduces the purchase, and my own
  v0.51 fixture is what caught it.** Both reviewers asserted the resulting budget was
  "one for the ride plus one for the answerer, strictly the doctrine"; neither priced
  ORDERING. Unlatched, the answerer takes TWO rolls by choosing the order: counter-flag
  first (roll one), watch the crowd re-confirm low, then sock-dispute to spend the
  ride's still-unspent wipe (roll two), erasing that low and voting mid alone over the
  bar — refunding the reserve for ~4%·X̄, the identical purchase v0.47, v0.50 and v0.51
  each closed at a different door. Latching bounds the budget to **at most one fresh
  tally per lane**: a sock that disputes first spends the ride's wipe and the answerer
  still gets their own poll; an answerer that counters first spends both, and every
  later round votes their accumulating tally.
  **CORRECTION to this commit's own message, which overclaimed.** I wrote "never two
  for one party". That is FALSE, and enumerating the three wipe sites against their
  gates shows why: post-adjudication the total is 1 if `CounterFlag` fires first (it
  latches, so the ride never wipes) but 2 if `OpenDispute` fires first (it latches, yet
  `CounterFlag` still wipes unconditionally — which is the whole point of the fix). The
  answerer's coalition can FORCE the second ordering with a sybil disputer, since the
  self-dispute guard is by its own comment "hygiene only (a sybil wallet trivially
  evades it)". So the answerer can buy BOTH polls — a ride poll plus their counter poll
  — for one dispute bond: net ~10%·X̄ on a quorum-less round (half the bond returns), or
  net ~4%·X̄ on an upheld round where the bond burns whole and comp pays back
  min(2·answerBond0, 80%·burned). Against a draw-proportional slash reaching 30.8%·X̄
  that is profitable optionality. Two things keep this a RESIDUAL rather than a
  regression: it is bounded at TWO polls, where pre-v0.51 every reopen wiped without
  limit; and it is not introduced here — post-v0.47 the answerer could always sock-
  dispute for a ride poll, so v0.51/v0.52 strictly narrowed it. Closing it properly
  means pricing the ride poll to the answerer rather than bounding the wipe, which is a
  dispute-bond question and belongs with the same econ vet as PLAN §12 row 30.
  Latching costs the answerer nothing they are owed, since their wipe is unconditional
  either way and `counterUsed` already bounds them to one challenge. Mutation-verified
  in BOTH directions, the two fixtures now pinning each other in opposition: drop the
  latch and `TestSockDisputeCannotEraseTheCounterTally` fails (the sock erases the
  counter tally); gate the wipe and `TestCounterFlagAlwaysGetsAnIndependentPoll` fails
  (the answerer inherits the ride). Neither error mode can slip through alone — which
  is the lesson: this defect and its fix are a matched pair, and a test for either half
  by itself would have passed the broken version. **Also closes**, per the same reviewer,
  a second path: the governor leaves `stateActive` BEFORE `p.closes` on three
  verdict-tally predicates (`governor.gno:1032/1050/1057`), so a whale could have spent
  the shared wipe on a ride with zero votable blocks; with the answerer's ballot no
  longer spendable, that buys nothing. **Vet results worth recording as PROVEN, not
  assumed:** STRAND none and CONSERVATION proven, by closure over every write to
  `pendingSlash`/`counterOpen`/`slashLevied`/`slotConsumed` — `counterOpen ⟹
  pendingSlash > 0` holds, the two closers partition all heights, and
  `counterVoteEnd = pendingSlashUntil` is load-bearing (shorter would leave a stretch
  where `ResolveCounter` is early and `ResolveSlashWindow` is blocked). FREEZE none: the
  new ride guard is the exact complement of `ResolveDispute`'s. And the first-mover
  poison I was most worried about **does not price out** — pre-seeding hurts the
  answerer only when the griefer's low weight exceeds `2·fullBar` (≥10% of court supply
  held non-staking), at which point they win the ⅔ contest outright and need no grief;
  below it, banked adverse weight counts toward the turnout bar the answerer must clear,
  so accumulation HELPS them. **Corrections to my own v0.51 comments:** the
  failed-quorum branch's claim that the reverse ordering "would strand in escrow with
  no later payout path" is FALSE — `refundSlash` has a `provClose` arm that pays the
  answerer directly, so both orders are safe and the ordering is a preference for the
  common path; and that branch scores the RESERVE only, deliberately not the TIER, so
  an identical full-bar non-⅔-low ride refunds while leaving `tier` LOW where a decided
  round promotes to MID. That asymmetry errs conservative in both directions it can err,
  and widening it moves draw money, so it stays pending its own econ vet. Documented the
  voter-facing rule neither v0.51 nor its reviewers had written down: across an
  accumulating tally an address's FIRST quality vote is its ONLY one, which changes the
  elector's optimal play on a ride to "commit once, late". **Residual:**
  `lastFlagEventAt` is not restamped on the two `ResolveDispute` dispose paths, unlike
  every other closer — harmless while `slotConsumed` bars a re-flag, but the 24h
  Crystallize quiet window is inconsistently maintained.

- **v0.51 — the TALLY WIPE was the re-roll (HIGH); the quality question is now
  re-asked exactly once and then accumulates.** v0.48 fixed a stranger's dispute
  spending the answerer's one-shot Q5 challenge by having `parkCounter` CANCEL the
  re-vote — clearing `counterUsed` — rather than spend it. That created the mirror
  defect: `counterUsed` became re-mintable on demand, so an answerer facing a settle
  could counter-flag, self-dispute through a sybil wallet to cancel it, and
  counter-flag again, indefinitely inside the escrow window. Chasing that exposed the
  larger one underneath it. **Every** dispute round and counter window called
  `openQualityTally`, which bumps `qVoteSeq` and zeroes the three buckets — a WIPE. The
  wipe, not any guard, was the re-roll: honest low weight that had already answered the
  quality question was ERASED rather than out-voted, so each reopen bought a fresh coin
  flip at the price of a dispute bond (~4 %·X̄, the same price v0.47 and v0.50 closed at
  two other doors), ~3× inside a 3-week escrow. After the reserve disposed, the prize
  grew: `resolveQualityRide` has no `!slotConsumed` guard, so a full-bar MID ride on a
  wiped tally promoted a settled LOW back to mid and restored the **whole draw**
  (`midGross`, ~86 % of it to the pool a mill controls) — strictly larger than the slash
  it was hunting. Fix: `qualityReasked`, a one-way latch making the wipe available AT
  MOST ONCE once anything has been adjudicated (`slotConsumed`); every later round and
  window votes the same ACCUMULATING tally. Accumulation is what converts the attack
  from erasure into out-weighing: `qVoted` keys on `qVoteSeq|addr`, so a frozen seq also
  freezes each address to one vote. `parkCounter` is deleted — its stated justification
  ("openQualityTally would silently discard the re-vote's votes") is discharged by the
  latch, since `counterOpen ⟹ qualityReasked` makes the wipe unreachable while a re-vote
  is live. What the answerer is owed on a round that decided nothing is the TIME, and
  `rearmSlashWindow` now returns exactly that by reopening the LANE
  (`counterOpen`, `counterVoteEnd = pendingSlashUntil`) while `counterUsed` stays true.
  Three further changes ship WITH it, not after, because accumulation makes each one
  load-bearing rather than cosmetic: (a) the dispute ride gains a vote deadline
  (`c.gov.State(proposalID) != "active"`) — under a per-round wipe a mempool-raced late
  vote died with its round, but a persistent tally would let transaction ordering rather
  than the electorate decide a reserve worth up to 30.8 %·X̄; (b) `ResolveDispute`'s
  failed-quorum branch now SCORES the ride (`disposeSlashOnRide`) instead of re-arming
  blindly — the VERDICT question failed quorum but the QUALITY question has its own,
  higher bar and can be answered on a round the governor's floor rejected, and a
  discarded full-bar rescue tally was then burned by the unconditional
  `ResolveSlashWindow`; a below-bar ride still re-arms, which is the v0.47 behavior
  verbatim; (c) `settleSlash`/`refundSlash` clear `counterOpen` above their early
  returns. **Method:** three identical-prompt subagents, iterated to convergence over
  three rounds (round 1 split A/B/A, round 2 A-OPEN/A-OPEN/OTHER, round 3 unanimous).
  Two facts were settled from code rather than by majority: `VoteQuality`'s three
  deadline guards are independent `if`s, so a lane left open past `counterVoteEnd`
  freezes quality voting for EVERYONE on the claim; and the doctrine is exactly one
  re-ask (§3.4 says so three times). Two of three reviewers independently derived the
  same sharpening — key the latch on `slotConsumed`, not `pendingSlash > 0`, since
  origination implies `slotConsumed` but not conversely, so the wider key also covers
  before-origination and after-disposal at zero extra state. **Rejected — WRONGLY; see
  v0.54, which adds it.** I rejected the third reviewer's authority ratchet in
  `resolveQualityRide` on the ground that it "would BREAK the legitimate rescue, since
  the one permitted re-ask starts the tally at zero, so a genuine full-bar rescue whose
  turnout lands between `fullBar` and `conclusiveTurnout` would be silently refused."
  **That reasoning is false, and it kept a HIGH out of the tree for two versions.** No
  rescue path reads `cs.tier` or passes through `resolveQualityRide` at all:
  `ResolveCounter` never calls it, and `disposeSlashOnRide` is a SEPARATE call scoring
  the buckets directly, invoked at `dispute.gno:237` (alone, on failed quorum) and
  `:310-317` (with `hadSlash` captured BEFORE the ride runs). An early return inside
  `resolveQualityRide` therefore cannot change any rescue outcome on any branch — which
  `TestBarePluralityRideCannotBuyTheTier` now demonstrates directly by asserting the
  refund happens on the very ride whose promotion is refused. The lesson for me: I
  reasoned about what the function was *named for* rather than tracing who actually
  reads its output. **Verification:** six guards
  mutation-verified (revert → the named test fails → restore); four new fixtures
  (`TestSockDisputeCannotEraseTheCounterTally`,
  `TestLapsedCounterLaneDoesNotFreezeTheRide`,
  `TestFailedQuorumRideAtFullBarLiftsTheSlash`, `TestRideVoteClosesWithTheRoll`), and
  `TestReopenSupersedesCounter` INVERTED — its `if cs.counterUsed { t.Fatal }` was the
  v0.48 defect encoded as a green test. **Honest gap:** the `counterOpen = false` inside
  `settleSlash`/`refundSlash` is UNREACHABLE today (every caller either clears the lane
  first or panics on it), so no mutation of it fails a test and it is defensive only. It
  stays because the failure it guards is unbounded rather than merely wrong:
  `Crystallize` panics on `counterOpen`, so a lane outliving its reserve would strand
  the claim's entire draw forever. **Residuals registered, not fixed:** the failed-quorum
  branch now settles a reserve on a full-bar ⅔-low ride WITHOUT recording the LOW tier
  (it never calls `resolveQualityRide`), an asymmetry the per-round wipe used to hide;
  and a full-bar ⅔-low tally riding a failed round still originates nothing while
  `slotConsumed` is false, leaving the pre-origination wipe lever untouched.

- **v0.50 — the ride lane could not levy a slash (HIGH, reproduced); origination and
  disposal now share one site.** A fresh sweep found, and I reproduced, that v0.47 shut
  `slashGrade`'s door to purchased immunity and left `resolveQualityRide`'s wide open.
  `pendingSlash` had exactly ONE origination site (ResolveFlag's slashGrade branch), while
  a conclusive ride latches `slotConsumed` — a one-way latch `OpenFlag` refuses forever. So
  **a full-bar ⅔-low verdict delivered on the RIDE permanently foreclosed the only path
  that could levy the slash it had just voted for.** The mill sock-disputes in the block
  after the answer (votingBlocks 7 d > settleDelay 72 h, so no flag can have resolved, and
  OpenFlag refuses while `disputeOpen`); the honest crowd then does exactly what the
  mechanism asks — upholds the true answer, votes the junk claim low — and thereby DESTROYS
  the slash. Measured: `pendingSlash=0` where 18 000 000 was owed. Price ~4 %·X̄ (the sock's
  burned dispute bond less minted comp) to avoid up to 30.8 %·X̄ — **v0.47's exact purchase
  through a different door**, again below the 4.5 %·X̄ flat floor. My blind spot precisely:
  v0.47 used "slotConsumed ⇒ ResolveFlag unreachable" as PROOF the `decidedRounds` clause
  was redundant and never asked whether the conclusive-ride branch was itself safe, and
  `TestDecidedRoundBuysNoSlashImmunity` asserts the ride is INCONCLUSIVE — scoped away from
  this exact state.
  **Three reviewers on identical prompts converged 3–0 on "let the ride originate"**, and
  each contributed a guard the others missed:
  - **`slashLevied`** — a one-way, exactly-once-per-claim latch across BOTH lanes. The flag
    lane was bounded by `slotConsumed`; the ride is not, so a reopen chain levied a fresh
    `slashSizeFor` out of the REMAINING bond every round (reachable inside a 3-week escrow:
    round 1 fails @7 d, flag resolves @14 d, window closes @21 d, reopen @21 d < 28 d).
    Mutation-demonstrated: without it a second 18 000 000 is carved from the 182 000 000
    remainder.
  - **`slashFlagger`** — the bounty beneficiary recorded AT origination. `settleSlash` must
    not fall back to `cs.flagger`, which on a ride path is either the zero address —
    `grc20votes.Mint` calls `mustBeValid` and PANICS, so the entitlement is unpayable
    forever while `reservedTail` (monotone, written only as `mustAdd`) has already advanced,
    permanently shrinking `reservoirR` for **every later junior draw in the court** — or a
    STALE flagger from an earlier inconclusive cycle whose bond already came back whole
    under T1, who would then mint a bounty for a slash the RIDE levied. I verified both legs
    (`mustBeValid` rejects the empty address; `reservedTail` has exactly one write site).
  - **the originate/dispose split** — `disposeSlashOnRide` scores a reserve the round
    INHERITED; one the round's own ride just levied gets its counter-flag window instead.
    Running both on the same tally settles the slash in the very call that levied it, with
    no window and no Q5 challenge. Mutation-demonstrated.
  Also shipped: a conclusive-LOW **ride now burns deposit+fee** like the flag lane
  (`burnConclusiveLowDust`, shared) — skipping them refunded the junk author at crystallize
  on exactly the claims the crowd demoted; and origination is a single shared
  `originateSlash` used by both lanes, so the two can no longer drift, the same "one sizer,
  two callers" discipline `slashSizeAt` established in v0.46. `tierFinal` stays false while
  a ride-levied reserve stands, preserving the answerer's one v0.31/Q5 counter re-vote.
  All four guards mutation-verified; `make check` + txtar green; **no existing test needed
  changing**, which is itself evidence no fixture had ever covered the ride's low path.
  **Registered, NOT fixed — three residuals from the same family, each needing its own
  vet:** (1) `parkCounter` clears `counterUsed`, the sole gate on `CounterFlag`, so an
  answerer's own sock can re-mint the one-shot Q5 challenge at ~4 %·X̄ a shot (bounded at
  3–4 by `escrowUntil`) — the v0.48 implementation vet found this, and `audit_m3_test.gno`
  currently ASSERTS the extra challenge as correct; (2) `slotConsumed` latches on a DUST low
  at the supply-floorless `demotionBar` in both lanes, so ~X̄/4 of sock weight self-flags,
  gets the bond back whole plus ~0.88 CC of minted bounty, and permanently disarms the
  full-bar slash at a NET PROFIT; (3) the quality RIDE has no vote deadline — `VoteQuality`
  guards `flagVoteEnd` and `counterVoteEnd` but not the dispute case, which since v0.48
  makes a ~30 %·X̄ decision a mempool race. Counting v0.47, that is **four doors to the same
  purchase**, which says the defect was never any single gate but that origination and
  disposal did not share a predicate — now they do.
- **v0.49 — the isolation guard was measuring less than half the system.**
  `scripts/check-isolation.py` kept its package list as a hand-maintained COPY of the
  Makefile's, and the two drifted: it staged 3 `p/` + 2 `r/` packages while
  `make realm-test` compiled 7 + 4. So **courtv2 — the realm under active development,
  every line of V2 — was never checked at all**, for its entire life, while the guard
  kept printing "all 151 tests across 5 packages pass alone as well as together". A guard
  that reports success while measuring nothing is worse than no guard; it is also the
  exact failure `make selftest` exists to catch, and no control was armed for it.
  **Fixed at the root:** the lists are now READ FROM the Makefile rather than copied, so
  drift is structurally impossible; if those loops ever move, the script exits loudly
  instead of quietly reading a shorter list. A dead `DEP` binding went with it. Coverage:
  **5 packages → 11, 151 tests → 343.** A new selftest control breaks the Makefile
  coupling on purpose and requires the guard to notice (verified it fires).
  **What the widened sweep found:** exactly one order-dependent test, and it was a
  genuinely vacuous assertion — V1's `TestDirectoryTiers` opened with
  `admin := DirectoryAdmin() // set across the suite`, depending on a NEIGHBOUR having
  created the first court. `directoryAdmin` is set to the first court's creator, so run
  alone the address the test calls `other` created the first court, became the admin
  itself, and the "a non-admin cannot curate" arm expected an abort that could never
  fire. It passed in company for the wrong reason. Now the test seeds the directory from
  a distinct address and asserts `admin != other`, so the arm can never silently
  degenerate again. Test-only: no V1 realm code touched. All ~190 newly-covered courtv2
  tests pass alone — worth stating, since many of them assert exact bond and slash
  arithmetic written during v0.40–v0.48.
  Final board: **all 343 tests across 11 packages pass alone as well as together.**
  **Two of the four v0.45 test gaps closed in the same pass**, both mutation-verified:
  - `TestFinalizeRetainsNothingAfterDustLowNoSlash` — Finalize's retention gate is
    `pendingSlash == 0 && !slotConsumed`, and the `!slotConsumed` half was never
    discriminated: every existing fixture either had `pendingSlash > 0` (which IMPLIES
    slotConsumed, so both clauses held together and neither was pinned) or an unconsumed
    slot. Only a conclusive flag that consumes the slot WITHOUT reserving a slash — a
    dust low — isolates it. Dropping the clause now withholds 22.5 M against a slash that
    can never land, and the test catches it. This is the Finalize twin of the exact
    non-discriminating shape the v0.44 vet caught in this session's own work.
  - `TestConclusiveLowBelowTwoThirdsHalfBurnsTheBond` — the T2 "failed slash attempt"
    branch had NO test: every conclusive-low fixture was either slash-grade (full bar AND
    ≥⅔ low) or below the full bar (dust low, T1 full return), so the band between them was
    never exercised. The new fixture sits at `qLowW/turnout` = 10/18 — median-low but short
    of ⅔ — at full-bar turnout, and pins that the flagger pays half the bond. (My first
    version asserted the wrong burn total; the supply also drops by the deposit+fee every
    conclusive low carries, independent of the slash question. Corrected against the
    measured 5.1 M rather than argued.)
  **Third v0.45 gap resolved — and it was not a missing test.** "The F9/Q7 bonus caps
  never bind in any fixture" turns out to be because they are **unreachable**, not
  because the fixtures are weak. `capBonus`'s bound is `tier·(positionRaw/openBlocks)/2`
  = HALF the position's time-averaged stake at mid tier (`tierMidX == 1`), while the
  gross it caps is conviction-scaled and bounded at ≤19.27%·X̄ over a 12-week life — the
  *same* 0.1927-vs-0.5 relationship that keeps the answer bond above the slash. The ratio
  `gross/bound` is `2·rate·openBlocks`, so binding needs `openBlocks > 1/(2·rate)` ≈ 1.1e7
  blocks ≈ **91 weeks**, far past the 12-week dead-claim timeout `PostAnswer` now
  enforces (v0.48). Measured at the most extreme legal shape — stake 100k CC, bank
  conviction, unstake (F9 keeps it), then age the claim 10 of its 12 permitted weeks so
  `openBlocks` dilutes `rawAvg` — the headroom is still **~9×** (bound 2.0e10 vs gross
  2.2e9). Higher tiers only double the bound. `TestF9CapHeadroomAtTheExtreme` pins the
  RELATIONSHIP rather than a number, so if rates, windows, or the timeout ever change
  enough to invert it, F9 starts binding honest positions and the test says so.
  (Methodology note worth keeping: the first version of this probe read the position's
  conviction BEFORE `WithdrawBonus`, which calls `accrue()` to settle it — the stale read
  was 0.15% low and made an equality assertion lie. Read settled state after the call.)
  **Fourth v0.45 gap closed, with a different answer from F9.** The P2 per-voter carrot
  clamp (`b0/2 - 1`) bites a sole voter when `carrotTotal` = 7%·midGross exceeds 1%·X̄,
  i.e. `midGross > 14.3%·X̄`. Measured on a cold court at 11 of the 12 permitted weeks:
  only **49%** of the clamp (carrotTotal 4.91e8 vs clamp 1.00e9). The limiter is not the
  claim's age but the RATE — `dEffBpsFP = min(curBudgetBpsFP, dReal)` where `dReal` is the
  EMA'd **realized** mint rate, so a single-claim court that emits almost nothing sits at
  the cold r0 (~63.8 bps/wk), and `emaMinted` decays by ¾ every roll so it cannot be
  seeded either. On a BUSY court at the hot rate `midGross/X̄ ≤ 19.27%` gives
  `carrotTotal` = 1.35%·X̄ against a 1%·X̄ clamp, so **P2 does bind in production** —
  unlike F9, which is unreachable at any rate. `TestP2CarrotClampBindsForASoleVoter`
  therefore asserts the cold-court measurement as a guard (if natural flow ever reaches
  the clamp, build the natural fixture) and then exercises the clamp directly by crafting
  a carrot above it. Mutation-verified: without the clamp the sole voter takes 3.00e9
  instead of 1.00e9.
  **All four v0.45 test gaps are now closed** — two by writing the missing fixture, two by
  establishing reachability first and pinning the relationship that governs it.
  Also corrected in this pass, both by verification rather than assumption: §12 row 30's
  provClose-reachability premise (false on any court past bootstrap — see the row) and
  v0.46's "the flag bounty does not rise under B" residual (stale — B fixed it; see the
  v0.46 entry).
- **v0.48 — the unslash leg: opening a dispute no longer forgives an adjudicated
  slash.** The second half of v0.47's hole, flagged by all three reviewers. `OpenDispute`
  called `unslash` UNCONDITIONALLY — before a single vote — so a **zero-vote,
  zero-weight failed-quorum dispute permanently destroyed a full-bar ⅔-low slash**, and
  `slotConsumed` was already latched so no replacement flag could ever re-arm it. Cost to
  the mill: half a dispute bond. Opening a round is not adjudicating one.
  **Shipped:** opening a round now only PARKS a running counter re-vote (`parkCounter`) so
  the ride tally can reset without silently discarding its votes — and parks it
  *cancelled, not spent*: `counterUsed` clears, so a stranger's dispute cannot consume the
  answerer's one v0.31/Q5 challenge. The round's OUTCOME then disposes the reserve:
  - **overturn** keeps its unconditional `unslash`, so the bond burns slash-inclusive (A19);
  - **uphold** is scored by `disposeSlashOnRide` on `ResolveCounter`'s EXACT test — the
    ride asks the slash's question at the same bars before a strictly larger electorate,
    so it *is* the counter re-vote: full bar with low short of ⅔ → refund; full-bar ⅔-low
    → settle; **below the bar → the reserve stands on a fresh window**. Never merely
    "conclusive", since `applyQualityTally` goes conclusive at the supply-floorless
    `demotionBar` — a dust ride must not be able to lift a full-bar slash;
  - **failed quorum** adjudicated nothing, so the reserve survives and only re-arms.
  Also fixed, newly reachable because a slash can now outlive the failed rounds provClose
  counts: `refundSlash` on a **provClosed** claim had no payout path at all
  (`provCloseClaim` already returned the bond and `Crystallize` refuses closed claims), so
  the reserve would have stranded in escrow forever — it now pays the answerer directly.
  Three stale-doctrine panic messages corrected ("a dispute supersedes the slash" is no
  longer true — its quality ride decides it), and the file header's "on an UNDISPUTED
  answer (v0.28)" claim retired.
  **Tests:** the two fixtures that encoded the old behavior are INVERTED, not deleted —
  `TestReopenDisputeSupersedesPendingSlash` asserted "the upheld bond returns whole, slash
  included", which was the attacker's payoff written as a green test. Added
  `TestReopenRideAtFullBarLiftsTheSlash` (the rescue arm still works — v0.48 did not make
  slashes unliftable) and `TestDustRideCannotLiftTheSlash`. All mutation-verified:
  restoring the unconditional `unslash` fails both inverted tests; weakening the full-bar
  guard fails the dust test.
  **A hypothesis I tested and DISPROVED, recorded so nobody re-derives it:** I suspected
  `resolveQualityRide` (which has no `!slotConsumed` guard) would let a dust-MID ride
  overwrite a full-bar conclusive LOW and restore the mid draw. It cannot — and the reason
  is a real invariant worth knowing: inside `applyQualityTally` the `demotionBar` enables a
  **low demotion only**, while any mid/high outcome requires the full supply-floored bar,
  so a dust ride is simply inconclusive. `TestDustRideCannotLiftTheSlash` now pins that
  asymmetry, because it is load-bearing: were promotions ever to become
  demotionBar-reachable, a dust voter could undo a full-bar junk verdict.
  `make check` + txtar green.
- **v0.47 — slash immunity was purchasable for ~4%·X̄ (HIGH); the `decidedRounds` gate
  deleted, by three-reviewer convergence.** `slashGrade` required `decidedRounds == 0`,
  so ONE decided dispute round retired the slash **permanently**. A mill bought that with
  a sock-wallet dispute it deliberately lost: the uphold burns the dispute bond, but
  `compAmount = min(2×answerBond0, 80%×burned)` refunds most of it, leaving a net cost of
  **~3–4%·X̄ against a slash worth up to 30.8%·X̄** — a 7.7–10.3× trade, break-even
  detection ~10–13% against the design's own q*≈0.22 target. Decisively, that price is
  **below even the 4.5%·X̄ flat slash floor** — cheaper than the smallest slash the system
  can levy — so buying dominated at every hold time, capping the entire v0.40
  draw-proportional deterrent at a flat ~4%. `VoteDispute` has no participant bar, and
  honest uphold turnout counts toward quorum, so the mill could need **zero weight of its
  own**. The repo already contained the fixture: `TestWeightlessContestEarnsNoCredential`
  builds this exact purchase ("imagine alice's second wallet") and asserts only that the
  CREDENTIAL is denied — the same round silently granted the SHIELD.
  **Decision:** three reviewers on identical prompts unanimously found the attack real and
  chose "sharpen the gate", then split 2–1 on the replacement; a second identical round
  converged **3–0 on deleting the clause outright**. The reasoning:
  - **It was redundant for every case v0.28 wrote it for.** A CONCLUSIVE ride latches
    `slotConsumed`, and `OpenFlag` panics on that (and on `disputeOpen`, with
    `OpenDispute` voiding any live flag), so `ResolveFlag` is *unreachable* once a round
    has judged quality. An OVERTURN zeroes `answerBond`, which the existing clamp turns
    into `slash == 0`. Its only live domain was an UPHELD round whose ride adjudicated
    **nothing** — exactly where immunity is unearned. All three verified this by
    enumerating `slotConsumed`'s write sites (two, both `= true`, none false) and every
    `answerBond` write.
  - **PLAN v0.28 itself calls the clause a "belt"** on top of the load-bearing
    supply-floored-bar + ⅔ "braces". A belt that costs ~4%·X̄ to unbuckle is a liability.
  - **The rejected alternative (gate on `!credEligible`) is worse than repriced — it is
    free.** A mill's junk-but-TRUE claim attracts an *honest* challenger who disputes and
    loses; that challenger's real weight (≥ floor/4) sets `credEligible` and hands the
    mill permanent immunity at no cost. It is also purchasable two-sidedly at zero escrow
    cost (sock-yes at exactly floor/4, sock-no larger, since 5001 bps keeps the uphold),
    and it welds a *reputation* predicate to a *security* gate. Verified by mutation: the
    new regression fails under `!credEligible` too, so it pins this choice, not merely the
    direction.
  Also rejected, unanimously: pricing the immunity (arithmetically impossible — the
  dispute bond is capped at 20%·X̄ by construction while the slash reaches 30.8%·X̄, so
  even comp = 0 cannot cover it) and a participant bar on `VoteDispute` (staked CC sits at
  escrow and never votes, so it touches none of the weight actually cast while
  disenfranchising the informed verdict electorate).
  **Shipped:** `slashGrade` (and the T2 free-roll arm) now ask "was a slash ever in
  reach?" directly as `answerBond > 0` — which also preserves the documented T2 intent the
  bare deletion would have lost, without the purchasable clause. Finalize's retention gate
  drops the same clause in **lockstep** (else the whole bond returns and the later slash
  clamps to zero — M3-HIGH-1's shape on the path a mill now targets), which as a bonus
  makes it *character-identical* to `SettleUndisputed`'s, closing the sibling asymmetry
  that produced v0.42 and v0.43. `TestDisputeUpholdPath` updated: an upheld bond now
  returns less the reserve, the remainder at crystallize. Mutation-verified three ways
  (old gate → slash leg fails; `!credEligible` → slash leg fails; lockstep reverted →
  Finalize leg fails). `make check` + txtar green.
  **NOT yet fixed — the second leg, next commit:** `OpenDispute` calls `unslash`
  UNCONDITIONALLY, before any round is decided, so a zero-vote failed-quorum dispute still
  permanently destroys an already-adjudicated slash while `slotConsumed` stays latched so
  no replacement flag can re-arm it. All three reviewers flagged it; the converged shape is
  to stop forgiving at OPEN and let the round's OUTCOME dispose the reserve, with an
  upheld round's ride scored on `ResolveCounter`'s exact test (full bar, low short of ⅔) —
  never merely "conclusive", since `applyQualityTally` returns conclusive-LOW at the
  supply-floorless `demotionBar`.
- **v0.46 — the drain: X̄ divorced from conviction (HIGH, confirmed + reproduced), fixed
  by three-reviewer convergence.** A fresh adversarial sweep found, and I reproduced with
  exact numbers, that the v0.40 anti-mill slash could be **nullified by one extra
  transaction**. `slashSizeFor` = max(4.5%·X̄, 1.6×midGross) is CLAMPED to the posted
  answer bond; midGross is the answered side's LIFETIME conviction, but the bond was
  sized off a 3-HOUR trailing average of stake — and `Unstake` is permissionless, free,
  and KEEPS conviction by design (F9). Stake 100k CC → hold 11 weeks (under the 12-week
  dead-claim timeout) → unstake to minAnswerX → wait 2h for the ring to forget → answer:
  **bond 50 CC against 11_220 CC of earned slash exposure, a 224× shortfall.** Break-even
  detection probability moves from ~0.385 to ~0.99 — profitable even at 90% detection.
  This is NOT the accepted idle-capital residual (which assumes the slash reaches
  1.6×midGross; here it never does). It also falsified the `mustInvariants` deploy bound
  at RUNTIME, where a check over constants cannot see it.
  **Decision process:** three independent reviewers on identical prompts split 2–1
  (A-only vs A+B) in round 1; a second identical round on the single open question
  converged **3–0 on A+B**. What flipped it: (1) the base was a **units mismatch** — the
  invariant's identity midGross/X̄ = rate·T_c is valid only when X̄ *is* the lifetime
  average, since midGross is a lifetime integral, so B makes the deploy check TRUE by
  construction rather than merely re-labelled; (2) A **removes the mill's reason to
  drain**, so the post-fix drained population is honest rotations while a mill simply
  doesn't drain — A-only's "cheap policing" is evadable by the adversary and unavoidable
  by the honest; (3) the drain **un-escrows** the attacker's weight (escrowed stake is
  netted out of `votable` and barred from the quality lane by `isParticipant`), so the
  same act that lowers every bar hands the attacker the weight to clear them; (4) the
  injured stakers are **disenfranchised** — `isParticipant` persists across withdrawal,
  so those whose draw is being zeroed may not vote, and the 7-day flag vote outlives the
  72-hour dispute window, so there is no rescue.
  **Shipped (A):** a collateralization floor in `PostAnswer` on the FULL sizer via a
  SHARED function (`slashSizeAt`) that `ResolveFlag` also uses, so "the bond
  collateralizes the slash" is enforced by shared code, not two parallel arithmetic paths
  a drain can pull apart; `touch`/`advancePools` hoisted above it (load-bearing — else
  the floor reads stale conviction); the floor applied AFTER the court cap deliberately
  (an uncollateralized slash is worse than an over-large bond). Flooring the WHOLE sizer,
  not just the draw arm, closes a trap that is inert only while `answerBondCapCC` is 0.
  **Shipped (B):** `xBarFrozen = max(3h trailing, lifetime time-averaged total stake)`,
  wholesale — P6's "one base" preserved, no split (the P2 carrot clamp is derived against
  `flagBondFor`'s b₀ and `disputeBond0`'s arms couple through `answerBond0`;
  desynchronizing them re-opens the base-shopping class this bug came from). Provably a
  no-op wherever total stake never decreased, so it binds only on a drain — confirmed
  empirically: the entire pre-existing suite passes unchanged.
  **Also shipped:** a dead-claim answerability gate — `CloseDeadClaim` is permissionless
  but OPTIONAL, so conviction kept accruing on an unclosed claim and past ~19.5 weeks the
  draw arm crossed the bond **on a perfectly constant pool**, no drain required; and
  `mustInvariants` demoted to a CALIBRATION with its missing flat-arm check added.
  Every guard is mutation-verified: removing B fails its test while the original drain
  repro still passes without B (proving A and B cover different ground and no single
  fixture could pin both). `make check` + txtar green.
  **Registered residuals** (named, not hidden): B raises `quorumFloor`/`fullBar` ~2× and
  pins `escrowWindow` at its cap on drained claims. **Corrected v0.49:** the claim that
  "the flag bounty does NOT rise under B" is imprecise and was carried over from the
  pre-B analysis. `bountyFor(bond, burns)` caps at the flagger's OWN bond
  (`flagBondFor` = 2%·X̄frozen), and `PullCarrot`'s per-voter clamp keys off the same
  `b0` — so once B redefined `xBarFrozen` as `max(3h, lifetime)`, **both** the carrot
  AND the slash-path bounty price off the honest lifetime size on a drained claim. Only
  the DUST-LOW branch stays pinned at 80%×(deposit+fee), and correctly so: no slash
  burned there, so there is nothing to pay a bounty out of. Policing pay on drained
  claims is therefore resolved by v0.46, not an open residual; a self-dispute-upheld path buys a mill
  permanent slash immunity for ~4 CC net (`decidedRounds=1` gates `slashGrade` off)
  — its own finding, not addressed here; and §12 row 30's "small claims cap at 2 failed
  rounds" premise is false on any court with real `minted`, since `escrowWindow` is
  already pinned at its 3-week cap.
- **v0.45 — test-gap sweep: pinning guards that would have survived deletion.** A
  dedicated completeness critic asked not "is the code right" but "which guarantees are
  UNPROVEN — which guards would survive being deleted?" It found several money-path
  guards standing behind fixtures that satisfy every clause at once and therefore pin
  none of them — the same non-discriminating shape the v0.44 vet caught in this
  session's own regression. **No source logic changed; these are proofs, not fixes.**
  Every item below was verified by explicitly mutating the guard and confirming the new
  test fails (and, where noted, that the old one did not):
  - **A decided verdict cannot be silently flipped back** (highest value). TWO separate
    permissionless entrypoints could reassign `provisional` from the overturn winner
    back to the answer, redirecting the entire winners' slice and locking the true
    winners out of `WithdrawBonus` — and both guards were unpinned. `SettleUndisputed`'s
    `disputeOpen || round > 0`: the only fixture settled while the dispute was OPEN, so
    both clauses held; since `disputeOpen ⟹ round > 0`, only a RESOLVED round isolates
    the load-bearing clause. `ResolveDispute`'s `if firstResolution` in the
    failed-quorum branch: every fixture already had `provisional == answer`, making the
    assignment a no-op and the guard invisible. `TestOverturnedVerdictCannotBeFlippedBack`
    drives overturn → refused settle → failed reopen → finalize → crystallize and
    asserts the verdict holds at each step AND that the money follows it. Both mutants
    die.
  - **`Crystallize` refuses while a slash is in flight.** The gate
    `flagOpen || counterOpen || pendingSlash > 0` had NO test at all. Without it,
    crystallize would zero `answerBond` mid-slash and a later winning counter-flag
    (`refundSlash` credits the reserve back) would restore coin to a field nothing pays
    out again — stranding it in escrow permanently. `TestCrystallizeRefusesWhileSlashPending`
    reaches the state where the pending slash is the ONLY remaining blocker (the 24 h
    quiet window closes ~6 days before the counter window), asserts the refusal, then
    closes the window and proves escrow drains to zero.
  - **The burned deposit cannot resurrect.** `TestCrystallizeLowTierZeroDrawCarrotStillPays`
    asserted `cs.deposit == 0` after crystallize — trivially true in both worlds, since
    Crystallize zeroes the field *after* paying. So dropping the burn-site zeroing would
    have refunded an already-burned deposit to the author **out of staked principal**,
    invisibly. Now asserts the author's balance and total supply are unchanged across
    Crystallize, plus escrow drains to zero. The old assertion did not catch the mutant;
    the new one does.
  **CORRECTION — the isolation guard measures less than it claims.**
  `scripts/check-isolation.py`'s `REALMS` list stages only 3 `p/` packages
  (checkpoint, grc20votes, governor) and 2 `r/` realms (govern, offerer), while its own
  comment says "everything `make realm-test` compiles" — which is 7 `p/` + 4 `r/`,
  **including courtv2**. So its cheerful "all 151 tests across 5 packages pass alone as
  well as together" has never included the V2 realm, and earlier changelog entries
  citing isolation as cover for courtv2 work (v0.42–v0.44) overstated it; the line in
  v0.44 is corrected in place. Nothing regressed — the claim was simply weaker than
  written. Registered as the next tooling fix (extend `REALMS` to the full realm-test
  set, then work through whatever order-dependence it exposes). Note also that
  `make isolation-test` currently fails outright for an unrelated environmental reason:
  a second worktree (`cryptocourt-mod`, branch courtv2-moderation) stages into the SAME
  `$GNOROOT/examples/.../cryptocourt` path and `rm -rf`s it on exit, deleting this run's
  staged tree mid-copy. Per-worktree GNOROOT (or staging dir) is the durable fix.
  Remaining registered gaps from the same sweep (lower value, none a known defect): the
  F9/Q7 bonus caps never bind in any fixture; the conclusive-low half-burn branch
  (full bar, low in [½, ⅔)) is untested; `Finalize`'s `!slotConsumed` reserve clause has
  the same non-discriminating shape as the settle one did (timing-only money); the P2
  per-voter carrot clamp never binds.
- **v0.44 — retention symmetry closed, and a mutation-tested guard.** With v0.43 shipped,
  `SettleUndisputed` was left the *less* precise sibling: it retained a reserve
  unconditionally, including when the flag slot was already consumed or a slash was
  already carved out — states where no further slash can ever land, so the retention was
  pure lockup of the answerer's coin until crystallize. Now gated `pendingSlash == 0 &&
  !slotConsumed` (no `decidedRounds` clause: that path panics on `round > 0`). **Not a
  security change** — totals are identical in every branch and the coin always returned
  at crystallize; this moves timing only, and it removes the sibling asymmetry that
  produced both v0.42 and v0.43. Adversarial vet: the CODE was proven correct on all six
  questions — the latch is real (`slotConsumed` has two writes, both `= true`, none
  false), a post-settle slash is impossible (both forfeiture routes shut: `slotConsumed`
  closes the carve, `verdictAt != 0` closes the overturn burn), conservation is
  exactly-once in every branch, and **the deterrent is provably not weakened** (retention
  is skipped only where the coin was already unslashable; the counter re-vote can't be
  bought with the early-returned coin either, since its weights read the sealed
  `qualityEpoch` pinned at PostAnswer). But the vet returned **INCOMPLETE on the proof
  surface**, and it was right: `pendingSlash > 0` *implies* `slotConsumed` (the carve
  follows the latch on one straight-line path), so the first regression satisfied both
  clauses and could not tell them apart — the load-bearing `!slotConsumed` was untested,
  and deleting it still passed. Fixed with a fixture that isolates it: a **dust low**
  (quarter-bar, below the full bar) consumes the slot with **no** slash reserved.
  Verified by explicit mutation — with `!slotConsumed` deleted, the old test PASSES and
  `TestSettleRetainsNothingAfterDustLowNoSlash` FAILS. §12 row 35 restated around the
  real invariant ("a slash can still land"), naming which clause carries it and which is
  defence-in-depth. `make check` + txtar green, and `make isolation-test` green —
  **but see the correction in v0.45: that guard does NOT stage courtv2**, so it never
  covered any of this work. The mutation checks, not isolation, are what carry these
  claims.
- **v0.43 — the SECOND Finalize twin: the missing slash reserve (HIGH), fixed +
  vetted.** The v0.42 vet surfaced an orthogonal twin in the same function, found by
  chasing the same meta-pattern ("a guard added to one sibling but not the other").
  `SettleUndisputed` retains a slash-sized reserve out of the answer bond through the
  quality slot (M3-HIGH-1, whose own comment warns "returning the whole bond here let
  the slash clamp to zero") — but `Finalize` refunded the bond **whole**. A claim that
  reaches finality through FAILED dispute rounds keeps `decidedRounds == 0` and so is
  still slash-eligible (`slashGrade` gates on exactly that), and since votingBlocks
  (7 d) exceeds the escrow window the conclusive-low flag typically resolves AFTER
  Finalize — so the slash clamped to a zero bond and the mill paid **nothing**. This
  was the common case on that path, not an edge. D = 0 still held throughout and no
  funds were ever misdirected: the loss was the deterrent itself. FIX: mirror the
  sibling's retention, gated `pendingSlash == 0 && decidedRounds == 0 &&
  !slotConsumed`. Proven load-bearing — `TestSlashSurvivesFinalize` (twin of
  `TestSlashSurvivesSettle`) fails `answerBond=0 want 22500000` without it. Adversarial
  vet: **FIX-CORRECT-AND-COMPLETE**, with a proof worth recording — `slashSizeFor` is
  *provably immutable* after the answer (PostAnswer advances the pools BEFORE pinning
  `frozenAt`/`rateAccAtFreeze`, so every later `advancePools` delta is exactly 0, and
  Stake/Unstake panic post-freeze). Hence the reserve computed at Finalize and the slash
  computed at ResolveFlag are identical **including under the clamp**, so a retained
  reserve can never come up short. The vet also proved no strand (every crystallize
  blocker has a permissionless closer, and the 7-day re-flag cooldown exceeds the 24 h
  quiet window), no double-pay, and that overturn is double-locked out of retention
  (`answerBond = 0` AND `decidedRounds++`). Its one correction is folded in: the
  original gate lacked `!slotConsumed` and so withheld a second reserve after an
  already-settled slash — money that still returned at crystallize, but needlessly late.
  §12 row 35 updated (retention is now a property of BOTH terminal paths).
  `make check` + txtar-test green. (The residual it left — `SettleUndisputed` being the
  *less* precise sibling — is closed in v0.44 below.)
- **v0.42 — convergence re-sweep: the Finalize tier-reset twin (HIGH), fixed +
  vetted.** Per "any applied change resets the sweep," a fresh holistic pass after
  v0.41 re-vetted the math commit SAFE and found a genuine HIGH: `Finalize`
  (dispute.gno) reset the quality tier guarded only by `!cs.tierFinal` — the
  UNTREATED TWIN of the v0.40 `SettleUndisputed` fix (session.gno, which got
  `&& !cs.slotConsumed`). Reachable exploit: a mill's junk claim survives a FAILED
  dispute round (which keeps verdictAt=0/decidedRounds=0), is flagged slash-grade
  conclusive-LOW (which leaves slotConsumed=true but tierFinal=false for the
  counter-flag window), then `Finalize` runs in that window and clobbers the tier
  LOW→MID → the junk claim draws full mid-tier emission at Crystallize, breaking the
  D=0 invariant the tier-low mechanism exists to guarantee. FIX: mirror the sibling
  guard exactly (`if !cs.tierFinal && !cs.slotConsumed`). Proven load-bearing —
  regression `TestConclusiveLowSurvivesLateFinalize` fails on the exact tier-clobber
  assertion with the guard reverted, passes with it. Adversarial vet:
  **FIX-CORRECT-AND-COMPLETE** — tierFinal/slotConsumed are one-way latches, so the
  new clause is dead for every conclusive mid/high/non-slash outcome (all already set
  tierFinal=true) and live ONLY for slash-grade-low (where tier must stay low); no
  third unguarded quality-tier site (directory.gno's `Court.tier` is unrelated
  curation state); the slash-window closers touch only tierFinal, and the
  bond/coin accounting is untouched. `make check` (11 suites + doc guards) +
  txtar-test green. The vet surfaced a SECOND, orthogonal twin — `Finalize` refunds
  the FULL answer bond with no slash reserve (unlike SettleUndisputed's M3-HIGH-1
  retention), so a claim flagged slash-grade-low AFTER a failed-round Finalize
  slashes nothing (a deterrent gap; D=0 still holds and no funds are mis-sent) —
  registered as the next convergence round.
- **v0.41 — adversarial overflow/underflow math audit (owner-directed).** A
  dedicated fresh-eyes pass over every arithmetic site — `×Bps`, `×10000`,
  `×2`/`×3`, all subtractions, the u128 conviction integrals — from an attacker's
  angle. Verdict: **0 CRITICAL, 0 HIGH, 1 MED, 6 NOTE.** The load-bearing safety
  story held up: `mustInvariants` caps `curveCap` so total supply can never exceed
  ≈ MaxInt64/Bps, which is what makes every supply-derived `×Bps`/`×10000` product
  fit int64 — and every silent-wrap subtraction (reservoir lanes, emission
  queue) was already guarded. The audit's one real correction to my own model:
  **conviction (the `convToCC` result) is stake × TIME, so it is NOT bounded by
  supply** — a whale on a long-open claim can push it past MaxInt64/10000, and it
  is the single quantity that can. That made two bare conviction×constant sites
  reachable-in-principle wraps, both now on the 128-bit path the winner-share and
  slash-draw arms already used, no money-path logic changed:
  - **MED-1 — `pct` (render).** `num*10000/den` wrapped negative at conviction
    scale (a display ratio, so cosmetic, but it renders garbage). Now
    `mulDiv128(num, 10000, den)` with a `num < 0` guard; `num ≤ den` here so the
    result stays ≤ 10000. Regression `TestPctNoOverflowAtWhaleConviction` crafts a
    ~7e18 numerator and asserts a sane percentage.
  - **NOTE-2 — `carrotTotal` (crystallize).** `midGross*splitCarrot/100` where
    `midGross` is conviction → `mulDiv128`; a wrap here would otherwise surface as
    a `PullCarrot` panic only at ~millennia scale.
  - **NOTE-6 — `mulDiv128` (stake) honors its contract.** The `hi < den` guard
    bounds the quotient to uint64, but a value in (MaxInt64, 2^64) would still
    wrap silently through `int64(q)`. Now it panics — unreachable at bounded
    inputs, but the discipline is fail-loud, never silent-wrong.
  NOTE-3/4/5/7 are millennia-scale defensive panics or already-documented-handled
  (no change). Gate green: `make check` (all 11 suites + citation/docnumber/storage
  guards) and the staged `courtv2` suite. No economic behavior changed — this is
  overflow-hardening of a display path plus two extreme-scale defensive panics.
- **v0.40 — draw-proportional anti-mill slash (owner-directed, three-designer
  convergence).** The P7 residual — a patient/idle-capital mill's punishment
  didn't track its hold-time-scaled draw — is now closed on the reachable
  (design-carry) axis. Three independent designers converged on
  `slash = min(bond, max(4.5%·X̄, k·midGross))`, k=1.6, where midGross =
  convToCC(winning=answer-side pool conviction) — the mill's counterfactual
  mid-tier take (the realized draw is 0 on a conclusive-low since tier→0, so
  the deterrent scales with the FORGONE draw). Computed from frozen conviction
  so the settle-time reserve and the flag-resolve slash are identical by
  construction; clamped to the posted bond; a new deploy invariant proves the
  draw arm fits under the bond at the hot-rate 12-week max (3083 ≤ 5000 bps).
  Effect: patient 12-wk mill q* 0.45→0.22, the whole hold-time curve flattened;
  fast claims unchanged (floor binds); A19 bounty still own-bond-capped;
  honest claims and the slashGrade trigger untouched. Owner DECLINED the
  reward-vesting transferability lever (§12 row 5, same session). Accepted
  residual: idle-capital q* floors at ~0.27 (answer-bond ceiling — V3
  weight-at-risk frontier, not closable by a bigger k). Adversarial code-review
  of the diff: **CLEAN (0 HIGH/0 MED)** — it confirmed exactly-once across both
  settle/flag orderings, two-site sizer consistency, overflow safety, the A19
  cap, and the clamp. It also surfaced a PRE-EXISTING LOW the resize made
  relevant and now fixed: **SettleUndisputed reset a conclusive-low tier back
  to mid** when a flag resolved before settle (both permissionless, overlapping
  windows) → the junk claim paid full mid emission; guarded with
  `&& !cs.slotConsumed` so a conclusive quality outcome is never clobbered
  (regression TestConclusiveLowSurvivesLateSettle). Two INFO items accepted as
  pre-existing/safe (the deploy invariant's midGross bound is exact for the
  ≤12-wk case, runtime clamp handles beyond; slashGrade after failed-only
  dispute rounds routes through Finalize).
- **v0.39 — P7 economic question RESOLVED (econ-vet); V2 economically closed.**
  The last open economic pin — does the 20% hot rate make the author-mill
  profitable? — got a dedicated econ-vet. Verdict: the mill's **edge over
  honest staking is negligible** (cap-bounded ≤ ~2.5 CC/claim) and erased at a
  detection probability of q\* ≈ 0.045–0.10, well inside what the paid flag
  lane supplies; the ~19%·X̄ P7 flagged is a gross draw (= the intended p=1
  staker reward), not net profit, fully forfeitable on a conclusive-low flag.
  **minAnswerX stays 100 CC** (proven the wrong lever — q\* ~invariant to it),
  **deposit stays 1 CC** (a 1→5 bump is registered as an owner-available lever,
  §12 row 37, but taxes honest thin-claim openers for a non-exploit). The
  genuine residual — the patient/idle-capital mill's absolute EV (q\* ≈ 0.22
  typical → 0.45 at the 12-wk edge) — is **structural and pre-existing** (≈0.44
  at the old ceiling); its real fix is a draw-proportional slash (§12 row 28b,
  V3 frontier, needs its own vet), out of P7's named lever. Two doc/code nits
  the vet surfaced, both fixed: crystallize's 80/93 winner split is intentional
  (~16% more conservative than §3.5's gross-up prose — a protective comment now
  says so, §3.5 corrected) and the true honest break-even is p ≈ 0.68 not 0.59
  (ECONOMICS.md corrected). No money-path logic changed. **All economic
  questions in the attack ledger and pin list are now closed or registered as
  V3-frontier; V2 is code-complete, audit-clean, and economically resolved.**
- **v0.38 — LAUNCH GATE CLEARED.** The final full-system adversarial audit
  (whole system, fresh eyes, cross-module + court-global conservation) returned
  **0 CRITICAL, 0 HIGH, 1 MED, 2 accepted NOTEs**, and re-verified every prior
  fix holds with no regression — including the highest-value re-check, the
  court-global emission-conservation invariant `emittedTotal ≤ cumAccrual`
  across an adversarial multi-claim interleave (proved by disjoint number-line
  tiling + probe). The one MED, fixed FIX-FIRST: **an overturned (wrong)
  answerer still drew the 5-point answerer emission slice** — the author slice
  is gated on winning-side skin but the answerer slice wasn't; on overturn the
  bond is burned and the record reset, so minting a slice contradicted §3.5 and
  Appendix B's own worked example. Fix: `drawAnswerer = 0` when
  `provisional != answer` (unclaimed points stay unminted — conservative). The
  two NOTEs are accepted/registered: `juniorReserved` monotonicity (§12 row 33,
  bounded + solvency-safe) and the inherited ~56-concurrent-dispute governor
  cap (N4). Regression: TestOverturnedAnswererDrawsNoSlice. Green across unit +
  check + txtar + isolation. **V2 is code-complete and audit-clean — the launch
  target.** Next: owner-directed continuous single-improvement hunting.
- **v0.37** — (iterations 16–18) **milestone-3 audit ingested (1C/1H/1M/1L),
  all fixed FIX-FIRST with regressions; full system green (unit + check +
  txtar + isolation 151 tests).**
  - **CRITICAL — reservoir double-spend.** `reserveJunior` added to
    `juniorReserved` but never advanced `reservedTail`, so a senior enqueued
    AFTER a junior draw (the carrot always is; later comps/bounties too) got
    `start = reservedTail`, overlapping accrual the junior already minted —
    `PullSenior` re-paid it and `emittedTotal` passed `cumAccrual`, breaking
    the 20%/yr ceiling. Fix: `enqueueSenior` start = `reservedTail +
    juniorReserved`, so seniors and juniors tile the accrual number line
    disjointly (pre-crystallize juniorReserved==0 → unchanged; milestone-1/2
    tests untouched). Latent until crystallize created the junior lane.
  - **HIGH — the 4.5%·X̄ slash was escapable via SettleUndisputed.** Settle
    returned the whole answer bond at 72h; `votingBlocks` (1wk) > `settleDelay`
    (72h) meant a flag could never resolve first, so the slash clamped to
    `min(4.5%·X̄, 0) = 0`. Fix: settle now RETAINS a slash-sized reserve in the
    bond (returning the rest), collateralized through the quality slot exactly
    as the dispute path keeps the bond through escrow; the reserve burns on a
    conclusive-low slash or returns to the answerer at crystallize.
  - **MED — free indefinite Crystallize grief** via a dust-low flag chain
    (T1 full-return, back-to-back reopens, participants excluded from
    self-defense). Fix: the 7-day re-flag cooldown now applies after EVERY
    inconclusive cycle (not only past the freeze); since 7d > the 24h
    Crystallize quiet window, each inconclusive leaves a ~6-day settle window
    the griefer cannot fill. Honest re-flag after an absent-electorate
    inconclusive waits 7d (bond was returned) — accepted, §12.
  - **LOW — reopen dispute vs open counter re-vote.** `OpenDispute` didn't
    guard `counterOpen`; a reopen reset the counter's tally. Fix: a reopen now
    `unslash`es (refunds the reserve into the bond, closes the counter) before
    opening its ride tally — a disputed answer is never slashable (v0.28); plus
    a `!disputeOpen` guard on `ResolveCounter`. Exactly-once held throughout.
  - Cleared with probes by the auditor: pool-integral exactness / no
    overdraw, carrot conservation + weight match, quality-vote integrity
    (epoch pin, participant exclusion, no key collision), exactly-once across
    all deposit/fee/bond sites, overflow guards, auth/borrow. **M2-1 verified
    effective** (credential priced at ~1.25%-of-supply weight). NOTES accepted:
    decided-route carrot disenfranchises flag voters (by design P14),
    `ConvictionOf` read-preview tail approximation (cosmetic).
- **v0.36** — (iterations 13–15) **the quality milestone is BUILT — every
  module of the §10 build order now exists.** Landed: rawConv ∫stake·dt cap
  accumulators + qualityEpoch pin (Q1/Q7 prereqs); quality.gno part 1 (sealed
  3-bucket court-local tally at the pinned epoch, participant exclusion, flag
  slot machine with doubling→4×b₀ freeze + close-anchored 7d cooldown, the
  full Q4 outcome table incl. T1 full-return and T2 half-burn, dust-low
  dispositions with burn-dominated bounty, slash RESERVE) and part 2 (the
  counter-flag window: CounterFlag = the answerer's one forced re-vote —
  slash falls only at fullBar-reached + ⅔-low missed; ResolveSlashWindow;
  settleSlash bounty top-up; the `unslash` hook — a DECIDED dispute round
  refunds the reserve into the bond BEFORE disposition); crystallize.gno
  (Q6-Q8: quiet-24h + participant-week gates, walk-free draw D = min(tier ×
  midGross, G_MAX, R), 80/8/5 slices, scale-then-cap pull-claims under
  (tier/2) caps, tier-invariant senior carrot with the per-voter b₀/2−1
  clamp, N1 deposit/fee disposition). Three build-time finds, fixed in place:
  (1) **an open flag could blockade the 72h dispute window** — a dispute now
  VOIDS an open flag (bond whole, slot unconsumed; the ride carries quality);
  (2) **position-fed pool integrals undercounted at crystallize** (early
  pullers would overdraw D) — pools now advance analytically from side
  totals (advancePools), exact at every mutation boundary; (3) **settle/
  finalize stamped default-mid over final conclusive-low tiers** — guarded.
  Carrot is ReleaseRoll-immune via court-side choice records; weights
  recompute from PastVotes at the proposal's epoch. The reservoir's first
  budget lands at the first weekly roll (tests must cross it — recorded).
  Milestone-3 adversarial audit LAUNCHED over the whole layer.
- **v0.35.1** — (iteration 12) **milestone-2 audit ingested: 0 CRITICAL, 0
  HIGH, 1 MED, 4 notes.** Every money path CLEARED under probe verification:
  escrow conservation on all routes, the A19 burn/mint doctrine, self-dispute
  strictly negative both ways, reopen flip-flops, F7 early-exit, no stuck
  interleaving, quorum-floor manipulation, tally overflow. The MED (M2-1):
  **self-contest manufactured the contested-and-upheld credential** at ~20%
  of a dispute bond per point (honest voters upholding a trivially-true claim
  supplied the win for free). FIXED same-iteration, two layers: the answerer
  cannot dispute their own answer (hygiene), and — the real defense —
  **creditUpheld now requires credEligible: some upheld round's OVERTURN side
  carried ≥ ¼ of the (supply-floored) quorum floor**. A farmer must hold and
  vote ~1.25% of court supply against their own claim, kept under the 50.01%
  overturn bar — the v0.28 pricing rule (supply-absolute prizes demand
  supply-absolute weight) applied to the credential. Consequence, accepted:
  near-unanimous upholds credit nothing (an answer nobody meaningfully backed
  overturning wasn't hard — matches the difficulty-weighting intent).
  Regression: TestWeightlessContestEarnsNoCredential. Notes N1-N4 recorded
  (N1 deposit/fee deferral is the quality module's job; N2 live-price escrow
  window only lengthens, safe; N3/N4 inherited V1 render/governor bounds).
  Fix verification folded into the milestone-3 (quality) audit brief.
- **v0.35** — (implementation iterations 6–7) **the verdict machine is
  complete**: `session.gno` (72h undisputed settle → VERDICT_FINAL, exactly-
  once bond return, `WithdrawStake` 1× both sides) and `dispute.gno` (V1's
  round structure with the v0.11–v0.25 dispositions: forfeitures burn / comp
  mints senior-queued at RoundDecided with both cap arms; failed rounds
  half-burn half-return with NO comp; provClose = everyone 1× + deposit AND
  fee refund, disposed inline at the third failed resolve; participant-gated
  Finalize week; F7 loser early-exit in WithdrawStake; quorumFloor and every
  bond read `X̄frozen` per P6). Implementation-level pins made while coding,
  each a deliberate refinement of the prose:
  (1) **the answer bond survives uphold rounds** — it stays escrowed until
  VERDICT_FINAL rather than returning at each decided round (V1 returned it
  early and accepted zero-collateral reopens); comp arms read the posted
  magnitude `answerBond0`, so an overturned-then-vindicated answerer is
  redressed by the reopen round's comp, not a resurrected bond;
  (2) **records move ONCE, at Finalize, from the final verdict** (P13), and
  `creditUpheld` additionally requires ≥1 DECIDED round — a verdict standing
  only on quorum-less defaults earns no difficulty point (else half a dispute
  bond of self-dispute burn would buy one);
  (3) **the undisputed settle is immediately final**: the 72h delay IS the
  first-round dispute window; the settle and dispute guards partition every
  height (`now ≥` vs `now <`), so no race and no undisputed-reopen path
  exists — contesting happens by disputing before the delay lapses;
  (4) **escrowWindow keeps V1's formula with X̄frozen as the size proxy**
  (the collateral is gone); consequence, recorded: with 1-week votes a
  3-failed-round provClose only fits inside escrow windows > 2 weeks (large
  claims) — small claims cap at 2 failed rounds and Finalize the defaulted
  verdict, exactly V1's audited behavior. Milestone-2 adversarial code audit
  LAUNCHED on the full verdict path.
- **v0.34** — (implementation iterations 2–5) **the money core is built and
  its milestone-1 audit is ingested (FIX-FIRST → fixed)**: emission.gno (the
  P5 senior queue verbatim, exact-remainder accrual, R_max pause,
  permissionless pulls), buy.gno (GNOT burned to a provably keyless sink —
  courtv2's own never-created sub-realm identity; V1's payment posture
  unchanged), records.gno (P13 credential: contested-wins-only, overturn
  resets, cold-start gate, one-active bracket), render.gno (three series, no
  backing, sanitized). Audit findings: **C1 CRITICAL** — the naive uint64
  budget product wrapped at ~485k CC of supply (34× under-budget at 1M CC;
  the V1 wrap class; unit tests had only 10k-CC magnitudes) → mulDiv128
  everywhere + curve-cap-scale regression tests; **H1 HIGH** — conviction was
  not actually rate-weighted (whole idle Δt priced at rate(now), retroactive
  repricing across rolls, frozen conviction revalued) → the audit's ERA
  INTEGRAL adopted (court-level Σ rate×blocks per segment; positions settle
  stake×Δacc; freeze pins the integral — immutable by construction). The
  feared idle-position accrual panic was formally disproved (~330M years).
  M1 (R_max segment granularity) documented as accepted. Verified clean:
  escrow conservation, senior/junior conservation, exactly-once, auth on all
  seven mutators, no /p/ escapes, no gas bombs.
- **v0.33** — (implementation iteration 1) **both v0.32 audits landed,
  convergent on a CRITICAL: budget-d unmoored the rate from realized carry**
  (riskless matched farming below ~18% participation — A1/A2 reopened by the
  4× ceiling raise). FIXED in code the same turn: d_eff = min(ceiling,
  realized-EMA) — the rate starts at the pure-r floor and rises with real
  participation. Slash retuned 2.5→4.5%·X̄ (mill-kill q back to ~0.22 at the
  hot rate; bounty bound holds). §10.1 pins P1–P14 adopted as the coding
  spec; §10 purged of rateAtFreeze and the double-decay trap; §11 gains the
  audit's UX rows + the never-render-the-ceiling rule; P3 headroom amended
  to ≥10% (owner-flagged, §12). CODE: claim.gno + stake.gno landed green
  (no-loss staking, u128 rate-weighted conviction, freeze semantics,
  dead-claim close, escrow-conservation tests). ECONOMICS/App-B reference
  numbers are stale at the hot rate — marked, recompute next.
- **v0.32** — (OWNER DIRECTIVE) inflation ceiling set at **20%/yr worst-case**:
  per-period budget `B_n = (20%/52) × S_live × 2^(−n/104)` — the ceiling now
  scales with live supply (a court of any size worst-cases at 20%/yr, decaying
  by the amortized halving), total supply provably bounded < 1.78× curve-sold
  supply, and `curveCapV2 = (MaxInt64/Bps)/2` restores the overflow headroom
  the tighter bound consumes. The %-of-live-supply objection from v0.3
  (compounding/gameable) is answered the same way live-d was: minting is
  earned-only and ceiling-bounded, buying raises the budget only by paying
  the curve, burning lowers it at the burner's sole cost. Economics vet
  launched on this sizing + a fresh full-design audit at the 20% numbers
  (owner asked for another audit). **IMPLEMENTATION BEGINS**: V1 code stays
  untouched; V2 lands as new modules in `realm/r/courtv2/` per §10.
- **v0.31** — (iteration 52) **T2 final — and with it the ledger: CONVERGED,
  no unvetted mechanism remains** (the micro-pass's own closing line). The
  weight time-lock was confirmed unimplementable against V1's actual
  checkpoint source (address-locks die to one transfer; balance-freezes break
  the grc20votes pin and bench the paid police); my flat-8%·X̄ candidate was
  REJECTED for re-creating V2-1 against honest flaggers; the adopted price is
  the v0.28-registered counter-flag window, now armed: slash + bounty escrow
  one challenge window, the slashed answerer forces one re-vote at the
  supply-floored bar (inconclusive re-vote → slash stands), outcome final —
  a capture-whale must win ⅔ twice, the second against maximal mobilization.
  Parallel-reuse residual registered A4-class. The quality/policing layer's
  full history: A4 → A15 → A16/A17 → A19 → A20 → A21 → T1/T2 — one hole
  re-expressed seven ways, now closed at every reachable scale and priced at
  every unreachable one.
- **v0.30** — (iteration 46) **T1 grief-pass: SAFE-AS-IS; the quality/policing
  layer is design-CONVERGED** (the pass's own words), with both of my
  candidate guards rejected for cause and the sleepy-regime residual priced
  and registered (income-free spite, ~4:1, killed by one counter-vote).
  Launched the genuinely last micro-pass: T2 (the full-bar free-roll
  half-burn + the low-side weight time-lock) is the only mechanism in the
  design that is vet-proposed but never itself attacked — and it is the one
  weight-at-risk rule. Its verdict completes the ledger.
- **v0.29** — (iteration 42) the original composition vet's SECOND report — a
  third independent A21 analysis — validates the v0.28 gate structure (and
  sides with vet B against my claim-scaled bar: "slash-scale prizes must stay
  supply-absolute") while fixing its two soft spots: **T1** inconclusive-LOW
  returns the full bond (cheap-when-right flags → f → 1 in the mill band →
  the mill-kill is robust to all three vets' divergent margin estimates;
  no faucet — a bond return is not income); **T2** full-bar-low under ⅔
  half-burns the bond and time-locks low-side voter weight for T_L on
  slash-triggering votes (the whale free-roll and its ~3%/wk reuse cadence
  die; V2's one weight-at-risk mechanism — locked, never lost). T3 dispute-
  ride pin; T4 register line. One micro-pass requested and launched: T1
  grief-pricing.
- **v0.28** — (iteration 40b) **A21 truly final: the second composition vet
  landed minutes after v0.27 and each vet corrected the other.** Vet A's mill
  arithmetic had dropped the flagged-branch carry term — vet B restored it:
  median-low tier-0 + carry kills mills at q ≈ 12%, X̄-invariant (my P1 stood
  after all; the slash is police-funding only). Vet B then invalidated BOTH
  reachable-bar slash designs (my claim-scaled draft and vet A's
  undisputed-gate) with the root observation: quality-vote weight is
  costless, reusable, never escrowed — any claim-scaled bar triggering
  X̄-scaled value is a faucet. Final: slash + full bounty only at the
  supply-floored bar AND undisputed (belt from vet A); median-low = dust
  economics that nonetheless suffice to kill mills; bounded dead zone
  accepted and priced; counter-flag upgrade path registered; root cause
  named and scoped to V3 (weight-at-risk vs carrot-only voting, decision
  #4). Both vets' convergence opinions now agree: remaining surface =
  accepted-register grief classes. **This closes the last structural DRAFT
  in the attack ledger.**
- **v0.27** — (iteration 40) **A21 resolved: the composition vet REJECTED my
  two-tier supermajority draft with decisive arithmetic** — my pre-analysis P1
  was wrong (tier-0 + deposit leaves mill break-even at an unreachable
  f* ≈ 0.74; the slash is LOAD-BEARING, halving it to 0.41), P2 confirmed
  (supply-floored gate = dead zone), and the supermajority route was a
  cheaper-than-high capture WITH a prize. Adopted its alternative: the slash
  fires at reachable MEDIAN-low but only on UNDISPUTED answers — the dispute
  machine itself is the evidence-gate (adjudicated-once bonds are immune);
  bounty base counts the slash only when it burned (V2-1 restored exactly in
  the mill band; honest-claim capture attempts risk the full bond against a
  paid electorate for a contested prize — the accepted A4 class). New pin:
  dispute-ride quality-low never slashes an upheld answer (A22). Residuals
  registered honestly (discriminator-not-wall; frozen-slot high-q-only
  policing). Its convergence opinion: this was the LAST structural joint —
  "who funds scaling policing pay at reachable evidence without creating a
  slashable-victim prize" — and with it fixed, the remaining surface is
  accepted-register grief classes.
- **v0.26b** — (iteration 31) ripple sweep: Appendix B's flagged ending
  recomputed under two-tier low (supermajority branch shown — slash 1,500 CC,
  bounty 1,200 CC; median-only branch noted at ≈0.9 CC); decision index rows
  22–25 added (ratchet freeze, bounty base, two-tier low, participant
  exclusion).
- **v0.26** — (iteration 30b) micro-vet-3 landed: CONFIRMS the answer-height
  snapshot (independently derived the identical pin) and the full-bar +
  dead-zone fixes; adds PARTICIPANT EXCLUSION (own-claim quality lane: no
  vote, no carrot — closes same-epoch and post-release enfranchisement;
  sybil caveat registered, full-bar stays load-bearing). Cross-checking it
  against v0.25 surfaced a SELF-FOUND composition hole none of the vets saw
  in isolation: slash + scaled bounty + claim-scaled demotion bar =
  a profitable low-capture faucet against honest claims. Fix drafted:
  TWO-TIER LOW (median-low = tier-0 with deposit-only economics;
  supermajority-low at the full ⅔+bar gate unlocks the slash and the full
  bounty — junk converges there honestly, honest claims cost the whale
  price). Final composition micro-vet launched; convergence call waits on it.
- **v0.25** — (iteration 30) **round-3 monolith + micro-vet-1 landed together,
  independently converging on a BREAKS: the v0.20 bounty was a mint faucet**
  (own-bond bounty unbounded by its event's ~1 CC of burns; junk-farm sybils
  pump X̄ with refundable stake, honest low votes trigger the mint, senior
  queue's head captured). Fixed with the per-event invariant the comp rule
  already obeys — bounty ≤ 80% of low-outcome burns — made meaningful by a
  scaling burn: conclusive low slashes 2.5%·X̄ from the answer bond
  (answerers become the quality gatekeepers of the slot they occupy). All
  sybil arrangements strictly negative again (junk farm nets −0.5%·X̄−1.1CC).
  Also from round-3: capped-court dispute-bond fix (B_d1 = min(20%·X̄,
  0.4×actual answer bond) — round-1 bar was silently ~0.71 on big capped
  claims); failed rounds burn HALF (the dispute lane had kept the disease
  V2-1 cured in flags); floor-rounding pinned on the 80% arm (ceil re-cracks
  the bound); the idle-reserve conclusive-mid squat closed (full bar to
  consume the slot; ¼-bar mid reopens ×2 — A20); the small-claim dead zone
  closed (quality bar = min(X̄,⅓votable)/4, no supply floor — pay-per-weight
  uniform at every claim size); no carrot on inconclusives; v0.23b's
  answer-height snapshot CONFIRMED as having killed a real adverse-selection
  attack (the v0.20 flag-height rule was exploitable). HOLDS verified:
  escalation ordering, answerer-prevails (whole at verdict-error < 24%),
  refund-farming zero, comp chains burn-dominated (3-round all-sybil: burns
  1.1X̄, mints 0.88X̄).
- **v0.24** — (iteration 29) **micro-vet-2 landed: independently CONFIRMS the
  v0.23 K-cap deletion** ("BREAKS — the cap IS the cheap immunization"),
  corrects its arithmetic (3-cycle burn = 7%·X̄, not 3.5% — 3.5·b₀ conflated
  with 3.5%; conclusion unchanged), and refines the fix: bare deletion left
  unbounded doubling, which re-immunizes by capital exhaustion (~32%·X̄ entry
  at cycle 5). Final rule: after 3 inconclusives the bond FREEZES at 8%·X̄
  (full-burn-unless-low, bounty = bond, 7-day cooldown) — flaggability is
  permanent at bounded capital, grief-delay costs ~120:1 against victim harm,
  X̄-invariant. Serial-grief chain HOLDS; refund-farming HOLDS (zero); new
  deploy invariant: flag-vote carrot < b₀/2 (sybil mid-voters net negative,
  margin ~2.2×).
- **v0.23b** — (iteration 28) extended the answer-height snapshot pin to
  dispute-ride quality votes: a disputer epoch-shops exactly as a flagger
  would, so BOTH quality paths use the claim's one fixed answer-height
  electorate (the verdict tally keeps the governor's propose-time snapshot —
  two lookups on one ballot, each serving its own threat model).
- **v0.23** — (iteration 27, micro-vets running) **deleted my own one-iteration-
  old K = 3 flag cap** — worked through while briefing micro-vet-2: a cap that
  terminates the slot AS MID is a guaranteed mill-immunization recipe (3 dust
  self-flags ≈ 3.5%·X̄ ≪ the ~9%·X̄ draw it protects), and it was redundant —
  per-slot doubling prices chains exponentially while the bounty-equals-own-
  bond rule keeps honest late flaggers at the same q > ½ threshold at any
  depth. Also pinned the quality-vote snapshot at the ANSWER height (one
  fixed epoch per claim, set before any flag exists — kills epoch-shopping
  and makes the escrow-disenfranchisement rule crisp). Both marked pending
  micro-vet confirmation.
- **v0.22** — (iteration 22) brainstorm pass 4: emission machinery judged
  irreducible (every component is load-bearing for a named, vetted invariant —
  paragraph doubles as an anti-"simplification" tripwire); the quality layer
  recorded as **the hidden price of no-loss staking** (V1 priced junk via
  losers' losses; remove loss and someone must adjudicate junk, incentivized
  and attack-priced — the flag lane is that someone). Zero design changes —
  third consecutive no-change brainstorm.
- **v0.21** — (iteration 20) **vet 2B landed and independently CONFIRMED the
  v0.20 targets**: analyzing the pre-v0.20 file, its three "decisions wording
  cannot close" were exactly the three v0.20 fixes (unpaid flag voters → paid;
  the fee's undefined default-mid branch → refunds; bounty∝deposit vs
  bond∝X̄ → bounty = own bond). Applied its full residual checklist + the
  monolith's second report: K = 3 hard cap on flag reopens; the
  mill-break-even fee sentence deleted (false under the v0.20 refund rule —
  anti-mill work belongs wholly to the flag lane); queue-jam register item 7
  (self-dispute chains can delay policing pay but burn ≥ 1.25× what they
  jam); §3.6 upstream prose corrected at the source; the v0.7
  "dilution-payers police for free" paragraph marked SUPERSEDED; §2 gains the
  missing backing-deletion row and the fee row; provClose fee/carrot
  dispositions pinned (fee refunds; no carrot without a verdict); author cap
  base pinned (time-averaged, either side); dispute-bond zero-case fixed
  (cap = 0 means uncapped, not zero); Appendix B fully recomputed at the
  v0.20 rules (rate ≈ 0.89%/wk, D ≈ 1,037, comp min-rule ending, split
  settlement). Round-3 vet running on the three v0.20 reconciliations
  (comp min-rule edge cases, half-burn chains, staked-can't-vote).
- **v0.20** — (iteration 19) **BOTH round-2 vets ingested (the stalled monolith
  finally landed, then 2A twenty minutes later — they agree, and 2A goes
  deeper). Verdict was NOT-CONVERGED; every structural item is now addressed:**
  (1) V2-1 CRITICAL flag-lane arithmetic — bounty repriced from ≈deposit/2
  (q_min ≈ 99.96%, nobody polices) to THE FLAGGER'S OWN BOND, and flag-vote
  voters now earn the tier-invariant carrot; the false "q ≈ 0.2" mill number
  retracted. (2) V2-2/2A comp recapture — comp = min(2×own bond, 80%×loser's
  burn): honest-dispute bar back to q > 1/3, every self-X sybil pair strictly
  negative (naive own-bond sizing would have made self-uphold a +0.8X̄ mint
  faucet — caught while reconciling the two vets). (3) 2A-T1 BREAKS →
  policing pay is a SENIOR-QUEUED entitlement (reserved on the accrual line,
  paid first, never scaled): kills the scarcity-window lying meta at the
  root; supersedes the monolith's sub-reservoir sketch. (4) V2-4 formula
  block rewritten — implementable now (tier-scaled trio from D; policing
  layer independent + senior). (5) V2-5 — the v0.12 24h-post-answer no-settle
  rule was VACUOUS under the retained 72h delay; replaced with
  reopen-relative 24h windows. (6) V2-6/2A-T2 pins — doubling PER-SLOT,
  inconclusive burns HALF (reconciling the vets' direct conflict), staked CC
  cannot vote quality (escrow weight nets out — mills can't vote working
  capital toward self-immunizing conclusive-mids), principal release NEVER
  pausable (split settlement). (7) V2-7 — d_n from LIVE supply, reversing the
  v0.15 ceiling pin that made early courts unpayable (decision-index #19; all
  manipulations self-costly). (8) V2-8/2A-T3 — rate-weighted conviction over
  a geometrically amortized table (×2^(−1/104)/period): rateAtFreeze deleted,
  no boundary block exists to race. (9) V2-9 — fee condition fixed (was
  undefined at default-mid-no-vote, the most common outcome). §4/§5/§7.2
  synced; stale items #5/#6/#15 fixed; Appendix B recompute + the remaining
  stale list ride the next commit with vet 2B. Core architecture (no-loss
  staking, reservoir rate, conviction, burn-at-Buy) survived both passes
  unchanged.
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
