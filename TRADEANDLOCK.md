# TRADEANDLOCK.md — tradeable court coins

**Status: PLAN. BOTH PARTS LIVE — Part A (transferability) and Part B′ (universal unbonding,
winners exempt).** Part B (loser-only) stays superseded by B′.

- **(A)** `kourt:XYZ` court coins become **transferable**. Reputation does **not**.
- **(B′)** **Everyone** waits to exit; **winning exempts you**; switching sides is free. The penalty
  for losing is emergent — losers wait, winners don't, nothing is taken.

**§0's gate is required under both**, for two independent reasons now: it keeps the unbonding real,
*and* it stops staked capital being sold out from under a live stake. `spendable()` already nets
locked balances, so one gate does both.

**UX is a stated owner concern and it is the right one** — see §B′7, which is where the honest cost
of B′ lives.

Sequence: plan → review tokenomics until convergence → implement → review.

---

## 0. THE INTERACTION THAT DECIDES THE ORDER

**A lock is a spend restriction on coins that never leave the holder's balance** (`lock.gno`: "a
lock, not custody" — `releaseStake` moves no coin). So:

> **(B) is only real if `Transfer` refuses locked coin.** Ship (A) without gating `Transfer` on
> `spendable()` and the unbonding period evaporates silently — sell the locked position, keep the
> proceeds, and there is nothing left to hold. Both prior vets flagged non-transferability as a
> standing dependency of the lock for exactly this reason.

**Consequence: (A) and (B) must land together, or (B) first.** They cannot land (A)-first without a
window in which the lock is unenforceable. And `Transfer` must be `spendable`-gated **from its first
commit**, not as a follow-up.

---

## PART A — TRADEABLE COURT COINS

### A1. What changes

- Add a transfer entrypoint to the court coin's exported surface. **Gated on `spendable()`**, which
  already nets `lockedOf` from `BalanceOf`, so staked *and* unbonding capital is untransferable by
  construction rather than by a second check.
- The one-way bonding curve is **unchanged** — GNOT still enters once and is burned, there is still
  no burn-for-GNOT exit, and no treasury appears. Transferability adds a **secondary** market; it
  does not add a redemption.

### A2. What must NOT change — reputation

`answerRecord` is keyed by address, has **no `Remove`**, and no code path assigns one address's
record to another (verified earlier this session: three access sites, all `Get`/`Set` on the
caller's own or the stored answerer's address). **That property is what must be preserved**, and it
is *not* preserved by non-transferability of the coin — it stands on its own. So making the coin
tradeable does not, by itself, make reputation tradeable.

**But the ECONOMIC transferability of reputation is a separate question and is NOT closed by the
above.** The *use* of a credentialed address can be sold — rent-a-lead — and `GAMETHEORY.md`
already discusses credential laundering. This plan does not solve that and must not pretend to.
**Open item for the review.**

### A3. `check-nontransferable.py` must be rewritten, not deleted

Today it fails the build on any `Transfer`/`Approve`/`TransferFrom`/`Delegate`/`Sell`/`Send`/`Gift`
entrypoint, and its docstring's reasoning is *"a coin that cannot change hands cannot have its
accrued conviction sold."* **That sentence stops being true.** The guard must invert: stop
forbidding **coin** transfer, start forbidding **reputation** transfer — an entrypoint named
`AssignRecord`, `MigrateCredential`, `SetStanding`, `Bequeath` or similar would currently sail
through, because the existing pattern only matches coin-transfer verbs.

Its docstring must be replaced with what is actually true afterwards, and it currently records
three things that "need transferability to be false". **Each has to be re-opened or re-argued:**

1. **The v0.31 `electionFloor` keep-netting ruling** — its refutation of the
   park-stake-to-cheapen-a-coup vector turns on an attacker being unable to acquire existing float.
2. **`MODERATION.md`'s sybil doctrine** — *"only capital-keyed defences hold"* is stronger than it
   reads while capital itself cannot move between addresses.
3. **Vote-buying** — conviction accrues to a holder over time.

### A4. THE RISK I THINK MATTERS MOST, and it is not the legal one

**Nearly every safety bar in this realm is denominated in % of court supply**, and today the *only*
way to acquire supply is the one-way curve — which burns GNOT at a monotonically rising price. So
clearing a bar has a known, rising, non-negotiable cost. **A secondary market lets supply be
acquired at whatever it clears at, which may be far below curve price — so every bar may get
cheaper to clear at once.** The bars, enumerated:

| bar | protects |
|---|---|
| `quorumFloor` | whether a verdict can be reached at all |
| `qualityBars` demotion floor (1.25%, **added today**) | the cheapest attack in the system |
| `qualityBars` full bar (5%) | the slash, and tier promotion |
| `credEligible` (1.25%) | the answer-priority credential |
| `electionFloor` (5% of votable) | moderator capture |
| `supplyFloor` lid | filing priced above winning the vote |

**The review must price each of these against a secondary price rather than the curve price**, and
answer the doctrinal question directly: *is "only capital-keyed defences hold" still true when
capital becomes cheap to rent?* If it is not, the constants chosen against a resale threat the code
did not expose are no longer conservative — they are calibrated for a world that just ended.

### A5. Regulatory delta — flagged, not decided

`REGULATIONS.md` §6 lists non-transferable positions as *"helps securities, can forfeit preemption;
product cost"*, and notes elsewhere that governance + utility + yield together *"all pull back
toward Howey"*. **Transferability adds a market, therefore a price, therefore a profit
expectation** — a direct hit on the prong the file says is load-bearing. Against that, the
2026-08-20 append-log entry finds CLARITY's **network token** / **ancillary asset** definitions may
fit a court coin, and a market-structure category presupposes a market. **Counsel flags both ways;
this plan asserts nothing.**

---

## PART B — LOSER UNBONDING PERIOD

Converged over four vets in `LOSERLOCK.md` §7–8. Restated here as the build spec.

### B1. The companion change, without which the lock is void

A lock at settlement holds nothing today: `Unstake` keeps conviction (F9) and the reward never
checks the position still exists, so a straddler drains both legs before the freeze and is paid in
full. **And it must be a SCALE, not a condition** — as a condition, keeping one base unit of a
hundred passes the check and pays the whole reward.

```
pay ≤ conviction-gross × min(1, stakeAtFreeze / timeAveragedStake)
```

- **Never-unstaked ⟹ factor exactly 1**, so an honest staker is **bit-identical to today**. The
  mean of a non-decreasing function is at most its final value, so this is a proof, not a
  measurement. Top-ups are never penalised.
- **Non-increasing ⟹ computes `∫min(stake(t), stake_freeze)·dt` exactly** — pro-rata on what
  remains, derived rather than chosen.
- **Full drain ⟹ zero**, no special case.

**Applied inside `capBonus`** (scale-then-cap, per that file's own discipline) so **both**
`WithdrawBonus` and `AuthorBonus` inherit it. `AuthorBonus` is not optional: without it, 13/93 —
**14% of every draw** — escapes the gate, and the self-dealt straddler who is also author and
answerer is exactly who keeps it.

**This does not reverse F9.** F9 is about the integral (capital conservation, game-proofness);
"principal is never hostage" is split settlement, a different mechanism. No accumulator changes.
The narrow real cost: *withdraw the forecast, then be right anyway* stops paying.

### B2. The duration: `L = 1 × claim life`

The reason is in the shipped constant. `rateBpsFP`'s `2.55 = 0.85 × 2 × 1.5`, and **that 1.5 is the
assumed lock-to-claim-life ratio, measured at 1.039** because the escrow half was never built.
Stakers have been **paid for a 1.5× lock and served 1.039×**. A one-claim-life loser lock delivers
`1.039 + 0.5 ≈ 1.5` in expectation at a coin flip.

> **`L = 1×T_c` is the length at which the code finally delivers the lock its own published rate has
> been billing for.** No external rate (ρ cancels), no new constant (`claimLife` is already computed
> and already capped at twelve weeks).

Range check: `λ = 0.115` is the minimum that deters; `λ = 1.459` is where the honest break-even
reaches the design's **own** documented `p_min ≈ 0.684`. **λ = 1 sits inside with 0.045 headroom** —
it moves the break-even 0.474 → 0.639, *toward* the design's target rather than past it.

**What it closes:** the ordinary tier and the self-dealt variant. **What it does not:** the bonus
tier and hot courts, which need λ ≈ 1.67 and 3.45 — both outside the design's own envelope. **Say so
rather than implying coverage.**

### B3. The early exit must go

It keys on the **standing** provisional, which a dispute chain flips, so a lock keyed to the final
verdict would have nothing to hold on **either** side. And the side it releases is **exactly** the
side the lock holds. Re-locking later is worse — freed capital may be committed elsewhere meanwhile,
making `lockedOf > BalanceOf` and falsifying `spendable()`'s stated invariant.

**A12's grief returns, bounded:** disputed claims only (undisputed already releases both sides
together, so the modal path is unchanged); **the griefer's own terminal path is exempt via an
explicit `!cs.provClose` clause**; capped by `escrowUntil` (≤ 3 weeks) which the winner already
serves; and conviction pays zero either way.

### B4. Build list

1. `stakePos` gains `released int64`, written by `WithdrawStake` before it zeroes `stake`. Post-
   freeze `stake + released` **is** the stake at the freeze, because both `Stake` and `Unstake`
   refuse once frozen.
2. `capBonus` takes the position and applies the scale **inside** the F9 bound.
3. `WithdrawStake`: **delete the early-exit clause**; refuse while `isLockedSide && !pastRelease`.
4. `pastRelease` **date-gated with a height fallback** (per `clock.gno`'s ruling that a published
   deadline must be block time); `ReleaseAt(slug, id, side)` publishes it.
5. `claimLife()` hoisted — **one** definition shared by the lock and crystallize's F9 denominator,
   replacing the same expression written twice.
6. `Transfer` gated on `spendable()` — **§0**, non-negotiable.

**Accepted side effect:** a forfeited share stays in `juniorReserved` and is never minted — the same
channel already used for cap-cut, dust, seeded authors and overturned answerers. A delay, not a
loss, but it can transiently tighten the next claim's reservation.

**Known and inherited, not fixed:** per unit of committed capital the lock charges the honest 50/50
staker **2× more** than the straddler, because at p = ½ the two positions are arithmetically
identical. It re-taxes what the bond re-keying deliberately made ~6× cheaper. §B2's envelope
argument is the answer, not a denial.

---

## WHAT THE REVIEW MUST CONVERGE ON

1. **§A4 — do the supply-denominated bars survive a secondary market?** Price each against a market
   price rather than the curve. **If this is severe, it outranks everything else in this plan.**
2. **§A2 — can reputation stay non-transferable in economic substance**, or does rent-a-lead defeat
   it? What, if anything, prices that?
3. **§A3 — the three re-opened rulings.** Does the `electionFloor` netting ruling survive? Does the
   sybil doctrine? Is vote-buying now live?
4. **§0 — is `spendable`-gating `Transfer` sufficient** to keep the lock real, including the
   `lockedOf > BalanceOf` edge?
5. **§B — anything the four prior vets missed**, now that transferability is in the same change.
6. **Ordering:** (A)+(B) together, or (B) then (A)? §0 argues never (A) alone.
7. **Counsel flags** for §A5, stated not decided.

---

## PART B′ — SUPERSEDES PART B: universal unbonding, winners exempt

**Owner's revision, and it is a better mechanism than Part B.** In their words: *"make the unbonding
period something everybody has to wait, unless they win. you can switch sides, but you can't just
withdraw, you need to wait. then, naturally, there is a penalty for losing, because you don't
benefit from winning."*

### B′1 The rule

- **Unbonding applies to EXIT, for everyone.** That is the baseline.
- **Winning exempts you** — a winner releases immediately.
- **Switching sides is free**, at any time, with no wait.
- **The penalty for losing is emergent**: losers wait, winners don't. Nothing is taken, nothing is
  slashed, principal is untouched.

### B′2 Why this is better than Part B — three reasons, and the third is the one I missed

1. **It may make the presence scale UNNECESSARY.** Part B needed the scale because the drain attack
   (unstake both legs before the freeze, collect anyway) made a settlement-time lock void. **But if
   unbonding applies to unstaking generally, the drain is closed directly** — you cannot exit early
   without waiting either. If that holds, `stakePos.released`, the scale, and the `capBonus` surgery
   all disappear, and the change becomes far smaller. **Under review.**
2. **It fits F9's rationale instead of straining it.** F9 exists so *"honest belief-updating is never
   punished"*. Here belief-updating — switching sides — is **completely free**; what is constrained
   is *exit*, a different act. Part B narrowed F9; this may not touch it at all.
3. **The regulatory shape improves, and this is the strongest argument for the revision.** Part B
   made the **duration of deprivation** outcome-contingent, which was the sharpest objection in four
   vets and the one I could not weaken. **B′ makes the baseline uniform and outcome-INDEPENDENT —
   everyone waits — and makes early release a reward for winning.** So what turns on the outcome is
   a **benefit**, not a deprivation. Against `REGULATIONS.md`'s operative test — *"staked or risked
   **upon the outcome**"* — a uniform wait is not something risked on the outcome; it is a condition
   of participating at all. **Counsel flag, not a conclusion, but the shape is better and that is
   worth having checked rather than assumed.**

### B′3 The ambiguity I resolved, and the reading I took

*"You can't just withdraw, you need to wait"* could mean **only post-verdict withdrawal**, or
**exit at any point in the lifecycle**. **I took the latter**, because it is the reading that
simultaneously closes the drain, makes the loss penalty emergent, and keeps belief-updating free —
the three things the revision is for. The narrower reading closes none of them and reduces to
Part B. **Flagged for the review to contradict if it sees something I don't.**

### B′4 THE HOLE I CAN SEE, and it needs pricing before this ships

**The exemption is binary; conviction is not.** Someone can switch to the winning side late —
earning almost no reward, since conviction is capital×time — and still collect the **immediate
release** exemption in full. So a straddler could hold both sides, watch the verdict form, and
consolidate onto the winner to escape the wait entirely.

If that lands, the exemption must be **conviction-weighted**, or keyed to the position **at the
freeze** rather than at the verdict. Note the second option quietly reintroduces a
presence-at-freeze notion — so §B′2's hoped-for simplification may not survive this hole. **This is
the first thing the review must price.**

### B′5 Duration — re-derive, do not assume

Part B's `L = 1 × claim life` rested on the shipped rate constant billing for a 1.5× lock and
delivering 1.039×. **That arithmetic assumed only the loser serves time.** Under B′ **both sides
serve time in expectation**, so the delivered lock is longer at the same `k` and the honest
break-even moves further. **Re-derive.** If it lands past the design's own documented `p_min ≈ 0.684`
the `k` must come down — the envelope argument was the whole justification for `k = 1` and it does
not survive being exceeded.

### B′6 Unchanged from Part B

`Transfer` gated on `spendable()` from its first commit (§0); `!cs.provClose` exemption; `claimLife()`
hoisted and shared; date-gated with a height fallback; `ReleaseAt()` published. And §A is untouched —
the supply-denominated-bar question is about transferability, not about the lock.

---

## §B′7 — UX, and the posterity finding

### The record does NOT keep the yes/no amounts. Checked, and it is a real gap.

**Conviction survives forever; the stake amounts do not.**

- `cs.yesConvHi/Lo` and `cs.noConvHi/Lo` are written by `add128` **only** — monotone, never
  decremented. The money×time weight each side carried is permanent, and it is frozen at the answer.
- **But `cs.yesStake` / `cs.noStake` are DECREMENTED on every withdrawal** (`WithdrawStake`). So once
  the participants have taken their principal home, **both read zero.**
- And `render.gno` displays the **live** figure, labelled *"instantaneous"* — so a settled claim's
  page eventually shows **`YES 0 / NO 0`**.

> **That visually breaks a promise the whitepaper makes in its introduction:** *"Win or lose,
> everything stays: every claim, every stake, every verdict, every dissent."* The *data* that
> matters — conviction — does stay. The **headline amounts** do not, and the page shows the drained
> value rather than the historical one.

**Nor is the raw per-side stake at the freeze recoverable.** `xBarFrozen` is the claim's
*time-averaged total*, not a per-side snapshot, so "how much was on YES when it was answered" is
**not stored anywhere** once positions drain.

**Fix, and it is small:** snapshot `yesStake`/`noStake` at the freeze into two new fields, and have
`render` show the frozen pair (plus conviction) for any answered claim rather than the live pair.
Cheap, no new invariant, and it makes the introduction's claim true rather than nearly-true.
**Independent of both A and B′ — worth doing regardless.**

### The UX cost of B′, stated rather than buried

**This is the honest downside and the owner named it before I did.**

1. **"I want my money back" now has an answer that is sometimes "not yet".** Today an exit is
   immediate; under B′ it is immediate only if you won. That is the single biggest change to how the
   product *feels*, and no amount of correct game theory softens it.
2. **The wait must be legible before it is incurred, not after.** A user needs to see, at the moment
   of staking: *what am I committing to, and when could I get it back at the earliest and the
   latest?* If that is only discoverable after the verdict, the mechanism is a trap regardless of how
   fair the arithmetic is. `ReleaseAt()` exists for this and must be surfaced in the UI, not just
   published on-chain.
3. **"Switching sides is free" is the mitigation and must be presented as one.** The honest framing
   is *your capital stays in the court until you're right; your opinion is never locked.* That is
   both true and reassuring, and it is the difference between this reading like a penalty and like a
   commitment.
4. **Winners must feel the exemption**, or the asymmetry does no work as an incentive. Being right
   should visibly buy something immediate.

**None of this is a reason not to build it** — but it is a reason the render work is part of the
change rather than a follow-up.
