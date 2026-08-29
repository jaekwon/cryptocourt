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

// claimBodyVisible is the MODERATION gate alone: the body a given reader is
// allowed to see, unsanitised. A purged claim answers with NOTHING rather than
// with its tombstone — the title already carries "[removed · <category>]", and
// repeating it here would be noise where the point is absence.
//
// EVERY CALLER MUST SANITISE FOR ITS OWN OUTPUT CONTEXT, and they do not agree on
// which helper, which is exactly why this returns raw. sanitize/v0's own rule is
// "sanitise once, at the point of output", and the two outputs are different
// documents:
//
//   the ClaimBody read  -> sanitize.Block. The overlay consumes it and does its
//                          own escaping; a `> ` on every line would be a
//                          markdown artefact in a place with no markdown.
//   Render's markdown   -> sanitize.Blockquote. See below.
func claimBodyVisible(c *Court, cs *claimState) string {
	if cs.body == "" {
		return ""
	}
	if c.mod != nil {
		if clm := lookupClaimMod(c.mod, cs.id); clm != nil {
			if clm.purged || clm.global {
				return ""
			}
		}
	}
	return cs.body
}

// claimBodyFor is the body as the ClaimBody read answers it: gated, then
// sanitize.Block — the STRICT variant, which escapes the doc-spoof markers (ATX
// headings, blockquote markers, list markers, thematic breaks, setext
// underlines) that sanitize.BlockRich deliberately preserves. Strict is right
// here: the body is the only multi-LINE string a stranger writes on a claim page,
// and every other user string on it is inline and cannot open a block at all.
//
// Block, not InlineText, because a body is multi-line by design and InlineText
// folds it to one — which would silently destroy the paragraphs the field is for.
func claimBodyFor(c *Court, cs *claimState) string {
	body := claimBodyVisible(c, cs)
	if body == "" {
		return ""
	}
	return sanitize.Block(body)
}

// claimBodyQuoted is the body for the MARKDOWN surface, and it is quoted rather
// than merely escaped. Block escapes CommonMark §4.6 HTML block types 1-5 —
// <script>, <pre>, <style>, <textarea> — but by its own documentation it does NOT
// escape types 6 and 7: <div>, <table>, <form>, arbitrary <foo>. Those it only
// CONTAINS, with a trailing blank line that closes the block before the realm's
// own chrome resumes. A test written against this realm's integration proved it:
// a body of "<div>" reached the page at line start, and the sections below it
// survived only because the envelope closed the block.
//
// Contained is not the same as absent. gnoweb runs no HTML sanitiser after the
// realm, so a `<form>` in a body would render a form on a page people stake money
// on, and a `<table>` would forge a data table under a headline. Blockquote is
// Block plus a `> ` on every line, so whatever HTML still opens does so INSIDE a
// quotation that closes at its own blank line — and that is also what the body
// honestly is: the author's statement, quoted, not the court's own words.
func claimBodyQuoted(c *Court, cs *claimState) string {
	body := claimBodyVisible(c, cs)
	if body == "" {
		return ""
	}
	return sanitize.Blockquote(body)
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

// courtDescFor is the description behind the same gate as the name: a purged
// court answers with nothing rather than with its tombstone, because the NAME
// already carries "[removed · <code>]" and repeating it under itself is noise
// where the point is absence. InlineText, not Block — the field is a single
// paragraph by construction (mustCourtDesc refuses newlines), and it renders
// inline beside the name in list rows.
func courtDescFor(c *Court) string {
	if c.desc == "" {
		return ""
	}
	if c.mod != nil && c.mod.courtPurged {
		return ""
	}
	return sanitize.InlineText(c.desc)
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
		return "> **Text withheld pending review.** The claim's id, its state, its deadlines and every balance are still shown, so you can always act on a position.\n\n"
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
			strconv.FormatUint(id, 10) + ") — settles at block " +
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
	b.WriteString("- action: **" + sanitize.InlineText(verb) + "** — " +
		appealVerbGloss(verb) + "\n")
	b.WriteString("- court: " + sanitize.InlineText(court) + "\n")
	// WHAT SILENCE DOES, which is the opposite thing for the two kinds of verb
	// and was on no surface. A restorative verb may carry on the undisputed
	// route, so a voter who does nothing lets it through; an aggressive one is
	// refused unless a quorate round decided it against real opposition, so a
	// voter who does nothing blocks it. Reading only the verb code, a voter
	// cannot tell which of those their abstention is.
	if verbIsAggressive(verb) {
		b.WriteString("- this is an **aggressive** act: it can only carry on a " +
			"contested vote that real opposition turned out for. Silence " +
			"defeats it.\n")
	} else {
		b.WriteString("- this is a **restorative** act: it undoes a restriction, so " +
			"it can carry undisputed. Silence lets it through.\n")
	}
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

// modActLine formats one log row, and is the ONLY place a log row becomes text.
//
// ONE COPY, TWO LOGS. The court-level log (boardmod.gno) and the per-claim log
// render identically apart from the label, and the second copy of these four
// lines immediately made two existing mutation-corpus anchors ambiguous — the
// corpus caught the duplication before a divergence could. `kind` is the only
// difference, because the two logs have SEPARATE row-id sequences and each has
// its own purge verb, so a reader has to be able to tell which id they are
// looking at.
//
// The row id is PRINTED because it is the handle PurgeModLogRow and
// PurgeCourtLogRow take (I11). A power addressed by an id nobody can see is a
// power nobody can use.
func modActLine(a modAct, kind string) string {
	line := "- " + kind + " " + strconv.FormatUint(a.rowID, 10) +
		" · block " + strconv.FormatInt(a.height, 10) + " · " +
		sanitize.InlineText(a.code) + " · by " + sanitize.InlineText(a.actor.String())
	switch {
	case a.purged:
		line += " — _[reason removed on legal grounds]_"
	case a.reason != "":
		line += " — " + sanitize.InlineText(a.reason)
	}
	return line
}

func renderModLog(slug string) string {
	if !Exists(slug) {
		return "## Not found\nNo court by that slug."
	}
	c := mustCourt(slug)
	b := strings.Builder{}
	b.WriteString("# Moderation log — " + courtNameFor(c) + "\n\n")
	// WHAT IT ACTUALLY COVERS. This said "every moderation act on this court",
	// and eleven do not appear: the ten folder verbs and court-desc emit a
	// ModAct event and never call appendLog. A demo court with three folders and
	// five filings read "No moderation acts yet" underneath the promise.
	//
	// The sentence is narrowed rather than the acts logged, because logging them
	// changes what this log IS — cm.log is where a board sanction lands precisely
	// because it has no claim to hang off, and a busy curator would push
	// sanctions off the first page of a bounded render. Recorded as a ruling in
	// docs/CLAIM_BOARDS.md §19 so it is a decision and not a default.
	//
	// It names where curation IS visible, because §18.2 made the filing tree
	// renderable: a reader who can now see that somebody organised a contested
	// docket should be told plainly where the record of that organising is, and
	// is not.
	b.WriteString("Every moderation act on this court's CLAIMS and COMMENTS is recorded here: who acted, what they did, and when. Moderation controls what is listed; it never moves a coin or changes a verdict.\n\n")
	b.WriteString("[Who holds these seats, and how to challenge them](/r/kourt/kourtv2:" +
		sanitize.InlineText(slug) + "/election)\n\n")
	b.WriteString("Curation — which claims a moderator filed under which heading — is " +
		"not in this list. The tree it produced is on the [court page](/r/kourt/kourtv2:" + sanitize.InlineText(slug) + "); the acts themselves are in " +
		"the chain's event stream.\n\n")
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
		// AND THE BOARD THRESHOLD, WHICH IS NOT THE SAME NUMBER. Board acts fire
		// at speechM = min(n, max(2, m)), so a 1-of-3 set needs two approvals to
		// touch anyone's speech. This page printed only `m of n` and therefore
		// stated the wrong rule for every court where the two differ; SpeechThreshold
		// existed with no caller at all.
		if sm := speechM(cm); sm != cm.m {
			b.WriteString("- " + strconv.Itoa(sm) + " of " + strconv.Itoa(cm.n) +
				" for a **board** act — hiding a comment, slashing standing, " +
				"freezing an address — because speech takes a wider agreement " +
				"than the set's own threshold\n")
		}
		if cm.suspended {
			// WHAT SUSPENSION ACTUALLY DOES. This line used to say "their hides
			// are masked and they cannot act". The second half is true; the first
			// is not, and no visibility predicate in the realm consults
			// cm.suspended — HiddenFromListing is `court || meta || global` and
			// boardMark reads the row's own bits. A page that promises a masking
			// the code does not perform tells a reader their content is back when
			// it is not. §7.4 asks for the masking; docs/CLAIM_BOARDS.md carries
			// the ruling on whether to build it.
			b.WriteString("- **suspended** — they cannot take new moderation acts. " +
				"The hides and freezes already in place stand until cleared, and " +
				"any member may still lift their own\n")
		}
		if cm.installedByMeta {
			b.WriteString("- seated by the review court; may not seed claims until a local election\n")
		}
		b.WriteString("\n")
	}
	// In-flight proposals, with their deadlines. An m-of-n set that cannot see
	// what it has half-approved coordinates by rumour, and v0.25 gave every
	// unfired approval a 7-day expiry — a deadline nobody can see is a trap for
	// a set six days into gathering signatures.
	//
	// The action KEY, the count and the deadline render. The stored `reason` does
	// NOT, deliberately: it is free text one moderator wrote, and no m-of-n has
	// approved it yet. Rendering it would hand any single member of the set a
	// publication channel on the court's own page without the set's consent —
	// which is the same authority-without-agreement the m-of-n exists to prevent.
	// It appears in the log only once the act FIRES.
	//
	// Bounded on entries VISITED, like the act loop below: this is the only place
	// in the realm that walks `pending`, and an unbounded walk here would undo
	// the v0.21 lesson one function away from where it was learned.
	pendingRows := []string{}
	pendingSeen := 0
	pendingMore := false
	now := heightNow()
	cm.pending.Iterate("", "", func(key string, v any) bool {
		pendingSeen++
		if a, ok := v.(*approval); ok {
			if deadline := a.openedAt + pendingTTLBlocks; now < deadline {
				pendingRows = append(pendingRows,
					// InlineCode, not backticks around InlineText. A backslash
					// escape is INERT inside a CommonMark code span, so
					// InlineText's `\`` would render the backslash literally and
					// the backtick would close the span early, spilling the rest
					// into the page. InlineCode is the helper for this position:
					// it sizes the fence to the content instead of escaping.
					//
					// NOT a live bug — every key here is verb:slug:id and mustSlug
					// bounds a slug to [a-z0-9-]{1,11}, so no key can hold a
					// backtick today. The invariant that makes the old code safe
					// lives in court.gno, three files from the thing it protects,
					// and a future key that carries a reason or a name would make
					// it exploitable with no failing test.
					"- "+sanitize.InlineCode(key)+" — "+strconv.Itoa(a.approvers.Size())+
						" of "+strconv.Itoa(cm.m)+" approved, expires at block "+
						strconv.FormatInt(deadline, 10))
			}
		}
		if len(pendingRows) >= renderPageSize || pendingSeen >= renderPageSize {
			pendingMore = true
			return true
		}
		return false
	})
	if len(pendingRows) > 0 {
		b.WriteString("## Awaiting approval\n\nProposals this set has started and not yet carried. An approval expires if the set does not reach its threshold in time; the reason is withheld until the act carries.\n\n")
		for _, r := range pendingRows {
			b.WriteString(r + "\n")
		}
		if pendingMore {
			b.WriteString("- _…more not shown_\n")
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
	// THE COURT-LEVEL LOG FIRST, and newest-first within it. A board sanction is
	// keyed to an ADDRESS, so it has no claim to hang off and lands in cm.log
	// (boardmod.gno). It is read first because those are the acts a reader is
	// least likely to find any other way: a claim's own page shows its hides, but
	// nothing shows a slash except this list.
	//
	// Rows are labelled "court row" because the two logs have SEPARATE
	// sequences — a court row and a claim row may share a number, and
	// PurgeCourtLogRow and PurgeModLogRow are different verbs.
	for i := len(cm.log) - 1; i >= 0 && len(rows) < renderPageSize; i-- {
		rows = append(rows, modActLine(cm.log[i], "court row"))
	}
	if len(rows) >= renderPageSize {
		truncated = true
	}
	cm.claims.ReverseIterate("", "", func(_ string, v any) bool {
		if len(rows) >= renderPageSize {
			truncated = true
			return true
		}
		clm, ok := v.(*claimMod)
		if !ok {
			return false
		}
		visited++
		for i := len(clm.log) - 1; i >= 0; i-- {
			rows = append(rows, modActLine(clm.log[i], "row"))
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

// appealVerbGloss says in words what a review verb does.
//
// The page showed the bare code — "action: **setmods**" — on the surface where
// the review court's heaviest acts are approved: seating moderators on somebody
// else's court, disarming a set, hiding a claim platform-wide. A voter asked to
// approve an act named only by its code is being asked to approve a word.
//
// The wording comes from the constants' own comments in meta.gno, so there is
// one description of each verb and not two that can disagree.
func appealVerbGloss(verb string) string {
	switch verb {
	case verbUnhide:
		return "un-hides a claim its own court's moderators hid"
	case verbClear:
		return "clears a hide the review court itself placed"
	case verbHide:
		return "hides a claim across the platform, over its court's head"
	case verbSuspend:
		return "disarms a court's moderator set — they can take no further act"
	case verbUnsuspend:
		return "re-arms a suspended moderator set, and re-applies the hides that " +
			"were masked while it was disarmed"
	case verbSetmods:
		return "installs a moderator set on that court, replacing whoever holds " +
			"the seats now"
	}
	// Not reachable through AppealParse, which validates the verb — but a render
	// that invents a description for an unknown verb would be worse than one
	// that admits it does not know.
	return "an action this page does not recognise"
}
