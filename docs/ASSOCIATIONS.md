# Associations on chain

**§5 calls this an argument edge; the code calls it an association.** One thing,
two names, and `realm/r/kourtv2/association.gno` carries the note on why: this
tree already uses "argument" for a function's parameters, so a file holding both
meanings is a file where `TestOrderFoldersBoundsItsArgument` reads like it is
about this feature. Quotations of §5 below keep §5's word — a citation that
paraphrases is not a citation.

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

So this change implements associations only.

§5's four properties all still hold, including after the association bond was
added: a bond nobody is refused and everybody honest gets back is a deposit
against griefing, not a gate — see *What it costs, and who pays*. "No mechanical
effect" is untouched: an edge still moves no vote, no tally and no deadline.

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

**That entry now exists as a proposal: `docs/SUPERSEDES.md`.** Writing it turned
up why the punt was right for a better reason than "no spec": `supersedes` is not
an opinion the way an association is. "X re-files Y, which died unanswered" is
a statement about the docket's own history, and `claimState.closed` is the
realm's own record of exactly that — set in one place, only when a claim has no
answer and the timeout has passed. So the chain can verify the predicate instead
of storing an assertion, which makes it a different design, not a second copy of
this one. Still unimplemented, and one policy call in it is the owner's.

## Shape

Two `bptree`s on the court, sharing one edge object:

```
assocOut : beClaimKey(from) + beClaimKey(to) -> *assocEdge
assocIn  : beClaimKey(to)   + beClaimKey(from) -> *assocEdge   (the SAME pointer)
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
author address, a height, and — since the association bond — a held amount and
the unix second its window closes. The write is an ordinary transaction and
carries the ordinary GNOT storage deposit, which is this realm's standard price
for every flood surface ("court-count floods are storage-deposit-priced",
MODERATION.md §2/§13.5).

**And a refundable bond, from strangers only.** This section used to read "No
bond, no fee: §5 says *anybody, at any time*, and a bond on speech-shaped state
would price out the counter-evidence the feature exists to carry." That objection
is still right, and it is why the bond is **refundable** rather than a fee:

- The **asserting claim's own author** pays nothing — they already have a
  deposited claim behind their name.
- An **active moderator** pays nothing — they are answerable by election.
- **Everybody else** posts `AssociationBond(court)`, held in the court escrow.
  A moderator who agrees the edge was worth attaching calls `ApproveAssociation`
  and the coin goes back; one who does not calls `DisapproveAssociation`, which
  **burns** it and drops the edge. If nobody looks within `assocBondWindowSecs`
  (14 days), the author takes it back with `ClaimAssociationBond` — **unjudged
  means approved**, because the other direction makes moderator inactivity a
  confiscation engine.

So an honest stranger is out the money only until somebody looks, and only ever
temporarily; a griefer pays for every bad edge. §5's *anybody, at any time* still
holds — nobody is refused, and the caps below are still the only hard limit.

What the storage deposit alone could not price was the case the caps section
below calls the uncomfortable one: filling a claim's inbound slots with junk. The
deposit is cheap enough that spamming was rational. **The price falls on being
wrong, not on speaking.**

**The mass verbs, and why only one of them takes m-of-n.** A griefed claim can
carry up to 96 junk edges (32 out + 64 in), so both verbs come in a per-claim bulk
form: `ApproveAllAssociations` settles every bond incident to a claim in one
transaction, and `DisapproveAllAssociations` burns them.

- **Approve-all is single-signer.** It only ever gives money BACK. A captured
  moderator using it refunds griefers, which costs the court nothing it ever had
  and removes no other remedy.
- **Disapprove-all takes the court's own m**, the same threshold as hide/unhide.
  One edge is one bond a griefer chose to risk; ninety-six at once is most of a
  claim page's contested state, and one careless or captured key should not empty
  it.
- **The bulk burn is bounded to edges that predate its proposal.** Between the
  first signature and the m-th, a stranger may post an honest bond nobody has
  looked at. `assocEdge.at` is compared against the proposal's open height so that
  bond survives — *unjudged means approved* has to hold against a bulk verb too,
  or it is a default rather than a rule. It also closes the mirror attack: a
  griefer who could invalidate the proposal by adding one edge a day would stall
  the remedy forever.

**Both are per CLAIM, not per court**, and that is what makes them bounded. The
griefing is per claim by construction — the caps section below names the inbound
cap itself as the vector — and `maxAssocOut+maxAssocIn` bounds one claim's incident
edges exactly. A per-court sweep would cost O(edges in the docket): a transaction
that gets more expensive as the court succeeds and one day cannot be sent. Court
scope would need a third index holding only bonded edges. That is the design if it
is ever wanted, and it is not free, so it waits for a court that needs it.

The figure is set in **two places**: the realm admin's default
(`SetAssociationBondDefault`, 1 CC at deploy — the `flagMinCC` scale) and a
court's own override (`SetCourtAssociationBond`, active moderators only). A court
field of zero means *unset*, never *free*, so every court that predates the field
inherits the default rather than silently going unpriced — the same sentinel
`Court.desc` uses, and what lets this ship with no migration.

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
deposit, which is the same economics every other flood here faces. **And, since
the association bond, 16 bonds** — none of them refundable, because filling a
claim's inbound slots with junk is precisely what a moderator disapproves. That
is the flood this section could only price in deposits when it was written, and
naming it here is why the bond exists. The
alternative — no inbound cap — moves the damage from "this claim's page is full"
to "this claim's page cannot be served", which is worse and unbounded.

## Removal

- **the edge's author** may remove their own edge, always;
- **an active court moderator** may remove any edge, single-signer, the same
  authority level as filing a folder (additive/reversible acts are 1-of-n here,
  and removing one wrong edge is reversible by re-adding it).

**The target claim's author may NOT remove inbound edges.** That is deliberate
and it is the whole point of the feature: a claim's author deleting the edges
that say "this is contradicted by #12" is exactly the censorship an association
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
