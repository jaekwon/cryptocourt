# ADR: the answer bond's conviction floor drops from 1.6x to 1.07x

## Context

The answer bond is `max(4.5%·X̄, k · the side's would-be mid draw)`, with
`k = bondFloorConvBps`. It was 1.6x. Answering a well-aged claim was therefore
expensive in proportion to how much conviction had accrued behind it, which is
the case where answering matters most.

The bond is not a deposit that a wrong answerer forfeits in the ordinary case,
and this is the part that is easy to get backwards. There are two terminal paths
and on each one, one of the two quantities is zero:

  * the answer is OVERTURNED — the bond burns at that round, and nothing was
    destroyed, because the honest side takes its draw.
  * the answer STANDS — `settleAnswerBond` returns the bond WHOLE, and the
    opposing pool's entire draw is annihilated.

An attacker who stakes dust on one side, declares it, and lets the 72h settle
window pass in silence is on the second path. Being unchallenged is
indistinguishable from being right, so there is no wrongness to slash. That is
why the bond has to bound what a SUCCESSFUL lie destroys rather than merely
deter an unsuccessful one, and why `openrewards.gno` caps a claim's draw at
`answerBond0 - carrot`.

## Decision

`bondFloorConvBps` 16000 -> 10700.

10700 is the floor, not a preference. The draw cap is the bond MINUS the 7%
carrot, so a bond of exactly 1.00x would leave 0.93·mg to cover a 1.00·mg MID
payout and would cut the published rate. `court.gno` refuses anything under
`(par + carrot)·100`, and a mutant at 10699 panics at deploy.

## Consequences

The cost is leverage, and it is real. `destroyed/posted` for a sniper is
`(tier + carrot)/k`:

| tier | at k=1.6 | at k=1.07 |
|------|----------|-----------|
| MID  | 0.669    | 1.00      |
| HIGH | 1.294    | 1.93      |

In detection terms, a bad answer must be disputed and overturned about **two
times in three** for the attack to lose money at HIGH, where 1.6x asked for
about four in seven (56%).

This widens a gap that was already open rather than opening one:
`openrewards.gno` measured 1.2937 at HIGH and stated plainly that sniping an
exceptional claim pays. The change does not cross a threshold; it moves further
along a tradeoff the design had already accepted.

WHAT IS NO LONGER IN FORCE. The old constant carried a calibration note —
"k=1.6 lands the 12-wk mill q* on the ~0.22 target (three-designer
convergence)". No live check ever computed that q*; it was a design target
carried in prose, which is why nothing failed when k moved. It is recorded here
because a target that no check enforces is exactly the kind of thing that
disappears silently, and the calibration pin in `court_test.gno` now asserts
10700 as a literal so the new value is a decision rather than a drift.

A NARROWER OBSERVABLE WINDOW, found by a test rather than by reasoning. The conv
arm overtakes the 6% base once `mg/X̄ > answerBondBps/k`, so the crossover moved
from 3.75% to 5.6% — about 8.8 weeks at a cold court's 63.75 bps/week instead of
6. Since a claim dies unanswered at 12 weeks, the window in which the keying is
observable at all narrows from roughly [6,12] weeks to [8.8,12].
`TestAnswerBondFloorIsKeyedToBothSides` aged 8 weeks and started failing its own
precondition; 14 weeks then panicked on the dead-claim timeout. It ages 11 now.

## Alternatives considered

* **Below 1.0x.** Not reachable without also cutting `tierParBps` or
  `splitCarrot`, since the invariant is exactly that sum. Cutting the payout to
  make the bond cheaper defeats the purpose.
* **Pricing on a detection rate.** If disputes could be relied on at 99%,
  break-even is `R·p/(1-p)` ≈ 0.02·mg — two percent, an 80x reduction. Rejected
  for now: the attacker picks the moment and needs only the one quiet claim in a
  hundred, so an average detection rate is the wrong statistic. Revisit with real
  dispute rates measured from the chain.
* **Lowering the flat arm (4.5%·X̄) instead.** That is the arm that binds on
  young, low-conviction claims, and it is not touched by this invariant — a
  genuine second lever. Left alone here because it is coupled to a hardcoded
  `600 = bondFloorFlatBps·4/3` in settle pricing, so it is a separate change with
  its own check to satisfy.

## Verification

`make realm-test` green. Two mutants: 10699 panics on the deploy invariant, and
16000 fails the calibration pin.
