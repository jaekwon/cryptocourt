package kourtv2

// The court's coin supply over time, for the chart on the court page.
//
// NO NEW STATE AND NO NEW WRITES. The ledger already checkpoints supply on
// every mint, and its archive is never trimmed, so the whole history is
// stored. This file only formats what is there — a supply chart costs the
// court nothing in storage and costs a buy nothing in gas.

import (
	"strconv"
	"strings"
)

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
// ONE GRAIN, unlike ClaimSeries. Supply moves only on a mint — a buy or an
// emission — which is rare next to a stake, so the change points are few and a
// coarser grain would have nothing to thin out.
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

	rows := make([]string, 0, len(pts))
	for _, p := range pts {
		rows = append(rows, strconv.FormatUint(uint64(p.e), 10)+":"+
			strconv.FormatInt(p.v, 10))
	}

	m := "0"
	if more {
		m = "1"
	}
	return strconv.FormatInt(c.coin.EpochBlocks(), 10) + "," +
		strconv.FormatUint(uint64(c.coin.Epoch()), 10) + "," + m + ";" +
		strings.Join(rows, ",")
}
