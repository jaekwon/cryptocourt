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

// THE LOCK CAN NEVER TRAP ANYONE, and that is a liveness property distinct from
// everything else here: a voter may commit their ENTIRE balance, which leaves them
// with nothing to pay a fee with, so if freeing the coin cost anything they would
// be stranded by their own vote.
//
// It does not, because every release trigger is free AND permissionless —
// ResolveDispute, ResolveElection, ResolveFlag, ResolveCounter, SettleUndisputed
// and Finalize between them charge the caller nothing (Finalize is
// participant-gated only for its grace window). So the locked party can always
// reach the release themselves. That is a claim about six functions not growing a
// fee, which is exactly the kind of claim that rots silently, so it is asserted
// here rather than trusted.
func TestAFullyCommittedVoterCanAlwaysFreeTheirOwnCoin(cur realm, t *testing.T) {
	alice := testutils.TestAddress("vl6-alice")
	bob := testutils.TestAddress("vl6-bob")
	voter := testutils.TestAddress("vl6-voter")
	c := testCourt(cur, "vlk6", alice, 40_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(voter, 10_000_000_000)
	id := stakeAnswerDispute(cur, "vlk6", alice, bob)
	cs := mustClaim(c, id)

	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "vlk6", id)

	// Commit EVERYTHING. The voter never paid a bond, so their whole balance is
	// their weight, and after voting their whole balance is committed.
	testing.SetRealm(testing.NewUserRealm(voter))
	VoteDispute(cross(cur), "vlk6", id, "no")
	locked := VoteLockedOf("vlk6", voter)
	if locked != c.coin.BalanceOf(voter) {
		t.Fatalf("fixture is vacuous: this test is about a voter with NOTHING "+
			"spare, but %d of %d is committed", locked, c.coin.BalanceOf(voter))
	}

	// Nothing at all can leave, not even one unit — so nothing could be paid.
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "not enough uncommitted CC", func() {
		TransferCC(cross(cur), "vlk6", bob, 1)
	})

	// And yet the voter frees themselves, unaided and for free, by resolving the
	// very question that locked them. Permissionless, no fee, no participant gate.
	testing.SkipHeights(c.params.votingBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(voter))
	ResolveDispute(cross(cur), "vlk6", id)
	uassert.Equal(t, int64(0), VoteLockedOf("vlk6", voter))
	testing.SetRealm(testing.NewUserRealm(voter))
	TransferCC(cross(cur), "vlk6", bob, 1)
	_ = cs
}

// The same property in the election lane, where the whole ballot is one commitment
// and ResolveElection is the release.
func TestAFullyCommittedApproverCanAlwaysFreeTheirOwnCoin(cur realm, t *testing.T) {
	creator := testutils.TestAddress("vl7-creator")
	voter := testutils.TestAddress("vl7-voter")
	other := testutils.TestAddress("vl7-other")
	mod := testutils.TestAddress("vl7-mod")
	c := electionCourt(cur, "vlk7", creator, []address{voter, other},
		[]int64{100_000_000_000, 100_000_000_000})
	// Bond money POST-seal so the snapshot stays at the full pre-seal balance and
	// the bond does not leave the voter with convenient spare change.
	c.coin.Mint(voter, 50_000_000)

	testing.SetRealm(testing.NewUserRealm(voter))
	cand := RegisterModCandidate(cross(cur), "vlk7", 1, mod)
	testing.SetRealm(testing.NewUserRealm(voter))
	OpenElection(cross(cur), "vlk7", cand)
	testing.SkipHeights(nominationWindow)
	testing.SetRealm(testing.NewUserRealm(voter))
	ApproveCandidate(cross(cur), "vlk7", cand)

	locked := VoteLockedOf("vlk7", voter)
	if locked <= 0 || locked > c.coin.BalanceOf(voter) {
		t.Fatalf("fixture is vacuous: locked=%d against a balance of %d",
			locked, c.coin.BalanceOf(voter))
	}
	// Spend the spare change down so the commitment really is everything.
	if spare := c.coin.BalanceOf(voter) - locked; spare > 0 {
		testing.SetRealm(testing.NewUserRealm(voter))
		TransferCC(cross(cur), "vlk7", other, spare)
	}
	uassert.Equal(t, locked, c.coin.BalanceOf(voter))
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "not enough uncommitted CC", func() {
		TransferCC(cross(cur), "vlk7", other, 1)
	})

	testing.SkipHeights(c.params.votingBlocks)
	testing.SetRealm(testing.NewUserRealm(voter))
	ResolveElection(cross(cur), "vlk7")
	uassert.Equal(t, int64(0), VoteLockedOf("vlk7", voter))
	testing.SetRealm(testing.NewUserRealm(voter))
	TransferCC(cross(cur), "vlk7", other, 1)
}

// PRUNING DROPS DEAD ROWS AND MOVES NOTHING ELSE.
//
// lockVote prunes, so an address that keeps voting never accumulates. One that
// votes in several simultaneously-open questions and then STOPS carries a row per
// question forever — measured at six open disputes voted, all six resolved, six
// rows still present with ZERO coin committed, and every mustSpendable on that
// address walking all six. Each is persistent state paying a storage deposit for
// nothing, and the count is bounded only by how many questions were open at once.
//
// The safety argument for leaving the entrypoint permissionless is an EQUALITY, not
// a judgement: prune removes exactly the rows voteLockedOf already skips, because
// both ask voteLockOpen. So the committed figure is identical either side of a
// prune. That is asserted here, together with the pair that matters more — a LIVE
// row must survive, or "prune" would be a way to walk out of a commitment.
func TestPruningDropsDeadRowsWithoutMovingTheCommitment(cur realm, t *testing.T) {
	alice := testutils.TestAddress("vl8-alice")
	whale := testutils.TestAddress("vl8-whale")
	voter := testutils.TestAddress("vl8-voter")
	c := testCourt(cur, "vlk8", alice, 40_000_000_000)
	c.coin.Mint(whale, 60_000_000_000)
	c.coin.Mint(voter, 10_000_000_000)

	// Three questions, all voted, all resolved: three dead rows.
	dead := make([]uint64, 0, 3)
	for i := 0; i < 3; i++ {
		id := stakeAnswerDispute(cur, "vlk8", alice, whale)
		testing.SetRealm(testing.NewUserRealm(whale))
		OpenDispute(cross(cur), "vlk8", id)
		testing.SetRealm(testing.NewUserRealm(voter))
		VoteDispute(cross(cur), "vlk8", id, "no")
		dead = append(dead, id)
	}
	testing.SkipHeights(c.params.votingBlocks + 1)
	for _, id := range dead {
		testing.SetRealm(testing.NewUserRealm(whale))
		ResolveDispute(cross(cur), "vlk8", id)
	}

	// A fourth question, voted and left OPEN, so there is a live row to protect.
	live := stakeAnswerDispute(cur, "vlk8", alice, whale)
	testing.SetRealm(testing.NewUserRealm(whale))
	OpenDispute(cross(cur), "vlk8", live)
	testing.SetRealm(testing.NewUserRealm(voter))
	VoteDispute(cross(cur), "vlk8", live, "no")

	// lockVote pruned on that fourth vote, so re-dirty the state: resolve the
	// fourth's PREDECESSORS are already gone, so instead add two more dead rows
	// after the live one exists.
	extra := make([]uint64, 0, 2)
	for i := 0; i < 2; i++ {
		id := stakeAnswerDispute(cur, "vlk8", alice, whale)
		testing.SetRealm(testing.NewUserRealm(whale))
		OpenDispute(cross(cur), "vlk8", id)
		testing.SetRealm(testing.NewUserRealm(voter))
		VoteDispute(cross(cur), "vlk8", id, "no")
		extra = append(extra, id)
	}
	testing.SkipHeights(c.params.votingBlocks + 1)
	for _, id := range extra {
		testing.SetRealm(testing.NewUserRealm(whale))
		ResolveDispute(cross(cur), "vlk8", id)
	}

	before := VoteLockedOf("vlk8", voter)
	rows := voteLockRows(c, voter)
	if rows < 2 || before <= 0 {
		t.Fatalf("fixture is vacuous: need dead rows AND a live commitment, got "+
			"rows=%d committed=%d", rows, before)
	}

	// Anyone may prune, so a bystander does it.
	testing.SetRealm(testing.NewUserRealm(alice))
	dropped := PruneVoteLocks(cross(cur), "vlk8", voter)
	if dropped <= 0 {
		t.Fatal("nothing was pruned, so this says nothing about pruning")
	}
	// THE EQUALITY: the commitment is untouched.
	uassert.Equal(t, before, VoteLockedOf("vlk8", voter))
	// And the live row survived — pruning is not an exit from a commitment.
	uassert.Equal(t, rows-dropped, voteLockRows(c, voter))
	if voteLockRows(c, voter) < 1 {
		t.Fatal("the LIVE row was pruned: prune must never be a way to walk out " +
			"of a commitment")
	}
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "not enough uncommitted CC", func() {
		TransferCC(cross(cur), "vlk8", whale, before)
	})

	// Idempotent: a second prune finds nothing, so it is not a repeatable state
	// churn a griefer could bill to the court.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.Equal(t, 0, PruneVoteLocks(cross(cur), "vlk8", voter))

	// And once the live question resolves, the last row goes too.
	testing.SkipHeights(c.params.votingBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(whale))
	ResolveDispute(cross(cur), "vlk8", live)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.True(t, PruneVoteLocks(cross(cur), "vlk8", voter) > 0)
	uassert.Equal(t, 0, voteLockRows(c, voter))
	uassert.Equal(t, int64(0), VoteLockedOf("vlk8", voter))
}

// voteLockRows counts an address's lock rows, live and dead. Test-only: the realm
// has no reason to know, and a reader would be one more surface to keep honest.
func voteLockRows(c *Court, who address) int {
	if c.voteLocks == nil {
		return 0
	}
	n := 0
	pre := string(who)
	c.voteLocks.Iterate(pre, pre+"\xff", func(_ string, _ any) bool { n++; return false })
	return n
}

// THE COMMON CASE CLEANS ITSELF, which is the whole reason PruneVoteLocks is for
// the pathological case only. An address that votes, sees the question resolve, and
// votes again carries ONE row — not one per vote it has ever cast.
//
// FOUND BY ABLATION, not by design: deleting lockVote's prune call left every other
// test in the suite green. Three tests catch a prune that removes too much and one
// catches a prune that removes nothing, but nothing at all noticed the routine
// prune simply not happening — the failure mode with no symptom except a bill.
func TestRepeatedVotingDoesNotAccumulateRows(cur realm, t *testing.T) {
	alice := testutils.TestAddress("vl9-alice")
	whale := testutils.TestAddress("vl9-whale")
	voter := testutils.TestAddress("vl9-voter")
	c := testCourt(cur, "vlk9", alice, 40_000_000_000)
	c.coin.Mint(whale, 60_000_000_000)
	c.coin.Mint(voter, 10_000_000_000)

	for round := 1; round <= 3; round++ {
		id := stakeAnswerDispute(cur, "vlk9", alice, whale)
		testing.SetRealm(testing.NewUserRealm(whale))
		OpenDispute(cross(cur), "vlk9", id)
		testing.SetRealm(testing.NewUserRealm(voter))
		VoteDispute(cross(cur), "vlk9", id, "no")

		// One row: this question. The previous rounds' rows were pruned by this
		// very vote, because their questions had resolved.
		if got := voteLockRows(c, voter); got != 1 {
			t.Fatalf("round %d: expected exactly 1 lock row after voting a single "+
				"open question, found %d — lockVote's prune is not running, so "+
				"rows accumulate one per vote for the address's whole life",
				round, got)
		}
		if VoteLockedOf("vlk9", voter) <= 0 {
			t.Fatalf("round %d: fixture is vacuous, nothing was committed", round)
		}

		testing.SkipHeights(c.params.votingBlocks + 1)
		testing.SetRealm(testing.NewUserRealm(whale))
		ResolveDispute(cross(cur), "vlk9", id)
		// Still one row, now dead — the prune happens on the NEXT vote, not on
		// resolution, because resolution is permissionless and must not be made to
		// pay for an unbounded sweep of everyone who voted.
		uassert.Equal(t, 1, voteLockRows(c, voter))
		uassert.Equal(t, int64(0), VoteLockedOf("vlk9", voter))
	}
}

// THE TWO EXPORTED FIGURES ANSWER DIFFERENT GATES, AND DisposableOf IS THE BINDING
// ONE.
//
// SpendableOf is stake-only — its name predates the vote lock — and every client had
// it while nothing exposed the figure the realm actually enforces on a bond, a
// deposit, a transfer or a wrap. This pins that they differ exactly when a holder has
// voted, that DisposableOf is what a transfer really allows to the unit, and that
// SpendableOf still answers its own question correctly for a stake.
func TestDisposableOfIsTheBindingFigureAndSpendableOfIsNot(cur realm, t *testing.T) {
	alice := testutils.TestAddress("vla-alice")
	whale := testutils.TestAddress("vla-whale")
	voter := testutils.TestAddress("vla-voter")
	c := testCourt(cur, "vlka", alice, 40_000_000_000)
	c.coin.Mint(whale, 60_000_000_000)
	c.coin.Mint(voter, 10_000_000_000)

	// Before voting the two agree, which is the bystander half: this change must not
	// move the figure for a holder who has not voted.
	uassert.Equal(t, SpendableOf("vlka", voter), DisposableOf("vlka", voter))

	id := stakeAnswerDispute(cur, "vlka", alice, whale)
	testing.SetRealm(testing.NewUserRealm(whale))
	OpenDispute(cross(cur), "vlka", id)
	testing.SetRealm(testing.NewUserRealm(voter))
	VoteDispute(cross(cur), "vlka", id, "no")

	// Top up so a disposable remainder exists and the two figures are both positive
	// but unequal — otherwise this passes against a DisposableOf that returned zero.
	testing.SetRealm(testing.NewUserRealm(whale))
	TransferCC(cross(cur), "vlka", voter, 4_000_000_000)

	sp := SpendableOf("vlka", voter)
	dp := DisposableOf("vlka", voter)
	locked := VoteLockedOf("vlka", voter)
	if locked <= 0 || dp <= 0 || dp >= sp {
		t.Fatalf("fixture is vacuous: need a live vote lock and 0 < disposable < "+
			"spendable, got locked=%d disposable=%d spendable=%d", locked, dp, sp)
	}
	// SpendableOf still answers ITS question: the balance less the stake lock, which
	// is the whole balance here because nothing is staked.
	uassert.Equal(t, c.coin.BalanceOf(voter), sp)
	// And DisposableOf is the balance less the vote commitment.
	uassert.Equal(t, c.coin.BalanceOf(voter)-locked, dp)

	// DisposableOf is what a transfer actually allows, to the unit.
	testing.SetRealm(testing.NewUserRealm(voter))
	TransferCC(cross(cur), "vlka", whale, dp)
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "not enough uncommitted CC", func() {
		TransferCC(cross(cur), "vlka", whale, 1)
	})
	// Whereas SpendableOf would have over-promised by exactly the commitment.
	uassert.Equal(t, locked, sp-dp)
}

// A QUALITY VOTE MUST NOT OUTLIVE ITS OWN INFLUENCE.
//
// A failed-quorum dispute round parks the claim: verdictAt == 0, closed == false,
// disputeOpen == false, round == 1, and failedRounds 1 of the 3 that would
// provisionally close it — a third that only arrives if somebody volunteers two more
// dispute bonds. Three routes out refuse: SettleUndisputed (round > 0), CloseDeadClaim
// (the claim has an answer), ResolveDispute (nothing open). The route that does work is
// Finalize, gated on the escrow window and then participant-only for
// finalizeGraceBlocks — so for an ordinary quality voter, who is not a participant, the
// wait was the escrow window plus a week. Probed at 155,521 blocks of escrow window
// left when the round failed: about sixteen days holding their ENTIRE balance, for a
// vote that could no longer decide anything.
//
// It could not decide anything because every path that COUNTS this tally (ResolveFlag,
// resolveQualityRide, ResolveCounter) runs behind flagOpen, disputeOpen or counterOpen,
// and each route to one of those calls openQualityTally first, which zeroes the
// weights. Finalize does not read them at all — dispute.gno never mentions qLowW.
func TestQualityLockReleasesWhenItsVoteCanNoLongerDecideAnything(cur realm, t *testing.T) {
	c, id, _, bob, carol, _ := qfSetup(cur, t, "vlq1")

	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "vlq1", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "vlq1", id, qualityLow)

	// THE BYSTANDER, and the half a release rule breaks first: while the question is
	// open the vote is about to be counted, so the coin stays put.
	held := c.coin.BalanceOf(carol)
	if VoteLockedOf("vlq1", carol) <= 0 {
		t.Fatal("a vote in an OPEN question must hold its coin — releasing here " +
			"would let a voter divest between casting and counting")
	}
	if disposable(c, carol) != 0 {
		t.Fatalf("the whole voted balance should be committed while the question "+
			"is open, disposable %d of %d", disposable(c, carol), held)
	}

	// Nobody votes the verdict. The window closes; anyone may resolve.
	testing.SkipHeights(c.params.votingBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(bob))
	ResolveDispute(cross(cur), "vlq1", id)

	cs := mustClaim(c, id)
	if cs.verdictAt != 0 || cs.closed || cs.disputeOpen {
		t.Fatal("fixture is not the parked state this test is about")
	}
	if cs.slotConsumed || cs.qualityReasked {
		t.Fatal("fixture must be the pre-adjudication case, where the next round " +
			"opens a fresh tally and discards these weights")
	}
	// The long way out, which is why releasing here is worth doing.
	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsContains(t, cur, "settles by vote", func() {
		SettleUndisputed(cross(cur), "vlq1", id)
	})
	uassert.AbortsContains(t, cur, "it settles, it does not die", func() {
		CloseDeadClaim(cross(cur), "vlq1", id)
	})
	uassert.AbortsContains(t, cur, "no dispute to resolve", func() {
		ResolveDispute(cross(cur), "vlq1", id)
	})
	uassert.AbortsContains(t, cur, "escrow window has not passed", func() {
		Finalize(cross(cur), "vlq1", id)
	})

	uassert.Equal(t, int64(0), VoteLockedOf("vlq1", carol))
	uassert.Equal(t, held, disposable(c, carol))
	// The row is collectable now too, so a parked vote stops taxing the lock walk.
	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.Equal(t, 1, PruneVoteLocks(cross(cur), "vlq1", carol))
}

// THE OTHER HALF: when the weights DO carry into later rounds the lock must hold, even
// with nothing open, because that is the case where a divested address was measured
// deciding rounds it never held through.
//
// reaskQualityTally opens a fresh tally unless slotConsumed AND qualityReasked are both
// set; once they are, every later round votes the SAME running total. This builds
// exactly that state and then parks the claim on top of it: a decided round consumes
// the slot through its ride, the reopen spends the single re-ask, and the reopened
// round fails quorum with the accumulating tally still standing.
//
// Without this test the carries-forward arm of the predicate could be deleted as
// redundant and nothing would notice.
func TestQualityLockHoldsWhenTheTallyCarriesIntoLaterRounds(cur realm, t *testing.T) {
	c, id, _, bob, carol, _ := qfSetup(cur, t, "vlq2")

	// Round 1 DECIDES (quorum met, below the overturn bar => upheld), and its ride
	// is conclusive, which is what consumes the slot.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "vlq2", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "vlq2", id, "no")
	VoteQuality(cross(cur), "vlq2", id, qualityMid)
	testing.SkipHeights(c.params.votingBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(bob))
	ResolveDispute(cross(cur), "vlq2", id)
	cs := mustClaim(c, id)
	if !cs.slotConsumed {
		t.Fatal("fixture: the ride was not conclusive, so no slot was consumed " +
			"and the next round would ask fresh")
	}
	if cs.verdictAt != 0 {
		t.Fatal("fixture: a decided round must not be terminal yet, or there is " +
			"no reopen window to use")
	}

	// The reopen spends the ONE re-ask, so the tally it opens is the last fresh one.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "vlq2", id)
	if !cs.qualityReasked {
		t.Fatal("fixture: the reopen did not spend the single re-ask")
	}
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "vlq2", id, qualityMid)
	locked := VoteLockedOf("vlq2", carol)
	if locked <= 0 {
		t.Fatal("fixture is vacuous: nothing was committed")
	}

	// Park it: this round fails quorum, nothing is open, the claim is not terminal.
	testing.SkipHeights(c.params.votingBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(bob))
	ResolveDispute(cross(cur), "vlq2", id)
	if cs.flagOpen || cs.disputeOpen || cs.counterOpen {
		t.Fatal("fixture: a question is still open, so this is the easy case")
	}
	if cs.verdictAt != 0 || cs.closed {
		t.Fatal("fixture: the claim went terminal, so the lock releases for a " +
			"different reason and this test proves nothing")
	}
	if !cs.slotConsumed || !cs.qualityReasked {
		t.Fatal("fixture: these weights would be discarded by the next round, " +
			"which is the other test")
	}

	// HELD, because this tally is what the next round votes.
	uassert.Equal(t, locked, VoteLockedOf("vlq2", carol))
	uassert.Equal(t, int64(0), disposable(c, carol))
	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.Equal(t, 0, PruneVoteLocks(cross(cur), "vlq2", carol))
}

// NO LANE MAY STRAND A VOTER'S COIN BEHIND SOMEBODY ELSE'S ACTION.
//
// The vote lock is only defensible if the voter can always get their own coin back
// without depending on a counterparty who may have no reason to act. Resolution is
// permissionless in both of these lanes today, which is what makes that true — and it
// is exactly the kind of property a later "only the disputer may resolve" tidy-up would
// remove while every existing test stayed green, because every existing test resolves
// from a participant.
//
// The third lane is the exception and it is bounded rather than absent: a quality vote
// releases the moment it can no longer decide anything (see the release test above),
// but in the frozen-accumulating case it holds until the claim is terminal, and the
// route there — Finalize — is participant-only for finalizeGraceBlocks. Measured at
// roughly sixteen days. That asymmetry is deliberate: there the vote really is still
// deciding rounds.
//
// Each test pairs the refusal with the release, because a lane that refused everything
// would pass a release-only assertion trivially.
func TestAnElectionVoterCanFreeItsOwnCoin(cur realm, t *testing.T) {
	creator := testutils.TestAddress("vlsr-creator")
	opener := testutils.TestAddress("vlsr-opener")
	voter := testutils.TestAddress("vlsr-voter")
	newMod := testutils.TestAddress("vlsr-newmod")
	c := electionCourt(cur, "vlsr", creator,
		[]address{opener, voter}, []int64{600_000_000, 400_000_000})
	c.coin.Mint(opener, 50_000_000)

	testing.SetRealm(testing.NewUserRealm(opener))
	cand := RegisterModCandidate(cross(cur), "vlsr", 1, newMod)
	testing.SetRealm(testing.NewUserRealm(opener))
	OpenElection(cross(cur), "vlsr", cand)
	testing.SkipHeights(nominationWindow)

	testing.SetRealm(testing.NewUserRealm(voter))
	ApproveCandidate(cross(cur), "vlsr", cand)
	held := c.coin.BalanceOf(voter)
	locked := VoteLockedOf("vlsr", voter)
	if locked <= 0 {
		t.Fatal("fixture is vacuous: approving committed nothing")
	}
	uassert.Equal(t, int64(0), disposable(c, voter))

	// THE BYSTANDER HALF: while the ballot is open the lock binds and resolution is
	// refused, so the release below is not the lane simply never holding anything.
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "voting window has not closed", func() {
		ResolveElection(cross(cur), "vlsr")
	})
	uassert.Equal(t, locked, VoteLockedOf("vlsr", voter))

	// And the voter resolves it THEMSELVES. No opener, no mod, no participant.
	testing.SkipHeights(c.params.votingBlocks)
	testing.SetRealm(testing.NewUserRealm(voter))
	ResolveElection(cross(cur), "vlsr")
	uassert.Equal(t, int64(0), VoteLockedOf("vlsr", voter))
	uassert.Equal(t, held, disposable(c, voter))
}

func TestADisputeVoterCanFreeItsOwnCoin(cur realm, t *testing.T) {
	c, id, _, bob, carol, _ := qfSetup(cur, t, "vlsd")

	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "vlsd", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "vlsd", id, "no")
	held := c.coin.BalanceOf(carol)
	locked := VoteLockedOf("vlsd", carol)
	if locked <= 0 {
		t.Fatal("fixture is vacuous: voting committed nothing")
	}
	// carol is neither author, answerer nor disputer — the point is that a plain
	// voter needs nobody's cooperation.
	cs := mustClaim(c, id)
	if isParticipant(cs, carol) {
		t.Fatal("fixture: carol must NOT be a participant, or this proves nothing")
	}
	uassert.Equal(t, int64(0), disposable(c, carol))

	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsContains(t, cur, "dispute vote is still open", func() {
		ResolveDispute(cross(cur), "vlsd", id)
	})
	uassert.Equal(t, locked, VoteLockedOf("vlsd", carol))

	testing.SkipHeights(c.params.votingBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(carol))
	ResolveDispute(cross(cur), "vlsd", id)
	uassert.Equal(t, int64(0), VoteLockedOf("vlsd", carol))
	uassert.Equal(t, held, disposable(c, carol))
}

// THE COUNTER LANE, AND WHY `cs.counterOpen` IS IN THE PREDICATE AT ALL.
//
// Measured rather than assumed: dropping each of the three live-question flags
// separately and running the whole suite, flagOpen and disputeOpen each fail tests and
// counterOpen fails NOTHING. It is redundant today, and by implication rather than by
// luck — CounterFlag sets counterUsed, qualityReasked and a fresh tally together, and
// rearmSlashWindow re-opens the window only `if cs.counterUsed`, so wherever counterOpen
// is true, slotConsumed && qualityReasked is true as well and the carries-forward arm
// already holds the coin.
//
// The term stays, because that implication is spread over three functions in two files
// with nothing enforcing it, and the failure direction without it is the bad one:
// ResolveCounter READS the tally, so releasing would free coin while its vote can still
// decide the slash. Over-locking is the safe error, the same default the mustStakable
// count is pinned on.
//
// What this pins is the IMPLICATION, which is what makes the redundancy safe —
// unreachable code cannot be pinned by a test, but the reason it is unreachable can. If
// a later change lets counterOpen be reached without both flags, this fails and says the
// counterOpen arm has become load-bearing.
//
// It also records the shape of the counter lane, which surprised the first draft of this
// test: the coin is STILL held after ResolveCounter. That is not a leak. slotConsumed
// and qualityReasked are both set, so reaskQualityTally will not open a fresh tally and
// a future dispute round votes this same frozen total — carol's counter vote can decide
// again, so it is still committed. The first draft asserted a release there and was
// asserting a bug.
func TestTheCounterLaneHoldsCoinAndItsRedundancyIsTheReasonWhy(cur realm, t *testing.T) {
	c, id, alice, _, carol, _, _ := slashSetup(cur, t, "vlq3")

	// alice is the slashed answerer and the only address that may counter-flag.
	testing.SetRealm(testing.NewUserRealm(alice))
	CounterFlag(cross(cur), "vlq3", id)
	cs := mustClaim(c, id)
	if !cs.counterOpen {
		t.Fatal("fixture: no counter poll is open, so this test is about nothing")
	}

	// THE IMPLICATION. Both must hold, or `|| cs.counterOpen` is the only thing
	// standing between a live counter tally and coin walking out from under it.
	if !cs.slotConsumed || !cs.qualityReasked {
		t.Fatalf("counterOpen is reachable with slotConsumed=%t qualityReasked=%t, "+
			"so the carries-forward arm no longer covers the counter lane and the "+
			"counterOpen term in voteLockOpen is now LOAD-BEARING — it was measured "+
			"redundant when it was written and its comment says so",
			cs.slotConsumed, cs.qualityReasked)
	}
	if !cs.counterUsed {
		t.Fatal("fixture: counterUsed is what rearmSlashWindow keys on; if " +
			"CounterFlag stopped setting it the re-arm path changes shape")
	}

	// Held while the counter poll can count it.
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "vlq3", id, qualityMid)
	locked := VoteLockedOf("vlq3", carol)
	if locked <= 0 {
		t.Fatal("fixture is vacuous: the counter vote committed nothing")
	}
	uassert.Equal(t, int64(0), disposable(c, carol))

	// Resolution is refused while the poll is open, and permissionless after — the
	// voter closes it themselves.
	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsContains(t, cur, "counter re-vote is still open", func() {
		ResolveCounter(cross(cur), "vlq3", id)
	})
	testing.SkipHeights(c.params.votingBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(carol))
	ResolveCounter(cross(cur), "vlq3", id)

	// STILL HELD, and this is the frozen-tally case rather than a leak: nothing is
	// open, but a future round votes this same total.
	uassert.Equal(t, locked, VoteLockedOf("vlq3", carol))
	uassert.Equal(t, int64(0), disposable(c, carol))
	if cs.counterOpen || cs.flagOpen || cs.disputeOpen {
		t.Fatal("fixture: a question is still open, so the hold above is the " +
			"live-question arm and says nothing about carry-forward")
	}

	// AND THE RELEASE EXISTS, reached by the voter alone: this claim was never
	// disputed, so round == 0 and SettleUndisputed is open to anybody once the answer
	// has aged. Terminal, and the coin comes back.
	testing.SkipHeights(settleDelay + 1)
	testing.SetRealm(testing.NewUserRealm(carol))
	SettleUndisputed(cross(cur), "vlq3", id)
	if cs.verdictAt == 0 {
		t.Fatal("fixture: the settle did not make the claim terminal")
	}
	uassert.Equal(t, int64(0), VoteLockedOf("vlq3", carol))
	uassert.Equal(t, c.coin.BalanceOf(carol), disposable(c, carol))
}

// THE ORDINARY FLAG VOTER GETS THEIR COIN BACK WHEN THE FLAG RESOLVES, which is the
// property the first version of this design CLAIMED and could not deliver.
//
// That comment said "the ordinary pre-adjudication case, the very next round — nobody is
// frozen for weeks over a flag", on the theory that the seq moves. The seq moves when a
// round OPENS and nothing makes a round open, so under the old predicate this voter was
// held until the claim went terminal. It is true now, and for a different reason: with
// slotConsumed set by the conclusive flag but qualityReasked still clear,
// reaskQualityTally would open a FRESH tally on the next dispute round and discard these
// weights, so they can no longer decide anything and the carries-forward arm lets go.
//
// This pins `cs.qualityReasked`, which the term-by-term ablation found unpinned: dropping
// it leaves slotConsumed alone, which is true here, so the coin would stay committed for
// a vote that is already spent.
func TestAnOrdinaryFlagVoteReleasesWhenTheFlagResolves(cur realm, t *testing.T) {
	c, id, _, bob, carol, _ := qfSetup(cur, t, "vlq4")

	testing.SetRealm(testing.NewUserRealm(bob))
	OpenFlag(cross(cur), "vlq4", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "vlq4", id, qualityMid)

	held := c.coin.BalanceOf(carol)
	locked := VoteLockedOf("vlq4", carol)
	if locked <= 0 {
		t.Fatal("fixture is vacuous: the flag vote committed nothing")
	}
	uassert.Equal(t, int64(0), disposable(c, carol))

	// Self-serviceable, as in every other lane: refused while open, and the voter
	// closes it themselves after.
	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsContains(t, cur, "flag vote is still open", func() {
		ResolveFlag(cross(cur), "vlq4", id)
	})
	testing.SkipHeights(c.params.votingBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(carol))
	ResolveFlag(cross(cur), "vlq4", id)

	cs := mustClaim(c, id)
	if !cs.slotConsumed {
		t.Fatal("fixture: the flag was inconclusive, so no slot was consumed and " +
			"this is not the state the test is about")
	}
	if cs.qualityReasked {
		t.Fatal("fixture: the single re-ask is already spent, so these weights " +
			"carry and holding them is correct — that is the other test")
	}
	if cs.verdictAt != 0 || cs.closed {
		t.Fatal("fixture: the claim went terminal, so the release below proves " +
			"nothing about the carries-forward arm")
	}
	// RELEASED, with nothing open and the claim still live.
	uassert.Equal(t, int64(0), VoteLockedOf("vlq4", carol))
	uassert.Equal(t, held, disposable(c, carol))
}

// A RESOLVED ELECTION'S COMMITMENT MUST NOT SURVIVE INTO THE NEXT ONE.
//
// c.mod.election is a single pointer, so the lock row from election N is matched against
// whichever election is current. `e.seq == id` is what keeps a stale row from being read
// against a live ballot, and the term-by-term ablation found it unpinned: dropping it
// leaves `!e.resolved`, which the NEXT election satisfies, so a voter who voted once
// would be re-committed by every later election they took no part in.
func TestAResolvedElectionsCommitmentDoesNotSurviveIntoTheNext(cur realm, t *testing.T) {
	creator := testutils.TestAddress("vlq5-creator")
	opener := testutils.TestAddress("vlq5-opener")
	voter := testutils.TestAddress("vlq5-voter")
	modA := testutils.TestAddress("vlq5-moda")
	modB := testutils.TestAddress("vlq5-modb")
	c := electionCourt(cur, "vlq5", creator,
		[]address{opener, voter}, []int64{600_000_000, 400_000_000})
	c.coin.Mint(opener, 200_000_000)

	// Election one: the voter approves, and it resolves.
	testing.SetRealm(testing.NewUserRealm(opener))
	candA := RegisterModCandidate(cross(cur), "vlq5", 1, modA)
	testing.SetRealm(testing.NewUserRealm(opener))
	seqA := OpenElection(cross(cur), "vlq5", candA)
	testing.SkipHeights(nominationWindow)
	testing.SetRealm(testing.NewUserRealm(voter))
	ApproveCandidate(cross(cur), "vlq5", candA)
	if VoteLockedOf("vlq5", voter) <= 0 {
		t.Fatal("fixture is vacuous: approving committed nothing")
	}
	testing.SkipHeights(c.params.votingBlocks)
	testing.SetRealm(testing.NewUserRealm(voter))
	ResolveElection(cross(cur), "vlq5")
	uassert.Equal(t, int64(0), VoteLockedOf("vlq5", voter))

	// Election two opens, with the voter taking no part in it at all.
	// Only skip if a cooldown is actually pending. Measured the hard way: this
	// election leaves electionCooldownUntil at 0, so an unguarded
	// `cooldownUntil - heightNow()` is a large NEGATIVE SkipHeights, which walks the
	// chain backwards to epoch 1 and fails in grc20votes with "that epoch has not
	// been sealed yet" — a confusing error a long way from its cause.
	if d := c.mod.electionCooldownUntil - heightNow() + 1; d > 0 {
		testing.SkipHeights(d)
		touch(c)
	}
	testing.SetRealm(testing.NewUserRealm(opener))
	candB := RegisterModCandidate(cross(cur), "vlq5", 1, modB)
	testing.SetRealm(testing.NewUserRealm(opener))
	seqB := OpenElection(cross(cur), "vlq5", candB)
	if seqB == seqA {
		t.Fatal("fixture: the second election reused the sequence number, so a " +
			"stale row would match by seq and this test proves nothing")
	}
	if c.mod.election.resolved {
		t.Fatal("fixture: the second election is already resolved, so `!e.resolved` " +
			"is false and the seq term is not what is being tested")
	}

	// The stale row from election one must not be read against the live ballot.
	uassert.Equal(t, int64(0), VoteLockedOf("vlq5", voter))
	uassert.Equal(t, c.coin.BalanceOf(voter), disposable(c, voter))
}
