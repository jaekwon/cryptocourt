# Courts — structure, render and interface (V4 spec)

What a court is made of structurally: the directory it lives in, what a claim is,
how claims argue with each other, what the chain serves, what it costs, and what
the interface owes a reader.

This document is the specification. The reasoning behind it — including three
discarded map layouts and several rules that were reversed — is in
`courts/COURTS_DESIGN_LOG.md`; where the two disagree, this one wins.

Companion: `COURTS_TOKENOMICS.md` (the coin, settlement, incentives, gas of the
economic rules).

---

## 1. Why any of this exists

An unfalsifiable narrative is not a claim, and a court that cannot host it is
useless for the thing people actually argue about.

*"It was an inside job"* cannot be settled. But it decomposes: *the shot came
from a second position* — ballistics, settleable. *The released footage was
edited between these two frames* — forensic, settleable. *A named agency had
personnel on site* — documentary, settleable.

**So the product is the record, not the verdict.** The top-level narrative may
never settle; its parts settle one at a time, and a reader gets a map of which
pieces held and which did not — with the counter-evidence attached to the claim it
counters, in the same view. That last property is the whole reason to build this
rather than a generic prediction market: the failure mode of contested research is
that claims and their debunkings live in different places, so nobody meets both.

## 2. The directory

Many courts live in one realm, because *anybody can start a court* has to mean a
transaction rather than a deploy and a compiler.

**Each court has a slug** — `[a-z0-9-]`, at least one non-digit, unique, bound at
creation. Starting one costs a **non-refundable deposit in GNOT** set by the
realm's admin, paid to the realm and not to the court; it buys the slug and a
listing, and it funds the moderation of the shelf. A new court's own treasury
starts empty and fills only as people buy its coin.

**Three tiers, and only the admin moves a court between them:**

- **promoted** — an explicitly ordered list, in whatever order the admin wants;
- **listed** — everything else, ordered by a sort the *reader* picks, never the
  admin;
- **unlisted** — absent from the page, reachable by slug, working normally.

**The boundary that makes an admin acceptable: they decide what is easy to find
and nothing else.** No verdict, treasury, coin, claim or vote is reachable from
the directory. Hiding removes a court from a list and changes nothing inside it —
which is why hiding is tolerable where deleting would not be, and there is no
delete.

Two obligations follow: an unlisted court says so on its own page, and the
moderation fund's balance, intake and spending are public.

## 3. What a court stands for

Every court carries a **charter** in markdown: what it is for, what it will hear,
and **what it already thinks**.

That last part is the unusual one. A court is invited at creation to list
contested claims *together with the verdict it expects*, because every
adjudicating body has priors and the only dishonest thing to do with them is hide
them.

**The declared verdicts are not verdicts.** Founding claims open as ordinary
claims with the charter's expectation attached as an annotation, and the court
must settle them like anything else. Pre-settling would make the founder a
publisher rather than a court.

Which produces the most informative number in the system: **of the founding
claims, how many settled as declared, how many against, how many are still open.**
Three numbers, never a ratio. It cannot be faked without actually settling claims,
and it is also the cold-start answer — a new court is not an empty docket, it is a
docket of exactly the questions its founder thinks matter.

## 4. A claim is a title and a body, and only one is the claim

**The title is the proposition.** One sentence, bounded, refusing control
characters — it goes into shared list items, and a newline in one forges a row.

**The body is markdown**: context, sources, what would count as evidence. It is
what a reader reads and it is *not* what gets adjudicated.

Markdown *on the chain's own renderer* — the realm passes it through
`sanitize.Block` and prints it, so gnoweb shows the author's formatting. The web
overlay deliberately does NOT: it escapes the text and splits it into paragraphs
on blank lines. Re-implementing a markdown parser there would add a second,
differently-shaped injection surface for a field any stranger can fill, and buy
emphasis. Paragraphs are the structure a question of fact needs. The two
renderings differ, and this is the reason.

That separation prevents the obvious attack. If the body could change what the
claim means, an author could take a position, watch the market, then rewrite the
framing so their side becomes the true one. So:

- **The title is immutable.** A different question is a different claim, and the
  argument graph is how you connect them.
- **The body is append-only.** Fixed at creation; the author may add timestamped
  notes below and may never revise or remove what is there.

Identity is `hash(parent, normalised title)`, so the same sentence cannot be
posted twice in the same place. A claim may be re-parented by its author while it
is unsettled and has no money on it; after either, it is fixed.

**Opening a claim does not require making a market** — see
`COURTS_TOKENOMICS.md` ("Positions and the market"). A claim is a record first.

## 5. Claims that argue with claims

Two kinds of edge, and they must not be merged.

| | containment | argument |
|---|---|---|
| shape | a tree | a graph on top of it |
| cardinality | at most one parent | any number |
| stance | — | supports / counters |
| gives | paths and sections | the research map |
| who may add | the author, at creation | anybody, at any time |

If a claim could sit in three places, paths stop identifying anything. So: one
containment parent, many argument edges — a piece of evidence genuinely does bear
on several claims, and that is what the argument edges are for.

**Argument edges do nothing mechanical.** A settled supporting claim does not move
its parent's odds, does not lower a bar, does not force a verdict. Inference over
a partially-settled cyclic graph is a research project, and mechanical propagation
would break the promise that a claim's verdict is decided by the people voting on
*that claim*. Views may aggregate; the chain does not infer.

Guards: no containment cycles, a depth cap, and only sections may be containment
parents.

## 6. Sections

A **section** is a heading with a slug, holding claims and other sections.

In V1 sections are written by the founder as part of the charter and edited by
hand. **Governed sections — where a heading is itself a claim, affirmed by vote,
its slug bound on affirmation and retired by another vote — are deferred**: a
curated taxonomy solves a two-thousand-claim docket, and a court that has one has
already succeeded. The design is in the log if it is wanted.

What survives from that design and is worth keeping when it returns: a slug binds
when the heading is *affirmed*, never at creation, so rivals may compete for
`/ballistics` and squatting an unaffirmed name buys nothing.

## 7. What a reader is shown

**Two lists carry the product**, and they are what the discarded graph view was
standing in for:

- **Unanswered** — claims with no counter-claim, sorted by money at stake. A
  cluster of support with nothing arguing back is either settled or unexamined,
  and in contested research that distinction is the whole game.
- **Contested** — claims whose counter is still open.

Both are sorted lists: cheap on chain, linkable, sortable, and readable on a
phone, which the graph was none of.

**Settling a claim whose children are unsettled is allowed** — requiring the
subtree would deadlock everything, since anybody may add to it. So every claim
view states **what is unsettled underneath**: how many supporting and countering
children are open, and how much is riding on them. A verdict rendered beside open
opposition reads as provisional and should look it.

**Verdicts are final; contradictions are shown.** If a counter-claim later
settles against a parent's verdict, nothing reverses — payouts have happened and a
retrial would be theatre. Show the contradiction on both claims and let the court
wear it. **Opposition raised after a verdict** is a court-quality statistic.

## 8. The chain render

> **The chain carries all the information. An overlay may only add presentation.**
> Anything needed to trade, answer, dispute, vote or judge the court must be
> legible from `Render` alone in gnoweb.

### 8.1 What gnoweb gives us

Goldmark with tables, strikethrough, footnotes, task lists, auto heading IDs.
**Raw HTML is stripped**, so everything is markdown plus gno's extensions:

- `> [!WARNING]` alerts, optionally collapsed.
- `<gno-columns>` … `<gno-columns-sep />` … `</gno-columns>`. The separator must
  be self-closing; `p/moul/md.Columns` emits a bare tag and silently collapses
  both columns, so write it by hand.
- `<gno-form>` — without `exec` it round-trips its fields back into `Render`'s own
  path, which is the only way an address-dependent view works at all.
- `<gno-foreign>` sandboxes markdown the realm did not author. Emit only via
  `gno.land/p/nt/markdown/foreign/v0`.
- Bare URLs do **not** autolink. Write real links.

Two constraints shape everything: **`Render` has no caller identity**, so every
"your position" view takes an address explicitly; and a query gets **~3 s of
reference CPU**, with output over **1 MiB not rendered at all**. Target 40 KB.

### 8.2 Actions are links

A link whose web-query carries `help` becomes a signable transaction with
arguments pre-filled:

    [Vote yes](/r/courts:orem$help&func=Vote&id=188&choice=yes)

`p/moul/txlink` builds them. **Every button in the interface is one of these**,
which is what makes the overlay optional rather than load-bearing.

### 8.3 Routes

| path | serves | bound |
|---|---|---|
| `` | the directory (courts by tier) | featured, then listed |
| `:<slug>` | one court: coin stats and its claims docket | — |
| `:<slug>/<id>` | one claim: title, body, market, verdict | — |

The shipped `Render` serves exactly these three. The richer routes once planned —
a section `:<slug>/s/<slug>`, a claim's `/c/<id>` form and its `/history`, a vote
`:<slug>/v/<id>`, `:<slug>/who/<address>`, and the `unanswered` / `contested` lists
— are **V2 and not yet served**.

### 8.4 Untrusted text has exactly two homes

- **Bodies and charters** — markdown by strangers — go in `<gno-foreign>`: links
  marked `nofollow ugc`, no forms, visibly framed as somebody else's writing.
- **Titles, section names and slugs** appear in tables and list items and go
  through `sanitize.TableCell` / `sanitize.InlineText`. A raw `|` in a title
  breaks out of its cell and forges a row.

### 8.5 Budgets

No route may iterate a user-controlled collection without a page bound, and **no
route may render a body inside a list** — bodies appear only on a claim's own
page, where there is one.

Statistics that would need walking the holder set are **maintained
incrementally** instead: a counter on an address's first trade, a running
top-ten, a running total. A statistic that cannot be served cannot be promised.

## 9. Storage layout and what it costs

Measured, not estimated: **100 ugnot per byte of delta, and 247,600 gas plus 14
per byte for every object a transaction dirties**.

> **Object count governs, not bytes.** Dirtying one object costs about what
> writing seventeen kilobytes into it costs. Few objects, each small, everything
> one action touches co-located.

### 9.1 The layout

| what | how | encoded |
|---|---|---|
| indexes, edges, balances, orders, roll, ledger | **bptree**, fanout 32 | new key +442 B; overwrite +55; remove −110 |
| claim header | one struct object, title inline | 1,291 B |
| body | its own object, chunked so appends never rewrite | 2 KB ≈ +2,086 B |
| **book, per (claim, side)** | one packed `[]byte`: bytes 0–15 the two occupancy bitmaps, then 100 ticks × 20 B (resting 8 + surv 8 + epoch 4) | ≈2,338 B |
| price ring | 108 bytes as a string field on the header | +146 B |
| open-interest ring | same shape, for the trailing-average X quorum keys off | +146 B |
| checkpoints | packed string, 12 B per entry (epoch 4 + value 8) | 12 B per vote |

**The 40× trap is literal.** A slice of anything but bytes encodes one 40-byte
`TypedValue` per element: 100 ticks as `[]uint64` measured 4,319 bytes against
≈2,338 packed. Same for checkpoints-as-two-int-slices (repacked to one 12 B/entry
string), roll-as-slice, edges-as-slice.

**avl is not bptree**: one insert into a 200-key avl measured +2,038 bytes and
447,300 gas against +442 and 169,669. Never on a hot path.

### 9.2 Per action

| action | deposit (ugnot) | gas |
|---|---|---|
| open a claim (2 KB body) | 784,100 | ~10.8M |
| — with the book allocated lazily | **≈476,500** | ~9.9M |
| post a resting order | 50,200 (refundable) | ~9.0M |
| take, crossing one level | 6,500 | ~7.9M |
| **take, crossing three levels** | **6,500** | **~8.0M** |
| mint a complete set (first / after) | 94,400 / 16,500 | ~9.5M |
| redeem a matched pair | −16,500 | ~9.8M |
| post an answer | 51,000 | ~7.6M |
| dispute | 50,200 (refundable) | ~8.9M |
| vote (first / after) | 46,300 / 7,600 | ~9.0M |

The bolded row is the argument for the tick book: **three levels cost the same as
one**, because they share an object. Across a tree, each level adds ~3M gas.

### 9.3 Deposits are escrowed by the realm

The chain refunds released deposit to **whoever sends the transaction**, pro-rata
over the realm's pool. Left alone, that makes deleting other people's claims
profitable.

So the realm keeps its own book: record who paid for each claim, hold what is
released, and repay the recorded payer on request. **The sweeper gets a tidy
docket and nothing else.**

**Only unanswered, abandoned claims are sweepable.** A claim that has resolved is
part of the permanent record and is never deleted — its deposit is returned to the
opener at resolution, and its verdict, title and final tally are kept forever.
Sweeping applies to claims that were never answered and now sit idle with no open
interest; that is the case where deleting is correct, and it returns the deposit
to the opener too. What a sweep may always reclaim, even on a kept claim, is the
transient bulk — a closed claim's order book and price ring — never the verdict.

## 10. The interface contract

**The deck is normative and is reconciled after every rule change.** A wireframe
showing a superseded rule is more persuasive than the document superseding it.

### 10.1 Four things a participant must understand

1. Buying the coin is **permanent** — there is no sell button, ever.
2. A share pays **one coin if yes, nothing if no**, and there is **no deadline**.
3. Anyone may **post an answer** with a bond large enough that lying does not
   pay; in V1 an undisputed answer becomes settleable **72 hours after it is
   posted** (fixed weekly sessions are a deferred V2 refinement), and silence
   settles — safely, because the money then waits in escrow where it can still be
   disputed.
4. Every button spends real money and is **final**.

Deliberately hidden, because knowing them changes no decision: warmth, the floor,
the falling bar, the bond slices, the delegate cap, the open-interest ceiling, the
settlement price rule, escrow rounds.

### 10.2 Rules the surfaces obey

- **Titles render verbatim everywhere**, truncated with an ellipsis, never
  rewritten. The title is immutable; paraphrasing it per screen dissolves the
  integrity argument.
- **Time is wall-clock.** "You can object until Sat 09:15 — about 4 days", with
  block height subordinate. Nobody converts blocks.
- **A verdict shows its route** — *undisputed* or *by vote (71%)*. That
  difference is the epistemic product.
- **Backing per coin sits beside the price**, because it is the number a
  first-time buyer needs most.
- **Statistics over few distinct participants are marked as such.**

### 10.3 The words

| not | but | why |
|---|---|---|
| assert | **post an answer** | "assert" is free talk; this is bonded and timed |
| dispute (an answer) | **answer dispute** — the canonical act; never "challenge" | "challenge" is reserved for a counter-claim |
| oppose / opposing claim | **counter / counter-claim** | pairs with "support"; frees "challenge" |
| escalate | **put to a vote** | nobody escalates; a vote starts |
| void | **no decision** / **closed without a decision** | one meant trading resumes, the other meant everyone is cashed out — a holder could reasonably expect their money back |
| reset rate | **votes that failed for lack of turnout** | it carried a judgment while undefined |
| standing (for weight) | **your weight in this vote** | standing is the reputational record, not voting power |

### 10.4 The screens

Ten, in the deck: the directory · a court · the map · a section · a claim · a
vote in session · **what needs you** · **an order ticket** · **your own page** ·
and the same claim as the chain alone serves it.

The three added last carry weight the others cannot:

- **What needs you** is the interface the security assumption depends on: the
  holder-indexed list of answers posted on claims you hold, flagged by whether
  the answer is against your side. Nobody is more motivated to check a false
  answer than the people whose money it would make worthless, and the court knows
  exactly who they are. It is a notification, deliberately not a role — a named
  checker turned out to be a capturable seat rather than a safeguard.
- **The order ticket** is the screen between a button and a position: average
  fill, worst fill, what it pays if right, that it pays nothing if wrong, and —
  the one every prediction market forgets — *what happens if it never resolves*.
- **Your own page** carries positions, what is claimable, what is in escrow, and
  what changed while you were away.

Still missing, in the order they do damage:

1. **Refusals**, each a designed path: the slug is taken; this claim cannot yet
   reach the turnout that would decide it; you are answering after the cutoff for
   the next session.
2. **Empty and new states.**
3. **After you act** — nothing currently follows a button.
4. **Mobile** — the docket row is a fixed four-column grid with no breakpoint.
5. **Search**, for a research product whose largest court holds two thousand
   claims.

## 11. Building it on the governor

The courts design assumes a governance layer underneath: a token whose voting
weight is readable at a sealed past epoch, per-kind rules, and a way to run code
when a vote passes. That layer exists — checked against it rather than assumed.

**Use the instantiable one.** There are two: a package-level singleton whose
state is realm-global, and `p/kourt/governor/v0`, which is a `Governor`
struct constructed with `New(voters, token)` and a per-instance ledger. Only the
second can host many courts in one realm, and its ledger's own documentation
already anticipates this — *"so one realm can run several, and a court can name
its own coin."*

### 11.1 What already works, exactly as the spec wants

| the spec needs | the governor has |
|---|---|
| many courts in one realm | a `Governor` struct and a per-instance ledger |
| weight sealed **before** the dispute | `Epoch()−1` snapshotted onto the proposal; past-votes refuses the current epoch outright |
| a quorum denominator that is not total supply | the electorate's engaged-total hook, snapshotted at propose |
| per-kind rules, frozen for an open vote | rules copied onto the proposal, so a later retune cannot move a bar people already voted at |
| run code when a vote passes | a kind's `Do`, dispatched with a **sub-realm** identity rather than the governor's own |
| a proposal that carries a claim id | the payload is an arbitrary string, and `Describe` and `Do` consume the identical one |
| abstain counts to turnout, stays out of the result | exactly that, already |
| a bar that cannot rise mid-vote | the early-close arithmetic is already one-directional |

### 11.2 What has to be added, and where

**In the governor — about fifty lines, all additive:**

1. **Clamp, do not panic, when the engaged denominator exceeds supply.** Today it
   panics, which forbids opening a dispute on a claim whose stake exceeds
   achievable turnout — and the spec deliberately wants that claim *hosted and
   undecidable*, not refused.
2. **An optional per-proposal turnout interface.** The engaged-total hook sees
   only an epoch, so it cannot express `max(5% of supply, 1× money on the claim)`,
   which is per-claim. Type-asserted, falling back to the existing behaviour, so
   nothing that exists today changes.
3. **Expose the snapshot** — the engaged figure and the epoch — so a court can
   render *your weight in this vote* and the bar.

**In the court, not the governor:** the roll, all money
(bonds, escrow, the fee split, the curve), claims, sections, the tick book, and
`Render`. Two of those are deliberate: the governor exposes one voter at a time
rather than an enumerable roll, because handing back the tree would hand back a
live mutator under its authority; and it ships no minter, because issuance policy
is the consuming realm's business — which is exactly what the curve is.

### 11.3 Three things the spec had wrong about the machine

- **Nothing happens at a block boundary.** "The verdict is recorded when the
  window closes" is not how the chain works: somebody must send the transaction
  that records it. The early-close *arithmetic* is real; the *instantaneity* is
  not, which is why settling is permissionless and why whoever wants the clock
  started can start it.
- **A tie passes.** The threshold comparison is `yes·bps >= (yes+no)·threshold`,
  so 5000 bps carries a tied vote. Verdicts use **5001**.
- **There is a ceiling on concurrent disputes.** The governor allows 64 open
  proposals with some reserved for governance kinds, so a court has roughly **56
  disputes in flight at once**. Fine for V1 and worth knowing before it is not.

## Open

- Whether governed sections return in V2, and whether the map returns with them.
- Cross-court reading: courts can read each other's records for free, which would
  let one require standing elsewhere as an entry condition.
- (Resolved in the tokenomics: escrow scaling, the three-round limit, weekly
  sessions with a 72h minimum.)
