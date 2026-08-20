# LOSERLOCK.md — locking the losing side, and for how long

**Status: PROPOSED, NOT AUDITED, NOT IMPLEMENTED.** Owner directive: pick a reasonable lock
duration to discourage straddling, converge, implement. Carry arithmetic is deliberately
out of scope — the question is now *how long*, not *whether the spread is worth chasing*.

---

## 1. THE CONSTRAINT THAT SHAPES EVERYTHING

**A lock at settlement is void on its own.** Two independent vets measured it:

- `Unstake` is free before the freeze and **keeps conviction** (F9), and `WithdrawBonus` gates
  on the side and the paid flag — **never on the position still existing.** So a straddler
  unstakes both legs the block before the answer, is paid in full, and has **nothing for a lock
  to hold.** Measured: locked balance 0, `WithdrawStake` panics "nothing staked on that side",
  payout bit-identical to the holder.
- **And it is not a race.** Draining at 4 weeks and at 8 weeks of the same claim return the same
  rate to five digits, because payout and cost scale together. No freeze can catch it.

> **So the lock requires a companion change: the reward must be conditioned on the position
> still being staked at settlement.** Without that, any duration is theatre — and shipping
> theatre is the exact mistake already made once in this file's history (§5).

**That companion change is not free**, and it is the real design decision here:

- It **reverses F9** ("conviction survives unstaking"), which is deliberate. F9 exists so
  principal is never hostage — but conditioning a *reward* on presence is not holding principal
  hostage, so the two may be separable. **The vet must rule on that.**
- It would **also** close the drain-then-answer attack that forced the answer bond's floor to be
  re-keyed. That is a second, unlooked-for benefit and should be priced.
- Two live fixtures assert the loser exits early, and `WithdrawStake`'s doc contract states the
  path "is unpausable: … nothing downstream may hold principal". A lock on the *losing* side
  touches that contract even though principal still returns 1×.

## 2. What the lock must NOT do

- **Principal must return 100%.** `REGULATIONS.md`: the whole escape rests on nothing being
  risked upon the outcome. A lock delays; it must never reduce.
- **It must not hold the winner.** Only the side the verdict went against.
- **It must not make a claim unanswerable.** A systematic incentive to drain before the answer
  would push claims below the answerability floor on thin courts, where they then die unanswered
  and pay *nobody* — measured as the sharpest participation harm in the prior vet.

## 3. THE PROPOSAL — proportional, one claim-life

**`L = the claim's own life`** (from open to answer-freeze), applied to the losing side only,
after settlement. Bounded automatically: claim life is already capped at twelve weeks by the
dead-claim rule, so `L ≤ 12 weeks` with no new constant.

**Why proportional rather than flat.** A prior vet established this and my earlier draft had it
backwards: a flat lock sized for the twelve-week maximum over-penalises a one-week claim by up
to **12×**, while a proportional lock matches the commitment at every claim length. Claim life is
already bounded, so proportional needs no cap of its own.

**Why exactly 1× and not more.** It is the one multiple that needs no calibration argument and
can be stated in a sentence: **if you were wrong, your capital stays committed for as long again
as the claim ran.** Symmetric, explainable, and it doubles a loser's total commitment without
reference to any external rate — which matters, because the owner has ruled the carry framing out
of scope and every larger multiple would need one to justify it.

**What it does to straddling, stated honestly:** it does not eliminate it. It doubles the
capital-time a hedger must commit per unit of reward, which discourages rather than forecloses.
Larger multiples discourage more; the ones that *eliminate* it at the bonus tier run to several
claim-lives and are not proposed.

## 4. What must be built

1. **Condition the winning-side reward on the position still being staked at settlement** — the
   companion change from §1, without which the rest is inert.
2. **Lock the losing side for `L` after settlement**, releasing at `verdictAt + L`.
3. **Do not touch the winner's release**, and do not touch principal at any point.
4. **Keep the early release the losing side has today?** — open. Today the loser exits *before*
   the winner, deliberately (registered mitigation A12, against a freeze-hostage grief). The
   proposal reverses that, so either A12's grief returns or the lock must start from settlement
   rather than replace the early exit. **The vet must resolve which.**

## 5. Recorded as already-rejected, so it is not re-proposed

- **Netting one address's two legs** — address-keyed, and addresses are free. Theatre.
- **Slashing the loser** — destroys the regulatory position outright.
- **Keying the draw to the net lean** — measured *worse than the bug*: a griefer destroys ~2.2
  units of honest reward per unit of their own cost, with no bond and no information.
- **A lock without §1's companion change** — measured void.

## 6. What the vet must decide

1. **Is §1's companion change sound?** Conditioning the reward on presence at settlement reverses
   F9. Is a reward-presence condition genuinely separable from "principal is never hostage", or
   does it break something F9 protects? **This is the question the whole proposal rests on.**
2. **Does it close the drain-then-answer attack too**, and if so what does that let us simplify?
3. **`L = 1× claim life` — right, too little, too much?** Give a number with a reason that does
   not appeal to an external rate.
4. **§4.4: keep or replace the losing side's early exit?** Name what A12's grief costs if it
   returns.
5. **What does it cost an honest wrong staker**, and does it deter participation on thin or young
   courts specifically?
6. **Does it re-tax the honest contrarian** the bond re-keying just deliberately made cheaper?
   A prior vet found an outcome-keyed lock charges the honest 50/50 staker **2× more** than the
   straddler per unit of capital. Does conditioning-plus-lock change that incidence, or inherit it?
7. **Sybil check.** With the companion change, is the lock genuinely capital-keyed — i.e. does
   splitting across wallets still leave the losing capital locked?
8. **Regulatory: counsel flag, not decided.** Principal returns 1×, but the *duration* of the
   deprivation becomes outcome-contingent. Note both sides against `REGULATIONS.md` and do not
   assert a conclusion.

---

## 7. VET 2 — a cheaper companion, and §1 as written CONFISCATES an honest winner's reward

Isolated shadow, 10 new fixtures, the full 266-fixture committed suite run under three
configurations (baseline, companion-only, companion+lock).

### 7.1 THE COMPANION: presence at the FREEZE, not at settlement

One bool, one line, one clause:

```go
// stake.gno   — stakePos gains:  heldAtFreeze bool
// session.gno — WithdrawStake, before zeroing p.stake:  p.heldAtFreeze = true
// crystallize.gno — WithdrawBonus:
//   if p.stake <= 0 && !p.heldAtFreeze { panic("… drained before the answer …") }
```

`WithdrawStake` is the **only** path that can empty a position after the freeze (`Unstake` panics
on `frozenAt != 0`), so one latch at one site makes `p.stake > 0 || heldAtFreeze` mean exactly
"live when the answer landed". **No snapshot, no iteration, no new tree** — crystallize stays
walk-free.

| | measured |
|---|---|
| Full committed suite, companion alone | **266/266 green — zero fixtures break** |
| Drainer | **refused** (conviction 7,650,000 — non-vacuous) |
| Holder | paid 6,580,645 |
| Baseline drainer, same setup | 6,580,645 — **bit-identical to the holder**, locked 0 |
| **Bystander** (honest one-sided winner) | 9,890,552 in **all three** configurations |

**Why the freeze beats settlement — the load-bearing result.** A winning-side position *cannot* be
emptied between the freeze and the verdict: `Unstake` refuses (frozen) and `WithdrawStake` refuses
the side the provisional is *for*. So **on every non-flipping claim the two rules are the same
predicate** — and the freeze version needs no state to express it.

**And F9 is NOT reversed.** All four of its properties are untouched and `Unstake` is not edited at
all; the 1:2:4 conviction linearity was re-measured *on the patched tree*. What changes is the
payability of a reward on a position absent at the one moment the claim is priced — separable from
"principal is never hostage". The one real cost is a **cliff**: a full exit at week 11 of 12
forfeits 11 weeks of conviction. That is intrinsic to any presence rule and cannot be smoothed.

### 7.2 §1 AS WRITTEN CONFISCATES AN HONEST WINNER, AND IT IS ATTACKER-TRIGGERABLE

Measured end to end: an honest, one-sided, non-author, non-answerer YES staker held to the freeze;
an overturn made YES provisionally losing; **she took the early release the code offers her**; a
reopened uphold flipped the provisional back; Finalize made her the winner with `StakeOf == 0`. The
two latches disagree — `heldAtFreeze = 1, heldToVerdict = 0`.

> Under presence-at-freeze she is paid **5,483,870**. Under §1's "still staked at settlement" she
> gets **nothing** — for using an entitlement the realm handed her. **And the attacker chooses when
> the provisional flips.**

§1 is withdrawn. This is why.

### 7.3 Two alternatives that are not alternatives, and one real runner-up

- **"Scale the reward by the fraction of life held" IS the shipped rule.** Three positions held
  1×/2×/4× scored conviction **exactly 1:2:4**, and payout is `tier × (80/93) × own conviction`.
  So the reward is *already* linear in capital×time. **That is not an alternative to the lock — it
  is the reason the lock is needed.**
- **"Refuse `Unstake` with an answer pending" is already the case** — `frozenAt` is set inside
  `PostAnswer`, so there is no pending state, and creating one would be a free freeze-grief on
  anybody's stake plus a free option for the announcer.
- **Runner-up, genuinely cheaper: lock at the moment of UNSTAKING.** Outcome-**independent**, so it
  removes the regulatory hook rather than arguing about it; needs **no** companion change, no F9
  question, and leaves every hold-to-verdict staker — winner *and* loser — untouched; charges the
  straddler on **both** legs so it needs half the duration. **But it does not touch the
  hold-straddle** — it converts a drain-straddle into a hold-straddle rather than closing it, and it
  taxes honest early exits. **Cheaper and more robust, strictly weaker.** Worth keeping as the
  fallback if the counsel flag comes back hot.

### 7.4 THE DURATION — my `k = 1` is 8.6× oversized

**There is no better anchor, and that is itself a finding:** no existing constant is proportional to
claim life, because claim life is the only thing that is. The only reuse available is
`cs.openBlocks`, which §3 already implies. **So the multiplier is the entire decision.**

> **`R(k,d) = 1` ⟺ `p*(k,d) = 0.5000` identically, for all k and d — algebraically, not
> approximately.** Deterring the straddle and amputating the honest 0.474–0.500 band are **the same
> statement.**

| k | deters MID up to | honest break-even | band amputated | vs the 0.75 factor `ECONOMICS.md` **rejected** |
|---|---|---|---|---|
| 0 (today) | — | 0.4736 | — | — |
| **1/8** | cold only | **0.5020** | **0.028** | **0.45×** |
| 0.29 | d_eff 2 bps | 0.5351 | 0.062 | 0.97× ← ceiling |
| **1 (my §3)** | d_eff 10.1 bps | **0.6385** | **0.165** | **2.61×** |
| 1.53 | HIGH/cold | 0.6896 | 0.216 | 3.4× |

**Recommendation: `L = claimLife/8`, hard-capped at `escrowMaxBlocks` (3 weeks).** The `/8` is the
derived deterrence floor (0.1157, rounded up to a clean fraction). The cap is redundant at `/8` but
pins the invariant **an honest loser is never held longer than the code already holds an honest
winner** — so a later increase cannot violate it silently.

**Cost to an honest loser at `k = 1/8`:** on a 12-week claim, +37.5 bps — the cost of being wrong
rises **12%**, break-even confidence 0.4736 → 0.5020. On a 1-week claim, ~21 hours.

**The case against my `k = 1`:** every unit above the binding point is **pure amputation with zero
deterrence gain**, worst exactly where courts are coldest and thinnest. What it buys over `/8` is
MID courts with `d_eff ∈ (0, 10]` bps — and it **still** does not reach HIGH/cold (needs 1.53) or
MID/hot (needs 3.45). That coverage costs a band **5.9× larger** and **2.6× the amputation this repo
already rejected once.**

### 7.5 Thirteen things that break or need attention — five committed fixtures, all release-timing

The five: `TestDisputeUpholdPath`, `TestDisputeOverturnPath`, `TestDisputeFailedRoundsToProvClose`,
`TestSettleUndisputedAndWithdraw`, `TestWithdrawStakeDebitsItsOwnSidesPool`. **Nothing** in emission,
quality, drawcap, stakeseries, render, moderation, meta or crystallize.

**The ones that change the design:**

- **B13 — 14% of every draw escapes a gate applied only at `WithdrawBonus`.** **M:** a drained
  author was refused her winner slice and **paid the entire author slice, 1,482,603**.
  `AnswererBonus` reads no position at all. So `AuthorBonus` needs the same gate — and the
  self-dealt straddler (author + answerer + staker, the worst cell measured anywhere) is exactly who
  keeps it. §4.1's "the winning-side reward" is not enough.
- **B2 — a `provClose` claim would lock a side on a verdict the system refuses to name.**
  `provCloseClaim` sets `verdictAt` while `Verdict()` panics *"closed without a decision"*. Fix:
  `&& !cs.provClose`, one clause.
- **B5 — the lock closes FIVE bonded entrypoints**, not one: `Stake`, `OpenClaim`, `OpenDispute`,
  `OpenFlag`, the election bond. **`GAMETHEORY.md` §13.5 already measured this shape** — the
  contrarian's spendable is 0 and `PostAnswer` refuses, with F9 as the rescue. **The lock removes
  that rescue for L, on the thinnest courts, from the people most likely to be the court's only
  policeman.**
- **B6 — `Buy` is not gated on `spendable`**, so anyone with GNOT buys their standing back at the
  curve. **The non-carry bite lands only on the capital-poor.**
- **B7 — that half is sybil-evadable and the carry half is not.** `c.locked` is address-keyed:
  straddle with A on YES and B on NO, and whichever loses, the other wallet keeps all five verbs.
  **So B5's cost is regressive *and* evadable.**
- **B3/B4 — deleting the early release costs `escrowWindow + L`, not L**, and amplifies A12's
  hostage window ~15× (≈1 week today → ≈15 weeks at k=1).
- **B12 — a stale comment that reads the wrong way round.** `answer.gno` says *"escrowed stake is
  netted out of `votable`"*, but post-v0.34 staked CC is not in escrow. **M** with 20,000 CC locked:
  the locked holder's vote **carried a dispute to resolution.** Good news — the lock does not
  disenfranchise — but the code claims the opposite.

**And two simplifications:** `lock.gno` needs **zero new state** (the schedule is
`verdictAt + claimLife`, and its "a lock, not custody" contract is unchanged); and `claimLife()`
should be **hoisted** so crystallize and the lock share one expression rather than two copies of a
divisor whose re-anchoring already has a documented history of being forgotten.

**Refuted, and recorded:** nothing depends on the losing side leaving while the claim is live —
`advancePools` is a no-op past the freeze and the OI ring never saw the withdrawal anyway.

### 7.6 Liquidity and attacks

Steady state `X = W/(1 + kλ)`: at k=1 average stake falls **33%**; at k=1/8, **5.9%**.
**Answerability starvation is refuted** — the floor only widens from 0.10% to 0.15% of supply. What
binds is a proportional cut to everything keyed on X̄, mostly absorbed by the demotion-bar supply
floor that just shipped. Small self-correcting term: a smaller draw lowers `d_eff`, which lowers the
rate, which lowers the straddle's own profit.

**Refuted: lock-timing grief by answering.** The answerer picks whose capital gets locked, but the
max-keyed collateralization floor prices it out — the attack destroys **4–18× less than it risks**
at every claim length.

**Survives: the lock amplifies vote capture at zero additional attacker cost.** A successful
overturn already destroys the honest majority's whole reward while the disputer's bond returns and
comp mints to them, so their cost is already ≤ 0; the lock adds k units on top for free.
**+5.7% at k=1/8, +45.6% at k=1** — another reason the multiplier should be small.

### 7.7 Regulatory — counsel flag, sharper against than §6.8 assumed

**Against:** the deprivation is **not only time-value**. Because `mustSpendable` gates filing,
answering, disputing, flagging and standing for election, what turns on the outcome is a **bundle of
venue rights**, and its duration is outcome-contingent. PoolTogether's plaintiff had only forgone
interest on a withdrawable deposit.

**For:** voting weight is measurably **intact** (§7.5 B12), principal returns 1×. And the
**reversal-priced variant is outcome-independent**, which removes the hook rather than arguing it —
the fallback if counsel comes back hot.
