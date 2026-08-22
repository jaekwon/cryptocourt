package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// THE PARTICIPANT-ONLY WINDOWS END ON THEIR EXACT BLOCK, and neither end was pinned.
//
// Two functions carry the same shape with different bases:
//
//	Crystallize  if now < cs.verdictAt+finalizeGraceBlocks   && !isParticipant(…)
//	Finalize     if now < cs.escrowUntil+finalizeGraceBlocks && !isParticipant(…)
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
