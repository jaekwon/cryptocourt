package kourtv2

// The two court-wide histories the court page charts: coin supply, and the
// GNOT burned to mint it.
//
// SUPPLY COSTS NOTHING TO KEEP. The ledger already checkpoints it on every
// mint and its archive is never trimmed, so that half is pure formatting.
//
// BURN DOES, and it is one row per epoch in which somebody bought. It cannot be
// derived from supply: supply also moves on reward emissions, which burn no
// GNOT, and the burn total counts bond and deposit burns that never minted
// anything. Two different questions, so two different records.

import (
	"strconv"
	"strings"
)

// burnSeriesKey names the burn history in the court's shared archive. Not a
// cs: key — those are per-claim and this is the whole court.
const burnSeriesKey = "burn"

// recordBurn checkpoints the court's burn total. Called from reindexBurn, after
// the total moves, and nowhere else.
//
// Must not panic: reindexBurn runs inside Buy, the only GNOT on-ramp, and an
// index that degrades is always preferable to buying that bricks. setIfChanged
// writes a fixed key and an int64, neither of which has a failing case.
func recordBurn(c *Court) {
	setIfChanged(ensureCSArch(c), &c.burnH, burnSeriesKey,
		uint32(heightNow()/epochBlocks)+1, c.burnedGNOT)
}

// formatSeries renders change points as "width,now,more;epoch:value,...".
//
// ONE FORMATTER FOR BOTH READS. The grammar is a contract with the chart, and
// two copies of it are two things that can drift apart — the client would parse
// one correctly and the other silently as garbage.
func formatSeries(width int64, now uint32, pts []histPoint, more bool) string {
	rows := make([]string, 0, len(pts))
	for _, p := range pts {
		rows = append(rows, strconv.FormatUint(uint64(p.e), 10)+":"+
			strconv.FormatInt(p.v, 10))
	}
	m := "0"
	if more {
		m = "1"
	}
	return strconv.FormatInt(width, 10) + "," +
		strconv.FormatUint(uint64(now), 10) + "," + m + ";" +
		strings.Join(rows, ",")
}

// SupplySeries is the court's coin supply history, one line of text a client
// parses:
//
//	"width,now,more;epoch:supply,..."
//
// Rows are CHANGE points, strictly ascending. A missing epoch means supply did
// not move, so a chart forward-fills and draws step-after lines, never
// interpolation. Epoch e covers heights [(e-1)*width, e*width), and a row at
// e == now is the running epoch, which may still coalesce until it seals.
// Values are CC base units, the same numbers CoinSupply serves live.
//
// more=1 means older points were dropped by the row cap. The rows kept are the
// newest, and each carries an absolute value, so any suffix stands alone.
//
// Empty rows mean the supply never moved, not that the read failed.
func SupplySeries(courtSlug string) string {
	c := mustCourt(courtSlug)

	pts := []histPoint{}
	more := false
	c.coin.WalkSupply(func(e uint32, v int64) bool {
		if len(pts) >= seriesRowCap {
			more = true
			return true
		}
		pts = append(pts, histPoint{e, v})
		return false
	})
	// The walk is newest-first; rows are ascending.
	for i, j := 0, len(pts)-1; i < j; i, j = i+1, j-1 {
		pts[i], pts[j] = pts[j], pts[i]
	}

	return formatSeries(c.coin.EpochBlocks(), c.coin.Epoch(), pts, more)
}

// BurnSeries is the cumulative GNOT burned into this court's curve over time,
// in the same grammar as SupplySeries. Values are ugnot and never decrease —
// the curve is one way, so this is the real value the court has absorbed.
//
// Read it as the court's livelihood: supply can rise on emissions nobody paid
// for, but this only moves when somebody spent.
func BurnSeries(courtSlug string) string {
	c := mustCourt(courtSlug)
	pts, more := collectSeriesKeyed(c.csArch, &c.burnH, burnSeriesKey)
	return formatSeries(epochBlocks, uint32(heightNow()/epochBlocks)+1, pts, more)
}
