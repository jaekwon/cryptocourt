package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// VOTE-THEN-SELL, which is what the floor alone did NOT stop. Probed on the floor
// before this lock existed: borrow, seal, open the dispute, vote while still
// holding, repay in the next call — 599x the quorum floor with a final balance of
// zero, against the 600x the original characterization measured. The floor moved
// the attack one step to the right. This is the step that prices it.
func TestVotedCoinCannotLeaveUntilTheRoundResolves(cur realm, t *testing.T) {
	whale := testutils.TestAddress("vl1-whale")
	author := testutils.TestAddress("vl1-author")
	renter := testutils.TestAddress("vl1-renter")
	c := testCourt(cur, "vlk1", author, 100_000_000_000)
	c.coin.Mint(whale, 400_000_000_000)

	id := stakeAnswerDispute(cur, "vlk1", author, whale)

	testing.SetRealm(testing.NewUserRealm(whale))
	TransferCC(cross(cur), "vlk1", renter, 300_000_000_000)
	testing.SkipHeights(epochBlocks * 2)
	touch(c)

	testing.SetRealm(testing.NewUserRealm(renter))
	OpenDispute(cross(cur), "vlk1", id)
	cs := mustClaim(c, id)

	// Vote WHILE HOLDING — the reorder the floor permits, and it still lands.
	testing.SetRealm(testing.NewUserRealm(renter))
	VoteDispute(cross(cur), "vlk1", id, "yes")
	_, w, ok := c.gov.VoteOf(cs.proposalID, renter)
	uassert.True(t, ok)
	if w <= 0 {
		t.Fatal("fixture is vacuous: nothing was voted, so nothing is being locked")
	}

	// The ballot's weight is now committed, exactly and no more.
	uassert.Equal(t, w, VoteLockedOf("vlk1", renter))

	// And repaying the lender is refused.
	testing.SetRealm(testing.NewUserRealm(renter))
	uassert.AbortsContains(t, cur, "not enough uncommitted CC", func() {
		TransferCC(cross(cur), "vlk1", whale, w)
	})

	// PAIRED with what must still work. The lock is amount-keyed, not
	// address-keyed: coin above the ballot's weight is untouched. The reverted
	// first attempt froze a voter's whole future inventory off one dust abstain.
	testing.SetRealm(testing.NewUserRealm(whale))
	TransferCC(cross(cur), "vlk1", renter, 5_000_000_000)
	testing.SetRealm(testing.NewUserRealm(renter))
	TransferCC(cross(cur), "vlk1", whale, 5_000_000_000)
	uassert.Equal(t, w, VoteLockedOf("vlk1", renter))

	// AND STAKING STILL WORKS, which is the other half of the rule: staking moves
	// nothing out of the balance, so a pending vote is no reason to refuse it. This
	// is the arm that catches folding the vote lock into spendable(). A SECOND
	// claim, because staking is frozen on one that already has an answer.
	testing.SetRealm(testing.NewUserRealm(author))
	other := OpenClaim(cross(cur), "vlk1", "an unanswered claim to stake on")
	testing.SetRealm(testing.NewUserRealm(renter))
	Stake(cross(cur), "vlk1", other, sideYES, 1_000_000_000)

	// RELEASED at resolution, not at the ballot close — the correction that
	// mattered, since the reverted version let a voter sell before the verdict
	// they caused was applied.
	testing.SkipHeights(c.params.votingBlocks + 1)
	if VoteLockedOf("vlk1", renter) != w {
		t.Fatal("the ballot closed but the round has not resolved — the coin must " +
			"still be committed, or a voter sells before their verdict applies")
	}
	testing.SetRealm(testing.NewUserRealm(whale))
	ResolveDispute(cross(cur), "vlk1", id)
	uassert.Equal(t, int64(0), VoteLockedOf("vlk1", renter))

	// Free to move again.
	testing.SetRealm(testing.NewUserRealm(renter))
	TransferCC(cross(cur), "vlk1", whale, 1_000_000_000)
}

// The election lane: one voter is one commitment, however many lines they approve.
func TestApprovingManyLinesLocksOneCommitment(cur realm, t *testing.T) {
	creator := testutils.TestAddress("vl2-creator")
	voter := testutils.TestAddress("vl2-voter")
	helper := testutils.TestAddress("vl2-helper")
	modA := testutils.TestAddress("vl2-moda")
	modB := testutils.TestAddress("vl2-modb")
	c := electionCourt(cur, "vlk2", creator,
		[]address{voter, helper}, []int64{200_000_000_000, 200_000_000_000})
	c.coin.Mint(voter, 50_000_000)
	c.coin.Mint(helper, 50_000_000)

	testing.SetRealm(testing.NewUserRealm(voter))
	candA := RegisterModCandidate(cross(cur), "vlk2", 1, modA)
	testing.SetRealm(testing.NewUserRealm(helper))
	candB := RegisterModCandidate(cross(cur), "vlk2", 1, modB)

	testing.SetRealm(testing.NewUserRealm(voter))
	OpenElection(cross(cur), "vlk2", candA)
	testing.SkipHeights(10)
	testing.SetRealm(testing.NewUserRealm(helper))
	NominateCandidate(cross(cur), "vlk2", candB)
	testing.SkipHeights(nominationWindow)

	testing.SetRealm(testing.NewUserRealm(voter))
	ApproveCandidate(cross(cur), "vlk2", candA)
	one := VoteLockedOf("vlk2", voter)
	if one <= 0 {
		t.Fatal("fixture is vacuous: the first approval locked nothing")
	}

	// A second line, and a third (retain) — the commitment does not grow.
	testing.SetRealm(testing.NewUserRealm(voter))
	ApproveCandidate(cross(cur), "vlk2", candB)
	uassert.Equal(t, one, VoteLockedOf("vlk2", voter))
	testing.SetRealm(testing.NewUserRealm(voter))
	ApproveRetain(cross(cur), "vlk2")
	uassert.Equal(t, one, VoteLockedOf("vlk2", voter))

	// Committed, and refused.
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "not enough uncommitted CC", func() {
		TransferCC(cross(cur), "vlk2", helper, one)
	})

	// Released when the election resolves.
	testing.SkipHeights(c.params.votingBlocks)
	testing.SetRealm(testing.NewUserRealm(helper))
	ResolveElection(cross(cur), "vlk2")
	uassert.Equal(t, int64(0), VoteLockedOf("vlk2", voter))
	testing.SetRealm(testing.NewUserRealm(voter))
	TransferCC(cross(cur), "vlk2", helper, one)
}

// A staker who votes holds ONE pile answering to TWO claims, and the rule is MAX
// not SUM. Summing them would refuse a transfer the holder can honestly make.
//
// The fixture is built so the two readings give DIFFERENT answers, which took
// arranging: the voter's live balance must exceed their snapshot (so the vote lock
// is smaller than the balance and something is free at all), and the stake lock
// must be smaller than the vote lock (so max picks the vote lock). Under SUM the
// final transfer is refused; under MAX it goes through.
//
// The court is kept small on purpose: effMinAnswerX is 10 bps of SUPPLY, and a
// larger court pushes the answerability floor above stakeAnswerDispute's X-bar so
// PostAnswer aborts before the test begins. That is how the first version failed.
func TestStakeAndVoteLocksOverlapRatherThanStack(cur realm, t *testing.T) {
	whale := testutils.TestAddress("vl3-whale")
	author := testutils.TestAddress("vl3-author")
	voter := testutils.TestAddress("vl3-voter")
	c := testCourt(cur, "vlk3", author, 40_000_000_000)
	c.coin.Mint(whale, 10_000_000_000)
	c.coin.Mint(voter, 10_000_000_000)

	id := stakeAnswerDispute(cur, "vlk3", author, whale)
	// A second, unanswered claim to stake on — staking is frozen once a claim has
	// an answer, and the answered one is the one being disputed below.
	testing.SetRealm(testing.NewUserRealm(author))
	other := OpenClaim(cross(cur), "vlk3", "an unanswered claim to stake on")
	testing.SkipHeights(epochBlocks * 2)
	touch(c)
	// AFTER the seal, so the ceiling stays at 10B while the balance rises. That gap
	// is what leaves anything free once the vote lock bites.
	c.coin.Mint(voter, 5_000_000_000)

	// Stake first, so a stake lock exists before the vote lock does.
	testing.SetRealm(testing.NewUserRealm(voter))
	Stake(cross(cur), "vlk3", other, sideYES, 2_000_000_000)
	bal := c.coin.BalanceOf(voter)
	sl := bal - SpendableOf("vlk3", voter)
	if sl != 2_000_000_000 {
		t.Fatalf("fixture is vacuous: expected a 2B stake lock, saw %d", sl)
	}

	testing.SetRealm(testing.NewUserRealm(whale))
	OpenDispute(cross(cur), "vlk3", id)
	testing.SetRealm(testing.NewUserRealm(voter))
	VoteDispute(cross(cur), "vlk3", id, "no")
	vl := VoteLockedOf("vlk3", voter)
	if vl <= sl {
		t.Fatalf("fixture is vacuous: the vote lock (%d) must EXCEED the stake "+
			"lock (%d) for max-vs-sum to be distinguishable", vl, sl)
	}

	// Under MAX the free amount is balance - vote lock. Under SUM it would be
	// balance - vote - stake, i.e. 2B less, and this transfer would be refused.
	free := bal - vl
	if free <= 0 || free <= sl {
		t.Fatalf("fixture is vacuous: free=%d must be positive and larger than "+
			"the stake lock=%d, or SUM and MAX agree", free, sl)
	}
	testing.SetRealm(testing.NewUserRealm(voter))
	TransferCC(cross(cur), "vlk3", whale, free)
	uassert.Equal(t, vl, c.coin.BalanceOf(voter))

	// And one unit more is refused: max is a real bound, not an unenforced one.
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "not enough uncommitted CC", func() {
		TransferCC(cross(cur), "vlk3", whale, 1)
	})
}
