package kourtv2

import (
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
)

// THE TRIM'S OWN EARLY RETURN IS AN UNDERFLOW GUARD, and nothing held it.
//
// trimClaimHistory returns early when `c.csArch == nil || hE <= hourlyKeep+1`, and
// the second half is not tidiness. `keep := hE - hourlyKeep` is uint32 arithmetic, so
// any court younger than 168 hourly epochs computes a keep of about four billion and
// then asks the archive to free every page older than THAT — which is all of them.
// The budget of two pages per ride is the only reason the loss would be gradual
// instead of total.
//
// Weakening the guard (its `||` to `&&`) survived the entire stakeseries suite. The
// reason is a fixture fact, not a coincidence: archive pages hold 32 entries, every
// existing test stages a handful of change points, and freeing "up to two pages" of a
// history that has not filled one page destroys nothing at all. So the failure mode is
// silent data loss that appears only at scale, which is the worst kind to leave
// unpinned — the read would simply start answering with less history and no error.
//
// Forty hourly change points, one stake per hourly epoch: one full rolled page plus a
// remainder, so a trim has something real to take. The assertions name what the
// fixture must contain before they mean anything — more than a page of rows, and a
// header saying the ROW CAP dropped nothing — so that a loss can only be the trim's.
func TestAYoungCourtsHourlyHistorySurvivesEveryTrimRide(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cstr-alice")
	testCourt(cur, "cstr", alice, 40_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "cstr", "staked across forty hours")

	// The change points are written STRAIGHT into the archive, ascending, and then the
	// production path rides the trim exactly once. Driving forty real Stake calls
	// instead measures 0.58s against 0.07s for this — 8x, and every mutation row pays
	// it again, about eight minutes across a full corpus pass. What this test is about
	// is the trim ride, not how the pools got there, and TestClaimSeriesGrammar
	// already pins that the production path records at all.
	//
	// (Those two figures are the tests' OWN durations from a -v run. A first attempt
	// compared whole-package wall clock and read 109s against 54s, which was a
	// concurrent corpus pass competing for the machine, not this test. It very nearly
	// bought a redesign.)
	c := mustCourt("cstr")
	cs := mustClaim(c, id)
	a := ensureCSArch(c)
	key := csKey(cs.id, "yh")
	testing.SkipHeights(epochBlocks * 45) // a young court, but past the points below
	first := hourEpochAt(testingHeight()) - 40
	for k := uint32(0); k < 40; k++ {
		cs.yesH.SetAt(a, key, first+k, int64(k+1)*1_000_000)
	}
	pts, capped := collectSeriesKeyed(a, &cs.yesH, key)
	if len(pts) < 33 {
		t.Fatalf("setup: the fixture must hold more than one archive page of change "+
			"points, holds %d", len(pts))
	}
	if capped {
		t.Fatal("setup: the row cap must not be involved, or a loss below is not the trim's")
	}
	// ONE ride of the production path, at a young court's own epoch.
	recordPools(c, cs)

	out := ClaimSeries("cstr", id, "hourly")
	parts := strings.SplitN(out, ";", 2)
	if len(parts) != 2 {
		t.Fatalf("setup: the read must return a header and a body, got %q", out)
	}
	// The row cap dropped nothing, so anything missing is the trim's doing. This one
	// is still a fixture question and it stays worded as one.
	if !strings.HasSuffix(parts[0], ",0") {
		t.Fatalf("setup: the row cap must not have dropped anything here: %q", parts[0])
	}
	// From here down the wording matters, because these are the DEFECT. The first
	// version of this test guarded the row count as "setup: forty changed epochs must
	// leave more than one page of rows" AFTER the ride, so the real failure reported
	// itself as a broken fixture — it said "got 15" where a reader would look for a
	// bug in the test.
	rows := strings.Split(parts[1], ",")
	if len(rows) < 33 {
		t.Fatalf("the ride cut the readable history to %d rows in a court too young "+
			"to trim anything: %s", len(rows), out)
	}
	// The oldest change point must still be readable — a trim in a young court takes
	// nothing, and `keep` must never have underflowed.
	if want := strconv.FormatUint(uint64(first), 10) + ":"; !strings.HasPrefix(rows[0], want) {
		t.Fatalf("the oldest change point was trimmed away: first row %q, want "+
			"epoch %d — full read %s", rows[0], first, out)
	}
	after, _ := collectSeriesKeyed(a, &cs.yesH, key)
	if len(after) < len(pts) {
		t.Fatalf("the ride freed %d archived points in a court too young to trim "+
			"anything", len(pts)-len(after))
	}
}

// ONE RIDE FREES EXACTLY TWO PAGES, which is the whole content of trimBudget and
// was the last of the six recorded constant gaps left undecided. The note said
// settling it needed a probe for an observable difference rather than an argument,
// because if the series converges to the same state at every budget then nothing
// can tell two budgets apart and the row is INVALID rather than a survivor.
//
// IT IS OBSERVABLE, and Trim's own arithmetic says exactly when. With C candidate
// pages and a budget b, Trim collects b+1 keys and deletes b when C >= b+1;
// otherwise the walk exhausts the candidates and it deletes C-1, sparing the
// newest all-below page. So two budgets differ only where C >= b+1 holds for the
// smaller one: at four candidate pages a budget of 2 deletes two and leaves the
// THIRD page's point as the oldest, while any budget of 3 or more deletes three
// and leaves the fourth.
//
// FOUR CANDIDATE PAGES IS WHY PRODUCTION NEVER SEES A DIFFERENCE, and why the
// constant reads as unpinnable at first glance: a trim rides every touched hour
// and production adds at most one candidate page per 32 changed epochs, so C is
// never above 1 or 2 while anything is touching the claim. Candidates only pile up
// across a GAP in which nobody touches it, which is what the 400-hour skip builds.
//
// SIX POINTS, NOT FOUR, because Trim never touches the two inline points: the
// Series keeps the newest two itself and only the older four reach the archive.
// A four-point fixture archives two pages, both budgets delete one, and the test
// would have passed against every mutation while looking like coverage.
//
// The expectation is the literal offset 64 — two pages of 32 — and never
// `trimBudget*PageEpochs`, which would move with the code it is meant to hold
// still. Nothing here reads the ambient height either: the fixture opens its own
// claim, whose series starts empty, and builds its own room.
func TestOneTrimRideFreesExactlyTwoArchivePages(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tbud-alice")
	testCourt(cur, "tbud", alice, 40_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "tbud", "six pages of history and one ride")

	c := mustCourt("tbud")
	cs := mustClaim(c, id)
	a := ensureCSArch(c)
	key := csKey(cs.id, "yh")

	// The next page boundary at or above the current hour, taken BEFORE the skip so
	// every point below lands in the past. heightNow(), not testingHeight(): the
	// production clock is floored by tcHeightFloor and freezable by an armed test
	// clock, so it can sit a long way from runtime.ChainHeight(), and recordPools
	// reads heightNow(). The first draft placed points against the wrong clock and
	// panicked with "the clock went backwards".
	base := ((hourEpochAt(heightNow()) / 32) + 1) * 32
	testing.SkipHeights(epochBlocks * 400)
	for k := uint32(0); k < 6; k++ {
		cs.yesH.SetAt(a, key, base+k*32, int64(k+1)*1_000_000)
	}
	before, capped := collectSeriesKeyed(a, &cs.yesH, key)
	if len(before) != 6 {
		t.Fatalf("setup: six change points, one per page, got %d", len(before))
	}
	if capped {
		t.Fatal("setup: the row cap must not be involved, or a loss below is not the trim's")
	}

	recordPools(c, cs) // ONE ride of the production path

	after, _ := collectSeriesKeyed(a, &cs.yesH, key)
	// SIX BECOME FIVE, and the arithmetic is worth spelling out because the obvious
	// guard is satisfied by the wrong number. The ride frees two pages AND appends a
	// point for the current hour, so a budget of ONE also lands on six — an earlier
	// draft guarded `len(after) >= len(before)` and reported that as "the ride must
	// free something", which is a real defect wearing a broken fixture's words. This
	// file's header already tells that story once; this is the same trap.
	if len(after) != 5 {
		t.Errorf("the ride left %d points, want 5: two pages freed and one point "+
			"appended for the current hour, from six", len(after))
	}
	if got := after[0].e; got != base+64 {
		t.Errorf("one ride left the oldest surviving point at base+%d, want base+64: a "+
			"ride that frees two pages leaves the THIRD point as the oldest, and any "+
			"other offset is a different budget", got-base)
	}
}
