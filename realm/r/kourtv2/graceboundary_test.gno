package kourtv2

import (
	"testing"
	"time"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// THE PARTICIPANT-ONLY WINDOWS END ON THEIR EXACT EDGE, and neither end was pinned.
//
// Two functions carry the same shape with different bases:
//
//	Crystallize  participant-only until verdictAtTime+finalizeGraceSecs (blocks as fallback)
//	Finalize     if now < cs.escrowUntil+finalizeGraceBlocks && !isParticipant(…)
//
// Crystallize reads seconds since the conversion; Finalize is still on blocks and
// converts next. Both edges still land on the same block HERE, because
// testing.SkipHeights advances time by exactly 5s per block and finalizeGraceSecs
// is exactly finalizeGraceBlocks×5 — which is precisely why this test cannot tell
// the two clocks apart, and why the one below exists to separate them.
//
// An operator sweep flipped `<` to `<=` and nothing failed: every existing use of
// finalizeGraceBlocks skips a week PAST the edge, so the edge itself was never visited.
// One block either way decides whether a stranger may end a claim, which is a
// permissionless action on somebody else's money — the same class as the quorum floor and
// the overturn threshold, both of which turned out unpinned at their exact values too.
//
// Each half is paired: a stranger refused one block early and allowed on the block itself,
// and a PARTICIPANT allowed while the window is still shut — because a window that refused
// everybody would satisfy the refusal half on its own.
func TestTheParticipantOnlyWindowsEndOnTheirExactBlock(cur realm, t *testing.T) {
	// ---- HALF ONE: Finalize, based on cs.escrowUntil ----
	author := testutils.TestAddress("gb-author")
	staker := testutils.TestAddress("gb-staker")
	stranger := testutils.TestAddress("gb-stranger")
	c := testCourt(cur, "gb", author, 60_000_000_000)
	c.coin.Mint(staker, 20_000_000_000)
	c.coin.Mint(stranger, 5_000_000_000)

	// Two claims, and the PAIRING one is built first on purpose: building a claim
	// advances the clock by a voting window plus an escrow window, so a claim built
	// second would push the first one's grace edge into the past. Found by the
	// assertion below reporting a height 156,965 blocks beyond its own target.
	pair := parkedClaim(cur, c, "gb", author, staker)

	// A participant may act while the window is shut. This runs first because it
	// proves the window is a window and not a wall.
	pcs := mustClaim(c, pair)
	if heightNow() >= pcs.escrowUntil+finalizeGraceBlocks {
		t.Fatal("fixture: already past the grace window, nothing is being tested")
	}
	testing.SetRealm(testing.NewUserRealm(staker)) // the disputer, a participant
	Finalize(cross(cur), "gb", pair)
	uassert.True(t, mustClaim(c, pair).verdictAt != 0)

	// Now the edge claim, built after the pairing is spent so its window is still
	// ahead of us.
	edge := parkedClaim(cur, c, "gb", author, staker)
	ecs := mustClaim(c, edge)
	target := ecs.escrowUntil + finalizeGraceBlocks
	if d := target - 1 - heightNow(); d > 0 {
		testing.SkipHeights(d)
	}
	uassert.Equal(t, target-1, heightNow())
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "participant-only", func() {
		Finalize(cross(cur), "gb", edge)
	})

	// And on the block itself the stranger may act. `<` and `<=` differ here and
	// nowhere else.
	testing.SkipHeights(1)
	uassert.Equal(t, target, heightNow())
	testing.SetRealm(testing.NewUserRealm(stranger))
	Finalize(cross(cur), "gb", edge)
	uassert.True(t, mustClaim(c, edge).verdictAt != 0)

	// ---- HALF TWO: Crystallize, based on cs.verdictAt ----
	// Same shape, different base, and the same pairing-first ordering for the same
	// reason. No flag ever opens on these, so lastFlagEventAt stays 0 and the 24h
	// priority window is long behind us — the grace edge is what is being tested.
	//
	// Since the conversion this half exercises the SECONDS arm, not the height one:
	// settledClaim goes through SettleUndisputed, which stamps verdictAtTime, so
	// `known` is true and the block arithmetic below is never consulted. The block
	// targets still compute the right edge for the reason in the header — 5s a
	// block, both ways — so the arithmetic is kept as the reader's landmark. What
	// it no longer is, is the thing under test.
	cpair := settledClaim(cur, c, "gb", author, staker)
	ccs := mustClaim(c, cpair)
	if heightNow() >= ccs.verdictAt+finalizeGraceBlocks {
		t.Fatal("fixture: already past the grace window, nothing is being tested")
	}
	testing.SetRealm(testing.NewUserRealm(author)) // the author, a participant
	Crystallize(cross(cur), "gb", cpair)
	uassert.True(t, mustClaim(c, cpair).crystallized)

	cedge := settledClaim(cur, c, "gb", author, staker)
	ecs2 := mustClaim(c, cedge)
	target2 := ecs2.verdictAt + finalizeGraceBlocks
	if d := target2 - 1 - heightNow(); d > 0 {
		testing.SkipHeights(d)
	}
	uassert.Equal(t, target2-1, heightNow())
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "participant-only", func() {
		Crystallize(cross(cur), "gb", cedge)
	})
	testing.SkipHeights(1)
	uassert.Equal(t, target2, heightNow())
	testing.SetRealm(testing.NewUserRealm(stranger))
	Crystallize(cross(cur), "gb", cedge)
	uassert.True(t, mustClaim(c, cedge).crystallized)
}

// A WEEK IS SEVEN DAYS, AND ON A SLOW CHAIN THAT IS NOT 120,960 BLOCKS.
//
// The test above cannot tell the two clocks apart, for the reason in its header:
// SkipHeights moves both at the fixed 5s ratio the block constants assume. A real
// chain does not hold that ratio, and kourt-1 did not — a claim settled 7 Apr 2022
// was STILL refusing strangers on 15 Dec 2026, because 1,713 days had elapsed but
// only 53,280 blocks of a 120,960-block window. The realm was not wrong; it was
// answering in the wrong unit. That was the reported bug and this is its test.
//
// So the clocks are separated by hand: advance TIME past the week while leaving
// HEIGHT far short of the block window. On the block arithmetic this reads as day
// four of seven and refuses; on the wall clock the week is over and a stranger may
// end the claim. The second half then zeroes the stamp on an identical claim to
// prove the height arm still governs a pre-upgrade record — same wall clock, other
// answer, and the only difference is the missing stamp.
func TestTheCrystallizeGraceIsAWeekOfWallClockNotOfBlocks(cur realm, t *testing.T) {
	author := testutils.TestAddress("gw-author")
	staker := testutils.TestAddress("gw-staker")
	stranger := testutils.TestAddress("gw-stranger")
	c := testCourt(cur, "gw", author, 60_000_000_000)
	c.coin.Mint(staker, 20_000_000_000)

	// ---- THE STAMP GOVERNS ----
	id := settledClaim(cur, c, "gw", author, staker)
	cs := mustClaim(c, id)
	if cs.verdictAtTime == 0 {
		t.Fatal("fixture: no verdict stamp, so this would test the height fallback instead")
	}
	// Blocks must say the window is SHUT, or the wall clock is not what let the
	// stranger in and this test proves nothing.
	if heightNow() >= cs.verdictAt+finalizeGraceBlocks {
		t.Fatal("fixture: already past the grace window in blocks, nothing is being tested")
	}

	// Eight days of wall clock, no blocks at all — the divergence a slow chain
	// produces, in one step. GetContext/SetContext rather than SkipHeights
	// precisely because SkipHeights refuses to let the clocks disagree.
	beforeH := heightNow()
	ctx := testing.GetContext()
	ctx.Time = ctx.Time.Add(8 * 24 * time.Hour)
	testing.SetContext(ctx)
	uassert.Equal(t, beforeH, heightNow()) // time moved, height did not

	testing.SetRealm(testing.NewUserRealm(stranger))
	Crystallize(cross(cur), "gw", id)
	uassert.True(t, mustClaim(c, id).crystallized)

	// ---- AND A PRE-UPGRADE CLAIM STILL READS HEIGHT, TO ITS EXACT BLOCK ----
	// Built after the above so its own grace window is ahead of us again.
	//
	// This half also inherits a job the test above used to do. Before the
	// conversion, the `<` in the height arithmetic was pinned by HALF TWO of the
	// other test; now that a stamped claim never reaches that arithmetic, the only
	// way to hold `<` against `<=` is a claim with no stamp, sitting on the edge.
	// Without this the operator sweep would flip that comparison and nothing would
	// notice — which is exactly the hole the other test was written to close.
	old := settledClaim(cur, c, "gw", author, staker)
	ocs := mustClaim(c, old)
	ocs.verdictAtTime = 0 // the pre-upgrade shape: a height, no stamp
	target := ocs.verdictAt + finalizeGraceBlocks
	if d := target - 1 - heightNow(); d > 0 {
		testing.SkipHeights(d)
	}
	uassert.Equal(t, target-1, heightNow())

	// The wall clock ran forward through all of that and is now many weeks past
	// the verdict. It is not consulted, because there is no stamp to consult.
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "participant-only", func() {
		Crystallize(cross(cur), "gw", old)
	})
	testing.SkipHeights(1)
	uassert.Equal(t, target, heightNow())
	testing.SetRealm(testing.NewUserRealm(stranger))
	Crystallize(cross(cur), "gw", old)
	uassert.True(t, mustClaim(c, old).crystallized)
}

// settledClaim returns a claim settled undisputed, so verdictAt is set and no quality
// question is open.
func settledClaim(cur realm, c *Court, slug string, author, staker address) uint64 {
	id := stakeAnswerDispute(cur, slug, author, staker)
	testing.SkipHeights(settleDelay + 1)
	testing.SetRealm(testing.NewUserRealm(staker))
	SettleUndisputed(cross(cur), slug, id)
	cs := mustClaim(c, id)
	if cs.verdictAt == 0 {
		panic("settledClaim: not settled")
	}
	return id
}

// parkedClaim returns a claim with a provisional verdict and its escrow window already
// passed: answered, disputed, nobody voted, resolved on a failed quorum.
func parkedClaim(cur realm, c *Court, slug string, author, staker address) uint64 {
	id := stakeAnswerDispute(cur, slug, author, staker)
	testing.SetRealm(testing.NewUserRealm(staker))
	OpenDispute(cross(cur), slug, id)
	testing.SkipHeights(c.params.votingBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(staker))
	ResolveDispute(cross(cur), slug, id)
	cs := mustClaim(c, id)
	if cs.provisional < 0 || cs.escrowUntil == 0 {
		panic("parkedClaim: no provisional verdict to finalize")
	}
	if d := cs.escrowUntil - heightNow() + 1; d > 0 {
		testing.SkipHeights(d)
	}
	return id
}
