// Render: the claim page IS the product (PLAN §3.9/§11). Three ratio series,
// no "backing" anywhere (burned GNOT backs nothing), sealed tallies once votes
// exist, absolute CC figures only — never percentages of return, never the
// inflation ceiling (§7.4). Every user string passes the sanitizer.
package kourtv2

import (
	"strconv"
	"strings"

	"chain/runtime"

	sanitize "gno.land/p/nt/markdown/sanitize/v0"
)

// Render routes:
//
//	""                    the directory
//	"<slug>"              one court
//	"<slug>/<id>"         one claim
//	"<slug>/<id>/<addr>"  one address's positions on a claim ("your page")
func Render(path string) string {
	path = strings.Trim(path, "/")
	if path == "" {
		return renderDirectory()
	}
	parts := strings.SplitN(path, "/", 3)
	if len(parts) == 1 {
		return renderCourt(parts[0])
	}
	// The moderation log is a named sub-route, so it must be carved out BEFORE
	// the numeric-id parse below (MODERATION.md §4).
	if parts[1] == "mod" {
		return renderModLog(parts[0])
	}
	id, err := strconv.ParseUint(parts[1], 10, 64)
	if err != nil {
		return "## Not found\nA claim id must be a number."
	}
	if len(parts) == 3 {
		return renderPositions(parts[0], id, parts[2])
	}
	return renderClaim(parts[0], id)
}

func renderDirectory() string {
	b := strings.Builder{}
	b.WriteString("# " + platformName + "\n\nStake on claims of fact. Your principal always returns 1×.\n\n")
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
	for _, s := range slugs {
		c := mustCourt(s)
		if c.tier != tierListed {
			continue
		}
		b.WriteString("- [" + courtNameFor(c) + "](/r/kourt/kourtv2:" + s + ") · " +
			qualifiedSymbol(c) + " — " + strconv.FormatUint(c.nextID, 10) + " claims\n")
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
	b.WriteString("- coin: " + qualifiedSymbol(c) + " — this court's own coin, not interchangeable with any other court's\n")
	b.WriteString("- coin price: " + strconv.FormatInt(c.crv.Price(c.minted), 10) + " ugnot per CC unit (one-way; the GNOT is burned)\n")
	b.WriteString("- supply: " + strconv.FormatInt(c.coin.TotalSupply(), 10) +
		" · emitted: " + strconv.FormatInt(c.emittedTotal, 10) + "\n")
	b.WriteString("- reward reservoir: " + strconv.FormatInt(c.reservoirR(), 10) +
		" · senior queue owed: " + strconv.FormatInt(c.seniorOwed, 10) + "\n\n")
	b.WriteString("## Claims\n\n")
	if c.nextID == 0 {
		b.WriteString("_No claims yet._\n")
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
	b.WriteString("[Moderation log](/r/kourt/kourtv2:" + slug + "/mod)\n")
	return b.String()
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
	b.WriteString(hideBanner(c, cs))
	writeAppeal(&b, c, cs)
	if cs.seeded {
		b.WriteString("_Seeded by a moderator to start this court; the author earns nothing from it._\n\n")
	}

	b.WriteString("## Signal\n\n")
	total := cs.yesStake + cs.noStake
	b.WriteString("- staked now: " + strconv.FormatInt(total, 10) +
		" (YES " + strconv.FormatInt(cs.yesStake, 10) + " / NO " + strconv.FormatInt(cs.noStake, 10) + ")\n")
	if total > 0 {
		b.WriteString("- instantaneous: " + pct(cs.yesStake, total) + " YES\n")
	}
	h := runtime.ChainHeight()
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
			strconv.FormatInt(cs.answerBond0, 10) + " CC units)\n")
		// The answerer's track record — contested-and-upheld answers only, so a
		// high number is hard-won signal, not volume (P13). If the court's
		// priority gate is armed, a record ≥ threshold earns a 24h head start.
		b.WriteString("- answerer's difficulty record (this court): " +
			strconv.FormatInt(int64(AnswerRecord(slug, cs.answerer)), 10) + "\n")
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
			b.WriteString("- disputing this answer now costs " +
				strconv.FormatInt(cs.disputeBond0(), 10) + " CC units (doubles per failed round)\n")
		}
		if cs.verdictAt != 0 && !cs.provClose {
			b.WriteString("- verdict: " + sideName(int(cs.provisional)) + " — " + cs.route + "\n")
		}
		// Quality: the tier and the flag slot. The tally itself stays sealed.
		q := "quality: " + tierName(cs.tier)
		if cs.tierFinal {
			q += " (final)"
		} else {
			q += " (default; the flag lane may re-vote it)"
		}
		b.WriteString("- " + q + "\n")
		switch {
		case cs.flagOpen:
			b.WriteString("- flag vote open — the tally is sealed until it closes\n")
		case cs.counterOpen:
			b.WriteString("- counter re-vote open — the tally is sealed until it closes\n")
		case cs.pendingSlash > 0:
			b.WriteString("- a slash is escrowed in its counter-flag window\n")
		case !cs.crystallized && !cs.slotConsumed && !cs.provClose:
			b.WriteString("- flag slot open — bond " + strconv.FormatInt(flagBondFor(cs), 10) + " CC units\n")
		}
		if cs.crystallized {
			w, a, ans, carrot := cs.drawWinners, cs.drawAuthor, cs.drawAnswerer, cs.carrotPool
			b.WriteString("- rewards crystallized — pools (CC units): accuracy " + strconv.FormatInt(w, 10) +
				", author " + strconv.FormatInt(a, 10) + ", answerer " + strconv.FormatInt(ans, 10) +
				", participation remaining " + strconv.FormatInt(carrot, 10) + "\n")
		}
	}
	b.WriteString("\n_Your positions: append your address to this path (…/" +
		strconv.FormatUint(id, 10) + "/<your-address>)._\n")
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
	b.WriteString("# Your positions\n\n")
	// Through the SAME text gate as every other surface, with the banner: this
	// route (…/<slug>/<id>/<addr>, reachable with any address string) was the one
	// render path that bypassed it, so a purged claim's text stayed publicly
	// readable and purge — the legal-compliance power — did not actually reach
	// "every surface".
	b.WriteString(hideBanner(c, cs))
	b.WriteString("Claim: " + claimTitleFor(c, cs) + "\n\n")
	b.WriteString("Address: " + sanitize.InlineText(addrStr) + "\n\n")

	yStake := StakeOf(slug, id, sideYES, who)
	nStake := StakeOf(slug, id, sideNO, who)
	yConv := ConvictionOf(slug, id, sideYES, who)
	nConv := ConvictionOf(slug, id, sideNO, who)
	b.WriteString("## Stake (live principal, always returns 1×)\n\n")
	b.WriteString("- YES: " + strconv.FormatInt(yStake, 10) +
		"   NO: " + strconv.FormatInt(nStake, 10) + " (CC base units)\n")
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
	bal := c.coin.BalanceOf(who)
	locked := lockedOf(c, who)
	b.WriteString("\n## Your CC in this court (all claims)\n\n")
	b.WriteString("- held: " + strconv.FormatInt(bal, 10) +
		" (CC base units) — every unit votes, committed or not\n")
	b.WriteString("- committed as stake: " + strconv.FormatInt(locked, 10) + "\n")
	b.WriteString("- free to commit: " + strconv.FormatInt(spendable(c, who), 10) +
		" — what a new stake, deposit or bond draws on\n")

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
		return "settled — every stake withdraws 1×"
	case cs.disputeOpen:
		return "disputed — a sealed vote is deciding; principal is never withheld"
	case cs.provisional >= 0:
		return "provisional verdict " + sideName(int(cs.provisional)) +
			" — reopenable by a new dispute until block " + strconv.FormatInt(cs.escrowUntil, 10) +
			"; the side it is against may withdraw 1× now"
	case cs.frozenAt != 0:
		return "answered — staking frozen; disputable until block " +
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
