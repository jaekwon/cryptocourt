package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// electionCourt mints to holders and seals an epoch, so PastVotes at the
// election's pinned epoch reflects the balances.
func electionCourt(cur realm, slug string, creator address, holders []address, amts []int64) *Court {
	testing.SetRealm(testing.NewUserRealm(creator))
	StartCourt(cross(cur), slug, "Election Court "+slug)
	c := mustCourt(slug)
	for i, h := range holders {
		c.coin.Mint(h, amts[i])
	}
	testing.SkipHeights(epochBlocks * 2) // seal the epoch that holds these balances
	return c
}

// THE round-6 F1 fixture: an honest 69% majority unseats a captured 31%
// minority. Under the rejected design (an absolute bps gate with retain as a
// silent zero-approval default) the 31% would have HELD, because abstention
// counted for the incumbent. With retain as a real approvable line judged by
// most-approvals-over-retain, the majority wins mechanically.
func TestElectionHonestMajorityUnseatsCapturedMinority(cur realm, t *testing.T) {
	creator := testutils.TestAddress("ev1-creator")
	honest := testutils.TestAddress("ev1-honest")
	captured := testutils.TestAddress("ev1-captured")
	newMod := testutils.TestAddress("ev1-newmod")
	c := electionCourt(cur, "ev1", creator,
		[]address{honest, captured}, []int64{690_000_000, 310_000_000})
	c.coin.Mint(honest, 50_000_000) // bond money

	testing.SetRealm(testing.NewUserRealm(honest))
	cand := RegisterModCandidate(cross(cur), "ev1", []address{newMod}, 1)
	testing.SetRealm(testing.NewUserRealm(honest))
	OpenElection(cross(cur), "ev1", cand)

	nomEnd, _ := ElectionWindows("ev1")
	_ = nomEnd
	testing.SkipHeights(nominationWindow) // voting opens

	testing.SetRealm(testing.NewUserRealm(honest))
	ApproveCandidate(cross(cur), "ev1", cand)
	testing.SetRealm(testing.NewUserRealm(captured))
	ApproveRetain(cross(cur), "ev1")

	testing.SkipHeights(c.params.votingBlocks)
	testing.SetRealm(testing.NewUserRealm(honest))
	ResolveElection(cross(cur), "ev1")

	if !IsCourtMod("ev1", newMod) {
		t.Fatal("the 69% majority's candidate must install")
	}
	if IsCourtMod("ev1", creator) {
		t.Fatal("the old set must be replaced")
	}
	// The creator's appointment power is spent once an election installs.
	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsContains(t, cur, "appointment power is spent", func() {
		AppointMods(cross(cur), "ev1", []address{creator}, 1)
	})
}

// Turnout below the quorum floor retains the current set (fail-safe on
// indecision — don't unseat moderators without a mandate).
func TestElectionBelowQuorumRetains(cur realm, t *testing.T) {
	creator := testutils.TestAddress("ev2-creator")
	whale := testutils.TestAddress("ev2-whale")
	dust := testutils.TestAddress("ev2-dust")
	newMod := testutils.TestAddress("ev2-newmod")
	c := electionCourt(cur, "ev2", creator,
		[]address{whale, dust}, []int64{1_000_000_000, 10_000_000})
	c.coin.Mint(dust, 50_000_000)

	testing.SetRealm(testing.NewUserRealm(dust))
	cand := RegisterModCandidate(cross(cur), "ev2", []address{newMod}, 1)
	testing.SetRealm(testing.NewUserRealm(dust))
	OpenElection(cross(cur), "ev2", cand)
	testing.SkipHeights(nominationWindow)

	// Only the dust holder votes: turnout 10 CC against a ~50 CC floor.
	testing.SetRealm(testing.NewUserRealm(dust))
	ApproveCandidate(cross(cur), "ev2", cand)
	testing.SkipHeights(c.params.votingBlocks)
	testing.SetRealm(testing.NewUserRealm(dust))
	ResolveElection(cross(cur), "ev2")

	if IsCourtMod("ev2", newMod) {
		t.Fatal("a sub-quorum turnout must not install")
	}
	if !IsCourtMod("ev2", creator) {
		t.Fatal("the current set is retained")
	}
	if ElectionCooldownUntil("ev2") == 0 {
		t.Fatal("a fully-failed election starts the court's cooldown")
	}
	// The cooldown blocks an immediate re-open.
	testing.SetRealm(testing.NewUserRealm(dust))
	uassert.AbortsContains(t, cur, "cooldown", func() {
		OpenElection(cross(cur), "ev2", cand)
	})
}

// The anti-decoy rule: a later-nominated near-duplicate that edges ahead by
// less than the margin does NOT displace the original — earliest nomination
// wins inside the margin.
func TestElectionDecoyLosesToEarliestNomination(cur realm, t *testing.T) {
	creator := testutils.TestAddress("ev3-creator")
	big := testutils.TestAddress("ev3-big")
	small := testutils.TestAddress("ev3-small")
	honestMod := testutils.TestAddress("ev3-honest")
	puppet := testutils.TestAddress("ev3-puppet")
	c := electionCourt(cur, "ev3", creator,
		[]address{big, small}, []int64{400_000_000, 20_000_000})
	c.coin.Mint(big, 50_000_000)
	c.coin.Mint(small, 50_000_000)

	// The honest set, nominated FIRST; then a decoy that swaps in a puppet.
	testing.SetRealm(testing.NewUserRealm(big))
	orig := RegisterModCandidate(cross(cur), "ev3", []address{honestMod}, 1)
	testing.SetRealm(testing.NewUserRealm(small))
	decoy := RegisterModCandidate(cross(cur), "ev3", []address{puppet}, 1)

	testing.SetRealm(testing.NewUserRealm(big))
	OpenElection(cross(cur), "ev3", orig)
	testing.SkipHeights(10)
	testing.SetRealm(testing.NewUserRealm(small))
	NominateCandidate(cross(cur), "ev3", decoy)
	testing.SkipHeights(nominationWindow)

	// The big holder approves both (they cannot tell them apart); the decoy's
	// backer tops it up — decoy leads, but by less than the margin.
	testing.SetRealm(testing.NewUserRealm(big))
	ApproveCandidate(cross(cur), "ev3", orig)
	testing.SetRealm(testing.NewUserRealm(big))
	ApproveCandidate(cross(cur), "ev3", decoy)
	testing.SetRealm(testing.NewUserRealm(small))
	ApproveCandidate(cross(cur), "ev3", decoy)

	testing.SkipHeights(c.params.votingBlocks)
	testing.SetRealm(testing.NewUserRealm(big))
	ResolveElection(cross(cur), "ev3")

	if !IsCourtMod("ev3", honestMod) {
		t.Fatal("the earliest-nominated set inside the margin must win")
	}
	if IsCourtMod("ev3", puppet) {
		t.Fatal("a late decoy must not install off a within-margin lead")
	}
}

// Bonds ADD candidates and never exclude one; the bond refunds only on install
// and half-burns otherwise (so self-approved junk always costs).
func TestElectionBondsAddAndRefundOnlyOnInstall(cur realm, t *testing.T) {
	creator := testutils.TestAddress("ev4-creator")
	voter := testutils.TestAddress("ev4-voter")
	loserPoster := testutils.TestAddress("ev4-loser")
	winMod := testutils.TestAddress("ev4-win")
	loseMod := testutils.TestAddress("ev4-lose")
	c := electionCourt(cur, "ev4", creator,
		[]address{voter, loserPoster}, []int64{800_000_000, 100_000_000})

	testing.SetRealm(testing.NewUserRealm(voter))
	winner := RegisterModCandidate(cross(cur), "ev4", []address{winMod}, 1)
	testing.SetRealm(testing.NewUserRealm(loserPoster))
	loser := RegisterModCandidate(cross(cur), "ev4", []address{loseMod}, 1)

	testing.SetRealm(testing.NewUserRealm(voter))
	OpenElection(cross(cur), "ev4", winner)
	bond := ElectionBondOf("ev4")
	// A second poster ADDS a line — no cap, no exclusion.
	loserBefore := c.coin.BalanceOf(loserPoster)
	testing.SetRealm(testing.NewUserRealm(loserPoster))
	NominateCandidate(cross(cur), "ev4", loser)
	if c.coin.BalanceOf(loserPoster) != loserBefore-bond {
		t.Fatal("nominating posts the bond")
	}

	testing.SkipHeights(nominationWindow)
	winBefore := c.coin.BalanceOf(voter)
	testing.SetRealm(testing.NewUserRealm(voter))
	ApproveCandidate(cross(cur), "ev4", winner)
	testing.SetRealm(testing.NewUserRealm(loserPoster))
	ApproveCandidate(cross(cur), "ev4", loser) // self-approval by a real holder

	testing.SkipHeights(c.params.votingBlocks)
	testing.SetRealm(testing.NewUserRealm(voter))
	ResolveElection(cross(cur), "ev4")

	if !IsCourtMod("ev4", winMod) {
		t.Fatal("the most-approved set should install")
	}
	if c.coin.BalanceOf(voter) != winBefore+bond {
		t.Fatal("the installed candidate's bond must refund in full")
	}
	// The loser gets half back; the other half burned.
	if got := c.coin.BalanceOf(loserPoster); got != loserBefore-bond+bond/2 {
		t.Fatalf("a non-installed bond must half-burn: got %d", got)
	}
}

// One nomination per address, and the ballot is closed to late nominations.
func TestElectionNominationGuards(cur realm, t *testing.T) {
	creator := testutils.TestAddress("ev5-creator")
	voter := testutils.TestAddress("ev5-voter")
	m1 := testutils.TestAddress("ev5-m1")
	m2 := testutils.TestAddress("ev5-m2")
	c := electionCourt(cur, "ev5", creator, []address{voter}, []int64{900_000_000})

	testing.SetRealm(testing.NewUserRealm(voter))
	a := RegisterModCandidate(cross(cur), "ev5", []address{m1}, 1)
	testing.SetRealm(testing.NewUserRealm(voter))
	b := RegisterModCandidate(cross(cur), "ev5", []address{m2}, 1)
	testing.SetRealm(testing.NewUserRealm(voter))
	OpenElection(cross(cur), "ev5", a)

	// The same address cannot nominate twice.
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "one nomination per address", func() {
		NominateCandidate(cross(cur), "ev5", b)
	})
	// Voting is closed until the nomination window ends.
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "voting opens", func() {
		ApproveCandidate(cross(cur), "ev5", a)
	})
	// After the window, nominations are closed.
	testing.SkipHeights(nominationWindow)
	other := testutils.TestAddress("ev5-other")
	c.coin.Mint(other, 50_000_000)
	testing.SetRealm(testing.NewUserRealm(other))
	uassert.AbortsContains(t, cur, "nomination window has closed", func() {
		NominateCandidate(cross(cur), "ev5", b)
	})
	// A voter may not approve the same line twice.
	testing.SetRealm(testing.NewUserRealm(voter))
	ApproveCandidate(cross(cur), "ev5", a)
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "already approved", func() {
		ApproveCandidate(cross(cur), "ev5", a)
	})
}

// Approving several lines counts the voter's weight ONCE toward turnout
// (distinct-voter weight, not the sum of approvals).
func TestElectionTurnoutIsDistinctVoters(cur realm, t *testing.T) {
	creator := testutils.TestAddress("ev6-creator")
	voter := testutils.TestAddress("ev6-voter")
	m1 := testutils.TestAddress("ev6-m1")
	m2 := testutils.TestAddress("ev6-m2")
	c := electionCourt(cur, "ev6", creator, []address{voter}, []int64{900_000_000})
	other := testutils.TestAddress("ev6-other")
	c.coin.Mint(other, 60_000_000)

	testing.SetRealm(testing.NewUserRealm(voter))
	a := RegisterModCandidate(cross(cur), "ev6", []address{m1}, 1)
	testing.SetRealm(testing.NewUserRealm(voter))
	b := RegisterModCandidate(cross(cur), "ev6", []address{m2}, 1)
	testing.SetRealm(testing.NewUserRealm(voter))
	OpenElection(cross(cur), "ev6", a)
	testing.SetRealm(testing.NewUserRealm(other))
	NominateCandidate(cross(cur), "ev6", b)
	testing.SkipHeights(nominationWindow)

	testing.SetRealm(testing.NewUserRealm(voter))
	ApproveCandidate(cross(cur), "ev6", a)
	testing.SetRealm(testing.NewUserRealm(voter))
	ApproveCandidate(cross(cur), "ev6", b)
	testing.SetRealm(testing.NewUserRealm(voter))
	ApproveRetain(cross(cur), "ev6")

	wA, retainW, turnout := ElectionTally("ev6", a)
	if wA != 900_000_000 || retainW != 900_000_000 {
		t.Fatalf("each approved line carries the voter's full weight: %d / %d", wA, retainW)
	}
	if turnout != 900_000_000 {
		t.Fatalf("turnout counts the voter ONCE, got %d", turnout)
	}
}

// A candidate the electorate did NOT approve must never install, even when it is
// the earliest-nominated line inside the margin band. The band is
// `weight >= maxW - floor`, so whenever the winning approval sits near the floor
// the band reaches down to zero — and the election opener is always the earliest
// line, so a griefer's puppet would beat a genuinely-approved challenger for
// free, permanently unseating the creator and gaining the seeding privilege.
func TestElectionZeroApprovalCandidateCannotInstall(cur realm, t *testing.T) {
	creator := testutils.TestAddress("ev7-creator")
	whale := testutils.TestAddress("ev7-whale")   // never votes
	small := testutils.TestAddress("ev7-small")   // the only approver
	griefer := testutils.TestAddress("ev7-grief") // opens with a puppet set
	honestMod := testutils.TestAddress("ev7-honest")
	puppet := testutils.TestAddress("ev7-puppet")
	c := electionCourt(cur, "ev7", creator,
		[]address{whale, small, griefer},
		[]int64{900_000_000, 50_000_000, 50_000_000})
	_ = c

	testing.SetRealm(testing.NewUserRealm(griefer))
	puppetSet := RegisterModCandidate(cross(cur), "ev7", []address{puppet}, 1)
	testing.SetRealm(testing.NewUserRealm(small))
	honestSet := RegisterModCandidate(cross(cur), "ev7", []address{honestMod}, 1)

	// The griefer opens, so their puppet is the EARLIEST line on the ballot.
	testing.SetRealm(testing.NewUserRealm(griefer))
	OpenElection(cross(cur), "ev7", puppetSet)
	testing.SkipHeights(10)
	testing.SetRealm(testing.NewUserRealm(small))
	NominateCandidate(cross(cur), "ev7", honestSet)
	testing.SkipHeights(nominationWindow)

	// Only the honest set is approved; the puppet gets nothing.
	testing.SetRealm(testing.NewUserRealm(small))
	ApproveCandidate(cross(cur), "ev7", honestSet)

	testing.SkipHeights(c.params.votingBlocks)
	testing.SetRealm(testing.NewUserRealm(small))
	ResolveElection(cross(cur), "ev7")

	if IsCourtMod("ev7", puppet) {
		t.Fatal("a candidate with ZERO approvals must never install")
	}
	if !IsCourtMod("ev7", honestMod) {
		t.Fatal("the approved candidate should install")
	}
}

// The deploy gate on β is a RATIO check, and a ratio check is blind to two
// runtime terms that can each invert the very thing it certifies: "affording
// the ballot is never harder than winning the vote". Both are checked here.
func TestElectionBondNeverExceedsTheFloor(cur realm, t *testing.T) {
	// ARM 1 — the absolute floor. A court with 10 CC votable has a 0.5 CC
	// election floor, but flagMinCC pins the bond at 1 CC: without the clamp
	// the ballot costs twice what winning the vote does, and the electorate's
	// own remedy is priced out of reach on precisely the youngest courts.
	creator := testutils.TestAddress("eb1-creator")
	holder := testutils.TestAddress("eb1-holder")
	_ = electionCourt(cur, "ebond1", creator, []address{holder}, []int64{10_000_000})

	cand1 := testutils.TestAddress("eb1-cand")
	testing.SetRealm(testing.NewUserRealm(holder))
	id1 := RegisterModCandidate(cross(cur), "ebond1", []address{cand1}, 1)
	testing.SetRealm(testing.NewUserRealm(holder))
	OpenElection(cross(cur), "ebond1", id1)

	floor1, bond1 := ElectionFloorOf("ebond1"), ElectionBondOf("ebond1")
	uassert.Equal(t, int64(500_000), floor1, "a twentieth of 10 CC votable")
	if bond1 > floor1 {
		t.Fatalf("the absolute flagMinCC arm escaped the clamp: bond %d > floor %d", bond1, floor1)
	}
	uassert.Equal(t, floor1, bond1, "on a small court the floor is the binding term")

	// ARM 2 — the base mismatch. 99% of supply sits in escrow as stake and
	// bonds, which is ordinary for a mature court. Quoted on RAW supply the
	// bond here would be 500 CC against a 50 CC floor: a tenfold inversion
	// produced by nothing but the two terms disagreeing about a denominator.
	// The sizes are deliberately well above flagMinCC so this arm tests the
	// base and not the clamp.
	creator2 := testutils.TestAddress("eb2-creator")
	holder2 := testutils.TestAddress("eb2-holder")
	testing.SetRealm(testing.NewUserRealm(creator2))
	StartCourt(cross(cur), "ebond2", "Escrow Heavy")
	c2 := mustCourt("ebond2")
	c2.coin.Mint(holder2, 1_000_000_000)    // 1,000 CC votable
	c2.coin.Mint(c2.escrow, 99_000_000_000) // 99,000 CC locked as stake and bonds
	testing.SkipHeights(epochBlocks * 2)

	cand2 := testutils.TestAddress("eb2-cand")
	testing.SetRealm(testing.NewUserRealm(holder2))
	id2 := RegisterModCandidate(cross(cur), "ebond2", []address{cand2}, 1)
	testing.SetRealm(testing.NewUserRealm(holder2))
	OpenElection(cross(cur), "ebond2", id2)

	floor2, bond2 := ElectionFloorOf("ebond2"), ElectionBondOf("ebond2")
	uassert.Equal(t, int64(50_000_000), floor2, "a twentieth of the 1,000 CC that can actually vote")
	if bond2 > floor2 {
		t.Fatalf("the bond is still quoted on raw supply: bond %d > floor %d", bond2, floor2)
	}
	// The beta-of-votable arm, not the clamp: the ratio holds on its own here.
	uassert.Equal(t, int64(5_000_000), bond2, "beta of votable weight, well clear of both bounds")
}
