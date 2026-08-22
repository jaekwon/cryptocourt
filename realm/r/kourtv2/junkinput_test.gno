package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// JUNK IN, NOTHING OUT — every exported read that takes a caller-supplied address.
//
// WHY THIS FILE EXISTS. `address` in gno is a bare declared string type with no length
// invariant, and nothing at the ABI boundary validates it: any string is a legal address
// argument to any exported function. The realm learned what that costs the expensive way
// — PruneVoteLocks prefix-scanned on an unvalidated `who`, so a stranger passing "g1"
// matched every holder's rows and the prune deleted them all as unreadable. A voter's
// entire commitment, destroyed by one free call.
//
// The corpus could not have caught it. It mutates this realm's CODE and every test in it
// passed a real address, so the whole input domain was unexamined. This is the sweep that
// examines it, and it is written generically on purpose: the property is not about one
// function, it is that no read hands a caller another holder's state because they typed
// something that was not an address.
//
// EVERY ASSERTION IS PAIRED. Each junk call sits beside the same call with a REAL address
// that returns something non-trivial, so a reader can see the fixture is rich enough for
// the junk answer to mean anything. Without that pairing "returns zero" is what a broken
// fixture returns too.
//
// WHAT THIS CATCHES, MEASURED, AND WHAT IT DOES NOT. It caught nothing when written —
// every one of these readers already refuses a non-address — so the honest question was
// whether it CAN fail. Removing any ONE protection leaves it green, because three layers
// overlap: the IsValid check at the door, the key-length check inside each prefix scan
// (stakeIdxMine, voteLockParts), and the kind switch that a shifted decode falls through.
// Remove the door check AND the length check together and it fires: a junk address
// returned the holder's three positions where zero was expected.
//
// So this file is BREADTH, not depth. It is the net that says all eighteen exported reads
// still refuse a non-address, across four shapes of junk, after any future change — and
// no single-mutation corpus row can be written for it, because each layer masks the next.
// The depth belongs where it already is: the unit tests that call the internal walks
// directly, past the door, so the inner layers are pinned on their own.
func TestNoReadAnswersForANonAddress(cur realm, t *testing.T) {
	alice := testutils.TestAddress("jk-alice")
	whale := testutils.TestAddress("jk-whale")
	holder := testutils.TestAddress("jk-holder")
	spender := testutils.TestAddress("jk-spender")
	// A separate voter, because a staker is a participant and Q2 bars them from the
	// verdict — the two halves of the fixture cannot be the same address.
	voter := testutils.TestAddress("jk-voter")
	newMod := testutils.TestAddress("jk-newmod")
	c := testCourt(cur, "jk", alice, 40_000_000_000)
	c.coin.Mint(whale, 60_000_000_000)
	c.coin.Mint(holder, 20_000_000_000)
	c.coin.Mint(voter, 10_000_000_000)

	// A rich position: a claim, an answer, a dispute, a stake, a vote, an allowance,
	// a moderator. Everything below reads some part of it.
	// Built by hand rather than via stakeAnswerDispute: the answer FREEZES staking,
	// so the holder's position has to exist before it.
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "jk", "Junk input sweep")
	matureOI(cur, "jk", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(holder))
	Stake(cross(cur), "jk", id, sideYES, 3_000_000_000)
	testing.SetRealm(testing.NewUserRealm(whale))
	Stake(cross(cur), "jk", id, sideNO, 300_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "jk", id, sideYES)
	testing.SetRealm(testing.NewUserRealm(whale))
	OpenDispute(cross(cur), "jk", id)
	testing.SetRealm(testing.NewUserRealm(voter))
	VoteDispute(cross(cur), "jk", id, "no")
	testing.SetRealm(testing.NewUserRealm(holder))
	ApproveCC(cross(cur), "jk", spender, 5_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	AppointMods(cross(cur), "jk", 1, newMod)

	// THE FIXTURE IS RICH: every one of these is non-trivial for the real holder, so
	// a zero from the junk call below is the guard and not an empty court.
	uassert.True(t, CoinBalanceOf("jk", holder) > 0)
	uassert.True(t, StakeOf("jk", id, sideYES, holder) > 0)
	uassert.True(t, VoteLockedOf("jk", voter) > 0)
	uassert.True(t, DisposableOf("jk", holder) >= 0 && LockedOf("jk", holder) >= 0)
	uassert.True(t, AllowanceCC("jk", holder, spender) > 0)
	uassert.True(t, StakedSize("jk", holder) > 0)
	uassert.True(t, StakedPage("jk", holder, 0, 0) != "")
	uassert.True(t, CommitmentsOf("jk", voter) != "")
	uassert.True(t, IsCourtMod("jk", newMod))
	if v, _ := ClaimVoteWeightOf("jk", voter, id); v <= 0 {
		t.Fatal("fixture: the voter has no verdict weight, so the junk case is moot")
	}

	// Four shapes of junk: empty, a plausible prefix, one char short of an address,
	// and one char over. The prefix is the one that mattered — it is what the prune
	// exploit used, because it looks like the start of every real address.
	real0 := string(holder)
	for _, bad := range []address{
		address(""),
		address("g1"),
		address(real0[:len(real0)-1]),
		address(real0 + "x"),
	} {
		uassert.Equal(t, int64(0), CoinBalanceOf("jk", bad))
		uassert.Equal(t, int64(0), StakeOf("jk", id, sideYES, bad))
		uassert.Equal(t, int64(0), ConvictionOf("jk", id, sideYES, bad))
		uassert.Equal(t, int64(0), VoteLockedOf("jk", bad))
		uassert.Equal(t, int64(0), LockedOf("jk", bad))
		uassert.Equal(t, int64(0), SpendableOf("jk", bad))
		uassert.Equal(t, int64(0), DisposableOf("jk", bad))
		uassert.Equal(t, int64(0), ElectionVoteWeightOf("jk", bad))
		uassert.Equal(t, int64(0), FranchiseOf(bad))
		uassert.Equal(t, 0, AnswerRecord("jk", bad))
		uassert.Equal(t, 0, StakedSize("jk", bad))
		uassert.Equal(t, "", StakedPage("jk", bad, 0, 0))
		uassert.False(t, IsCourtMod("jk", bad))

		// An allowance is two addresses; junk in either slot must read nothing, or a
		// stranger learns what somebody granted somebody else.
		uassert.Equal(t, int64(0), AllowanceCC("jk", bad, spender))
		uassert.Equal(t, int64(0), AllowanceCC("jk", holder, bad))

		// Weight readers: no figure, and the explanation must be the one for an
		// address that holds nothing rather than a real holder's sentence.
		v, q := ClaimVoteWeightOf("jk", bad, id)
		uassert.Equal(t, int64(0), v)
		uassert.Equal(t, int64(0), q)

		// The draw's per-address state must not report somebody else's payouts.
		w, a, an := PullState("jk", id, bad)
		uassert.False(t, w)
		uassert.False(t, a)
		uassert.False(t, an)
	}
}
