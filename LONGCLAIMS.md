# LONGCLAIMS.md — rewarding a five-year call

**Status: RECONSTRUCTED SPECIFICATION, NOT AUDITED, NOT IMPLEMENTED.**

An earlier version of this design was worked out in conversation and **never written down**; it
was dropped when attention moved to the answer bond. That was a mistake — the owner named this
the *primary* concern and the bond the secondary one. This file exists so it cannot be lost
again. Numbers here are **re-derived from scratch** and every one of them is marked as
**(D)** derived, **(S)** read from source, or **(A)** assumed and needing audit.

---

## 1. The requirement, in the owner's words

> *"If I knew with scant evidence that covid19 was lab leaked, I should be rewarded for staking
> on it the whole time, not be dismissed with a new claim."*

> *"I want to be able to claim rewards for 5 years, even if it doesn't give me the full inflation
> as if I had won several bets over those years — it should give me reputation or something and
> be > 0."*

Two things are conceded in the requirement itself and must stay conceded: **not** the full
inflation of five years of wins (that is a money printer), and **> 0** (today it is exactly zero).

## 2. What is already closed, so this does not reopen it

- **A claim cannot live five years.** `deadClaimSecs = 12 weeks` (S), keyed on `openedAtTime`,
  never paused. `PostAnswer` refuses past it whether or not anyone has closed the claim (S).
- **Re-answerability is dead, three independent ways** (`GAMETHEORY.md` §5). Resetting the
  verdict **bricks the claim 72h after any undisputed re-answer with no adversary at all** —
  7 of 7 exits refuse, principal locked forever, no admin path — and "nobody disputes" is the
  *modal* outcome. Keeping the verdict makes it a no-op. Resetting the whole round state hands a
  sniper 11 retries and takes per-claim destruction from 19% to 89.3%. **There is no fourth
  branch.** So "make the old claim answerable again" is not available and this design must not
  smuggle it back in.
- **Principal returns 1× and the prize is minted** (`REGULATIONS.md:18-21`, escape (b)). Any
  reward here must not be funded by a counterparty.
- **An expired claim pays nothing today.** **M**, from `GAMETHEORY.md` item 4: a 300 CC position
  held 12 weeks evaporates **22.950015 CC of conviction** and receives principal only.

## 3. The shape: credit accrues ACROSS claims, and pays in cheaper answering

### 3.1 Why it cannot be conviction on one claim

Conviction is capital×time and accrues per block (S), but the claim dies at 12 weeks, so
conviction on any single expired claim is capped at 12 weeks' worth. **A five-year call is
therefore necessarily a sequence** — the COVID docket asks the laboratory question in 2020, 2023
and 2025, and that shape was *forced* by the rule, not chosen. So the unit of credit is
**one expired claim on which you held the eventually-vindicated side**, and a five-year call earns
credit repeatedly rather than continuously.

### 3.2 Why the payout should NOT be coin

Three reasons, and the third is the one that decides it:

1. **Regulatory.** A coin payout for a position on an *expired* claim is a payment contingent on
   an outcome the claim never adjudicated. Minting it re-opens exactly the question
   `REGULATIONS.md` escape (b) exists to close. A non-monetary credential is not a payment at all.
2. **The money printer the owner already named.** Any per-claim coin reward scaled to hold time
   is farmable by asking the same question repeatedly and holding both sides.
3. **There is a payout that is worth real money without being a payment: make answering
   cheaper for you.** The bond is the binding constraint on participation — `GAMETHEORY.md`
   measures the cost of a 50% bond as an ~8× restriction of the eligible answerer set. So:

> **The reward for being early and right is that your future answers cost less to bond, and you
> get first refusal on answering.**

That compounds in the direction you want — the person who was right early can act on their next
conviction more cheaply — and it mints nothing.

### 3.3 It reuses machinery that already exists

- `priorityNetRecord` and a 24h answer-priority window (S), gated at 3 qualified addresses
  (`priorityColdStartN`) (S).
- `credEligible` / `creditUpheld` / `resetOverturned` (S) — the existing credential already
  tracks *answer* accuracy. This adds a second source: *stake* accuracy on expired claims.
- **The deferred conviction lever** (`GAMETHEORY.md` §13.5) is a bond discount keyed to own
  conviction, already specced and straddle-proofed at `u* ≥ 1 − L0/k` = 25%. **A
  credential-keyed discount is the same machinery with a different key**, so these two should be
  designed together or one will foreclose the other.

## 4. The three hard problems, stated rather than hidden

### 4.1 LINKAGE — how does an expired claim connect to its successor? (the hardest)

Credit for holding "the eventually-vindicated side" requires knowing which later verdict
vindicated it. Options, with the objection to each:

- **(a) The author declares a parent claim ID at open.** Cheapest. But the author picks their own
  ancestry, so they can point a new claim at whichever expired claim makes their friends
  eligible. Needs the parent's *text* to be constrained, and Kourt has no semantic equality.
- **(b) Anyone proposes a link; it is voted.** Honest but expensive — a vote per link, on a
  system whose measured problem is already **turnout** (`GAMETHEORY.md` §4.2).
- **(c) Reuse the structure layer's argument edges.** **Blocked as stated:** the whitepaper
  commits that *"edges will be inert by design"* and that *"the chain does not infer."* A
  credential keyed on edges makes them non-inert, contradicting a published design decision. If
  this route is taken, that commitment must be revisited **explicitly**, not quietly.
- **(d) The claim's wordlock.** Claims are wordlocked (S). If two claims are *byte-identical* in
  their proposition, the link is mechanical and unforgeable. **This is the only option needing no
  new trust, and its limit is obvious:** re-asking the same question usually rewords it, and the
  COVID docket's three laboratory claims are **not** byte-identical.

**(A) My recommendation is (d) with (a) as a fallback**, precisely because (d) is
manipulation-proof and cheap where it applies. **This is the single biggest open question in the
design and it needs the audit's judgement, not mine.**

### 4.2 ANTI-STRADDLE — stake is no-loss, so why not hold both sides of everything?

`WithdrawStake` returns 1× on both sides (S), so holding both sides of a claim costs only carry.
If credit accrues to whichever side is later vindicated, **the dominant strategy is to straddle
every claim** and collect on all of them.

- Keying credit to **conviction** rather than stake presence raises the cost from zero to
  capital×time — this is the same fix that defeated the straddle in `GAMETHEORY.md` §13.5, where
  the threshold came out at `u* ≥ 1 − L0/k` = **25%** of the larger pool.
- **Netting the opposing position is the obvious next step and it was measured FATAL in the
  analogous case** (§13.5): with the self-tax removed, carry alone is 6.4× too cheap and no
  threshold ≤ 1 works. **(A) Whether that result transfers here is unknown and is the second
  question for the audit.**

### 4.3 ANTI-SPAM — what stops farming credit by asking questions nobody cares about?

Filing costs a deposit plus a fee (S), and **the fee burns unconditionally when a claim dies
unanswered** (S — `claim.gno:368-378`). So expiry is already not free. But:

- A self-answered pair of claims could farm credit at the cost of two fees.
- **(A) The floor is presumably that credit must require the claim to have carried *someone
  else's* conviction** — but `GAMETHEORY.md` already records that the "never carried stake"
  predicate is **farmable by a 1-unit self-stake**, so a naive version of this fails.

## 5. Draft numbers — ALL (A), for the audit to derive or refute

The earlier lost version had *~1 coin to file* and *~17 points for a five-year call*. I can
reconstruct the shape but **not** defend the constants, so they are stated as a starting point to
be replaced:

| quantity | draft | basis |
|---|---|---|
| credit per vindicated expired claim | 1 point × conviction weight | (A) |
| conviction weight | `min(1, ownConv / u*·mg_max)`, `u*` = 1/3 | (D) from §13.5's straddle threshold |
| five-year call, 5 re-askings, full weight | **5 points** | (D) — *not 17; I cannot reconstruct 17 and will not pretend to* |
| priority gate | 3 points (existing `priorityNetRecord`) | (S) |
| bond discount at full credential | ≤ 25% of the bond | (D) — §13.5 measured 75% of the price as non-discountable by construction |

**Note the honest discrepancy:** a five-year call earning ~5 points against a priority gate of 3
means the credential *saturates early* and the fifth year adds nothing. Either the gate rises,
the credit scales with hold time within each claim, or the reward has a second dimension. **(A) —
the audit should resolve which.**

## 6. What the audit must prove

1. **Linkage (§4.1).** Which of (a)–(d), or a fifth option? If (c), the whitepaper's inert-edges
   commitment must be revisited explicitly. If (d), how much of the real use case does
   byte-identity actually cover — the COVID docket is the test case and its three laboratory
   claims are **not** byte-identical.
2. **Straddle (§4.2).** Does §13.5's `u* ≥ 1 − L0/k` threshold transfer? Does netting fail here
   the same way?
3. **Spam (§4.3).** Is there a self-stake-proof predicate for "this claim carried real
   conviction"? The naive one is known farmable.
4. **Saturation (§5).** A five-year call must be worth measurably more than a one-year call, or
   the requirement is not met.
5. **Does a bond discount actually deliver "> 0" in the owner's sense?** It is worth money only
   if the holder answers again. Someone who was right once and never answers gets nothing. **Is
   that acceptable, or does the reward need to be claimable without further participation?** This
   is a question about the requirement, not the mechanism, and it should be surfaced rather than
   assumed.
6. **Interaction with the settled bond work.** The discount keys on the same floor C3 re-keys
   (`answer.gno:148`) and draws on the same budget §13.2 shows is spendable only once. **Can the
   credential discount and C3 coexist, or does one foreclose the other?**
7. **Does any of this smuggle re-answerability back in?** §5's trichotomy is exhaustive; a design
   that effectively re-opens an expired claim inherits all three failures.

## 7. What this design does NOT do

It does not make an expired claim answerable, pay coin for an expired position, or give the
five-year holder anything approaching five years of inflation. **It converts being early and
right into cheaper future participation.** Whether that satisfies "reputation or something and
be > 0" is the owner's call, and §6.5 is where it gets decided.
