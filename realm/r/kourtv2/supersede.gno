// Supersedes edges: a claim re-filed after the question it asks died unanswered.
// docs/SUPERSEDES.md is the design, the settled authorization rule, and the
// argument against that rule which was kept rather than buried.
//
// WHY THIS IS NOT A SECOND COPY OF association.gno. An argument edge is speech —
// "this claim supports that one" is a view, anybody may add one, and the chain
// checks nothing because there is nothing to check. This is a statement about
// the docket's own history, and the chain holds the evidence: claimState.closed
// is written in exactly one place, only when a claim has no answer and the
// dead-claim timeout has passed. So the predicate is verified rather than taken
// on trust.
//
// AND WHY VERIFYING IT DOES NOT MAKE IT PERMISSIONLESS, which is the part that
// took three reviews to settle. The realm's genuinely permissionless
// entrypoints — CloseDeadClaim, ResolveDispute — have predicates LOGICALLY
// EQUIVALENT to their act: if the guard passes the write is correct whoever
// sent it, so "the verdict is the authority, not the caller". This predicate is
// necessary and not sufficient. It certifies that the pair is ELIGIBLE, not that
// the two claims ask the same question — and since dead claims are produced
// constantly, nearly every one of them is an eligible `to` for any given `from`.
// The caller picks one out of hundreds, and that choice is the whole assertion.

package kourtv2

import (
	"strconv"
	"strings"

	bptree "gno.land/p/nt/bptree/v0"
)

const (
	// maxSupIn bounds the read: a claim page lists who re-filed it.
	maxSupIn = 8
	// THE ANTI-SYBIL TERM, and the audit line it repairs. An earlier draft argued
	// no per-author cap was needed because "the flood is priced by the claim, not
	// the edge" — eight inbound slots costing eight real deposits. That is true
	// only because assertion is author-only, which was the very rule still under
	// question when it was written; and even then one address can fill all eight
	// with eight of its own claims. Argument edges kept a per-author term with an
	// inbound cap eight times looser, for the same reason.
	maxSupInPerAuthor = 2
)

// supEdge is ONE object in TWO indexes, the shape association.gno established. `to`
// is redundant with supBy's key and necessary in supOf's, which is keyed by
// `from` alone because outbound is capped at one.
type supEdge struct {
	to     uint64
	author address
	at     int64 // height, for the record; nothing gates on it
}

// ensureSup allocates the two indexes. WRITE PATHS ONLY — named in
// check-read-purity.py's ALLOCATORS, because a read that allocated would let the
// first caller change what the second one sees, unpaid.
func ensureSup(c *Court) {
	if c.supOf == nil {
		c.supOf = bptree.NewBPTree32()
	}
	if c.supBy == nil {
		c.supBy = bptree.NewBPTree32()
	}
}

// supersedeOrdered reports whether `from` was filed no earlier than the moment
// `to` could first have died.
//
// The wall clock is preferred and the height is the fallback, which is exactly
// how CloseDeadClaim decides the same question about the same claim — a claim
// opened before the clock was running carries openedAtTime 0, and a predicate
// that only knew about stamps would refuse every such claim for ever.
//
// This is also what makes cycles UNREPRESENTABLE rather than refused: every edge
// moves at least twelve weeks forward, so a chain of re-filings cannot close on
// itself and no cycle walk is needed. An edit that weakens this check would take
// that property away silently.
func supersedeOrdered(from, to *claimState) bool {
	if from.openedAtTime != 0 && to.openedAtTime != 0 {
		return from.openedAtTime >= to.openedAtTime+deadClaimSecs
	}
	return from.openedAt >= to.openedAt+deadClaimTimeout
}

// SupersedeClaim records that `from` re-files `to`, which died unanswered.
//
// The author of `from`, or an active court moderator. Narrower than an argument
// edge deliberately: outbound is capped at ONE and removal belongs to the edge's
// author, so under a permissionless rule a stranger could take a claim's only
// outgoing slot with a `to` its author would never have chosen — an assertion
// about what they meant by filing, which they could not remove, permanently
// blocking the true edge, for one storage deposit. AddAssociation has no such
// exposure because its cardinality is 32 and non-exclusive.
func SupersedeClaim(cur realm, courtSlug string, from, to uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	if from == to {
		panic("kourtv2: a claim cannot supersede itself")
	}
	// Both endpoints in THIS court: a cross-court edge would split one object's
	// moderation between two moderator sets, the rule associations took.
	f := mustClaim(c, from)
	t := mustClaim(c, to)

	if f.author != who {
		// ensureMod, NOT `c.mod == nil`. A court's moderation state is allocated
		// lazily and ensureMod seeds the CREATOR as its first member, so a nil
		// c.mod does not mean "this court has no moderators" — it means nobody has
		// moderated yet. Reading it as the former refuses the one person who is
		// certainly a moderator, on exactly the courts where nothing has happened.
		//
		// Membership spelled out so the refusal names both parties who may act.
		cm := ensureMod(c)
		if !cm.members.Has(who.String()) {
			panic("kourtv2: only the re-filing claim's author or a court moderator may record it")
		}
		requireActiveMod(cm, who)
	}
	if !t.closed {
		panic("kourtv2: only a claim that died unanswered can be superseded")
	}
	if !supersedeOrdered(f, t) {
		panic("kourtv2: a re-filing must come after the claim it re-files could have died")
	}

	ensureSup(c)
	if c.supOf.Get(beClaimKey(from)) != nil {
		panic("kourtv2: that claim already re-files one; remove that edge first")
	}

	inN, mine := 0, 0
	p := beClaimKey(to)
	c.supBy.Iterate(p, "", func(key string, v any) bool {
		if !strings.HasPrefix(key, p) {
			return true
		}
		inN++
		if e, ok := v.(*supEdge); ok && e.author == who {
			mine++
		}
		return false
	})
	if inN >= maxSupIn {
		panic("kourtv2: that claim has already been re-filed " + strconv.Itoa(maxSupIn) + " times")
	}
	if mine >= maxSupInPerAuthor {
		panic("kourtv2: you already record " + strconv.Itoa(maxSupInPerAuthor) +
			" re-filings of that claim")
	}

	e := &supEdge{to: to, author: who, at: heightNow()}
	c.supOf.Set(beClaimKey(from), e)
	c.supBy.Set(beClaimKey(to)+beClaimKey(from), e)
}

// RemoveSupersede withdraws the edge `from` asserts. Its author, or an active
// moderator — the composite RemoveAssociation uses, and reversible by re-adding,
// which is why it is single-signer.
func RemoveSupersede(cur realm, courtSlug string, from uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	if c.supOf == nil {
		panic("kourtv2: that claim re-files nothing")
	}
	v := c.supOf.Get(beClaimKey(from))
	if v == nil {
		panic("kourtv2: that claim re-files nothing")
	}
	e := v.(*supEdge)
	requireEdgeRemover(c, e.author, who)
	// BOTH indexes, or the edge survives in one direction and the two reads
	// disagree about whether it exists.
	c.supOf.Remove(beClaimKey(from))
	c.supBy.Remove(beClaimKey(e.to) + beClaimKey(from))
}

// ClaimSupersedes is every re-filing edge touching one claim, packed:
//
//	of:<id>;by:<id>,<id>
//
// `of` is the one claim this one re-files (empty if none); `by` is every claim
// that re-files THIS one. Both halves always present, either may be empty
// ("of:;by:"). Nine rows at worst, against ClaimAssociations' ninety-six.
//
// Reads nil trees as empty and never allocates: a court that has never carried
// an edge answers without the query creating anything.
func ClaimSupersedes(courtSlug string, claimID uint64) string {
	c := mustCourt(courtSlug)
	mustClaim(c, claimID)
	var b strings.Builder
	b.WriteString("of:")
	if c.supOf != nil {
		if v := c.supOf.Get(beClaimKey(claimID)); v != nil {
			e := v.(*supEdge)
			// The same gate the titles take: an edge pointing at a purged or
			// globally-redacted claim is not returned, or the read would put a
			// withheld claim's id back on another claim's page.
			if !assocTextGone(c, e.to) {
				b.WriteString(strconv.FormatUint(e.to, 10))
			}
		}
	}
	b.WriteString(";by:")
	if c.supBy != nil {
		p := beClaimKey(claimID)
		n := 0
		c.supBy.Iterate(p, "", func(key string, v any) bool {
			if !strings.HasPrefix(key, p) {
				return true
			}
			other := claimIDFromKey(key[8:])
			if assocTextGone(c, other) {
				return false
			}
			if n > 0 {
				b.WriteString(",")
			}
			b.WriteString(strconv.FormatUint(other, 10))
			n++
			return false
		})
	}
	return b.String()
}
