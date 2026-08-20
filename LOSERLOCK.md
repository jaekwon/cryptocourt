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
