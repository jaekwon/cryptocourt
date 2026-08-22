package kourtv2

import (
	"testing"

	checkpoint "gno.land/p/kourt/checkpoint/v0"

	testutils "gno.land/p/nt/testutils/v0"
)

// THE ROW CAP AT ITS OWN BOUNDARY. seriesRowCap is the promise that this read's cost
// cannot be grown without bound by attacker-priced writes (audit N3), and the `more`
// flag is how a client learns the history it got is not all of it. An operator sweep
// of every cap comparison in the realm found this one unrowed and its boundary
// unpinned: `if len(pts) >= seriesRowCap` widened to `>` SURVIVED the whole suite.
//
// WHAT THAT MUTATION ACTUALLY DOES, which is worse than one extra point. The walk
// sets `more` when it MEETS the cap, so widening the test to `>` means it never fires
// at all on a history of exactly seriesRowCap+1: at len(pts) == 400 the check
// `400 > 400` is false, the 401st point is appended, the walk then ends with nothing
// left to reject, and `more` stays FALSE. So the read returns one point past its
// documented cap AND tells the client it has the complete history. The flag flips
// from true to false, which is why this test asserts the flag rather than a length.
//
// ON THE DAILY GRAIN, deliberately, because that is the one where the cap is
// reachable. The hourly series is trimmed to hourlyKeep = 168 entries, so it can
// never hold 400 archived points in production; the daily series "serves the claim's
// whole life" and is never trimmed, so 401 daily change points is 401 days of a
// claim whose pools moved — long, but a state the design intends to survive.
//
// Points go straight into the archive, the idiom TestAYoungCourtsHourlyHistory-
// SurvivesEveryTrimRide established and measured: driving them through real Stake
// calls costs 8x for a fixture whose subject is the read, not how the pools got there.
func TestTheSeriesRowCapHoldsAtExactlyItsOwnBoundary(cur realm, t *testing.T) {
	alice := testutils.TestAddress("scap-alice")
	testCourt(cur, "scap", alice, 40_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "scap", "four hundred days of stake")

	c := mustCourt("scap")
	cs := mustClaim(c, id)
	a := ensureCSArch(c)

	// Past the oldest point written below, or the epochs would run negative.
	testing.SkipHeights(dailyBlocks * int64(seriesRowCap+10))
	now := uint32(heightNow()/dailyBlocks) + 1

	// ONE OVER THE CAP on the yes side: the cap must bind and say so.
	//
	// WRITE THREE MORE THAN THAT, because SetAt keeps the two newest values in the
	// Series' own inline slots and only rolls older ones into the archive — measured
	// at 20 written, 18 archived. The cap counts ARCHIVED entries only, so a fixture
	// that wrote exactly seriesRowCap+1 archived two fewer than it meant to and left
	// the cap slack. That is what the first version of this test did, and it failed
	// against correct code: 401 points came back with the flag clear, because 399 of
	// them were archived and the other two were the inline pair.
	overKey := csKey(cs.id, "yd")
	overWant := seriesRowCap + 1
	first := now - uint32(overWant) - 2
	for k := 0; k <= overWant+1; k++ {
		cs.yesD.SetAt(a, overKey, first+uint32(k), int64(k+1)*1_000_000)
	}
	// EXACTLY the cap on the no side: the flag must stay clear. This is the arm that
	// makes the assertion above mean something — without it, `capped` reporting true
	// for everything would pass — and it has to sit at the LAST LEGAL VALUE rather
	// than at some comfortable count, because a cap that fires one row early is the
	// other half of the same off-by-one.
	atKey := csKey(cs.id, "nd")
	firstAt := now - uint32(seriesRowCap) - 1
	for k := 0; k <= seriesRowCap+1; k++ {
		cs.noD.SetAt(a, atKey, firstAt+uint32(k), int64(k+1)*2_000_000)
	}

	over, overCapped := collectSeriesKeyed(a, &cs.yesD, overKey)
	at, atCapped := collectSeriesKeyed(a, &cs.noD, atKey)

	// THE FIXTURE HAS TO HOLD WHAT IT CLAIMS, counted rather than assumed. The
	// inline/archived split is the checkpoint package's business and this test must
	// not depend on it staying two: it counts the archived entries and refuses to
	// proceed unless they sit exactly on the two sides of the cap. Without this the
	// arms below pass or fail for reasons that have nothing to do with the cap.
	if n := archived(a, overKey); n != seriesRowCap+1 {
		t.Fatalf("setup: the over-cap side must archive exactly %d entries, has %d",
			seriesRowCap+1, n)
	}
	if n := archived(a, atKey); n != seriesRowCap {
		t.Fatalf("setup: the at-cap side must archive exactly %d entries, has %d",
			seriesRowCap, n)
	}

	if !overCapped {
		t.Fatalf("a history of %d change points exceeds the row cap of %d, so the "+
			"read must report that older points were dropped; it reported a complete "+
			"history of %d points", seriesRowCap+1, seriesRowCap, len(over))
	}
	if atCapped {
		t.Fatalf("a history of exactly %d change points fits the row cap, so nothing "+
			"was dropped and the read must not say otherwise (%d points returned)",
			seriesRowCap, len(at))
	}
}

// archived counts what is in the archive under one key, which is the population the
// row cap actually governs — the Series' inline pair is appended after the cap and is
// not subject to it.
func archived(a *checkpoint.Archive, key string) int {
	n := 0
	a.WalkDesc(key, func(_ uint32, _ int64) bool { n++; return false })
	return n
}
