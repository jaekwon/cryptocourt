// Associations: claims that bear on other claims (COURTS_STRUCTURE.md §5, and
// docs/ASSOCIATIONS.md for this design and what it deliberately leaves out).
//
// ONE THING, TWO NAMES, and this is the only place that has to say so. §5 calls
// it an ARGUMENT edge, and every quotation of §5 in this tree keeps that word,
// because a citation that paraphrases is not a citation. The code calls it an
// ASSOCIATION: "argument" is already the word for a function's parameters, and a
// file with both meanings in it is a file where `TestOrderFoldersBoundsIts-
// Argument` reads like it is about this feature. So: §5's argument edge is this
// realm's association, in the same way §5's "counters" is this realm's
// `assocContests`.
//
// §5's table is the whole specification and it is short: an association has a
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
// realm actually chose. SUPERSEDES has no §5 entry; it means "a re-filing after a
// claim died unanswered", which this docket produces constantly. It is designed
// in docs/SUPERSEDES.md and deliberately not built here, because it is not the
// same kind of thing: an association is an opinion and this is a checkable fact
// about the docket (`claimState.closed` is the realm's own record that a claim
// died without an answer), so it wants a verifying entrypoint rather than a
// second copy of this one.

package kourtv2

import (
	"strconv"
	"strings"

	bptree "gno.land/p/nt/bptree/v0"
)

const (
	assocSupports = int8(0)
	assocContests = int8(1)
	// THE CAPS BOUND A READ, not a writer's enthusiasm. A claim page lists every
	// incident edge, so without a cap its render grows with whatever an attacker
	// is willing to pay to write — the failure seriesRowCap exists to prevent
	// elsewhere in this realm.
	maxAssocOut = 32
	maxAssocIn  = 64
	// The anti-sybil term, and the reason the inbound cap is not itself a free
	// griefing vector: filling one claim's 64 inbound slots takes 16 distinct
	// addresses, each paying its own storage deposit. That is the same price
	// every other flood surface here pays.
	maxAssocInPerAuthor = 4
)

// ---- the association bond ------------------------------------------------
//
// WHY A BOND, AND ONLY FOR STRANGERS. COURTS_STRUCTURE.md §5 opens this edge to
// "anybody, any time, no mechanical effect", and the note above says why that is
// not already a free griefing vector: filling one claim's inbound slots takes
// sixteen addresses, each paying its own storage deposit. The judgement here is
// that a storage deposit is too cheap to deter somebody who WANTS those slots
// full, and too blunt to tell a stranger's counter-evidence from a flood.
//
// THE REFUND IS THE POINT, and it is what keeps this on the right side of §5. A
// bond that is never returned is a price on speech — exactly what "no mechanical
// effect" was protecting, and what AddAssociation's own note calls pricing out the
// counter-evidence this edge exists to carry. A bond returned once a moderator
// agrees the edge was worth attaching costs an honest contributor nothing but
// the wait, and costs a griefer everything.
//
// Nobody accountable pays it: the asserting claim's own author has already put a
// deposited claim behind their name, and a moderator is answerable by election.
//
// TWO PLACES, deliberately. The realm admin sets the default so a new court is
// never unpriced; a court's own moderators may override it, because a small
// trusted docket should not need a realm upgrade to make association free, and a
// court under attack should not have to wait for one to make it dear.
const assocBondDefaultInit = int64(1_000_000) // 1 CC, the flagMinCC scale

var assocBondDefault = assocBondDefaultInit

// assocBondFor resolves the two places: this court's override, else the realm
// default. Court.assocBond says why zero there means unset rather than free.
func assocBondFor(c *Court) int64 {
	if c.assocBond > 0 {
		return c.assocBond
	}
	return assocBondDefault
}

// SetAssociationBondDefault sets the realm-wide default every court inherits.
func SetAssociationBondDefault(cur realm, amount int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("kourtv2: only the global DAO admin sets the default association bond")
	}
	if amount < 0 {
		panic("kourtv2: an association bond cannot be negative")
	}
	assocBondDefault = amount
}

// SetCourtAssociationBond overrides the default for one court; 0 clears the
// override and returns the court to the realm default.
func SetCourtAssociationBond(cur realm, courtSlug string, amount int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	// An ACTIVE moderator: repricing association is not one of the de-escalatory
	// acts a suspended set may still take.
	requireActiveMod(ensureMod(c), who)
	if amount < 0 {
		panic("kourtv2: an association bond cannot be negative")
	}
	c.assocBond = amount
}

// AssociationBond is what a stranger must post to attach an edge in this court.
func AssociationBond(courtSlug string) int64 { return assocBondFor(mustCourt(courtSlug)) }

// AssociationBondDefault is the realm-wide default, for a page that wants to say
// which of the two places a court's figure came from.
func AssociationBondDefault() int64 { return assocBondDefault }

// assocBondWindowSecs is how long a bond waits on a moderator before its author
// may take it back.
//
// UNJUDGED MEANS APPROVED, and the direction is the whole design. The other way
// round — burn what nobody judged — makes moderator inactivity a confiscation
// engine, and a court with one absent moderator would quietly keep every
// stranger's CC. Two weeks is long enough for a moderator who is paying any
// attention and short enough that an honest contributor is not out of pocket for
// a quarter waiting on one who is not.
const assocBondWindowSecs = int64(14 * 86400)

// mustAssocEdge is the lookup every association verb starts with. Both the nil
// tree and the missing key answer the caller the same way, because the
// difference between "this court has no edges" and "this pair has none" is not
// a distinction the caller can act on.
func mustAssocEdge(c *Court, from, to uint64) *assocEdge {
	if c.assocOut == nil {
		panic("kourtv2: no such association")
	}
	v := c.assocOut.Get(assocKey(from, to))
	if v == nil {
		panic("kourtv2: no such association")
	}
	return v.(*assocEdge)
}

// dropAssocEdge clears BOTH indexes, or the edge survives in one direction and the
// two reads disagree about whether it exists.
func dropAssocEdge(c *Court, from, to uint64) {
	c.assocOut.Remove(assocKey(from, to))
	c.assocIn.Remove(assocKey(to, from))
}

// burnAssocBond destroys a held bond and zeroes it, so nothing can be burned
// twice. The exact mirror of releaseAssocBond, and deliberately shaped like it:
// both move the money and neither touches the edge.
//
// THREE CALLERS AND IT DOES NOT DROP THE EDGE, because they disagree about
// dropping and only about that: DisapproveAssociation and the bulk burn drop as
// part of the judgement, while RemoveAssociation drops every edge it is given,
// bonded or not, so a drop in here would be a second one. Writing the burn out
// three times was the first shape, and check-mutation-anchors refused it — two
// corpus rows had become ambiguous across the copies. That is the guard doing
// its job: a second spelling of one rule is how one copy comes to forget to
// zero the field, and an unzeroed bond can be burned again.
func burnAssocBond(c *Court, e *assocEdge) {
	amt := e.bond
	e.bond = 0
	c.coin.Burn(c.escrow, amt)
}

// releaseAssocBond returns a held bond to the edge's author and zeroes it, so
// nothing can be released twice.
func releaseAssocBond(c *Court, e *assocEdge) {
	if e.bond <= 0 {
		return
	}
	amt := e.bond
	e.bond = 0
	c.coin.Transfer(c.escrow, e.author, amt)
}

// ApproveAssociation returns a stranger's bond: a moderator has judged the edge
// worth carrying. The edge stays either way — approval is about the money, not
// about the assertion, which anybody may make (§5).
func ApproveAssociation(cur realm, courtSlug string, from, to uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	requireActiveMod(ensureMod(c), who)
	e := mustAssocEdge(c, from, to)
	if e.bond <= 0 {
		panic("kourtv2: no bond is held on that edge")
	}
	releaseAssocBond(c, e)
}

// DisapproveAssociation burns the bond and drops the edge.
//
// SINGLE-SIGNER, matching removal: a moderator can already delete any edge
// outright, so the judgement this adds is over money the griefer chose to put at
// risk, not over the record. The MASS form is the one that takes m-of-n.
func DisapproveAssociation(cur realm, courtSlug string, from, to uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	requireActiveMod(ensureMod(c), who)
	e := mustAssocEdge(c, from, to)
	if e.bond <= 0 {
		panic("kourtv2: no bond is held on that edge; remove it instead")
	}
	burnAssocBond(c, e)
	dropAssocEdge(c, from, to)
}

// ClaimAssociationBond lets the author take back a bond no moderator judged
// inside the window. The edge stays; only the money moves.
func ClaimAssociationBond(cur realm, courtSlug string, from, to uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	e := mustAssocEdge(c, from, to)
	if e.bond <= 0 {
		panic("kourtv2: no bond is held on that edge")
	}
	if e.author != who {
		panic("kourtv2: only the edge's author may take its bond back")
	}
	if nowTime() < e.bondUntil {
		panic("kourtv2: the moderation window on that bond has not closed yet")
	}
	releaseAssocBond(c, e)
}

// pendingIncident collects every edge incident to one claim that still holds a
// bond, as two lists of the OTHER endpoint: outs are the `to` of edges this claim
// asserts, ins are the `from` of edges asserted about it.
//
// BOTH DIRECTIONS, because both caps are griefing vectors. A stranger may fill a
// claim's 32 outbound slots as readily as its 64 inbound ones — AddAssociation's
// `from` is any claim in the court, not the caller's own — so "clear the junk off
// this claim" is not true if it clears half of it.
//
// COLLECTED BEFORE ANYTHING IS SETTLED, and that is not tidiness: the disapprove
// path REMOVES keys from the very trees this walks, and mutating a bptree
// mid-iteration is undefined. The two slices are bounded by maxAssocOut and
// maxAssocIn, which is what makes the mass verbs cost no more than the caps the
// write path already enforces.
func pendingIncident(c *Court, claimID uint64) ([]uint64, []uint64) {
	outs, ins := []uint64{}, []uint64{}
	if c.assocOut == nil {
		return outs, ins
	}
	p := beClaimKey(claimID)
	c.assocOut.Iterate(p, "", func(key string, v any) bool {
		if !strings.HasPrefix(key, p) {
			return true
		}
		if e := v.(*assocEdge); e.bond > 0 {
			outs = append(outs, claimIDFromKey(key[8:]))
		}
		return false
	})
	c.assocIn.Iterate(p, "", func(key string, v any) bool {
		if !strings.HasPrefix(key, p) {
			return true
		}
		if e := v.(*assocEdge); e.bond > 0 {
			ins = append(ins, claimIDFromKey(key[8:]))
		}
		return false
	})
	return outs, ins
}

// ApproveAllAssociations settles every bond held on an edge incident to one
// claim, in one transaction: a moderator has read the claim's page and judged
// what is on it worth carrying. Returns how many bonds it returned.
//
// SINGLE-SIGNER, like the individual approve, and the reason does not carry over
// to its mirror: this verb only ever gives money BACK. A captured moderator using
// it refunds griefers, which costs the court nothing it ever had — the bonds were
// never the court's — and takes away no other remedy: the edges can still be
// removed, hidden, or struck one at a time.
//
// PER CLAIM, not per court, and that is what makes it bounded. The griefing this
// answers IS per claim — ASSOCIATIONS.md names the inbound cap itself as the
// vector — and a claim's incident edges are bounded by maxAssocOut+maxAssocIn exactly.
// A per-court sweep would cost O(edges in the docket): a transaction that gets
// more expensive as the court succeeds and one day cannot be sent at all. Court
// scope would need a third index holding only bonded edges; that is the design if
// it is ever wanted, and it is not free, so it waits for a court that needs it.
func ApproveAllAssociations(cur realm, courtSlug string, claimID uint64) int {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	requireActiveMod(ensureMod(c), who)
	mustClaim(c, claimID)
	outs, ins := pendingIncident(c, claimID)
	n := 0
	for _, to := range outs {
		releaseAssocBond(c, mustAssocEdge(c, claimID, to))
		n++
	}
	for _, from := range ins {
		releaseAssocBond(c, mustAssocEdge(c, from, claimID))
		n++
	}
	return n
}

// DisapproveAllAssociations judges every bonded association edge touching one
// claim at once: the bonds are BURNED and the edges dropped. Returns how many
// were burned, and 0 while the threshold is still short.
//
// reason is recorded on the moderation log and is required.
//
// SEVERAL MODERATORS MUST AGREE, at the court's moderation threshold — unlike
// approving in bulk and unlike disapproving one edge, both of which are
// single-signer. The difference is how much of other people's money one
// signature may destroy: a claim can carry up to 96 incident edges, and emptying
// them all is most of a page's contested state.
//
// ONLY EDGES THAT PREDATE THE PROPOSAL ARE BURNED. A bond posted between the
// first signature and the one that fires it has been judged by nobody, so it
// survives and its edge stays.
//
// Refused when the court or claim does not exist, the caller is not an active
// moderator, or the reason is missing or too long.
func DisapproveAllAssociations(cur realm, courtSlug string, claimID uint64, reason string) int {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireActiveMod(cm, who)
	checkReason(reason)
	mustClaim(c, claimID)

	key := "assocburn:" + strconv.FormatUint(claimID, 10)
	// Read BEFORE this signature joins, or a set of one always reads its own
	// height and the bound means nothing.
	opened := pendingOpenedAt(cm.pending, key)
	fire, _ := approveAction(cm.pending, key, who, reason, cm.m)
	if !fire {
		return 0
	}
	if opened == 0 {
		opened = heightNow() // this call both opened and fired it
	}

	outs, ins := pendingIncident(c, claimID)
	n := 0
	for _, to := range outs {
		n += burnIfOlder(c, claimID, to, opened)
	}
	for _, from := range ins {
		n += burnIfOlder(c, from, claimID, opened)
	}
	return n
}

// burnIfOlder burns one edge's bond and drops the edge, but only if the edge was
// written at or before `opened`. Returns 1 if it did.
func burnIfOlder(c *Court, from, to uint64, opened int64) int {
	e := mustAssocEdge(c, from, to)
	if e.bond <= 0 || e.at > opened {
		return 0
	}
	burnAssocBond(c, e)
	dropAssocEdge(c, from, to)
	return 1
}

// assocEdge is ONE object held in TWO indexes. assocOut and assocIn store the same
// pointer, so a stance cannot desync from itself and removal has to clear both
// or the edge survives in one direction — which is what the removal test pins.
type assocEdge struct {
	// bond is the CC this edge's author posted and has not got back: held in
	// c.escrow while no moderator has judged it, and zeroed the moment it moves
	// either way. So `bond > 0` IS the pending state and there is no second
	// flag to disagree with it — a refund or a burn cannot happen twice because
	// the second attempt finds nothing to move.
	bond int64
	// bondUntil is when the author may take an unjudged bond back, in UNIX
	// SECONDS rather than blocks. clock.gno's ruling: a deadline a user plans
	// around gates on block time, because a height only means a date if the
	// chain's pace never changes. Bonds only exist on edges written after this
	// field did, so unlike the claim deadlines there is no height fallback to
	// keep — every bonded edge has a real stamp.
	bondUntil int64

	stance int8
	author address
	// at is the height the edge was written. This said "for the record; nothing
	// gates on it", and DisapproveAllAssociations changed that: the bulk burn
	// settles only edges at or below the height its m-of-n proposal opened, so
	// this field is what keeps a bond posted mid-vote out of a burn nobody
	// consented to. Height and not time, deliberately — it is compared against
	// approval.openedAt, which is a height, and the two must be the same clock.
	at int64
}

// ensureAssocs allocates the two indexes. WRITE PATHS ONLY — it is named in
// check-read-purity.py's ALLOCATORS for that reason. A read that reached for it
// would let the first caller change what the second one sees, and a query
// carries no storage deposit, so it would be unpaid state growth.
func ensureAssocs(c *Court) {
	if c.assocOut == nil {
		c.assocOut = bptree.NewBPTree32()
	}
	if c.assocIn == nil {
		c.assocIn = bptree.NewBPTree32()
	}
}

// assocKey is the 16-byte composite both indexes use, so "every edge incident to
// claim X" is one prefix scan rather than a walk of the whole tree.
func assocKey(a, b uint64) string { return beClaimKey(a) + beClaimKey(b) }

// assocTextGone reports whether a claim's text is withheld — a purged or globally
// redacted claim. An edge pointing at one is not returned, for the same reason
// its title is not.
func assocTextGone(c *Court, id uint64) bool {
	if c.mod == nil {
		return false
	}
	clm := lookupClaimMod(c.mod, id)
	return clm != nil && (clm.purged || clm.global)
}

// AddAssociation records that claim `from` bears on claim `to`, with a stance.
// stance is "supports" or "contests". Both claims must be in the named court.
//
// ANYBODY MAY ASSERT AN EDGE. Most callers post a REFUNDABLE BOND first, held in
// the court escrow: it comes back in full if a moderator approves the edge, or
// by default if none looks at it inside the bond window. It is burned only if a
// moderator disapproves. Two callers pay nothing — the author of `from`, who
// already has a deposit behind their name, and an active court moderator.
// AssociationBond(courtSlug) quotes the amount.
//
// The price falls on being WRONG, not on speaking.
//
// Refused when the court does not exist, `from` equals `to`, either claim does
// not exist in that court, the stance is not one of the two words, that exact
// edge already exists (remove it to change its stance), `from` already asserts
// 32 associations, `to` already carries 64, the caller already holds 4 on `to`,
// or the caller's DisposableOf is short of the bond. Nothing is charged until
// every one of those has passed.
func AddAssociation(cur realm, courtSlug string, from, to uint64, stance string) {
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
		st = assocSupports
	case "contests":
		st = assocContests
	default:
		panic("kourtv2: a stance is \"supports\" or \"contests\"")
	}
	// Both endpoints must exist IN THIS COURT. Cross-court edges would put a
	// second court's id in the key and split one object's moderation authority
	// between two moderator sets.
	f := mustClaim(c, from)
	mustClaim(c, to)

	// WHO DOES NOT PAY. The asserting claim's own author already has a deposited
	// claim behind their name, and an active moderator is answerable by election.
	// Everybody else posts a refundable bond — see the note above the constant.
	// Resolved here but SPENT below, after every refusal has had its chance: a
	// call that is going to panic must not have moved money first.
	bond := int64(0)
	if f.author != who && !isActiveMod(ensureMod(c), who) {
		bond = assocBondFor(c)
	}

	ensureAssocs(c)
	k := assocKey(from, to)
	if c.assocOut.Get(k) != nil {
		panic("kourtv2: that edge already exists; remove it to change its stance")
	}

	// One scan answers all three caps: how many this claim already asserts, how
	// many are already asserted about the target, and how many of those are this
	// author's.
	outN := 0
	c.assocOut.Iterate(beClaimKey(from), "", func(key string, _ any) bool {
		if !strings.HasPrefix(key, beClaimKey(from)) {
			return true
		}
		outN++
		return outN > maxAssocOut
	})
	if outN >= maxAssocOut {
		panic("kourtv2: this claim already asserts " + strconv.Itoa(maxAssocOut) + " associations")
	}
	inN, mine := 0, 0
	c.assocIn.Iterate(beClaimKey(to), "", func(key string, v any) bool {
		if !strings.HasPrefix(key, beClaimKey(to)) {
			return true
		}
		inN++
		if e, ok := v.(*assocEdge); ok && e.author == who {
			mine++
		}
		return false
	})
	if inN >= maxAssocIn {
		panic("kourtv2: that claim already carries " + strconv.Itoa(maxAssocIn) + " associations")
	}
	if mine >= maxAssocInPerAuthor {
		panic("kourtv2: you already hold " + strconv.Itoa(maxAssocInPerAuthor) +
			" associations on that claim")
	}

	// Every refusal above has fired, so this is the first line that can cost the
	// caller anything.
	if bond > 0 {
		mustSpendable(c, who, bond)
		c.coin.Transfer(who, c.escrow, bond)
	}
	e := &assocEdge{stance: st, author: who, at: heightNow(), bond: bond}
	if bond > 0 {
		e.bondUntil = nowTime() + assocBondWindowSecs
	}
	c.assocOut.Set(k, e)
	c.assocIn.Set(assocKey(to, from), e)
}

// RemoveAssociation withdraws an edge. The edge's OWN AUTHOR, always; an active
// court moderator, always. Not the target claim's author — a claim's author
// deleting the edges that say "this is contested by #12" is exactly the
// censorship an association graph exists to resist, and it is the one removal rule
// worth being unable to bend.
func RemoveAssociation(cur realm, courtSlug string, from, to uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	if c.assocOut == nil {
		panic("kourtv2: no such association")
	}
	v := c.assocOut.Get(assocKey(from, to))
	if v == nil {
		panic("kourtv2: no such association")
	}
	e := v.(*assocEdge)
	requireEdgeRemover(c, e.author, who)
	// A HELD BOND FOLLOWS WHOEVER REMOVED THE EDGE. An author withdrawing their
	// own assertion takes their bond with them — they are not being judged. A
	// moderator removing it HAS judged it, which is the same act as
	// DisapproveAssociation, so it burns; otherwise removal would be the cheap
	// way around the burn and the bond would deter nothing.
	if e.bond > 0 {
		if e.author == who {
			releaseAssocBond(c, e)
		} else {
			burnAssocBond(c, e)
		}
	}
	dropAssocEdge(c, from, to)
}

// ClaimAssociations is every edge incident to one claim, packed:
//
//	out:<to>:<s|c>,<to>:<s|c>;in:<from>:<s|c>,...
//
// Both halves are always present and either may be empty ("out:;in:"). Packed
// rather than returned as a struct for the same reason ClaimSeries is: one read,
// one round trip, and a shape the overlay already knows how to parse.
//
// Bounded by construction — maxAssocOut + maxAssocIn rows, whatever anybody writes.
// Reads nil trees as empty and never allocates: a court that has never carried an
// edge answers "out:;in:" without the query creating anything.
func ClaimAssociations(courtSlug string, claimID uint64) string {
	c := mustCourt(courtSlug)
	mustClaim(c, claimID)
	var b strings.Builder
	b.WriteString("out:")
	if c.assocOut != nil {
		p := beClaimKey(claimID)
		n := 0
		c.assocOut.Iterate(p, "", func(key string, v any) bool {
			if !strings.HasPrefix(key, p) {
				return true
			}
			e := v.(*assocEdge)
			other := claimIDFromKey(key[8:])
			if assocTextGone(c, other) {
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
	if c.assocIn != nil {
		p := beClaimKey(claimID)
		n := 0
		c.assocIn.Iterate(p, "", func(key string, v any) bool {
			if !strings.HasPrefix(key, p) {
				return true
			}
			e := v.(*assocEdge)
			other := claimIDFromKey(key[8:])
			if assocTextGone(c, other) {
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
	if s == assocContests {
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
