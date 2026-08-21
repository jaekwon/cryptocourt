# Exact-anchor voting weight

**FALSIFIED BY AUDIT. NOT IMPLEMENTED, AND NOT TO BE.** Two independent audits
killed it on the same premise, which I then verified by reading `p/checkpoint`:

> *"a height-keyed row is immutable the moment it is written"* — **FALSE.**

`ValueAt` opens with `if at >= s.e0 { return s.cur }`, and `SetAt` collapses
same-unit writes with `if e == s.e0 { s.cur = v; return }`. So a row keyed at the
CURRENT unit is still mutable, and reading it returns the live value bit for bit.
**Anchoring at height H is the live read that got `ece5aec` reverted, reached
through a different door.** Only H−1 is frozen.

Three further findings, each measured:

1. **With the H−1 fix the rental is not closed, it gets ~720× CHEAPER.** A
   past-height anchor is a historical fact you cannot undo, so the renter simply
   returns the coin *before* voting: borrow at H−1, open at H, repay, vote. The
   lock gates only future transfers, so it answers a question the renter never
   asks. Measured: vote weight 300 B, balance 0, 600× the quorum floor.
2. **The type change was never needed.** `p/checkpoint` does not know what its
   keys mean, so "height-keying" is obtainable by constructing the ledger with
   `epochBlocks = 1` — zero code edits, 10/10 suites green. And the cost is
   identical: measured 1,448× storage on identical dense traffic, +2,450 GNOT/yr
   for an ORDINARY hourly-active holder, 200× the marginal storage on the most
   common operation in the system.
3. **It re-opens a documented attack.** `court.gno:710` reads the last *sealed*
   epoch precisely because *"live supply is atomically griefable … a whale sitting
   on unclaimed franchise could front-run an honest answer in the same block."* A
   one-block anchor restores that front-run, and no test guards it.

**And the framing that matters most: granularity was never the disease.** The
200%/160×/400× coherence failures came from *live reads* and from *two frozen
quantities frozen at different instants* — not from an hour of staleness.
`p.epoch`, `e.epoch` and `cs.qualityEpoch` are each already set once per question
and read by both sides. An exact anchor adds no coherence; it shortens a rental
window from an hour to a block, for a large and permanent storage bill.

**The surviving design is in the last section of this file.**

## The one-sentence version

Weight is what you held **at the height the question was opened**, read exactly
rather than rounded down to the last sealed epoch — and casting a vote locks that
much coin against transfer until the round resolves.

## Why this, after two failures

| attempt | what it did | why it died |
|---|---|---|
| **today** | weight = `PastVotes(who, Epoch()-1)`, the last **sealed** epoch at propose time | the anchor is up to `epochBlocks` (720 blocks, 1 h) stale, so a fresh buyer has no weight. Also rentable: buy, wait an epoch, open the question yourself, sell, vote. |
| **live weight + transfer lock** (reverted, `ece5aec`) | weight = `BalanceOf(who)` at vote time | a live numerator against frozen bars gave turnout at 200–400% of its own bar in five lanes; and `VoteWithWeight` let `cast` exceed `p.total`, voiding `rest := p.total - cast` and dropping `no` out of the early-decide test — a permissionless verdict flip |
| **bonded electorate** (designed, not built) | weight = coin in a separate bonded state, tranched by height | works, but the bars must re-denominate in bonded stock, discounting every capital-keyed defence by 1/φ — 4.75× at φ=20%, 19× at φ=5% — and Kourt cannot buy a high φ (≈39% of the weekly emission budget at φ=60%) |

**The insight the third attempt produced, kept; the subsystem it wrapped it in,
dropped.** The reverted design's fatal flaw was the **live read**, not the lock.
Anchoring at the question's open height keeps every property the live read was
for, and loses none of the coherence the frozen bars need.

## Why an exact anchor is coherent by construction

The denominator is `PastTotal(H)` for the question's open height `H`. Each
numerator addend is `PastVotes(who, H)` for the same `H`. The ledger's own
contract (`electorate.gno`) is that the parts sum to at most the whole **at a
given instant**. One instant, therefore:

```
Σ over voters of PastVotes(voter, H)  ≤  PastTotal(H)  =  p.total
```

exactly, with no clamp. So `rest := p.total - cast` stays non-negative, `wouldBe`
is untouched, both early-decide arms stay sound, and **the engine still derives the
weight itself** — no consumer-supplied weight, so the critical failure is
structurally unreachable rather than merely avoided.

## Why newly acquired coin votes immediately — better than today

Today a buyer waits for the current epoch to seal: up to 720 blocks, one hour,
before they have any weight at all. Under an exact anchor:

- buy in block N,
- a dispute opens in block N (or N+1, or later) — the anchor is that height,
- vote with **full weight, in the same block**.

**Zero wait.** The only thing given up is voting on a question that was *already
open* when you bought — which is the property the snapshot legitimately buys, and
the one that stops a buyer from watching a fight start and paying to join it.

## What the lock is still for

An exact anchor alone does not stop renting: buy at h₁, open the question yourself
at h₂, vote at h₃, sell at h₄ — you held for three blocks. So the transfer lock
stays, and it does one job: **you cannot dispose of the weight you voted with until
the round resolves.** A renter must therefore hold a real position across a real
round.

Three corrections to the reverted lock, each from a panel finding:

1. **Lock until RESOLUTION, not the ballot close.** The reverted version ended at
   `p.closes`, so a voter sold before `ResolveDispute` applied the verdict they had
   caused.
2. **Lock the AMOUNT voted, not the address.** The reverted version was a bare
   height comparison on the address, so one dust abstain froze a voter's entire
   future inventory for a round — and `render.gno` told them it locked "the coin you
   vote with". With an exact anchor the weight is known at vote time, so the exact
   figure can be locked.
3. **No bond credit.** The reverted version credited a voter's own ballot-line
   bond as weight, which at `votable < 20 CC` made `electionBond == electionFloor`
   and handed out a **zero-cost moderator coup**. It does not come back. The
   nominator's bond is escrowed coin, and escrowed coin does not vote — which is
   what `votableAt` already says.

## What this fixes for free

- **Election `turnout` vs `line.weight`.** The panels measured a line carrying 10×
  the election's whole turnout, because each approval re-read a live balance. With
  one anchor per election a voter has **one** weight for the whole ballot, so
  `max(line.weight) ≤ turnout` is arithmetic again.
- **`credWeightFloor`.** Numerator and denominator both at `H`, so the career
  credential stops being purchasable mid-window.
- **No 1/φ discount.** Bars stay denominated in supply. Nothing has to bond, so
  nothing has to be paid to bond.

## The infrastructure this needs

`PastVotes(who, at)` currently takes a **`uint32` epoch**. It must take a height.

- `p/checkpoint`: `Series.SetAt` / `ValueAt` key on height instead of epoch.
  `PageEpochs = 32` becomes a height-scaled `PageHeights` or pages hold 720× less.
- `p/grc20votes`: write `l.Height()` where it writes `l.Epoch()`;
  `mustBeSealed(at)` becomes "refuse a FUTURE height" rather than "refuse the
  current epoch" — because a height-keyed row is immutable the moment it is
  written, so there is no unsealed window to protect.
- **Storage cost, and this is the real price:** one archived row per balance
  *change* instead of one per *epoch in which a change occurred*. `SetAt` today
  collapses same-epoch writes (`if e == s.e0 { s.cur = v; return }`) and that
  collapsing is what disappears. For a holder who moves coin once a week:
  identical. For a DEX pool or a market maker: many more rows, paid for by their
  own gas.

## Open questions the audit must answer

1. **Is the height-keyed checkpoint sound and affordable?** `uint32` holds
   4.29e9 — 680 years at 5s blocks — but the type change runs through `be32`/`rd32`
   and the page keys. What is the real row-count and gas delta on a busy address?
2. **What else depends on epoch granularity?** Conviction (`effectiveRateAcc`),
   emission, `credWeightFloor`'s `gov.Snapshot`, `cs.qualityEpoch`, `e.epoch`,
   `votableAt`. Does any of them *want* coarse epochs, or is epoch-vs-height
   incidental everywhere but the vote?
3. **Does coherence hold at all 28 bar sites**, per the inventory in the earlier
   panel report? Especially the quality lane, whose tally accumulates across rounds
   — a divested voter decided a later round it never voted in.
4. **Does the lock's third edge survive?** The quality lane has no single close;
   with a per-round anchor and an accumulating tally, what exactly is a voter
   committing to?
5. **Is the excluded-party lever closed?** With frozen supply-denominated bars, the
   answerer (who may not vote) cannot move the bar. Confirm an exact anchor keeps
   that, since it was the decisive argument against live bars.
6. **What breaks?** 141 call sites of the three vote entrypoints, plus every
   fixture that relies on `SkipHeights(epochBlocks*2)` to seal an epoch before
   voting.

---

# THE SURVIVING DESIGN — and it is one I already rejected

All four agents converged on the same shape, from four directions:

```
w = min( PastVotes(who, <the question's own frozen epoch>), spendable(c, who) )
```

plus the amount-keyed transfer lock until resolution, and **no checkpoint change
at all**.

- **Coherent, exactly.** `w ≤ PastVotes(who, E)` for the question's own epoch `E`,
  so `Σ w ≤ PastTotal(E) = p.total`. `rest` cannot go negative, `wouldBe` is
  untouched, the engine still derives the weight. Every absolute bar
  (`credWeightFloor`, both quality bars) is bounded by the same instant as its
  numerator.
- **Rental dead.** The renter must return the coin to repay, and `spendable` is
  then 0, so `w` is 0. The snapshot half stops them buying in after the question;
  the live floor stops them voting weight they have given back. Neither half works
  alone — that is why two attempts failed.
- **The lock keeps one job:** vote-then-sell, which the floor alone does not catch
  because a cast ballot is never undone.
- **Constraint (3) is satisfied to within one epoch, and the epoch is a DIAL.**
  `epochBlocks` is a ledger construction argument. 720 → one hour; 12 → one
  minute for ~12× the archive cost on dense writers only, measured, with zero test
  failures. So "how immediate is immediate" becomes a priced parameter rather than
  a redesign.

## This is Closure A, which I rejected — and my reason was inconsistent

`RENTEDWEIGHT.md` rejected `min(snapshot, live)` because it *"charges the voter for
coin they moved into the realm's own escrow as a bond or deposit."* But this file's
own §"No bond credit" then argued the opposite and correctly: *"escrowed coin does
not vote — which is what `votableAt` already says."* Both cannot stand. The second
is right: `votableAt` nets the escrow out of every denominator, so escrowed coin
voting was the inconsistency, and a nominator holding exactly the floor who pays a
fee genuinely holds 4.57% of votable and is correctly refused.

So the haircut is accepted, and the two election fixtures that sat at exactly the
floor get rebalanced rather than the mechanism bent around them.

## Still open — an owner decision, not a design gap

**RESOLVED — see `votelock.gno`. Kept below as the question, since its framing was
what made the answer findable.** The release point is not an instant but a
condition: *the claim is not terminal AND the tally seq voted in is still live.*
Superseded tallies count toward nothing and so hold nothing; a frozen seq keeps
deciding rounds and so keeps holding coin until the claim ends.

**The quality lane's tally accumulates across rounds.** `reaskQualityTally` re-asks
exactly once; every later round votes the same accumulating tally. Measured, a
fully divested address keeps deciding rounds it never held through, and there is no
single "resolution" for the lock to reach. Either accumulation goes (per-round
tally, per-round bar) or `applyQualityTally` changes shape so each addend is
compared against a bar at its own anchor — which is not expressible as one scalar
`turnout`. Both are product decisions.
