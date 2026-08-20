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
