package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// DisputeVoteCloses must agree with the gate the court actually enforces, not
// merely be a plausible number. The governor refuses a vote once
// heightNow() >= closes and ResolveDispute refuses until then, so the read is
// asserted AGAINST BOTH: one block before the answer, a vote is accepted and
// Resolve is refused; one block after, the reverse. A read that were off by a
// day would still look reasonable on a page and would be caught here.
func TestDisputeVoteClosesMatchesTheGate(cur realm, t *testing.T) {
	alice := testutils.TestAddress("dvc-alice")
	bob := testutils.TestAddress("dvc-bob")
	carol := testutils.TestAddress("dvc-carol")
	dave := testutils.TestAddress("dvc-dave")
	c := testCourt(cur, "dvc", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)
	// Minted with the others, BEFORE the round opens, so dave carries snapshot
	// weight when he tries to vote after the close. Without it he would be
	// refused for holding nothing and the assertion below would pass on the
	// wrong layer.
	c.coin.Mint(dave, 12_000_000_000)

	id := stakeAnswerDispute(cur, "dvc", alice, bob)

	// BEFORE a round is open the answer is 0, not a panic and not a stale
	// height: a client draws this on every claim page, and "no round is open"
	// is an answer. Asserted before OpenDispute so it cannot pass by reading a
	// zero that simply has not been written yet in some later state.
	uassert.Equal(t, int64(0), DisputeVoteCloses("dvc", id))

	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "dvc", id)

	closes := DisputeVoteCloses("dvc", id)
	if closes == 0 {
		t.Fatal("an open round must publish its close height")
	}
	// The window is the governor's own, taken from the court's params rather
	// than restated as a literal here: a test that spells the expectation with
	// the constant under test moves with it and pins nothing. This one pins the
	// SHAPE — opened at the current height, closing votingBlocks later — and
	// the two behavioural assertions below pin the value.
	uassert.Equal(t, heightNow()+c.params.votingBlocks, closes)

	// One block short of the close: voting works, resolving does not.
	testing.SkipHeights(closes - heightNow() - 1)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "dvc", id, "yes")
	uassert.AbortsContains(t, cur, "the dispute vote is still open", func() {
		ResolveDispute(cross(cur), "dvc", id)
	})
	// ...and the read has not moved under an open vote.
	uassert.Equal(t, closes, DisputeVoteCloses("dvc", id))

	// At the close: voting is refused, and the round can be resolved.
	//
	// DAVE, not alice and not carol. Alice authored the claim and would be
	// refused by kourtv2's own participant guard; carol has already voted and
	// would be refused by the governor's "already voted" — either would pass
	// this assertion without the CLOSE having anything to do with it. Dave is
	// eligible in every way except that the window has shut.
	//
	// The message is the governor's own and is named in full: castVote calls
	// settle(p) first, which moves a past-close proposal off stateActive, and
	// the refusal is the one below. An empty or generic expectation here is
	// satisfied by any layer, which is what check-abort-assertions objects to.
	testing.SkipHeights(1)
	testing.SetRealm(testing.NewUserRealm(dave))
	uassert.AbortsContains(t, cur, "govern: that proposal is closed", func() {
		VoteDispute(cross(cur), "dvc", id, "no")
	})
	testing.SetRealm(testing.NewUserRealm(carol))
	ResolveDispute(cross(cur), "dvc", id)

	// A resolved round is not an open one, so the read goes back to 0 rather
	// than leaving a height in the past on the page — which would render as a
	// countdown that has already run out on a claim with nothing to vote on.
	uassert.Equal(t, int64(0), DisputeVoteCloses("dvc", id))
}

// THE BALLOT'S VOCABULARY, at the boundary where it is translated.
//
// The court says "spam"; the governor says "abstain" for the same bucket — the
// one that counts toward quorum and not toward the verdict bar. One translation
// point, and the old word is REFUSED rather than aliased: two names for one
// bucket is how a client and a realm come to disagree about what was cast, and
// a caller still sending "abstain" was written against a meaning that no longer
// describes what the vote does.
func TestTheBallotTakesSpamAndRefusesAbstain(cur realm, t *testing.T) {
	alice := testutils.TestAddress("bv-alice")
	bob := testutils.TestAddress("bv-bob")
	carol := testutils.TestAddress("bv-carol")
	dave := testutils.TestAddress("bv-dave")
	c := testCourt(cur, "bv", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)
	c.coin.Mint(dave, 12_000_000_000)

	id := stakeAnswerDispute(cur, "bv", alice, bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "bv", id)

	// The word that used to work.
	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsContains(t, cur, "\"spam\" to say the claim was not worth judging", func() {
		VoteDispute(cross(cur), "bv", id, "abstain")
	})
	// And anything else, so the refusal is not specific to one stale word.
	uassert.AbortsContains(t, cur, "\"spam\" to say the claim was not worth judging", func() {
		VoteDispute(cross(cur), "bv", id, "maybe")
	})

	// The word that works, and it lands in the governor's abstain bucket —
	// counted toward turnout, absent from the verdict bar.
	cs := mustClaim(c, id)
	VoteDispute(cross(cur), "bv", id, voteSpam)
	yes, no, abstain, _ := c.gov.Tally(cs.proposalID)
	uassert.Equal(t, int64(0), yes)
	uassert.Equal(t, int64(0), no)
	if abstain <= 0 {
		t.Fatalf("a spam vote must land in the quorum-counting bucket, got %d", abstain)
	}

	// THE COURT'S OWN RECORD KEEPS THE COURT'S WORD. PullCarrot matches this
	// against cs.carrotChoice, which is written in this realm's vocabulary — a
	// record saying "abstain" could never match a "spam" payout.
	v := cs.qVoted.Get("d" + beClaimKey(uint64(cs.proposalID)) + string(carol))
	if v == nil {
		t.Fatal("the court must record the vote it just cast")
	}
	uassert.Equal(t, voteSpam, v.(string))

	// A side vote still works and still takes a side.
	testing.SetRealm(testing.NewUserRealm(dave))
	VoteDispute(cross(cur), "bv", id, voteYes)
	yes2, _, _, _ := c.gov.Tally(cs.proposalID)
	if yes2 <= 0 {
		t.Fatal("a yes must still reach the verdict bar")
	}
}

// THE SPAM TALLY IS FROZEN ON THE ROUND THAT DECIDED, not on whatever round
// cs.proposalID happens to name later.
//
// This is decidedPID's own reason, applied to a second pair of figures:
// proposalID is overwritten by every new round, so a claim that fails a round
// and then decides on the next one would, without this, be discounted by the
// tally of a round that decided nothing. The governor's counters DO survive a
// ReleaseRoll — Tally reads yes/no/abstain and not the roll — so the hazard is
// reading the wrong round, not reading a gap.
func TestTheSpamTallyIsFrozenOnTheDecidingRound(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sf-alice")
	bob := testutils.TestAddress("sf-bob")
	carol := testutils.TestAddress("sf-carol")
	dave := testutils.TestAddress("sf-dave")
	c := testCourt(cur, "sf", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)
	// A NON-ZERO SPAM WEIGHT IS LOAD-BEARING IN THIS FIXTURE. With nobody
	// flagging spam, `cast = yes+no+spam` and `cast = yes+no` are the same
	// number, and an ablation dropping spam from the denominator passed —
	// measured. Dave's weight is what makes the two distinguishable.
	c.coin.Mint(dave, 12_000_000_000)

	id := stakeAnswerDispute(cur, "sf", alice, bob)
	cs := mustClaim(c, id)

	// Nothing is frozen before a round decides — and zero is what the draw reads
	// as "no discount", not as "discount to nothing".
	uassert.Equal(t, int64(0), cs.spamW)
	uassert.Equal(t, int64(0), cs.spamTotalW)

	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "sf", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "sf", id, voteYes)
	testing.SetRealm(testing.NewUserRealm(dave))
	VoteDispute(cross(cur), "sf", id, voteSpam)
	testing.SkipHeights(c.params.votingBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(carol))
	ResolveDispute(cross(cur), "sf", id)

	// The deciding round's figures, and the denominator is the SAME cast the
	// quorum bar was measured against — so a discount is a fraction of the
	// turnout that actually decided the claim.
	if cs.decidedPID == 0 {
		t.Fatal("the fixture must produce a decided round")
	}
	yes, no, spam, _ := c.gov.Tally(cs.decidedPID)
	if spam <= 0 {
		t.Fatal("the fixture must carry a real spam weight, or the denominator " +
			"arm below cannot be distinguished from yes+no")
	}
	uassert.Equal(t, spam, cs.spamW)
	// THE DENOMINATOR INCLUDES SPAM, which is the same cast the quorum bar was
	// measured against — so the discount is a fraction of the turnout that
	// actually decided the claim, not of the side-takers only.
	uassert.Equal(t, yes+no+spam, cs.spamTotalW)
	if cs.spamTotalW == yes+no {
		t.Fatal("the denominator must not be yes+no — spam is part of the turnout")
	}

	// AND THEY ARE FROZEN AGAINST decidedPID, not proposalID. Asserted as an
	// identity rather than by driving a second round: the two ids are equal here,
	// so a test that only compared figures would pass either way — what pins the
	// choice is that the frozen denominator matches the DECIDED round's tally,
	// which the read above uses cs.decidedPID to fetch.
	uassert.Equal(t, cs.decidedPID, cs.proposalID)
}

// THE DISCARD, DRIVEN THROUGH A REAL VOTE — the money and the carrot.
//
// THE FIXTURE'S SHAPE IS THE FINDING. Three earlier attempts died on
// "govern: already voted" with demonstrably distinct voter addresses, and the
// cause was not the addresses: a voter needs CHECKPOINTED weight at the
// proposal's epoch, so an epoch has to be sealed (SkipHeights + touch) between
// minting the voters and opening the dispute. Without that seal the votes go
// wrong in a way whose error names the wrong thing entirely.
//
// It also has to be driven through ResolveDispute rather than by calling
// spamDiscardClaim: OpenDispute moves the escrow by ZERO while recording a bond
// — the disputer's coin passes through to the governor as the proposal's own
// bond and only returns when it settles — so a discard called any earlier tries
// to refund a bond the escrow does not hold.
func TestTheSpamDiscardPaysEveryoneButTheAuthor(cur realm, t *testing.T) {
	author := testutils.TestAddress("sk-author")
	staker := testutils.TestAddress("sk-staker")
	flag := testutils.TestAddress("sk-flag")
	keep := testutils.TestAddress("sk-keep")
	c := testCourt(cur, "sk", author, 30_000_000_000)
	c.coin.Mint(staker, 10_000_000_000)
	// Unequal on purpose: the spam share is WEIGHT, not headcount. 8 against 2
	// is 80% — past half, so the claim is discarded, and past two thirds, so the
	// deposit burns as well.
	c.coin.Mint(flag, 8_000_000_000)
	c.coin.Mint(keep, 2_000_000_000)

	id := stakeAnswerDispute(cur, "sk", author, staker)

	// SEAL AN EPOCH so the voters have checkpointed weight to vote with.
	testing.SkipHeights(epochBlocks)
	touch(c)

	testing.SetRealm(testing.NewUserRealm(staker))
	OpenDispute(cross(cur), "sk", id)
	cs := mustClaim(c, id)
	if cs.deposit <= 0 || cs.fee <= 0 || cs.answerBond <= 0 || cs.disputeBond <= 0 {
		t.Fatalf("the fixture must have all four at stake: dep=%d fee=%d "+
			"answer=%d dispute=%d", cs.deposit, cs.fee, cs.answerBond, cs.disputeBond)
	}

	testing.SetRealm(testing.NewUserRealm(flag))
	VoteDispute(cross(cur), "sk", id, voteSpam)
	testing.SetRealm(testing.NewUserRealm(keep))
	VoteDispute(cross(cur), "sk", id, voteNo)

	dep, fee := cs.deposit, cs.fee
	authorBefore := c.coin.BalanceOf(author)
	stakerBefore := c.coin.BalanceOf(staker)
	supplyBefore := c.coin.TotalSupply()

	testing.SkipHeights(c.params.votingBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(staker))
	ResolveDispute(cross(cur), "sk", id)

	if !cs.spamClosed {
		t.Fatalf("a four-fifths spam vote must discard the claim, got route %q", cs.route)
	}
	// THE DISPUTER IS REPAID. They opened the round that found the spam, and
	// burning their bond would discourage the only path that surfaces it.
	if c.coin.BalanceOf(staker) <= stakerBefore {
		t.Fatal("the disputer's bond must return on a discard")
	}
	// THE ANSWERER IS REPAID — author and answerer are the same address here, so
	// this is asserted against the burn below rather than in isolation.
	if c.coin.BalanceOf(author) <= authorBefore {
		t.Fatal("the answerer's bond must return on a discard")
	}
	// AND EXACTLY THE RIGHT COIN LEFT THE SUPPLY. Asserted as an AMOUNT, not as
	// "something burned": at four fifths both the deposit and the fee burn, and
	// a version that refunded the fee would still burn the deposit and still
	// satisfy `burned > 0` — measured, that ablation survived until this line
	// named the sum.
	burned := supplyBefore - c.coin.TotalSupply()
	uassert.Equal(t, dep+fee, burned)
	if fee <= 0 || dep <= 0 {
		t.Fatal("the fixture must have both at stake for that sum to mean anything")
	}

	// THE CARROT IS POINTED AT THE SPAM SIDE, which is what stops the button
	// being dominated the way abstain was.
	uassert.Equal(t, voteSpam, cs.carrotChoice)
	if cs.carrotDenom != cs.spamW || cs.carrotDenom <= 0 {
		t.Fatalf("the carrot's denominator must be the spam weight: denom=%d spam=%d",
			cs.carrotDenom, cs.spamW)
	}
	if cs.decidedPID == 0 {
		t.Fatal("PullCarrot reads the deciding round, so a discard must name one")
	}
	// And the flagger's own ballot is on record under the COURT's word, so it
	// can match carrotChoice at pull time.
	v := cs.qVoted.Get("d" + beClaimKey(uint64(cs.decidedPID)) + string(flag))
	if v == nil || v.(string) != voteSpam {
		t.Fatalf("the spam voter's ballot must be recorded as %q, got %v", voteSpam, v)
	}
}
