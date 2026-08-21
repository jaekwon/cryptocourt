package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// RENTED VOTING WEIGHT — closed at v0.57 by live weight plus a transfer lock.
//
// This file was a CHARACTERIZATION suite one commit ago: it asserted the exploit
// SUCCEEDED, with the instruction that any fix must flip it. The fix landed and it
// flipped. What follows is the regression suite it was designed to become.
//
// THE HOLE THAT WAS. Weight was read from a sealed past epoch, and the anchor was
// `Epoch()-1` AT PROPOSE TIME — so whoever opened the dispute or election chose it.
// Buy float, wait ONE epoch (~1h) for the checkpoint to seal, open the round
// yourself, sell everything back, and vote with weight you no longer owned; a past
// checkpoint cannot be un-written by a later transfer. Measured before the fix:
// 300 B of weight cast at 600x the quorum floor with a live balance of ZERO.
//
// THE FIX, both halves load-bearing:
//
//   - Weight is what the voter holds AT THE MOMENT THEY VOTE. No anchor to choose,
//     and newly bought coin votes at once — the owner's rule.
//   - Voting locks that coin AGAINST TRANSFER ONLY until the round closes. Staking,
//     bonding and deposits are untouched, so voting costs no YIELD, only liquidity.
//     Renting requires selling back, and selling is the one thing forbidden.
//
// WHAT IT COST, and it is not small: an OPEN vote can now be BOUGHT into. See
// TestVotingWindowAndWeightGates, where a latecomer minted more CC than the honest
// holder now votes and decides. No denominator prevents that — you gain 100% of
// what you acquire while a 5%-of-votable bar gains 5% of it. VOTELOCK.md carries
// the measurement and the owner's decision.

// Sell first, then try to vote: nothing is left to vote with. This is the literal
// sequence that was measured working before the fix.
func TestRentedWeightCannotVoteADispute(cur realm, t *testing.T) {
	whale := testutils.TestAddress("rw-whale")
	author := testutils.TestAddress("rw-author")
	renter := testutils.TestAddress("rw-renter")
	c := testCourt(cur, "rntw1", author, 40_000_000_000)
	c.coin.Mint(whale, 10_000_000_000)

	id := stakeAnswerDispute(cur, "rntw1", author, whale)

	// Acquire, then wait the one epoch that used to be the whole cost.
	testing.SetRealm(testing.NewUserRealm(whale))
	TransferCC(cross(cur), "rntw1", renter, 9_000_000_000)
	testing.SkipHeights(epochBlocks * 2)
	touch(c)
	// The old anchor still shows the rented weight. That is the point: a
	// checkpoint is untouchable, which is why the fix could not live there.
	uassert.Equal(t, int64(9_000_000_000), c.coin.PastVotes(renter, c.coin.Epoch()-1))

	// Open the round to pin the old anchor, then sell it all back.
	testing.SetRealm(testing.NewUserRealm(renter))
	OpenDispute(cross(cur), "rntw1", id)
	testing.SetRealm(testing.NewUserRealm(renter))
	TransferCC(cross(cur), "rntw1", whale, SpendableOf("rntw1", renter))

	testing.SetRealm(testing.NewUserRealm(renter))
	uassert.AbortsContains(t, cur, "no court coin to vote with", func() {
		VoteDispute(cross(cur), "rntw1", id, "yes")
	})
}

// THE OTHER ORDERING, and the one the lock exists for: vote FIRST, then try to
// sell. The ballot stands — a cast vote is never undone — so the coin must not be
// allowed to leave, or the weight was rented after all.
func TestCoinVotedWithCannotBeSoldUntilTheRoundCloses(cur realm, t *testing.T) {
	whale := testutils.TestAddress("rw-whale2")
	author := testutils.TestAddress("rw-author2")
	renter := testutils.TestAddress("rw-renter2")
	c := testCourt(cur, "rntw2", author, 40_000_000_000)
	c.coin.Mint(whale, 10_000_000_000)

	id := stakeAnswerDispute(cur, "rntw2", author, whale)
	testing.SetRealm(testing.NewUserRealm(whale))
	TransferCC(cross(cur), "rntw2", renter, 9_000_000_000)

	testing.SetRealm(testing.NewUserRealm(renter))
	OpenDispute(cross(cur), "rntw2", id)
	testing.SetRealm(testing.NewUserRealm(renter))
	VoteDispute(cross(cur), "rntw2", id, "yes")

	// Locked, and the height is published so a UI can state it BEFORE the vote.
	until := VoteLockedUntil("rntw2", renter)
	uassert.True(t, until > heightNow())

	testing.SetRealm(testing.NewUserRealm(renter))
	uassert.AbortsContains(t, cur, "cannot be transferred until block", func() {
		TransferCC(cross(cur), "rntw2", whale, 1_000_000)
	})
	// The allowance door is shut too, keyed on the OWNER rather than the spender —
	// otherwise an approval would launder the sale.
	testing.SetRealm(testing.NewUserRealm(renter))
	ApproveCC(cross(cur), "rntw2", whale, 1_000_000)
	testing.SetRealm(testing.NewUserRealm(whale))
	uassert.AbortsContains(t, cur, "cannot be transferred until block", func() {
		TransferFromCC(cross(cur), "rntw2", renter, whale, 1_000_000)
	})

	// And it lifts by itself — no sweep, no claim, nothing to strand.
	testing.SkipHeights(until - heightNow())
	uassert.Equal(t, int64(0), VoteLockedUntil("rntw2", renter))
	testing.SetRealm(testing.NewUserRealm(renter))
	TransferCC(cross(cur), "rntw2", whale, 1_000_000)
}

// THE OWNER'S FIRST CONSTRAINT: voting must cost no YIELD. The lock is
// transfer-only, so every earning use of the coin survives it. If this fails, the
// mechanism has become a tax on participating.
func TestVotingCostsNoYieldOnlyLiquidity(cur realm, t *testing.T) {
	whale := testutils.TestAddress("rw-whale3")
	author := testutils.TestAddress("rw-author3")
	voter := testutils.TestAddress("rw-voter3")
	c := testCourt(cur, "rntw3", author, 40_000_000_000)
	c.coin.Mint(whale, 10_000_000_000)
	c.coin.Mint(voter, 10_000_000_000)

	id := stakeAnswerDispute(cur, "rntw3", author, whale)
	testing.SetRealm(testing.NewUserRealm(voter))
	OpenDispute(cross(cur), "rntw3", id)
	testing.SetRealm(testing.NewUserRealm(voter))
	VoteDispute(cross(cur), "rntw3", id, "yes")
	uassert.True(t, VoteLockedUntil("rntw3", voter) > heightNow())

	// FILING still works, which means the DEPOSIT still moved.
	testing.SetRealm(testing.NewUserRealm(voter))
	other := OpenClaim(cross(cur), "rntw3", "Can a vote-locked holder still stake?")

	// STAKING still works — so the conviction this coin would have earned is not
	// forgone, which is the whole argument that voting is not economically
	// disadvantageous.
	testing.SetRealm(testing.NewUserRealm(voter))
	Stake(cross(cur), "rntw3", other, sideYES, 1_000_000_000)
	uassert.Equal(t, int64(1_000_000_000), StakeOf("rntw3", other, sideYES, voter))

	// Only the sale is refused.
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "cannot be transferred until block", func() {
		TransferCC(cross(cur), "rntw3", whale, 1_000)
	})
}

// THE OWNER'S THIRD CONSTRAINT: coin bought a moment ago votes at full size, with
// no seasoning at all — same block, no epoch sealed.
func TestNewlyAcquiredCoinVotesImmediately(cur realm, t *testing.T) {
	whale := testutils.TestAddress("rw-whale4")
	author := testutils.TestAddress("rw-author4")
	buyer := testutils.TestAddress("rw-buyer4")
	c := testCourt(cur, "rntw4", author, 40_000_000_000)
	c.coin.Mint(whale, 10_000_000_000)

	id := stakeAnswerDispute(cur, "rntw4", author, whale)
	// The whale opens it: author is also the ANSWERER here, and an answerer may
	// not dispute their own answer.
	testing.SetRealm(testing.NewUserRealm(whale))
	OpenDispute(cross(cur), "rntw4", id)

	uassert.Equal(t, int64(0), c.coin.BalanceOf(buyer))
	testing.SetRealm(testing.NewUserRealm(whale))
	TransferCC(cross(cur), "rntw4", buyer, 6_000_000_000)
	testing.SetRealm(testing.NewUserRealm(buyer))
	VoteDispute(cross(cur), "rntw4", id, "yes")

	_, w, ok := c.gov.VoteOf(mustClaim(c, id).proposalID, buyer)
	uassert.True(t, ok)
	uassert.Equal(t, int64(6_000_000_000), w) // full size, no haircut
}

// Voting on a second round EXTENDS the lock and never shortens it. Without the
// monotone rule, voting again on a shorter round would release the first round's
// coin early and hand the rental straight back.
func TestASecondVoteNeverShortensTheLock(cur realm, t *testing.T) {
	whale := testutils.TestAddress("rw-whale5")
	author := testutils.TestAddress("rw-author5")
	voter := testutils.TestAddress("rw-voter5")
	c := testCourt(cur, "rntw5", author, 40_000_000_000)
	c.coin.Mint(whale, 10_000_000_000)
	c.coin.Mint(voter, 10_000_000_000)

	id := stakeAnswerDispute(cur, "rntw5", author, whale)
	testing.SetRealm(testing.NewUserRealm(voter))
	OpenDispute(cross(cur), "rntw5", id)
	testing.SetRealm(testing.NewUserRealm(voter))
	VoteDispute(cross(cur), "rntw5", id, "yes")
	first := VoteLockedUntil("rntw5", voter)
	uassert.True(t, first > heightNow())

	// A lock that would end EARLIER must not pull the first one in.
	testing.SkipHeights(10)
	lockVote(c, voter, heightNow()+5)
	uassert.Equal(t, first, VoteLockedUntil("rntw5", voter))

	// One ending LATER does extend it — but only as far as one round from now,
	// because the cap binds before the extension does. Asserting the capped value
	// rather than the requested one pins both behaviours at once: a later round
	// extends, and no round can push the lock past a single round from today.
	lockVote(c, voter, first+100_000)
	uassert.Equal(t, heightNow()+c.params.votingBlocks, VoteLockedUntil("rntw5", voter))
	uassert.True(t, VoteLockedUntil("rntw5", voter) > first)
}

// The lock is capped at one round however long a lane's window claims to be, so
// the commitment is statable before the vote rather than discovered after.
func TestTheLockIsCappedAtOneRound(cur realm, t *testing.T) {
	author := testutils.TestAddress("rw-author6")
	c := testCourt(cur, "rntw6", author, 10_000_000_000)

	lockVote(c, author, heightNow()+c.params.votingBlocks*100)
	uassert.Equal(t, heightNow()+c.params.votingBlocks, VoteLockedUntil("rntw6", author))

	// A round that already closed locks nothing at all.
	other := testutils.TestAddress("rw-other6")
	lockVote(c, other, heightNow()-1)
	uassert.Equal(t, int64(0), VoteLockedUntil("rntw6", other))
}
