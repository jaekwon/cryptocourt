// Moderation-aware render surfaces (MODERATION.md §5, §3.2) and the front
// page's two orderings.
//
// Kept beside render.gno rather than inside it so the claim page — the product
// — stays one readable file; render.gno calls into the helpers here at the few
// points where moderation changes what a reader sees:
//
//   - ordinary LISTINGS drop hidden rows (the only place a hide bit subtracts);
//   - DEEP LINKS always render, with a banner naming the authority;
//   - the GLOBAL bit redacts user text on EVERY surface but still shows IDs,
//     state, deadlines and money, so a participant can always act;
//   - PURGED rows render a category-code tombstone in place of text;
//   - the POLICING STRIPS ignore courtMod/meta bits entirely.
//
// Front-page ordering: GNOT-burn descending by default. Burned GNOT is the one
// signal an attacker cannot manufacture (you cannot fake burning real money),
// so ranking on it needs no gameable activity/vote score. Creation-newest-first
// is the alternative. Both read monotone secondary indexes and are paginated,
// so page cost never grows with the court count.
package kourtv2

import (
	"math/overflow"
	"strconv"
	"strings"

	bptree "gno.land/p/nt/bptree/v0"
	sanitize "gno.land/p/nt/markdown/sanitize/v0"
)

// burnIdx orders courts by cumulative GNOT burned, DESCENDING: the key inverts
// the burn total so ascending iteration yields the biggest first. createdIdx
// orders by creation height, and is reverse-iterated for newest-first.
var (
	burnIdx    = bptree.NewBPTree32()
	createdIdx = bptree.NewBPTree32()
	courtSeq   uint64
)

// beInv encodes a descending key: larger values sort earlier.
func beInv(v int64) string {
	if v < 0 {
		v = 0
	}
	return beClaimKey(^uint64(v))
}

// reindexBurn adds `spent` to a court's burn total and re-keys its index row.
// Called from Buy; never panics, never reads money state back.
func reindexBurn(c *Court, spent int64) {
	// Checked add with a SILENT skip — deliberately not mustAdd. This runs
	// inside Buy, the platform's only GNOT on-ramp, so a panic here would brick
	// buying on every court; an unreachable overflow must degrade the index,
	// never the money path. (Same discipline as accrueFranchise.)
	sum, ok := overflow.Add64(c.burnedGNOT, spent)
	if !ok {
		return
	}
	if c.burnedGNOT > 0 || c.burnKey != "" {
		burnIdx.Remove(c.burnKey)
	}
	c.burnedGNOT = sum
	c.burnKey = beInv(c.burnedGNOT) + c.id
	burnIdx.Set(c.burnKey, c.id)
}

// indexNewCourt registers a court in both directory indexes at creation.
func indexNewCourt(c *Court) {
	courtSeq++
	c.createdSeq = courtSeq
	createdIdx.Set(beClaimKey(c.createdSeq), c.id)
	c.burnKey = beInv(0) + c.id
	burnIdx.Set(c.burnKey, c.id)
}

// listedPage returns up to limit listed-tier slugs in the requested order,
// skipping offset. order "new" is creation-newest-first; anything else is the
// default, GNOT-burn descending. Hidden-tier courts never appear.
func listedPage(order string, offset, limit int) []string {
	out := []string{}
	if limit <= 0 {
		return out
	}
	skipped := 0
	take := func(_ string, v any) bool {
		slug, ok := v.(string)
		if !ok || !Exists(slug) {
			return false
		}
		c := mustCourt(slug)
		if c.tier == tierHidden {
			return false
		}
		if skipped < offset {
			skipped++
			return false
		}
		out = append(out, slug)
		return len(out) >= limit
	}
	if order == "new" {
		createdIdx.ReverseIterate("", "", take)
	} else {
		burnIdx.Iterate("", "", take)
	}
	return out
}

// ListedCourtsBy is the paginated front-page read ("burn" | "new").
func ListedCourtsBy(order string, offset, limit int) []string {
	return listedPage(order, offset, limit)
}

// CourtBurnedGNOT is the cumulative GNOT burned into a court's curve.
func CourtBurnedGNOT(courtSlug string) int64 { return mustCourt(courtSlug).burnedGNOT }

// ---- text gates used by every render path ---------------------------------

// claimTitleFor is THE single place a claim's title becomes display text. A
// purged row shows its statutory category code; a globally-redacted row shows
// nothing at all. Everything else is sanitized.
func claimTitleFor(c *Court, cs *claimState) string {
	if c.mod != nil {
		if clm := lookupClaimMod(c.mod, cs.id); clm != nil {
			if clm.purged {
				return "[removed · " + sanitize.InlineText(clm.tombstone) + "]"
			}
			if clm.global {
				return "[text withheld]"
			}
		}
	}
	return sanitize.InlineText(cs.title)
}

// platformName / platformTicker are the product's identity.
const (
	platformName   = "Kourt"
	platformTicker = "KOURT"
)

// qualifiedSymbol renders a court coin as KOURT:SYMBOL. A BARE court symbol is
// only ever shown inside that court's own page: court coins are non-fungible and
// backed by separate one-way curves, so an unqualified ticker in a directory or
// a wallet-style list invites reading one court's coin as another's — or as the
// platform token.
func qualifiedSymbol(c *Court) string {
	return platformTicker + ":" + sanitize.InlineText(c.coin.Symbol())
}

// courtNameFor gates a COURT's name the way claimTitleFor gates a claim title.
// A whole-court purge is a legal-hold act, and §2 lists court names in the
// user-text inventory purge must reach — rendering the raw name anywhere would
// leave the offending text on the directory and on every page of that court.
func courtNameFor(c *Court) string {
	if c.mod != nil && c.mod.courtPurged {
		return "[removed · " + sanitize.InlineText(c.mod.courtTombstone) + "]"
	}
	return sanitize.InlineText(c.name)
}

// hideBanner names the authority hiding a claim, for deep links (which always
// render). Empty when nothing hides it.
func hideBanner(c *Court, cs *claimState) string {
	if c.mod == nil {
		return ""
	}
	clm := lookupClaimMod(c.mod, cs.id)
	if clm == nil {
		return ""
	}
	switch {
	case clm.purged:
		return "> **Removed on legal grounds** (" + sanitize.InlineText(clm.tombstone) +
			"). The claim's lifecycle is unaffected: stakes, verdict and refunds proceed.\n\n"
	case clm.global:
		return "> **Text withheld pending review.** IDs, state, deadlines and balances still render, so you can always act on a position.\n\n"
	case clm.meta:
		return "> **Hidden by the review court.** Listed nowhere, reachable here; the lifecycle is unaffected.\n\n"
	case clm.court:
		return "> **Hidden by this court's moderators.** Listed nowhere, reachable here; the lifecycle is unaffected.\n\n"
	}
	return ""
}

// ---- the policing strip + pending list pages ------------------------------

func writeStrip(b *strings.Builder, slug string) {
	c := mustCourt(slug)
	n := StripSize(slug)
	if n == 0 {
		return
	}
	b.WriteString("## Needs review\n\nClaims that are answered and not yet settled — nearest deadline first. This list ignores moderation: a claim hidden from the lists above still appears here while it can still be flagged.\n\n")
	ids := StripPage(slug, 0, renderPageSize)
	for _, id := range ids {
		cs := mustClaim(c, id)
		b.WriteString("- [" + claimTitleFor(c, cs) + "](/r/kourt/kourtv2:" + slug + "/" +
			strconv.FormatUint(id, 10) + ") — settles at height " +
			strconv.FormatInt(cs.answerHeight+settleDelay, 10) + "\n")
	}
	if n > len(ids) {
		b.WriteString("- _…and " + strconv.Itoa(n-len(ids)) + " more_\n")
	}
	b.WriteString("\n")
}

func writePending(b *strings.Builder, slug string) {
	c := mustCourt(slug)
	n := PendingSize(slug)
	if n == 0 {
		return
	}
	b.WriteString("## Awaiting an answer\n\nSeeded and appeal claims that no one has answered yet.\n\n")
	ids := PendingPage(slug, 0, renderPageSize)
	for _, id := range ids {
		cs := mustClaim(c, id)
		tag := ""
		if cs.seeded {
			tag = " — seeded by a moderator"
		}
		b.WriteString("- [" + claimTitleFor(c, cs) + "](/r/kourt/kourtv2:" + slug + "/" +
			strconv.FormatUint(id, 10) + ")" + tag + "\n")
	}
	if n > len(ids) {
		b.WriteString("- _…and " + strconv.Itoa(n-len(ids)) + " more_\n")
	}
	b.WriteString("\n")
}

// writeAppeal renders a meta claim's parsed instruction — the verb, the target,
// and for a setmods appeal the exact moderator set it would install.
//
// This closes the amplifier on the setmods bait-and-switch: the ballot is a
// claim TITLE, so without decoding it here the electorate votes on an opaque
// string and cannot see which addresses they are seating. It renders the STORED
// parse, which survives a purge, so a redacted appeal still shows verb+target
// (realm-validated, category-code-class strings) rather than blinding its own
// voters.
func writeAppeal(b *strings.Builder, c *Court, cs *claimState) {
	if c.id != metaSlug {
		return
	}
	verb, court, target, valid := AppealParse(cs.id)
	if !valid {
		b.WriteString("> _Not a valid review request — this is an ordinary claim on the review court._\n\n")
		return
	}
	b.WriteString("## Review request\n\n")
	b.WriteString("- action: **" + sanitize.InlineText(verb) + "**\n")
	b.WriteString("- court: " + sanitize.InlineText(court) + "\n")
	if verb == verbSetmods {
		b.WriteString("- installs candidate set #" + strconv.FormatUint(target, 10) + ":\n")
		if !Exists(court) {
			b.WriteString("  - _that court does not exist_\n\n")
			return
		}
		tc := mustCourt(court)
		if tc.mod == nil || tc.mod.candidates == nil ||
			tc.mod.candidates.Get(beClaimKey(target)) == nil {
			// An unregistered id is exactly the bait-and-switch shape: say so
			// loudly rather than rendering a blank.
			b.WriteString("  - **this candidate set does not exist yet — do not approve**\n\n")
			return
		}
		cand := tc.mod.candidates.Get(beClaimKey(target)).(*modCandidate)
		for _, a := range cand.members {
			b.WriteString("  - " + sanitize.InlineText(a.String()) + "\n")
		}
		b.WriteString("  - threshold: " + strconv.Itoa(cand.m) + " of " +
			strconv.Itoa(len(cand.members)) + " must agree\n")
	} else if target != 0 {
		b.WriteString("- claim: " + strconv.FormatUint(target, 10) + "\n")
	}
	b.WriteString("\n")
}

// ---- the moderation log route (<slug>/mod) --------------------------------

func renderModLog(slug string) string {
	if !Exists(slug) {
		return "## Not found\nNo court by that slug."
	}
	c := mustCourt(slug)
	b := strings.Builder{}
	b.WriteString("# Moderation log — " + courtNameFor(c) + "\n\n")
	b.WriteString("Every moderation act on this court is recorded here: who acted, what they did, and when. Moderation controls what is listed; it never moves a coin or changes a verdict.\n\n")
	if c.mod == nil {
		// Lazily created, so there is no object yet — but the set is not empty:
		// the admin is the 1-of-1 until an act, an appointment or an election
		// materialises one. Saying only "no acts yet" hid who could act.
		b.WriteString("## Moderators\n\n1-of-1 — " + c.admin.String() +
			" (the court's creator, until an election or an appointment changes it)\n\n")
		b.WriteString("_No moderation acts yet._\n")
		return b.String()
	}
	cm := c.mod
	if cm.courtPurged {
		b.WriteString("> **This court was removed on legal grounds** (" +
			sanitize.InlineText(cm.courtTombstone) + "). No new claims may be opened; existing claims settle and pay out normally.\n\n")
	}
	b.WriteString("## Moderators\n\n")
	if cm.n == 0 {
		b.WriteString("_None — the set is empty; the court's holders can elect one._\n\n")
	} else {
		b.WriteString("- " + strconv.Itoa(cm.m) + " of " + strconv.Itoa(cm.n) +
			" must agree for a moderation act\n")
		if cm.suspended {
			b.WriteString("- **suspended** — their hides are masked and they cannot act\n")
		}
		if cm.installedByMeta {
			b.WriteString("- seated by the review court; may not seed claims until a local election\n")
		}
		b.WriteString("\n")
	}
	// Newest acts first, one page (the N3 bound). ReverseIterate matters: claim
	// keys are big-endian ids, so a forward walk starts at the OLDEST moderated
	// claim — once those filled a page, no recent act was ever visible, which is
	// the opposite of what a moderation log is for.
	//
	// TWO bounds, not one. Stopping only when ROWS fill a page is a bound on
	// output, not on work: a claimMod carrying few or no acts costs a step and
	// buys no row, so a court with many lightly-moderated claims walks them all.
	// Nothing mints an act-less row today (ensureClaimMod runs only after the
	// m-of-n fires), but that is an invariant elsewhere in the file, and a
	// render should not silently depend on one. So the WALK is bounded too.
	rows := []string{}
	visited := 0
	truncated := false
	cm.claims.ReverseIterate("", "", func(_ string, v any) bool {
		clm, ok := v.(*claimMod)
		if !ok {
			return false
		}
		visited++
		for i := len(clm.log) - 1; i >= 0; i-- {
			a := clm.log[i]
			line := "- height " + strconv.FormatInt(a.height, 10) + " · " +
				sanitize.InlineText(a.code) + " · by " + sanitize.InlineText(a.actor.String())
			if a.reason != "" && !a.purged {
				line += " — " + sanitize.InlineText(a.reason)
			}
			rows = append(rows, line)
			if len(rows) >= renderPageSize {
				truncated = true
				return true
			}
		}
		if visited >= renderPageSize {
			truncated = true
			return true
		}
		return false
	})
	b.WriteString("## Acts\n\n")
	if len(rows) == 0 {
		b.WriteString("_No moderation acts yet._\n")
		return b.String()
	}
	for _, r := range rows {
		b.WriteString(r + "\n")
	}
	// SAY SO when the page is not the whole log. A moderation log is an
	// accountability record, and one that silently shows a slice of itself
	// invites the reader to conclude that nothing else happened. The exact
	// remaining count is deliberately not computed — that would re-walk
	// everything this bound exists to avoid — but the claim count is O(1) and
	// tells a reader how much history there is.
	if truncated {
		b.WriteString("\n_Showing the " + strconv.Itoa(len(rows)) +
			" most recent acts. This court has moderated " + strconv.Itoa(cm.claims.Size()) +
			" claims; older acts are not shown._\n")
	}
	return b.String()
}
