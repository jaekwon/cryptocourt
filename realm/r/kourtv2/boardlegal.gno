// The board's legal lane: the two verbs a takedown needs, and the one that
// destroys text (docs/CLAIM_BOARDS.md §6.8).
//
// WHY A ROW-LEVEL PAIR AT ALL. GlobalHide and PurgeClaim are keyed to a CLAIM,
// so the DMCA answer to one infringing comment would be to redact the claim's
// title and every other comment on it — over-redaction as the only fast lane,
// which is how a notice about one row silences a whole discussion. And the
// courtMod row hide is discovery-only by design: the deep link still serves, so
// it does not "disable access" and is not the verb a notice asks for.
//
// TWO CODE SETS, AND THE SPLIT IS DELIBERATE. Editorial acts — hide, slash,
// freeze — take a CLOSED code from mustBoardCode: they target a person, MODERATION
// §6's mod-copy rule forbids assertions of fact about one, and there is no
// "claim-about-the-claim" phrasing available for "this address was slashed". The
// LEGAL acts here keep the length-bounded, extensible code the rest of the realm
// uses, because I11 requires the purge code set to stay shape-extensible before
// deploy and a closed switch on a write-once realm cannot record the first
// statutory category nobody anticipated.
package kourtv2

import "strconv"

// boardActCode is the code a board legal act writes into the moderation log.
//
// THE ROW ID GOES IN THE CODE, NOT THE REASON. PurgeModLogRow tombstones a log
// row's REASON, so an id kept there would be destroyed by the very verb whose
// job is removing text — and the log would then say a comment was redacted
// without saying which. The id is metadata about the act, not the offending
// text, so it belongs on the side that survives.
func boardActCode(verb string, rowID uint64, categoryCode string) string {
	code := verb + "#" + strconv.FormatUint(rowID, 10)
	if categoryCode != "" {
		code += ":" + categoryCode
	}
	return code
}

// The closed editorial set. A switch and not a length check: these are the codes
// that appear on a person's own page, so the vocabulary is the whole guarantee.
const (
	boardCodeSpam      = "spam"
	boardCodeOffTopic  = "off-topic"
	boardCodeAbuse     = "abuse"
	boardCodeImpersonation = "impersonation"
	boardCodeIllegal   = "illegal-referred"
)

// mustBoardCode refuses anything outside the set.
//
// THE FULL SET MUST EXIST BEFORE DEPLOY. Realms are write-once, so a category
// nobody anticipated cannot be added later — which is exactly why the LEGAL
// verbs below do not use this function. Adding a code here is a deploy, and that
// is the trade: a fixed vocabulary on the acts that name a person, an extensible
// one on the acts that answer a statute.
func mustBoardCode(code string) {
	switch code {
	case boardCodeSpam, boardCodeOffTopic, boardCodeAbuse,
		boardCodeImpersonation, boardCodeIllegal:
		return
	}
	panic("kourtv2: a board moderation code is one of: spam, off-topic, abuse, " +
		"impersonation, illegal-referred")
}

// BoardCodes is the vocabulary, for a client that has to offer it.
func BoardCodes() string {
	return boardCodeSpam + "," + boardCodeOffTopic + "," + boardCodeAbuse + "," +
		boardCodeImpersonation + "," + boardCodeIllegal
}

// GlobalHideRow withholds one comment's text on every surface — the deep link
// included, unlike an editorial hide.
//
// SINGLE KEY, for the speed a notice needs, and the same windowed m-of-n re-set
// GlobalHide carries: re-setting a redaction that a global act cleared inside the
// counter-notice window takes m-of-n, so one rogue key cannot win the reversal
// race and camp a row redacted.
func GlobalHideRow(cur realm, courtSlug string, claimID, rowID uint64, categoryCode string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	if !isGlobalMod(who) {
		panic("kourtv2: only a global DAO member may globally hide a comment")
	}
	checkReason(categoryCode)
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	r := mustBoardRow(cs, rowID)
	if r.purged {
		// The bytes are gone and there is no un-purge, so a redaction here cannot
		// change what anyone sees. Refused rather than accepted-and-inert: it
		// would otherwise arm the re-set window, record a redaction in the log,
		// and emit an event, all for an act with no effect. Same rule as the
		// upvote of a purged row (audit D3).
		panic("kourtv2: that comment was already destroyed; there is nothing to withhold")
	}
	now := heightNow()
	if !r.global && r.globalClearedAt != 0 && now < r.globalClearedAt+reSetWindowBlocks {
		d := ensureGlobalDAO()
		fire, _ := approveAction(d.pending,
			"boardreset:"+c.id+":"+strconv.FormatUint(claimID, 10)+":"+strconv.FormatUint(rowID, 10),
			who, categoryCode, d.purgeM)
		if !fire {
			return
		}
	}
	r.global = true
	// A redacted row leaves the ranked index: Top must not carry a rank for text
	// nobody may read. Newest keeps the stub, so enumeration survives.
	scoreIndexDrop(cs, r)
	// The log row is written LAST, once the act is certain — same reason
	// GlobalHide allocates its claimMod only after the m-of-n gate: a refused
	// call must not leave a row saying it happened.
	ensureClaimMod(c, ensureMod(c), claimID).
		appendLog(who, boardActCode("board-global-hide", rowID, categoryCode), "")
	emitGlobalAct(c.id, claimID, "board-global-hide", who)
}

// GlobalClearRow is the put-back, and it is the reason the pair exists.
//
// §512(g) restores THE SPECIFIC MATERIAL. GlobalClearBoardBits — a court-wide
// recovery verb — is not that: it answers capture, not a counter-notice. Without
// this, a wrongly-redacted row could only be restored by clearing every
// redaction in the court.
func GlobalClearRow(cur realm, courtSlug string, claimID, rowID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	if !isGlobalMod(who) {
		panic("kourtv2: only a global DAO member may clear a global comment hide")
	}
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	r := mustBoardRow(cs, rowID)
	if !r.global {
		panic("kourtv2: that comment is not globally hidden")
	}
	r.global = false
	r.globalClearedAt = heightNow() // arms the re-set window
	scoreIndexPut(cs, r)
	ensureClaimMod(c, ensureMod(c), claimID).
		appendLog(who, boardActCode("board-global-clear", rowID, ""), "")
	emitGlobalAct(c.id, claimID, "board-global-clear", who)
}

// PurgeBoardRow destroys one comment's text. m-of-n, global DAO, irreversible.
//
// IT ZEROES THE BYTES, and that is the difference from every other purge in this
// realm. Elsewhere purge sets a tombstone flag and the text stays in state, which
// is tolerable for a title; a board is an unbounded 2 KB-per-row surface under a
// runbook that says hosting-is-offence gets a purge within 72 hours, and leaving
// the bytes there does not discharge that. The row id, its author and its height
// remain, so the record still says a comment was here and who wrote it.
func PurgeBoardRow(cur realm, courtSlug string, claimID, rowID uint64, categoryCode string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	d := ensureGlobalDAO()
	if !d.members.Has(who.String()) {
		// Verbatim, and check-epoch-coherence arm 14 requires the exact string: every
		// purge verb in the realm speaks with one voice, so no new one can drift its
		// own gate past the census.
		panic("kourtv2: only a global DAO member may purge")
	}
	mustCategoryCode(categoryCode)
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	r := mustBoardRow(cs, rowID)
	if r.purged {
		// Already destroyed; a second purge is a no-op, not an error — the exact
		// rule PurgeModLogRow states for its own log. Checked BEFORE the vote, so
		// a repeat does not consume an m-of-n proposal or write a second log row
		// for an act that cannot change anything.
		return
	}
	fire, votedCode := approveAction(d.pending,
		"boardpurge:"+c.id+":"+strconv.FormatUint(claimID, 10)+":"+strconv.FormatUint(rowID, 10),
		who, categoryCode, d.purgeM)
	if !fire {
		return
	}
	r.purged = true
	r.text = "" // the bytes, not a flag
	scoreIndexDrop(cs, r)
	ensureClaimMod(c, ensureMod(c), claimID).
		appendLog(who, boardActCode("board-purge", rowID, votedCode), "")
	emitPurge(c.id, claimID, "board-row", who)
}

// BoardRowState is the row's withholding state as one character, for a client
// that has to say WHY a comment is not there: "." readable, "h" hidden by its
// author or a court mod, "g" withheld, "x" purged.
func BoardRowState(courtSlug string, claimID uint64, rowID uint64) string {
	return boardMark(mustBoardRow(mustClaim(mustCourt(courtSlug), claimID), rowID))
}

// maxBatchRows is what one transaction may destroy. The bound is the
// transaction, not the policy: a batch that does not fit is a batch that fails
// halfway and leaves nobody able to say which rows went.
const maxBatchRows = 64

// PurgeBoardRange destroys a claim's whole board, up to maxBatchRows at a time.
//
// WHY A RANGE VERB EXISTS AT ALL. §7.5 refuses a reclaim crank — hidden rows
// persist, because deleting them on a timer would delete the evidence a
// successor set needs, and because the chain refunds the storage deposit to
// whoever frees the state, which makes a permissionless deletion crank a
// standing bounty for censorship. The consequence carried forward was that a
// whole-court purge is vacuous for a board (it stops new rows, it does not touch
// the existing ones) while the existing set is reachable only one row at a time.
// A hosting-is-offence order against a 400-row board cannot be answered in 400
// transactions inside 72 hours.
//
// THE DECISION IS VOTED ONCE, THE COMPLETION IS NOT. The first call takes
// d.purgeM; it sets boardPurgeAll and then any global DAO member advances the
// cursor. m-of-n per batch would turn a 500-row board into eight coordinated
// votes against a clock, and the second vote decides nothing the first did not.
//
// Returns the row id to resume from, or 0 when the board is done.
func PurgeBoardRange(cur realm, courtSlug string, claimID, fromRowID uint64, categoryCode string) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	d := ensureGlobalDAO()
	if !d.members.Has(who.String()) {
		panic("kourtv2: only a global DAO member may purge")
	}
	mustCategoryCode(categoryCode)
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	cm := ensureMod(c)
	clm := lookupClaimMod(cm, claimID)
	if clm == nil || !clm.boardPurgeAll {
		fire, _ := approveAction(d.pending,
			"boardpurgeall:"+c.id+":"+strconv.FormatUint(claimID, 10),
			who, categoryCode, d.purgeM)
		if !fire {
			return fromRowID
		}
		clm = ensureClaimMod(c, cm, claimID)
		clm.boardPurgeAll = true
		// The court-level record of the ORDER, written once, so the page can say
		// a board is under a purge before the last batch has run.
		clm.appendLog(who, boardActCode("board-purge-all", 0, categoryCode), "")
		emitPurge(c.id, claimID, "board-all", who)
	}
	if cs.board == nil {
		return 0
	}
	// THE BOUND COUNTS WORK, NOT VISITS. Counting visits looks equivalent and is
	// not: a re-run over an already-purged board would hit the bound at row 65
	// and report a resume cursor forever, so "done" was unreachable for any board
	// over one batch. Skipping a purged row costs a visit and no write, and the
	// walk is bounded anyway — maxBoardRowsPerClaim caps a board at 512 rows.
	n, next := 0, uint64(0)
	cs.board.Iterate(beClaimKey(fromRowID), "", func(_ string, v any) bool {
		r := v.(*boardRow)
		if r.purged {
			return false
		}
		if n >= maxBatchRows {
			next = r.id // where the next call resumes; nothing is skipped
			return true
		}
		r.purged = true
		r.text = "" // the bytes, not a flag
		scoreIndexDrop(cs, r)
		n++
		return false
	})
	return next
}

// BoardPurgeOrdered reports whether a claim's whole board is under a purge order
// — true from the first batch, so the page does not have to wait for the last.
func BoardPurgeOrdered(courtSlug string, claimID uint64) bool {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return false
	}
	clm := lookupClaimMod(c.mod, claimID)
	return clm != nil && clm.boardPurgeAll
}
