// The policing surfaces (MODERATION.md §5.3) — the load-bearing guarantee of
// the whole moderation design.
//
// Hiding a claim is render-layer, but it still shapes ECONOMICS, because V2's
// junk defense (the quality flag lane) is discovery-driven: a claim nobody
// discovers in time is a claim nobody flags, and it settles at the paying MID
// default. So a hidden claim must never fall off EVERY surface while it is
// still policeable. Two indexed strips (per-court and realm-wide) plus a
// per-court pending list carry that guarantee, and they IGNORE the courtMod and
// meta hide bits by construction.
//
// Ordering is the anti-flood spine: rows sort by their actionable DEADLINE
// (answerHeight + settleDelay), nearest-to-mint first. A mill cannot manufacture
// a past deadline, and it cannot keep its own about-to-settle target off the top
// of the page — the target is discoverable-for-policing for its whole settle
// window. Keys are big-endian so ascending iteration IS deadline order; entry
// and exit compute the same key from immutable fields, so membership is
// idempotent and needs no stored key.
//
// Every write here is called BY the money path (PostAnswer, Crystallize,
// provCloseClaim, CloseDeadClaim) and therefore must never panic: a
// moderation-side invariant may not block a lifecycle transition (§2).

package kourtv2

import bptree "gno.land/p/nt/bptree/v0"

// stripActorCap bounds how many rows one answerer or one author may occupy on a
// contended page. It binds ONLY when the index overflows a page — an
// uncontended strip renders every row (round-4 F3b). Caps key the FREE
// dimensions (addresses), so they only blunt a sybil blockade; the deadline
// ordering is what defeats it. Seeded rows are exempt: a seed-farm burying
// itself past the cap is covered by the "seeded" badge, so capping them would
// only hide the evidence (round-4 code-truth F4).
const stripActorCap = 5

// stripRow identifies one policeable claim on the realm-wide directory strip.
type stripRow struct {
	slug    string
	claimID uint64
}

// globalStripIdx is the realm-wide policing index behind the directory strip:
// be(deadline)|slug|be(claimID) -> *stripRow. It exists so a TIER-HIDDEN
// court's policeable claims are still discoverable (round-2 M-A14: court-level
// hiding was the same turnout lever one level up).
var globalStripIdx = bptree.NewBPTree32()

// beHeightKey encodes a height big-endian so string order is numeric order.
func beHeightKey(h int64) string {
	if h < 0 {
		h = 0
	}
	return beClaimKey(uint64(h))
}

// stripDeadline is the row's ordering key: the settle deadline on the dominant
// (undisputed) path. Deliberately computed from the IMMUTABLE answer height
// rather than tracking the live actionable height — a stable key never needs
// re-keying, and §5.3 only claims the ordering APPROXIMATES urgency once a
// claim leaves the dominant path (flag/escrow/counter windows restamp
// crystallize-eligibility, never this key).
func stripDeadline(cs *claimState) int64 { return cs.answerHeight + settleDelay }

func stripKey(cs *claimState) string {
	return beHeightKey(stripDeadline(cs)) + beClaimKey(cs.id)
}

func globalStripKey(slug string, cs *claimState) string {
	return beHeightKey(stripDeadline(cs)) + slug + beClaimKey(cs.id)
}

// pendingKey orders the pending list by open height. Honest note (round-5 F2):
// a pre-answer row has no SettleDeadline, so the pending list CANNOT carry the
// deadline spine, and this key sorts a flood earliest. Its guarantee is
// pagination + the priced door, and the real escape is that an appellant can
// self-answer to move their row onto the deadline-ordered strip.
func pendingKey(cs *claimState) string {
	return beHeightKey(cs.openedAt) + beClaimKey(cs.id)
}

// ---- membership writes (called by the money path; never panic) ------------

// stripEnter puts an answered claim on both policing strips. Idempotent.
func stripEnter(c *Court, cs *claimState) {
	if cs.inStrip {
		return
	}
	if c.stripIdx == nil {
		c.stripIdx = bptree.NewBPTree32()
	}
	c.stripIdx.Set(stripKey(cs), cs.id)
	globalStripIdx.Set(globalStripKey(c.id, cs), &stripRow{slug: c.id, claimID: cs.id})
	cs.inStrip = true
}

// stripExit removes a claim once it is no longer policeable: crystallized,
// provClosed, or dead-closed. Idempotent.
func stripExit(c *Court, cs *claimState) {
	if !cs.inStrip {
		return
	}
	if c.stripIdx != nil {
		c.stripIdx.Remove(stripKey(cs))
	}
	globalStripIdx.Remove(globalStripKey(c.id, cs))
	cs.inStrip = false
}

// pendingEnter puts an unanswered seeded claim (or, once the meta module lands,
// an unanswered `mod:` appeal) on the court's pending list, so a pre-answer row
// can never be embargoed off every surface. Idempotent.
func pendingEnter(c *Court, cs *claimState) {
	if cs.inPending {
		return
	}
	if c.pendingIdx == nil {
		c.pendingIdx = bptree.NewBPTree32()
	}
	c.pendingIdx.Set(pendingKey(cs), cs.id)
	cs.inPending = true
}

// pendingExit drops a pending row: it moved to the strip at PostAnswer, or it
// dead-closed. Idempotent.
func pendingExit(c *Court, cs *claimState) {
	if !cs.inPending {
		return
	}
	if c.pendingIdx != nil {
		c.pendingIdx.Remove(pendingKey(cs))
	}
	cs.inPending = false
}

// ---- reads (render + clients; never read by a money path) -----------------

// stripPageIDs walks a court's strip in nearest-deadline order and returns up
// to limit claim IDs after skipping offset rows, applying the per-actor cap
// only when the index overflows one page.
func stripPageIDs(c *Court, offset, limit int) []uint64 {
	out := []uint64{}
	if c.stripIdx == nil || limit <= 0 {
		return out
	}
	capBinds := c.stripIdx.Size() > renderPageSize
	perAnswerer := map[string]int{}
	perAuthor := map[string]int{}
	skipped := 0
	c.stripIdx.Iterate("", "", func(_ string, v any) bool {
		id, ok := v.(uint64)
		if !ok {
			return false
		}
		cv := c.claims.Get(beClaimKey(id))
		if cv == nil {
			return false
		}
		cs := cv.(*claimState)
		if capBinds && !cs.seeded {
			a := cs.answerer.String()
			b := cs.author.String()
			if perAnswerer[a] >= stripActorCap || perAuthor[b] >= stripActorCap {
				return false // this actor already holds its share of a contended page
			}
			perAnswerer[a]++
			perAuthor[b]++
		}
		if skipped < offset {
			skipped++
			return false
		}
		out = append(out, id)
		return len(out) >= limit
	})
	return out
}

// StripPage is the per-court policing strip: the claims that are answered but
// not yet crystallized/provClosed/closed, nearest-deadline first, regardless of
// any courtMod or meta hide bit. Paginated so the guarantee never bottoms out
// at one page (§4).
func StripPage(courtSlug string, offset, limit int) []uint64 {
	return stripPageIDs(mustCourt(courtSlug), offset, limit)
}

// StripSize is how many policeable rows a court currently has.
func StripSize(courtSlug string) int {
	c := mustCourt(courtSlug)
	if c.stripIdx == nil {
		return 0
	}
	return c.stripIdx.Size()
}

// PendingPage is the per-court pending list (unanswered seeded claims and, once
// the meta module lands, unanswered `mod:` appeals), oldest first.
func PendingPage(courtSlug string, offset, limit int) []uint64 {
	out := []uint64{}
	c := mustCourt(courtSlug)
	if c.pendingIdx == nil || limit <= 0 {
		return out
	}
	// IterateByOffset descends to the offset in O(log n) instead of stepping
	// over it. The strip page below cannot do this — its per-actor cap counts
	// across the whole prefix ON PURPOSE, so that a deep page stays consistent
	// with the pages before it — but the pending list has no such term, and a
	// caller-supplied offset is otherwise a linear walk they pay gas for.
	c.pendingIdx.IterateByOffset(offset, limit, func(_ string, v any) bool {
		if id, ok := v.(uint64); ok {
			out = append(out, id)
		}
		return false
	})
	return out
}

// PendingSize is how many pending rows a court currently has.
func PendingSize(courtSlug string) int {
	c := mustCourt(courtSlug)
	if c.pendingIdx == nil {
		return 0
	}
	return c.pendingIdx.Size()
}

// DirectoryStripPage is the realm-wide policing strip, nearest-deadline first
// across every court — including tier-hidden ones. Returned as parallel slices
// so a caller gets (slug, claimID) pairs without a /p/ pointer escaping realm
// state (borrow rule #2). A per-court sub-cap keeps one court from occupying
// the page when it overflows.
func DirectoryStripPage(offset, limit int) ([]string, []uint64) {
	slugs := []string{}
	ids := []uint64{}
	if limit <= 0 {
		return slugs, ids
	}
	capBinds := globalStripIdx.Size() > renderPageSize
	perCourt := map[string]int{}
	skipped := 0
	globalStripIdx.Iterate("", "", func(_ string, v any) bool {
		r, ok := v.(*stripRow)
		if !ok {
			return false
		}
		if capBinds {
			if perCourt[r.slug] >= stripActorCap {
				return false
			}
			perCourt[r.slug]++
		}
		if skipped < offset {
			skipped++
			return false
		}
		slugs = append(slugs, r.slug)
		ids = append(ids, r.claimID)
		return len(slugs) >= limit
	})
	return slugs, ids
}

// DirectoryStripSize is the realm-wide policeable row count.
func DirectoryStripSize() int { return globalStripIdx.Size() }

// OnStrip / OnPending are the membership reads (render badges; tests).
func OnStrip(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).inStrip
}

func OnPending(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).inPending
}
