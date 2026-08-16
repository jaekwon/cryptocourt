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
   emission slices. Deposit refunds to the author.
6. **Dead claim.** A claim that never reaches an answer unlocks fully after a
   timeout: all stakes 1×, deposit back (fixes V1 residual O6).
7. **provClose** (3 failed dispute rounds): everyone 1×, no bonus, no author
   reward, deposit back. No price needed — the V1 O5 manipulation surface is gone.

### 3.2 Conviction (time-weighted stake) — `VETTING`

The bonus weight is not the stake, it is the **time-integral of the stake on the
winning side**, from stake-time until the answer freeze. This does three jobs at
once: (a) rewards *early* information — the whole point of a forecasting signal —
(b) makes last-second stake-flooding worthless, and (c) prices the lock: a farmer
must actually commit capital-time, not just capital.

### 3.3 Emission — `VETTING`

- **Fixed absolute budget per period** (period = 1 week = 120,960 blocks), **not**
  a % of supply (%-of-supply compounds unboundedly and is gameable by minting).
- **Halving** every 104 periods (~2 years). Total emission is therefore a finite
  geometric sum, provably bounded: `Σ ≤ 2 × B₀ × 104`.
- **Deploy-time invariant** (checked in code, V1-style): `curveCap + Σemission ≤
  MaxInt64/Bps` with ≥20% headroom — the tally-overflow safety V1 depended on
  survives issuance.
- **Ceiling, not floor.** Only rewards actually earned are minted. Unearned budget
  is *never* minted (no rollover; deflationary bias, and no "catch-up" jackpots).
- **Sizing target** (provisional, pending economics vet): B₀ such that a correct
  early staker on a mid-quality claim sees ~15–30% APR-equivalent on conviction at
  projected launch participation. Placeholder: B₀ = curveCap / 10,000 per week.
- All constants frozen at deploy. No governance emission lever, ever (§0).

### 3.4 Resolution: verdict + quality — `VETTING`

- **Verdict**: unchanged binary machine. Winners = stakers on the side matching
  the final verdict.
- **Quality**: a second question on the same dispute proposal — was this claim
  **low / mid / high** information? Resolved by **weighted median** over
  `grc20votes` snapshots (the bucket where cumulative weight crosses 50%): a whale
  can pull the median one bucket at most, never to an extreme; three buckets give
  voters a Schelling point so honest votes converge.
- **Undisputed claims** (no vote happened): quality defaults to **mid**. Low would
  punish the healthy path (most good claims settle by silence); high would be
  free. `OPEN` — the economics vet examines whether default-mid is farmable and
  whether a cheap opt-in "rate this claim" vote is worth the machinery.
- Tier multipliers: **low = 0×, mid = 1×, high = 2×**. Low-quality claims earn
  *zero* bonus for anyone — junk is pure cost (deposit + lock + dilution).
- **Implementation shape** (from the §Appendix A sweep): quality does NOT touch
  `/p/governor`. It is a court-local 3-bucket tally: `VoteQuality(claimID,
  bucket)` weighs the voter by `PastVotes` at the **same sealed snapshot epoch as
  the dispute proposal** (same anti-flash-loan property, no second snapshot);
  state is three weight counters + a voter→(bucket,weight) record (double-vote
  guard, and the record the voter carrot pays from); the median is computed at
  close and never rendered before it (sealed, like the verdict tally). No new
  governor lane, no /p/ change.

### 3.5 Reward split — `VETTING`

Per period, over the claims settled in it:

```
claim weight   W_c  = tier_c × Σ_winners conviction_i
period pool    B    = this period's budget (ceiling)
claim's draw   D_c  = B × W_c / Σ W_c
split of D_c:  winners 80% (pro-rata by conviction)
               author 8% · with-verdict+with-median voters 7% · answerer 5%
individual cap: bonus_i ≤ stake_i × tier/2   (mid ≤ 0.5×, high ≤ 1.0× principal)
```

- The **cap** keeps the headline honest ("up to 2× on a high-quality claim") and
  stops quiet-period jackpots; capped-out remainder is simply not minted.
- **Voter reward is carrot-only**: with-verdict/with-median voters share the slice;
  wrong-side voters lose nothing (owner's call; noted fragility: carrot-only
  weakens as claim value grows — revisit if large-value capture appears).
- All slices are **computed by formula from the tallies** — no discretionary
  "pay X" votes anywhere (Ooki surface minimization, §7.3).
- `OPEN`: whale-hogging — one giant claim can absorb the whole period pool;
  candidate smoothers (per-claim share cap, concave weight) are with the vet.

### 3.6 Bonds and deposits — `DRAFT`

Answer bonds and dispute bonds stay forfeitable exactly as V1 (bond doubling is
what makes the adjudication game honest; without loss, wrong answers are free).
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

### 3.8 Signal & render — `DRAFT`

The sparkline is the stake ratio `YES/(YES+NO)` bucketed hourly (same epoch-bucket
code as V1's TWAP, storing the two pool sizes). Render shows: ratio series, total
staked, conviction leaders, verdict + tier + route ("undisputed" / "by vote 71%,
quality: high"), and the emission drawn. The claim page IS the product.

## 4. Parameters (deploy-time constants)

| Constant | Value (provisional) | Note |
|---|---|---|
| period | 120,960 blocks (1 wk) | matches V1 vote length |
| B₀ (initial weekly budget) | curveCap / 10,000 | pending economics vet |
| halving interval | 104 periods | total emission ≤ 2·B₀·104 |
| supply invariant | curveCap + Σemission ≤ MaxInt64/Bps, ≥20% headroom | checked at deploy |
| tiers | low 0× · mid 1× · high 2× | §3.4 |
| individual bonus cap | tier/2 × principal | §3.5 |
| split | 80/8/7/5 winners/author/voters/answerer | §3.5 |
| minAnswerX, bonds, escrow windows, 5001 bps, 72h delay | V1 values | unchanged |
| dead-claim timeout | 12 weeks | new (O6 fix) |

## 5. Attacks & mitigations

| # | Attack | Mitigation | Status |
|---|---|---|---|
| A1 | **Matched-stake farming**: stake both sides, riskless bonus | Conviction (time-cost) + tier-0 junk + pro-rata pool self-deflates + per-address *net* stake counts toward bonus | `VETTING` |
| A2 | Sybil split of A1 across wallets | Doubles lock cost; residual accepted at low bonus rates — size B₀ so riskless carry ≈ lock's opportunity cost | `VETTING` |
| A3 | Last-second stake flood | Conviction ≈ 0 for late stake | `ACCEPTED (design)` |
| A4 | Quality-vote capture (push median to high on own claim) | Weighted median (whale moves it ≤1 bucket); sealed tally; carrot goes only to with-median voters; capture farms CC whose value the capture debases | `VETTING` |
| A5 | Junk-claim spam for default-mid on undisputed settle | Deposit + minAnswerX gate + anyone can dispute quality... (`OPEN`: does disputing quality alone need a lane?) | `VETTING` |
| A6 | Whale claim hogs the period pool | Candidate: per-claim draw cap / concave weight | `OPEN` |
| A7 | Emission-lever capture | No lever exists (frozen constants) | `ACCEPTED (V1 discipline)` |
| A8 | Unstake-grief (yank stake to flip ratio pre-answer) | Ratio is time-bucketed; answerability reads the trailing average; freeze at answer | `DRAFT` |
| A9 | Overflow via huge stakes (no caps anymore) | `ccMul`/checked adds everywhere + the supply invariant; **conviction specifically MUST be a 128-bit accumulator** — stake (≤ MaxSupply ≈ 9.2e14) × blocks (~6.3e6/yr) ≈ 5.8e21 ≫ MaxInt64, so per-staker and per-claim conviction accumulate in uint128 (hi,lo pairs, tickbook-style) and every pro-rata draw goes through the audited 128-bit `mulDivFloor`. No saturation, no silent wrap | `ACCEPTED (design)` |

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

## 8. Open questions / vet queue

1. A1/A2 economics: closed-form on when matched farming is profitable; size B₀.
2. A6 pool-hogging smoother: cap vs concave vs nothing.
3. Undisputed default-mid (§3.4): farmable? opt-in quality vote worth it?
4. ~~Bond-forfeiture fallback~~ — RESOLVED (rejected; §3.6: time-lock-only bonds
   invite first-answerer squatting/DoS; forfeiture is load-bearing for the
   one-per-claim answer slot). Legal color still pending from the legal vet.
5. Should conviction decay for very long stakes (anti-zombie) or is monotone fine?
6. ~~Removal-impact sweep~~ — DONE (Appendix A). Load-bearing catches: X̄ feed
   must switch to Stake/Unstake events; conviction needs 128-bit accumulators
   (A9); emission mints at pull-time and never transits escrow, preserving the
   V1 escrow-conservation invariant and its txtar checks.

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

## 9. Changelog

- **v0.1** — initial standalone draft: no-loss conviction staking, bounded halving
  emission, quality tiers via weighted median, GNOT burn decision, bonds kept,
  diff table, attack table, regulatory rationale + accepted-risk register.
  Launched vets: economics/attack (A1–A6), legal (no-loss/emission/burn/bonds).
- **v0.2** — (iteration 1, vets still out) resolved §8.4 and §8.6 in-house:
  bond-forfeiture fallback REJECTED with reasoning (first-answerer squat DoS —
  §3.6); Appendix A removal-impact map added with three load-bearing catches
  (X̄ feed switches to stake events; conviction must be 128-bit — A9 upgraded;
  emission never transits escrow, preserving the V1 conservation invariant);
  quality tally concretely specced as court-local 3-bucket median on the dispute
  proposal's snapshot epoch (§3.4) — no /p/governor change.
