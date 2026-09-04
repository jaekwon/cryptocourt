# Rented voting weight

**Status: CLOSED.** Weight is now

    w = min( PastVotes(who, <the question's own frozen epoch>), BalanceOf(who) )

in all three lanes — quality (`quality.gno`), election (`modvote.gno`) and verdict
(`dispute.gno`, via the governor's `VoteWithCap`). The snapshot is the CEILING and
stops buying in after the question; the live balance is the FLOOR and stops voting
weight already handed back.

**AND THE FLOOR ALONE WAS NOT ENOUGH — it reordered the attack rather than pricing
it, and this was MEASURED on the shipped floor rather than reasoned about.** The
floor asks what you hold at the moment of voting and says nothing about the moment
after, and a cast ballot is never undone. So the rental survived unchanged in cost:
borrow, seal, open the dispute yourself, **vote while still holding**, repay in the
very next call. Probed at **599× the quorum floor with a final balance of zero**,
against the 600× measured before any of this work. One step to the right, same
price.

What prices it is the second half: **coin you voted with cannot leave your balance
until the question resolves** (`votelock.gno`). A renter must carry the position
across the whole voting-and-resolution window — about a week instead of an hour —
so the attack costs the risk of holding that long. Until resolution and not the
ballot close; the amount voted and not the address; blocking disposal but not
staking, since staking leaves the coin in the balance and voting.

**The quality lane is locked too, and it was not an owner decision after all.** It
looked unlockable because its tally accumulates — no single "round resolved" instant
to release at — but looking for an instant was the mistake. The rule is that the
commitment lasts exactly as long as the influence. The first predicate read *open iff
the claim is not terminal AND `cs.qVoteSeq` is still the seq voted in*, on the reasoning
that a superseded tally counts toward nothing, so the lock lets go the moment the seq
moves — "the very next round, nobody is frozen for weeks over a flag".

That last part was false, and it is worth keeping the correction visible because the
principle was right and only the predicate was wrong. **The seq moves when a round
OPENS, and nothing makes a round open.** A failed-quorum dispute parks the claim with
`verdictAt == 0`, `closed == false` and nothing open, and in that state the vote can
never decide anything again — every path that counts the tally runs behind `flagOpen`,
`disputeOpen` or `counterOpen`, and each route to one calls `openQualityTally`, which
zeroes the buckets. Measured on the shipped code: an ordinary voter's ENTIRE balance
held, 20,000,000,000 of 20,000,000,000 with disposable 0, for about sixteen days — the
escrow window (probed at 155,521 blocks remaining) plus the 120,960-block
participant-only grace on `Finalize`, which they cannot shorten because they are not a
participant. (An earlier draft of this claimed the state was a dead end and the freeze
unbounded; that was three routes checked and `Finalize` never tried.)

So the predicate asks whether the vote can still DECIDE anything: *open iff not terminal
AND the seq is still the one voted in AND (a question is open now OR these weights carry
forward)*, carry-forward being `slotConsumed && qualityReasked` — exactly when
`reaskQualityTally` stops opening fresh tallies and every later round votes the same
running total. The frozen-accumulating case still holds coin until the claim ends,
because there the vote really is still deciding rounds.

`rentedweight_test.gno` has been flipped: it asserted the exploit worked precisely
so a fix would fail it loudly, and it now asserts every refusal, with each fixture
still pinning the attack's own scale so it cannot pass by the rental being too
small. `VOTEFLOOR.md` has the derivation, the audit trail and the four errors the
panels caught on the way.

**What is recorded below is the measurement and the two closures that FAILED.**
Kept because both failures are load-bearing: they are why the shipped fix needs
both halves, and why it uses `BalanceOf` rather than `spendable()`.

---

## The claim that was false

`realm/p/governor/governor.gno`, `propose()`, said:

> The electorate is the checkpointed supply at the last sealed epoch. Not a
> hand-kept roll: the token already remembers who held what, and asking it is what
> makes the weight both historical **and impossible to rent**.

It is rentable. That comment has been corrected in place; this file is the
measurement behind the correction.

## The mechanism

Every vote is weighed at a **sealed past epoch**. That stops weight acquired
*after* the question was asked. It does nothing about weight acquired shortly
*before* — and **the anchor is `Epoch()-1` at propose time, so whoever proposes
chooses it.**

```
1. buy float on the market            (possible only since coins became transferable)
2. wait ONE epoch to seal             (epochBlocks = 720 blocks ≈ 1 hour)
3. open the dispute / election yourself   ← pins the anchor inside your holding window
4. sell everything back               (the past checkpoint cannot be un-written)
5. vote with the full weight you no longer own
```

## Measured

Pinned by `realm/r/kourtv2/rentedweight_test.gno`, which asserts the exploit
**succeeds** — a characterization test, so any fix will make it fail loudly.

| | |
|---|---|
| weight acquired | 300,000,000,000 |
| live votes at the moment of voting | **0** |
| weight the vote was recorded at | **300,000,000,000** |
| quorum floor it had to clear | 500,000,000 |
| **multiple of the bar** | **600×** |
| capital at risk | **one epoch** |

Election lane, on a 500 B-supply court: a one-epoch rental stands at **12× the
election floor** (floor 25 B, rental 300 B), and an election coup is court-wide
rather than one claim.

**Three lanes, ranked by exposure:**

| lane | anchor pinned by | rentable |
|---|---|---|
| **election** (`modvote.gno`) | whoever calls `OpenElection` | **yes** — worst; court-wide |
| **verdict** (governor via `OpenDispute`) | whoever opens the dispute | **yes** — demonstrated end to end |
| **quality** (`quality.gno`) | the **answerer**, at `PostAnswer` | hardest — you must answer the claim yourself and vote from a second address |

## What is and is not new

- **"Selling out after voting costs nothing" is deliberate**, standard
  snapshot-governance behaviour, and pinned by `r/govern`'s own
  `TestAVoteCannotBePassedAlongWithTheTokens`: *"a vote already cast is not undone
  by selling, and the buyer does not inherit it."* Not in dispute.
- **What is new is that the actor chooses the anchor**, which converts an accepted
  property into a rental market.
- **`r/govern`'s token has always been transferable**, so that lane was exposed
  before kourtv2 was. Transferable court coins extended an existing exposure; they
  did not create the mechanism.

## One honest qualification

The probe's `TransferCC` is free. On a real market, acquiring a governance-sized
position and dumping it an hour later pays **slippage twice plus an hour of price
risk**, so the true cost is a market round trip, not zero. What changed is that it
is no longer an **irreversible curve purchase burning GNOT at a rising price** —
which is precisely the premise the v0.31 `electionFloor` keep-netting ruling and
`MODERATION.md`'s capital-keyed sybil doctrine rested on. Those two rulings are
what need re-arguing, and this is why.

---

## Closure A — cap at live weight. REVERTED, then SHIPPED with two changes.

`w = min(PastVotes(who, p.epoch), VotesOf(who))`.

Kills the exploit outright (measured: the rented vote was refused). Preserves the
snapshot half, since the pinned figure remains the ceiling. Required adding
`VotesOf` to the `Electorate` interface — as a **required** method, not an optional
one the governor type-asserts, because an optional one is a guard that passes
vacuously for every implementor who skipped it.

**Why it was reverted: it charges the voter for coin they moved into the realm's
own escrow.** Bonds and deposits leave the balance, so whoever **pays to initiate**
a proceeding votes at less than their weight. That is a perverse incentive aimed at
exactly the people the system needs to act.

**WHAT SHIPPED, and the two differences that made it survivable.** First, the cap
is `BalanceOf`, not `VotesOf` and emphatically not `spendable()` — staked coin
stays in the balance and keeps voting, so a staker is not docked, and `spendable()`
would have re-imposed the court-wide disenfranchisement v0.34 deleted. Second, the
haircut is ACCEPTED rather than designed around: `votableAt` already nets escrowed
coin out of the election denominator, so escrowed coin voting was the
inconsistency, and the two fixtures that sat at exactly the floor were rebalanced
instead of the mechanism bent. The coherence objection below dissolves for the same
reason — the cap only ever LOWERS a numerator that was already coherent, so
`Σ min(PastVotes, BalanceOf) ≤ Σ PastVotes ≤ PastTotal` holds with no clamp.

Third, and this is the part that made it safe rather than merely correct: the live
figure is supplied to the governor as a **ceiling** (`VoteWithCap`), never as a
weight. `VotesOf` is not back on the `Electorate` interface, so the engine still
cannot read a live balance at all.

Measured breakage:

- `TestElectionZeroApprovalCandidateCannotInstall` — `small` holds **exactly** the
  5% election floor (50,000,000 of a 1,000,000,000 supply) by design, as the
  minimum viable approver. The registration fee they paid to nominate pushed them
  **under the floor they were built to sit on**, and the honest candidate stopped
  installing.
- `TestElectionTurnoutIsDistinctVoters` — 900,000,000 of weight became 895,500,000,
  the 4,500,000 being fees paid by the voter who opened the election.
- A disputer's own vote on their own dispute is docked by their dispute bond.

**And a coherence problem:** the numerator would be live-capped while the
denominator (`votableAt`, and every snapshotted quorum floor) stays at the sealed
epoch. The tally would be measured against a denominator that counts weight nobody
can cast. Direction of error is conservative, but the asymmetry is real.

## Closure B — require the weight to be older. REVERTED.

`w = min(PastVotes(who, p.epoch), PastVotes(who, p.epoch - HoldEpochs))`,
`HoldEpochs = 168` (one week at hourly epochs).

Both readings historical, so **nothing a voter does after the anchor reduces them**
— no bond haircut, no coherence problem. Turns a one-epoch rental into a one-week
one.

**Why it was reverted: it disenfranchises every recent acquirer.** Anyone who
joined within the window has *zero* voting power, not reduced power. Measured: it
refused an ordinary honest vote in `r/govern`'s own suite. A smaller window (24
epochs ≈ 1 day) is proportionate but still locks out same-day buyers, and it is a
behavioural change to a shipped, audited realm.

It is also **a price, not a wall** — an attacker willing to hold for the window
qualifies, and two point-readings do not require *continuous* holding, so
hold → sell → re-acquire-by-the-anchor passes.

## Closure C — take the anchor away from the actor. NOT IMPLEMENTED.

Pin the **verdict** lane's electorate to the claim's `qualityEpoch` (set at
`PostAnswer`) instead of the dispute's own epoch. Then the disputer cannot move the
anchor, and the electorate for *"was this answer right"* is the holders at the time
the answer was given — which is arguably the correct electorate anyway.

- **Wall, not a price**, for that lane. No honest cost: no live reading, no
  holding period.
- Requires `propose` to accept an explicit epoch — a governor API change.
- Cost: holders who joined the court after the answer cannot vote that claim's
  verdict. Bounded, since the dispute window is 1–3 weeks after the answer.
- **Does not help elections**, which have no prior non-actor event to anchor to.
  Gating only the *opener* does not work either: any long-standing holder can open
  on request while the renter buys in an hour before.

**Not taken.** It is a wall for one lane and does nothing for elections, and the
shipped fix closes all three at once without disenfranchising anyone who joined
after the answer — which was this closure's unavoidable cost.

---

## What was kept

- The false comment in `propose()` corrected, and `Vote`'s comment now states the
  exposure and points here.
- `electorate.gno` records that `VotesOf` was added and removed, so re-adding it is
  understood as re-opening this decision rather than a small change.
- `openrewards.gno`'s carrot now pays the **recorded** ballot weight, read from
  **this realm's own** `qVoted` on both branches, instead of re-deriving it from
  `PastVotes`. A no-op today — recorded and re-derived are equal while the tally is
  an uncapped snapshot read — but it removes a live over-payment hole that Closure
  A silently opened: a voter capped low at vote time could buy back before pulling
  and be paid an uncapped numerator against a capped denominator. Worth keeping on
  its own, and a precondition for any future weighting change.

  **Caught in audit:** the first version of that rewrite read the weight from
  `gov.VoteOf`, which stops answering once anyone calls the permissionless
  `ReleaseRoll` (`p.voted = nil`). A claimant who had not pulled yet would have
  been refused a carrot they had earned. `dispute.gno` had said *"the carrot must
  not depend on it"* since the choice record was added, and the rewrite ignored it.
  Latent rather than live — kourtv2 exposes no `ReleaseRoll` entrypoint, which is
  precisely why nothing caught it — so `TestTheCarrotSurvivesRollReclamation`
  reaches past the entrypoints and calls the governor directly. Mutation-verified:
  restoring the `gov.VoteOf` read is caught by that test.
- `rentedweight_test.gno`, asserting the exploit works, so it cannot be forgotten
  and any fix has a target.
