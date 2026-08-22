package kourtv2

import (
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// THE PACKING AND THE BUCKET BOUNDARY, as a unit — the part with no claims in it.
//
// Buckets are keyed by claimID/stakeIdxPage, so ids either side of a multiple of 64 land
// in DIFFERENT buckets and the walk has to put them back in order. That is the one place
// a packed, bucketed index can silently reorder or drop, and it needs no claim to test.
func TestTheStakeIndexPacksAndOrdersAcrossBuckets(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sidx-alice")
	other := testutils.TestAddress("sidx-other")
	c := testCourt(cur, "sidx", alice, 1_000_000)

	// Straddle the boundary deliberately, and insert out of order.
	for _, id := range []uint64{64, 1, 63, 200, 65} {
		indexPosition(c, id, alice, sideYES)
	}
	indexPosition(c, 1, alice, sideNO) // both sides of one claim
	indexPosition(c, 7, other, sideYES)

	if stakeIdxKey(alice, 63) == stakeIdxKey(alice, 64) {
		t.Fatal("63 and 64 share a bucket, so stakeIdxPage is not bucketing")
	}
	if stakeIdxKey(alice, 64) != stakeIdxKey(alice, 65) {
		t.Fatal("64 and 65 are in different buckets, so the page size is not 64")
	}

	var got []uint64
	var sides []int
	stakeIdxWalk(c, alice, func(id uint64, side int) bool {
		got = append(got, id)
		sides = append(sides, side)
		return false
	})
	// BUCKETS in claim-id order, ARRIVAL order within a bucket. The first version of
	// this test asserted a global ascending order and caught the truth: bucket 0 held
	// [1y, 63y, 1n] because that is when they arrived. Sorting within a bucket was
	// rejected rather than implemented — it would shift entries and break the offset
	// stability StakedPage's paging depends on.
	uassert.Equal(t, 6, len(got))
	uassert.Equal(t, uint64(1), got[0])  // bucket 0 first
	uassert.Equal(t, uint64(63), got[1]) // still bucket 0, arrived second
	uassert.Equal(t, uint64(1), got[2])  // claim 1's OTHER side, arrived third
	if sides[0] == sides[2] {
		t.Fatalf("both sides of claim 1 should appear once each, got sides %v", sides)
	}
	// Everything in bucket 0 precedes everything in bucket 1, whatever the arrival.
	uassert.Equal(t, uint64(64), got[3])
	uassert.Equal(t, uint64(65), got[4])
	uassert.Equal(t, uint64(200), got[5])

	// OFFSET STABILITY, which is what the arrival order buys: a later position on an
	// OLDER claim must not move the entries a client already paged past.
	firstTwo := StakedPage("sidx", alice, 0, 2)
	indexPosition(c, 2, alice, sideYES)
	uassert.Equal(t, firstTwo, StakedPage("sidx", alice, 0, 2))
	uassert.Equal(t, 7, StakedSize("sidx", alice))
	// The other holder's range is untouched by any of it.
	uassert.Equal(t, 1, StakedSize("sidx", other))

	// A non-address gets nothing rather than another holder's range.
	uassert.Equal(t, 0, StakedSize("sidx", address("g1")))
	uassert.Equal(t, "", StakedPage("sidx", address("g1"), 0, 0))
	// AND PAST THAT GUARD: the walk itself refuses a bucket key it did not write, so
	// a short prefix reads nothing even from inside. This is the half pruneVoteLocks
	// did not have, which is how one permissionless call could delete every
	// commitment in a court.
	inside := 0
	stakeIdxWalk(c, address("g1"), func(_ uint64, _ int) bool { inside++; return false })
	uassert.Equal(t, 0, inside)

	// The cap binds and paging walks the same order.
	uassert.Equal(t, 2, len(strings.Split(StakedPage("sidx", alice, 0, 2), ";")))
	uassert.Equal(t, 5, len(strings.Split(StakedPage("sidx", alice, 2, 0), ";")))
	if StakedPage("sidx", alice, 99, 0) != "" {
		t.Fatal("an offset past the end should be empty")
	}
}

// AND THE REAL PATH: staking records the position, the read reports the LIVE figure, and
// a fully withdrawn position stays listed at zero because its conviction may still be
// owed — there is no stakers.Remove in this realm and the row is also the participant
// test.
func TestStakingIsIndexedAndTheReadReportsLiveStake(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sidx2-alice")
	bob := testutils.TestAddress("sidx2-bob")
	c := testCourt(cur, "sidx2", alice, 40_000_000_000)
	c.coin.Mint(bob, 20_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id1 := OpenClaim(cross(cur), "sidx2", "First")
	testing.SetRealm(testing.NewUserRealm(alice))
	id2 := OpenClaim(cross(cur), "sidx2", "Second")

	// Nothing staked yet: the index is empty for bob, which is the fixture's own
	// precondition — otherwise the assertions below could pass on stale rows.
	uassert.Equal(t, 0, StakedSize("sidx2", bob))

	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "sidx2", id1, sideYES, 3_000_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "sidx2", id1, sideNO, 1_000_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "sidx2", id2, sideYES, 2_000_000_000)

	uassert.Equal(t, 3, StakedSize("sidx2", bob))
	page := StakedPage("sidx2", bob, 0, 0)
	// One read, three positions, each with the side and the live figure.
	// FIVE FIELDS: the conviction rides along now. It is asserted as a SHAPE plus a
	// property rather than a literal, because conviction is a stake-time integral and
	// pinning a number here would pin the fixture's block count instead of the format.
	parts := strings.Split(page, ";")
	uassert.Equal(t, 3, len(parts))
	for i, want := range []string{
		"c:" + itoa(int64(id1)) + ":0:3000000000:",
		"c:" + itoa(int64(id1)) + ":1:1000000000:",
		"c:" + itoa(int64(id2)) + ":0:2000000000:",
	} {
		if !strings.HasPrefix(parts[i], want) {
			t.Fatalf("record %d is %q, want the prefix %q", i, parts[i], want)
		}
		if len(strings.Split(parts[i], ":")) != 5 {
			t.Fatalf("record %d must carry five fields, got %q", i, parts[i])
		}
	}

	// AND THE CONVICTION FIELD MUST BE ABLE TO BE NON-ZERO, or every assertion above
	// holds for a page that reports a constant. Conviction is a stake-time integral, so
	// it is zero until blocks pass: let some pass, then read it back and compare against
	// what ConvictionOf answers for the same position — one formula, two readers, and
	// this is the assertion that keeps them one.
	testing.SkipHeights(5_000)
	rec := strings.Split(strings.Split(StakedPage("sidx2", bob, 0, 1), ";")[0], ":")
	if len(rec) != 5 {
		t.Fatalf("setup: the record must carry five fields, got %v", rec)
	}
	if rec[4] == "0" {
		t.Fatal("after 5,000 blocks a live position must report some conviction")
	}
	if want := itoa(ConvictionOf("sidx2", id1, sideYES, bob)); rec[4] != want {
		t.Fatalf("the page's conviction is %s and ConvictionOf says %s — the two "+
			"readers have drifted", rec[4], want)
	}

	// Withdraw one in full. The entry REMAINS, at zero.
	testing.SetRealm(testing.NewUserRealm(bob))
	Unstake(cross(cur), "sidx2", id2, sideYES, 2_000_000_000)
	uassert.Equal(t, 3, StakedSize("sidx2", bob))
	if !strings.Contains(StakedPage("sidx2", bob, 0, 0), "c:"+itoa(int64(id2))+":0:0:") {
		t.Fatalf("a fully withdrawn position must stay listed at zero, since its "+
			"conviction may still be owed: %s", StakedPage("sidx2", bob, 0, 0))
	}
	// Staking again on it does not duplicate the entry.
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "sidx2", id2, sideYES, 500_000_000)
	uassert.Equal(t, 3, StakedSize("sidx2", bob))

	// THE INDEX AGREES WITH cs.stakers, which is the invariant the whole thing rests
	// on. cs.id is the index's only source for the claim id and has no other reader
	// on this path, so it is checked here too.
	stakeIdxWalk(c, bob, func(claimID uint64, side int) bool {
		cs := mustClaim(c, claimID)
		if cs.id != claimID {
			t.Fatalf("cs.id %d is not the id it is stored under (%d)", cs.id, claimID)
		}
		if cs.stakers.Get(posKey(bob, side)) == nil {
			t.Fatalf("the index lists claim %d side %d with no stakers row",
				claimID, side)
		}
		return false
	})
}
