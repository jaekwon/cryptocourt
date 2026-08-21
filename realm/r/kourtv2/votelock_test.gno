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

// THE QUALITY LANE, CASE 1 — a SUPERSEDED tally releases the coin immediately.
//
// Before anything is adjudicated, reaskQualityTally bumps the seq on every round,
// and qVoted keys on qVoteSeq|addr — so once the seq moves, the earlier vote counts
// toward nothing at all. Holding coin against a vote that decides nothing would be
// a pure tax on participation, so the lock has to let go, and this asserts it does.
func TestASupersededQualityVoteReleasesItsCoin(cur realm, t *testing.T) {
	c, id, _, bob, carol, _ := qfSetup(cur, t, "qvl1")
	cs := mustClaim(c, id)

	testing.SetRealm(testing.NewUserRealm(bob))
	OpenFlag(cross(cur), "qvl1", id)
	seq0 := cs.qVoteSeq

	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "qvl1", id, qualityLow)
	locked := VoteLockedOf("qvl1", carol)
	if locked <= 0 {
		t.Fatal("fixture is vacuous: the quality vote committed nothing")
	}
	// Committed while the tally is live.
	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsContains(t, cur, "not enough uncommitted CC", func() {
		TransferCC(cross(cur), "qvl1", bob, locked)
	})

	// A dispute arrives and re-asks: nothing is adjudicated yet, so the seq moves
	// and carol's ballot is now attached to a tally nobody counts.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "qvl1", id)
	if cs.qVoteSeq == seq0 {
		t.Fatal("fixture is vacuous: the seq did not move, so nothing was superseded")
	}
	uassert.Equal(t, int64(0), VoteLockedOf("qvl1", carol))

	// Free to move. HALF, not all: the floor would refuse a vote from an address
	// that had just divested completely, and the next assertion is about the LOCK
	// letting go, not about the floor.
	testing.SetRealm(testing.NewUserRealm(carol))
	TransferCC(cross(cur), "qvl1", bob, locked/2)

	// And free to vote the NEW tally, which is the point of the seq moving.
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "qvl1", id, qualityMid)
	// Re-committed against the live tally, at the weight she now holds.
	if got := VoteLockedOf("qvl1", carol); got <= 0 || got >= locked {
		t.Fatalf("the new ballot should commit what she still holds: got %d, "+
			"previous commitment was %d", got, locked)
	}
}

// THE QUALITY LANE, CASE 2 — a FROZEN accumulating tally holds the coin until the
// claim is over, because that is exactly how long the vote keeps deciding rounds.
//
// Reaching the frozen state takes three dispute rounds and nothing else, which is
// worth stating because the obvious route does not exist: a flag vote runs for
// votingBlocks (a week) while the dispute window is settleDelay (72h), so a flag
// can never resolve in time to be followed by a dispute. The reachable path is
// entirely inside the dispute lane, because resolveQualityRide also consumes the
// slot — and only on a DECIDED round, never on one that failed quorum.
//
//	R1 decides, its ride goes conclusive  -> slotConsumed
//	R2 opens                              -> the ONE re-ask is spent, seq moves
//	R3 opens                              -> no re-ask left, seq FROZEN
//
// A vote cast into R2's tally therefore decides R3 as well, which is the measured
// hazard: a divested address deciding a round it never held through. So the coin
// stays committed while that is true, and is released when the claim ends.
func TestAFrozenQualityTallyHoldsCoinUntilTheClaimEnds(cur realm, t *testing.T) {
	alice := testutils.TestAddress("vl5-alice")
	bob := testutils.TestAddress("vl5-bob")
	carol := testutils.TestAddress("vl5-carol")
	c := testCourt(cur, "vlk5", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "vlk5", "a frozen accumulating tally")
	matureOI(cur, "vlk5", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "vlk5", id, sideYES)
	c.params.escrowMinBlocks = 700_000 // room for three rounds inside the escrow
	c.params.escrowMaxBlocks = 700_000
	cs := mustClaim(c, id)

	// R1: decided, and its ride conclusive — carol's 20 B clears the full bar
	// alone, which is what consumes the slot.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "vlk5", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "vlk5", id, qualityMid)
	testing.SetRealm(testing.NewUserRealm(bob))
	VoteDispute(cross(cur), "vlk5", id, "no")
	testing.SkipHeights(c.params.votingBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(bob))
	ResolveDispute(cross(cur), "vlk5", id)
	if !cs.slotConsumed {
		t.Fatal("fixture is vacuous: R1's ride did not go conclusive, so the " +
			"re-ask is never spent and the seq keeps moving every round")
	}

	// R2: spends the one re-ask, so the seq moves and carol votes a fresh tally.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "vlk5", id)
	if !cs.qualityReasked {
		t.Fatal("fixture is vacuous: the one re-ask was not spent")
	}
	frozen := cs.qVoteSeq
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "vlk5", id, qualityHigh)
	locked := VoteLockedOf("vlk5", carol)
	if locked <= 0 {
		t.Fatal("fixture is vacuous: the quality vote committed nothing")
	}
	testing.SetRealm(testing.NewUserRealm(bob))
	VoteDispute(cross(cur), "vlk5", id, "no")
	testing.SkipHeights(c.params.votingBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(bob))
	ResolveDispute(cross(cur), "vlk5", id)

	// Resolving the ROUND does not release it: the tally is still live, so carol's
	// ballot is still counted. This is the case that has no "round resolved"
	// instant to release at, and the reason the predicate reads the claim instead.
	uassert.Equal(t, locked, VoteLockedOf("vlk5", carol))

	// R3: no re-ask left, so the seq does NOT move and carol's R2 ballot now
	// decides this round too. Asserted, because if the seq moved this test would be
	// case 1 wearing case 2's name.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "vlk5", id)
	if cs.qVoteSeq != frozen {
		t.Fatalf("fixture is vacuous: the seq moved from %d to %d, so the tally "+
			"is not accumulating and this says nothing about the frozen case",
			frozen, cs.qVoteSeq)
	}
	uassert.Equal(t, locked, VoteLockedOf("vlk5", carol))
	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsContains(t, cur, "not enough uncommitted CC", func() {
		TransferCC(cross(cur), "vlk5", bob, locked)
	})

	// The claim ends, and the vote stops deciding anything.
	testing.SetRealm(testing.NewUserRealm(bob))
	VoteDispute(cross(cur), "vlk5", id, "no")
	testing.SkipHeights(c.params.votingBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(bob))
	ResolveDispute(cross(cur), "vlk5", id)
	if d := EscrowUntil("vlk5", id) - heightNow() + 1; d > 0 {
		testing.SkipHeights(d)
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "vlk5", id)
	if cs.verdictAt == 0 && !cs.closed {
		t.Fatal("fixture is vacuous: the claim is not terminal, so the release " +
			"below is not caused by what this test says causes it")
	}
	uassert.Equal(t, int64(0), VoteLockedOf("vlk5", carol))
	testing.SetRealm(testing.NewUserRealm(carol))
	TransferCC(cross(cur), "vlk5", bob, locked)
}

// ONE PILE, TWO QUESTIONS, ONE COMMITMENT — the max across open questions, not the
// sum. Each lock row is a floor ("at least this much must stay put") and one pile
// of size max(rows) honours them all, because the same coins can satisfy more than
// one commitment at a time.
//
// This was a SHIPPED BUG, found by probing rather than by reading. P11 makes the
// quality ride its own transaction, so voting a verdict and then its quality
// question is what an engaged holder ordinarily does — and that holder ended up
// with 40 B committed against a 20 B balance, unable to move anything, having
// committed one pile once. Measured before the fix, pinned here after it.
func TestTwoQuestionsCommitOnePileOnce(cur realm, t *testing.T) {
	alice := testutils.TestAddress("vl4-alice")
	bob := testutils.TestAddress("vl4-bob")
	carol := testutils.TestAddress("vl4-carol")
	c := testCourt(cur, "vlk4", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "vlk4", "one pile, two questions")
	matureOI(cur, "vlk4", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "vlk4", id, sideYES)

	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "vlk4", id)
	bal := c.coin.BalanceOf(carol)

	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "vlk4", id, "no")
	one := VoteLockedOf("vlk4", carol)
	if one <= 0 {
		t.Fatal("fixture is vacuous: the verdict vote committed nothing")
	}

	// The ride, in its own transaction, exactly as P11 intends.
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "vlk4", id, qualityMid)
	two := VoteLockedOf("vlk4", carol)

	// The instrument's own precondition: two rows really are open. Without this the
	// assertion below would pass just as happily against a lane that recorded
	// nothing for the second question.
	if !c.voteLocks.Has(voteLockKey(carol, voteLockDispute,
		id, uint64(mustClaim(c, id).proposalID))) {
		t.Fatal("fixture is vacuous: no dispute lock row was written")
	}
	if !c.voteLocks.Has(voteLockKey(carol, voteLockQuality,
		id, uint64(mustClaim(c, id).qVoteSeq))) {
		t.Fatal("fixture is vacuous: no quality lock row was written")
	}

	// Two questions, one commitment. Not two.
	uassert.Equal(t, one, two)
	if two > bal {
		t.Fatalf("the commitment (%d) exceeds the whole balance (%d): the same "+
			"coins are being counted twice", two, bal)
	}

	// PAIRED: the commitment is real, and it is exactly the pile. One unit over is
	// refused, so max is a bound rather than an unenforced number.
	testing.SetRealm(testing.NewUserRealm(bob))
	TransferCC(cross(cur), "vlk4", carol, 1_000_000_000)
	testing.SetRealm(testing.NewUserRealm(carol))
	TransferCC(cross(cur), "vlk4", bob, 1_000_000_000)
	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsContains(t, cur, "not enough uncommitted CC", func() {
		TransferCC(cross(cur), "vlk4", bob, 1)
	})
}
