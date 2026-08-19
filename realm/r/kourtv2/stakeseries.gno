package kourtv2

// Drawable per-claim stake history (owner ask, 2026-08-17): the two pools as
// checkpoint series so a chart can show what actually happened, not a shape
// synthesized from three ratios. Hourly points are kept hot for a week and
// trimmed past it; daily points are kept for the claim's life. Change-only:
// an epoch in which the pools did not move stores nothing — that guard is the
// CALLER's (SetAt archives unconditionally on an epoch roll), the same
// discipline grc20votes applies at addVotes.
//
// This is render/read-layer state: no money path reads any of it.

import (
	"strconv"
	"strings"

	checkpoint "gno.land/p/kourt/checkpoint/v0"
)

const (
	// hourlyKeep is how many hourly epochs stay hot — a week, the same figure
	// as twapBuckets. Older hourly pages are trimmed; the daily grain answers
	// below the horizon.
	hourlyKeep = uint32(168)
	// trimBudget bounds the archive pages freed per trim ride. Production adds
	// at most one candidate page per 32 CHANGED hourly epochs per series, so a
	// budget of 2 per touched hour strictly outruns it.
	trimBudget = 2
	// dailyBlocks is the daily grain's width: 24 hourly epochs. 17,280 blocks
	// is already the realm's canonical day (priorityWindowBlocks).
	dailyBlocks = int64(17_280)
	// seriesRowCap bounds ClaimSeries' output rows (audit N3 discipline: no
	// read's cost may grow unbounded with attacker-priced writes). Hourly can
	// never reach it (retention 168+2); daily reaches it only on a zombie
	// claim staked across ~13 months of daily changes.
	seriesRowCap = 400
)

// csKey names one series' pages in the court's shared archive.
//
// NEVER beClaimKey here: it packs raw zero bytes and checkpoint.Sep IS \x00,
// so every claim id would panic mustBeUsable. Decimal text is fine — the key
// is short (≤ 25 bytes against MaxKey 128) and never parsed back.
func csKey(id uint64, suffix string) string {
	return "cs:" + strconv.FormatUint(id, 10) + ":" + suffix
}

// ensureCSArch lazily creates the court's history archive (write paths only —
// reads must tolerate nil, per the read-purity rule).
func ensureCSArch(c *Court) *checkpoint.Archive {
	if c.csArch == nil {
		c.csArch = checkpoint.NewArchive()
	}
	return c.csArch
}

// setIfChanged is the no-change ⇒ no-storage guard. SetAt with a rolled epoch
// archives the previous point even when the value is identical; skipping the
// write entirely is what keeps a quiet claim at zero bytes.
func setIfChanged(a *checkpoint.Archive, s *checkpoint.Series, key string, e uint32, v int64) {
	if v != s.Value() {
		s.SetAt(a, key, e, v)
	}
}

// recordPools checkpoints both pools on both grains. Contract: runs AFTER the
// pool mutation (it records the new value), from the same two call sites as
// observePools — and nowhere else, so a frozen claim's record simply stops.
// Within one epoch the writes coalesce on the inline slots for free; the trim
// rides at most once per hourly epoch per claim.
func recordPools(c *Court, cs *claimState) {
	h := heightNow()
	a := ensureCSArch(c)
	hE := uint32(h/epochBlocks) + 1 // 1-based, the coin's own epoch clock
	dE := uint32(h/dailyBlocks) + 1
	setIfChanged(a, &cs.yesH, csKey(cs.id, "yh"), hE, cs.yesStake)
	setIfChanged(a, &cs.noH, csKey(cs.id, "nh"), hE, cs.noStake)
	setIfChanged(a, &cs.yesD, csKey(cs.id, "yd"), dE, cs.yesStake)
	setIfChanged(a, &cs.noD, csKey(cs.id, "nd"), dE, cs.noStake)
	if hE > cs.histTrimmedTo {
		cs.histTrimmedTo = hE
		trimClaimHistory(c, cs, hE)
	}
}

// trimClaimHistory frees hourly pages older than the keep window, bounded.
// Also called once at settlement so a finished claim's hourly tail is clipped
// to its final week without waiting for traffic it will never see again.
func trimClaimHistory(c *Court, cs *claimState, hE uint32) {
	if c.csArch == nil || hE <= hourlyKeep+1 {
		return
	}
	keep := hE - hourlyKeep
	c.csArch.Trim(csKey(cs.id, "yh"), keep, trimBudget)
	c.csArch.Trim(csKey(cs.id, "nh"), keep, trimBudget)
}

// histPoint is one change point during collection.
type histPoint struct {
	e uint32
	v int64
}

// collectSeriesKeyed returns one series' change points ascending — the newest
// seriesRowCap archived entries plus the two inline points — and whether
// older archived entries were dropped by the cap. Nil archive is a claim
// (or court) from before this feature: only the inline points, which for a
// zero Series is nothing at all.
func collectSeriesKeyed(a *checkpoint.Archive, s *checkpoint.Series, key string) ([]histPoint, bool) {
	pts := []histPoint{}
	more := false
	if a != nil && key != "" {
		a.WalkDesc(key, func(e uint32, v int64) bool {
			if len(pts) >= seriesRowCap {
				more = true
				return true
			}
			pts = append(pts, histPoint{e, v})
			return false
		})
	}
	// Newest-first to ascending.
	for i, j := 0, len(pts)-1; i < j; i, j = i+1, j-1 {
		pts[i], pts[j] = pts[j], pts[i]
	}
	if e1, pv := s.Prev(); e1 != 0 {
		pts = append(pts, histPoint{e1, pv})
	}
	if e0 := s.Since(); e0 != 0 {
		pts = append(pts, histPoint{e0, s.Value()})
	}
	return pts, more
}

// ClaimSeries is the recorded history of a claim's two stake pools, one line
// of text a client parses: "grain,width,now,more;epoch:yes:no,...".
//
// Rows are CHANGE points, strictly ascending — a missing epoch means the
// pools did not move, and the consumer forward-fills (charts draw step-after
// lines, never interpolation). Rows are a contiguous newest-suffix of the
// change history: between consecutive rows and from the last row to `now`,
// forward-fill is exact. Epoch e covers heights [(e-1)*width, e*width); a row
// at e == now is the running epoch's latest value and may still coalesce
// until the epoch seals. Values are CC base units, the same numbers
// StakePools serves live; intra-epoch flicker that reverts within an epoch
// leaves no trace — the record is where the pools settled each epoch, the
// twap ring's own last-value-in-bucket posture.
//
// grain "hourly" serves from the trim horizon (~a week) to now; "daily"
// serves the claim's whole life. more=1 means older change points exist but
// were dropped by the row cap — ask the coarser grain. A 0:0 row is real
// (everyone unstaked), not absence; empty rows mean the pools never changed.
//
// No purge gate, deliberately: the gate exists for TEXT (ClaimTitle's
// tombstone), and this read carries none — pool sizes are the same numeric
// surface StakePools already serves ungated ("stakes, verdict and refunds
// proceed", the purge banner's own words). It refuses only a missing
// court/claim and a bad grain, like every sibling read.
func ClaimSeries(courtSlug string, claimID uint64, grain string) string {
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	var width int64
	var yS, nS *checkpoint.Series
	var yKey, nKey string
	switch grain {
	case "hourly":
		width = epochBlocks
		yS, nS = &cs.yesH, &cs.noH
		yKey, nKey = csKey(claimID, "yh"), csKey(claimID, "nh")
	case "daily":
		width = dailyBlocks
		yS, nS = &cs.yesD, &cs.noD
		yKey, nKey = csKey(claimID, "yd"), csKey(claimID, "nd")
	default:
		panic(`kourtv2: grain is "hourly" or "daily"`)
	}
	now := uint32(heightNow()/width) + 1
	ys, moreY := collectSeriesKeyed(c.csArch, yS, yKey)
	ns, moreN := collectSeriesKeyed(c.csArch, nS, nKey)

	// Union of change epochs, forward-filling the side that did not change.
	// When a side's older entries were capped away, rows below its oldest
	// KNOWN entry would forward-fill from an unknowable floor — clip the
	// union there so every emitted row is exact.
	start := uint32(0)
	if moreY && len(ys) > 0 && ys[0].e > start {
		start = ys[0].e
	}
	if moreN && len(ns) > 0 && ns[0].e > start {
		start = ns[0].e
	}
	more := moreY || moreN
	curY, curN := int64(0), int64(0)
	i, j := 0, 0
	for i < len(ys) && ys[i].e < start {
		curY = ys[i].v
		i++
	}
	for j < len(ns) && ns[j].e < start {
		curN = ns[j].v
		j++
	}
	rows := []string{}
	for i < len(ys) || j < len(ns) {
		var e uint32
		switch {
		case i >= len(ys):
			e = ns[j].e
		case j >= len(ns):
			e = ys[i].e
		case ys[i].e < ns[j].e:
			e = ys[i].e
		default:
			e = ns[j].e
		}
		if i < len(ys) && ys[i].e == e {
			curY = ys[i].v
			i++
		}
		if j < len(ns) && ns[j].e == e {
			curN = ns[j].v
			j++
		}
		rows = append(rows, strconv.FormatUint(uint64(e), 10)+":"+
			strconv.FormatInt(curY, 10)+":"+strconv.FormatInt(curN, 10))
	}
	// The union of two capped sides can itself exceed the cap: keep the
	// newest suffix (each row carries absolute values, so any suffix stands
	// alone) and say so.
	if len(rows) > seriesRowCap {
		rows = rows[len(rows)-seriesRowCap:]
		more = true
	}
	m := "0"
	if more {
		m = "1"
	}
	return grain + "," + strconv.FormatInt(width, 10) + "," +
		strconv.FormatUint(uint64(now), 10) + "," + m + ";" +
		strings.Join(rows, ",")
}
