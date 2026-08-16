# ECONOMICS.md — private emission-calibration memo (V2)

> Referenced by PLAN.md §3.3. INTERNAL: per §7.4 comms hygiene, nothing in this
> file — rates, APR-equivalents, margins — may appear in public docs, render,
> or marketing. Public copy says only: "participation rewards at a published
> protocol rate, subject to availability."

## Symbols

| | |
|---|---|
| `r` | external opportunity rate (what locked capital could earn elsewhere), per week |
| `d` | dilution rate = minted / supply, per week |
| `ρ` | `r + d` — the full carry cost of locked CC |
| `T_c` | conviction time: stake → answer-freeze |
| `T_L` | lock time: stake → withdraw (≈ 1.5 × T_c: adds 72h + escrow) |
| `y` | yield per conviction actually paid (the effective rate) |
| `p` | a staker's true accuracy on the claims they stake |

## Core results (econ vet F5; reservoir vet F-R1/F-R5)

- **Matched-farming threshold**: staking both sides is profitable iff
  `y > y* = 2ρ·T_L/T_c`. Below y*, no farming capital enters at all.
- **Honest threshold**: a staker with accuracy p profits iff `y > y*/(2p)`.
- **The schedule**: `rate_n = 0.85 × y*(n)` per period n. Consequences:
  farming margin −15% (never profitable); honest break-even at
  `p_min = 1/(2×0.85) ≈ 0.59`; a p = 0.7 staker nets ≈ `(2p×0.85 − 1)·ρ·T_L
  ≈ 0.19·ρ·T_L` per episode on conviction.
- **Why 0.85, not 0.75**: the schedule (below) removes the *deterministic*
  y*-decay that the margin previously had to absorb; the remaining drift is r
  only. 0.75 amputated the 0.59–0.67 accuracy band — real calibration signal
  — for margin we no longer need (F-R5).

## The d_n rule (v0.20 — LIVE supply, superseding the ceiling path)

`d_n = B_n / S_live`, with `S_live` read once at each period boundary
(deterministic on-chain data, not a lever) and `B_n` the per-period budget on
the **geometrically amortized** step-down (`×2^(−1/104)` per period — no
cliffs exist, so no boundary block can be raced; 2A-T3). Then
`y*(n) = 2(r₀ + d_n)·T_L/T_c` and `rate_n = 0.85·y*(n)`.

Why live, not ceiling (the v0.15→v0.20 reversal, PLAN decision #19): the
ceiling path understates d early — at 10% of ceiling supply, actual d is 10×
the scheduled figure, actual y* ≈ 3.75%/wk vs a 0.89%/wk rate, and honest
break-even needs p > 1: **the early court pays nobody**. With live d the 15%
anti-farm margin tracks the true y* at every supply level. Manipulation check:
buying CC lowers everyone's rate including yours (self-defeating for a
yield-seeker); burning your CC raises the rate at your sole cost — every
manipulation is self-costly. Self-bound unchanged: draws are conviction-based,
so `d_real ≤ rate × staked-fraction` — no court dilutes faster than its own
participation earns.

Conviction itself is **rate-weighted** (∫rate(t)·stake·dt — V2-8): there is no
rate snapshot anywhere, accrual is priced as it happens, and the F5 band holds
within every era because 0.85·y*(t) < y*(t) pointwise.

## Reference launch numbers (used across all vet math)

r₀ = 0.25%/wk (~13%/yr), d₀ ≈ 0.1%/wk, T_L/T_c = 1.5 →
y*₀ = 2(0.35%)(1.5) = 1.05%/wk → **rate₀ = 0.89%/wk per unit conviction**.

| Actor | Position | Net per episode (on stake, T_c = 2wk ref) |
|---|---|---|
| Matched farmer | both sides, 2× lock | **negative** (earns 0.85·y* on half the capital vs 2× carry) |
| Coin-flipper (p = .5) | one side | negative (0.85/2·y*·T_c < ρ·T_L) |
| Break-even staker | p ≈ 0.59 | ≈ 0 |
| Good staker (p = 0.7) | one side | ≈ +0.19·ρ·T_L ≈ +0.10%·stake/wk-equivalent |
| Mill (post-v0.12 fixes) | self-claim | negative at flag-prob q ≥ 0.2; fee+deposit at risk vs mid-tier crumbs |

## Sizing B and R_max

`B_period` is a throughput ceiling, not a target: size it ≥ the forecast
`rate × Σconviction` of a healthy busy week so honest demand never scales down
in normal operation (scaling is reserved for genuine surges). `R_max = 4 ×
B_period` banks a month of quiet; anything longer is forgone by design
(ceiling-not-floor). Under-demand mints nothing; over-demand rations by
availability, farmers exit first (F-R4 ordering).

## The 80/8/7/5 split — tuning rationale (v0.19; converts "provisional" to "reasoned-provisional")

The split's job is ordering, not precision — each slice must clear its role's
participation threshold without inverting the hierarchy *winners ≫ author >
voters > answerer*:

- **Winners 80%**: the core signal incentive must dominate everything else
  combined, or staking becomes a side-show to service extraction. 80% keeps
  the effective staker rate at 0.8 × rate_n — the F5/F-R5 margins in this memo
  are computed on exactly that basis, so moving this number moves p_min.
- **Author 8%**: with the conditional fee refund (mech vet R7b), the author's
  worst honest case is ≈ 0 (fee back, small slice) and the good case is
  8% × a draw their claim attracted — pure upside for surfacing questions the
  crowd funds. Above ~10% authorship starts to compete with staking as the
  yield path (invites claim-spam pressure the fee must then re-price); below
  ~5% thin-claim authorship pays nothing at all.
- **Voters 7%**: deliberately a *token* at small draws (0.7 CC/voter on a
  1,000 CC draw) — voters' real motive is stake-protection and the court's
  credibility; the carrot only needs to beat gas and tip marginal attention.
  Making it large enough to be a primary income would recreate the F2/F3
  vote-for-pay dynamics the tier-invariance fix just contained.
- **Answerer 5%**: intentionally the smallest — the answerer's true
  compensation is the bond return + the difficulty-weighted credential
  (priority access to future slices); the slice is a top-up. Raising it
  re-inflates the self-answer mill margin that A15's fixes just priced out
  (the mill keeps winner+author+answerer = 93%; every answerer point is a
  mill point).

Tune freely at deploy **within the ordering and the caps** (§4); crossing the
ordering or touching cap *rules* re-opens A15/F2 and needs a fresh vet.

## Cross-references

PLAN.md §3.3 (mechanism + pins) · §3.5 (slices/caps) · §5 A1/A14 (the attacks
this math closes) · §6 (the p < 0.59 exclusion, owned) · vet findings F5,
F-R1, F-R4, F-R5 (derivations verified adversarially, twice).
