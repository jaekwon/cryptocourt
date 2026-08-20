# STRADDLE.md — the both-sides profit, and the delayed-release fix

**Status: PROPOSED, NOT AUDITED, NOT IMPLEMENTED.** Written before vetting so the vet has a
fixed target. Owner's idea; my earlier suggestion (netting one address's two legs) was
rejected correctly and is recorded in §4 as the wrong answer.

---

## 1. The bug, and why it pays

Staking **both** sides of one claim is profitable today, risk-free. Measured (`TODOs.md` §0a):
600 CC as 300 YES + 300 NO on an 11-week claim draws **18.096774 CC** against **16.500000 CC**
of carry — **+1.596774 CC, +1.26%/yr, riskless**.

**Why**, derived and then checked against that measurement:

```
payout = tier · mult · (r0 + d_eff) · T · share      (the winning leg)
carry  = r0 · (2T + L)                               (both legs; L = extra lock on the loser)

return/carry = tier · mult · share · (1 + d_eff/r0) · T/(2T + L)
```

with `mult = 2.55` (`rateBpsFP`), `share = 80/93` (winners' slice), `r0 = 25` bps/wk
(`r0WeeklyBps`). At `L = 0, tier = 1, d_eff = 0` this gives **1.09677**, against a measured
**18.096774/16.500000 = 1.09677**. Exact to five digits, so the model is the mechanism.

**The one-line reason: the straddler pays carry on TWO units and is paid on ONE**, so it wins
whenever the payout rate exceeds twice the carry rate. It does, by 9.7% at the coldest setting —
`mult` would have to fall below `2/share = 2.325` for the ordinary tier to break even, and it is
**2.55**.

**It is profitable at every tier and every rate.** No parameter choice removes it, because
`tier·mult·share·(1 + d_eff/r0) ≥ 2.194 > 2` always.

## 2. Why the two obvious fixes are closed

**Slashing the losing side is the one thing that cannot be done.** `REGULATIONS.md:18-21`: no U.S.
prediction market has ever been held "not gambling" on the merits by relabeling; the two proven
escapes are (a) become a regulated derivative or (b) **remove the wager substance**, and this
design takes (b). That rests on exactly one fact — **principal always returns 1×, so nothing is
risked upon the outcome.** Slash one basis point and consideration + chance + prize all line up,
and the payout becomes a bilateral event-contingent transfer, i.e. a swap in exclusive CFTC
jurisdiction. Intrade was pure P2P and was killed anyway.

**Cutting the rate is a dead end.** `mult` would need to drop from 2.55 to below 2.325 — a ~9% cut
to *everyone's* yield — and that only fixes the ordinary tier at the cold rate. The bonus tier
stays profitable at any positive multiplier.

## 3. THE PROPOSAL — delay the losing side's release

**Costs time, not principal.** The loser still gets 100% back, just later. So the sentence the
whole regulatory position rests on stays literally true.

**And — the reason this is better than my suggestion — it is CAPITAL-KEYED, not address-keyed.**
Whether you straddle with one wallet or fifty, the losing capital is locked either way. There is no
sybil evasion because there is nothing to evade: the penalty attaches to the *coins*, not to the
*identity*. That is this repo's own root doctrine (`MODERATION.md`), and it is exactly why netting
fails and this does not.

### 3.1 The lock length needed, derived

`return/carry < 1` requires **`L > T · (tier · mult · share · (1 + d_eff/r0) − 2)`**:

| tier | d_eff | return/carry at L=0 | lock needed | on a 12-week claim |
|---|---|---|---|---|
| MID | 0 (cold) | 1.097 | **0.194 × T** | **2.3 weeks** |
| MID | 19 | 1.930 | 1.861 × T | 22.3 weeks |
| MID | 38 (hot ceiling) | 2.764 | 3.528 × T | 42.3 weeks |
| HIGH | 0 | 2.194 | 2.387 × T | 28.6 weeks |
| HIGH | 19 | 3.861 | 5.721 × T | 68.7 weeks |
| HIGH | 38 | 5.528 | **9.055 × T** | **108.7 weeks** |

**So the common case is cheap and the extremes are brutal.** A ~2.3-week extra hold kills the
ordinary/cold straddle. Killing it everywhere needs a **9× claim-life** lock — over two years on a
twelve-week claim — which is not a serious proposal.

### 3.2 The three shapes this could take

- **(a) Flat lock**, e.g. one settlement period. Kills ordinary/cold. Leaves the bonus tier and hot
  courts profitable. Cheapest to build, easiest to explain, honest about its scope.
- **(b) Proportional lock**, `L = k·T`. Self-scaling with claim life. Still needs `k ≥ 9` for the
  worst regime, so in practice it is (a) with extra steps unless `k` is large.
- **(c) Lock keyed to what the claim actually paid** — scale `L` with `tier` and the realized rate,
  so the lock is long exactly where the straddle is profitable. Most precise, most complex, and it
  makes an honest loser's wait depend on a number they could not see when they staked.

**(A) My inclination is (a), sized to the ordinary/cold case, and to state plainly that the bonus
tier is not closed.** But this is the question for the vet, not my call to make alone.

## 4. Recorded as the WRONG answer: netting one address's two legs

I proposed subtracting an address's YES and NO before paying. **It is theatre.** The defence is
address-keyed and addresses are free, so it costs an attacker one extra wallet and nothing else —
and two addresses on opposite sides are *observationally identical to two people who genuinely
disagree*, so no rule can separate them. I recommended it while simultaneously admitting it does
not work, which was incoherent. It is in this file so it is not proposed again.

## 5. What the vet must decide

1. **Does it actually survive sybils?** §3's central claim is that the lock is capital-keyed and
   therefore sybil-proof. **Attack that.** Can a straddler get the losing capital out early — by
   unstaking before the verdict, by moving the position, by choosing which side is "losing", by
   arranging a provisional that flips? `Unstake` behaviour before the freeze is the obvious place
   to look.
2. **It REVERSES a deliberate current behaviour, and the reversal needs justifying.** Today the
   losing side is released **early** — `session.gno` releases the side a standing provisional is
   against, specifically so their capital is not hostage, and that property was used as an argument
   *against* a longer settle window. This proposal makes holding the loser's capital a feature. Say
   whether that is defensible, and what else was resting on the early release.
3. **What it costs an honest wrong staker**, in yield terms, at each candidate lock length. An
   honest loser already forfeits the reward; this adds a time cost on top.
4. **Does it fight the bond fix?** The re-keyed bond just made honest *contrarian* answers ~6×
   cheaper, deliberately, because the system needs unpopular positions. A lock penalises being
   wrong, and the honest contrarian is the most likely to be wrong. **Quantify whether this
   re-taxes exactly the behaviour the bond change just subsidised.**
5. **The regulatory question, flagged not decided.** Principal returns 1×, but the *time value* of
   the losing side is now contingent on the outcome. Is forgone yield "something of value risked
   upon the outcome"? It is far safer than slashing and it is not obviously free of the question.
   **Counsel flag; do not assert either way.**
6. **Which shape** — (a), (b), (c), or something else — and the concrete constant.
7. **Is it worth doing at all?** At the ordinary tier the straddle earns ~10% above carry while an
   honest staker earns **12× that with risk**. Say plainly whether the cure is proportionate, or
   whether the honest answer is to fix `WHITEPAPER.md`'s false claim (§2 asserts staking both sides
   "buys nothing") and accept the spread.

---

## 6. VET 1 — **DO NOT BUILD IT.** The lock leaks twice, and its incidence is upside-down.

Isolated shadow, six fixtures, full suite green, each asserting its own non-clamping precondition.

### 6.1 "Capital-keyed therefore sybil-proof" is TRUE and IRRELEVANT

My §3 argument was that the penalty attaches to coins rather than identities, so there is nothing
to evade. Correct — and beside the point. **The lock can only attach to coins still staked at the
verdict, and the reward is not conditioned on them being there.** `WithdrawBonus` gates on
`bonusPaid` and `side == provisional` only — never on the position — and `Unstake` deliberately
*keeps* conviction (F9). So the penalty attaches to capital the straddler has already withdrawn.

**Leak 1 — drain both legs before the freeze.** **M**, twin straddlers, one holding to the verdict
and one releasing both legs the block before the answer: payouts **asserted equal**, drainer's
locked balance **0**, and `WithdrawStake` on the losing side panics "nothing staked on that side".

**And it is not a race.** Draining at 4 weeks and at 8 weeks of the same claim both return
**10,967 bps of carry — identical to five digits**, because payout and carry scale linearly
together so the *rate* is invariant to exit time. No freeze can catch him; he can also *be* the
answerer, unstake the leg he is about to declare against, and answer in one sequence.

**The tree already knew this and I misread which problem it had solved.** `PostAnswer`'s own
comment says a pool that banked eleven weeks and drained "still carries a 100k-CC prize". That was
priced as a *bond-sizing* problem and fixed with the `lifeAvgStake` max(). **The prize surviving
the drain was left intact deliberately** — and it is exactly what makes a post-verdict lock
uncollectable.

**Leak 2 — a flipping provisional releases both legs.** `WithdrawStake` releases whichever side the
*standing* provisional is against, and over a dispute chain that flips, that is both sides in turn.
**M:** withdrew NO after an uphold, YES after an overturn, locked balance **0** with `verdictAt`
still 0, winning leg **still paid**. So a lock keyed to the final verdict is void on any claim whose
provisional flips once — the fix cannot re-key the release, it has to **delete** it.

Routes checked and closed: no position transfer exists, CC has no user-facing transfer at all, the
lock is per-court, purge touches no money. **But note the dependency that creates:** the lock is a
bookkeeping row against a balance the realm does not hold, so it bites *only* because CC is
soulbound — and `check-nontransferable.py`'s own docstring records that MODERATION.md wants meta-CC
transferable, i.e. spec and code already disagree. **The day a transfer entrypoint lands, a delayed
release evaporates silently.**

### 6.2 It reverses a REGISTERED MITIGATION, not merely a behaviour

`PLAN.md` **§A12**: the early release is the designated fix for the provClose freeze-hostage
(*"stakers frozen ~8 weeks, conviction pays zero"*), status **MITIGATED (F7+v0.20)**. Removing it
does not restore a hostage — it **arms an amplifier**, since a griefer's hold becomes the
multi-round grind *plus* L. Three more things rest on it: `WithdrawStake`'s doc contract states the
path "is unpausable: … nothing downstream may hold principal", which this **contradicts**; live
fixtures assert the loser exits 1× while the winner is refused; and pool bookkeeping depends on the
early exit happening *while the claim is live*.

### 6.3 THE RESULT THAT SHOULD DECIDE IT — the incidence is exactly backwards

Per unit of committed capital the lock is **exactly 2× harder on the honest wrong staker than on
the straddler it targets**: the straddler commits 2X and has one X locked; the honest staker commits
X and has all of X locked. In expectation the honest staker bears `(1−p)·L`, the straddler bears
`L/2` **with certainty** — equal at **p = 0.50**, against today's break-even confidence to stake at
all of **p\* = 0.474**.

> **So every honest staker in the band the design most needs — 0.474 to 0.50, the genuine
> contrarian — pays MORE lock than the straddler the lock exists to punish.** That is §4's
> observational-equivalence failure arriving through the **capital** door instead of the address
> door: netting could not tell two disagreeing people from one straddler, and this cannot tell an
> honest 50/50 staker from half a straddle.

### 6.4 And the bug is ALREADY bounded twice, by clamps that shipped

| | net on 600 CC | annualised |
|---|---|---|
| straddler, holds both legs | +953,917 | **+0.72%/yr** |
| straddler, **drains** (the dominant play) | +1,596,774 | **+1.26%/yr** |
| honest **correct** one-sided staker | +19,070,275 | **+14.46%/yr** |

Honest earns **11.5× the drain and 20× the hold**, with risk. And:

- **The draw cap binds at the bonus tier.** **M:** `paid 29,701,653` against `uncapped 36,173,963`
  — exactly the cap's own prediction. So the bonus tier pays **1.80×** carry, not §3.1's 2.194×.
  A clamp I landed for another reason already took the worst cell off the table.
- **The period budget bounds the size.** In a thin court (600 CC straddled against 2,106 CC of live
  supply) the draw clamps 18,086,981 → 6,252,991 and **the straddle LOSES** — 3,651 bps of carry.
  Break-even one-leg size is ~5.7% of live supply; **above ~11% straddled it is loss-making.**

**So it is a self-limiting sub-2%/yr spread, capped in tier by one shipped clamp and in size by
another, against a cure that one address evades, that costs the honest contrarian twice what it
costs its target, and that requires deleting a registered mitigation. The cure is grossly
disproportionate.**

### 6.5 The whitepaper has TWO false sentences, and the second is worse

1. *"It buys nothing."* — false; it pays 1.0967× carry at the coldest setting.
2. *"Staked coins sit in escrow, where they carry no vote, so a hedger gives up voting weight on
   both halves."* — **this describes custody that was DELETED in v0.34.** `lock.gno`: staked CC
   "stays in the holder's own balance and keeps voting", and custody "bought exactly one thing:
   disenfranchisement", removed on purpose. **So the whitepaper's stated REASON the straddle costs
   something no longer exists in the code.**

### 6.6 My arithmetic priced the DRAIN, not the hold

The model's carry term runs to the freeze and drops the settle window on both legs, so it prices the
*drained* straddle. Holding to the verdict returns **1.0556**, not 1.0968 — and my §3.1 lock column
is over-stated by ~2S/T throughout. Corrected, with the bonus rows also moving because the draw cap
landed *after* my table was written:

| tier | d_eff | my R₀ | true R₀ | my L/T | true L/T |
|---|---|---|---|---|---|
| MID | 0 | 1.097 | **1.097** | 0.194 | **0.116** |
| MID | 38 | 2.764 | 2.764 | 3.528 | 3.450 |
| HIGH | 0 | 2.194 | **1.802** | 2.387 | **1.53** |
| HIGH | 38 | 5.528 | **4.23** | 9.055 | **6.38** |

**And §3.2's shape preference was backwards:** proportional dominates flat, because `k = 0.2` kills
MID/cold at *every* claim length while no flat constant does — a flat lock sized for the 12-week
maximum over-penalises a one-week claim by up to **12×**.

### 6.7 Regulatory — COUNSEL FLAG, both arguments live and both already in the file

**For:** the append-log entry on **Kent v. PoolTogether** is directly on point — a no-loss crypto
protocol, dismissed for want of standing because principal was withdrawable, with forgone interest
expressly called *"a problem of his own making."* The most favourable data point in the file.

**Against:** the *next* entry cuts the other way — prize-linked savings needed a **statutory**
exemption to make returnable deposits the "sole consideration", so "principal returns ⇒ no
consideration" is not enough on its own. The operative test the file adopts is *"staked or risked
**upon the outcome**"*, and today nothing about a staker's position turns on the verdict except an
emission-funded reward. **A delayed release makes the duration of the deprivation
outcome-contingent — a change in kind, not degree.** Kent was standing-only and the file notes it
"blocks private suits, not AGs".

---

## 7. THE ANSWER

**Do not build it. Fix the whitepaper's two false sentences, record the straddle with its measured
bounds, and accept the spread.** It is ~1.3%/yr riskless against 14.5% for taking a view, already
capped in tier by the draw cap and in size by the period budget, and loss-making in a thin court.

**A method note for `AGENTS.md`:** `scripts/gnoroot.py` resolves the real GNOROOT by shelling
`gno env GNOROOT`, which returns a *sandbox-relative* path when cwd is outside the checkout, so
`build` fails with "no GNOROOT" unless `--root` is passed. Every shadow-staged vet hits this.

---

## 8. VET 2 — an impossibility result, and the actual root cause

Independent of vet 1, same conclusion, deeper reason.

### 8.1 The straddle is not a mechanism. It is an algebraic identity.

`D = tier × midGross` split pro-rata over `midGross` means **`midGross` cancels**: a staker is paid
`tier × (80/93) × own conviction`, **independent of pool size.** **M, bit-exact:** the same
straddler, with and without a 21× larger honest pool on its winning side, was paid `603878647`
**both times — delta 0.** The honest bystander moved by **one base unit** (double-floor dust).

So a straddler's payoff is exactly `½·winner + ½·loser`:

> **The straddle IS the p = ½ point on the honest staker's own payoff line** — at every tier, rate
> and claim length. **M:** honest break-even `p* = 0.4731`; the straddle sits at **0.5000** exactly.

**Which gives an impossibility result: any cost linear in staked capital-time prices the straddler
and the p = ½ honest staker identically, because they are the same portfolio.** So every candidate
either fails to separate them, or leaves the linear class and hits a closed door.

### 8.2 The whole candidate list, priced

| candidate | verdict |
|---|---|
| **entry fee on capital-time** | Sizes exactly at **ψ = 2.42 bps/wk**, and is **the only lever the F9 drain cannot escape** (charge and reward scale with exit time together). Costs an honest staker *half* what the rate cut does. But it moves the honest break-even to 0.500 too — same theorem. Humphrey factor 1 (fees paid win-or-lose), and `REGULATIONS.md` says the load-bearing prong is "risked **upon the outcome**", not "no consideration" — **counsel flag, not a bar.** The only survivor. |
| payout excludes own contribution | Sole honest staker earns **0**. Sybil factor `(1 − 1/N)`, and `buy.gno` mints to the caller so N wallets are free. **Dead.** |
| cap one address's share | Same sybil escape; on a thin court the only staker is the whale it caps. **Dead.** |
| **draw keyed on the LEAN** | **Measured, and worse than the bug.** A pure griefer staking the losing side destroyed **2.196 units of honest reward per unit of its own carry** — principal 1×, no bond, no answer, no vote, no information; 4.4× at HIGH. It re-opens the pool-annihilation attack the draw cap was built to bound, **uncollateralized**. It does not even kill the straddle (1.046), a genuinely 50/50 claim pays its winners **0**, and it flunks Humphrey factor 2. **Four independent refutations.** Note `WHITEPAPER.md` §2 already claims "the lean measures net stake" — the *draw* does not key on the lean, and this is why it must not. |
| tighten `capBonus` | At the binding point it **is** the rate cut, exactly. |
| slash the loser | Closed regulatorily — **and it would not have worked anyway**, because F9 empties the position before settlement so there is nothing to slash. |

**The closest thing to a fix "not on the table" is one the design gave away.** The whitepaper's own
stated reason — escrowed stake carries no vote, so a hedger pays twice — is the *correct shape*:
capital-keyed, outcome-independent, sybil-proof, and it charges two legs against one. `lock.gno`
deleted custody deliberately ("bought exactly one thing: disenfranchisement"). That reasoning is
sound on its own terms and wrong about the consequence: **custody's value was never the principal,
it was the vote, and the vote is what prices a hedge.** Restoring it would need the forgone vote
worth ≥1.27%/yr of staked principal; the carrot flow is ~0.5%/yr and per-voter clamped, so **it does
not reach.** Recorded, not re-litigated.

### 8.3 THE ROOT CAUSE — an unbilled lock premium

`rateBpsFP`'s **2.55 = 0.85 × 2 × 1.5**, and that 1.5 is `ECONOMICS.md`'s `T_L/T_c` — *"lock time:
stake → withdraw (≈ 1.5 × T_c: adds 72h + escrow)"*. **The "+ escrow" term was never built**:
`WithdrawStake` is explicitly unpausable, so principal is never held past the verdict.

**M: `T_L/T_c` = 1.0389, against 1.5 assumed.** The anti-farming margin is
`1.09677/(T_L/T_c) − 1`: at the assumed 1.5 it is **−26.9%** (safe); at the delivered 1.039 it is
**+5.6%**.

> **The straddle IS the gap between the lock time the rate was priced for and the lock time the code
> delivers.** And `ECONOMICS.md` propagated the 80/93 correction to the honest break-even
> (0.59 → 0.68) but **not** to the farming threshold.

### 8.4 Three more corrections to my §3.1 — all overstatements

- **Carry omits the 72h settle both legs already serve.** True ratio against `T_L` carry is
  **1.0557**, not 1.0968, so **every lock row is overstated by 6 days** — the MID/cold case needs
  1.47 weeks on a 12-week claim, not 2.3.
- **The bonus rows ignore `aeba536`.** The draw cap **binds at HIGH and is inert at MID** (`want
  42120534 > capd 34525782`), so HIGH/cold is **1.800**, not 2.194 — independently matching vet 1 —
  and my worst row is ~6.4×T rather than 9.055×T.
- **I modelled only the winners' slice.** A straddler who is *also author and answerer* takes 93/93
  of D: **M, ratio 1.2764 — +27.6% above carry, 2.8× the headline**, needing a 0.55×T lock.

### 8.5 It is not risk-free in aggregate — and one open item would remove the margin

LOW pays the straddler **0**; a dead claim pays **0** and never crystallizes. So `E > 0` requires
**P(claim reaches a ≥MID crystallize) > 91.1%** (78.3% for the self-dealt variant).

> **Any court where more than 1 in 11 claims dies unanswered, is voted conclusive-LOW, or fails to
> crystallize prices the ordinary straddle out with no code change at all.**

**⚠️ Sequencing conflict:** `TODOs.md` §4 proposes making dead-claim conviction recoverable. **That
removes this 8.8% margin**, which is currently doing most of the work at the ordinary tier. Two open
items point in opposite directions and must be sequenced deliberately.

### 8.6 Crowding out, and why priority follows the court's success

Self-minting means the payout channel has **zero** interaction between stakers, so the *only*
dilution channel is the budget clamp — and there the transfer is exact: **M**, the honest whale lost
`164594773` while the straddler took `164594772`, **1:1**. Clamping needs ~55% of supply on the
winning side at MID/cold (unreachable — and straddling actually *relieves* the pressure) versus
**~22% at the hot ceiling**. With 30% honest at p = 0.7, the tipping straddle fraction is **~68% of
supply cold, ~1.5% hot.**

**And the two regimes coincide.** `d_eff = min(budget, EMA(minted)/supply)`, so **a hot court is by
definition a clamped court.** Cold: +5.6%, the harm falls on emission and nobody is robbed. Hot: up
to +176%, the clamp binds, and the harm falls on honest stakers **1:1**. Compounding it, the reward
scales with `r + d` while the *differential* carry of staking-versus-holding is only `r` — dilution
hits staked and unstaked CC alike — so `ECONOMICS.md`'s `ρ = r + d` is right for the *buy* decision
and wrong for the *stake* decision, and **the anti-farm margin degrades linearly in `d_eff`. The
hazard grows with the court's success.**

### 8.7 Self-minting is the DESIGN, and load-bearing

`tier × (80/93) × own conviction`, pool-invariant, **is** the "published rate is a promise, not a
contested pool" property — the single strongest de-gambling fact in `REGULATIONS.md` (Humphrey
factor 2; *White v. Cuomo*, prizes unchanged by entrant numbers). `court.gno`'s `slashDrawBps >=
10700` check exists to certify exactly that. **Every dilution-based fix converts it back into a
contested pool.** It is also why the straddle harms no honest staker off the clamp — the leak is
dilution of CC holders, not theft.

### 8.8 The bonus tier cannot be targeted, and that is provable

The straddle returns `tier × 1.0968` and breaks even only at `tier ≤ 0.911`, so **any tier
multiplier worth having is straddle-profitable.** A cost-side lever cannot be tier-scaled because
the tier is decided *after* the cost is incurred, and tightening the payout below 0.911×mg abolishes
the premium. Two mitigants to bank instead: the tier is **not straddler-selectable** (HIGH needs a
conclusive full-bar tally and `isParticipant` bars stakers from their own claim's quality lane), and
at HIGH the clamp threshold halves, so a HIGH-heavy court clamps sooner.

### 8.9 And the delayed release fails on thin courts in a new way

Vet 1's F9 leak reproduced independently (`locked = 0`, `stake = 0` at settlement, full 1.0968
margin, one extra transaction). But the participation harm is worse than discouragement: the
proposal creates a systematic incentive to **drain both legs immediately before the answer**, and on
a thin court the trailing `minAnswerX` floor then makes the claim **unanswerable — it dies at 12
weeks with no payout to anyone.** That is the exact drain pattern `answer.gno`'s `lifeAvgStake`
max-keying was built to defend against on the *pricing* side; this would make it the norm on the
*participation* side.

---

## 9. CONVERGED — the answer

**Do not build it.** Two independent vets, same verdict, different routes.

**Accept the spread and fix the documents**, because the cure is worse than the disease in a precise
sense: closing the straddle means making the p = ½ staker unprofitable, which moves the honest
break-even from **0.473 to exactly 0.500** — and `ECONOMICS.md` is already on record rejecting a
0.75 factor because it *"amputated the 0.59–0.67 accuracy band — real calibration signal"*. **The
cure is the disease that memo rejected 0.75 for.**

What to do instead:

1. **`WHITEPAPER.md` §2** — three false sentences (§8.2, §6.5).
2. **`ECONOMICS.md`** — record `T_L/T_c = 1.039` measured against 1.5 assumed, that the −15% margin
   is gone once 80/93 is propagated, and that `ρ = r + d` overstates the differential carry of
   staking.
3. **This file's §3.1** — corrected in §8.4.
4. **Sequence `TODOs.md` §4 against §8.5**, since dead-claim recovery removes the margin currently
   doing most of the work.
5. **If a fix is ever wanted:** the only survivor is a **time-proportional charge on `∫stake·dt` at
   ψ = 2.42 bps/wk, burned** — `stakePos.rawHi/rawLo` already holds the integral, so it is nearly
   free to build, and it is the one lever F9 cannot escape. It still moves the honest break-even to
   0.500. **Price that band before building it.**
