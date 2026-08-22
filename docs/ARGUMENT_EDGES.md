# Argument edges on chain

**Status: designed, scoped down from what the overlay draws, implementing.**

The web overlay renders a "Where this claim sits" section with three kinds of
edge between claims, and the chain stores none of them — every screen that draws
one says so ("your local curation — held in this browser, not on any chain").
This is the design for moving the part that *can* move onto the chain.

## The scope is one of three types, and the other two are findings

The overlay's comment says its three types match "the repo's own future design in
`COURTS_STRUCTURE.md` §5". Read against §5, that is not so, and the mismatch is
the first thing this design had to settle.

| overlay type | §5 status | verdict |
|---|---|---|
| `bears` (supports / contradicts) | §5's **argument** edge, fully specified: any number, anybody, any time, no mechanical effect | **build it** |
| `part` (containment) | §5's **containment** edge — but its guards say **"only sections may be containment parents"**, and §6 defers sections | **blocked**, and the overlay's claim→claim `part` edges contradict the spec |
| `supersedes` | not in §5, or anywhere else in the docs | **unspecified** — the overlay invented it |

So this change implements argument edges only.

**Containment is blocked on a deferred feature, not on effort.** §5 is explicit
that a containment parent is a *section*, and §6 defers governed sections with a
reason ("a curated taxonomy solves a two-thousand-claim docket, and a court that
has one has already succeeded"). Building claim→claim containment now would ship
the exact shape §5's own guard forbids. What the chain already has for this job
is folders: flat, moderator-curated, per-court — the containment layer this realm
actually chose.

**`supersedes` is real but unspecified.** It means "a re-filing after a claim
died unanswered", which this docket produces constantly — `deadClaimSecs` is
twelve weeks, so a live question outlives its contract and gets re-put. The
covid fixture uses it three times. It deserves a spec entry before it gets an
entrypoint; it is not in this change.

## Shape

Two `bptree`s on the court, sharing one edge object:

```
argOut : beClaimKey(from) + beClaimKey(to) -> *argEdge
argIn  : beClaimKey(to)   + beClaimKey(from) -> *argEdge   (the SAME pointer)
```

A claim page needs both directions — the edges this claim asserts, and the edges
asserted about it — and each is then one prefix scan on an 8-byte key, the same
shape `stakers` uses for `addr|side`. One object in two indexes rather than two
copies: the stance cannot desync from itself, and an edge is immutable anyway
(to change a stance you remove and re-add, which re-prices the write).

Both trees are **nil until the first edge exists**, and every read tests for nil
rather than calling an `ensure*` helper. That is forced by
`check-read-purity.py`: a read that allocates makes the first caller change what
the second one sees, and a query carries no storage deposit, so a lazily-
initialising read is unpaid state growth.

## What it costs, and who pays

`WriteString`-level facts first: an edge is two claim ids, a stance byte, an
author address and a height. The write is an ordinary transaction and carries the
ordinary GNOT storage deposit, which is this realm's standard price for every
flood surface ("court-count floods are storage-deposit-priced", MODERATION.md
§2/§13.5). No bond, no fee: §5 says *anybody, at any time*, and a bond on
speech-shaped state would price out the counter-evidence the feature exists to
carry.

## The caps, and the griefing they trade against

Unbounded incident edges would make a claim page's render grow with what an
attacker is willing to write — the exact failure `seriesRowCap` exists to prevent
elsewhere in this realm ("no read's cost may grow unbounded with attacker-priced
writes"). So:

| cap | value | why |
|---|---|---|
| outbound per claim | 32 | what one claim can assert about others; the author's own page |
| inbound per claim | 64 | what others may assert about it; bounds the render |
| inbound per (claim, author) | 4 | the anti-sybil term |

The inbound cap is the uncomfortable one, and it is worth naming rather than
hiding: **a cap on inbound edges is itself a griefing vector** — fill a claim's
64 slots with junk and no real edge fits. The per-author term is what prices it:
filling 64 slots needs 16 distinct addresses, each paying its own storage
deposit, which is the same economics every other flood here faces. The
alternative — no inbound cap — moves the damage from "this claim's page is full"
to "this claim's page cannot be served", which is worse and unbounded.

## Removal

- **the edge's author** may remove their own edge, always;
- **an active court moderator** may remove any edge, single-signer, the same
  authority level as filing a folder (additive/reversible acts are 1-of-n here,
  and removing one wrong edge is reversible by re-adding it).

**The target claim's author may NOT remove inbound edges.** That is deliberate
and it is the whole point of the feature: a claim's author deleting the edges
that say "this is contradicted by #12" is exactly the censorship an argument
graph exists to resist.

## Moderation

An edge is an assertion about two claims and carries no free text, so there is no
new text surface to escape — the reader sees the two claims' own titles, which
are already gated by `claimTitleFor`. What the gate must still do:

- an edge to or from a **purged or globally-redacted** claim is not returned by
  the reads, for the same reason the title is not;
- moderators can remove edges outright (above).

## What it deliberately does not do

Nothing mechanical. §5: "a settled supporting claim does not move its parent's
odds, does not lower a bar, does not force a verdict... Views may aggregate; the
chain does not infer." No money path reads an edge. This is render-layer state,
like `stakeseries.gno` says of itself.

Edges are **within one court**. A cross-court edge would put another court's id
in the key and split the moderation authority over one object between two
moderator sets; the overlay's curation is per-court for the same reason.

## Migration

The two trees are new nilable fields on `Court`. An already-deployed court reads
them as nil, every read returns empty, and the first write creates them — no
migration step, no version field, no backfill. That is the same shape `c.mod`
already uses for moderation state.
