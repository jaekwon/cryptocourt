# TODOs

Open items with enough detail to act on cold. Newest first. Each item records what
was *verified in the source* separately from what was *measured in a run*, because
the two rot at different rates.

---

## 1. LIVE BUG — `provClose` is unreachable on default params, so a false answer finalizes by apathy

**Severity: high.** This is the anti-apathy backstop, and on a default court it never
fires. The consequence is not a stuck claim — it is the wrong verdict becoming final,
with the honest challenger having paid for the privilege of finding out.

### The defect

`votingBlocks` and `escrowMinBlocks` are **the same number**:

```go
// realm/r/kourtv2/court.gno:283,288
votingBlocks:    120_960,   // one week
escrowMinBlocks: 120_960,   // one week
```

`escrowWindow` (dispute.gno:630-637) returns `escrowMinBlocks + extraDays*oneDayBlocks`,
where `extraDays = mulDiv128(cs.xBarFrozen, c.crv.Price(c.minted), 500_000_000)` and
`Price(s) = s / c.d` (p/curve/curve.gno:183). **So on any court with `minted == 0`,
`extraDays` is exactly 0 and `escrowWindow == votingBlocks` exactly.** More generally it
is 0 whenever `xBarFrozen × Price(minted) < 5×10^8`, which is most young courts.

`escrowUntil` is set **once, at the first resolution, and deliberately never recomputed**
(dispute.gno:344-349 — the comment says so, citing V1 §3.6). Every later round must
*open* before that fixed deadline (dispute.gno:99-102) and each round burns a full
`votingBlocks` to vote, because `ResolveDispute` refuses while the governor's proposal is
`"active"` (dispute.gno:216-218).

So round 3 needs `escrowWindow > votingBlocks`. At the defaults they are equal, and round
3 cannot open. `failedRounds` caps at **2**, but `provClose` only fires at
`failedRounds >= maxFailedRounds` where `maxFailedRounds = 3` (court.gno:76,
dispute.gno:266-268). **The branch is dead.**

Meanwhile the *first* failed round already did the damage:

```go
// dispute.gno:260-263 — only the FIRST failed round defaults the verdict
if firstResolution {
    cs.provisional = cs.answer
}
```

The false answer becomes the standing provisional verdict, nothing later dislodges it, and
`Finalize` lands on it. **Apathy resolves the claim in the liar's favour** — which is the
exact outcome the failed-quorum branch's own comment says must not happen ("apathy must
not resolve a claim").

### Measured

From the staged-copy run (`zz_measure_test.gno`, shadow root — full kourtv2 suite green):

| `escrowMinBlocks` | rounds that fit | `provClose` |
|---|---|---|
| 120_960 (**default**) | 2 | **false** — `provisional` = the answer |
| 120_961 | 2 | false |
| 120_962 | 3 | true |

So the threshold is `votingBlocks + 2`, and the default misses it by two blocks.

Cost to the honest side, same run: the disputer burned **210.000000 CC** across two failed
rounds (half of each of two doubling bonds) on a claim with `xBarFrozen ≈ 700 CC`, and the
false answer still won.

### Two comments that assert the opposite

Both are wrong as written and should be fixed with the code, since they are what a reader
would trust instead of re-deriving this:

- `dispute.gno:~128` — *"provClose bounds failedRounds ≤ 2 here"*. The bound is real but it
  comes from the **calendar**, not from `provClose`. On default params `provClose` never
  runs. (This is the highest-value lens in this repo — a comment asserting a property
  nothing enforces — and it caught this one.)
- The `escrowMinBlocks` default is documented as "the escrow window's floor: one week"
  (court.gno:275, pinned at court_test.gno:322) with no hint that being *equal* to
  `votingBlocks` is what disarms the backstop.

### Candidate fixes (not yet chosen)

1. **Raise `escrowMinBlocks`** to `votingBlocks*maxFailedRounds + slack` so
   `maxFailedRounds` rounds always fit. Simplest, and makes the constant mean what
   `maxFailedRounds` claims. Cost: lengthens every escrow, including honest ones.
2. **Derive `maxFailedRounds` from the window** rather than fixing it at 3, so the two
   constants cannot disagree.
3. **Extend `escrowUntil` per failed round** — but the "set once, never recomputed" rule at
   dispute.gno:344-349 is deliberate anti-manipulation design and must not be dropped
   casually. A failed-quorum-only extension is narrower and may be safe.
4. **Add a deploy invariant** in `mustInvariants` pinning
   `escrowMinBlocks > votingBlocks*(maxFailedRounds-1)`. Do this **regardless** of which
   of 1-3 lands — it is the check that stops this from silently returning.

Whichever lands, the test must assert the bystander: an ordinary claim with a *decided*
first round must still finalize on its old schedule.

---

## 2. An overturn's free quality ride can zero the winners it just vindicated

**Severity: medium-high.** The one shape where a false answer really does destroy the
honest payout — and it is not the ordinary overturn.

An ordinary overturn pays honest winners **in full**: `Finalize` restores
`cs.tier = tierMidX` (dispute.gno:462-464), and measured, a 300 CC / 3-week winning
position draws **4.955068 CC** whether the answer stood or was overturned — bit-identical.
Only the answerer loses (5-point slice zeroed, bond burned, credential reset).

But `resolveQualityRide` (quality.gno:618) can set `tier = tierLowX = 0` on **the same
tally that overturned the answer**, and `crystallize.gno:83` (`want := mustMul(cs.tier,
midGross)`) then zeroes the entire draw. So the vote that proved the answer false
simultaneously declares the claim junk and pays the honest winners nothing. Measured: same
fixture, **0**.

quality.gno:24-28 and :639-641 argue at length that "was the answer right" and "is the
claim worth anything" are *different questions*. This path conflates them.

**Fix direction:** gate the *demotion* arm of `resolveQualityRide` on an overturn round, or
require its own mandate for it. A verdict round should not be able to zero the tier it just
vindicated.

---

## 3. `provClose` zeroes the draw while calling itself "not a conclusive low"

**Severity: medium.** Internal contradiction, and it strands honest stakers.

`provCloseClaim` (dispute.gno:386-413) refunds the deposit **and** the fee, with the
explicit comment *"provClose is not a conclusive low — §3.1.7"* (dispute.gno:385). Then it
sets `tier = tierLowX` and `tierFinal = true` (dispute.gno:390) — and `Crystallize` refuses
outright on top of that (`crystallize.gno:32-34`, "closed claims have no draw"). So it
treats itself as not-a-low for the deposit and as a low for the draw.

Honest winners get principal back at 1× and **no winnings**, on a claim where nobody was
found to have done anything wrong.

**Fix direction:** pay the winners at the default MID against the standing `provisional`,
consistent with how provClose already treats itself everywhere else.

*(Note: fixing item 1 makes this path reachable for the first time on a default court. Do
not fix 1 without deciding 3.)*

---

## 4. Dead-claim expiry evaporates conviction with no payout

Not a bug — designed — but recorded because it is the thing the owner cares most about and
the design work is unresolved.

A claim that dies unanswered at 12 weeks (`deadClaimSecs`, clock.gno:37) refunds principal
via `Unstake` and pays **nothing**: measured, **22.950015 CC of conviction evaporates** on
a 300 CC / 12-week position. `CloseDeadClaim` also burns the fee unconditionally
(claim.gno:368-378), which contradicts PLAN.md:989 (fee should burn only on
dead-with-no-stake) — though that predicate is farmable with a 1-unit self-stake, so the
spec may be the thing that is wrong.

**Ruled out:** re-answerability. It cannot re-freeze the conviction pin without arming
three dormant clamps (answer.gno:130-147 names them), cannot reopen staking without making
one claim a ~51× risk-free emission faucet (measured: 297.982184 CC period budget vs
5.760267 CC honest draw), cannot get the calendar it needs (the 12-week clock never
pauses, and extending it panics at deploy per court.gno:224-229), and a second answer would
inherit answer #1's `slotConsumed`/`slashLevied` latches — making it **structurally
unflaggable and unslashable**.

---

## 5. Owner / other session

- Add `chat_all.js` to `CHECKS` in `web/tests/browser/run.js` (untracked, theirs).
