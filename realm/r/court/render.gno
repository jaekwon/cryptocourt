package court

import (
	"strconv"
	"strings"

	sanitize "gno.land/p/nt/markdown/sanitize/v0"
)

// Render is the read-only view of the whole realm, routed by path:
//
//	""                 the directory (courts by tier)
//	"<slug>"           one court (its coin, and its claims)
//	"<slug>/<id>"      one claim (title, body, market, answer, dispute)
//
// Every user-supplied string — a court name, a claim title, a body — is passed
// through the sanitizer before it reaches markdown, so attacker-controlled input
// (STRUCTURE §8.4) can never inject a link, a heading, or a table break. The LIVE
// dispute tally is deliberately NOT shown while a vote is open (§3.4 sealed vote);
// only that a dispute is under way. The chain carries all the information; a client
// overlay just makes it prettier.
func Render(path string) string {
	path = strings.Trim(path, "/")
	if path == "" {
		return renderDirectory()
	}
	parts := strings.SplitN(path, "/", 2)
	if len(parts) == 1 {
		return renderCourt(parts[0])
	}
	id, err := strconv.ParseUint(parts[1], 10, 64)
	if err != nil {
		return "## Not found\nA claim id must be a number."
	}
	return renderClaim(parts[0], id)
}

func renderDirectory() string {
	b := strings.Builder{}
	b.WriteString("# CryptoCourt\n\nPlay-wager on claims of fact in the court you trust.\n\n")
	// Measure AFTER the header: the tiers, not the header, decide whether anything
	// was listed. Checking b.Len() == 0 was dead — the header is always written
	// first — so the empty state never showed on a realm with no (visible) courts.
	afterHeader := b.Len()
	writeTier(&b, "Featured", tierFeatured)
	writeTier(&b, "Courts", tierListed)
	if b.Len() == afterHeader {
		b.WriteString("_No courts yet._\n")
	}
	return b.String()
}

func writeTier(b *strings.Builder, heading string, tier uint8) {
	slugs := ListByTier(int(tier))
	if len(slugs) == 0 {
		return
	}
	b.WriteString("## " + heading + "\n\n")
	for _, s := range slugs {
		c := mustCourt(s)
		b.WriteString("- [" + sanitize.InlineText(c.name) + "](/r/cryptocourt/court:" + s + ") — " +
			strconv.FormatUint(c.shares.Count(), 10) + " claims\n")
	}
	b.WriteString("\n")
}

func renderCourt(slug string) string {
	if !Exists(slug) {
		return "## Not found\nNo court by that slug."
	}
	c := mustCourt(slug)
	b := strings.Builder{}
	b.WriteString("# " + sanitize.InlineText(c.name) + "\n\n")
	b.WriteString("- coin price: " + strconv.FormatInt(c.crv.Price(c.minted), 10) +
		" · backing: " + strconv.FormatInt(c.crv.Backing(c.minted), 10) + " (per coin)\n")
	b.WriteString("- supply: " + strconv.FormatInt(c.coin.TotalSupply(), 10) +
		" · treasury: " + strconv.FormatInt(c.treasury, 10) + " GNOT\n")
	b.WriteString("- open interest: " + strconv.FormatInt(c.oi, 10) + " CC\n\n")
	b.WriteString("[buy the coin →](/r/cryptocourt/court$help&func=Buy&slug=" + slug + ")\n\n")

	b.WriteString("## Claims\n\n")
	n := c.shares.Count()
	for id := uint64(1); id <= n; id++ {
		if !c.shares.Exists(id) {
			continue
		}
		cs := mustClaim(c, id)
		b.WriteString("- [" + sanitize.InlineText(cs.title) + "](/r/cryptocourt/court:" + slug + "/" +
			strconv.FormatUint(id, 10) + ") — " + claimStatus(cs) + "\n")
	}
	return b.String()
}

func renderClaim(slug string, id uint64) string {
	if !Exists(slug) {
		return "## Not found\nNo court by that slug."
	}
	c := mustCourt(slug)
	if !c.shares.Exists(id) {
		return "## Not found\nNo claim by that id."
	}
	cs := mustClaim(c, id)
	b := strings.Builder{}
	b.WriteString("# " + sanitize.InlineText(cs.title) + "\n\n")
	if body := ClaimBody(slug, id); body != "" {
		b.WriteString(sanitize.Block(body) + "\n\n")
	}

	b.WriteString("## Market\n\n")
	b.WriteString("- open interest X: " + strconv.FormatInt(claimX(c, id), 10) + " CC\n")
	if bb, ok := cs.book.BestBid(); ok {
		b.WriteString("- best bid: " + strconv.Itoa(int(bb)+1) + "\n")
	}
	if ba, ok := cs.book.BestAsk(); ok {
		b.WriteString("- best ask: " + strconv.Itoa(int(ba)+1) + "\n")
	}
	b.WriteString("\n## Verdict\n\n" + claimStatus(cs) + "\n")
	return b.String()
}

// claimStatus is a one-line status, and — crucially — it never reveals the live
// dispute tally: while a vote is open it says only that one is, not who is winning.
func claimStatus(cs *claimState) string {
	switch {
	case cs.finalized && cs.provClose:
		return "closed without a decision — redeemed at the pre-answer price"
	case cs.finalized:
		return "resolved: " + verdictName(int(cs.provisional))
	// disputeOpen MUST be tested before provisional: a reopen has both set, and the
	// sealed-tally rule requires the "a dispute is under way" line to win.
	case cs.disputeOpen:
		return "a dispute is under way — the tally is sealed until the vote closes"
	case cs.provClose:
		return "closing without a decision (three disputes failed to reach a verdict)"
	case cs.provisional >= 0:
		return "provisional " + verdictName(int(cs.provisional)) +
			", in escrow until height " + strconv.FormatInt(cs.escrowUntil, 10) + " (reopenable)"
	case cs.answered:
		return "answered " + verdictName(int(cs.answer)) + " (awaiting a dispute or settlement)"
	default:
		return "open — no answer yet"
	}
}

func verdictName(outcome int) string {
	if outcome == outcomeYES {
		return "YES"
	}
	return "NO"
}
