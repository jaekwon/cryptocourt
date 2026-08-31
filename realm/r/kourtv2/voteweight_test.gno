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

	// VERDICT LANE. The second return is the retired quality lane's and is now
	// always zero; the read keeps its pair shape only because the overlay
	// destructures it, so this asserts the ONE quote that means anything and says
	// so rather than checking a constant.
	qVerdict, _ := ClaimVoteWeightOf("qmc", carol, id)
	if qVerdict <= 0 {
		t.Fatalf("fixture is vacuous: the verdict quote must be positive, got %d", qVerdict)
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

	// THE QUALITY LANE STOOD HERE and is gone. What it added was a SECOND lane whose
	// quote had to match its own charge independently; with one lane the assertion
	// above is the whole property.

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

	// VOTABLE IS SUPPLY LESS THE ESCROW, AND NEVER LESS THAN WHAT CAN BE CAST.
	//
	// An earlier version of this asserted votable EQUALS the sum of user holdings and
	// called the netting list complete. That is fixture-dependent and the claim was
	// wrong: ccwrap's vault holds CC at a realm address that can never vote, arriving
	// through TransferFromCC — the one generic `Transfer(from, to)` in the realm, which
	// the enumeration behind that claim saw and did not chase. Measured with 10e9
	// wrapped of 60e9 supply: votable 59,968,900,000 against a castable
	// 49,968,900,000, overstated by 16.7%. TestVotableCountsAKeylessHolderAndTheCapIsWhy
	// holds that case.
	//
	// So the two properties worth pinning are the definition and its DIRECTION.
	// Over-stating is fail-safe: bars denominated in a percentage of votable rise
	// above the weight able to clear them, which stalls a court and never passes
	// anything it should not. Under-stating is the dangerous one — every bar drops
	// below the electorate it is meant to measure — so the inequality is asserted, not
	// just the arithmetic.
	escrowW := c.coin.PastVotes(c.escrow, at)
	if escrowW <= 0 {
		t.Fatal("fixture is vacuous: the escrow holds nothing, so votable and the " +
			"raw total coincide and the netting is not being tested")
	}
	uassert.Equal(t, total-escrowW, votableAt(c, at))
	var userSum int64
	for _, a := range append([]address{alice}, holders...) {
		userSum = mustAdd(userSum, c.coin.PastVotes(a, at))
	}
	if votableAt(c, at) < userSum {
		t.Fatalf("votable %d is BELOW the castable weight %d, so every bar quoted "+
			"as a share of votable is now below the electorate it measures",
			votableAt(c, at), userSum)
	}

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

// TestTheTwoLanesGetSeparateExplanations went with the quality lane: there is one lane, so there are no two explanations to keep apart

// TestTheReadersSeeACounterPollAndQuoteWhatItCharges went with the quality lane: there is no counter poll

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
		// "spam" is the court's word for the bucket the governor calls abstain;
		// the literal "abstain" is refused at the boundary now.
		VoteDispute(cross(cur), "coh", id, []string{voteYes, voteNo, voteSpam, voteYes}[i])
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

// A KEYLESS HOLDER COUNTS AS VOTABLE, AND THE WRAP CAP IS WHY THAT IS TOLERABLE.
//
// ccwrap's Wrap moves CC to cur.Address() — a realm address with no key and no voting
// entrypoint — so wrapped coin is permanently uncastable and votableAt still counts it.
// This is item 3 of the standing list, and the answer is that it stays counted.
//
// NETTING IT OUT WOULD BE WORSE. kourtv2 is the lower layer; ccwrap depends on it and not
// the reverse, so kourtv2 would need a registry of addresses declared unable to vote — and
// shrinking votable LOWERS every bar denominated in it, which makes such a registry a
// lever for making quorum easier. A fail-safe overstatement is better than a governance
// surface that can cheapen every question in the court.
//
// What bounds it instead is ccwrap's own maxWrapBps, which refuses a wrap that would push
// the vault past its share of votable. So the overstatement is capped rather than
// eliminated, and the residual is that a bar quoted as q% of votable really costs
// q/(1-k)% of castable weight at a vault share of k.
func TestVotableCountsAKeylessHolderAndTheCapIsWhy(cur realm, t *testing.T) {
	alice := testutils.TestAddress("vkh-alice")
	holder := testutils.TestAddress("vkh-holder")
	vault := testutils.TestAddress("vkh-vault") // stands in for ccwrap's realm address
	c := testCourt(cur, "vkh", alice, 40_000_000_000)
	c.coin.Mint(holder, 20_000_000_000)
	stakeAnswerDispute(cur, "vkh", alice, holder)

	testing.SetRealm(testing.NewUserRealm(holder))
	TransferCC(cross(cur), "vkh", vault, 10_000_000_000)
	testing.SkipHeights(epochBlocks * 2)
	touch(c)
	at := c.coin.Epoch() - 1

	vaultW := c.coin.PastVotes(vault, at)
	if vaultW <= 0 {
		t.Fatal("fixture is vacuous: the vault holds nothing at the sealed epoch")
	}
	castable := c.coin.PastVotes(alice, at) + c.coin.PastVotes(holder, at)
	votable := votableAt(c, at)

	// Counted, deliberately, and the gap IS the vault.
	uassert.Equal(t, castable+vaultW, votable)
	if votable <= castable {
		t.Fatal("fixture is vacuous: the vault is not inflating votable, so there " +
			"is nothing here to bound")
	}
	// And still fail-safe: never below what can be cast.
	if votable < castable {
		t.Fatal("votable fell below the castable weight")
	}
}

// THE DIVESTED HOLDER GETS THE RIGHT SENTENCE, and it is not the capped one.
//
// whyWeighed is a four-way switch and an operator sweep found its third arm unpinned:
// widening `case w <= 0` to `< 0` sends a holder whose live balance is ZERO into the
// capped arm, which tells them they are "limited to what you still hold, which is less
// than you held when this question was asked". They hold nothing. The sentence implies a
// residual and there is none, and this is the divested renter — the one holder the whole
// floor exists to describe, so the one whose sentence is worth being exact about.
//
// Paired with the arm on either side of it, because a switch is only correct if each case
// keeps the ones below it from firing: the never-held holder and an ordinary uncapped
// holder must keep their own sentences.
func TestTheDivestedHolderIsNotToldTheyAreCappedAtNothing(cur realm, t *testing.T) {
	author := testutils.TestAddress("dw-author")
	staker := testutils.TestAddress("dw-staker")
	seller := testutils.TestAddress("dw-seller")
	newcomer := testutils.TestAddress("dw-newcomer")
	sink := testutils.TestAddress("dw-sink")
	keeper := testutils.TestAddress("dw-keeper") // holds throughout, pays nothing
	c := testCourt(cur, "dw", author, 40_000_000_000)
	c.coin.Mint(staker, 10_000_000_000)
	c.coin.Mint(seller, 20_000_000_000)
	c.coin.Mint(keeper, 5_000_000_000)

	id := stakeAnswerDispute(cur, "dw", author, staker)
	testing.SkipHeights(epochBlocks * 2)
	touch(c)
	testing.SetRealm(testing.NewUserRealm(staker))
	OpenDispute(cross(cur), "dw", id)
	cs := mustClaim(c, id)
	at := c.gov.EpochOf(cs.proposalID)

	// The seller held at the frozen epoch and holds nothing now.
	if c.coin.PastVotes(seller, at) <= 0 {
		t.Fatal("fixture: the seller has no snapshot to be divested of")
	}
	testing.SetRealm(testing.NewUserRealm(seller))
	TransferCC(cross(cur), "dw", sink, DisposableOf("dw", seller))
	if c.coin.BalanceOf(seller) != 0 {
		t.Fatalf("fixture: the seller still holds %d, so w is not zero and the "+
			"arm under test does not fire", c.coin.BalanceOf(seller))
	}
	verdict, _ := VoteWeightWhy("dw", seller, id)
	uassert.Equal(t,
		"you had some when this vote started but have none now, and your say is the smaller of the two",
		verdict)

	// THE ARM ABOVE: a holder who never held at all gets its own sentence, not the
	// divested one.
	if c.coin.PastVotes(newcomer, at) != 0 {
		t.Fatal("fixture: the newcomer is not a newcomer")
	}
	verdict, _ = VoteWeightWhy("dw", newcomer, id)
	uassert.Equal(t,
		"you had none when this vote started; coin bought since counts in later votes",
		verdict)

	// THE ARM BELOW: an uncapped holder is not told they were capped. The keeper is a
	// separate address for a reason found the hard way — the staker pays a dispute
	// bond, so its live balance sits BELOW its snapshot and it is genuinely capped.
	if w, snap := votingWeight(c, keeper, at); w != snap || w <= 0 {
		t.Fatalf("fixture: the keeper is capped (w %d, snapshot %d), so it cannot "+
			"stand for the uncapped case", w, snap)
	}
	verdict, _ = VoteWeightWhy("dw", keeper, id)
	uassert.Equal(t, "counted in full", verdict)
}
