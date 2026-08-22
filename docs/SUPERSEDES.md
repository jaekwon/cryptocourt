# `supersedes` — the spec entry it was punted for

**Status: designed and audited, NOT implemented. One decision is the owner's; it
is named at the bottom.**

`docs/ARGUMENT_EDGES.md` shipped argument edges and punted this one, for a reason
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

§5's argument edge is speech. "This claim supports that one" is a view, any
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
| both claims exist in **this** court | a cross-court edge splits one object's moderation between two moderator sets — same rule argument edges took |
| `from != to` | — |
| `to.closed` | it died unanswered. A claim with an answer settles; nothing re-files it |
| `from.openedAtTime >= to.openedAtTime + deadClaimSecs` | `from` was filed no earlier than the moment `to` could first have died. This is derivable and needs no new field |
| `from` has no outgoing edge yet | a re-filing re-files one question |
| `to` holds fewer than 8 inbound | bounds the read |

**Cycles are unrepresentable, not refused.** Every edge strictly increases
`openedAtTime` by at least twelve weeks, so a chain can only run forward in time
and `13 → 11 → 1` (the covid fixture's shape) cannot close on itself. This is
worth stating because the folder code pays for a cycle walk and argument edges
reason about one; here the arithmetic does it for free, and a future edit that
weakens the time check would silently take that away.

## Shape

Two trees on the court, the pattern `argOut`/`argIn` already established:

```
supOf : beClaimKey(from)                  -> to        (at most one, by the cap)
supBy : beClaimKey(to) + beClaimKey(from) -> struct{}  (prefix scan: who re-filed this)
```

Both nil until the first edge; every read tests nil rather than calling an
`ensure*` helper, which `check-read-purity.py` requires and which keeps a query
from being unpaid state growth.

Read: `ClaimSupersedes(courtSlug, id) string` → `of:<id>;by:<id>,<id>` with
either half possibly empty, the same packed shape `ClaimArguments` returns.

## Who may add, and what it costs

The author of `from`, or an active court moderator.

That is narrower than the argument edge's "anybody", and deliberately: an
argument edge is a stranger's counter-evidence and pricing it would defeat the
point, whereas "my claim re-files that one" is a statement about one's own
filing. A moderator may also record it, because a docket's curator noticing that
two claims are the same question is the ordinary case.

**The flood is priced by the claim, not by the edge.** Filling one dead claim's
eight inbound slots takes eight real claims, each carrying its own deposit —
orders of magnitude above the storage deposit an edge costs. No per-author cap is
needed here, unlike `maxArgInPerAuthor`, because the expensive thing is already
required.

Removal: the edge's author, or an active moderator, single-signer — the same
authority argument edges use for the same reason (reversible by re-adding).

## Moderation

An edge carries no text of its own, so there is no new escaping surface. What the
gate must still do is what `argTextGone` already does: an edge to or from a
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
at 8. `ClaimSupersedes` is nine rows at worst, against `ClaimArguments`' 96.

**Storage growth.** Two claim ids per edge, and an edge cannot exist without a
claim that paid a deposit to exist.

**Gas.** One `Get` for the outgoing cap, one bounded prefix scan for the inbound
cap, two `Set`s. No walk over the chain, because the time predicate removes the
reason to have one.

**Spam without a price.** Priced by the claim deposit, above.

**Moderation gaps.** Covered by the same purge gate as argument edges; moderators
may remove any edge.

**Migration for already-deployed courts.** None. Two new nilable fields read as
nil, every read returns empty, the first write creates them — the shape `c.mod`
and the argument trees already use.

## The one decision that is not mine

Everything above follows from what the repo already says. This does not:

**Should a re-filing be sayable by a third party at all?** The design above says
the author of `from` or a moderator. The alternative is the argument edge's rule
— anybody, at any time — on the grounds that "these two claims are the same
question" is an observation, not a confession, and that the time-and-death
predicate already stops it being abused.

I recommend author-or-moderator, because an unverifiable *intent* ("this was
filed AS a re-filing") is the one part of the assertion the chain cannot check,
and the author is the only party who knows it. But it is a policy call about what
the docket is for, the entrypoint is easy to add and hard to take back, and it is
exactly the kind of call the original punt was protecting.
