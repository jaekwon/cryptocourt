package kourtv2

import (
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
)

// splitSeries takes "width,now,more;rows" apart. Returns the header fields and
// the rows, so a test can assert each without re-deriving the grammar.
func splitSeries(t *testing.T, s string) (width, now, more string, rows []string) {
	t.Helper()
	head, body, ok := strings.Cut(s, ";")
	if !ok {
		t.Fatalf("no ; in series %q", s)
	}
	h := strings.Split(head, ",")
	if len(h) != 3 {
		t.Fatalf("header has %d fields, want 3: %q", len(h), head)
	}
	if body == "" {
		return h[0], h[1], h[2], nil
	}
	return h[0], h[1], h[2], strings.Split(body, ",")
}

// TestSupplySeriesGrammar pins the shape a chart parses, and pins that quiet
// epochs cost nothing: rows are change points, so skipping hours adds none.
func TestSupplySeriesGrammar(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ss-alice")
	c := testCourt(cur, "ss1", alice, 10_000_000_000)
	founded := CoinSupply("ss1")
	e1 := hourEpochAt(testingHeight())

	testing.SkipHeights(720 * 3)
	c.coin.Mint(alice, 5_000_000_000)
	e2 := hourEpochAt(testingHeight())

	testing.SkipHeights(720 * 4) // quiet hours: rows must NOT grow
	now := hourEpochAt(testingHeight())

	width, gotNow, more, rows := splitSeries(t, SupplySeries("ss1"))
	if width != "720" {
		t.Errorf("width = %q, want 720 (the ledger's epoch)", width)
	}
	if want := strconv.FormatUint(uint64(now), 10); gotNow != want {
		t.Errorf("now = %q, want %q", gotNow, want)
	}
	if more != "0" {
		t.Errorf("more = %q, want 0 — nothing was capped", more)
	}
	if len(rows) != 2 {
		t.Fatalf("got %d rows, want 2 (two mints, four quiet hours): %v", len(rows), rows)
	}

	// Ascending, and each row is the supply as of that epoch.
	wantRows := []string{
		strconv.FormatUint(uint64(e1), 10) + ":" + strconv.FormatInt(founded, 10),
		strconv.FormatUint(uint64(e2), 10) + ":" + strconv.FormatInt(founded+5_000_000_000, 10),
	}
	for i, want := range wantRows {
		if rows[i] != want {
			t.Errorf("row %d = %q, want %q", i, rows[i], want)
		}
	}

	// The newest row must agree with what the court serves live, or the chart
	// ends somewhere the rest of the page does not.
	live := strconv.FormatInt(CoinSupply("ss1"), 10)
	if _, v, _ := strings.Cut(rows[len(rows)-1], ":"); v != live {
		t.Errorf("newest row is %q, but CoinSupply is %s", v, live)
	}

	// Purity: identical bytes on a re-read.
	if a, b := SupplySeries("ss1"), SupplySeries("ss1"); a != b {
		t.Error("SupplySeries is not deterministic across back-to-back reads")
	}
}

// Two mints in ONE epoch are one point, not two: the ledger coalesces within an
// epoch, which is what keeps a busy hour from costing a row per transaction.
func TestSupplySeriesCoalescesWithinAnEpoch(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ss2-alice")
	c := testCourt(cur, "ss2", alice, 1_000_000)
	c.coin.Mint(alice, 2_000_000)
	c.coin.Mint(alice, 3_000_000)

	_, _, _, rows := splitSeries(t, SupplySeries("ss2"))
	if len(rows) != 1 {
		t.Fatalf("got %d rows, want 1 — three mints in one epoch coalesce: %v", len(rows), rows)
	}
	want := strconv.FormatInt(CoinSupply("ss2"), 10)
	if _, v, _ := strings.Cut(rows[0], ":"); v != want {
		t.Errorf("the single row is %q, want the final supply %s", v, want)
	}
}

// The burn history must track what CourtBurnedGNOT reports, and must move only
// when somebody actually spent — that is the whole reason it is kept separately
// from supply, which also moves on emissions nobody paid for.
func TestBurnSeriesFollowsWhatWasSpent(cur realm, t *testing.T) {
	alice := testutils.TestAddress("bs-alice")
	fundAndBuy(cur, "bs1", alice, 300_000_000)
	first := CourtBurnedGNOT("bs1")
	if first <= 0 {
		t.Fatalf("fixture bought nothing: burned = %d", first)
	}

	_, _, _, rows := splitSeries(t, BurnSeries("bs1"))
	if len(rows) != 1 {
		t.Fatalf("got %d rows after one buy, want 1: %v", len(rows), rows)
	}
	if _, v, _ := strings.Cut(rows[0], ":"); v != strconv.FormatInt(first, 10) {
		t.Errorf("row is %q, want the burn total %d", v, first)
	}

	// A later epoch with another buy adds a point; the total only ever grows.
	testing.SkipHeights(720 * 2)
	fundAndBuy(cur, "bs1", alice, 300_000_000)
	second := CourtBurnedGNOT("bs1")
	if second <= first {
		t.Fatalf("a second buy did not raise the burn total: %d -> %d", first, second)
	}
	_, _, _, rows2 := splitSeries(t, BurnSeries("bs1"))
	if len(rows2) != 2 {
		t.Fatalf("got %d rows after a buy in a new epoch, want 2: %v", len(rows2), rows2)
	}
	if _, v, _ := strings.Cut(rows2[1], ":"); v != strconv.FormatInt(second, 10) {
		t.Errorf("newest row is %q, want %d", v, second)
	}

	// Quiet epochs cost nothing: no buy, no row.
	testing.SkipHeights(720 * 5)
	_, _, _, rows3 := splitSeries(t, BurnSeries("bs1"))
	if len(rows3) != 2 {
		t.Errorf("quiet epochs added rows: %v", rows3)
	}
}

// A court nobody has bought into has no burn history, and that is not an error.
func TestBurnSeriesIsEmptyBeforeAnyBuy(cur realm, t *testing.T) {
	alice := testutils.TestAddress("bs2-alice")
	testCourt(cur, "bs2", alice, 1_000_000)
	if got := CourtBurnedGNOT("bs2"); got != 0 {
		t.Fatalf("fixture already burned %d", got)
	}
	_, _, more, rows := splitSeries(t, BurnSeries("bs2"))
	if len(rows) != 0 {
		t.Errorf("a court with no buys has rows: %v", rows)
	}
	if more != "0" {
		t.Errorf("more = %q on an empty history, want 0", more)
	}
}

// A court that does not exist is refused, like every sibling read.
func TestSupplySeriesRefusesAnUnknownCourt(cur realm, t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Error("an unknown court must be refused")
		}
	}()
	SupplySeries("no-such-court")
}

func TestBurnSeriesRefusesAnUnknownCourt(cur realm, t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Error("an unknown court must be refused")
		}
	}()
	BurnSeries("no-such-court")
}
