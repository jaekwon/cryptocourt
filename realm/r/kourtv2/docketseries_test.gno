package kourtv2

import (
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
)

// DocketSeries exists to be ONE read where the overlay used four per claim, so
// the property that matters is not "it returns a string" — it is that every
// field equals what the single-claim reader would have said. A packed reader
// that drifts from the readers it replaces is worse than the four queries it
// saved, because the docket would draw a ratio the claim page contradicts.
func TestDocketSeriesAgreesWithTheReadersItReplaces(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ds-alice")
	bob := testutils.TestAddress("ds-bob")
	testCourt(cur, "ds", alice, 20_000_000_000)
	c := mustCourt("ds")
	c.coin.Mint(bob, 20_000_000_000)

	ids := []uint64{}
	for i := 0; i < 3; i++ {
		testing.SetRealm(testing.NewUserRealm(alice))
		ids = append(ids, OpenClaim(cross(cur), "ds", "claim "+strconv.Itoa(i)))
	}
	// Different shapes: one YES-heavy, one NO-heavy, one untouched — so a field
	// that is accidentally constant cannot pass.
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "ds", ids[0], sideYES, 3_000_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "ds", ids[0], sideNO, 1_000_000_000)
	testing.SkipHeights(50)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "ds", ids[1], sideNO, 2_000_000_000)
	testing.SkipHeights(50)

	const window = int64(120960)
	list := strconv.FormatUint(ids[0], 10) + "," + strconv.FormatUint(ids[1], 10) +
		"," + strconv.FormatUint(ids[2], 10)
	rows := strings.Split(DocketSeries("ds", list, window), ";")
	if len(rows) != 3 {
		t.Fatalf("three claims asked for, %d rows back", len(rows))
	}
	for n, row := range rows {
		f := strings.Split(row, ":")
		if len(f) != 9 {
			t.Fatalf("row %d: want 9 fields, got %d (%q)", n, len(f), row)
		}
		id, err := strconv.ParseUint(f[0], 10, 64)
		if err != nil || id != ids[n] {
			t.Fatalf("row %d: id %q is not %d", n, f[0], ids[n])
		}
		yes, no := StakePools("ds", id)
		cy, cn := PoolConviction("ds", id)
		oi, oiM := TrailingOI("ds", id, window)
		ty, tyM := TrailingYes("ds", id, window)
		want := []string{
			f[0],
			strconv.FormatInt(yes, 10), strconv.FormatInt(no, 10),
			strconv.FormatInt(cy, 10), strconv.FormatInt(cn, 10),
			strconv.FormatInt(oi, 10), boolDigit(oiM),
			strconv.FormatInt(ty, 10), boolDigit(tyM),
		}
		for i := range want {
			if f[i] != want[i] {
				t.Fatalf("row %d field %d: packed %q, single reader says %q",
					n, i, f[i], want[i])
			}
		}
	}
	// and the numbers are not all zero, or the comparison above is vacuous
	if strings.Split(rows[0], ":")[1] == "0" {
		t.Fatal("the fixture staked nothing — the agreement check proves nothing")
	}
}

// An id this court does not have is SKIPPED, never guessed and never a panic:
// the overlay hands it whatever ids its docket page is showing, and a claim can
// be closed or a page can be stale.
func TestDocketSeriesSkipsWhatItDoesNotHave(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ds2-alice")
	testCourt(cur, "ds2", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "ds2", "the only claim")

	got := DocketSeries("ds2", "999,"+strconv.FormatUint(id, 10)+",abc,,4242", int64(120960))
	rows := strings.Split(got, ";")
	if len(rows) != 1 {
		t.Fatalf("only one of those ids exists, got %d rows: %q", len(rows), got)
	}
	if !strings.HasPrefix(rows[0], strconv.FormatUint(id, 10)+":") {
		t.Fatalf("the row that came back is not the claim that exists: %q", rows[0])
	}
	if DocketSeries("ds2", "", int64(120960)) != "" {
		t.Fatal("no ids asked for is the empty reply, not a panic")
	}
	if DocketSeries("ds2", "999", int64(120960)) != "" {
		t.Fatal("no ids matched is the empty reply")
	}
}

// The cap is real. Without it one query could be asked to walk every claim in a
// court, which is the cost this function exists to bound.
func TestDocketSeriesCapsOneReply(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ds3-alice")
	testCourt(cur, "ds3", alice, 200_000_000_000)
	asked := []string{}
	for i := 0; i < seriesPageMax+5; i++ {
		testing.SetRealm(testing.NewUserRealm(alice))
		id := OpenClaim(cross(cur), "ds3", "claim "+strconv.Itoa(i))
		asked = append(asked, strconv.FormatUint(id, 10))
	}
	rows := strings.Split(DocketSeries("ds3", strings.Join(asked, ","), int64(120960)), ";")
	if len(rows) != seriesPageMax {
		t.Fatalf("asked for %d, want %d back, got %d", len(asked), seriesPageMax, len(rows))
	}
}
