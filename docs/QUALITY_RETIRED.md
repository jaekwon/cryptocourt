# The quality lane, retired — decision record

**Status: decided and implemented.** The tier, the flag lane, the slash and the
quality ballot are out of `r/kourtv2`. This is the record of what was decided,
what it was decided *against*, what it costs, and what is still open.

It is deliberately self-contained. The two working documents behind it —
a four-option analysis and an implementation plan — live in `scratchpad/` and
are **untracked**, so the passages that carry the reasoning are quoted here
rather than cited. If those files matter, they need committing; nothing below
depends on them surviving.

## Context

The ask was about signing, not economics:

> *"it's bad UX to require two stages of voting for every claim… how can we
> reduce this to one vote?"*

Quality was the second stage. It was never a cosmetic multiplier: `tierLowX = 0`
and `want := mustMul(cs.tier, midGross)`, so a LOW verdict did not shrink a
claim's draw, it **zeroed** it. That made quality the author-mill defence — the
thing that stopped an author filing worthless claims and collecting the
emission for answering them.

## Decision

Full removal. Quality goes: the tier, the flag lane, the slash, and the ballot.

## What it was decided against, and by whom

The analysis put four options and recommended the **cheapest**, not this one:

> **Do Option 1 now.** It is the only one that answers the actual complaint —
> two ballots — at zero economic cost, and it is reversible.
>
> **Then treat 2/3/4 as a separate economics decision.** […] It is not the same
> question as "why am I signing twice", and answering that one by deleting the
> mill defence would trade a UI annoyance for an economic hole.

Option 1 merged the two *transactions* while keeping both *weights* — which is
possible because `VoteDispute` weighs at the round's epoch and the quality
ballot weighed at an epoch pinned at the answer, and one entrypoint can carry
both.

**Full removal was chosen anyway.** That is the owner's call and it is recorded
as such: the UX complaint was answered by removing the mechanism rather than by
merging the signatures, and the economic consequence below was accepted rather
than discovered.

## The accepted cost, stated once

Quoted from the implementation plan, because these are terms of the decision
and not surprises to find in review:

> Worthless claims draw the same as good ones. Nothing penalises answering one.
> The author standing category is never credited.

## Consequences, as observed in the code afterwards

Measured while auditing the tree, not predicted:

- **A decided dispute round is now the only route to an adjudicated claim.** It
  is what sets `decidedPID`, and `decidedPID` is what crystallize and the carrot
  read. Several tests in other files used to reach that state through the flag
  lane, because a conclusive flag consumed the claim's slot and funded a carrot
  with no dispute bond posted.
- **The answer bond refunds unconditionally.** Retention used to be conditional
  on an adjudication; there is no reserve to carve now.
- **Dead state and dead code were left behind**, and are tracked separately
  rather than swept in silently: three `claimState` fields with no non-comment
  readers (`flagger`, `flagVoteEnd`, `dustBurns`), one uncalled function
  (`creditFlagSlash`) whose rate is still tangled in an exported setter, two
  exported reads nothing references (`ClaimTierBps`, `ClaimTierRef`), and an
  exported pair whose second return value is now always zero
  (`ClaimVoteWeightOf`, `VoteWeightWhy`). Each needs a decision; none is
  load-bearing.
- **The three tier constants outlived the tier.** `tierLowX, tierMidX,
  tierHighX` are still declared at `court.gno:94` with **zero production
  readers** — measured, comments and their own declaration excluded. Six
  references remain and all six are in tests. `court.gno:369` already says
  "tierMidX is gone; par is tierParBps", so the constants are vestigial while
  the tests that name them keep them compiling. Whether those tests still
  assert anything about tier semantics, or only about numbers that happen to be
  0/1/2, is the question to settle before deleting.
- **The guards noticed, which is the point of having them.** Eight selftest
  control arms went dead with the lane — five naming the deleted file outright,
  three planting into files that still exist while naming symbols that do not.
  One rule (`check-epoch-coherence`'s arm 10, "a quality question has exactly
  one definition") was retired rather than re-aimed, because the hazard it
  guarded was a *disjunction* drifting between readers and there is one liveness
  question left. `qualityQuestionOpen`, `qualityEpoch`, `pendingSlash`,
  `tierFinal`, `flagOpen` and `counterOpen` now have zero non-comment
  references.

## Findings this retired, named so they are not mistaken for gaps

Seven adversarial cases in `audit_m3_test.gno` attacked the flag/slash
mechanism. They die with it — not because they were wrong, but because what
they attacked no longer exists. The file's own header keeps the list; in
summary:

| finding | what it required |
|---|---|
| M3-HIGH-1 | a slash reserve surviving both terminal paths — no reserve now |
| M3-HIGH-2 | retention conditional on an adjudication — now unconditionally nothing |
| M3-MED-1 | a griefer re-flagging to stall `Crystallize` — no flag to re-open |
| M3-LOW-1 | a reopen landing on a pending slash and an open counter — both unreachable |

A future reader can tell a RETIRED finding from one that was never found by
this table.

## Still open

**Migration.** Quoted, because it remains the first question on a live chain
and this record does not answer it:

> A realm change is a redeploy. A claim mid-flag has a bond escrowed and
> possibly a slash reserved; a claim mid-dispute has a quality ride
> accumulating. Nothing here says what happens to those, and on a live chain
> that is the first question, not the last.

The project's answer to a realm change has so far been a `--reset` reseed,
which sidesteps the question rather than answering it. That is tolerable while
the chain carries only seeded fixtures and stops being tolerable the moment it
carries someone's bond.

## Docs that still describe the lane as live

`PLAN.md`, `MODERATION.md` and `VOTEFLOOR.md` still document the
flag/slash/quality-ballot mechanism in the present tense. They are the
remaining half of this cleanup and are not corrected by this file.
`WHITEPAPER.md` is generated and must not be hand-edited.
