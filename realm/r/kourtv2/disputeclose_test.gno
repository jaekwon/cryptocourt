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
