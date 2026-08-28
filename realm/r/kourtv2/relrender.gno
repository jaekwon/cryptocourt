// A claim's relations to other claims, which rendered nowhere.
//
// THE FOURTH INSTANCE OF ONE PATTERN, after the comment board (a working route
// nothing linked to), the filing tree (seven verbs, no page) and the ballot
// (fourteen entrypoints, no page). association.gno and supersede.gno export
// about fifteen entrypoints between them — add, remove, approve, disapprove,
// claim the bond, the batch verbs, and the two packed reads — and no
// human-facing page drew a single edge. The overlay renders them; gnoweb did
// not, so the two surfaces disagreed about what a claim even is.
//
// AND SUPERSEDES IS THE ONE THAT COSTS SOMETHING. An argument edge is a view
// somebody holds. A supersede edge is a statement about the docket's own
// history, verified by the chain: it says this claim's question died unanswered
// and was re-filed as another. A reader sitting on a superseded claim, with coin
// staked on it, had no way to learn that the live version of their question is
// somewhere else. That is not a missing feature, it is a reader left on a page
// the docket has moved past.

package kourtv2

import (
	"strconv"
	"strings"
)

// writeRelations draws the supersede edges and the argument edges for one claim.
//
// Both halves are gated the way the packed reads gate them — assocTextGone
// keeps a purged or globally-redacted claim's id off another claim's page — so
// this renders exactly the set the qeval reads would return, and no more. A
// render that showed an edge the read withholds would put a withheld claim back
// in front of a reader by a side door.
func writeRelations(b *strings.Builder, c *Court, claimID uint64) {
	base := "/r/kourt/kourtv2:" + c.id + "/"
	sup := writeSupersedes(b, c, claimID, base)
	arg := writeArguments(b, c, claimID, base)
	if sup || arg {
		b.WriteString("\n")
	}
}

// writeSupersedes is "this claim re-files that one" and "these re-file this
// one", in that order.
//
// THE INCOMING EDGE IS THE URGENT ONE and it goes FIRST, before the claim's own
// signal, because it changes what the page below it is worth reading. Everything
// else about relations is context; this is a redirection.
func writeSupersedes(b *strings.Builder, c *Court, claimID uint64, base string) bool {
	wrote := false
	if c.supBy != nil {
		p := beClaimKey(claimID)
		n := 0
		c.supBy.Iterate(p, "", func(key string, v any) bool {
			if !strings.HasPrefix(key, p) {
				return true
			}
			from := claimIDFromKey(key[len(p):])
			if from == 0 || from > c.nextID || assocTextGone(c, from) {
				return false
			}
			if n == 0 {
				b.WriteString("> **This question was asked again.** It died here " +
					"without an answer and was re-filed as:\n")
			}
			n++
			cs := mustClaim(c, from)
			b.WriteString(">\n> - [" + claimTitleFor(c, cs) + "](" + base +
				strconv.FormatUint(from, 10) + ") — " + claimStatus(cs) + "\n")
			return n >= renderPageSize
		})
		if n > 0 {
			b.WriteString("\n")
			wrote = true
		}
	}
	if c.supOf != nil {
		if v := c.supOf.Get(beClaimKey(claimID)); v != nil {
			e := v.(*supEdge)
			if e.to != 0 && e.to <= c.nextID && !assocTextGone(c, e.to) {
				cs := mustClaim(c, e.to)
				b.WriteString("_Re-files [" + claimTitleFor(c, cs) + "](" + base +
					strconv.FormatUint(e.to, 10) + "), which died unanswered._\n\n")
				wrote = true
			}
		}
	}
	return wrote
}

// writeArguments is the support/contest graph.
//
// NAMED FOR WHAT IT IS, not for the field. "association" is the code's word and
// says nothing; the page says a claim supports or contests another. And the
// direction is spelled out both ways, because "out" and "in" are meaningless to
// a reader: an edge this claim asserts is not the same fact as an edge somebody
// else pointed at it, and conflating them would let anyone put words in a
// claim's mouth.
//
// THE PAGE SAYS THESE ARE OPINIONS. Anyone may add one and the chain checks
// nothing — association.gno's own header says an argument edge is speech — so a
// reader who took this list for an adjudicated finding would be reading a
// stranger's claim as the court's.
func writeArguments(b *strings.Builder, c *Court, claimID uint64, base string) bool {
	var out, in strings.Builder
	nOut := writeEdgeSide(&out, c, claimID, base, true)
	nIn := writeEdgeSide(&in, c, claimID, base, false)
	if nOut+nIn == 0 {
		return false
	}
	b.WriteString("## Related claims\n\n")
	b.WriteString("_Anyone may draw these links, and the court does not rule on " +
		"them — they are what readers have asserted, not findings._\n\n")
	if nOut > 0 {
		b.WriteString("This claim says:\n\n")
		b.WriteString(out.String() + "\n")
	}
	if nIn > 0 {
		b.WriteString("Others say about this claim:\n\n")
		b.WriteString(in.String() + "\n")
	}
	return true
}

// writeEdgeSide walks one direction of the argument graph.
func writeEdgeSide(b *strings.Builder, c *Court, claimID uint64, base string, outgoing bool) int {
	t := c.assocIn
	if outgoing {
		t = c.assocOut
	}
	if t == nil {
		return 0
	}
	p := beClaimKey(claimID)
	n := 0
	t.Iterate(p, "", func(key string, v any) bool {
		if !strings.HasPrefix(key, p) {
			return true
		}
		e, ok := v.(*assocEdge)
		if !ok {
			return false
		}
		other := claimIDFromKey(key[len(p):])
		if other == 0 || other > c.nextID || assocTextGone(c, other) {
			return false
		}
		verb := "supports"
		if e.stance == assocContests {
			verb = "contests"
		}
		if !outgoing {
			verb += " it"
		}
		n++
		cs := mustClaim(c, other)
		b.WriteString("- " + verb + " [" + claimTitleFor(c, cs) + "](" + base +
			strconv.FormatUint(other, 10) + ")\n")
		return n >= renderPageSize
	})
	return n
}
