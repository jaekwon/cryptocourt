package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// RENTED VOTING WEIGHT — A CHARACTERIZATION TEST, NOT A GUARD.
//
// READ THIS FIRST. The tests below assert that the exploit WORKS. They are not
// endorsing it. They exist because the hole is real, measured, currently OPEN, and
// exactly the kind of thing that gets silently forgotten — so it is pinned here
// with its own numbers, and ANY FIX MUST FLIP THESE ASSERTIONS. A test that goes
// green after a fix would have hidden the fix; these will fail loudly and their
// failure is the signal that the decision in RENTEDWEIGHT.md was finally taken.
//
// THE HOLE. Every vote is weighed at a sealed past epoch, and governor.propose
// used to claim in a comment that this made weight "impossible to rent". It does
// not. The anchor is Epoch()-1 AT PROPOSE TIME, and for two of the three lanes the
// party who INITIATES the action is the one who pins it. So: acquire float on the
// market — possible at all only because court coins were made transferable — wait
// ONE epoch for the checkpoint to seal, open the dispute or election yourself
// (pinning the anchor to a window in which you hold), sell everything back, and
// vote with the full weight you no longer own. A past checkpoint cannot be
// un-written by a later transfer.
//
// WHAT IS AND IS NOT NEW. "Selling out after voting costs nothing" is the standard
// snapshot-governance property, deliberate, and pinned by r/govern's own
// TestAVoteCannotBePassedAlongWithTheTokens. What is new is that the actor CHOOSES
// THE ANCHOR, which converts an accepted property into a rental market. r/govern's
// token has always been transferable, so this lane was exposed before kourtv2 was.
//
// WHY NOTHING IS FIXED HERE. Two closures were implemented and measured, and each
// broke an honest path; RENTEDWEIGHT.md has the numbers. It is an owner decision.
//
// ONE HONEST QUALIFICATION, because the probe overstates the attack. TransferCC
// between two test addresses is free. Acquiring a governance-sized position on a
// real market and dumping it an hour later pays slippage twice plus an hour of
// price risk, so the true cost is a market round trip — not zero. What changed is
// that it is no longer an IRREVERSIBLE curve purchase burning GNOT at a rising
// price, which is what the old reasoning rested on.

// THE VECTOR, end to end, on the verdict lane. Asserts it SUCCEEDS.
func TestRentedWeightCanStillVoteADispute(cur realm, t *testing.T) {
	whale := testutils.TestAddress("rw-whale")
	author := testutils.TestAddress("rw-author")
	renter := testutils.TestAddress("rw-renter")
	c := testCourt(cur, "rntw1", author, 100_000_000_000)
	c.coin.Mint(whale, 400_000_000_000)

	id := stakeAnswerDispute(cur, "rntw1", author, whale)
	uassert.Equal(t, int64(0), c.coin.BalanceOf(renter))

	// Acquire, then wait exactly ONE epoch to seal. One epoch is all it takes.
	testing.SetRealm(testing.NewUserRealm(whale))
	TransferCC(cross(cur), "rntw1", renter, 300_000_000_000)
	testing.SkipHeights(epochBlocks * 2)
	touch(c)
	pinned := c.coin.PastVotes(renter, c.coin.Epoch()-1)
	uassert.Equal(t, int64(300_000_000_000), pinned)

	// Pin the anchor by opening the dispute yourself. THIS is the step that turns
	// a snapshot into a rental: without it the anchor would predate the purchase.
	testing.SetRealm(testing.NewUserRealm(renter))
	OpenDispute(cross(cur), "rntw1", id)
	cs := mustClaim(c, id)

	// Sell it all back. The pinned checkpoint is untouched.
	testing.SetRealm(testing.NewUserRealm(renter))
	TransferCC(cross(cur), "rntw1", whale, SpendableOf("rntw1", renter))
	uassert.Equal(t, int64(0), c.coin.VotesOf(renter))
	uassert.Equal(t, pinned, c.coin.PastVotes(renter, c.coin.Epoch()-1))

	// And the vote lands, with weight the voter does not hold.
	testing.SetRealm(testing.NewUserRealm(renter))
	VoteDispute(cross(cur), "rntw1", id, "yes")
	_, w, ok := c.gov.VoteOf(cs.proposalID, renter)
	uassert.True(t, ok)
	uassert.Equal(t, pinned, w)

	// The scale of it: the rented weight dwarfs the bar it had to clear.
	floor := quorumFloor(c, cs.xBarFrozen)
	uassert.True(t, floor > 0)
	uassert.True(t, w/floor >= 100) // measured at 600x on this fixture
}

// The election lane, which is the worse one: OpenElection pins the anchor and a
// coup is court-wide rather than one claim. Asserted on the weighting inputs,
// since driving a full election to installation is a different fixture.
func TestRentedWeightClearsTheElectionFloor(cur realm, t *testing.T) {
	whale := testutils.TestAddress("rw-whale5")
	renter := testutils.TestAddress("rw-renter5")
	c := testCourt(cur, "rntw5", whale, 500_000_000_000)

	testing.SetRealm(testing.NewUserRealm(whale))
	TransferCC(cross(cur), "rntw5", renter, 300_000_000_000)
	testing.SkipHeights(epochBlocks * 2)
	touch(c)
	at := c.coin.Epoch() - 1
	pinned := c.coin.PastVotes(renter, at)

	// The coup is in range: a one-epoch rental stands above the floor.
	uassert.True(t, pinned > electionFloor(c, at))
	uassert.True(t, pinned/electionFloor(c, at) >= 10) // measured at 12x

	// And selling back does not touch the pinned figure.
	testing.SetRealm(testing.NewUserRealm(renter))
	TransferCC(cross(cur), "rntw5", whale, SpendableOf("rntw5", renter))
	uassert.Equal(t, pinned, c.coin.PastVotes(renter, at))
	uassert.Equal(t, int64(0), c.coin.VotesOf(renter))
}

// The half that DOES work, and the reason snapshot weighting must stay: weight
// acquired after the anchor buys nothing. Any fix must preserve this — a live-only
// reading would trade this guarantee away and let weight borrowed inside the
// voting window decide the vote.
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
