package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// THE QUOTE MATCHES THE CHARGE, in all three lanes.
//
// voteweight.gno exists so that the number shown to an elector and the number the
// vote actually records come from one expression. That is a claim about two code
// paths agreeing, which is exactly the kind of claim a comment cannot keep — so
// this asserts it by reading the quote, casting the vote, and comparing the quote
// against the RECORDED weight rather than against a re-derivation.
//
// The verdict lane is the one worth the trouble: it does not call votingWeight at
// all. It hands the governor a ceiling and the governor derives its own snapshot,
// so quote and charge agree only because min(PastVotes(who, p.epoch), BalanceOf) is
// the same number computed twice in two packages. If either drifts, this fails.
func TestTheQuoteMatchesTheCharge(cur realm, t *testing.T) {
	alice := testutils.TestAddress("qmc-alice")
	bob := testutils.TestAddress("qmc-bob")
	carol := testutils.TestAddress("qmc-carol")
	c := testCourt(cur, "qmc", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)
	id := stakeAnswerDispute(cur, "qmc", alice, bob)
	cs := mustClaim(c, id)

	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "qmc", id)

	// Make the floor actually bite, so the quote is not trivially the snapshot:
	// carol gives away part of her position after the anchor was pinned.
	testing.SetRealm(testing.NewUserRealm(carol))
	TransferCC(cross(cur), "qmc", bob, 8_000_000_000)
	snap := c.coin.PastVotes(carol, c.gov.EpochOf(cs.proposalID))
	if snap <= c.coin.BalanceOf(carol) {
		t.Fatal("fixture is vacuous: the floor must bite for quote-vs-charge to " +
			"be more than an identity on the snapshot")
	}

	// VERDICT LANE.
	qVerdict, qQuality := ClaimVoteWeightOf("qmc", carol, id)
	if qVerdict <= 0 || qQuality <= 0 {
		t.Fatalf("fixture is vacuous: both quotes must be positive, got %d and %d",
			qVerdict, qQuality)
	}
	uassert.Equal(t, c.coin.BalanceOf(carol), qVerdict) // capped, not the snapshot
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "qmc", id, "no")
	_, charged, ok := c.gov.VoteOf(cs.proposalID, carol)
	uassert.True(t, ok)
	uassert.Equal(t, qVerdict, charged)

	// QUALITY LANE.
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "qmc", id, qualityMid)
	rec := cs.qVoted.Get(beClaimKey(cs.qVoteSeq) + string(carol))
	if rec == nil {
		t.Fatal("fixture is vacuous: the quality weight was never recorded")
	}
	uassert.Equal(t, qQuality, rec.(int64))

	// AND THE EXPLANATION IS THE RIGHT ONE, since a holder acts on it. Per lane,
	// because with a dispute open there are two live questions at two epochs.
	capped := "capped at what you still hold, which is less than you held when " +
		"this question was asked"
	cv, cq := VoteWeightWhy("qmc", carol, id)
	uassert.Equal(t, capped, cv)
	uassert.Equal(t, capped, cq)
	// The bystander: bob held throughout, so he is quoted the full snapshot in both.
	bv, bq := VoteWeightWhy("qmc", bob, id)
	uassert.Equal(t, "weighed at the full snapshot", bv)
	uassert.Equal(t, "weighed at the full snapshot", bq)
}

// THE ELECTION QUOTE REPORTS THE FROZEN FIGURE, not a fresh derivation.
//
// A voter's weight is fixed at their first approval and reused for the whole
// ballot, so after approving once the quote must report what was frozen. A reader
// that re-derived would tell a voter who has since topped up that they are worth
// more than their remaining lines will be credited.
func TestTheElectionQuoteReportsTheFrozenFigure(cur realm, t *testing.T) {
	creator := testutils.TestAddress("eqf-creator")
	voter := testutils.TestAddress("eqf-voter")
	helper := testutils.TestAddress("eqf-helper")
	modA := testutils.TestAddress("eqf-moda")
	c := electionCourt(cur, "eqf", creator, []address{voter, helper},
		[]int64{100_000_000_000, 400_000_000_000})
	c.coin.Mint(voter, 50_000_000)

	testing.SetRealm(testing.NewUserRealm(voter))
	cand := RegisterModCandidate(cross(cur), "eqf", 1, modA)
	testing.SetRealm(testing.NewUserRealm(voter))
	OpenElection(cross(cur), "eqf", cand)
	testing.SkipHeights(nominationWindow)

	// Go poor, so the first approval freezes a reduced figure.
	testing.SetRealm(testing.NewUserRealm(voter))
	TransferCC(cross(cur), "eqf", helper, SpendableOf("eqf", voter)-1_000_000_000)
	quoted := ElectionVoteWeightOf("eqf", voter)
	if quoted <= 0 {
		t.Fatal("fixture is vacuous: nothing quoted before the first approval")
	}
	testing.SetRealm(testing.NewUserRealm(voter))
	ApproveCandidate(cross(cur), "eqf", cand)
	_, _, turnout := ElectionTally("eqf", cand)
	uassert.Equal(t, quoted, turnout)

	// Top back up well above the snapshot. The quote must NOT move.
	testing.SetRealm(testing.NewUserRealm(helper))
	TransferCC(cross(cur), "eqf", voter, 200_000_000_000)
	if c.coin.BalanceOf(voter) <= quoted {
		t.Fatal("fixture is vacuous: the top-up must exceed the frozen figure")
	}
	uassert.Equal(t, quoted, ElectionVoteWeightOf("eqf", voter))
}

// Σ PastVotes == PastTotal at a sealed epoch — the ledger identity every coherence
// argument in this design rests on.
//
// The whole safety case is Σ min(PastVotes, BalanceOf) ≤ Σ PastVotes = PastTotal,
// and the second step is an equality, not an inequality. OZ cannot say it
// (getPastTotalSupply counts all supply while getPastVotes counts only DELEGATED
// supply, so its denominator exceeds its achievable numerator); grc20votes can,
// because delegation defaults to self. That is asserted in a comment in
// grc20votes.gno and, until now, nowhere else.
func TestPastVotesSumToPastTotal(cur realm, t *testing.T) {
	alice := testutils.TestAddress("spv-alice")
	holders := []address{
		testutils.TestAddress("spv-h1"), testutils.TestAddress("spv-h2"),
		testutils.TestAddress("spv-h3"), testutils.TestAddress("spv-h4"),
	}
	c := testCourt(cur, "spv", alice, 7_000_000_000)
	for i, h := range holders {
		c.coin.Mint(h, int64(i+1)*1_111_111_111)
	}
	id := stakeAnswerDispute(cur, "spv", alice, holders[0])
	_ = id
	testing.SkipHeights(epochBlocks * 2)
	touch(c)
	at := c.coin.Epoch() - 1

	// Every address that can hold this coin: the four holders, the author, and the
	// court's own escrow, which is where bonds and stakes went.
	var sum int64
	for _, a := range append([]address{alice, c.escrow}, holders...) {
		sum = mustAdd(sum, c.coin.PastVotes(a, at))
	}
	total := c.coin.PastTotal(at)
	if total <= 0 {
		t.Fatal("fixture is vacuous: nothing was in issue at that epoch")
	}
	// EXACT. Not "at most" — the parts of a self-delegated ledger sum to the whole,
	// and an inequality here would mean weight nobody can cast sits in every
	// denominator.
	uassert.Equal(t, total, sum)

	// And the floor can only lower it, which is the step that makes every tally
	// coherent against a bar drawn at the same epoch.
	var capped int64
	for _, a := range append([]address{alice, c.escrow}, holders...) {
		w, _ := votingWeight(c, a, at)
		capped = mustAdd(capped, w)
	}
	if capped > total {
		t.Fatalf("Σ min(snapshot, held) = %d exceeded PastTotal = %d", capped, total)
	}
}

// THE TWO LANES CAN DISAGREE, AND THE EXPLAINER MUST NOT AVERAGE THEM.
//
// With a dispute open, BOTH questions are live — VoteQuality accepts votes while
// cs.disputeOpen — at DIFFERENT epochs: the verdict at the proposal's, the quality
// ride at the answer's. So a holder who bought AFTER the answer but BEFORE the
// dispute opened has nothing at the quality epoch and a full position at the
// dispute's.
//
// The first VoteWeightWhy returned one string and picked the dispute's epoch whenever
// a dispute was open. Measured, this exact holder was told "weighed at the full
// snapshot" while VoteQuality was about to refuse them for having no checkpointed
// weight at all. The reader was not merely incomplete, it was wrong in the direction
// that makes a holder act.
func TestTheTwoLanesGetSeparateExplanations(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tls-alice")
	whale := testutils.TestAddress("tls-whale")
	late := testutils.TestAddress("tls-late")
	c := testCourt(cur, "tls", alice, 40_000_000_000)
	c.coin.Mint(whale, 60_000_000_000)

	// Answered while `late` holds nothing: the quality epoch sees zero.
	id := stakeAnswerDispute(cur, "tls", alice, whale)
	cs := mustClaim(c, id)
	testing.SkipHeights(epochBlocks * 2)
	touch(c)

	// THEN they acquire, and it seals, so the dispute's epoch will see them.
	testing.SetRealm(testing.NewUserRealm(whale))
	TransferCC(cross(cur), "tls", late, 10_000_000_000)
	testing.SkipHeights(epochBlocks * 2)
	touch(c)
	testing.SetRealm(testing.NewUserRealm(whale))
	OpenDispute(cross(cur), "tls", id)

	// The instrument's own precondition: the two epochs must actually disagree, or
	// this test is asserting nothing that a single-string version would fail.
	qSnap := c.coin.PastVotes(late, cs.qualityEpoch)
	dSnap := c.coin.PastVotes(late, c.gov.EpochOf(cs.proposalID))
	if qSnap != 0 || dSnap <= 0 {
		t.Fatalf("fixture is vacuous: need a zero quality snapshot and a positive "+
			"dispute one, got %d and %d", qSnap, dSnap)
	}

	verdict, quality := ClaimVoteWeightOf("tls", late, id)
	uassert.Equal(t, int64(0), quality)
	uassert.True(t, verdict > 0)

	vWhy, qWhy := VoteWeightWhy("tls", late, id)
	uassert.Equal(t, "weighed at the full snapshot", vWhy)
	if qWhy == vWhy {
		t.Fatalf("the two lanes disagree for this holder, so their explanations "+
			"must too — both said %q", qWhy)
	}
	uassert.Equal(t, "you held no coin at the epoch this question was frozen at, "+
		"so there is nothing to weigh; coin bought since counts in later questions",
		qWhy)

	// And the realm agrees with the quality explanation rather than the verdict one.
	testing.SetRealm(testing.NewUserRealm(late))
	uassert.AbortsContains(t, cur, "no checkpointed weight at the claim's quality "+
		"epoch", func() { VoteQuality(cross(cur), "tls", id, qualityMid) })
}
