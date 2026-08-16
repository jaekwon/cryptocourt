// Render: the claim page IS the product (PLAN §3.9/§11). Three ratio series,
// no "backing" anywhere (burned GNOT backs nothing), sealed tallies once votes
// exist, absolute CC figures only — never percentages of return, never the
// inflation ceiling (§7.4). Every user string passes the sanitizer.
package courtv2

import (
	"strconv"
	"strings"

	"chain/runtime"

	sanitize "gno.land/p/nt/markdown/sanitize/v0"
)

// Render routes:
//
//	""              the directory
//	"<slug>"        one court
//	"<slug>/<id>"   one claim
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
	b.WriteString("# CryptoCourt V2\n\nStake on claims of fact. Your principal always returns 1×.\n\n")
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
		b.WriteString("- [" + sanitize.InlineText(c.name) + "](/r/cryptocourt/courtv2:" + s + ") — " +
			strconv.FormatUint(c.nextID, 10) + " claims\n")
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
	for id := uint64(1); id <= c.nextID; id++ {
		cs := mustClaim(c, id)
		b.WriteString("- [" + sanitize.InlineText(cs.title) + "](/r/cryptocourt/courtv2:" + slug + "/" +
			strconv.FormatUint(id, 10) + ") — " + claimStatus(cs) + "\n")
	}
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
	b.WriteString("# " + sanitize.InlineText(cs.title) + "\n\n")

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
	return b.String()
}

// claimStatus is the one-line lifecycle readout. It grows verdict/tier/route
// lines as those modules land; the sealed-tally rule (never a running count)
// binds every future addition.
func claimStatus(cs *claimState) string {
	switch {
	case cs.closed:
		return "closed — never answered; every stake exited 1×, the deposit refunded"
	case cs.frozenAt != 0:
		return "answered — staking frozen; resolution in progress (principal is never withheld)"
	default:
		return "open — stake YES or NO; unstake freely until an answer posts"
	}
}

// pct renders a basis-point-precision percentage from two int64s.
func pct(num, den int64) string {
	if den <= 0 {
		return "—"
	}
	bps := num * 10000 / den
	return strconv.FormatInt(bps/100, 10) + "." + pad2(bps%100) + "%"
}

func pad2(v int64) string {
	if v < 10 {
		return "0" + strconv.FormatInt(v, 10)
	}
	return strconv.FormatInt(v, 10)
}
