// Argument edges: claims that bear on other claims (COURTS_STRUCTURE.md §5, and
// docs/ARGUMENT_EDGES.md for this design and what it deliberately leaves out).
//
// §5's table is the whole specification and it is short: an argument edge has a
// stance (supports / counters), any number may exist, ANYBODY may add one at any
// time, and it does nothing mechanical. That last line is load-bearing —
//
//	"a settled supporting claim does not move its parent's odds, does not lower
//	 a bar, does not force a verdict... Views may aggregate; the chain does not
//	 infer."
//
// — so no money path reads any of this. It is render-layer state, the same
// posture stakeseries.gno takes about itself.
//
// NOT IMPLEMENTED HERE, and both are findings rather than omissions. The overlay
// draws three edge kinds and says they match §5; two of them do not.
// CONTAINMENT (`part-of`) is §5's other edge, but its own guards say "only
// sections may be containment parents" and §6 defers sections — so claim→claim
// containment is the shape §5 forbids, and flat folders are the containment this
// realm actually chose. SUPERSEDES is in no spec at all; it means "a re-filing
// after a claim died unanswered", which this docket produces constantly, and it
// deserves a spec entry before an entrypoint.
package kourtv2

import (
	"strconv"
	"strings"

	bptree "gno.land/p/nt/bptree/v0"
)

const (
	argSupports  = int8(0)
	argContests  = int8(1)
	// THE CAPS BOUND A READ, not a writer's enthusiasm. A claim page lists every
	// incident edge, so without a cap its render grows with whatever an attacker
	// is willing to pay to write — the failure seriesRowCap exists to prevent
	// elsewhere in this realm.
	maxArgOut = 32
	maxArgIn  = 64
	// The anti-sybil term, and the reason the inbound cap is not itself a free
	// griefing vector: filling one claim's 64 inbound slots takes 16 distinct
	// addresses, each paying its own storage deposit. That is the same price
	// every other flood surface here pays.
	maxArgInPerAuthor = 4
)

// argEdge is ONE object held in TWO indexes. argOut and argIn store the same
// pointer, so a stance cannot desync from itself and removal has to clear both
// or the edge survives in one direction — which is what the removal test pins.
type argEdge struct {
	stance int8
	author address
	at     int64 // height, for the record; nothing gates on it
}

// ensureArgs allocates the two indexes. WRITE PATHS ONLY — it is named in
// check-read-purity.py's ALLOCATORS for that reason. A read that reached for it
// would let the first caller change what the second one sees, and a query
// carries no storage deposit, so it would be unpaid state growth.
func ensureArgs(c *Court) {
	if c.argOut == nil {
		c.argOut = bptree.NewBPTree32()
	}
	if c.argIn == nil {
		c.argIn = bptree.NewBPTree32()
	}
}

// argKey is the 16-byte composite both indexes use, so "every edge incident to
// claim X" is one prefix scan rather than a walk of the whole tree.
func argKey(a, b uint64) string { return beClaimKey(a) + beClaimKey(b) }

// argTextGone reports whether a claim's text is withheld — a purged or globally
// redacted claim. An edge pointing at one is not returned, for the same reason
// its title is not.
func argTextGone(c *Court, id uint64) bool {
	if c.mod == nil {
		return false
	}
	clm := lookupClaimMod(c.mod, id)
	return clm != nil && (clm.purged || clm.global)
}

// AddArgument records that claim `from` bears on claim `to`, with a stance.
// ANYBODY, at any time (§5) — the write's own storage deposit is the price, and
// a bond on speech-shaped state would price out the counter-evidence this exists
// to carry.
func AddArgument(cur realm, courtSlug string, from, to uint64, stance string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	if from == to {
		panic("kourtv2: a claim cannot bear on itself")
	}
	var st int8
	switch stance {
	case "supports":
		st = argSupports
	case "contests":
		st = argContests
	default:
		panic("kourtv2: a stance is \"supports\" or \"contests\"")
	}
	// Both endpoints must exist IN THIS COURT. Cross-court edges would put a
	// second court's id in the key and split one object's moderation authority
	// between two moderator sets.
	mustClaim(c, from)
	mustClaim(c, to)

	ensureArgs(c)
	k := argKey(from, to)
	if c.argOut.Get(k) != nil {
		panic("kourtv2: that edge already exists; remove it to change its stance")
	}

	// One scan answers all three caps: how many this claim already asserts, how
	// many are already asserted about the target, and how many of those are this
	// author's.
	outN := 0
	c.argOut.Iterate(beClaimKey(from), "", func(key string, _ any) bool {
		if !strings.HasPrefix(key, beClaimKey(from)) {
			return true
		}
		outN++
		return outN > maxArgOut
	})
	if outN >= maxArgOut {
		panic("kourtv2: this claim already asserts " + strconv.Itoa(maxArgOut) + " argument edges")
	}
	inN, mine := 0, 0
	c.argIn.Iterate(beClaimKey(to), "", func(key string, v any) bool {
		if !strings.HasPrefix(key, beClaimKey(to)) {
			return true
		}
		inN++
		if e, ok := v.(*argEdge); ok && e.author == who {
			mine++
		}
		return false
	})
	if inN >= maxArgIn {
		panic("kourtv2: that claim already carries " + strconv.Itoa(maxArgIn) + " argument edges")
	}
	if mine >= maxArgInPerAuthor {
		panic("kourtv2: you already hold " + strconv.Itoa(maxArgInPerAuthor) +
			" argument edges on that claim")
	}

	e := &argEdge{stance: st, author: who, at: heightNow()}
	c.argOut.Set(k, e)
	c.argIn.Set(argKey(to, from), e)
}

// RemoveArgument withdraws an edge. The edge's OWN AUTHOR, always; an active
// court moderator, always. Not the target claim's author — a claim's author
// deleting the edges that say "this is contested by #12" is exactly the
// censorship an argument graph exists to resist, and it is the one removal rule
// worth being unable to bend.
func RemoveArgument(cur realm, courtSlug string, from, to uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	if c.argOut == nil {
		panic("kourtv2: no such argument edge")
	}
	v := c.argOut.Get(argKey(from, to))
	if v == nil {
		panic("kourtv2: no such argument edge")
	}
	e := v.(*argEdge)
	if e.author != who {
		if c.mod == nil {
			panic("kourtv2: only the edge's author or a court moderator may remove it")
		}
		requireActiveMod(c.mod, who)
	}
	// BOTH indexes, or the edge survives in one direction and the two reads
	// disagree about whether it exists.
	c.argOut.Remove(argKey(from, to))
	c.argIn.Remove(argKey(to, from))
}

// ClaimArguments is every edge incident to one claim, packed:
//
//	out:<to>:<s|c>,<to>:<s|c>;in:<from>:<s|c>,...
//
// Both halves are always present and either may be empty ("out:;in:"). Packed
// rather than returned as a struct for the same reason ClaimSeries is: one read,
// one round trip, and a shape the overlay already knows how to parse.
//
// Bounded by construction — maxArgOut + maxArgIn rows, whatever anybody writes.
// Reads nil trees as empty and never allocates: a court that has never carried an
// edge answers "out:;in:" without the query creating anything.
func ClaimArguments(courtSlug string, claimID uint64) string {
	c := mustCourt(courtSlug)
	mustClaim(c, claimID)
	var b strings.Builder
	b.WriteString("out:")
	if c.argOut != nil {
		p := beClaimKey(claimID)
		n := 0
		c.argOut.Iterate(p, "", func(key string, v any) bool {
			if !strings.HasPrefix(key, p) {
				return true
			}
			e := v.(*argEdge)
			other := claimIDFromKey(key[8:])
			if argTextGone(c, other) {
				return false
			}
			if n > 0 {
				b.WriteString(",")
			}
			b.WriteString(strconv.FormatUint(other, 10) + ":" + stanceCode(e.stance))
			n++
			return false
		})
	}
	b.WriteString(";in:")
	if c.argIn != nil {
		p := beClaimKey(claimID)
		n := 0
		c.argIn.Iterate(p, "", func(key string, v any) bool {
			if !strings.HasPrefix(key, p) {
				return true
			}
			e := v.(*argEdge)
			other := claimIDFromKey(key[8:])
			if argTextGone(c, other) {
				return false
			}
			if n > 0 {
				b.WriteString(",")
			}
			b.WriteString(strconv.FormatUint(other, 10) + ":" + stanceCode(e.stance))
			n++
			return false
		})
	}
	return b.String()
}

func stanceCode(s int8) string {
	if s == argContests {
		return "c"
	}
	return "s"
}

// claimIDFromKey is beClaimKey's inverse, for reading the other endpoint back
// out of a composite key.
func claimIDFromKey(k string) uint64 {
	if len(k) < 8 {
		return 0
	}
	var id uint64
	for i := 0; i < 8; i++ {
		id = id<<8 | uint64(k[i])
	}
	return id
}
