// Render: the claim page IS the product (PLAN §3.9/§11). Three ratio series,
// no "backing" anywhere (burned GNOT backs nothing), sealed tallies once votes
// exist, absolute CC figures only — never percentages of return, never the
// inflation ceiling (§7.4). Every user string passes the sanitizer.
package kourtv2

import (
	"strconv"
	"strings"

	sanitize "gno.land/p/nt/markdown/sanitize/v0"
)

// Render routes:
//
//	""                    the directory
//	"<slug>"              one court
//	"<slug>/<id>"         one claim
//	"<slug>/folder/<fid>" one folder
//	"<slug>/election"     the moderator ballot
//	"<slug>/<id>/<addr>"  one address's positions on a claim ("your page")
func Render(path string) string {
	// An armed test clock fabricates every date below. Say so on EVERY page,
	// first thing: an accessor nobody reads is not a disclosure, and gnoweb
	// serves this output directly to readers who have no other signal.
	// The overlay header sits beside the clock banner and for the same reason: a
	// disclosure that appears on some pages and not others is one a reader cannot
	// rely on. Empty when no domain is configured (sitelink.gno), so a realm with
	// no website renders exactly as it always did.
	return testClockBanner() + siteBanner(path) + render(path)
}

// testClockBanner is empty on any ordinary chain.
func testClockBanner() string {
	if !TestClockFabricated() {
		return ""
	}
	// Keyed on Fabricated, not Active: a SEALED test chain can no longer be
	// driven but is still full of invented dates, and that is precisely when a
	// reader is most likely to mistake it for a real one.
	// No longer claims heights are real: the override covers height too, so a
	// test chain's block numbers are as fabricated as its dates.
	tail := " Balances are real."
	if !TestClockActive() {
		// Says what sealing does to the FUTURE, not only to the past. Sealing
		// drops the skew but keeps a floor, so both clocks sit at that floor
		// until real time and real height catch up — up to a century and up to
		// ten weeks of blocks. Anything opened after the seal is stamped at the
		// floor and its windows are never reached. "Fixed history" was true and
		// silent about exactly the part a reader would act on.
		tail = " The clock is now sealed: these dates are fixed history, and" +
			" this chain's clock stays stopped until the real one catches up," +
			" so nothing opened from here will reach a deadline. Balances are real."
	}
	// A chain whose HEIGHT was moved but whose calendar was not would otherwise
	// read "advanced 0 seconds", which says nothing was moved at all — while
	// conviction, emission and every trailing average on the page came from a
	// block count the scenario handed the chain.
	moved := strconv.FormatInt(TestClockPeakSkew(), 10) + " seconds"
	if h := TestHeightPeakSkew(); h > 0 {
		moved += " and " + strconv.FormatInt(h, 10) + " blocks"
	}
	return "> **Test chain — the dates on this page are fabricated.** Its clock was " +
		"set by the deployer and advanced " + moved + "." + tail + "\n\n"
}

func render(path string) string {
	path = strings.Trim(path, "/")
	if path == "" {
		return renderDirectory()
	}
	// FOUR, not three. The cap used to be the thing that refused a fourth
	// segment — it folded into the address argument and IsValid() rejected it —
	// and the board's per-row deep link needs a fourth, so the refusal moved to
	// an explicit arm below. `<slug>/<id>/<addr>/extra` still renders "Not
	// found"; it is a different line that says so.
	parts := strings.SplitN(path, "/", 4)
	if len(parts) == 1 {
		// The help page, carved before the court arm. It cannot shadow a court:
		// a slug is at most 11 characters and this path is 12, so the two sets
		// are disjoint by construction rather than by a reserved word somebody
		// has to remember to keep reserved (help.gno).
		if parts[0] == helpPath {
			return renderHelp()
		}
		return renderCourt(parts[0])
	}
	// The moderation log is a named sub-route, so it must be carved out BEFORE
	// the numeric-id parse below (MODERATION.md §4).
	if parts[1] == "mod" {
		return renderModLog(parts[0])
	}
	// The standing page carves at the same position and for the same reason. A
	// slug is [a-z0-9-]{1,11} so a court MAY be called "me", but that occupies
	// parts[0]; and a claim id is numeric, so "me" can never be mistaken for one.
	// FOLDERS, which rendered NOWHERE. A court's moderators can build a whole
	// filing tree — seven verbs, an events filetest, its own mutation rows — and
	// no page in this realm ever drew one. Same defect the board had: a feature
	// that exists, is written to, and is unreachable by anybody who is not
	// running the overlay. Carved here for the reason "mod" and "me" are carved
	// here: a folder id is numeric, so the word can never be taken for a claim.
	// THE BALLOT, which rendered nowhere at all — fourteen entrypoints and no
	// page (docs §21). Carved beside "mod" and "me" for the same reason: a claim
	// id is numeric, so a word can never be taken for one.
	if parts[1] == electionPath {
		if len(parts) != 2 {
			return "## Not found\nThe ballot is /<court>/election."
		}
		return renderElection(parts[0])
	}
	if parts[1] == "folder" {
		if len(parts) != 3 {
			return "## Not found\nA folder is /<court>/folder/<id>."
		}
		fid, ferr := strconv.ParseUint(parts[2], 10, 64)
		if ferr != nil {
			return "## Not found\nA folder id must be a number."
		}
		return renderFolderPage(parts[0], fid)
	}
	if parts[1] == "me" {
		if len(parts) == 3 {
			return renderStanding(parts[0], parts[2])
		}
		return renderStandingIndex(parts[0])
	}
	id, err := strconv.ParseUint(parts[1], 10, 64)
	if err != nil {
		return "## Not found\nA claim id must be a number."
	}
	// The board: a page at three segments, one row at four. Carved BEFORE the
	// positions arm, and deliberately without touching that arm's text — two
	// mutation rows anchor on it verbatim, and an edit there would leave them
	// measuring nothing.
	if len(parts) >= 3 && parts[2] == "board" {
		if len(parts) == 4 {
			// "top" is the ranked VIEW of the same board, carved before the
			// numeric parse for the reason "mod" and "me" are: a row id is
			// numeric, so a word can never be mistaken for one.
			if parts[3] == "top" {
				return renderBoardTop(parts[0], id)
			}
			return renderBoardRow(parts[0], id, parts[3])
		}
		return renderBoardPage(parts[0], id)
	}
	if len(parts) == 4 {
		return "## Not found\nThat is not a page."
	}
	if len(parts) == 3 {
		return renderPositions(parts[0], id, parts[2])
	}
	return renderClaim(parts[0], id)
}

func renderDirectory() string {
	b := strings.Builder{}
	b.WriteString("# " + platformName + "\n\nStake on claims of fact. Your principal always returns 1×.\n\n")
	// THE WAY IN, on the page every stranger lands on first. Read cold, the
	// lede above is two pieces of vocabulary ("stake", "principal returns 1×")
	// and then a list of court names — nothing that says what any of it is. The
	// explanation existed only in docs/ and in the overlay, neither of which a
	// gnoweb reader can reach from here.
	b.WriteString(helpLink + "\n\n")
	afterHeader := b.Len()
	writeTier(&b, "Featured", tierFeatured)
	// The listed tier ranks by cumulative GNOT burned into each court — the one
	// signal nobody can fake, so the front page needs no gameable activity or
	// vote score (MODERATION.md §3.2).
	writeListedByBurn(&b)
	if b.Len() == afterHeader {
		b.WriteString("_No courts yet._\n")
	}
	return b.String()
}

func writeListedByBurn(b *strings.Builder) {
	slugs := listedPage("burn", 0, renderPageSize)
	if len(slugs) == 0 {
		return
	}
	b.WriteString("## Courts\n\n")
	shown := 0
	for _, s := range slugs {
		c := mustCourt(s)
		if c.tier != tierListed {
			continue
		}
		shown++
		b.WriteString("- [" + courtNameFor(c) + "](/r/kourt/kourtv2:" + s + ") · " +
			qualifiedSymbol(c) + " — " + strconv.FormatUint(c.nextID, 10) + " claims\n")
	}
	// A CAPPED LIST MUST SAY WHAT IT DROPPED. writeTier has always announced its
	// omissions; when the listed tier moved to burn-ranking it stopped, and a
	// silently truncated directory reads as the whole directory — a court past
	// row 50 looks like it does not exist. Counted against the live tier rather
	// than the page, because the page is what was capped.
	if total := len(ListByTier(int(tierListed))); total > shown {
		b.WriteString("- _…and " + strconv.Itoa(total-shown) +
			" more; open any court directly at /r/kourt/kourtv2:<slug>_\n")
	}
	b.WriteString("\n")
}

// renderPageSize bounds every render loop to a constant so a page's gas cost
// cannot grow with the (attacker-openable, deposit-priced) claim or court
// count (audit N3). Deep links (…/<slug>, …/<slug>/<id>) reach anything the
// capped list omits.
const renderPageSize = 50

func writeTier(b *strings.Builder, heading string, tier uint8) {
	slugs := ListByTier(int(tier))
	if len(slugs) == 0 {
		return
	}
	b.WriteString("## " + heading + "\n\n")
	shown := len(slugs)
	if shown > renderPageSize {
		shown = renderPageSize
	}
	for _, s := range slugs[:shown] {
		c := mustCourt(s)
		b.WriteString("- [" + courtNameFor(c) + "](/r/kourt/kourtv2:" + s + ") · " +
			qualifiedSymbol(c) + " — " + strconv.FormatUint(c.nextID, 10) + " claims\n")
	}
	if len(slugs) > shown {
		b.WriteString("- _…and " + strconv.Itoa(len(slugs)-shown) +
			" more; open any court directly at /r/kourt/kourtv2:<slug>_\n")
	}
	b.WriteString("\n")
}

func renderCourt(slug string) string {
	if !Exists(slug) {
		return "## Not found\nNo court by that slug."
	}
	c := mustCourt(slug)
	b := strings.Builder{}
	b.WriteString("# " + courtNameFor(c) + "\n\n")
	// DELISTED, SAID OUT LOUD. A global DAO member may set a court to
	// tierHidden, which removes it from the directory and from every listing
	// read — and no page said so. A hidden CLAIM gets one of four banners naming
	// the authority that hid it; a hidden COURT got silence, so its creator and
	// its holders watched it disappear from the front page with nothing anywhere
	// to tell them it had been an act rather than a bug.
	//
	// The wording follows the claim's meta banner, because the situation is the
	// same one: listed nowhere, reachable here, lifecycle untouched. That last
	// part matters most — a delisted court still settles its claims and pays out.
	if c.tier == tierHidden {
		b.WriteString("> **Delisted by the global DAO.** This court appears in no " +
			"listing and is reachable only by direct link. Nothing else changes: " +
			"its claims still stake, answer, settle and pay out as usual.\n\n")
	}
	if d := courtDescFor(c); d != "" {
		b.WriteString(d + "\n\n")
	}
	// The filing tree, as ONE LINE of links rather than a section. It is
	// navigation — a way INTO the claims — so it belongs above them; and it is
	// one line so that putting it there does not re-create the thing the coin
	// block was moved out of the way for.
	writeFolderIndex(&b, c, slug)
	// THE CLAIMS FIRST. Four lines of coin plumbing used to sit here, between a
	// reader and the only thing on this page they arrived for. Read cold,
	// "supply: 5108592379 · emitted: 0" and "reward reservoir: 0 · senior queue
	// owed: 0" are not an introduction to a court — they are the accounting of
	// one, which is a thing you want AFTER you have decided to care. It is all
	// still here, below the claims, where writeCourtCoin puts it.
	b.WriteString("## Claims\n\n")
	if c.nextID == 0 {
		b.WriteString("_No claims yet._\n\n")
		// Still shown on an empty court: the coin exists from the moment the
		// court does, and its price is exactly what somebody deciding whether
		// to be early wants to see.
		writeCourtCoin(&b, c)
		return b.String()
	}
	// Newest first, bounded to one page (audit N3): a court with thousands of
	// deposit-priced claims must not make its page cost unbounded. Older claims
	// stay reachable by direct id link.
	lo := uint64(1)
	if c.nextID > renderPageSize {
		lo = c.nextID - renderPageSize + 1
	}
	for id := c.nextID; id >= lo; id-- {
		cs := mustClaim(c, id)
		// The ONE place a hide bit subtracts: ordinary discovery listings. The
		// claim stays reachable by deep link, and if it is still policeable it
		// stays on the "needs review" strip below (§5.3).
		if HiddenFromListing(slug, id) {
			continue
		}
		b.WriteString("- [" + claimTitleFor(c, cs) + "](/r/kourt/kourtv2:" + slug + "/" +
			strconv.FormatUint(id, 10) + ") — " + claimStatus(cs) + "\n")
	}
	if lo > 1 {
		b.WriteString("- _…and " + strconv.FormatUint(lo-1, 10) +
			" older; open any by id at /r/kourt/kourtv2:" + slug + "/<id>_\n")
	}
	b.WriteString("\n")
	writeStrip(&b, slug)
	writePending(&b, slug)
	writeCourtCoin(&b, c)
	b.WriteString("[Moderation log](/r/kourt/kourtv2:" + slug + "/mod)\n")
	return b.String()
}

// writeCourtCoin is the court's accounting, below the claims rather than above
// them.
//
// EVERY LINE CARRIES ITS OWN GLOSS. These are the realm's four house terms —
// supply, emitted, reservoir, senior queue — and each was printed as a bare
// label beside a ten-digit number. A number whose name you do not know is worse
// than no number: it reads as something you are failing to understand rather
// than something nobody told you. The gloss is short and in the same sentence,
// because a legend somewhere else is a legend nobody reads.
func writeCourtCoin(b *strings.Builder, c *Court) {
	b.WriteString("## This court's coin\n\n")
	b.WriteString("- " + qualifiedSymbol(c) +
		" — this court's own coin, not interchangeable with any other court's\n")
	b.WriteString("- price: " + strconv.FormatInt(c.crv.Price(c.minted), 10) +
		" ugnot per coin — buying burns the GNOT, there is no sell side, " +
		"and the price only rises\n")
	b.WriteString("- in circulation: " + strconv.FormatInt(c.coin.TotalSupply(), 10) +
		" · paid out as rewards so far: " + strconv.FormatInt(c.emittedTotal, 10) + "\n")
	b.WriteString("- reward reservoir: " + strconv.FormatInt(c.reservoirR(), 10) +
		" waiting to be earned · " + strconv.FormatInt(c.seniorOwed, 10) +
		" already owed to earlier earners\n\n")
	b.WriteString(helpLink + "\n\n")
}

func renderClaim(slug string, id uint64) string {
	if !Exists(slug) {
		return "## Not found\nNo court by that slug."
	}
	c := mustCourt(slug)
	if id == 0 || id > c.nextID {
		return "## Not found\nNo claim by that id."
	}
	cs := mustClaim(c, id)
	b := strings.Builder{}
	// A deep link ALWAYS renders — hiding removes a claim from lists, never from
	// its own page — with a banner naming the authority. Text itself is withheld
	// only by the global (legal-hold) bit or a purge, and even then IDs, state,
	// deadlines and balances still render so a participant can always act.
	b.WriteString("# " + claimTitleFor(c, cs) + "\n\n")
	// The author's own statement of what the claim means, above the money. It is
	// gated by claimBodyFor, so a purged or globally-redacted claim prints nothing
	// here — and it goes ABOVE the banner because a reader deciding whether to
	// stake should read the question before the state of the market on it.
	if body := claimBodyQuoted(c, cs); body != "" {
		b.WriteString(body)
	}
	b.WriteString(hideBanner(c, cs))
	// THE BOARD, LINKED FROM THE CLAIM. It had no link from anywhere: the route
	// existed and the only way to reach it was to type the URL, so every comment
	// ever written was on a page nobody could navigate to.
	writeRelations(&b, c, id)
	writeBoardLink(&b, c, cs, id)
	writeAppeal(&b, c, cs)
	if cs.seeded {
		b.WriteString("_Seeded by a moderator to start this court; the author earns nothing from it._\n\n")
	}

	b.WriteString("## Signal\n\n")
	// ANSWERED CLAIMS SHOW THE RECORD, NOT THE REMAINDER. The live counters are
	// decremented as principal is withdrawn, so a settled claim's page used to
	// converge on "YES 0 / NO 0" — the drained value, displayed as though it were
	// the history. The frozen pair is what the claim was actually answered on.
	if cs.frozenAt != 0 {
		fTotal := cs.yesStakeAtFreeze + cs.noStakeAtFreeze
		b.WriteString("- staked when answered: " + strconv.FormatInt(fTotal, 10) +
			" " + qualifiedSymbol(c) + " (YES " + strconv.FormatInt(cs.yesStakeAtFreeze, 10) +
			" / NO " + strconv.FormatInt(cs.noStakeAtFreeze, 10) + ")\n")
		if fTotal > 0 {
			b.WriteString("- lean when answered: " + pct(cs.yesStakeAtFreeze, fTotal) + " YES\n")
		}
		if live := cs.yesStake + cs.noStake; live > 0 {
			b.WriteString("- still unwithdrawn: " + strconv.FormatInt(live, 10) +
				" " + qualifiedSymbol(c) + "\n")
		}
	} else {
		total := cs.yesStake + cs.noStake
		b.WriteString("- staked now: " + strconv.FormatInt(total, 10) +
			" " + qualifiedSymbol(c) + " (YES " + strconv.FormatInt(cs.yesStake, 10) +
			" / NO " + strconv.FormatInt(cs.noStake, 10) + ")\n")
		if total > 0 {
			b.WriteString("- instantaneous: " + pct(cs.yesStake, total) + " YES\n")
		}
	}
	h := heightNow()
	if yAvg, ym := cs.yes.Average(h, periodBlocks); ym {
		if tAvg, tm := cs.oi.Average(h, periodBlocks); tm && tAvg > 0 {
			b.WriteString("- trailing week: " + pct(yAvg, tAvg) + " YES\n")
		}
	}
	yc := convToCC(cs.yesConvHi, cs.yesConvLo)
	nc := convToCC(cs.noConvHi, cs.noConvLo)
	if yc+nc > 0 {
		// The conviction-weighted lifetime ratio — the series a manipulator can
		// move only by paying capital-time (F9).
		b.WriteString("- lifetime conviction: " + pct(yc, yc+nc) + " YES\n")
	}
	b.WriteString("\n## Status\n\n" + claimStatus(cs) + "\n")
	if cs.frozenAt != 0 {
		b.WriteString("\n## Resolution\n\n")
		b.WriteString("- answer: " + sideName(int(cs.answer)) + " (bond " +
			strconv.FormatInt(cs.answerBond0, 10) + " " + qualifiedSymbol(c) + ")\n")
		// The answerer's track record — contested-and-upheld answers only, so a
		// high number is hard-won signal, not volume (P13). If the court's
		// priority gate is armed, a record ≥ threshold earns a 24h head start.
		b.WriteString("- the answerer has been challenged and upheld " +
			strconv.FormatInt(int64(AnswerRecord(slug, cs.answerer)), 10) +
			" time(s) in this court — answers nobody contested do not count\n")
		if PriorityGateActive(slug) {
			b.WriteString("- answer priority is live here — a record of " +
				strconv.FormatInt(int64(priorityNetRecord), 10) +
				"+ earns a 24h head start on new claims\n")
		}
		if cs.failedRounds > 0 {
			b.WriteString("- failed dispute rounds: " + strconv.FormatInt(cs.failedRounds, 10) +
				" of " + strconv.FormatInt(int64(maxFailedRounds), 10) +
				" — the next dispute bond doubles\n")
		}
		if cs.disputeOpen {
			// The sealed-tally rule: an open vote renders NO running count.
			b.WriteString("- dispute round " + strconv.FormatInt(cs.round, 10) +
				" vote open — the tally is sealed until the vote closes\n")
		} else if cs.verdictAt == 0 {
			// Disputable: show what contesting the answer costs right now, so a
			// user can weigh it without simulating the bond formula themselves.
			// The bond doubles each failed round (reflected as rounds accrue).
			b.WriteString("- disputing this answer costs a bond of " +
				strconv.FormatInt(cs.disputeBond0(), 10) + " " + qualifiedSymbol(c) +
				", doubling for each round that fails to reach a quorum\n")
			b.WriteString("  - win and the answerer's bond is burned and you are " +
				"compensated, up to twice your own bond; lose and yours burns " +
				"instead. Nothing passes between the two of you — a forfeit is " +
				"burned, a compensation is newly issued\n")
			b.WriteString("  - if the round draws no quorum, half your bond burns " +
				"and half returns; three such rounds close the claim undecided, " +
				"with every stake out at 1× and the deposit and fee refunded\n")
			// THE SENTENCE THAT MATTERS MOST, and the one the 1× guarantee makes
			// true: a dispute risks the BOND and never the stake. Without it a
			// reader weighing a dispute has to assume their position is exposed.
			b.WriteString("  - **your stake is not at risk either way** — only the " +
				"bond is\n")
		}
		if cs.verdictAt != 0 && !cs.provClose {
			b.WriteString("- verdict: " + sideName(int(cs.provisional)) + " — " + cs.route + "\n")
		}
		// Quality: the tier and the flag slot. The tally itself stays sealed.
		//
		// UNRATED IS NOT LOW, and printing it as low was expensive. cs.tier is
		// the ZERO VALUE — which is tierLowX — until a settle or a finalize
		// writes mid, so every answered-but-unsettled claim rendered
		// "quality: low". And the tier is a payout MULTIPLIER: crystallize
		// computes `want = tier × midGross`, and tierLowX is 0. So the page told
		// the answerer and every staker that the claim currently pays NOTHING,
		// when its actual outcome absent a flag vote is mid — full pay.
		//
		// A genuine low is distinguishable: quality.gno lands a voted tier and
		// sets slotConsumed in the same block, so low-and-unconsumed can only be
		// the untouched zero.
		//
		// "default" was also the wrong word for the unfinalised case: it reads as
		// "low is the default" when it means "this rating is not settled yet".
		var q string
		switch {
		case cs.tierFinal:
			q = "quality: " + tierName(cs.tier) + " (final)"
		case cs.tier == tierLowX && !cs.slotConsumed:
			q = "quality: not yet rated — mid unless a quality vote lowers it"
		default:
			q = "quality: " + tierName(cs.tier) +
				" (not final; a quality vote can still change it)"
		}
		b.WriteString("- " + q + "\n")
		// WHAT THE RATING IS FOR, which no surface said. A reader who does not
		// know the tier multiplies the reward reads "low" as an editorial
		// opinion of the claim rather than as the difference between being paid
		// and not.
		b.WriteString("- the rating sets what this claim pays: **low pays " +
			"nothing**, mid pays the full amount, high pays double\n")
		switch {
		case cs.flagOpen:
			b.WriteString("- flag vote open — the tally is sealed until it closes\n")
		case cs.counterOpen:
			b.WriteString("- counter re-vote open — the tally is sealed until it closes\n")
		case cs.pendingSlash > 0:
			b.WriteString("- a slash is escrowed in its counter-flag window\n")
		case !cs.crystallized && !cs.slotConsumed && !cs.provClose:
			b.WriteString("- anyone may challenge that rating once, by posting a " +
				"bond of " + strconv.FormatInt(flagBondFor(cs), 10) + " " +
				qualifiedSymbol(c) + " and calling a vote on it\n")
		}
		if cs.crystallized {
			w, a, ans, carrot := cs.drawWinners, cs.drawAuthor, cs.drawAnswerer, cs.carrotPool
			b.WriteString("- rewards crystallized — pools (" + qualifiedSymbol(c) +
				"): accuracy " + strconv.FormatInt(w, 10) +
				", author " + strconv.FormatInt(a, 10) + ", answerer " + strconv.FormatInt(ans, 10) +
				", participation remaining " + strconv.FormatInt(carrot, 10) + "\n")
		}
	}
	b.WriteString("\n_To see your own stake on this claim, put your address on " +
		"the end of this page's path:_ `/r/kourt/kourtv2:" + sanitize.InlineText(slug) +
		"/" + strconv.FormatUint(id, 10) + "/<your address>`\n")
	return b.String()
}

// renderPositions is the per-address "your page" for one claim (§11): live
// principal per side, durable conviction (the reward weight), the caller's
// roles, and lifecycle hints on what is withdrawable. Read-only — it composes
// existing reads and never re-derives the money math the pull entrypoints own.
func renderPositions(slug string, id uint64, addrStr string) string {
	if !Exists(slug) {
		return "## Not found\nNo court by that slug."
	}
	c := mustCourt(slug)
	if id == 0 || id > c.nextID {
		return "## Not found\nNo claim by that id."
	}
	who := address(addrStr)
	if !who.IsValid() {
		return "## Not found\nThat is not a valid address."
	}
	cs := mustClaim(c, id)

	b := strings.Builder{}
	b.WriteString("# Positions on this claim\n\n")
	// Through the SAME text gate as every other surface, with the banner: this
	// route (…/<slug>/<id>/<addr>, reachable with any address string) was the one
	// render path that bypassed it, so a purged claim's text stayed publicly
	// readable and purge — the legal-compliance power — did not actually reach
	// "every surface".
	b.WriteString(hideBanner(c, cs))
	b.WriteString("Claim: [" + claimTitleFor(c, cs) + "](/r/kourt/kourtv2:" + slug +
		"/" + strconv.FormatUint(id, 10) + ") in [" + courtNameFor(c) +
		"](/r/kourt/kourtv2:" + slug + ")\n\n")
	b.WriteString("Address: " + sanitize.InlineText(addrStr) + "\n\n")

	yStake := StakeOf(slug, id, sideYES, who)
	nStake := StakeOf(slug, id, sideNO, who)
	yConv := ConvictionOf(slug, id, sideYES, who)
	nConv := ConvictionOf(slug, id, sideNO, who)
	b.WriteString("## Stake (live principal, always returns 1×)\n\n")
	b.WriteString("- YES: " + strconv.FormatInt(yStake, 10) +
		"   NO: " + strconv.FormatInt(nStake, 10) + " (" + qualifiedSymbol(c) +
		" base units)\n")
	b.WriteString("- conviction so far — YES: " + strconv.FormatInt(yConv, 10) +
		"   NO: " + strconv.FormatInt(nConv, 10) + " (the reward weight)\n")

	// The wallet-level picture, which nothing rendered before staking became a
	// lock in place. It matters now for a reason that is invisible from the
	// balance alone: staked CC STAYS in the holder's balance and keeps voting, so
	// a client showing only the balance tells someone they have coins to bond
	// when those coins are already committed, and the refusal then reads as a bug
	// in the realm rather than as the arithmetic it is.
	//
	// COURT-WIDE, not claim-scoped, and labelled as such — the numbers above are
	// this claim's, these are every claim in this court plus any live bond, so
	// showing them side by side without saying which is which would be worse than
	// showing neither.
	// TWO "free" FIGURES, NOT ONE, because there are two gates and they answer
	// different questions. A stake draws on spendable() through mustStakable: it
	// moves nothing, so a pending vote is no reason to refuse it. Everything else —
	// a deposit, a bond, a transfer, a wrap — draws on disposable() through
	// mustSpendable, which nets out the vote lock as well.
	//
	// This line used to read "free to commit: <spendable> — what a new stake,
	// deposit or bond draws on", which was one number wearing three labels. After
	// the vote lock it told a voter they had coin free for a bond that would be
	// refused, and named the wrong gate for two of the three uses.
	//
	// The PARTITION the test cares about survives, twice over:
	//   held = committed as stake     + free to stake
	//   held = max(stake, voting)     + free to bond/deposit/transfer
	// The two locks OVERLAP rather than stack — staked coin still votes, so one
	// pile can answer to both — which is why the second row is a max and not a sum.
	bal := c.coin.BalanceOf(who)
	locked := lockedOf(c, who)
	voted := voteLockedOf(c, who)
	b.WriteString("\n## This address's " + qualifiedSymbol(c) +
		" in this court (all claims)\n\n")
	b.WriteString("- held: " + strconv.FormatInt(bal, 10) +
		" — every unit votes, committed or not\n")
	b.WriteString("- committed as stake: " + strconv.FormatInt(locked, 10) + "\n")
	b.WriteString("- committed by voting: " + strconv.FormatInt(voted, 10) +
		" — until each question resolves\n")
	b.WriteString("- free to stake: " + strconv.FormatInt(spendable(c, who), 10) + "\n")
	b.WriteString("- free to bond, deposit or transfer: " +
		strconv.FormatInt(disposable(c, who), 10) + "\n")

	// Roles on this claim.
	roles := ""
	if who == cs.author {
		roles += "author "
	}
	if cs.frozenAt != 0 && who == cs.answerer {
		roles += "answerer "
	}
	if roles != "" {
		b.WriteString("- roles: " + roles + "\n")
	}
	if rec := AnswerRecord(slug, who); rec > 0 {
		b.WriteString("- difficulty record (this court): " + strconv.FormatInt(int64(rec), 10) + "\n")
	}

	// Lifecycle hints — what to do next. No amounts (the pulls compute those).
	b.WriteString("\n## What you can do\n\n")
	switch {
	case cs.verdictAt == 0 && cs.frozenAt == 0:
		b.WriteString("- staking is open — stake or unstake freely until an answer posts\n")
	case cs.verdictAt == 0:
		b.WriteString("- answered, awaiting the verdict — principal is never withheld; withdraw once it is final\n")
	default:
		b.WriteString("- the verdict is final — withdraw your principal on either side (1×)\n")
		if cs.crystallized {
			win := int(cs.provisional)
			if !cs.provClose && ((win == sideYES && yStake+yConv > 0) || (win == sideNO && nStake+nConv > 0)) {
				b.WriteString("- you backed the winning side — pull your accuracy reward\n")
			}
			if who == cs.author && cs.drawAuthor > 0 {
				b.WriteString("- author reward available — pull it\n")
			}
			if who == cs.answerer && cs.drawAnswerer > 0 {
				b.WriteString("- answerer reward available — pull it\n")
			}
		}
	}
	return b.String()
}

func tierName(tier int64) string {
	switch tier {
	case tierLowX:
		return "low"
	case tierHighX:
		return "high"
	default:
		return "mid"
	}
}

func sideName(side int) string {
	if side == sideYES {
		return "YES"
	}
	return "NO"
}

// ClaimStatus is the human one-line lifecycle status for a claim — the exact
// text the claim page shows — exposed so a client gets it in ONE qeval instead
// of reconstructing the phase precedence from a half-dozen reads.
func ClaimStatus(courtSlug string, claimID uint64) string {
	return claimStatus(mustClaim(mustCourt(courtSlug), claimID))
}

// claimStatus is the one-line lifecycle readout. It grows verdict/tier/route
// lines as those modules land; the sealed-tally rule (never a running count)
// binds every future addition.
func claimStatus(cs *claimState) string {
	switch {
	case cs.closed:
		return "closed — never answered; every stake exited 1×, the deposit refunded"
	case cs.provClose:
		return "closed without a decision — three dispute rounds failed quorum; everyone withdraws 1×, deposit and fee refunded"
	case cs.verdictAt != 0:
		// NAMING THE SIDE IS THE WHOLE POINT OF A VERDICT. This line said only
		// "settled" for a long time, so a settled-YES claim and a settled-NO claim
		// read identically on every client that shows a one-line status — while the
		// PROVISIONAL case two branches down has always named its side. The overlay
		// had to ask Verdict() per settled claim to recover what the status already
		// knew.
		//
		// provisional IS the verdict here, and this reads it under exactly the guard
		// Verdict() uses: verdictAt != 0 and not provClose, which the case above
		// already took. It cannot be -1 in this branch — settle-undisputed writes
		// provisional = answer beside verdictAt, and Finalize's only route in
		// requires escrowUntil, which is written after a resolution has set
		// provisional. TestBothSettleRoutesNameTheVerdictSide pins both.
		return "settled " + sideName(int(cs.provisional)) + " — every stake withdraws 1×"
	case cs.disputeOpen:
		return "disputed — a sealed vote is deciding; principal is never withheld"
	case cs.provisional >= 0:
		return "provisional verdict " + sideName(int(cs.provisional)) +
			" — reopenable by a new dispute until block " + strconv.FormatInt(cs.escrowUntil, 10) +
			"; the side it is against may withdraw 1× now"
	case cs.frozenAt != 0:
		return "answered " + sideName(int(cs.answer)) +
			" — staking frozen; disputable until block " +
			strconv.FormatInt(cs.answerHeight+settleDelay, 10) + ", then it settles undisputed"
	default:
		return "open — stake YES or NO; unstake freely until an answer posts"
	}
}

// pct renders a basis-point-precision percentage from two int64s. num can be a
// conviction-CC value, which is stake×TIME and so NOT bounded by supply — a bare
// num*10000 wraps for a whale on a long-open claim (math-audit MED-1). The
// 128-bit intermediate is overflow-proof (num ≤ den here, so bps ≤ 10000).
func pct(num, den int64) string {
	if den <= 0 || num < 0 {
		return "—"
	}
	bps := mulDiv128(num, 10000, den)
	return strconv.FormatInt(bps/100, 10) + "." + pad2(bps%100) + "%"
}

func pad2(v int64) string {
	if v < 10 {
		return "0" + strconv.FormatInt(v, 10)
	}
	return strconv.FormatInt(v, 10)
}

// writeFolderIndex is the court's root folders, on one line, or nothing at all.
//
// Retired and purged headings are skipped: a retired folder is one a moderator
// struck from the tree, and a purged one has had its name erased rather than
// flagged, so there is no name to print. Both still occupy an id — the overlay
// walks 1..FolderCount and calls that contiguity load-bearing — which is why
// this filters on the rows instead of on the count.
func writeFolderIndex(b *strings.Builder, c *Court, slug string) {
	if c.mod == nil {
		return
	}
	shown := 0
	for _, f := range c.mod.folderRows() {
		if f.parent != 0 || f.retired || f.purged {
			continue
		}
		if shown == 0 {
			b.WriteString("Filed under: ")
		} else {
			b.WriteString(" · ")
		}
		b.WriteString("[" + sanitize.InlineText(f.name) + "](/r/kourt/kourtv2:" +
			slug + "/folder/" + strconv.FormatUint(f.id, 10) + ")")
		shown++
	}
	if shown > 0 {
		b.WriteString("\n\n")
	}
}

// renderFolderPage draws one heading: what is under it, and what is filed in it.
//
// A FOLDER CURATES AND CAN NEVER BURY — that is the founding promise of this
// module, and it is why this page is safe to render at all. Every claim here is
// also on the court's flat newest-first docket; nothing is reachable only
// through a folder, so a moderator cannot use the filing tree to make a claim
// hard to find. The page says so, because a reader looking at somebody else's
// organisation of a contested subject is entitled to know it is not the only way
// in.
func renderFolderPage(slug string, fid uint64) string {
	if !Exists(slug) {
		return "## Not found\nNo court by that slug."
	}
	c := mustCourt(slug)
	if c.mod == nil {
		return "## Not found\nThis court has no folders."
	}
	v := c.mod.folders.Get(beClaimKey(fid))
	if v == nil {
		return "## Not found\nNo folder by that id."
	}
	f := v.(*folder)
	base := "/r/kourt/kourtv2:" + slug
	var b strings.Builder
	// A PURGED HEADING STILL RENDERS, as a tombstone naming the authority — the
	// same posture a purged claim's own page takes. A page that 404s instead
	// would make a purge indistinguishable from a folder that never existed.
	if f.purged {
		b.WriteString("# [purged:" + sanitize.InlineText(f.code) + "]\n\n")
		b.WriteString("_This heading was purged by the global DAO. Its name and " +
			"description were erased, not hidden._\n\n")
		b.WriteString("[← " + courtNameFor(c) + "](" + base + ")\n")
		return b.String()
	}
	b.WriteString("# " + sanitize.InlineText(f.name) + "\n\n")
	// The breadcrumb walks up, so a nested heading says where it sits rather
	// than stranding a reader who arrived by deep link.
	b.WriteString("[← " + courtNameFor(c) + "](" + base + ")")
	for up, n := f.parent, 0; up != 0 && n <= maxFolders; n++ {
		pv := c.mod.folders.Get(beClaimKey(up))
		if pv == nil {
			break
		}
		pf := pv.(*folder)
		b.WriteString(" · [" + sanitize.InlineText(pf.name) + "](" + base +
			"/folder/" + strconv.FormatUint(pf.id, 10) + ")")
		up = pf.parent
	}
	b.WriteString("\n\n")
	if f.retired {
		b.WriteString("> This heading was retired by a moderator. It is kept so " +
			"links to it still resolve.\n\n")
	}
	if f.desc != "" {
		b.WriteString(sanitize.Block(f.desc) + "\n")
	}

	kids := 0
	for _, k := range c.mod.folderRows() {
		if k.parent != f.id || k.retired || k.purged {
			continue
		}
		if kids == 0 {
			b.WriteString("## Under this heading\n\n")
		}
		kids++
		b.WriteString("- [" + sanitize.InlineText(k.name) + "](" + base + "/folder/" +
			strconv.FormatUint(k.id, 10) + ")\n")
	}
	if kids > 0 {
		b.WriteString("\n")
	}

	b.WriteString("## Claims filed here\n\n")
	filed := 0
	for _, id := range f.items {
		if id == 0 || id > c.nextID {
			continue
		}
		cs := mustClaim(c, id)
		filed++
		b.WriteString("- [" + claimTitleFor(c, cs) + "](" + base + "/" +
			strconv.FormatUint(id, 10) + ") — " + claimStatus(cs) + "\n")
	}
	if filed == 0 {
		b.WriteString("_Nothing filed here yet._\n")
	}
	b.WriteString("\n_A folder curates and can never bury: every claim above is " +
		"also on the court's own newest-first list, and nothing is reachable only " +
		"from here._\n\n")
	b.WriteString(helpLink + "\n")
	return b.String()
}
