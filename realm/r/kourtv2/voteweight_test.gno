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
	// AND THE COMMITMENT IS THAT SAME NUMBER. Asserted HERE, before the quality vote
	// adds a second row, because voteLockedOf is a MAX and would stop isolating this
	// lane once another row exists.
	//
	// This is the direction that matters. A lock BELOW the charge is the rental
	// reopened — vote at w, commit less, sell the difference while the ballot stands,
	// which is the 599x vote-then-sell the lock was built to price. Nothing else in
	// the suite compared these two numbers for this lane; the structure that keeps
	// them equal is that dispute.gno locks the figure it READS BACK from the governor
	// rather than one it recomputes, and that structure was unpinned.
	uassert.Equal(t, qVerdict, VoteLockedOf("qmc", carol))

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
	// The COMMITMENT is the same number too, which the turnout assertion above does
	// not show: modvote uses one `w` for the voter record, the turnout and the lock,
	// and a lock below the charge would let this voter sell the difference while
	// their approval still counts.
	uassert.Equal(t, quoted, VoteLockedOf("eqf", voter))

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

// THE READERS MUST SEE A COUNTER POLL, and the quote they give must be the charge.
//
// The counter re-vote is the one quality question neither reader was ever tested
// against: mutating the counterOpen term out of qualityQuestionOpen survived the whole
// suite, both before and after that predicate was consolidated, which means nothing
// asked either reader what it says while a counter poll is open. The consequence would
// not be a crash — it is a holder told "no quality vote is open on this claim" and
// quoted zero weight, on a question they can vote in right now.
//
// Paired both ways round: with nothing open the readers must SAY nothing is open, or
// this test would pass on a reader that answers "you have weight" unconditionally.
func TestTheReadersSeeACounterPollAndQuoteWhatItCharges(cur realm, t *testing.T) {
	c, id, alice, _, carol, _, _ := slashSetup(cur, t, "cqr")
	cs := mustClaim(c, id)

	// THE BYSTANDER: the flag that created the slash has resolved, so no quality
	// question is open and both readers must say exactly that.
	if qualityQuestionOpen(cs) {
		t.Fatal("fixture: a question is already open, so the negative half of " +
			"this test is vacuous")
	}
	if _, q := ClaimVoteWeightOf("cqr", carol, id); q != 0 {
		t.Fatalf("quoted %d quality weight with no quality question open", q)
	}
	_, why := VoteWeightWhy("cqr", carol, id)
	uassert.Equal(t, "no quality vote is open on this claim", why)

	// The answerer opens their one counter re-vote.
	testing.SetRealm(testing.NewUserRealm(alice))
	CounterFlag(cross(cur), "cqr", id)
	if !cs.counterOpen {
		t.Fatal("fixture: the counter poll did not open")
	}

	_, quoted := ClaimVoteWeightOf("cqr", carol, id)
	if quoted <= 0 {
		t.Fatal("a counter poll is open and carol holds coin, so the reader must " +
			"quote a quality weight — a zero here is the reader failing to see " +
			"the counter lane at all")
	}
	_, why = VoteWeightWhy("cqr", carol, id)
	if why == "no quality vote is open on this claim" {
		t.Fatal("the explainer denies a counter poll that IS open")
	}

	// AND THE QUOTE IS THE CHARGE. This is the property the split readers exist for:
	// what the elector is told, and what the vote actually commits, are one number.
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "cqr", id, qualityMid)
	uassert.Equal(t, quoted, VoteLockedOf("cqr", carol))
}

// THE COHERENCE CHAIN, END TO END IN A REAL COURT.
//
// The whole safety case is
//
//	Σ min(PastVotes(·,E), BalanceOf(·))  ≤  Σ PastVotes(·,E)  =  PastTotal(E)
//
// so cast can never exceed the proposal's own total and rest = total - cast is never
// negative. A negative rest is not a rounding curiosity: it let the early-DEFEAT arm
// fire on a question still open, and that work was reverted.
//
// Both halves were pinned in ISOLATION and never together. TestPastVotesSumToPastTotal
// asserts the ledger identity by summing over addresses directly. The governor's own
// suite asserts parts-never-exceed-the-whole, including under caps, against synthetic
// ledgers it builds itself. Nothing asserted the JOIN: a real dispute in a real court,
// where kourtv2 picks the epoch, kourtv2 supplies the caps, and the governor tallies.
// That join is where an epoch can be wired to the wrong instant while both halves stay
// individually correct.
//
// Every voter here is capped, which is the condition that makes the chain's first
// inequality strict rather than decorative, and the fixture asserts that it bit.
func TestTheCoherenceChainHoldsForARealDisputeWithEveryVoterCapped(cur realm, t *testing.T) {
	author := testutils.TestAddress("coh-author")
	staker := testutils.TestAddress("coh-staker")
	sink := testutils.TestAddress("coh-sink")
	voters := []address{
		testutils.TestAddress("coh-v1"), testutils.TestAddress("coh-v2"),
		testutils.TestAddress("coh-v3"), testutils.TestAddress("coh-v4"),
	}
	c := testCourt(cur, "coh", author, 30_000_000_000)
	c.coin.Mint(staker, 10_000_000_000)
	for i, v := range voters {
		c.coin.Mint(v, int64(i+3)*2_000_000_000) // 6, 8, 10, 12 e9 — distinct weights
	}

	id := stakeAnswerDispute(cur, "coh", author, staker)

	// SUPPLY MUST MOVE ACROSS THE EPOCH BOUNDARY, or the epoch-link assertion below
	// cannot fail. Measured: with a flat supply, PastTotal(at) and PastTotal(at-1) are
	// the same number, so taking the proposal's total from the WRONG epoch — the
	// reverted live-denominator defect, in miniature — passed the test. An assertion
	// that cannot distinguish its two sides is not an assertion. Minted after the
	// answer so the supply-proportional answer bar was already cleared.
	testing.SkipHeights(epochBlocks) // seal an epoch WITHOUT the mint
	touch(c)
	c.coin.Mint(sink, 9_000_000_000) // lands in the NEXT epoch
	testing.SkipHeights(epochBlocks) // and seal that one WITH it
	touch(c)

	testing.SetRealm(testing.NewUserRealm(staker))
	OpenDispute(cross(cur), "coh", id)
	cs := mustClaim(c, id)
	at := c.gov.EpochOf(cs.proposalID)
	if at < 2 || c.coin.PastTotal(at) == c.coin.PastTotal(at-1) {
		t.Fatalf("fixture cannot tell two epochs apart: PastTotal(%d)=%d, "+
			"PastTotal(%d)=%d — the epoch-link assertion would pass on a total "+
			"read at the wrong instant", at, c.coin.PastTotal(at), at-1,
			c.coin.PastTotal(at-1))
	}

	// Every voter divests half to a sink that never votes, AFTER the epoch froze. So
	// each one's live balance is below its own snapshot and the floor binds for all
	// four — the case the chain is actually about.
	var snapSum int64
	for _, v := range voters {
		snap := c.coin.PastVotes(v, at)
		if snap <= 0 {
			t.Fatal("fixture: a voter has no checkpointed weight at the frozen epoch")
		}
		snapSum += snap
		testing.SetRealm(testing.NewUserRealm(v))
		TransferCC(cross(cur), "coh", sink, c.coin.BalanceOf(v)/2)
		if c.coin.BalanceOf(v) >= snap {
			t.Fatalf("fixture is vacuous: %s is not capped, balance %d vs snapshot %d",
				v, c.coin.BalanceOf(v), snap)
		}
	}

	// All four vote, split across the choices so no single arm dominates.
	for i, v := range voters {
		testing.SetRealm(testing.NewUserRealm(v))
		VoteDispute(cross(cur), "coh", id, []string{"yes", "no", "abstain", "yes"}[i])
	}

	yes, no, abstain, total := c.gov.Tally(cs.proposalID)
	cast := yes + no + abstain
	rest := total - cast

	// THE LINK THAT WAS UNPINNED: the proposal's own total is the ledger's sealed
	// total at the epoch kourtv2 froze. If these ever differ, every bar in the round
	// is drawn on a different base than the weights it judges.
	uassert.Equal(t, c.coin.PastTotal(at), total)

	if cast > total {
		t.Fatalf("cast %d exceeds the proposal total %d: rest is %d and the "+
			"early-defeat arm can fire on an open question", cast, total, rest)
	}
	if rest < 0 {
		t.Fatalf("rest is %d", rest)
	}
	// And strictly below the uncapped sum, which is what proves the floor did the
	// work rather than the inequality holding for a trivial reason.
	if cast >= snapSum {
		t.Fatalf("cast %d is not below the uncapped snapshot sum %d, so the caps "+
			"never bit and this test would pass without the floor", cast, snapSum)
	}
	if cast <= 0 {
		t.Fatal("fixture is vacuous: nothing was cast")
	}
	// The bar is drawn on the same base it judges.
	if floor := c.gov.QuorumFloor(cs.proposalID); floor > total {
		t.Fatalf("quorum floor %d exceeds the total %d it is a fraction of",
			floor, total)
	}
	// Per voter, the charge is the capped figure and not the snapshot.
	for _, v := range voters {
		_, charged, ok := c.gov.VoteOf(cs.proposalID, v)
		uassert.True(t, ok)
		w, snap := votingWeight(c, v, at)
		uassert.Equal(t, w, charged)
		if charged >= snap {
			t.Fatalf("%s was charged %d, its uncapped snapshot %d", v, charged, snap)
		}
	}
}
