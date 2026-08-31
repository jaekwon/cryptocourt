# What a claim is worth — size, and the spam flag

**Status: implemented and green.** Replaces the quality lane (`quality.gno`'s
three-bucket vote, its flag slot, its bond, its slash and its counter-flag
window) with two multipliers on the claim draw. This is the decision record: what
changed, what was rejected, and — the part that matters later — what was accepted
as a cost with eyes open.

## The complaint this started from

Two ballots on one claim. A disputed claim asked the electorate *"should this
answer be overturned?"* and, separately, *"was this claim low, mid or high
information?"* — two signatures, two mental models, on one page.

It also had a dead button. Abstain locked the same coin and added the same
turnout as a side vote, while the carrot pays only voters who matched the
verdict — every cost, no upside. It was strictly dominated, so no
payoff-maximiser ever pressed it, and a choice nobody rationally takes is not a
signal.

## What replaced it

**One ballot: overturn / uphold / spam.** Abstain's slot became the spam flag.

**Two multipliers on the draw, composed:**

    want = midGross × tierBpsFor(cs) × spamNetBps(cs)

`tierBpsFor` is the claim's SIZE against the court's typical claim, continuous,
clamped 0.25×–2×. `spamNetBps` is `1 − 2s` where `s` is the deciding round's spam
share, floored at zero.

**Past half the weight cast, the claim is discarded** (`spamW*2 > cast`).
Stakes return 1× on both sides. The answerer's and disputer's bonds return —
neither of them wrote the claim, and the disputer opened the round that found it.
The filing fee always burns. At two thirds or more, the deposit burns too.

**The carrot pays the spam side when spam wins**, which is what stops the new
button being dominated the way the old one was.

## Why size, and why it stays for the undisputed case

A winner's slice is

    gross = drawWinners × myConv / winPoolConv = tier × myConv × 0.86

because `midGross` IS `winPoolConv` — **the pool cancels**. Without a multiplier
the same 10 CC earns the same on a 100 CC claim and a 1000 CC claim, and `tier`
is the only free term in that expression. Size is what reaches a staker's rate.

It stays for undisputed claims because the spam flag cannot reach them: no
dispute, no voters, no signal. Without size, the mill's route — open a claim,
self-answer it, self-stake the answered side, settle undisputed, collect — pays
in full. A self-staked claim is small against its court's typical claim, so size
rates it 0.25×.

The reference is the court's own running average of answered claims' sizes,
frozen at the answer. A claim of typical size earns par in any court, with no
constant chosen by hand.

## Rejected, and why

**Spam REPLACING the size rating** rather than discounting it. Size reaches 2×
and spam caps at 1×, so replacement would let a small self-staked claim rated
0.25× jump to 1.00× by being disputed with no spam — a 4× promotion bought for
the price of a dispute bond by a second address, since `OpenDispute` bars only
the answerer. Composed, a dispute can lower a claim and never promote one.

**A banded size rating** (low/mid/high by size) instead of a continuous one. A
step function has a bar, and crossing a bar re-prices the crosser's whole
pre-existing position in one jump — the last unit of stake before the line buys
a windfall on every unit already there.

**A fixed supply-fraction reference.** It would call every claim in a
small-claims court low and every claim in a large one high, and the fraction
itself would be a guess. The measured evidence agreed: at a 20 bps reference the
suite's ordinary fixtures landed on the 2× ceiling, and a reference that calls
the typical claim exceptional is the wrong reference.

**A weekly shared pot**, allocated across claims superlinearly by size. This is
the only shape that makes a size-sensitive rate genuinely unbuyable — inflating
your own claim dilutes you from a fixed pot rather than minting new coin. It was
rejected as too large: claims currently crystallize independently against a
first-come budget, and this needs them settled as a batch per period. If the
marginal buyability below ever proves worse than modelled, this is where to go.

**Paying every voter regardless of what they voted.** It would buy turnout, not
judgement, and the cheapest way to earn it becomes voting at random on
everything.

## Accepted costs

These are decisions, not oversights. Anyone reading this later should know they
were named before shipping.

**The size multiplier is buyable at the margin.** A holder who stakes their own
claim raises its multiplier, including on their own position, and may answer it
themselves. The bound is the token's distribution: the multiplier cannot be
lifted without locking a real fraction of supply on the claim, on a side, for its
life. This bound was ruled sufficient. It is the same bound the vote had, where a
holder could carry a tally with weight they merely HELD — here they must lock it.

**Attention becomes value by construction.** There is no longer any way to say "a
lot of money looked at this and it was still worthless" absent a dispute. That
judgement was the quality vote's entire job.

**Nothing stops a spam brigade** on a claim that is merely unpopular. The quorum
bar and the participant exclusion — the author, answerer and stakers cannot vote
— are the only defences, and this design adds none. A claim can be deleted by a
bare majority of a quorate turnout, and the author loses their fee for it.

**The deposit burn is the harshest money outcome in this system reachable by
somebody who posted no bond.** That is why it needs a supermajority rather than
the bare majority that merely deletes the claim; the two thresholds are
deliberately asymmetric.

**The drain path needed a separate fix, and got one.** Size cut against it — a
drained claim rates small — but did not close it, and the deterrent that did was
the quality lane's slash, which this change removes. `Unstake` now forfeits
conviction **in proportion to the coin withdrawn**: you must still be holding
when the claim is judged to be paid for it, and holding longer still pays more.
That reverses F9's capital conservation. Principal is untouched, so no-loss is
unaffected — it was always a promise about principal.

Two things about the shape are deliberate:

- **Proportional, not a flag.** "Did this position ever exit" is defeated by
  staking 1,000, withdrawing 999 and leaving 1: the flag never fires and the
  position keeps every unit the 1,000 earned. `TestPartialExitForfeitsInProportion`
  IS that attack, and it is the only test that fails an all-or-nothing forfeit.
- **Conviction only — the raw integral is spared.** Conviction is what the coin
  EARNED and it follows the coin; the raw integral is what the claim WAS, and it
  prices every bar in the system (the answer bond, the dispute bond, the quorum
  floor, the tier reference). If withdrawing shrank it, draining would make a
  claim *cheaper* to answer and to dispute — the same attack pointed the other
  way. Scaling it broke `TestDrainedClaimPricesBarsOffLifetimeStake` on the first
  attempt, which is what that test is for.

## Findings worth keeping

Three things cost real time and are not obvious from the code.

**The governor's abstain slot already had the semantics spam needs.**
`turnout(p) = yes + no + abstain` counts it toward quorum; `forAndAgainst(p) =
yes + no` excludes it from the verdict bar. Both are exactly what a spam flag
wants, which is why this was a relabel and not a new vote bucket.

**`OpenDispute` moves the escrow by ZERO while recording a bond.** The disputer's
coin passes straight through to the governor as the proposal's own bond and only
returns when the proposal settles — measured, escrow 31,100,000 before and after
against a 12,000,000 bond. Any disposition that refunds it must therefore run
from `ResolveDispute`, after settle. A test that discarded earlier failed with a
panic that looked like a bug in the discard.

**A voter needs checkpointed weight at the proposal's epoch.** An epoch has to be
SEALED — `SkipHeights(epochBlocks)` then `touch` — between minting voters and
opening a dispute. Without it the failure is `govern: already voted`, which names
the wrong thing entirely and cost three rounds of fruitless address-fiddling.

## Where the code is

| | |
|---|---|
| the two multipliers | `realm/r/kourtv2/tier.gno` — `tierBpsFor`, `spamNetBps` |
| the ballot's vocabulary | `realm/r/kourtv2/dispute.gno` — `VoteDispute`, one translation point |
| the thresholds | `dispute.gno` — `spamDiscards`, `spamBurnsDeposit` |
| the discard | `dispute.gno` — `spamDiscardClaim`, a sibling of `provCloseClaim` |
| the composition | `crystallize.gno`, guarded by `check-epoch-coherence` |
| parameter relationships | `court.gno` `mustInvariants` — the floor/answerability alignment |
