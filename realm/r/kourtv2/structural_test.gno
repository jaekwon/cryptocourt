package kourtv2

import (
	"testing"

	grc20votes "gno.land/p/kourt/grc20votes/v0"
	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// Fixtures for the four structural fixes (S1-S4), which shipped WITHOUT them.
//
// This file is the debt in TODOs.md 0b being paid. Until it existed the four
// fixes rested on a suite that stayed green and four shadow-copy vets — weaker
// than the bond work beside them, which was mutation-verified in its final
// registered form.
//
// THREE TRAPS, each already paid for once and each avoided here on purpose:
//
//  1. `cs.tier == 0` IS AMBIGUOUS. It is 0 both BEFORE any terminal path runs
//     and AFTER a demotion, so a fixture built on the tier field proves nothing.
//     Everything below asserts on MONEY — DrawSlices, balances — never on tier.
//  2. NON-CLAMPING MUST BE A PRECONDITION. The draw is
//     min(tier x midGross, G_MAX, reservoir), and the comp drought can pay a
//     restored draw ZERO, so a fixture that only checks "not the capped figure"
//     passes against the wrong zero. drainUntilUnclamped below LOOPS on the
//     reservoir rather than skipping a guessed constant: the draw scales with
//     X-bar, so a fixed wait silently stops sufficing the moment anyone re-scales
//     a fixture.
//  3. THE SLICES FLOOR INDEPENDENTLY, so their sum sits up to two units under
//     the reserved pool. Every comparison here is slice against matching slice,
//     never sum against sum.
//
// MUTATION-VERIFIED IN FINAL REGISTERED FORM. Ten mutants, all killed, each with
// "0 build errors" — a mutant that fails to build is invalid, not a survivor:
//
//	S1  restore quorumFloor's supply arm ............ killed by the floor test
//	S1  credWeightFloor reads live supply ........... killed by the anchor test
//	S2  drop the failedRounds gate .................. killed by the bystander test
//	S2  drop the ladder floor entirely .............. killed at line 151, OpenDispute
//	S2  drop the mustSane ladder clause ............. killed by the bound test
//	S3  reinstate tierFinal = true .................. killed by both S3 tests
//	S3  provCloseClaim sets tierLowX ................ killed by both S3 tests
//	S3  restore Crystallize's provClose refusal ..... killed at line 321, Crystallize
//	S4  drop the demotion supply floor .............. killed by the floor test
//	S4  drop the demotion votable clamp ............. killed by the escrowed-court test
//
// The failedRounds-gate mutant is the one worth a note. In the full suite it dies
// on a hard panic in dispute_test.gno BEFORE reaching this file, so the suite
// result could not attribute it. Re-run against this fixture alone under a filter
// whose selection was verified non-vacuously, it fails on BOTH stamps — height
// 243484 vs 278045 and time 1235784695 vs 1235957500 — which is exactly what the
// fixture exists for, since flooring only the height arm leaves the bug fully live.

// drainUntilUnclamped advances until the court's reservoir covers `want`, so a
// draw of that size is not clamped by the junior reservation. Loops rather than
// skipping a constant, and fails loudly rather than silently under-waiting —
// a fixture that crystallizes into a dry reservoir asserts nothing.
func drainUntilUnclamped(cur realm, slug string, want int64) {
	for i := 0; i < 400; i++ {
		if Reservoir(slug) >= want {
			return
		}
		testing.SkipHeights(20_000)
		testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("st-poker")))
		Poke(cross(cur), slug)
	}
	panic("fixture is vacuous: the reservoir never covered the draw, so any " +
		"assertion about an unclamped draw would be testing the clamp")
}

// ----------------------------------------------------------------- S1 --------

// S1's floor, asserted by VALUE, on a claim where the deleted supply arm would
// have changed the answer.
//
// Prior work found ZERO fixtures reading quorumFloor anywhere in the suite, so
// the verdict lane's turnout bar had no shipped assertion of its value at all.
// The mutation this must catch is restoring the supply arm — max()ing against 5%
// of court SUPPLY when the prize a claim pays is denominated in that claim's own
// STAKE, which below X-bar = 5% of supply makes the bar unreachable by any
// turnout proportional to the claim, and an unreachable quorum is not "no
// verdict": the failed-quorum branch leaves provisional = answer, so
// non-satisfaction was a WIN for the answerer.
func TestS1TheQuorumFloorIsMinOfXBarAndAThirdOfVotable(cur realm, t *testing.T) {
	alice := testutils.TestAddress("s1-alice")
	c := testCourt(cur, "s1a", alice, 100_000_000_000)

	// Seal an epoch so PastTotal/PastVotes have something to read.
	testing.SkipHeights(c.coin.EpochBlocks() * 2)

	at := c.coin.Epoch() - 1
	supply := c.coin.PastTotal(at)
	votable := supply - c.coin.PastVotes(c.escrow, at)
	uassert.True(t, votable > 0)
	third := votable / 3
	fivePct := supply * quorumSupplyBps / 10000

	// THE ARM THAT MATTERS. A claim small against the court is the case the
	// deleted arm broke, so the fixture has to be in that regime or it proves
	// nothing about the deletion.
	small := third / 100
	if small < 1 || small >= fivePct {
		t.Fatal("fixture is vacuous: this X-bar is not in the regime where the " +
			"deleted supply arm would have bound")
	}
	uassert.Equal(t, small, quorumFloor(c, small))

	// The other arm: an X-bar larger than a third of the votable pool clamps to
	// the third. Without this the assertion above is satisfied by a function that
	// simply returns its argument.
	uassert.Equal(t, third, quorumFloor(c, third*2))

	// And the unit floor, which exists because governor.ProposeWithQuorum refuses
	// a non-positive floor and a fully-escrowed court has votable == 0.
	uassert.Equal(t, int64(1), quorumFloor(c, 0))
}

// S1's second half: the credential bar reads supply at the PROPOSAL's epoch, not
// at resolve.
//
// This is the regression my own first version of the fix introduced — reading at
// resolve is ~168 epochs late, which lets anyone mint mid-window to inflate the
// denominator and strip an honest winner's credit. The fixture pins the anchor by
// moving supply AFTER the snapshot and requiring the bar not to move.
func TestS1TheCredentialBarIsAnchoredAtTheProposalEpoch(cur realm, t *testing.T) {
	alice := testutils.TestAddress("s1-alice2")
	bob := testutils.TestAddress("s1-bob2")
	c := testCourt(cur, "s1b", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)

	id := stakeAnswerDispute(cur, "s1b", alice, bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "s1b", id)
	pid := mustClaim(c, id).proposalID

	before := credWeightFloor(c, pid)
	uassert.True(t, before > 0)

	// Mint a large amount mid-window and seal epochs over it. If the bar read
	// supply at resolve, this would raise it and could strip a winner's credit.
	c.coin.Mint(testutils.TestAddress("s1-whale"), 400_000_000_000)
	testing.SkipHeights(c.coin.EpochBlocks() * 3)

	uassert.Equal(t, before, credWeightFloor(c, pid))
}

// ----------------------------------------------------------------- S2 --------

// S2, the whole point of it: a DEFAULT court reaches provClose.
//
// The pre-existing TestDisputeFailedRoundsToProvClose reaches provClose only
// because it widens escrowMinBlocks to 450_000 by hand, with a comment saying
// small claims cap at failedRounds = 2 on real params. That hand-widening IS the
// bug S2 fixed, which is why the existing test could never have caught it — it
// configures the defect away before exercising the path.
func TestS2ADefaultCourtReachesProvClose(cur realm, t *testing.T) {
	alice := testutils.TestAddress("s2-alice")
	bob := testutils.TestAddress("s2-bob")
	c := testCourt(cur, "s2a", alice, 50_000_000_000)
	c.coin.Mint(bob, 20_000_000_000)

	// PRECONDITION, asserted rather than assumed: untouched default params. If a
	// future edit widens the defaults, this fixture stops testing the floor and
	// starts passing for the same reason the old one did.
	uassert.Equal(t, defaultParams().escrowMinBlocks, c.params.escrowMinBlocks)
	uassert.Equal(t, defaultParams().escrowMaxBlocks, c.params.escrowMaxBlocks)
	uassert.Equal(t, defaultParams().votingBlocks, c.params.votingBlocks)

	id := stakeAnswerDispute(cur, "s2a", alice, bob)
	for round := int64(1); round <= maxFailedRounds; round++ {
		testing.SetRealm(testing.NewUserRealm(bob))
		OpenDispute(cross(cur), "s2a", id)
		testing.SkipHeights(c.params.votingBlocks + 1) // nobody votes
		testing.SetRealm(testing.NewUserRealm(bob))
		ResolveDispute(cross(cur), "s2a", id)
		uassert.Equal(t, round, FailedRounds("s2a", id))
	}
	uassert.True(t, ProvClose("s2a", id))
	uassert.True(t, Settled("s2a", id))
}

// S2's bystander, which is the half that matters most: a DECIDED round must keep
// today's schedule bit-identically. Flooring unconditionally would tax an honest
// disputed claim from 14 to 21 days of frozen winning-side principal — the exact
// objection used to reject a longer settle window — and double the reopen grind.
//
// Asserted on both stamps. The gates read escrowUntilAt whenever it exists, so a
// fixture checking only the height arm would leave half the mutation live.
func TestS2ADecidedRoundKeepsTodaysWindow(cur realm, t *testing.T) {
	alice := testutils.TestAddress("s2-alice2")
	bob := testutils.TestAddress("s2-bob2")
	carol := testutils.TestAddress("s2-carol2")
	c := testCourt(cur, "s2b", alice, 50_000_000_000)
	c.coin.Mint(bob, 20_000_000_000)
	c.coin.Mint(carol, 30_000_000_000)

	id := stakeAnswerDispute(cur, "s2b", alice, bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "s2b", id)
	// Carol is a non-participant, so she may vote — participants are refused on
	// their own claim's verdict. "no" is a vote against overturning, i.e. an
	// uphold, and it is the choice that makes this a DECIDED round rather than a
	// failed one.
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "s2b", id, "no")
	testing.SkipHeights(c.params.votingBlocks + 1)
	at := heightNow()
	testing.SetRealm(testing.NewUserRealm(bob))
	ResolveDispute(cross(cur), "s2b", id)

	uassert.Equal(t, int64(0), FailedRounds("s2b", id))
	// The window is the plain escrow minimum, NOT the ladder floor — and the
	// ladder must actually be longer here, or the assertion is vacuous.
	uassert.True(t, ladderWindow(c.params) > c.params.escrowMinBlocks)
	uassert.Equal(t, at+c.params.escrowMinBlocks, EscrowUntil("s2b", id))
	cs := mustClaim(c, id)
	uassert.Equal(t, nowTime()+blocksToSecs(c.params.escrowMinBlocks), cs.escrowUntilAt)
}

// S2's guardrail: mustSane refuses a configuration whose ladder cannot fit in its
// own escrow window, which is the misconfiguration the fix exists to make
// impossible rather than merely unlikely.
//
// This replaces an invariant of mine that was VACUOUS — two independent vets
// found it, and a sweep of 1,845,616 parameter sets fired it only at
// maxFailedRounds = 0. Paired with the config one block wider, which must pass.
func TestS2TheLadderMustFitTheEscrowWindow(cur realm, t *testing.T) {
	p := defaultParams()
	uassert.True(t, ladderWindow(p) <= p.escrowMaxBlocks) // the shipped default

	tight := defaultParams()
	tight.escrowMaxBlocks = ladderWindow(tight)
	tight.mustSane() // exactly fits: must pass

	short := defaultParams()
	short.escrowMaxBlocks = ladderWindow(short) - 1
	short.escrowMinBlocks = short.escrowMaxBlocks
	uassert.PanicsContains(t, cur, "ladder", func() { short.mustSane() })
}

// ----------------------------------------------------------------- S3 --------

// S3: a provClosed claim DRAWS, and it draws bit-identically to the
// 2-failed-round Finalize path it was contradicting.
//
// Two claims run in lockstep in one court so midGross and openBlocks are equal
// by construction — conviction is frozen at the answer, so the extra dispute
// round afterwards cannot move it. They diverge only in how they end.
//
// The mutations this must catch: reinstating `tierFinal = true` in provCloseClaim
// (which makes its own guard SELF-BLOCKING, so the claim pays 0 forever — my own
// first spec had this), reinstating tierLowX (which is 0, so the whole draw
// vanishes), restoring Crystallize's provClose refusal, and restoring OpenFlag's
// provClose arm.
func TestS3ProvCloseDrawsLikeTheTwoFailedRoundFinalize(cur realm, t *testing.T) {
	alice := testutils.TestAddress("s3-alice")
	bob := testutils.TestAddress("s3-bob")
	c := testCourt(cur, "s3a", alice, 400_000_000_000)
	c.coin.Mint(bob, 100_000_000_000)

	// Opened, staked and answered at the same heights, so the two claims differ
	// in nothing the draw reads.
	testing.SetRealm(testing.NewUserRealm(alice))
	refID := OpenClaim(cross(cur), "s3a", "Reference: two failed rounds")
	testing.SetRealm(testing.NewUserRealm(alice))
	pcID := OpenClaim(cross(cur), "s3a", "Subject: three failed rounds")
	// INTERLEAVED, not one claim then the other. matureOI stakes three times with
	// an epoch between, so calling it per claim sequentially leaves the first
	// claim staked two epochs longer — measured, the reference came out with 1.8x
	// the X-bar and 3x the conviction, and the whole comparison was between two
	// different claims. Conviction is capital x TIME, so identical amounts on
	// different schedules are not identical inputs.
	for i := 0; i < 3; i++ {
		for _, id := range []uint64{refID, pcID} {
			testing.SetRealm(testing.NewUserRealm(alice))
			Stake(cross(cur), "s3a", id, sideYES, 200_000_000)
			testing.SetRealm(testing.NewUserRealm(bob))
			Stake(cross(cur), "s3a", id, sideNO, 300_000_000)
		}
		if i < 2 {
			testing.SkipHeights(epochBlocks)
		}
	}
	for _, id := range []uint64{refID, pcID} {
		testing.SetRealm(testing.NewUserRealm(alice))
		PostAnswer(cross(cur), "s3a", id, sideYES)
	}
	// THE PREMISE OF COMPARING THEM AT ALL, asserted on both inputs the draw
	// reads. Without this the test is an equality between two unrelated claims,
	// which is how the first version of it failed.
	uassert.Equal(t, XBarFrozen("s3a", refID), XBarFrozen("s3a", pcID))
	rcs, pcs := mustClaim(c, refID), mustClaim(c, pcID)
	uassert.Equal(t, convToCC(rcs.yesConvHi, rcs.yesConvLo),
		convToCC(pcs.yesConvHi, pcs.yesConvLo))
	uassert.Equal(t, rcs.answerBond0, pcs.answerBond0)

	// Two failed rounds each, in lockstep.
	for round := int64(1); round <= 2; round++ {
		for _, id := range []uint64{refID, pcID} {
			testing.SetRealm(testing.NewUserRealm(bob))
			OpenDispute(cross(cur), "s3a", id)
		}
		testing.SkipHeights(c.params.votingBlocks + 1)
		for _, id := range []uint64{refID, pcID} {
			testing.SetRealm(testing.NewUserRealm(bob))
			ResolveDispute(cross(cur), "s3a", id)
		}
	}
	uassert.Equal(t, int64(2), FailedRounds("s3a", refID))
	uassert.Equal(t, int64(2), FailedRounds("s3a", pcID))

	// Now they diverge, and THE ORDER MATTERS. The subject's third round has to
	// open while its escrow window is still live: skipping ahead to finalize the
	// reference first pushes BOTH claims past their windows, and OpenDispute then
	// refuses with "the escrow window has passed" — measured, not predicted.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "s3a", pcID)
	testing.SkipHeights(c.params.votingBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(bob))
	ResolveDispute(cross(cur), "s3a", pcID)
	uassert.True(t, ProvClose("s3a", pcID))

	// The reference wants the opposite — its window PASSED — so it finalizes
	// after, on a defaulted verdict rather than a provClose.
	if d := EscrowUntil("s3a", refID) - heightNow() + 1; d > 0 {
		testing.SkipHeights(d)
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "s3a", refID)
	uassert.False(t, ProvClose("s3a", refID))

	// NON-CLAMPING AS A PRECONDITION. Both draws must fit the reservoir or the
	// comparison is between two clamped figures, which would agree for the wrong
	// reason — the comp drought can pay a restored draw zero.
	want := mustMul(tierMidX, convToCC(mustClaim(c, pcID).yesConvHi, mustClaim(c, pcID).yesConvLo))
	uassert.True(t, want > 0)
	drainUntilUnclamped(cur, "s3a", mustMul(want, 3))

	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "s3a", refID)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "s3a", pcID)

	rw, ra, rn, rc := DrawSlices("s3a", refID)
	pw, pa, pn, pc2 := DrawSlices("s3a", pcID)

	// NOT ZERO first, so nothing below can agree by both being nothing. This is
	// the assertion that kills the tierLowX and tierFinal mutations.
	uassert.True(t, pw > 0)
	uassert.True(t, pa > 0)
	uassert.True(t, pn > 0)

	// SLICE AGAINST MATCHING SLICE, never sum against sum: the slices floor
	// independently, so their total sits up to two units under the reserved pool
	// and a sum comparison would hide a per-slice divergence of one unit.
	uassert.Equal(t, rw, pw)
	uassert.Equal(t, ra, pa)
	uassert.Equal(t, rn, pn)
	uassert.Equal(t, rc, pc2)
}

// S3's other half: the winners of a provClosed claim can actually COLLECT. A
// draw that crystallizes and then cannot be pulled is the same stranding in a
// different place, and DrawSlices alone would not notice.
func TestS3ProvCloseWinnersCanCollect(cur realm, t *testing.T) {
	alice := testutils.TestAddress("s3-alice2")
	bob := testutils.TestAddress("s3-bob2")
	c := testCourt(cur, "s3b", alice, 400_000_000_000)
	c.coin.Mint(bob, 100_000_000_000)

	id := stakeAnswerDispute(cur, "s3b", alice, bob)
	for round := int64(1); round <= maxFailedRounds; round++ {
		testing.SetRealm(testing.NewUserRealm(bob))
		OpenDispute(cross(cur), "s3b", id)
		testing.SkipHeights(c.params.votingBlocks + 1)
		testing.SetRealm(testing.NewUserRealm(bob))
		ResolveDispute(cross(cur), "s3b", id)
	}
	uassert.True(t, ProvClose("s3b", id))

	cs := mustClaim(c, id)
	want := mustMul(tierMidX, convToCC(cs.yesConvHi, cs.yesConvLo))
	drainUntilUnclamped(cur, "s3b", mustMul(want, 2))
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "s3b", id)

	before := c.coin.BalanceOf(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	paid := WithdrawBonus(cross(cur), "s3b", id, sideYES)
	uassert.True(t, paid > 0)
	uassert.Equal(t, before+paid, c.coin.BalanceOf(alice))

	// The author slice too — provClose refunds deposit AND fee, so the author
	// being paid here is the draw and not a refund.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.True(t, AuthorBonus(cross(cur), "s3b", id) > 0)
}

// ----------------------------------------------------------------- S4 --------

// S4: the demotion bar carries a supply floor and a votable clamp.
//
// Keyed to the claim alone the bar bottomed out at ~2.5 bps of court supply, and
// a demotion there is NET PROFITABLE — below the full bar ResolveFlag returns the
// flag bond whole and mints a bounty against the author's burned deposit, so
// zeroing a claim's entire draw cost nothing and paid. Voting consumes no weight,
// so one holder did it to several claims at once. Measured: 49 bps of supply
// zeroed a draw the same tally had just vindicated.
//
// Probed through the shipped qualityBars by moving cs.xBarFrozen, because the bar
// is a max-then-clamp and only the boundary cases distinguish it from either arm
// alone. Asserted by value, never on cs.tier — which is 0 both before any
// terminal path runs and after a demotion, and therefore proves nothing.
func TestS4TheDemotionBarHasASupplyFloor(cur realm, t *testing.T) {
	alice := testutils.TestAddress("s4-alice")
	bob := testutils.TestAddress("s4-bob")
	c := testCourt(cur, "s4a", alice, 200_000_000_000)
	c.coin.Mint(bob, 50_000_000_000)

	id := stakeAnswerDispute(cur, "s4a", alice, bob)
	cs := mustClaim(c, id)

	supply := c.coin.PastTotal(cs.qualityEpoch)
	votable := supply - c.coin.PastVotes(c.escrow, cs.qualityEpoch)
	quarter := mulDiv128(supply, quorumSupplyBps, 10000) / 4
	third := votable / 3
	uassert.True(t, quarter > 0)

	// REGIME 1 — a claim small against the court. Unfloored this is xBar/4, which
	// is the ~2.5 bps that made a free demotion profitable; the floor lifts it to
	// 1.25% of supply.
	cs.xBarFrozen = quarter // so arm/4 is a quarter of that, well under the floor
	got, _ := qualityBars(c, cs)
	uassert.Equal(t, quarter, got)

	// REGIME 2 — a claim large enough that its own quarter clears the floor. The
	// pairing that matters: without it, regime 1 is satisfied by a bar that
	// ignores the claim entirely and always returns 1.25% of supply.
	big := quarter * 8
	if big/4 <= quarter || big > third {
		t.Fatal("fixture is vacuous: no X-bar leaves the claim's own arm above " +
			"the supply floor and below the votable clamp, so the middle regime " +
			"is untested")
	}
	cs.xBarFrozen = big
	got, _ = qualityBars(c, cs)
	uassert.Equal(t, big/4, got)

	// The ordering the pair has always had is preserved: demotion is a quarter of
	// the full bar's arm, so the full bar is never below it.
	_, full := qualityBars(c, cs)
	uassert.True(t, full >= got)
}

// S4's reachability clamp, which is the arm that keeps a mostly-escrowed court
// demotable at all.
//
// It can ONLY be reached through the supply floor: `arm` is already clamped to
// votable/3 before being divided by 4, so the claim's own contribution can never
// exceed the clamp — measured, not assumed, which is why the fixture has to move
// 97% of the float into the escrow to reach it. A bar above a third of the
// votable float cannot be cleared by any set of votes, and raising an unreachable
// bar makes the lane more dead rather than safer.
func TestS4TheDemotionBarStaysReachableOnAnEscrowedCourt(cur realm, t *testing.T) {
	alice := testutils.TestAddress("s4-alice2")
	bob := testutils.TestAddress("s4-bob2")
	c := testCourt(cur, "s4b", alice, 200_000_000_000)
	c.coin.Mint(bob, 50_000_000_000)

	id := stakeAnswerDispute(cur, "s4b", alice, bob)
	cs := mustClaim(c, id)

	// Starve the votable float, which the escrow's votes are excluded from by
	// construction — so this is the shape a heavily-bonded court has. It takes
	// MORE than it looks: the clamp binds only when votable falls under 3.75% of
	// supply (1.25% of supply exceeding votable/3), so moving 97% of one holder's
	// balance is not enough and the first version of this fixture failed its own
	// vacuity check saying exactly that. Both holders, down to a sliver.
	//
	// Raw ledger transfers, deliberately: they bypass spendable(), which is the
	// point — this is an in-package fixture arranging a balance sheet, not a user
	// action, and routing it through TransferCC would be refused for the staked
	// portion.
	for _, who := range []address{alice, bob} {
		if b := c.coin.BalanceOf(who); b > 0 {
			c.coin.Transfer(who, c.escrow, b*99/100)
		}
	}
	testing.SkipHeights(c.coin.EpochBlocks() * 3)
	cs.qualityEpoch = c.coin.Epoch() - 1

	supply := c.coin.PastTotal(cs.qualityEpoch)
	votable := supply - c.coin.PastVotes(c.escrow, cs.qualityEpoch)
	quarter := mulDiv128(supply, quorumSupplyBps, 10000) / 4
	third := votable / 3
	if quarter <= third {
		t.Fatal("fixture is vacuous: the supply floor does not exceed a third of " +
			"the votable float, so the reachability clamp cannot bind")
	}

	cs.xBarFrozen = supply // as large as it can be; the clamp must still bind
	got, _ := qualityBars(c, cs)
	uassert.Equal(t, third, got)
	uassert.True(t, got < quarter) // the clamp really did cut the floor
}

// THE BARS AT THEIR EXACT VALUES. An operator sweep of the lane bars turned three
// exact-threshold cases into survivors: turnout exactly at the quality full bar, turnout
// exactly at the dispute quorum floor, and a split exactly at the overturn threshold.
// Each is a one-character change with a different outcome and money moving the other way,
// and nothing noticed. The quality lane even has a test called
// TestApplyQualityTallyOnEveryBoundary, which catches three of its four boundaries.
//
// A voter's weight is min(snapshot, balance), so any exact figure can be hit by holding a
// large snapshot and then transferring the excess away: the snapshot stays, the balance
// becomes the target, and user-to-user transfers leave supply and votable untouched.

// EXACTLY AT THE QUORUM FLOOR IS QUORUM MET, not apathy. `cast < floor` is the failed
// branch; at cast == floor the round must be DECIDED. Getting this wrong half-burns the
// disputer's bond, defaults the verdict to the answer and discards a turnout that did
// clear the bar — on the most contested rounds, which are the ones that land near it.
func TestATurnoutExactlyAtTheQuorumFloorIsNotApathy(cur realm, t *testing.T) {
	author := testutils.TestAddress("bq-author")
	staker := testutils.TestAddress("bq-staker")
	voter := testutils.TestAddress("bq-voter")
	sink := testutils.TestAddress("bq-sink")
	c := testCourt(cur, "bq", author, 40_000_000_000)
	c.coin.Mint(staker, 10_000_000_000)
	c.coin.Mint(voter, 20_000_000_000)

	id := stakeAnswerDispute(cur, "bq", author, staker)
	testing.SkipHeights(epochBlocks * 2)
	touch(c)
	testing.SetRealm(testing.NewUserRealm(staker))
	OpenDispute(cross(cur), "bq", id)
	cs := mustClaim(c, id)

	floor := c.gov.QuorumFloor(cs.proposalID)
	snap := c.coin.PastVotes(voter, c.gov.EpochOf(cs.proposalID))
	if floor <= 0 || snap < floor {
		t.Fatalf("fixture: floor %d is not reachable from a snapshot of %d",
			floor, snap)
	}
	// Hold EXACTLY the floor, so weight == min(snapshot, balance) == floor.
	testing.SetRealm(testing.NewUserRealm(voter))
	TransferCC(cross(cur), "bq", sink, c.coin.BalanceOf(voter)-floor)
	uassert.Equal(t, floor, c.coin.BalanceOf(voter))

	testing.SetRealm(testing.NewUserRealm(voter))
	VoteDispute(cross(cur), "bq", id, "no")
	yes, no, ab, _ := c.gov.Tally(cs.proposalID)
	if cast := yes + no + ab; cast != floor {
		t.Fatalf("fixture is vacuous: cast %d is not exactly the floor %d, so this "+
			"is not the boundary case", cast, floor)
	}

	testing.SkipHeights(c.params.votingBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(staker))
	ResolveDispute(cross(cur), "bq", id)

	// Quorum was met, so this is a DECIDED round and not a failed one.
	if cs.failedRounds != 0 {
		t.Fatalf("turnout of exactly the floor %d was treated as apathy: "+
			"failedRounds is %d", floor, cs.failedRounds)
	}
}

// EXACTLY AT THE OVERTURN THRESHOLD OVERTURNS. disputeThresholdBps is 5001, documented as
// "> 5000 so a tie never overturns", so the exact case is yes:no = 5001:4999 —
// yes*10000 == (yes+no)*5001. One character makes that an UPHOLD instead, which burns the
// disputer's bond rather than the answerer's.
func TestASplitExactlyAtTheOverturnThresholdOverturns(cur realm, t *testing.T) {
	author := testutils.TestAddress("bo-author")
	staker := testutils.TestAddress("bo-staker")
	yesV := testutils.TestAddress("bo-yes")
	noV := testutils.TestAddress("bo-no")
	sink := testutils.TestAddress("bo-sink")
	c := testCourt(cur, "bo", author, 40_000_000_000)
	c.coin.Mint(staker, 10_000_000_000)
	c.coin.Mint(yesV, 20_000_000_000)
	c.coin.Mint(noV, 20_000_000_000)

	id := stakeAnswerDispute(cur, "bo", author, staker)
	testing.SkipHeights(epochBlocks * 2)
	touch(c)
	testing.SetRealm(testing.NewUserRealm(staker))
	OpenDispute(cross(cur), "bo", id)
	cs := mustClaim(c, id)
	answer := cs.answer

	// Scale the 5001:4999 pair up until it clears the quorum floor.
	floor := c.gov.QuorumFloor(cs.proposalID)
	scale := floor/10000 + 1
	wantYes, wantNo := 5001*scale, 4999*scale
	if wantYes+wantNo < floor {
		t.Fatalf("fixture: %d+%d does not clear the floor %d", wantYes, wantNo, floor)
	}
	for who, want := range map[address]int64{yesV: wantYes, noV: wantNo} {
		if c.coin.PastVotes(who, c.gov.EpochOf(cs.proposalID)) < want {
			t.Fatalf("fixture: %s cannot reach %d", who, want)
		}
		testing.SetRealm(testing.NewUserRealm(who))
		TransferCC(cross(cur), "bo", sink, c.coin.BalanceOf(who)-want)
	}
	testing.SetRealm(testing.NewUserRealm(yesV))
	VoteDispute(cross(cur), "bo", id, "yes")
	testing.SetRealm(testing.NewUserRealm(noV))
	VoteDispute(cross(cur), "bo", id, "no")

	yes, no, _, _ := c.gov.Tally(cs.proposalID)
	if yes*grc20votes.Bps != (yes+no)*c.params.disputeThresholdBps {
		t.Fatalf("fixture is vacuous: %d*%d != (%d+%d)*%d, so this is not the "+
			"exact threshold", yes, grc20votes.Bps, yes, no,
			c.params.disputeThresholdBps)
	}

	testing.SkipHeights(c.params.votingBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(staker))
	ResolveDispute(cross(cur), "bo", id)

	if cs.decidedRounds != 1 {
		t.Fatalf("a split exactly at the threshold did not decide: decidedRounds %d",
			cs.decidedRounds)
	}
	if cs.provisional != int8(oppositeSide(int(answer))) {
		t.Fatalf("a split exactly at the threshold did not OVERTURN: provisional "+
			"%d, answer %d", cs.provisional, answer)
	}
}

// EXACTLY AT THE QUALITY FULL BAR CLEARS IT. `turnout >= fullBar` is the gate on every
// conclusive quality outcome, and the exact case was the one boundary
// TestApplyQualityTallyOnEveryBoundary does not reach — it covers the two-thirds high
// split, the median-low half and the demotion bar, and not this.
func TestATurnoutExactlyAtTheQualityFullBarClearsIt(cur realm, t *testing.T) {
	author := testutils.TestAddress("bf-author")
	flagger := testutils.TestAddress("bf-flagger")
	voter := testutils.TestAddress("bf-voter")
	sink := testutils.TestAddress("bf-sink")
	c := testCourt(cur, "bf", author, 30_000_000_000)
	c.coin.Mint(flagger, 5_000_000_000)
	c.coin.Mint(voter, 25_000_000_000)

	testing.SetRealm(testing.NewUserRealm(author))
	id := OpenClaim(cross(cur), "bf", "Exactly at the full bar")
	matureOI(cur, "bf", id, author, 2_000_000_000)
	testing.SetRealm(testing.NewUserRealm(author))
	PostAnswer(cross(cur), "bf", id, sideYES)
	cs := mustClaim(c, id)

	testing.SetRealm(testing.NewUserRealm(flagger))
	OpenFlag(cross(cur), "bf", id)
	_, fullBar := qualityBars(c, cs)
	snap := c.coin.PastVotes(voter, cs.qualityEpoch)
	if fullBar <= 0 || snap < fullBar {
		t.Fatalf("fixture: full bar %d unreachable from a snapshot of %d",
			fullBar, snap)
	}
	// Hold EXACTLY the bar.
	testing.SetRealm(testing.NewUserRealm(voter))
	TransferCC(cross(cur), "bf", sink, c.coin.BalanceOf(voter)-fullBar)
	testing.SetRealm(testing.NewUserRealm(voter))
	VoteQuality(cross(cur), "bf", id, qualityHigh)

	turnout := cs.qLowW + cs.qMidW + cs.qHighW
	if turnout != fullBar {
		t.Fatalf("fixture is vacuous: turnout %d is not exactly the full bar %d",
			turnout, fullBar)
	}

	testing.SkipHeights(c.params.votingBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(flagger))
	ResolveFlag(cross(cur), "bf", id)

	if !cs.slotConsumed {
		t.Fatalf("turnout of exactly the full bar %d was treated as inconclusive",
			fullBar)
	}
	uassert.Equal(t, int64(qualityHigh), cs.tier)
}

// THE BARS NEVER REACH ZERO, AND A ZERO BAR IS NOT A SMALL BAR.
//
// An operator sweep of the bar DERIVATIONS — as opposed to the comparisons against them,
// which the previous commit pinned — left four survivors, all of them the minimum clamps:
// the demotion bar's, the full bar's, the ladder's (full below demotion), and
// supplyFloor's. Only quorumFloor's was pinned.
//
// They bind on a MICRO COURT, which is not hypothetical: StartCourt is free and a fresh
// court's supply is whatever has been bought so far, and the realm already reasons about
// "a court with less than 20 CC votable" elsewhere. At votable = 2 the third-of-votable
// arm is 0, so every bar derives to zero and only the clamps lift them.
//
// A zero full bar is not a lenient bar, it is a broken one. The conclusive test is
// `turnout >= fullBar && cs.qHighW*3 >= turnout*2`, which at fullBar = 0 and an EMPTY
// tally reads 0 >= 0 && 0 >= 0 — so a flag nobody voted in would consume the slot and
// promote the claim to HIGH. That is the same empty-denominator failure the governor's
// `p.yes > 0` arm exists to stop, in another lane; there it was found by review and
// commented, here it was standing on an unpinned clamp.
func TestTheQualityBarsNeverReachZeroOnAMicroCourt(cur realm, t *testing.T) {
	alice := testutils.TestAddress("mb-alice")
	c := testCourt(cur, "mb", alice, 2) // two units, the whole court
	testing.SkipHeights(epochBlocks * 2)
	touch(c)
	at := c.coin.Epoch() - 1

	// THE PRECONDITION: the clamps must actually be what lifts these bars, or the
	// test passes on arithmetic that never needed them.
	votable := c.coin.PastTotal(at) - c.coin.PastVotes(c.escrow, at)
	if votable/3 != 0 {
		t.Fatalf("fixture is vacuous: a third of votable is %d, so the bars do not "+
			"derive to zero and the clamps are not being tested", votable/3)
	}
	cs := &claimState{qualityEpoch: at, xBarFrozen: 1}
	demotionBar, fullBar := qualityBars(c, cs)
	if demotionBar < 1 {
		t.Fatalf("the demotion bar is %d; nothing can be below a bar of zero",
			demotionBar)
	}
	if fullBar < 1 {
		t.Fatalf("the full bar is %d; an EMPTY tally clears a bar of zero", fullBar)
	}
	if fullBar < demotionBar {
		t.Fatalf("the ladder is inverted: full %d below demotion %d",
			fullBar, demotionBar)
	}

	// And the outcome that depends on it: an empty tally decides nothing.
	tier, conclusive, turnout := applyQualityTally(c, cs)
	uassert.Equal(t, int64(0), turnout)
	if conclusive {
		t.Fatalf("an empty tally was conclusive at tier %d — zero turnout just "+
			"promoted a claim", tier)
	}
}

// supplyFloor is the same clamp one layer down, and it feeds the deposit and answer bars
// rather than the quality ladder. A zero floor means a free claim on a young court.
func TestTheSupplyFloorNeverReachesZero(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ms-alice")
	c := testCourt(cur, "ms", alice, 2)
	testing.SkipHeights(epochBlocks * 2)
	touch(c)

	// Zero bps and zero dust is the shape that derives to nothing: without the clamp
	// this returns 0, which is why the clamp is the only thing holding the bar up.
	if got := supplyFloor(c, 0, 0); got < 1 {
		t.Fatalf("supplyFloor(0 bps, 0 dust) is %d, so a bar derived from it is "+
			"zero and anything clears it", got)
	}
	// The bystander: an ordinary derivation is NOT forced to the clamp, or this would
	// be a constant rather than a floor.
	if got := supplyFloor(c, 5000, 1_000_000); got != 1_000_000 {
		t.Fatalf("supplyFloor should return the dust arm %d on a tiny court, got %d",
			1_000_000, got)
	}
}
