# Vote-lock: BUILT, REVIEWED BY THREE INDEPENDENT PANELS, REVERTED

**REVERTED at v0.58. Do not re-implement from this document without reading
"Why it came out" below — the design satisfies all three constraints and is still
unsafe, and the reason is structural rather than a bug list.**

## Why it came out

**CRITICAL, and it alone was sufficient: `governor.VoteWithWeight` voids the
governor's `rest` contract, giving a permissionless verdict flip.**

`wouldBe` computes `rest := p.total - cast` and says so beside it:

> *"Negative if an electorate's parts exceed its whole, **which this token cannot
> do** and a replacement might; a clamp here changed no outcome... **The contract is
> on the electorate instead**, where somebody swapping one will read it."*

A consumer-supplied weight is not drawn from `p.total`, so `cast` can exceed it and
`rest` goes negative. The early-succeed arm then reduces algebraically to
`yes*bps >= (total - abstain)*ThresholdBps` — **`no` drops out of the test entirely**.
Abstain with more than the sealed supply and the round closes early on a single
`yes`; later `no` voters are refused "that proposal is closed"; `ResolveDispute`
reads the truncated tally and overturns. ~50% of sealed supply, acquirable
mid-window from a zero balance, released one round later. Confirmed end to end.

**HIGH: live weight is incoherent with every frozen bar in the system, not just the
one this document considered.** §"Turnout can now exceed the snapshot denominator"
said *"the threshold test is a ratio, so it is unaffected"* — true for the
threshold, false for every ABSOLUTE numerator measured against a frozen bar:

| bar | anchor | confirmed consequence |
|---|---|---|
| `credWeightFloor` | frozen `engaged` at the proposal epoch | `yes` reached **200% of its own denominator**; bar cleared **160×**; the career credential is purchasable inside the window |
| `qualityBars` | frozen at `PostAnswer` | supply grew 21×, bars did not move; one post-answer buyer cleared `fullBar` **400×**, latched `slotConsumed` and levied a real slash off the answerer's bond |
| quality **promotion** | same | buying `fullBar` (5% of supply) **doubles the claim's draw** — this document priced only demotion |
| `electionFloor` | frozen at `OpenElection` | gains **0%** of a buy-in, not the 5% claimed above |
| election `turnout` vs `line.weight` | two live readings at different times | a line can carry **10× the election's whole turnout** |

Both `votable/3` reachability clamps are void for their stated purpose too:
turnout is no longer bounded by votable at any epoch.

**HIGH, and self-inflicted: the election bond credit added here was a free coup.**
`electionBond` clamps to `electionFloor` whenever votable < 20 CC, so an attacker
holding exactly the floor posts it all as the bond (balance → 0) and votes the whole
floor on credited weight alone. Installs, bond refunds, **net cost zero**, and
`AppointMods` refuses forever after. At ordinary scale it is a standing 10%
discount on every coup. The credit was double duty: the same coin as anti-spam bond
and as deciding vote.

**MEDIUM, three more:** the lock ended at the *ballot close*, so a voter sold before
`ResolveDispute` applied the verdict they caused; the quality tally accumulates
across rounds, so a **fully divested** address decided a later round it never voted
in, zeroing the draw via `tierLowX`; and the lock had **no amount**, freezing a
voter's entire future inventory for a round on one dust abstain — while `render.gno`
told them it locks "the coin you vote with".

## What the constraints actually demand

The three constraints are individually reasonable and jointly force live weight,
and live weight is incoherent with a system whose every bar is deliberately frozen
so it cannot move under an open vote. **That is the finding.** Anyone reviving this
needs to answer it first, not patch the six sites:

- **`min(snapshot, live)`** restores coherence and kills the rental, but violates
  constraint (3): newly acquired coin has a snapshot of zero.
- **Making every bar live** restores coherence and gives up "the bar cannot move
  under an open vote", which `ProposeWithQuorum` exists to guarantee.
- **Clamping turnout at the frozen denominator** keeps (3) and bounds the
  incoherence, but makes the tally non-additive — whose ballot gets clipped?

## What was kept from the reverted work

- `check-nontransferable.py` rebuilt on the axis that matters. The inversion earlier
  the same day had added a required reputation-noun suffix, and `SellCC` /
  `RedeemForGNOT` both silently began to PASS — so the one property this design
  treats as existential ("the payment is burned, nothing ever redeems") had no
  tripwire at all. Verb lists were the wrong instrument: they trip on
  `WithdrawStake` and V1's three `Redeem*`, all of which return a holder's own CC
  and touch no GNOT. The guard now pins `SendCoins` to `buy.gno` at an exact count
  — two in kourtv2 (the burn, and the buyer's dust change), one in kourtv1.
- Two selftest controls that had been **silently dead**: the coin-`Transfer` control
  (planting what the guard now permits) and the Makefile coupling anchor (moved when
  `ccwrap` joined `realm-test`). `make selftest` is not in the default gate, which
  is how both survived.

---

Three constraints, all three binding:

1. **Voting must not be economically disadvantageous.**
2. **Rented weight must not decide votes.**
3. **Newly acquired coin must vote immediately** — no seasoning, no waiting.

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

**Order:** whitepaper first (the owner asked), then implementation, then the guard
mutation battery, then the audit.
