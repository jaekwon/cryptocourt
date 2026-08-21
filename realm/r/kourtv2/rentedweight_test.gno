package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// RENTED VOTING WEIGHT — CLOSED. These tests used to assert that the exploit
// WORKED, deliberately, so that any fix would make them fail loudly rather than
// quietly go green. That is what happened, and this file is the flip.
//
// THE HOLE THAT WAS. Every vote was weighed at a sealed past epoch, which stops
// weight acquired AFTER the question was asked and does nothing about weight
// acquired shortly before — and for two of the three lanes the party who
// INITIATES the action is the one who pins the anchor. So: acquire float on the
// market, wait ONE epoch for the checkpoint to seal, open the dispute or election
// yourself, sell everything back, and vote the full weight you no longer own. A
// past checkpoint cannot be un-written by a later transfer. Measured at 600x the
// quorum floor on the verdict lane and 12x on the election lane.
//
// WHAT CLOSED IT. Weight became
//
//	w = min( PastVotes(who, <the question's own frozen epoch>), BalanceOf(who) )
//
// The snapshot is the CEILING and stops buying in after the question. The live
// balance is the FLOOR and stops voting weight already given back. Neither half
// works alone: two earlier attempts each kept one and failed, one to rental and
// one to a live numerator against a frozen bar. The renter must return the coin
// to repay the loan, and at that moment there is nothing left to vote.
//
// WHAT IS STILL TRUE AND DELIBERATE. Selling out AFTER voting does not undo the
// vote. That is standard snapshot-governance behaviour, pinned by r/govern's own
// TestAVoteCannotBePassedAlongWithTheTokens, and it is not what this file was
// ever about — the defect was that the actor chose the anchor, which turned an
// accepted property into a rental market.

// THE VECTOR, end to end, on the verdict lane. Asserts it now FAILS.
func TestRentedWeightCannotVoteADispute(cur realm, t *testing.T) {
	whale := testutils.TestAddress("rw-whale")
	author := testutils.TestAddress("rw-author")
	renter := testutils.TestAddress("rw-renter")
	// The whale ANSWERS, which makes them a participant and bars them from the
	// verdict entirely. The pair below therefore needs a third holder who is not
	// party to the claim — found the hard way, by the pair aborting on Q2.
	keeper := testutils.TestAddress("rw-keeper")
	c := testCourt(cur, "rntw1", author, 100_000_000_000)
	c.coin.Mint(whale, 400_000_000_000)

	id := stakeAnswerDispute(cur, "rntw1", author, whale)
	uassert.Equal(t, int64(0), c.coin.BalanceOf(renter))

	// Acquire, then wait exactly ONE epoch to seal. One epoch is all it took.
	testing.SetRealm(testing.NewUserRealm(whale))
	TransferCC(cross(cur), "rntw1", renter, 300_000_000_000)
	testing.SetRealm(testing.NewUserRealm(whale))
	TransferCC(cross(cur), "rntw1", keeper, 20_000_000_000)
	testing.SkipHeights(epochBlocks * 2)
	touch(c)
	pinned := c.coin.PastVotes(renter, c.coin.Epoch()-1)
	uassert.Equal(t, int64(300_000_000_000), pinned)

	// Pin the anchor by opening the dispute yourself. This step still works — it
	// is the anchor choice, and taking it away was a different design that was
	// rejected for disenfranchising everyone who joined after the answer.
	testing.SetRealm(testing.NewUserRealm(renter))
	OpenDispute(cross(cur), "rntw1", id)
	cs := mustClaim(c, id)

	// Sell it all back. The pinned checkpoint is STILL untouched — the fix does
	// not pretend otherwise, it just stops the checkpoint being the whole story.
	testing.SetRealm(testing.NewUserRealm(renter))
	TransferCC(cross(cur), "rntw1", whale, SpendableOf("rntw1", renter))
	uassert.Equal(t, int64(0), c.coin.VotesOf(renter))
	uassert.Equal(t, pinned, c.coin.PastVotes(renter, c.coin.Epoch()-1))

	// And the vote is refused. The scale of what is being refused: the pinned
	// figure stood at 600x the bar it would have had to clear.
	floor := quorumFloor(c, cs.xBarFrozen)
	if floor <= 0 || pinned/floor < 100 {
		t.Fatalf("fixture is vacuous: a rental worth %d against a floor of %d is "+
			"not the attack this test exists to refuse", pinned, floor)
	}
	testing.SetRealm(testing.NewUserRealm(renter))
	uassert.AbortsContains(t, cur, "no longer hold", func() {
		VoteDispute(cross(cur), "rntw1", id, "yes")
	})
	_, _, ok := c.gov.VoteOf(cs.proposalID, renter)
	uassert.False(t, ok) // nothing was recorded

	// THE PAIR, and the reason this is a floor rather than a wall: the keeper held
	// throughout and votes at their full pinned weight, undocked.
	keeperPinned := c.coin.PastVotes(keeper, c.gov.EpochOf(cs.proposalID))
	if keeperPinned <= 0 {
		t.Fatal("fixture is vacuous: the keeper has no pinned weight, so the " +
			"refusal above is not being contrasted with anything")
	}
	testing.SetRealm(testing.NewUserRealm(keeper))
	VoteDispute(cross(cur), "rntw1", id, "no")
	_, w, ok := c.gov.VoteOf(cs.proposalID, keeper)
	uassert.True(t, ok)
	uassert.Equal(t, keeperPinned, w)
}

// A PARTIAL repayment is refused only in proportion. The floor is not a
// participation test — it prices the position down to what is actually held — and
// this is the case that separates the two readings.
func TestPartlyRepaidWeightVotesOnlyWhatIsLeft(cur realm, t *testing.T) {
	whale := testutils.TestAddress("rw-whale2")
	author := testutils.TestAddress("rw-author2")
	renter := testutils.TestAddress("rw-renter2")
	c := testCourt(cur, "rntw2", author, 100_000_000_000)
	c.coin.Mint(whale, 400_000_000_000)

	id := stakeAnswerDispute(cur, "rntw2", author, whale)
	testing.SetRealm(testing.NewUserRealm(whale))
	TransferCC(cross(cur), "rntw2", renter, 300_000_000_000)
	testing.SkipHeights(epochBlocks * 2)
	touch(c)

	testing.SetRealm(testing.NewUserRealm(renter))
	OpenDispute(cross(cur), "rntw2", id)
	cs := mustClaim(c, id)
	pinned := c.coin.PastVotes(renter, c.gov.EpochOf(cs.proposalID))
	if pinned <= 0 {
		t.Fatal("fixture is vacuous: the renter has no pinned weight")
	}

	// Repay most of it, keep a real remainder.
	testing.SetRealm(testing.NewUserRealm(renter))
	TransferCC(cross(cur), "rntw2", whale, 250_000_000_000)
	kept := c.coin.BalanceOf(renter)
	if kept <= 0 || kept >= pinned {
		t.Fatalf("fixture is vacuous: need 0 < kept < pinned, got %d and %d",
			kept, pinned)
	}

	testing.SetRealm(testing.NewUserRealm(renter))
	VoteDispute(cross(cur), "rntw2", id, "yes")
	_, w, ok := c.gov.VoteOf(cs.proposalID, renter)
	uassert.True(t, ok)
	// Exactly what is still held — not the pinned figure, and not zero.
	uassert.Equal(t, kept, w)
}

// The election lane, which was the worse one: OpenElection pins the anchor and a
// coup is court-wide rather than one claim.
func TestRentedWeightCannotClearTheElectionFloor(cur realm, t *testing.T) {
	whale := testutils.TestAddress("rw-whale5")
	renter := testutils.TestAddress("rw-renter5")
	newMod := testutils.TestAddress("rw-newmod5")
	c := testCourt(cur, "rntw5", whale, 500_000_000_000)

	testing.SetRealm(testing.NewUserRealm(whale))
	TransferCC(cross(cur), "rntw5", renter, 300_000_000_000)
	testing.SkipHeights(epochBlocks * 2)
	touch(c)

	testing.SetRealm(testing.NewUserRealm(whale))
	cand := RegisterModCandidate(cross(cur), "rntw5", 1, newMod)
	testing.SetRealm(testing.NewUserRealm(renter))
	OpenElection(cross(cur), "rntw5", cand)
	e := ensureMod(c).election
	pinned := c.coin.PastVotes(renter, e.epoch)

	// The coup WAS in range: a one-epoch rental stood above the floor, measured
	// at 12x. Asserted, so this test cannot pass by the rental being too small.
	floor := electionFloor(c, e.epoch)
	if floor <= 0 || pinned/floor < 10 {
		t.Fatalf("fixture is vacuous: a rental of %d against a floor of %d is not "+
			"the coup this test exists to refuse", pinned, floor)
	}
	testing.SkipHeights(nominationWindow)

	// Repay, and the pinned figure is still there, and it still buys nothing.
	testing.SetRealm(testing.NewUserRealm(renter))
	TransferCC(cross(cur), "rntw5", whale, SpendableOf("rntw5", renter))
	uassert.Equal(t, pinned, c.coin.PastVotes(renter, e.epoch))
	uassert.Equal(t, int64(0), c.coin.VotesOf(renter))

	testing.SetRealm(testing.NewUserRealm(renter))
	uassert.AbortsContains(t, cur, "no longer hold", func() {
		ApproveCandidate(cross(cur), "rntw5", cand)
	})
	_, _, turnout := ElectionTally("rntw5", cand)
	uassert.Equal(t, int64(0), turnout)
}

// The half that ALWAYS worked, and the reason snapshot weighting stays: weight
// acquired after the anchor buys nothing. The floor did not trade this away — that
// is the whole point of keeping the snapshot as a ceiling, and a live-only reading
// would have let weight borrowed inside the voting window decide the vote.
func TestBuyingInAfterTheAnchorBuysNothing(cur realm, t *testing.T) {
	whale := testutils.TestAddress("rw-whale4")
	author := testutils.TestAddress("rw-author4")
	voter := testutils.TestAddress("rw-voter4")
	c := testCourt(cur, "rntw4", author, 100_000_000_000)
	c.coin.Mint(whale, 400_000_000_000)

	id := stakeAnswerDispute(cur, "rntw4", author, whale)

	testing.SetRealm(testing.NewUserRealm(whale))
	TransferCC(cross(cur), "rntw4", voter, 10_000_000_000)
	testing.SkipHeights(epochBlocks * 2)
	touch(c)

	testing.SetRealm(testing.NewUserRealm(voter))
	OpenDispute(cross(cur), "rntw4", id)

	// Buy a great deal more AFTER the anchor is pinned.
	testing.SetRealm(testing.NewUserRealm(whale))
	TransferCC(cross(cur), "rntw4", voter, 300_000_000_000)
	uassert.True(t, c.coin.VotesOf(voter) > 300_000_000_000)

	testing.SetRealm(testing.NewUserRealm(voter))
	VoteDispute(cross(cur), "rntw4", id, "yes")
	_, w, ok := c.gov.VoteOf(mustClaim(c, id).proposalID, voter)
	uassert.True(t, ok)
	// Capped at the snapshot, unmoved by the later purchase.
	uassert.True(t, w <= 10_000_000_000)
}

// THE CARROT SURVIVES THE GOVERNOR'S ROLL BEING RECLAIMED.
//
// dispute.gno has said since the choice record was added that the carrot must not
// depend on the governor's roll, because ReleaseRoll is permissionless and sets
// p.voted = nil. A first version of PullCarrot's rewrite ignored that and read the
// weight back with gov.VoteOf, which stops answering once the roll is gone — so a
// claimant who had not pulled yet would have been refused a carrot they earned.
//
// It was LATENT rather than live: kourtv2 exposes no ReleaseRoll entrypoint, so
// nothing reclaims its rolls today. Which is exactly why no test caught it, and
// why this one reaches past the entrypoints to call the governor directly.
func TestTheCarrotSurvivesRollReclamation(cur realm, t *testing.T) {
	author := testutils.TestAddress("rw-author6")
	whale := testutils.TestAddress("rw-whale6")
	voter := testutils.TestAddress("rw-voter6")
	// Kept small on purpose: effMinAnswerX is 10 bps of SUPPLY, so a big court
	// makes stakeAnswerDispute's ~900M X-bar unanswerable outright.
	c := testCourt(cur, "rntw6", author, 40_000_000_000)
	c.coin.Mint(whale, 10_000_000_000)
	c.coin.Mint(voter, 10_000_000_000)

	id := stakeAnswerDispute(cur, "rntw6", author, whale)
	cs := mustClaim(c, id)
	testing.SetRealm(testing.NewUserRealm(whale))
	OpenDispute(cross(cur), "rntw6", id)
	pid := cs.proposalID

	// A non-participant votes with the verdict, which is who the carrot pays.
	testing.SetRealm(testing.NewUserRealm(voter))
	VoteDispute(cross(cur), "rntw6", id, "no") // uphold
	recorded := cs.qVoted.Get("dw" + beClaimKey(uint64(pid)) + string(voter))
	if recorded == nil {
		t.Fatal("fixture is vacuous: no court-side weight was recorded, so " +
			"nothing is being shown to survive")
	}

	testing.SkipHeights(c.params.votingBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(whale))
	ResolveDispute(cross(cur), "rntw6", id)
	if d := EscrowUntil("rntw6", id) - heightNow() + 1; d > 0 {
		testing.SkipHeights(d)
	}
	testing.SetRealm(testing.NewUserRealm(author))
	Finalize(cross(cur), "rntw6", id)

	// RECLAIM THE ROLL. Reached directly, because no entrypoint offers it — and
	// asserted, so this cannot pass against a governor that quietly refused.
	c.gov.ReleaseRoll(whale, pid)
	_, _, ok := c.gov.VoteOf(pid, voter)
	uassert.False(t, ok) // the governor has genuinely forgotten the ballot

	// The court has not. The carrot still pays.
	drainForCarrot(cur, "rntw6", cs)
	testing.SetRealm(testing.NewUserRealm(author))
	Crystallize(cross(cur), "rntw6", id)
	testing.SetRealm(testing.NewUserRealm(voter))
	paid := PullCarrot(cross(cur), "rntw6", id)
	uassert.True(t, paid > 0)
}

// drainForCarrot advances until the reservoir covers the claim's draw, so the
// carrot is not zero for want of emission rather than for want of a record.
func drainForCarrot(cur realm, slug string, cs *claimState) {
	want := mustMul(tierMidX, convToCC(cs.yesConvHi, cs.yesConvLo)) * 3
	for i := 0; i < 400; i++ {
		if Reservoir(slug) >= want {
			return
		}
		testing.SkipHeights(20_000)
		testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("rw-poker")))
		Poke(cross(cur), slug)
	}
	panic("fixture is vacuous: the reservoir never covered the draw")
}

// THE QUALITY LANE, which this file never covered and which votelock.gno calls "the
// hardest lane to rent into regardless, because the anchor is the ANSWERER's".
//
// That claim was true and unenforced. The other two lanes let the actor pin their own
// anchor — OpenDispute and OpenElection both do — so the rental there is a solo move.
// Quality is anchored at cs.qualityEpoch, set inside PostAnswer, and the answerer is
// barred from voting their own claim's quality by Q2. So renting this lane takes TWO
// parties: an answerer who pins the epoch and a second address that votes it. That is a
// higher bar, and it is not a wall, so the floor and the lock still have to hold.
//
// Both orderings, because the first fix stopped one and left the other at 599x:
// sell-then-vote is refused by the FLOOR, and vote-then-sell by the LOCK.
func TestRentedWeightCannotVoteQualityEitherWayRound(cur realm, t *testing.T) {
	author := testutils.TestAddress("rwq-author")
	whale := testutils.TestAddress("rwq-whale")
	renter := testutils.TestAddress("rwq-renter")
	keeper := testutils.TestAddress("rwq-keeper")
	flagger := testutils.TestAddress("rwq-flagger")
	c := testCourt(cur, "rwq", author, 60_000_000_000)
	c.coin.Mint(whale, 300_000_000_000)
	c.coin.Mint(flagger, 5_000_000_000)

	testing.SetRealm(testing.NewUserRealm(author))
	id := OpenClaim(cross(cur), "rwq", "A claim whose quality can be rented?")
	matureOI(cur, "rwq", id, author, 2_000_000_000)

	// The rental is taken BEFORE the answer, because the answer is what pins the
	// epoch this lane weighs at. Two parties by construction: the author answers.
	testing.SetRealm(testing.NewUserRealm(whale))
	TransferCC(cross(cur), "rwq", renter, 200_000_000_000)
	testing.SetRealm(testing.NewUserRealm(whale))
	TransferCC(cross(cur), "rwq", keeper, 20_000_000_000)
	testing.SkipHeights(epochBlocks * 2)
	touch(c)

	testing.SetRealm(testing.NewUserRealm(author))
	PostAnswer(cross(cur), "rwq", id, sideYES)
	cs := mustClaim(c, id)
	pinned := c.coin.PastVotes(renter, cs.qualityEpoch)
	if pinned <= 0 {
		t.Fatal("fixture: the rental is not checkpointed at the quality epoch, so " +
			"there is nothing for the floor to refuse")
	}

	// A quality question, opened by a fourth party so the renter stays a
	// non-participant and Q2 does not do the refusing for us.
	testing.SetRealm(testing.NewUserRealm(flagger))
	OpenFlag(cross(cur), "rwq", id)
	if !qualityQuestionOpen(cs) {
		t.Fatal("fixture: no quality question is open")
	}
	_, fullBar := qualityBars(c, cs)
	if fullBar <= 0 || pinned/fullBar < 10 {
		t.Fatalf("fixture is vacuous: a rental worth %d against a full bar of %d "+
			"is not the attack this test exists to refuse", pinned, fullBar)
	}
	t.Logf("the rental stands at %dx the quality full bar (%d against %d)",
		pinned/fullBar, pinned, fullBar)

	// ORDERING ONE — SELL THEN VOTE. Repay first, then try to vote the checkpoint.
	// The checkpoint is untouched and the floor is what refuses.
	testing.SetRealm(testing.NewUserRealm(renter))
	TransferCC(cross(cur), "rwq", whale, DisposableOf("rwq", renter))
	uassert.Equal(t, pinned, c.coin.PastVotes(renter, cs.qualityEpoch))
	testing.SetRealm(testing.NewUserRealm(renter))
	uassert.AbortsContains(t, cur, "no longer hold", func() {
		VoteQuality(cross(cur), "rwq", id, qualityHigh)
	})

	// THE PAIR: the keeper held throughout and votes its full pinned weight. Without
	// this the floor could be a wall refusing everybody and the test would not know.
	keeperPinned := c.coin.PastVotes(keeper, cs.qualityEpoch)
	if keeperPinned <= 0 {
		t.Fatal("fixture is vacuous: the keeper has no pinned weight")
	}
	testing.SetRealm(testing.NewUserRealm(keeper))
	VoteQuality(cross(cur), "rwq", id, qualityMid)
	rec := cs.qVoted.Get(beClaimKey(cs.qVoteSeq) + string(keeper))
	if rec == nil {
		t.Fatal("the keeper's quality vote was not recorded")
	}
	uassert.Equal(t, keeperPinned, rec.(int64))

	// ORDERING TWO — VOTE THEN SELL, which the floor alone left open at 599x on the
	// verdict lane. The keeper has now voted, so its own repayment is what must be
	// refused, and by the LOCK rather than the floor.
	testing.SetRealm(testing.NewUserRealm(keeper))
	uassert.AbortsContains(t, cur, "not enough uncommitted CC", func() {
		TransferCC(cross(cur), "rwq", whale, keeperPinned)
	})
	uassert.Equal(t, keeperPinned, VoteLockedOf("rwq", keeper))
	uassert.Equal(t, int64(0), disposable(c, keeper))
}
