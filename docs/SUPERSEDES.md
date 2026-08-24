# `supersedes` — the spec entry it was punted for

**Status: designed, audited, and settled. NOT implemented.** The one open
question — who may assert a re-filing — was taken to three independent reviews
and converged; see the last section.

`docs/ASSOCIATIONS.md` shipped associations and punted this one, for a reason
that still stands as far as it goes:

> **`supersedes` is real but unspecified.** It means "a re-filing after a claim
> died unanswered", which this docket produces constantly — `deadClaimSecs` is
> twelve weeks, so a live question outlives its contract and gets re-put. The
> covid fixture uses it three times. It deserves a spec entry before it gets an
> entrypoint.

This is that entry. Writing it turned up the thing that makes `supersedes`
different in kind from the edge that shipped beside it, and the whole design
falls out of that difference.

## It is not an opinion, and that changes everything

§5's argument edge — this realm's association — is speech. "This claim supports that one" is a view, any
number may exist, **anybody may add one at any time**, and the chain checks
nothing because there is nothing to check.

`supersedes` is a statement about the docket's own history:

> claim X re-files claim Y, which died unanswered

and every part of that is **on chain already**. `claimState.closed` is set in
exactly one place, and only when the claim has no answer (`frozenAt == 0`, "this
claim has an answer; it settles, it does not die") and the dead-claim timeout has
passed. So `to.closed` is not a label somebody applied; it is the realm's own
record that this question died without a decision.

An edge whose predicate the chain can verify should be verified. Otherwise the
realm stores an assertion it is in a position to have refuted, which is the worst
of both — the weight of chain state with the reliability of a comment.

## The predicate

`SupersedeClaim(cur realm, courtSlug string, from, to uint64)` records that
`from` re-files `to`, and refuses unless all of:

| check | why |
|---|---|
| both claims exist in **this** court | a cross-court edge splits one object's moderation between two moderator sets — same rule associations took |
| `from != to` | — |
| `to.closed` | it died unanswered. A claim with an answer settles; nothing re-files it |
| `from.openedAtTime >= to.openedAtTime + deadClaimSecs` | `from` was filed no earlier than the moment `to` could first have died. This is derivable and needs no new field |
| `from` has no outgoing edge yet | a re-filing re-files one question |
| `to` holds fewer than 8 inbound | bounds the read |
| `to` holds fewer than 2 inbound **from this author** | the anti-sybil term; see the last section for why the claim deposit alone is not the price it looks like |

**Cycles are unrepresentable, not refused.** Every edge strictly increases
`openedAtTime` by at least twelve weeks, so a chain can only run forward in time
and `13 → 11 → 1` (the covid fixture's shape) cannot close on itself. This is
worth stating because the folder code pays for a cycle walk and associations
reason about one; here the arithmetic does it for free, and a future edit that
weakens the time check would silently take that away.

## Shape

Two trees on the court, the pattern `assocOut`/`assocIn` already established:

```
supOf : beClaimKey(from)                  -> to        (at most one, by the cap)
supBy : beClaimKey(to) + beClaimKey(from) -> struct{}  (prefix scan: who re-filed this)
```

Both nil until the first edge; every read tests nil rather than calling an
`ensure*` helper, which `check-read-purity.py` requires and which keeps a query
from being unpaid state growth.

Read: `ClaimSupersedes(courtSlug, id) string` → `of:<id>;by:<id>,<id>` with
either half possibly empty, the same packed shape `ClaimAssociations` returns.

## Who may add, and what it costs

The author of `from`, or an active court moderator — settled in the last section,
which is also where the reasoning lives.

**The flood is priced by the claim AND by a per-author term.** Because only
`from`'s author may assert, filling one dead claim's eight inbound slots takes
eight real claims, each carrying its own deposit — orders of magnitude above an
edge's storage deposit. An earlier draft of this document stopped there and
concluded that no `maxAssocInPerAuthor` analogue was needed. That was wrong twice
over: it is true only under author-only assertion (so it was an argument FOR the
rule, quietly assumed while the rule was still undecided), and even then one
address can fill all eight slots with eight of its own claims. Hence the
per-author cap of 2 in the predicate above.

Removal: the edge's author, or an active moderator, single-signer — the same
authority associations use for the same reason (reversible by re-adding).

## Moderation

An edge carries no text of its own, so there is no new escaping surface. What the
gate must still do is what `assocTextGone` already does: an edge to or from a
purged or globally-redacted claim is not returned, for the same reason that
claim's title is not.

## Nothing mechanical

§5 binds here even though §5 does not name this edge: "a settled supporting claim
does not move its parent's odds, does not lower a bar, does not force a
verdict... Views may aggregate; the chain does not infer." A superseding claim
does not inherit its predecessor's stake, positions, reputation or deadline. It
is a new claim that happens to ask the old question again, and it is decided
alone. No money path reads this.

## Audit

**Unbounded read cost.** No. Outgoing is one by construction; inbound is capped
at 8. `ClaimSupersedes` is nine rows at worst, against `ClaimAssociations`' 96.

**Storage growth.** Two claim ids per edge, and an edge cannot exist without a
claim that paid a deposit to exist.

**Gas.** One `Get` for the outgoing cap, one bounded prefix scan for the inbound
cap, two `Set`s. No walk over the chain, because the time predicate removes the
reason to have one.

**Spam without a price.** Priced by the claim deposit and bounded by the
per-author inbound cap, above. The deposit alone was not enough, and the draft
that said it was had assumed the authorization rule it was meant to be arguing
for.

**Moderation gaps.** Covered by the same purge gate as associations; moderators
may remove any edge.

**Migration for already-deployed courts.** None. Two new nilable fields read as
nil, every read returns empty, the first write creates them — the shape `c.mod`
and the association trees already use.

## Who may assert it — settled, and not for the reason first given

**The author of `from`, or an active court moderator.** Single-signer, the
composite `RemoveAssociation` already uses.

Three independent reviews were run on this question, one arguing from the
docket's purpose, one from attack surface, one from the repo's own authority
tiers. Two recommended author-or-moderator outright. The third recommended
"anybody" — and then attached an amendment ("the author of `from` outranks a
stranger on `from`'s single outgoing slot") which is author-or-moderator with a
round of griefing in front of it. So the convergence is (a), and the reasons that
carried it are better than the one this document opened with.

**The predicate is necessary, not sufficient.** `to.closed` plus the twelve-week
gap certifies that the PAIR IS ELIGIBLE. It does not certify that the two claims
ask the same question — and since `deadClaimSecs` is twelve weeks and this docket
produces dead claims constantly, nearly every dead claim in a court qualifies as
a `to` for any given `from`. The chain says what is allowed; the caller says
WHICH, out of hundreds, and that choice is the entire content of the assertion.
Compare the realm's genuinely permissionless entrypoints — `CloseDeadClaim`,
`ResolveDispute`, `SettleUndisputed`. Their predicates are logically equivalent
to the act, so the caller contributes nothing and "the verdict is the authority,
not the caller" holds. Here the caller contributes the whole judgment.

**Cardinality one is what makes it different from an association.** Outbound is
capped at one, and removal belongs to the edge's author. Compose those with
"anybody" and a stranger consumes my claim's only outgoing slot with a `to` I
would never have chosen — an assertion about what I meant by filing, which I
cannot remove, which permanently blocks the true edge, bought for one storage
deposit. `AddAssociation` has no such exposure, and not because it is better
guarded: its openness is safe BECAUSE its cardinality is thirty-two and
non-exclusive. Exclusive, author-attributable, per-claim state is the shape
`EditClaimTitle` guards, and it guards it author-only.

**And the spam pricing above is only true under (a).** "Filling one dead claim's
eight inbound slots takes eight real claims, each carrying its own deposit" holds
only if the asserter must have authored them. Let anybody assert, and an attacker
points eight OTHER PEOPLE's existing claims at one dead claim for eight storage
deposits — collapsing the price by orders of magnitude and forcing a
`maxAssocInPerAuthor` analogue back in, which would make this a second copy of the
association, the exact outcome `association.gno` says the separate design exists
to avoid.

### One amendment, adopted

**A per-author inbound cap of 2 of the 8.** Under (a) a single address can still
fill all eight slots with eight of its own claims. Associations kept a
per-author term with an inbound cap eight times looser, and the reason given
there applies here unchanged. It costs one counter in a scan the write already
does, and it guarantees at least four distinct re-filers stay representable.

### The strongest argument against, kept rather than buried

**(a)'s privilege is forward-only, and it decays.** The edge a reader most needs
is the oldest one — "this 2020 claim was re-put in 2023" — and under (a) its only
authorized asserter is the author of the 2023 claim, who may themselves be dead,
refunded and gone. The chain of re-filings breaks at its oldest link, exactly
where the record is most useful, and the only remedy is a moderator: which puts
the completeness of the record in the hands of the court's curators.

There is a second, sharper form of it. **`CloseDeadClaim` is permissionless.**
The `to.closed` bit this entire predicate rests on is written by whoever bothers
to send the transaction. Requiring authorship for the derived statement, having
not required it for the primitive it derives from, is a real inconsistency and
should be admitted as one.

Both are true. They are outweighed because the failure modes are not symmetric: a
missing edge is a false negative that either of two parties can fix at any later
time, while a squatted slot is a false positive the subject cannot fix at all,
which also blocks the true edge, bought for a rounding error. An incomplete graph
is a better thing to own than adverse possession of somebody else's filing.
