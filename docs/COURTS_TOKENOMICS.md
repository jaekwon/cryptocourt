# Courts — tokenomics (V4 spec)

What a court is made of economically: who pays, who is paid, what stops each
attack, and what every number is. This document is the specification. The
reasoning that produced it — including four mechanisms that were designed,
attacked and thrown away — is in `courts/COURTS_DESIGN_LOG.md`; where the two
disagree, this one wins.

Companion: `COURTS_STRUCTURE.md` (claims, folders, the chain render, the
interface contract).

---

## 1. The system in one page

A **court** is an instance on a shared realm. It has its own coin, its own
treasury of GNOT, and its own docket of factual claims.

- **Coin in, one way.** You send GNOT to the court's bonding curve and receive
  its coin (CC). There is no sale back to the court, ever. The GNOT becomes a
  treasury the holders vote to spend on prizes and bounties.
- **Claims never expire.** A claim is a proposition that trades continuously as
  conditional shares collateralised in CC. It may trade for years and never
  resolve; the price is the product, and settlement is the exception.
- **Most claims settle without a vote.** Somebody posts an answer with a bond; if
  nobody disputes before the next settlement session, that answer is the verdict —
  and the money still waits in escrow.
- **Contested claims go to the holders.** A vote, weighted at a sealed epoch from
  before the dispute was filed, against a bar that can never fall below what is
  riding on the claim.
- **The record is fast; the money is slow.** A verdict is written at the session
  that resolves it. Collateral unlocks after an escrow period, during which anybody may
  reopen it.

**The hard constraint, and the reason several mechanisms here look unusual:**
GNOT never pays voters. Every incentive is denominated in the court's own coin or
in a public record.

## 2. The coin

### 2.1 Issuance

**The curve is the only issuance. There is no minting after it, ever.** Total
supply and treasury therefore stay in a fixed relationship, and every mechanism
below is redistribution rather than inflation.

- **Linear price**, `p = k · supply`. Chosen on a capture-versus-distribution
  trade: a flat price gives a raider no margin, a quadratic one resists raids
  best and entrenches early buyers worst.
- **The court's own treasury may not buy.** Otherwise GNOT cycles out and back
  while new coin is issued against no new backing.
- The one-hop version of that cycle — pay a bounty, the recipient buys — cannot
  be prevented and is bounded by §7's ceiling on treasury outflow, not by a
  prohibition.

### 2.2 What makes it worth GNOT

1. It is the only chip you can wager in that court.
2. It is a claim on that court's fees — the adjudication fee if you vote, the
   settlement fee if you answer or sit on the roll.
3. It is the vote, and the vote controls a treasury that pays GNOT prizes.
4. It carries a public record as a juror.

**In V1, only the first of those is live.** The treasury is unspendable and the
roll's fee share is deferred (§11.1), so a V1 coin has no cash flow at all: it is
the right to play and to judge in that court, bought one-way at twice its
backing. That should be said on the buy page in those words rather than implied
away — a coin with no yield and no exit is a defensible thing to sell only if
nobody was told otherwise.

### 2.3 What the curve does and does not protect

**Buying control costs x² × the eventual treasury for the first fraction x of
supply.** So a latecomer doubling the supply to hold half pays about three times
the treasury, and an early buyer taking half pays about a quarter of it.

The curve defends against a **raid**, not against a **founder**. That is how
every early-stake system works, and it is why holder concentration and backing
per coin are published (§8) rather than assumed away.

**Backing per coin is exactly half the marginal price** under a linear curve, so
every buyer pays twice the backing of the coin they buy. That is what a rising
price means and it must be stated at the point of purchase.

## 3. Claims and settlement

**Terminology (canonical, for the /p/ and /r/ code too).** An **answer** is a posted resolution of a claim. An **answer dispute** (`answerDispute`) contests an answer and sends it to a vote — never called a "challenge". A **support** and a **counter** (counter-claim) are the two kinds of argument edge between claims (`COURTS_STRUCTURE.md`), and a counter is inert: it never mechanically moves its parent's price, bar, or verdict.

### 3.1 Positions and the market

One CC of collateral mints one YES share and one NO share, and a matched pair can
be handed back for the collateral at any time. With no deadline, **tradability is
the only exit** — which makes the market the load-bearing part of this section
rather than a convenience.

**Opening a claim does not require making a market.** A claim is a record first,
tradeable the moment anybody wants to trade it. The layout agrees: allocating a
claim's book lazily, on its first order, halves what opening one costs
(`COURTS_STRUCTURE.md` ("Storage layout and what it costs")).

**Opening costs a governance-set minimum deposit, and it is never zero.** Beyond
the storage rent the chain charges, a court sets a **minimum claim deposit** by
vote. It is refundable, so it costs an honest opener nothing but the time-value of
the lock — but a floor of zero would let anybody flood the docket for gas alone,
so the parameter exists to make spam cost something and cannot be set to zero.

**When it comes back depends on what the claim became.** A claim that gets
answered and resolves is now part of the permanent record; its verdict is never
deleted, and the deposit is returned to the opener **at resolution**. A claim that
is never answered and sits idle with no open interest is spam by another name:
anybody may **sweep** it, which deletes it and returns the deposit to the opener.
So sweeping is only ever for the unanswered and abandoned — a settled claim is
kept, not swept, because the record is the product.

That ordering matters, because the alternative was tried and the arithmetic
kills it.

> **An automated maker was specified here for one pass and withdrawn.** Seed a
> constant-product pool with N complete sets and its terminal value if the claim
> resolves is `N·√((1−p)/p)` — **one third of the seed at p = 0.9, one tenth at
> p = 0.99** — transferred to whoever moved the price. Break-even needs a **20–35%
> fee**, or forty round-trips of uninformed volume per unit of liquidity at 1%.
> And the no-deadline property makes it *worse*, not better: there is no horizon
> over which fees amortise, and a claim parked at 0.95 forever is a pool of
> permanently locked worthless-side inventory.
>
> The sentence that settles it: **an LP position in a claim is a bet against the
> truth being discovered.** In a product whose purpose is discovering it, nobody
> should be asked to take that side to open a question.

**A tick-quantised book instead.** A hundred price ticks on a 0.01 grid, one
aggregated quantity per (claim, side, tick), and occupancy in a pair of 64-bit
bitmaps per side. A taker walks the levels it crosses by scanning the bitmap —
one to three levels at realistic depth. Integer-only, no rounding hazard, no
liquidity provider, no subsidy, and **O(levels crossed) rather than O(orders)**.

That last point retires the objection that sent this design to an AMM in the
first place: the gas cost of a book is an artifact of a comparison-sorted price
tree, not of books.

**Liquidity is optional, separate and labelled.** Anybody — including a court's
treasury, once it may spend — may post resting quotes, and a resting order costs
nothing while it waits and can be cancelled the moment its author learns
something. On an indefinite market that is exactly the right primitive, and an
AMM position is its opposite: it cannot cancel.

**If an opener should have skin in the game, they buy a side.** A directional
stake is positive-EV when they are right, which is the incentive the product
wants. Making a market is the incentive it does not.

### 3.2 The optimistic path

1. **One address posts an answer** with a bond of **min(50% of the money on the
   claim, a governance-set cap)** (§3.2a explains both parts). Returned if the
   answer stands.

   **The answer bond is not co-funded, and that is deliberate.** The cap already
   makes it affordable to a single party — a court sets the cap to what a serious
   answerer can post — so pooling buys nothing, and it opens an attack: a liar
   co-funds a sliver, recruits dupes for the rest on fabricated evidence, and
   their *personal* break-even detection rises toward certainty while the dupes
   carry the deterrent. One answerer, whole bond, whole personal stake in being
   right. (An answer *dispute* may be co-funded — see §3.3 — because there the
   backers are the losing-side holders defending real, shared positions, so there
   is no dupe to recruit.)

   **A claim is only answerable once it holds a governance-set minimum of open
   interest.** This is a separate parameter from the answer bond, on purpose: the
   threshold decides *whether a claim is worth resolving at all*, and the bond
   decides *how much the answerer stakes*. Keeping them apart means an empty or
   barely-traded claim simply cannot be answered — so nobody writes a free verdict
   into the permanent record on a claim nobody bet on — while the bond stays a
   clean 50% of whatever is actually at stake, never needing a floor bolted onto
   it.

   *No gates at all: not "you must hold no position", not "you must be on the
   roll".* The first constrained nobody, since a confederate address holds the
   position, while excluding the people most likely to know the answer. The
   second deadlocks: the roll is whoever voted recently, votes only happen on
   disputes, and the design's whole aim is that disputes are rare — so the roll
   drains to empty and nothing can be answered at all.

   **The bond is what makes answering safe. Nothing else has to.**

2. **The answer is resolved at the next settlement session** (§3.2b), not in a
   window the answerer picks.
3. **If nobody disputes before that session, the answer is the verdict** — and
   the money still waits in escrow (§3.6).

Silence settles. What makes that safe is not a watcher but the escrow in §3.6:
the record is written quickly and the **money does not move until later**, during
which anybody may dispute and reopen it.

> **A named-attestor role lived here for two passes and is deleted.** Three
> holders of the losing side were to be asked by name, with silence sending the
> claim to a vote. It breaks on a primitive this very design provides:
> **shares are mintable in pairs**. Mint N pairs and you hold N of the losing
> side — top of the list, seat acquired — while holding N of the winning side
> too, so your net exposure is *zero* and the capital is refundable. The rule
> selected on **gross** holdings and reasoned about them as **net**.
>
> It failed three further ways. The attestors were by construction the people who
> lose if the answer stands, and the dispute bond was flat, so disputing was a
> cheap option they would exercise every time — the acknowledgement branch would
> never fire on any claim carrying real money. An acknowledgement was not the
> costly signal it looked like, because positions can be sold during the window
> and the acknowledgement itself signals imminent settlement. And a one-of-three
> threshold in a small court is a publicly identifiable committee chosen by
> wealth, bribeable once rather than per claim — the trusted committee this
> design claims not to have, minus the accountability.

### 3.2a What the bond has to be, and why the old number was fantasy

The arithmetic that governs every optimistic system:

> A successful lie pays up to **X**, the whole of the losing side's claim on the
> collateral. A bond of **k·X** makes lying break even at a detection probability
> of **1/(1+k)** — the smaller the bond, the closer to certain detection must be.

| bond | lying breaks even at a detection rate of |
|---|---|
| 6% of the claim — what this document said for several passes | **94%** |
| 25% | 80% |
| 100% | 50% |

A pull-based notification page watched by volunteers does not deliver 94%, and
the ratio is scale-invariant, so there is no claim size at which honesty becomes
forced. **No bond makes lying unprofitable at zero detection**, so the bond is
not a number to pick in isolation — it is a function of the detection rate the
rest of the design can deliver, and both have to rise.

- **The bond is 50% of the money on the claim, up to a governance-set cap.**
  Capital, returned if the answer stands, not a fee. At 50% a lie is unprofitable
  once lies are caught **two times in three** (67%); at 33% it would take three in
  four (75%), and at 25%, four in five (80%). 50% is the least capital that still
  deters at a detection rate scheduled sessions plus a holder-indexed notification
  can plausibly reach. A 100% bond needs only even-odds detection but is a
  permanent lock of capital equal to the claim, so nobody would answer.

- **Why cap it, and what the cap really means.** A wildly popular claim has an X
  so large that 50% of it is more capital than anyone can post — so without a cap
  it becomes *unanswerable and never resolves*, which is worse than any lie. The
  cap says: above this size, stop relying on the bond to deter a lie and rely on
  the crowd instead. That is coherent, not a cop-out, because a wildly popular
  claim is exactly the one with the most watchers and the most heavily-incentivised
  losing side — the claims where detection is closest to certain. Be honest about
  the bet, though: once the cap binds, the break-even detection rate is X/(X+cap),
  which rises toward 1 as X grows, so the cap should be set at the size where you
  are genuinely confident the crowd catches a lie the bond no longer can. It is the
  "how big before we trust attention instead of capital" knob, and nothing more.
- **Every parameter keyed to X is snapshotted at that same moment**, or an
  attacker answers a small claim cheaply and then mints pairs to inflate X past
  any reachable quorum.

### 3.2b Settlement sessions, because attention needs a time

The deeper problem was never the bond: **the answerer chose the moment.** A claim
with no deadline has no scheduled instant when anybody is watching, and an
attacker picks three in the morning on a holiday.

So an answer cannot settle the instant it is posted. **In V1 an undisputed answer
becomes settleable on a rolling clock — a fixed `settleDelay` of 72 hours after it
was posted — and anybody may then settle it permissionlessly (`SettleUndisputed`).**
There is no fixed cadence and no paid-for short window: the answerer no longer picks
the moment, which is the advantage being removed. **Fixed weekly sessions at a
pre-announced time are a deferred (V2) refinement** that would change only *when* a
due answer settles, not the accounting. *Throughout this document "settlement
session" names that deferred cadence; for V1, read it as the rolling 72h clock.*

A disputed claim goes to a **7-day vote**, not to the 72h clock — the vote resolves
the answers somebody disputed; the clock resolves the ones nobody did.

### 3.3 Disputes

**Anybody may dispute at a bond of `max(governance-set minimum, 20% of X)`**,
whoever they are. The claim goes to a vote of the coin holders.

The shape mirrors the answer bond, floored instead of capped:

- **The 20%-of-X slope deters griefing.** A dispute drags the whole electorate
  into a 7-day vote, and that cost scales with the court — so a purely flat bond,
  if set too low, is a faucet for forcing pointless votes. Scaling the bond with
  the claim makes griefing a large claim cost something proportional to the
  disruption it causes.
- **The floor keeps tiny claims from being free to dispute**, where 20% of a
  small X would be trivial.
- **20% against the answer's 50% keeps honest policing attractive**: a disputer
  risks 20% of X to win the answerer's whole bond (up to the answer cap) *and* to
  defend their own losing-side position, worth up to X. On big capped claims the
  dispute bond can exceed the frozen answer bond — and that is fine, because the
  people who dispute a big lie are the losing-side holders defending X, not
  bounty-hunters chasing the bond.

*The tier that charged position-holders more than others is still deleted.* This
bond is the same for everyone at a given claim; it scales with the claim, not with
who you are — a whale cannot dodge it by splitting a position across addresses,
because it keys off X, which is public.

**A dispute may be co-funded**, unlike an answer (§3.2). The backers are the
losing-side holders defending real, shared positions, so there is no dupe to
recruit — pooling a large claim's 20%-of-X dispute is exactly the natural
syndicate the co-funding attack on the *answer* side lacked.

**Buying the losing side cheaply and then disputing is policing, and it is meant
to pay.** It is the one self-funding way a false answer gets caught.

### 3.4 The vote

**The ballot is the claim itself — yes or no — never "uphold the answer".** An
overturn is simply the opposite answer winning, which keeps the question a voter
sees identical to the question the claim asks, and keeps the correctness slice
about the truth rather than about deference to whoever answered first.

> **V1 note.** The shipped governor vote and the wireframe frame the ballot as
> "OVERTURN the answer?" (yes = overturn, no = uphold). Reconciling that with the
> claim-itself principle above is deferred — a product/epistemic call, not a doc fix.

**The running tally is not shown until voting closes.** With weight sealed
beforehand and a correctness slice on offer, a live tally makes copying the first
large voter the EV-maximising move for everybody smaller, which turns one whale's
vote into a self-fulfilling one.

- Weight is read at a **sealed epoch from before the dispute was filed**, so
  weight cannot be bought once a fight is visible.
- **A delegate may carry at most four times their own holding.** Otherwise a
  delegate votes weight they do not own and forfeits nothing when the coin
  craters, which is the deterrent this design rests on.

  *Deferred, and not only for scope:* the underlying ledger checkpoints an
  account's **votes** but not its **balance**, so a delegate's own holding at a
  sealed epoch cannot be read without adding a second checkpoint series per
  account. Until then a court simply does not expose a delegate entrypoint —
  which is the V1 position anyway.
- The threshold is **5001 bps** of yes+no for verdicts — not 5000, because the
  governor's comparison is `yes·bps >= (yes+no)·threshold`, which passes a tie. Constitutional and
  treasury decisions use supermajorities (§7).

### 3.5 The bar

    required = max( 5% of supply , min( 1 × the trailing-average money on the claim , ⅓ of votable weight ) )

The static form above is the shipped `quorumFloor`. The **warmth** bump and the
**fall(t)** decay described below are **deferred past V1** — V1 neither raises the
bar by past turnout nor decays it over the vote.

- **The floor** is the security parameter and the answer at launch, when nothing
  has ever been voted on.
- **The stake term** is the interesting one: *the coin that votes must
  collectively be worth at least what is riding on the claim.* A coalition can
  never profit, because the turnout it must overcome holds more than the prize.
- *(Deferred past V1.)* **warmth** — an average of turnout on past escalations only, `warmth +=
  (turnout − warmth)/4`, halving every six months so a dormant court can wake —
  raises the bar above the floor where a court has been turning out. It may only
  ever raise it.
- *(Deferred past V1.)* **fall** decays the bar over the voting period to 60% of its opening value,
  **but only the floor and warmth terms fall — never the stake term.** The bar
  may never go below 1× the money on the claim.

  That last clause is load-bearing. **Voting weight is coin, and it is held, not
  spent** — a coalition keeps its coin whatever it votes. So if the bar could fall
  to 0.6× the stake, a holder of 10% of supply could decide claims worth 16.7% of
  supply and take them, profitable even if the coin went to zero afterwards. Held
  at 1×, the gain can never exceed the holding.

### 3.5a X is manipulable, so the stake term needs a ceiling — the biggest break in V4

The stake term keys off X = open interest, and **X is not exogenous: anyone mints
pairs to raise it and redeems to lower it.** Minting also *spends coin out of
balances*, so pumping X simultaneously raises the quorum and shrinks the votable
weight that could meet it. They cross: at half the supply minted into one claim,
a 1×X quorum already exceeds all votable weight, so **no vote can ever reach
quorum and a false answer settles undisputed** — for the price of a capped answer
bond, redeemed the moment the snapshot is taken.

Two rules are needed, and both are now part of the design:

- **The X that quorum keys off is a trailing time-average of open interest, not
  its instant value.** A one-block mint-then-redeem barely moves a seven-day
  average — verified, it shifts a 7-day TWA of a 200k pump by under 2 CC — so to
  raise the quorum an attacker must *hold* the inflated position for the whole
  window, locking real capital. This kills the cheap flash version outright, and
  it costs honest holders nothing: they redeem whenever they like, because it is
  the *average* that is read, not the moment. The open-interest average is one
  more ring beside the price ring, so it is nearly free on chain. The same
  trailing average is what the "minimum open interest to answer" threshold reads,
  so that cannot be flash-crossed either. *(V1 uses a 3-hour `answerWindow` for both
  the quorum stake term and the answer threshold; the seven-day figure is the target,
  not the shipped value — see §9a. The full week is used only for the pre-answer
  price, `priceWindow`.)*
- **Quorum is capped at a fraction of *votable* weight, never gross X.**
  `required = min( 1 × X̄ , θ · votable supply )` with θ well under 1 (say 1/3),
  X̄ the trailing average. Below the cap the mechanical "coin that votes is worth
  more than the prize" argument holds; above it, a claim is too big to decide by
  turnout and security shifts to where the answer-bond cap already sends it — the
  coin's own value and the published record. This is the quorum twin of
  `min(50% of X, cap)` on the bond, and handles the *honestly* large claim, where
  real X exceeds votable weight through no manipulation at all.

A determined whale can still lock real capital for a full window to move the
average, so the honest statement is: **the stake term is a mechanical guarantee
only up to θ of votable weight; past that a court leans on coin value and
reputation, exactly as it does for the answer bond.** But the *cheap* attack —
flash-inflate, answer, redeem — is gone, and no honest holder's exit is frozen to
get there.

**The three size-gates form one ladder, and it has no dead zone** — verified:

| a claim's X̄ (trailing-avg open interest) | state |
|---|---|
| below the min-OI threshold | **not answerable** — too little at stake to be worth a verdict |
| threshold … ⅓ of votable weight | **healthy** — answerable, and a dispute's quorum (`1× X̄`) both reachable *and* larger than the prize, so capture is mechanically unprofitable |
| above ⅓ of votable weight | **answerable, still disputable** — quorum is capped at ⅓ votable, so it is *more* reachable, not less; what lapses is only the mechanical capture guarantee, which hands off to coin value and the record |

The one thing to check for was a gap where a claim is *answerable but a false
answer cannot be disputed to resolution* — that never occurs, because quorum is
always ≤ votable weight (it is capped below it), so every answerable claim can be
taken to a vote. The cap trades the capture guarantee for reachability on the
biggest claims; it never strands one.

  Note the asymmetry between *voting* and *positioning*: voting consumes no coin,
  but minting a pair to take a position **spends** a coin of collateral out of your
  balance. So a position-holder does not get to vote that collateral — it is not
  in anyone's balance while it backs a claim. What actually stops a position-holder
  voting their own stake, though, is not the spend (weight is read at a sealed
  epoch, and a position taken after that epoch leaves the sealed balance untouched)
  but the sealed epoch itself plus the 1× stake term.
- The bar must be **non-increasing within a vote**: the governor records success
  permanently the instant the condition holds.

**There is no per-claim size cap.** A claim that grows past roughly a third of
the coin that actually turns out simply cannot muster the turnout to settle, and
resets.
The cap was deleted because the quorum rule already is it, expressed as a
requirement rather than a prohibition — so a young court may *host* a large claim
and merely cannot *decide* it yet. A **court-wide ceiling on total open interest —
20% of supply** (four times the 5% quorum floor) — remains, because twenty
settleable claims would otherwise let one coalition win twenty times for the price
of qualifying once.

### 3.6 The record is fast, the money is slow

The verdict is recorded at the settlement session. **Collateral unlocks after an
escrow period** — `clamp(1 week + 1 day per 500 GNOT-equivalent of X, 1 week, 3
weeks)` — during which anybody may dispute at the ordinary bond and reopen the verdict. A reopen goes straight to a vote; it does not reset the escrow clock,
and it is not charged a fresh adjudication fee (§4).

This is the answer to a missed lie. What makes one fatal is that the money is
gone — irreversibility, not invisibility — and on a claim with no deadline nobody
needs their money in a hurry.

### 3.6a Three details the payout rules need

- **Every vote has a disputer**, now that silence settles rather than escalating,
  so "the loser's bond" always has a referent.
- **Abstentions count toward the required turnout and stay out of the result.**
  They earn the participation slice like any other vote; they cannot earn the
  winning-side slice, which is what stops abstention being the cheapest way to
  farm it.
- **The settlement fee splits half to the prevailing answer's author and half to
  the roll**, claimed pull-style rather than pushed. **In V1 only the answerer's
  half is charged** — the roll's half is deferred while CC is unspendable.

### 3.7 When a vote fails

**No decision.** The answer is withdrawn, the claim returns to trading, and it
can be answered again later.

- **No adjudication fee is charged**, because nothing was adjudicated. The claim's
  collateral is not touched, so it still fully backs its shares.
- **The answerer's bond is returned.** Their bond scales with the claim, and
  forfeiting it on a quiet week would make the expected cost of answering honestly
  so high that nobody would answer anything.
- **The disputer forfeits their whole bond.** They summoned the court and did not
  bring enough turnout; apathy must not be free for the disputer. The forfeited
  bond is split **half to the answerer** (compensation for a frivolous dispute)
  and **half burnt** — it is deliberately *not* paid to whoever turned up, because paying
  failed-round voters is a self-pay faucet (dispute your own claim, vote alone,
  collect your own forfeited bond). Sacrificing that small turnout reward is the
  price of closing the faucet.
- **The disputer's bond doubles per failed round**: the base is `max(gov-min,
  20% of X)`, then ×2 on the second failed round and ×2 again on the third. Keyed
  to the claim's failed-round count, so it is sybil-proof — a fresh address does
  not reset it — and a griefer forcing three rounds pays base + 2·base + 4·base =
  seven times the base.

Two things are load-bearing here. Apathy must not resolve a claim, because an
unresolved claim harms nobody while a wrong verdict pays out irreversibly. And
apathy must not be free for the disputer, or answerers get burned by anybody
objecting into a sleepy court.

*An earlier draft also claimed "turnout is paid even when it is insufficient, so
griefing funds the turnout problem." That is false and is deleted: a failed round
charges no adjudication fee and the forfeited bond is burnt-and-compensated, not
paid to whoever turned up — precisely to close the self-pay faucet. Failed-round
turnout is unpaid, and the honest reason it still happens is that reaching quorum
is what pays, so the marginal voter who tips a round over the bar is the one
rewarded.*

After **three failed dispute rounds** a claim is **closed without a decision**
and
every share redeems at the **time-weighted price from before the first answer** —
pre-dispute, long-window, chosen by nobody. The count is on *dispute rounds*, not
on time: a claim nobody disputes is hosted indefinitely and never force-closed;
the counter only runs once a dispute cycle begins.

Deliberately *not* an equal split, which would pay a side trading at 0.05 a full
half and make forcing a deadlock a put option worth ten times its cost. The one
exception is a claim that never traded at all: with no price to read, it closes
with every share redeeming equally, which is right precisely because nobody ever
expressed a view.

## 4. Who gets paid, and in what

Nothing here is GNOT.

Two separate flows, and keeping them separate is what makes the incentives work.

**The bonds are a bet between two people.** The loser's bond goes to the winner,
whole. Nothing else touches it. That is what makes disputing a lie worth filing,
and it scales with the claim because the answerer's bond does.

**The jurors are paid by the claim, not by the parties.** A disputed claim pays an
**adjudication fee — min(3% of collateral, 200 GNOT-equivalent)** — charged
**once, when the claim is resolved**. Of that fee, **60% goes to everyone who
voted, by weight**, and **40% to the weight that voted with the verdict**.

**Two rules make the fee safe, and both close attacks:**

- **The flat cap** stops the fee being a standing skim on other people's money.
  Without it: answer your own claim, dispute from a second address, vote alone
  (quorum is satisfied because you hold more than the claim is worth), and take
  the whole percentage while your two bonds cancel — a 3% yield on holding coin,
  paid by third parties. A flat cap makes that yield shrink to nothing as the
  court grows, because the coin you must hold to sole-vote grows with the court
  while the prize does not. A supply-relative cap was rejected for the opposite
  reason: it would hold the skim yield constant forever.
- **Once per resolution.** A claim is charged the fee a single time. A reopen
  during escrow (§3.6) charges no new fee and does not reset the escrow clock —
  otherwise reopening your own verdict every week would be a skim faucet.

On a claim large enough for the cap to bind, the fee no longer scales with the
turnout the claim demands — but those are exactly the claims where the people who
hold positions have enough at stake to vote without being paid to.

| source | goes to | for |
|---|---|---|
| the loser's bond, whole | the party who was right | making disputes worth filing |
| the adjudication fee — 60% | everyone who voted, by weight | showing up |
| the adjudication fee — 40% | the weight that voted with the verdict | being right |
| a failed dispute's forfeited bond | split: compensate the answerer, and burn the rest | apathy is not free for the disputer, without a self-pay faucet |
| the settlement fee — **~1% of resolved collateral** (V1: the answerer's half only; the roll's half deferred) | the answerer, and the roll | producing a verdict nobody had to vote on |
| the public record | answerers and voters | reputation, never a payment weight |

**A claim pays one fee, never both.** An **undisputed** claim pays only the
**settlement fee** (~1%), to the answerer who produced a verdict cheaply. A
**disputed** claim that reaches a decision pays only the **adjudication fee** (3%),
to the voters who had to sit — the prevailing party's reward there is the loser's
whole bond, not a cut of the collateral. A claim **closed without a decision**
pays nothing. So the worst a winner is skimmed is 3%, on the contested path, not
3% + 1%.

> **Why the jurors are paid by the claim rather than out of a bond**, which is the
> correction that mattered most in this revision:
>
> - **It cannot favour a direction.** The fee is a percentage of the money on the
>   claim, and that number is the same whoever wins. An earlier version paid
>   jurors a share of whichever bond was forfeited — and once the answerer's bond
>   scaled with the claim while the disputer's stayed flat, that paid **a hundred
>   times more to overturn than to uphold** on a large claim. The electorate
>   acquired a standing interest in overturning every answer, whatever the truth.
> - **It is large enough to be worth voting for.** Keyed to a bond, the pool
>   was a few coins spread across a turnout requirement equal to the whole claim —
>   so every voter without a position in the claim was paid less than their gas,
>   and the only positive-EV voters were the ones with money riding on the answer.
>   Keyed to the claim, the pool grows with exactly the thing that makes turnout
>   matter.
> - **It is always funded on a decided vote**, because it comes from the claim, not
>   from whichever bond is forfeit. (A vote that *fails* quorum pays no fee at all
>   and does not pay the people who turned up — see §3.7; failed-round turnout is
>   unpaid, which is the price of closing the self-pay faucet.)
>
> A disputed claim therefore pays out slightly less than an undisputed one. That
> is the honest price of having asked a court to sit, it is borne by the money
> that asked, and it should be shown on the claim.
**The participation slice is the big one on purpose** — 60% of the fee for
turning up against 40% for being right. A juror who expects to *lose* the vote is
paid for voting anyway, and during a manipulation the side expecting to lose is
the honest side.

The settlement fee is the *undisputed* path's reward, so the "answerer" who
collects it is by definition the one nobody overturned. On the disputed path there
is no settlement fee to reassign — the voters are paid the adjudication fee and the
prevailing party takes the loser's bond. **No fee on a claim closed without a
decision**, so income is tied to a claim actually resolving.

**Both fees fall on the winning side**, because the losing side receives nothing
either way. They are priced in at entry — a quoted price is probability × (1 −
fees) — so a buyer pays less for the same odds, but it is honest to say plainly
that the money comes out of the payout rather than pretending it is shared.

Neither fee is farmable: you must post the collateral they are skimmed from, and
a self-dealer receives only their pro-rata share back.

## 5. The roll, and warmth

Two different things, deliberately separated after an earlier design conflated
them:

- **warmth** — one scalar per court, the moving average of escalation turnout,
  used only as the quorum denominator's adaptive term. No per-account state.
- **the roll** — the set of addresses that voted within the window. Membership is
  one write per voter per window, and eligibility is an O(1) lookup because fees
  are claimed rather than pushed. Its only job is **who shares the settlement
  fee**; it gates nothing, which is what stops it deadlocking when disputes are
  rare.

Maintaining the *sum* of engaged weight as it silently expires was unaffordable;
recording *membership* is not. That distinction is the whole reason both can
exist.

## 6. What each attack costs

| attack | what stops it |
|---|---|
| buy a verdict outright | turnout required is 1× the money on the claim, up to a fraction of votable weight (§3.5a); below the cap the coin that must vote is worth more than the prize |
| buy control cheaply | nothing, if you are early — hence published concentration and backing per coin |
| lie on the optimistic path | your bond scales with the pot, so a lie must beat a detection rate of 1/(1+k); answers are resolved at a scheduled session rather than a moment you choose; disputing costs a flat floor on small claims but 20% of X on large ones — meaningful, but far below the answerer's 50% and it wins the whole answer bond; and the money sits in escrow afterwards, so a missed lie is reopenable rather than final |
| delegate-borrowed weight | V1 exposes no delegation at all; the 4× cap arrives with it |
| split one bet across many claims | the court-wide open-interest ceiling |
| force a deadlock for the payout | closed-without-decision settles at the pre-answer price, not an equal split |
| grind the bar down and wait | warmth counts escalations only, and the falling part of the bar never takes it below what is riding on the claim |
| farm the participation slice with dust addresses | the slice is per weight, not per address |
| delete somebody's thin claim for the deposit | the realm escrows deposits and repays the recorded payer — the chain's own refund goes to whoever sends the transaction, so this cannot be left to the chain (`COURTS_STRUCTURE.md` ("Deposits are escrowed by the realm")) |
| forge the court's statistics | publish distinct participants; mark statistics computed over few addresses |
| vote the treasury to yourself | §7 |

## 7. The treasury

The only real money in the system, and therefore the only thing worth attacking
the court for.

- Spent **only** on prizes and bounties, by vote. Not gas, not voter
  compensation, not redemption.
- **Threshold 9,000 bps** — nine votes in ten. Not unanimity, which would let one
  dissenter block every payout forever. It fails closed: a blocking minority means
  the money stays put.
- A **higher quorum** than a verdict, a **long timelock**, a **cap per payout**,
  and a **ceiling on total outflow per period**. The cap is what actually bounds
  the damage — a threshold tries to prevent a bad vote, a cap survives one.

## 7a. What it costs to start a court

Real GNOT, paid to the shared realm rather than to the court: a deposit set by
the realm's admin, **not refundable**, which funds the moderation of the
directory. It buys the court's slug and its listing. The new court's own treasury
starts empty and fills only as people buy its coin.

This is the one place in the system where money leaves a participant and is spent
by somebody they did not elect, so the fund's balance, intake and spending are
published (§8) and the admin's powers stop at visibility — see
`COURTS_STRUCTURE.md` ("The directory").

## 8. What every court publishes

These are security controls, not decoration: the deterrent against a corrupt
majority is that the corruption is visible, so a court that hides its numbers has
nothing behind its verdicts.

- **backing per coin** (treasury ÷ supply) beside the price
- **distinct participants**, and a mark on any statistic computed over few of them
- **charter kept** — of the founding claims a court declared, how many settled as
  declared, how many against, how many still open (three numbers, not a ratio)
- **votes that failed for lack of turnout**
- **answers overturned on dispute**
- **holder concentration** — the top ten holders' share
- **settled volume**, because it is what says whether the court's jurors are being
  paid at all

Distinct participants, holder concentration and settled volume are **maintained
incrementally**, not computed by walking the holder set: a counter bumped on an
address's first trade, a running top-ten, and a running total. A statistic that
required iterating a user-controlled collection could not be served by the chain
render at all (`COURTS_STRUCTURE.md` ("Budgets")), which is a real constraint on which
statistics may be promised.

## 9. The numbers

| | |
|---|---|
| curve | linear, one way, court's own address refused |
| answerer's bond | min(50% of the money on the claim, governance-set cap), snapshotted at answer |
| disputer's bond | max(governance-set min, 20% of X), doubling per failed dispute round on the same claim |
| the loser's bond | whole, to the party who was right (on a decided vote). On a failed vote the disputer forfeits their escalating bond, split answerer-compensation and burn; the answerer's bond is returned |
| adjudication fee | min(3% of collateral, 200 GNOT-equiv), charged once per resolution: 60% to everyone who voted, 40% to the weight that voted with the verdict |
| settlement fee | ~1% of resolved collateral, split half to the answerer and half to the roll — **V1 charges only the answerer's half** (the roll's half is deferred while CC is unspendable) |
| required turnout | max(5% of supply, min(1× **trailing-avg** money on claim, ⅓ of votable weight)) — the shipped `quorumFloor`. The falling-bar decay (supply term to 60% over the vote) is deferred past V1; the stake term never falls |
| warmth | average of escalation turnout, k = 4, half-life 6 months, fraction 0.9 — *deferred past V1* |
| delegate cap | 4× own holding — *deferred, and not computable until the ledger checkpoints balances as well as votes* |
| settlement | V1: an undisputed answer is settleable 72h after posting (`settleDelay`), then settled permissionlessly; fixed weekly sessions are deferred to V2. A disputed claim goes to a 7-day vote instead |
| escrow before payout | clamp(1 week + 1 day per 500 GNOT-equiv of X, 1 week, 3 weeks); a reopen does not reset it |
| open-interest ceiling | 20% of supply, court-wide |
| min claim deposit | governance-set, refundable, **never zero** — a spam floor |
| min open interest to answer | governance-set — below it a claim cannot be answered |
| treasury threshold | 9,000 bps, plus per-payout cap and per-period ceiling — **not implemented in V1** (the treasury is unspendable) |
| verdict threshold | 5001 bps of yes+no (5000 would pass a tie) |

All flat GNOT-equivalent figures (the disputer bond, the fee cap) convert to CC at
the curve's marginal price **at the moment they are posted or charged**.

**Who actually votes in V1, stated plainly.** Gas is paid in GNOT; juror pay is in
CC; and in V1 CC has no spendable value (§2.2). So **V1 jurors are not paid in any
sense that covers their costs** — the people who vote are the ones holding
positions in the claim, plus whoever cares about the court. That is survivable at
V1 scale and it is why the roll's fee share and the treasury are deferred rather
than pretended. It is also the single thing to measure before scaling: if
position-holders alone cannot reach quorum, nothing else in this document
matters.

**Viability, once fees are live.** A juror voting on ten escalations a year burns
about 0.5 GNOT of gas. At a 1% fee, a juror holding 1% of the roll needs the court to settle on the
order of **10,000 GNOT-equivalent of collateral a year** (the roll receives half the settlement fee, not all of it, which an earlier version of this figure forgot) before fee income covers it. Below a
few thousand GNOT of annual settled volume, **jurors are volunteers** — the
financial incentives here only close above that line, and below it a court runs
on interest and reputation. Its own page should say so.

## 9a. The governance surface, and why a founder can't set a trap

The design has accumulated a lot of knobs. An over-tunable court is its own attack
surface: several parameters, set adversarially by a founder who also holds coin,
are extraction or rug vectors — a near-zero answer-bond cap makes lying free, a
huge dispute minimum makes policing impossible, a huge answer threshold means
nothing ever resolves. So three rules govern the knobs themselves:

1. **Per-court parameters are set by the court's own coin-holder vote, not by the
   founder after launch.** The founder chooses launch values, and those values are
   **published in the charter** so anybody buying in sees the terms first.
2. **The realm puts hard bounds on the trap-parameters**, so no setting — even a
   passed vote — can configure a court into a wall. A cap has a floor; a minimum
   has a ceiling.
3. **The genuinely global parameters are realm-wide constants**, identical for
   every court, so they are not a per-court attack surface at all.

| parameter | who sets it | guard against a bad setting |
|---|---|---|
| min claim deposit | court vote | never zero; realm ceiling so a court can't price out openers |
| min open interest to answer | court vote | realm ceiling, so a court can't make claims unanswerable |
| answer-bond cap | court vote | realm **floor**, so lying can't be made cheap |
| dispute-bond minimum | court vote | realm **ceiling**, so policing can't be priced out |
| treasury threshold / payout cap / period ceiling | court vote | realm floors (already strict) — **deferred; the V1 treasury is unspendable** |
| adjudication fee rate + cap | **realm constant** | not per-court — it decides juror pay and a skim, and neither should be a founder's lever |
| θ (votable-weight quorum cap) | realm constant | — |
| trailing-average window for X (`answerWindow`) | realm constant | V1: 3h — enough trailing history to block a flash-answer; 7 days is the target as the design hardens |
| pre-answer price window (`priceWindow`) | realm constant | a full week (168 hourly buckets); a market too young to fill it defaults to the 50/50 split |
| quorum floor (5% of supply) | realm constant | — |
| 72h settlement minimum (`settleDelay`), 7-day vote | realm constant | weekly session cadence deferred to V2 |
| escrow shape (1–3 weeks) | realm constant | — |
| failed-round limit (3) | realm constant | — |
| verdict threshold (5001 bps) | realm constant | — |

The test each row passes: **could a founder who set this maliciously harm someone
who did not read the charter?** If yes, it is bounded by the realm or made a
constant; if a bad setting only makes the founder's own court unattractive
(self-punishing), it stays a court-governed knob with its terms on display.

## 10. Known limits

- **The founder problem is unsolved and probably unsolvable.** Early buyers get
  cheap control; the answer is publication, not prevention.
- **Below the viability threshold the incentives do not close.** Stated rather
  than papered over.
- **A court can be wrong.** Nothing anchors truth outside its holders. The wager
  is on what *this court* will eventually say, which is why the directory's
  statistics and the charter scorecard are the product as much as the verdicts
  are.
- **Sybils defeat every per-address rule**, including the no-position rule for
  answerers. What survives is per-weight accounting and the size of what must be
  put at risk.

## 11. What ships first

The spec above is the whole design. It is roughly four times the product, and
building it all before anybody uses it would be the ordinary way to get this
wrong. Two reviewers were given the same question independently — *what is the
smallest thing that is still this product* — and agreed on almost all of it.

### 11.1 Deferred, with what breaks

| deferred | what breaks, and why it is survivable |
|---|---|
| the folder tree and folder-claims | no governed taxonomy — but curation solves a two-thousand-claim docket, and v1 has forty on one page under founder-written headings |
| warmth, the falling bar, the half-life | quorum is fixed at `max(5% of supply, 1× money on the claim)` — warmth adapts to turnout history that does not exist yet, and three constants fitted to zero data points are a guess with a formula around them |
| delegation and the 4× cap | nobody has a delegate in a fifty-holder court, and deleting the feature deletes the attack |
| treasury spending, entirely | GNOT accrues and is unspendable — backing per coin still rises, and the most attackable surface in the system simply does not exist yet |
| the settlement fee's share to the roll | §9 says jurors are volunteers below a few thousand GNOT of annual volume, so this would be a payment rail whose designed output is zero. Say on the page that jurors are unpaid |
| the balloon map | replaced by the two lists it stood in for — **Unanswered** and **Contested** |
| four of the seven statistics | keep backing per coin, distinct participants, settled volume; the rest have a denominator of two at launch |
| charter amendment by vote | the founder edits their own text |

### 11.2 Irreducible

The one-way curve and the per-court coin; backing per coin quoted at the point of
purchase; immutable title with append-only body; pair mint and redeem, with
liquidity optional; **no deadline**; a **never-zero minimum claim deposit** and a
**minimum open interest to answer** as the two spam floors; the answer → dispute →
vote path, with scheduled settlement sessions and silence settling into escrow;
quorum with the stake term **and its votable-weight cap plus the trailing-average
X** (the fix for the biggest break, and cheap — one ring, one `min()`); weight
sealed before the dispute; escrow before payout; inert argument edges; verdicts
carrying their route; and `Render` as the interface with every action a txlink.

### 11.3 Where the two reviews disagreed, and the call

- **Attestors.** One would cut them and lean on escrow plus a notification bot;
  the other called them the reason most claims settle safely. **Cut**, in the end,
  and not on either of those arguments — a named checker turned out to be a seat
  that could be bought for nothing, because shares are mintable in pairs. What
  replaced it is escrow plus scheduled sessions.
- **Paying the jurors.** Both reviewers took the bond split as given. It is gone:
  the loser's bond goes whole to the winner, and jurors are paid an adjudication
  fee charged to the claim (§4), which is the only arrangement that cannot favour
  a verdict direction.
- **The market.** One would replace the book with an automated maker; the other
  would keep the book and have the founder quote both sides by hand. **The book
  wins**, in the tick-quantised form of §3.1 — the maker was specified for one
  pass and withdrawn when its arithmetic was worked out. The founder quoting by
  hand is the bootstrap, and it is a person rather than a mechanism, which is
  §11.4's whole point.

### 11.4 Manual before mechanised

Market making by the founder, publicly declared. A losing-side notification bot
reading chain events — telling the holders of the side an answer would zero that it
was posted, which is the holder-indexed watchlist as an off-chain service before
it is an on-chain view. The taxonomy as founder-written headings. Statistics beyond
the three as an off-chain page. Court creation as a deploy before it is a
directory. **A mechanism is worth building when the manual version becomes the
bottleneck, and not before.**

### 11.5 The riskiest thing that remains

Both reviews named it, unprompted and identically: **a market too thin to exit.**
Not adjudication, not capture, not turnout — the plain possibility that somebody
buys in and finds no counterparty, on a claim that may never resolve. The
structural answer is that a claim is a record before it is a market, so nothing
depends on liquidity existing; the practical answer is a founder standing ready
to quote, and a treasury able to post wide resting bids once it may spend. If
neither works, nothing further down this document matters.

The second risk is turnout on disputes, and its failure is silent: in a court
where quorum never clears, disputing becomes pure loss, rational disputers stop,
and every claim settles unopposed on whoever answered first. Nothing errors. The
charts keep moving. **Test that before writing settlement code**: run one court
with real claims and find out whether twenty people will read a contested factual
claim and vote, unpaid.

## Open


- The **TWAP-put residual**: closing a deadlocked claim at its pre-answer
  time-weighted price is still a put when the post-answer price sits far below it,
  and it cannot be fully closed while quorum can fail. Escalating bonds blunt it;
  it is published under the failed-vote statistic rather than pretended away.
- Cross-court standing: courts can read each other's records for free, which
  would let a court require standing elsewhere as an entry condition. Unspecified.
