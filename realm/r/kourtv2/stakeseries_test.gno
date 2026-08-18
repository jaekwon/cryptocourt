package kourtv2

import (
	"strconv"
	"strings"
	"testing"

	checkpoint "gno.land/p/kourt/checkpoint/v0"
	testutils "gno.land/p/nt/testutils/v0"
)

// hourEpochAt / dayEpochAt mirror recordPools' clocks for assertions. The
// widths in the EXPECTED strings below are written as literals (720, 17280),
// independently of the constants, so a constant edit cannot silently agree
// with itself.
func hourEpochAt(h int64) uint32 { return uint32(h/720) + 1 }
func dayEpochAt(h int64) uint32  { return uint32(h/17280) + 1 }

func seriesHeader(grain string, width int64, now uint32, more string) string {
	return grain + "," + strconv.FormatInt(width, 10) + "," +
		strconv.FormatUint(uint64(now), 10) + "," + more + ";"
}

// TestClaimSeriesGrammar pins the exact output byte-for-byte across a staged
// history — the grammar IS the API a chart parses.
func TestClaimSeriesGrammar(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cs-alice")
	_ = testCourt(cur, "cs1", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "cs1", "Does the record hold?")

	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "cs1", id, sideYES, 41_000_000)
	h1 := testingHeight()
	e1h, e1d := hourEpochAt(h1), dayEpochAt(h1)

	testing.SkipHeights(720 * 28) // 28 hours: a new hour AND a new day
	Stake(cross(cur), "cs1", id, sideNO, 12_000_000)
	h2 := testingHeight()
	e2h, e2d := hourEpochAt(h2), dayEpochAt(h2)

	testing.SkipHeights(720 * 3)
	Unstake(cross(cur), "cs1", id, sideYES, 1_000_000)
	h3 := testingHeight()
	e3h, e3d := hourEpochAt(h3), dayEpochAt(h3)

	testing.SkipHeights(720 * 5) // quiet epochs: rows must NOT grow
	nowH := testingHeight()

	rowsH := strconv.FormatUint(uint64(e1h), 10) + ":41000000:0," +
		strconv.FormatUint(uint64(e2h), 10) + ":41000000:12000000," +
		strconv.FormatUint(uint64(e3h), 10) + ":40000000:12000000"
	wantH := seriesHeader("hourly", 720, hourEpochAt(nowH), "0") + rowsH
	if got := ClaimSeries("cs1", id, "hourly"); got != wantH {
		t.Errorf("hourly grammar:\n got %q\nwant %q", got, wantH)
	}

	if e1d == e2d || e2d != e3d {
		t.Fatalf("fixture day epochs drifted: %d %d %d", e1d, e2d, e3d)
	}
	// Day 2 holds two changes; they coalesce to the LAST value in the bucket.
	rowsD := strconv.FormatUint(uint64(e1d), 10) + ":41000000:0," +
		strconv.FormatUint(uint64(e2d), 10) + ":40000000:12000000"
	wantD := seriesHeader("daily", 17280, dayEpochAt(nowH), "0") + rowsD
	if got := ClaimSeries("cs1", id, "daily"); got != wantD {
		t.Errorf("daily grammar:\n got %q\nwant %q", got, wantD)
	}

	// Live agreement: the newest row equals StakePools right now.
	y, n := StakePools("cs1", id)
	if y != 40_000_000 || n != 12_000_000 {
		t.Errorf("live pools = %d/%d, want 40000000/12000000", y, n)
	}
	// Purity: identical bytes on a re-read.
	if a, b := ClaimSeries("cs1", id, "hourly"), ClaimSeries("cs1", id, "hourly"); a != b {
		t.Error("ClaimSeries is not deterministic across back-to-back reads")
	}
}

func TestClaimSeriesEmptyAndRefusals(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cs-b")
	c := testCourt(cur, "cs2", alice, 1_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "cs2", "Never staked?")
	_ = c

	want := seriesHeader("hourly", 720, hourEpochAt(testingHeight()), "0")
	if got := ClaimSeries("cs2", id, "hourly"); got != want {
		t.Errorf("empty series = %q, want header-only %q", got, want)
	}

	defer func() {
		r := recover()
		if r == nil || !strings.Contains(r.(string), `grain is "hourly" or "daily"`) {
			t.Errorf("bad grain must refuse with the exact message, got %v", r)
		}
	}()
	ClaimSeries("cs2", id, "weekly")
}

// TestClaimSeriesNoChangeNoStorage pins the owner's requirement directly: a
// value that does not move stores nothing, at either grain.
func TestClaimSeriesNoChangeNoStorage(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cs-c")
	c := testCourt(cur, "cs3", alice, 1_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "cs3", "Quiet?")
	Stake(cross(cur), "cs3", id, sideYES, 5_000_000)
	pagesAfterFirst := c.csArch.Size()

	// Stake the SAME side by zero-effect ops is impossible; instead: many
	// quiet epochs, then re-read. No writes ⇒ no new pages, and the NO series
	// never came into existence at all.
	testing.SkipHeights(720 * 200)
	if got := c.csArch.Size(); got != pagesAfterFirst {
		t.Errorf("pages grew across silence: %d -> %d", pagesAfterFirst, got)
	}
	cs := mustClaim(c, id)
	if e0 := cs.noH.Since(); e0 != 0 {
		t.Errorf("the untouched NO series has a point (epoch %d) — the guard leaked a write", e0)
	}
	// One row, forever; now advances past it.
	got := ClaimSeries("cs3", id, "hourly")
	if strings.Count(got, ":") != 2 {
		t.Errorf("expected exactly one row after silence, got %q", got)
	}
}

// TestClaimSeriesTrimAndRouting drives ~200 changed hourly epochs and pins:
// the hourly tier keeps a bounded page count, answers exactly inside its
// window, and the daily tier answers below the horizon.
func TestClaimSeriesTrimAndRouting(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cs-d")
	c := testCourt(cur, "cs4", alice, 100_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "cs4", "Does the trim hold the week?")

	// A change every hour for 200 hours: alternate 1-unit stakes.
	for k := 0; k < 200; k++ {
		Stake(cross(cur), "cs4", id, sideYES, 1_000)
		testing.SkipHeights(720)
	}
	cs := mustClaim(c, id)

	// Bound the archived ENTRY count: 168 kept epochs plus at most a spared
	// below-horizon page and a straddler (≤ 64 more).
	entries := 0
	c.csArch.WalkDesc(csKey(id, "yh"), func(e uint32, v int64) bool { entries++; return false })
	if entries > 168+64 {
		t.Errorf("hourly archive holds %d entries — the trim is not keeping up", entries)
	}

	// Inside the window: the hourly read answers, ascending, ending at the
	// live value.
	got := ClaimSeries("cs4", id, "hourly")
	if !strings.HasSuffix(got, ":200000:0") {
		t.Errorf("hourly must end at the live pools, got tail of %q", got[len(got)-40:])
	}
	// Below the horizon the daily tier carries the early history: its first
	// row is the FIRST day's close, which the hourly tier no longer holds.
	daily := ClaimSeries("cs4", id, "daily")
	body := strings.SplitN(daily, ";", 2)[1]
	first := strings.SplitN(body, ",", 2)[0]
	if !strings.HasSuffix(first, ":24000:0") {
		t.Errorf("daily first row should be day 1's close (24 hourly stakes), got %q", first)
	}
	_ = cs
}

// TestClaimSeriesFreeze pins that the record stops at the freeze and the
// read keeps answering the frozen pools forever after.
func TestClaimSeriesFreeze(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cs-e")
	bob := testutils.TestAddress("cs-f")
	c := testCourt(cur, "cs5", alice, 10_000_000_000)
	c.coin.Mint(bob, 5_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "cs5", "Frozen record?")
	Stake(cross(cur), "cs5", id, sideYES, 30_000_000)
	testing.SkipHeights(720 * 2)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "cs5", id, sideNO, 10_000_000)

	// Answerability needs matured trailing history; take the local shortcut
	// used by the freeze tests: freeze directly, in-package.
	cs := mustClaim(c, id)
	testing.SkipHeights(100)
	touch(c)
	cs.frozenAt = testingHeight()
	cs.rateAccAtFreeze = c.rateAccFP

	before := ClaimSeries("cs5", id, "hourly")
	testing.SkipHeights(720 * 50)
	after := ClaimSeries("cs5", id, "hourly")
	// Only the header's `now` may differ.
	bBody := strings.SplitN(before, ";", 2)[1]
	aBody := strings.SplitN(after, ";", 2)[1]
	if bBody != aBody {
		t.Errorf("rows moved after the freeze:\n before %q\n after  %q", bBody, aBody)
	}
	y, n := StakePools("cs5", id)
	if !strings.HasSuffix(aBody, ":"+strconv.FormatInt(y, 10)+":"+strconv.FormatInt(n, 10)) {
		t.Errorf("frozen series must still end at the frozen pools %d/%d, got %q", y, n, aBody)
	}
}

// TestClaimSeriesLazyInitOldObjects simulates a pre-upgrade claim: zeroed
// series fields and a nil court archive must self-heal on the next op.
func TestClaimSeriesLazyInitOldObjects(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cs-g")
	c := testCourt(cur, "cs6", alice, 1_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "cs6", "Old object?")
	cs := mustClaim(c, id)

	// Zero everything the feature added, as a persisted pre-upgrade object
	// would deserialize.
	cs.yesH = checkpoint.Series{}
	cs.noH = checkpoint.Series{}
	cs.yesD = checkpoint.Series{}
	cs.noD = checkpoint.Series{}
	cs.histTrimmedTo = 0
	c.csArch = nil

	// Reads tolerate the nil archive (header-only output)…
	want := seriesHeader("hourly", 720, hourEpochAt(testingHeight()), "0")
	if got := ClaimSeries("cs6", id, "hourly"); got != want {
		t.Errorf("nil-archive read = %q, want %q", got, want)
	}
	// …and the next stake op begins the history with no panic.
	Stake(cross(cur), "cs6", id, sideYES, 2_000_000)
	if c.csArch == nil {
		t.Fatal("the write path must lazily create the archive")
	}
	got := ClaimSeries("cs6", id, "hourly")
	if !strings.HasSuffix(got, ":2000000:0") {
		t.Errorf("history must begin at the eligibility op, got %q", got)
	}
}
