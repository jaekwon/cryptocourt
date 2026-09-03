# ADR: the governor's voting deadline

**Status:** IMPLEMENTED in the governor. The decision below stands as written;
the second attempt found the cause the first could not, and it was not in the
conversion at all. Consumers (`DisputeVoteCloses`, `ClaimTimeline`, the web)
still publish heights and are the remaining work.

**Scope:** `p/governor`'s `closes`, the `Electorate` interface it reads its clock
from, and the consumers that publish that deadline — `r/kourtv2`'s
`DisputeVoteCloses` and `ClaimTimeline`, `r/govern`'s re-export, and the web.

## Context

This is the last site in `docs/CLOCK_DEADLINES_PLAN.md` and the first of the two
bugs that started it:

> A dispute dated **11 Dec 2026** whose vote "closes in ~7 days" while the answer
> above it was dated **2021** — a five-year gap the countdown did not know about.

Every other deadline in the realm now gates on a stamp and keeps its height as a
reference. The governor does not. `propose()` writes `closes: now +
rules.VotingBlocks`, `wouldBe` gates on `now >= p.closes`, and the page prints
_"Voting closes in %d blocks, at height %d"_ — a promise a reader can only check
by knowing the chain's pace, which is not a promise.

`DisputeVoteCloses` publishes that height, and its comment argues for it:

> A HEIGHT, NOT A TIME, because that is what the governor gates on … Projecting
> it into a date is the consumer's job and its projection is an estimate.

That reasoning was correct while the gate was height. This ADR inverts it: once
the gate reads a date, the realm knows the date, and the consumer's estimate —
which is what was five years wrong on the claim page — stops being necessary.

## Decision

Give the governor a wall clock from the same source it already gets height from,
and store the voting window as a stamped pair.

1. **`Electorate` gains `Now() int64`.** The governor may not read the chain
   directly: the interface exists so a realm whose clock can be fast-forwarded
   moves the VOTES with it, and reading `runtime.ChainHeight()` inside would
   leave a test chain able to age everything except the one thing a dispute waits
   on. The same argument applies unchanged to wall time.
2. **`grc20votes.Clock` gains `Now()`**, and `Ledger` forwards it. The ledger
   keeps quantising epochs by HEIGHT — that quantisation is what makes the
   anti-flash-loan property structural, and this ADR does not touch it. `Now()`
   passes through solely so a deadline the governor publishes can be a date.
3. **`proposal` gains `openedTime`/`closesTime`**, written in `propose()` beside
   the heights and never derived afterwards — a stored future moment cannot be
   reconstructed later, because the `now` it came from is gone.
4. **The close gate prefers the stamp**, falling back to `now >= p.closes` for a
   proposal opened before the stamps existed.
5. **The page prints the date**, with the block beside it.
6. **Consumers follow**: `DisputeVoteCloses` publishes `(at, atHeight)` as the
   freeze reads now do, `ClaimTimeline`'s dispute row carries the pair, and the
   web stops estimating.

## Alternatives considered

- **Leave the governor on height and let the web keep estimating.** Rejected:
  the estimate is the bug. It is also the only remaining place where a published
  deadline and the gate that enforces it can disagree.
- **Read `time.Now()` inside `p/governor`.** Rejected for the reason the
  interface exists at all — it would desynchronise a fast-forwarded test chain
  from its own votes, and the governor and ledger could disagree about when it is.
- **Widen `Timings()` from four values to six.** Deferred. `Timings` is consumed
  by `r/govern` as well as kourtv2, and arity is the kind of change that should
  land with its readers rather than ahead of them. A `TimingsAt` sibling added in
  the same commit as its first reader is the cheaper path.
- **Convert only the render.** Rejected: the page would then disagree with the
  gate, which is the same class of defect as the reopen link that contradicted
  its own gate (`dispute.gno:986`, fixed earlier in this plan).

## Consequences

- `Electorate` and `grc20votes.Clock` are shared interfaces. **Seven
  implementers** must gain `Now()`: `realmClock` (kourtv2), `Ledger`
  (grc20votes), and five test fakes across `p/governor` (`council`, `weighted`,
  `stated`) and `r/govern` (`fakeVotes`, `council`).
- `secsPerBlock = 5` enters `p/governor` to convert a `VotingBlocks` rule. This
  is the same cadence assumption `blocksToSecs` already carries in kourtv2, and
  the same caveat applies: governor rules are configured in blocks, so the
  conversion assumes a pace. Moving `Rules.VotingBlocks` to seconds is a larger
  change and is not proposed here.
- Voting deadlines become proposer-nudgeable by seconds, as every other deadline
  in this plan already is. On kourt-1 — a single validator — this concedes
  nothing; the argument is in the plan's Risks section.

## What the obstacle actually was

Neither failure was in the conversion. Both were TEST HARNESSES DRIVING ONE
CLOCK.

`r/govern`'s `advanceBlocks` and `p/governor`'s both call `testing.SetHeight`,
which moves height and leaves block time alone. That is invisible while every
window gates on height, and stops being invisible the moment a deadline is a
date: a fixture advancing 200 blocks left `closesTime` unreached, so proposals
never closed and two tests reported "active, want defeated" for a reason with
nothing to do with what they tested.

Both harnesses now derive time FROM height (`setClock`), which makes the lockstep
structural — no sequence of calls can desynchronise them.

**And a second, sharper one underneath it.** The VM's default test context is
internally inconsistent: it starts at **height 123 with the time still at
genesis**. A proposal stamped from that context carries a deadline 615 seconds
behind its own height, and the first `setClock` then appears to jump past it.
`p/governor` gained a `resumeClock()` for this, and it is required of any test
that writes before it advances — the same discipline `r/govern` already had for
its checkpoints, now for the clock.

**THE LESSON GENERALISES BEYOND THIS ADR.** Every fixture in this repo that
fabricates a height is a candidate for the same defect, and it only surfaces once
something reads both clocks. The first attempt's failure was blamed on the gate;
it was the fixture, twice.

## What the first attempt cost, measured

The implementation above was written in full and reverted. Both `p/grc20votes`
and `r/kourtv2` passed. Two things did not, and the next attempt should budget
for them:

1. **`p/governor`'s `TestTheCountdownToCloseCountsDown` pins the block text.**
   It asserts the page contains `"closes in 100 blocks"`. This is an expected,
   intended update — the test says what the page said, and the page is what this
   ADR changes — but it must be rewritten, not deleted: the countdown it guards
   is real, and the replacement should assert the DATE and the block reference,
   with the pre-stamp branch still asserting the block form.
2. **`r/govern` has two failures that are NOT text.**
   `TestQuorumIsAFractionOfTheSnapshot` and
   `TestAQuestionSettledByItsDeadlineCanBeAskedAgain` both report a proposal
   still `"active"` where they expect `defeated` — i.e. under the stamp path the
   proposal does not close. Its fakes drive height with `testing.SkipHeights`,
   which advances context time by 5s per block, so the two clocks should agree;
   they demonstrably do not. **THE CAUSE IS NOT YET ISOLATED**, and finding it is
   the first job of the next attempt, before any code is rewritten. A probe
   placed in the predicate did not fire on the governor's own failing test, so
   the probe belongs in `r/govern`'s failing tests specifically.

The patch kept at `scratchpad/gov-attempt/governor-clock.patch` is what landed,
plus the two harness fixes and the tests above.

## Why this ADR exists at all

The plan named the governor "the hard one" before any of it was written, on the
grounds that `p/governor` is a `/p/` package shared with other consumers so
adding a stamp is an API change rather than a local edit. That turned out to
understate it: the API change is not to the governor's own signature but to an
INTERFACE IT CONSUMES, which means every implementer of a clock — including test
fakes in a realm that has nothing to do with kourtv2 — moves with it. That is
worth knowing before starting, and it is why this is the one site in the plan
that gets a document instead of a commit.
