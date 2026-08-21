# Vote-lock: solve rented weight, let new coin vote at once, cost the voter no yield

**IMPLEMENTED at v0.57. Draft 1 → two review rounds → converged design → built.
The implementation surfaced one consequence bigger than anything in the plan; it is
the first section below.**

Three constraints, all three binding:

1. **Voting must not be economically disadvantageous.**
2. **Rented weight must not decide votes.**
3. **Newly acquired coin must vote immediately** — no seasoning, no waiting.

---

## THE CONSEQUENCE THE PLAN MISSED: an open vote can now be BOUGHT into

Found while implementing, not while planning, and it is the price of constraint
(3) rather than a defect in the build. Two existing tests were pinning the
property being removed, and one of them says it outright:

> *"Weight is pinned at the epoch the election opened. The latecomer is minted more
> CC than the honest voter holds and still cannot vote, because it held none at the
> pin."* — `TestVotingWindowAndWeightGates`, before this change

Under live weight that latecomer votes, and decides. **And no choice of denominator
prevents it**, which is the part worth internalising:

| | |
|---|---|
| dust's weight, snapshot | 10,000,000 |
| dust's weight, live (after minting 50 M mid-election) | 60,000,000 |
| floor, 5% of *sealed* votable | 50,500,000 |
| floor, 5% of *live* votable | 53,000,000 |

Sub-quorum becomes quorum either way. **You gain 100% of what you acquire while a
5%-of-votable bar gains 5% of it**, so a fractional bar cannot resist buy-in. The
old snapshot did not price the attack — it *forbade* it, and (3) is the instruction
to stop forbidding it.

What is bought is not cheap and not rented: curve minting burns GNOT
irreversibly, market buying pays the spread, and the vote-lock holds the position
through the round. So the honest framing is **"votes are purchasable at market,
and the buyer keeps the position"** — not "votes are cheap".

Also inverted for the same reason: `TestElectionBelowQuorumRetains` and
`TestElectionDecoyLosesToEarliestNomination` both minted coin *after* the epoch
seal specifically so it would not count. Their fixtures were rebalanced into the
sealed epoch so they still test quorum and margin rather than the weighting.

**This is the one thing to reverse if the trade is unwanted, and reversing it means
giving up (3).**

---

## Why the obvious answers fail

| candidate | fails on |
|---|---|
| Seasoning ("weight must be N epochs old") | **(3)** outright — that *is* the waiting period |
| Cap at live weight, `min(snapshot, VotesOf)` | **(1)** — docks whoever paid a bond to initiate; measured, it pushed a holder of exactly the election floor under it |
| Freeze the coin and pay voters the court rate | **(1)** — but see below: the payment is the problem, not the freeze |
| Weigh ballots again at resolution | O(voters) at resolve → a gas bomb anyone can load by spamming ballots |

The freeze-and-pay idea is worth killing explicitly because it looks right. Paying
voters a duration-scaled reward means new emission: `carrotTotal = midGross × 7/100`
is keyed to **conviction**, so on a young claim it is structurally tiny —
measured, 7% of 3.8M against a lock cost of 1.25M, a **4.6× loss** exactly where
turnout matters most. Scaling it to cover the lock means emission proportional to
`turnout × time`, which is unbounded against a supply-derived ceiling
(`curPeriodBudget`, `rMax`). **So the reward cannot be made to cover a
yield-bearing freeze. The freeze has to cost no yield instead.**

---

## The design

**Two changes, and the second is what makes the first affordable.**

### 1. Vote weight becomes LIVE, not a snapshot

`w = the voter's balance at the moment they vote.` No `PastVotes`, no anchor, no
epoch. Satisfies **(3)** exactly: coin acquired one block ago votes at full size.

This is only safe because of change 2. On its own, live weight is what snapshot
voting exists to prevent — an atomic borrow → vote → repay decides the vote for
the price of a flash-loan fee.

### 2. Voting locks the coin AGAINST TRANSFER ONLY, until the round closes

Not against staking. Not against bonding. Not against filing a claim. **Only
against leaving your hands.**

That single distinction is the whole design:

- **(2) solved.** After voting you cannot sell, so you cannot rent. To vote you
  must hold through the round — which is a position, not a rental. It also closes
  the flash loan, because the repayment leg is a transfer.
- **(1) solved, and for free.** You forgo *no yield*: your coin can still be
  staked to earn conviction, still back a bond, still pay a deposit. The only
  thing you give up is the option to **sell** for the rest of the round. A holder
  who was not going to sell this week pays nothing at all. The carrot stays a pure
  bonus on top and needs no resizing.
- **(3) solved**, by change 1.

### Mechanically

- One new tree: `c.voteLockUntil`, `addr → height`.
- On voting: `voteLockUntil[who] = max(existing, roundEnd)`.
- `TransferCC` / `TransferFromCC` refuse while `now < voteLockUntil[from]`.
- **No release transaction and no sweep.** The gate is a height comparison, so the
  lock lifts by itself. Nothing can be stranded by a voter who forgets to claim,
  which is the failure mode the deleted unbonding queue had.
- **No bond credit, no per-address escrow accounting.** Because nothing is docked
  from anyone's weight, the ~35 sites of escrow plumbing that killed the earlier
  attempt are not needed.
- **Cap the lock at `votingBlocks`.** No single vote may freeze coin longer than
  one round, whatever window the lane nominally has.

### The governor seam

`governor.Vote` derives weight itself (`g.voters.PastVotes(who, p.epoch)`), and
`r/govern` shares the package. So the governor gains a way to be **told** a weight
instead of deriving one; `Vote` keeps deriving by default, so `r/govern` is
untouched and its snapshot semantics are unchanged. kourtv2 passes live weight and
does its own locking. Elections and the quality lane are kourtv2's own tallies and
do not touch the governor at all.

---

## Review — holes hunted, one at a time

**Sybil split.** Spread coin over N addresses and vote from each? Total weight is
still total coin, and every one of those addresses gets locked. No gain. The design
does not rest on an address-keyed defence, which `MODERATION.md` is right that it
could not.

**Vote then acquire and vote again.** Refused already: one vote per address per
tally (`p.voted.Has`, `qVoted.Has`).

**Move the coin out before voting.** Then live weight is zero at the vote. Nothing
to game.

**Bond your way out.** Post a bond so the coin leaves to escrow, then sell? Bonds
return to the **poster**, and only after the round resolves — by which time the
vote is decided. No exit.

**A round that never ends.** Quality voting has no fixed close of its own (the
ride's deadline is the governor's, and `disputeOpen` stays true). Hence the
`votingBlocks` cap: an unbounded lock would be the worst outcome for an honest
voter and the cap is what makes the commitment statable in advance.

**Turnout can now exceed the snapshot denominator.** Weight is live; the quorum
bar is a fraction of `PastTotal` at the round's epoch. Coin minted through the
curve mid-round adds turnout that the denominator never counted, so quorum gets
marginally *easier*. Direction is aligned rather than dangerous — S1's whole
finding was that quorum was unreachably hard and that was the bug — and the
threshold test is a ratio, so it is unaffected. **Accepted and stated.**

**Does this fix the "simultaneous across every open claim" cost?** No, and nobody
should think it does. One coin still votes on every open claim, because the lock
rations *disposal*, not voting. What it does change is that the capital must now be
held through the longest round it voted in, so the simultaneous malicious overturn
S1 priced at −4.80 to +19.20 CC now also carries a week of price risk on the whole
position. Cheaper than fixing it, better than nothing, not a fix.

**`check-read-purity`.** The lock is written in `VoteDispute` / `VoteQuality` /
`VoteElection` — write paths. No read allocates.

**Is "you cannot sell for a week" really no cost?** It is not *zero* — it is
liquidity and price risk, which is real for someone who wanted to exit. But it is
**not a yield cost**, which is what constraint (1) is about, and it is the same
commitment the court already asks of every staker. Anyone who wants to keep the
option to sell can abstain, and abstaining is already a first-class choice that
counts toward turnout.

**What breaks in the existing suite?** Every test that votes and then transfers,
and every test asserting a specific weight derived from a snapshot. Each needs
reading for whether it pinned a *property* or a *fixture convenience* — the same
question that caught me out on `r/govern` earlier today, where four "failures" were
message text and nothing more.

---

## Review round 2 — two findings, one load-bearing

**DELEGATION WOULD BREAK LIVE WEIGHT, AND IT IS UNREACHABLE ONLY BY ACCIDENT OF
WHAT KOURTV2 EXPOSES.** `grc20votes` supports delegation: `VotesOf(who)` is
`a.votes`, which includes power delegated *in*. If a delegator can hand power to a
delegate, the delegate votes with it, the delegate's own coin gets locked — and the
**delegator's coin does not.** They delegate, the vote lands, they sell. Rented
weight through a side door, and worse than the original because the renter needs no
epoch of holding at all.

It is unreachable today: **kourtv2 exposes no `Delegate` entrypoint** — grepped,
zero hits outside tests — so court-coin power is always self-delegated and
`VotesOf == BalanceOf`. That is what makes live weight safe here.

Consequences for the plan, and both are required:

- **Take the weight from `BalanceOf`, not `VotesOf`.** They are equal today, so it
  costs nothing, and it means the design does not silently depend on delegation
  staying unexposed.
- **Add a guard** in the style of `check-nontransferable.py` that fails if a
  `Delegate`-shaped entrypoint ever appears on a court coin, naming this document.
  A precondition nothing enforces is the exact defect class that started this
  thread.

`r/govern` **does** expose `Delegate`, which is a second reason its lane stays on
the snapshot path rather than being "upgraded" for consistency.

**THE QUALITY LANE TRADES A WALL FOR A PRICE, and the owner should see that
plainly rather than find it later.** Today the quality tally is weighed at
`qualityEpoch`, pinned at `PostAnswer` — an anchor *nobody voting can move*. So a
would-be demoter who did not already hold before the answer landed cannot vote at
all: a wall. Under live weight they can buy in and vote, and the only cost is
holding through the lock.

Sizing it honestly: a demotion needs 1.25% of court supply (the S4 floor), so the
new price is "1.25% of a court, held for a round." That is far more than the zero
it costs a pre-answer holder today, and far less than the impossibility a
post-answer buyer faces today. **It is strictly worse than the status quo for this
one lane, and strictly better for the two lanes that are actually being exploited.**
Constraint (3) is what forces it: an answer-pinned anchor and "new coin votes
immediately" cannot both hold.

If that trade is unwanted, the alternative is to exempt the quality lane and leave
it on `qualityEpoch` — which keeps the wall and gives up (3) for quality votes only.
**Flagged as an owner decision; the plan below takes the uniform path, because one
rule that holds everywhere is worth more than a special case, and because the lane
being exempted is not the lane under attack.**

## Lock length, settled per lane

Capped at `votingBlocks` (one round, ~1 week) everywhere, so the commitment is
statable before the vote and no vote can freeze coin for longer than one round.

- **verdict**: the governor's own close. Naturally one round.
- **election**: `e.voteEnd`. Naturally bounded.
- **quality**: has no close of its own — the ride's deadline is the governor's and
  `disputeOpen` stays true until resolved — so the cap *is* the rule here. That
  means a quality voter can outlast their own lock on a long-running tally and sell
  while their vote still stands. Recorded rather than hidden: it is the residual
  rental in this design, priced at one round.

## Converged design

1. `c.voteLockUntil` tree, `addr → height`. `TransferCC` and `TransferFromCC`
   refuse while locked; nothing else does.
2. Vote weight is the voter's live **`BalanceOf`** (not `VotesOf`), in all three
   lanes, plus a guard refusing any `Delegate` entrypoint on a court coin.
3. Voting sets `voteLockUntil[who] = max(existing, min(roundEnd, now+votingBlocks))`.
4. `governor.Vote` gains a caller-supplied-weight path; the deriving path stays for
   `r/govern`.
5. The carrot is untouched.
6. Readers: `VoteLockedUntil(courtSlug, who)` so a UI can state the commitment
   **before** the vote is cast, not after.

**Built, in that order.** Whitepaper note first (`WHITEPAPER-ITERATION.md`, since
`WHITEPAPER.md` is loop-managed), then the implementation, then the battery.

### What shipped

- `c.voteLockUntil`, and `mustNotVoteLocked` on `TransferCC` / `TransferFromCC`
  only — keyed on the OWNER in the allowance door, so an approval cannot launder
  the sale.
- `lockVote` is monotone and capped at one round. Both properties are
  mutation-verified: dropping the monotone check releases an earlier round's coin
  when a shorter one is voted in, and dropping the cap lets a lock run past a round.
- Live `BalanceOf` weight in all three lanes, plus the voter's own ballot-line
  bonds in the election lane — because a live reading alone docks whoever paid to
  participate, measured as a holder of exactly the 5% floor being pushed to 4.57%
  by the fee they paid to nominate.
- `governor.VoteWithWeight`, so `r/govern` keeps the snapshot untouched. Its whole
  suite passes unchanged, which is the evidence nothing moved there.
- `scripts/check-nodelegate.py`, wired into `realm-test`, verified to fire on a
  planted `DelegateVotes`.
- `VoteLockedUntil(courtSlug, who)` so a UI can state the commitment before the
  vote rather than after.

### Battery

Eleven mutants, all killed, `0 build errors` each: seven new guards, and four
pre-existing corpus rows re-anchored onto the changed lines. **One survived first
and was a real coverage gap I had created** — inverting the latecomer assertion
removed the only test that a zero-coin address is refused, so the election weight
guard could be deleted unnoticed. A ghost arm was added back to
`TestVotingWindowAndWeightGates` and the mutant now dies there. "Anyone who buys
can vote" is not "anyone can vote", and the suite has to say so separately.
