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

## The deterministic d(n) path (why a scalar rate self-defeats — F-R1)

`d(n) = b_n / S_ceiling(n)` where `b_n` is the per-block accrual (halves every
104 periods) and `S_ceiling(n) = curveCap + Σ_{k<n} b_k·blocks` (worst-case:
every budget fully minted). Both numerator and denominator paths are
deploy-known, so **y*(n) = 2(r₀ + d(n))·T_L/T_c is computable at deploy for
every future period** — that table IS the rate schedule. A frozen scalar
compared against this path crosses above y* around the second step-down
(farming turns on by schedule); the schedule can't.

Conservatism check (PLAN v0.15 pin): real supply ≤ ceiling supply ⇒ real d ≥
scheduled d ⇒ real y* ≥ scheduled y* ⇒ the 15% margin holds in every court at
every age. And the self-bound: draws are conviction-based, so
`d_real ≤ rate × staked-fraction` — no court dilutes faster than its own
participation earns, regardless of court size.

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

## Cross-references

PLAN.md §3.3 (mechanism + pins) · §3.5 (slices/caps) · §5 A1/A14 (the attacks
this math closes) · §6 (the p < 0.59 exclusion, owned) · vet findings F5,
F-R1, F-R4, F-R5 (derivations verified adversarially, twice).
