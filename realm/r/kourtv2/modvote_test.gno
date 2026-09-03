package kourtv2

import (
	"chain/runtime"
	"strconv"
	"testing"
	"time"

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
// Enforces I12's install rule: argmax-approval over {candidates, retain}.
func TestElectionHonestMajorityUnseatsCapturedMinority(cur realm, t *testing.T) {
	creator := testutils.TestAddress("ev1-creator")
	honest := testutils.TestAddress("ev1-honest")
	captured := testutils.TestAddress("ev1-captured")
	newMod := testutils.TestAddress("ev1-newmod")
	c := electionCourt(cur, "ev1", creator,
		[]address{honest, captured}, []int64{690_000_000, 310_000_000})
	c.coin.Mint(honest, 50_000_000) // bond money

	testing.SetRealm(testing.NewUserRealm(honest))
	cand := RegisterModCandidate(cross(cur), "ev1", 1, newMod)
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
		AppointMods(cross(cur), "ev1", 1, creator)
	})
}

// Turnout below the quorum floor retains the current set (fail-safe on
// indecision — don't unseat moderators without a mandate).
// Enforces I12's turnout arm: below quorum, retain wins by default.
func TestElectionBelowQuorumRetains(cur realm, t *testing.T) {
	creator := testutils.TestAddress("ev2-creator")
	whale := testutils.TestAddress("ev2-whale")
	dust := testutils.TestAddress("ev2-dust")
	newMod := testutils.TestAddress("ev2-newmod")
	c := electionCourt(cur, "ev2", creator,
		[]address{whale, dust}, []int64{1_000_000_000, 10_000_000})
	c.coin.Mint(dust, 50_000_000)

	testing.SetRealm(testing.NewUserRealm(dust))
	cand := RegisterModCandidate(cross(cur), "ev2", 1, newMod)
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
	orig := RegisterModCandidate(cross(cur), "ev3", 1, honestMod)
	testing.SetRealm(testing.NewUserRealm(small))
	decoy := RegisterModCandidate(cross(cur), "ev3", 1, puppet)

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
// Enforces I2's ONLY carve-out — the candidate-bond legs — and I12's bond
// rule: refunded on install, otherwise half-burned.
func TestElectionBondsAddAndRefundOnlyOnInstall(cur realm, t *testing.T) {
	creator := testutils.TestAddress("ev4-creator")
	voter := testutils.TestAddress("ev4-voter")
	loserPoster := testutils.TestAddress("ev4-loser")
	winMod := testutils.TestAddress("ev4-win")
	loseMod := testutils.TestAddress("ev4-lose")
	c := electionCourt(cur, "ev4", creator,
		[]address{voter, loserPoster}, []int64{800_000_000, 100_000_000})

	testing.SetRealm(testing.NewUserRealm(voter))
	winner := RegisterModCandidate(cross(cur), "ev4", 1, winMod)
	testing.SetRealm(testing.NewUserRealm(loserPoster))
	loser := RegisterModCandidate(cross(cur), "ev4", 1, loseMod)

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
	a := RegisterModCandidate(cross(cur), "ev5", 1, m1)
	testing.SetRealm(testing.NewUserRealm(voter))
	b := RegisterModCandidate(cross(cur), "ev5", 1, m2)
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

// THE POST-ELECTION COOLDOWN IS A WEEK, NOT 120,960 BLOCKS.
//
// A fully-failed election arms this court's cooldown so the same ballot cannot be
// re-run immediately. TestElectionBelowQuorumRetains proves the cooldown BLOCKS a
// re-open; nothing proved when it LIFTS, and the corpus carried no row for it at
// all — so its length was free to be anything.
//
// The duration is decideWindowBlocks, the realm's unit for "a body gets this long
// to decide", reused here. On a chain off 5s a block, counted in blocks, a
// court's enforced pause between ballots is not the week the unit means.
func TestTheElectionCooldownLiftsOnTheWallClock(cur realm, t *testing.T) {
	creator := testutils.TestAddress("evc-creator")
	whale := testutils.TestAddress("evc-whale")
	dust := testutils.TestAddress("evc-dust")
	newMod := testutils.TestAddress("evc-newmod")
	c := electionCourt(cur, "evc", creator,
		[]address{whale, dust}, []int64{1_000_000_000, 10_000_000})
	c.coin.Mint(dust, 50_000_000)

	testing.SetRealm(testing.NewUserRealm(dust))
	cand := RegisterModCandidate(cross(cur), "evc", 1, newMod)
	testing.SetRealm(testing.NewUserRealm(dust))
	OpenElection(cross(cur), "evc", cand)
	testing.SkipHeights(nominationWindow)
	testing.SetRealm(testing.NewUserRealm(dust)) // sub-quorum turnout
	ApproveCandidate(cross(cur), "evc", cand)
	testing.SkipHeights(c.params.votingBlocks)
	testing.SetRealm(testing.NewUserRealm(dust))
	ResolveElection(cross(cur), "evc")

	cm := c.mod
	if cm.electionCooldownUntilTime == 0 {
		t.Fatal("fixture: the cooldown must be stamped, or this pins the height arm")
	}
	frozenH := heightNow()
	bumpTo := func(target int64) {
		d := target - nowTime()
		if d < 0 {
			t.Fatalf("fixture: %d is already behind us (now %d)", target, nowTime())
		}
		ctx := testing.GetContext()
		ctx.Time = ctx.Time.Add(time.Duration(d) * time.Second)
		testing.SetContext(ctx)
	}

	// ONE SECOND SHORT: still shut.
	bumpTo(cm.electionCooldownUntilTime - 1)
	uassert.Equal(t, frozenH, heightNow())
	uassert.True(t, heightNow() < cm.electionCooldownUntil) // blocks agree it is early
	testing.SetRealm(testing.NewUserRealm(dust))
	uassert.AbortsContains(t, cur, "cooldown", func() {
		OpenElection(cross(cur), "evc", cand)
	})

	// THE SECOND ITSELF: a new ballot may open, with no block mined and the block
	// arithmetic still reading "in cooldown".
	bumpTo(cm.electionCooldownUntilTime)
	uassert.Equal(t, frozenH, heightNow())
	uassert.True(t, heightNow() < cm.electionCooldownUntil)
	testing.SetRealm(testing.NewUserRealm(dust))
	OpenElection(cross(cur), "evc", cand)
	if !ElectionOpen("evc") {
		t.Fatal("past the cooldown on the wall clock a ballot must open")
	}
}

// A COURT THAT FAILED AN ELECTION BEFORE THE STAMPS keeps its block cooldown.
func TestAPreStampElectionCooldownKeepsItsBlockWindow(cur realm, t *testing.T) {
	creator := testutils.TestAddress("evd-creator")
	whale := testutils.TestAddress("evd-whale")
	dust := testutils.TestAddress("evd-dust")
	newMod := testutils.TestAddress("evd-newmod")
	c := electionCourt(cur, "evd", creator,
		[]address{whale, dust}, []int64{1_000_000_000, 10_000_000})
	c.coin.Mint(dust, 50_000_000)

	testing.SetRealm(testing.NewUserRealm(dust))
	cand := RegisterModCandidate(cross(cur), "evd", 1, newMod)
	testing.SetRealm(testing.NewUserRealm(dust))
	OpenElection(cross(cur), "evd", cand)
	testing.SkipHeights(nominationWindow)
	testing.SetRealm(testing.NewUserRealm(dust))
	ApproveCandidate(cross(cur), "evd", cand)
	testing.SkipHeights(c.params.votingBlocks)
	testing.SetRealm(testing.NewUserRealm(dust))
	ResolveElection(cross(cur), "evd")

	cm := c.mod
	cm.electionCooldownUntilTime = 0 // the pre-upgrade shape: a height, no stamp

	if d := cm.electionCooldownUntil - 1 - heightNow(); d > 0 {
		testing.SkipHeights(d)
	}
	uassert.Equal(t, cm.electionCooldownUntil-1, heightNow())
	testing.SetRealm(testing.NewUserRealm(dust))
	uassert.AbortsContains(t, cur, "cooldown", func() {
		OpenElection(cross(cur), "evd", cand)
	})
	testing.SkipHeights(1)
	uassert.Equal(t, cm.electionCooldownUntil, heightNow())
	testing.SetRealm(testing.NewUserRealm(dust))
	OpenElection(cross(cur), "evd", cand)
	if !ElectionOpen("evd") {
		t.Fatal("a pre-stamp cooldown must lift on its exact block")
	}
}

// THE BALLOT'S PHASES ARE HOURS, NOT BLOCK COUNTS — AND THEY MEET EXACTLY.
//
// nominateEnd and voteEnd are STORED FUTURE HEIGHTS, which is the kind that
// cannot be repaired after the fact: the `now` they were derived from is gone, so
// unlike an event stamp there is nothing a fallback could reconstruct. They are
// written as seconds at the same moment as their heights, and the three gates and
// the render's phase banner all read them through nominationClosed/votingClosed.
//
// WHAT THIS TEST IS REALLY FOR is the boundary BETWEEN the phases, not either one
// alone. `approve` tests both back to back, so a half-conversion — nomination on
// the clock, voting on blocks — would open instants where neither window accepts
// anything, or where the ballot takes votes the render calls closed. Asserting
// each phase separately would pass in that state. So this walks the seam: the
// last second of nominating and the first second of voting, with no block mined
// between them, and checks that BOTH verbs flip together.
func TestTheBallotPhasesMeetExactlyOnTheWallClock(cur realm, t *testing.T) {
	creator := testutils.TestAddress("evw-creator")
	voter := testutils.TestAddress("evw-voter")
	m1 := testutils.TestAddress("evw-m1")
	m2 := testutils.TestAddress("evw-m2")
	c := electionCourt(cur, "evw", creator, []address{voter}, []int64{900_000_000})

	testing.SetRealm(testing.NewUserRealm(voter))
	a := RegisterModCandidate(cross(cur), "evw", 1, m1)
	testing.SetRealm(testing.NewUserRealm(voter))
	b := RegisterModCandidate(cross(cur), "evw", 1, m2)
	testing.SetRealm(testing.NewUserRealm(voter))
	OpenElection(cross(cur), "evw", a)

	e := c.mod.election
	if e.nominateEndTime == 0 || e.voteEndTime == 0 {
		t.Fatal("fixture: the ballot must stamp both deadlines, or this pins the height arm")
	}
	openedH := heightNow()
	bumpTo := func(target int64) {
		d := target - nowTime()
		if d < 0 {
			t.Fatalf("fixture: %d is already behind us (now %d)", target, nowTime())
		}
		ctx := testing.GetContext()
		ctx.Time = ctx.Time.Add(time.Duration(d) * time.Second)
		testing.SetContext(ctx)
	}

	// ---- THE LAST SECOND OF NOMINATING ----
	bumpTo(e.nominateEndTime - 1)
	uassert.Equal(t, openedH, heightNow())
	uassert.True(t, heightNow() < e.nominateEnd) // blocks agree it is early, either way
	other := testutils.TestAddress("evw-other")
	c.coin.Mint(other, 50_000_000)
	testing.SetRealm(testing.NewUserRealm(other))
	NominateCandidate(cross(cur), "evw", b) // still open
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "voting opens", func() { // and voting is not
		ApproveCandidate(cross(cur), "evw", a)
	})

	// ---- THE FIRST SECOND OF VOTING, one second later, no block mined ----
	// BOTH verbs flip on the same instant. That is the seam: nominating must shut
	// exactly when voting opens, with no gap and no overlap.
	bumpTo(e.nominateEndTime)
	uassert.Equal(t, openedH, heightNow())
	uassert.True(t, heightNow() < e.nominateEnd) // the block arm still says "nominating"
	third := testutils.TestAddress("evw-third")
	c.coin.Mint(third, 50_000_000)
	testing.SetRealm(testing.NewUserRealm(third))
	uassert.AbortsContains(t, cur, "nomination window has closed", func() {
		NominateCandidate(cross(cur), "evw", b)
	})
	testing.SetRealm(testing.NewUserRealm(voter))
	ApproveCandidate(cross(cur), "evw", a) // voting is open on the same second

	// ---- AND THE FAR EDGE: voting shuts exactly when resolution opens ----
	bumpTo(e.voteEndTime - 1)
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "voting window has not closed", func() {
		ResolveElection(cross(cur), "evw")
	})
	bumpTo(e.voteEndTime)
	uassert.Equal(t, openedH, heightNow())
	testing.SetRealm(testing.NewUserRealm(other))
	uassert.AbortsContains(t, cur, "voting has closed", func() {
		ApproveCandidate(cross(cur), "evw", b)
	})
	testing.SetRealm(testing.NewUserRealm(voter))
	ResolveElection(cross(cur), "evw") // and resolution is open on that same second
	if ElectionOpen("evw") {
		t.Fatal("the ballot must resolve once its voting window closes on the clock")
	}
}

// A BALLOT OPENED BEFORE THE STAMPS still runs on its heights, at both seams.
func TestAPreStampBallotKeepsItsBlockPhases(cur realm, t *testing.T) {
	creator := testutils.TestAddress("evp-creator")
	voter := testutils.TestAddress("evp-voter")
	m1 := testutils.TestAddress("evp-m1")
	m2 := testutils.TestAddress("evp-m2")
	c := electionCourt(cur, "evp", creator, []address{voter}, []int64{900_000_000})

	testing.SetRealm(testing.NewUserRealm(voter))
	a := RegisterModCandidate(cross(cur), "evp", 1, m1)
	testing.SetRealm(testing.NewUserRealm(voter))
	b := RegisterModCandidate(cross(cur), "evp", 1, m2)
	testing.SetRealm(testing.NewUserRealm(voter))
	OpenElection(cross(cur), "evp", a)

	e := c.mod.election
	e.nominateEndTime, e.voteEndTime = 0, 0 // the pre-upgrade shape: heights only

	// One block short of the nomination edge, both verbs answer as before.
	if d := e.nominateEnd - 1 - heightNow(); d > 0 {
		testing.SkipHeights(d)
	}
	uassert.Equal(t, e.nominateEnd-1, heightNow())
	other := testutils.TestAddress("evp-other")
	c.coin.Mint(other, 50_000_000)
	testing.SetRealm(testing.NewUserRealm(other))
	NominateCandidate(cross(cur), "evp", b)
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "voting opens", func() {
		ApproveCandidate(cross(cur), "evp", a)
	})

	// And on the block itself they flip together, exactly as the clock arm does.
	testing.SkipHeights(1)
	uassert.Equal(t, e.nominateEnd, heightNow())
	third := testutils.TestAddress("evp-third")
	c.coin.Mint(third, 50_000_000)
	testing.SetRealm(testing.NewUserRealm(third))
	uassert.AbortsContains(t, cur, "nomination window has closed", func() {
		NominateCandidate(cross(cur), "evp", b)
	})
	testing.SetRealm(testing.NewUserRealm(voter))
	ApproveCandidate(cross(cur), "evp", a)

	// ---- AND THE FAR SEAM, which the nomination half does not reach ----
	// Walked because it was measured unpinned: mutating votingClosed's height arm
	// SURVIVED while only the nomination seam was covered. Two deadlines share one
	// shape, and sharing a shape is not sharing a test.
	if d := e.voteEnd - 1 - heightNow(); d > 0 {
		testing.SkipHeights(d)
	}
	uassert.Equal(t, e.voteEnd-1, heightNow())
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "voting window has not closed", func() {
		ResolveElection(cross(cur), "evp")
	})
	testing.SkipHeights(1)
	uassert.Equal(t, e.voteEnd, heightNow())
	testing.SetRealm(testing.NewUserRealm(other))
	uassert.AbortsContains(t, cur, "voting has closed", func() {
		ApproveCandidate(cross(cur), "evp", b)
	})
	testing.SetRealm(testing.NewUserRealm(voter))
	ResolveElection(cross(cur), "evp")
	if ElectionOpen("evp") {
		t.Fatal("a pre-stamp ballot must still close on its exact block")
	}
}

// Approving several lines counts the voter's weight ONCE toward turnout
// (distinct-voter weight, not the sum of approvals).
func TestElectionTurnoutIsDistinctVoters(cur realm, t *testing.T) {
	creator := testutils.TestAddress("ev6-creator")
	voter := testutils.TestAddress("ev6-voter")
	m1 := testutils.TestAddress("ev6-m1")
	m2 := testutils.TestAddress("ev6-m2")
	c := electionCourt(cur, "ev6", creator, []address{voter}, []int64{900_000_000})
	// Bond money, minted AFTER electionCourt sealed the epoch, so e.epoch cannot
	// see it: votableAt, electionFloor and electionBond are all unchanged and this
	// is a no-op today. It exists so the voter can pay the 4,500,000 election bond
	// at OpenElection and still hold the 900,000,000 this test asserts — the
	// repo's own idiom (see the honest-voter mint below).
	//
	// Needed because vote weight is becoming min(snapshot, live balance): the bond
	// leaves the balance, so without this the voter votes 895,500,000 and every
	// literal here would have to move. Measured minimum: 4,499,999 fails.
	c.coin.Mint(voter, 4_500_000)
	other := testutils.TestAddress("ev6-other")
	c.coin.Mint(other, 60_000_000)

	testing.SetRealm(testing.NewUserRealm(voter))
	a := RegisterModCandidate(cross(cur), "ev6", 1, m1)
	testing.SetRealm(testing.NewUserRealm(voter))
	b := RegisterModCandidate(cross(cur), "ev6", 1, m2)
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
	// `small` holds EXACTLY the 50,000,000 election floor — that is the point of
	// this fixture, since ResolveElection's second install condition
	// (l.weight-e.retainW < e.floor) only bites when maxW == e.floor and is what
	// keeps the zero-approval puppet out. Post-seal bond money so paying the
	// 5,000,000 nomination bond does not push them under their own bar.
	//
	// MUST be post-seal. Minting pre-seal instead also makes the test pass, and
	// makes it VACUOUS: measured, with a pre-seal 55,291,006 the fixture still
	// passes when that second condition is deleted, so it stops catching the
	// mutation it was written for. Measured minimum here: 4,999,999 fails.
	c.coin.Mint(small, 5_000_000)

	testing.SetRealm(testing.NewUserRealm(griefer))
	puppetSet := RegisterModCandidate(cross(cur), "ev7", 1, puppet)
	testing.SetRealm(testing.NewUserRealm(small))
	honestSet := RegisterModCandidate(cross(cur), "ev7", 1, honestMod)

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
	// election floor, but carrotClampMinCC pins the bond at 1 CC: without the clamp
	// the ballot costs twice what winning the vote does, and the electorate's
	// own remedy is priced out of reach on precisely the youngest courts.
	creator := testutils.TestAddress("eb1-creator")
	holder := testutils.TestAddress("eb1-holder")
	_ = electionCourt(cur, "ebond1", creator, []address{holder}, []int64{10_000_000})

	cand1 := testutils.TestAddress("eb1-cand")
	testing.SetRealm(testing.NewUserRealm(holder))
	id1 := RegisterModCandidate(cross(cur), "ebond1", 1, cand1)
	testing.SetRealm(testing.NewUserRealm(holder))
	OpenElection(cross(cur), "ebond1", id1)

	floor1, bond1 := ElectionFloorOf("ebond1"), ElectionBondOf("ebond1")
	uassert.Equal(t, int64(500_000), floor1, "a twentieth of 10 CC votable")
	if bond1 > floor1 {
		t.Fatalf("the absolute carrotClampMinCC arm escaped the clamp: bond %d > floor %d", bond1, floor1)
	}
	uassert.Equal(t, floor1, bond1, "on a small court the floor is the binding term")

	// ARM 2 — the base mismatch. 99% of supply sits in escrow as stake and
	// bonds, which is ordinary for a mature court. Quoted on RAW supply the
	// bond here would be 500 CC against a 50 CC floor: a tenfold inversion
	// produced by nothing but the two terms disagreeing about a denominator.
	// The sizes are deliberately well above carrotClampMinCC so this arm tests the
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
	id2 := RegisterModCandidate(cross(cur), "ebond2", 1, cand2)
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

// THE deposed-signature bypass. Approvals record ADDRESSES and are never
// re-validated at fire time, so any surviving entry lets a moderator the
// electorate just removed still count toward the threshold. installModSet is
// the shared install primitive for both peers that replace a set — the court's
// own election and the meta court's `mod:setmods` verdict — and it was the one
// membership change that left `pending` standing.
//
// The exploit this pins: the outgoing set banks m-1 approvals on a hide, the
// electorate throws them out, and a single member of the incoming set fires it
// on the deposed signatures. That breaks §3.1's "a lone puppet installed into a
// set can act on nothing" in precisely the scenario the election exists to
// remedy, and ResolveElection is permissionless, so the attacker does not even
// need to be the one who calls it.
func TestInstallModSetDiscardsTheDeposedSetsApprovals(cur realm, t *testing.T) {
	creator := testutils.TestAddress("dep-creator")
	holder := testutils.TestAddress("dep-holder")
	oldA := testutils.TestAddress("dep-oldA")
	oldB := testutils.TestAddress("dep-oldB")
	newX := testutils.TestAddress("dep-newX")
	newY := testutils.TestAddress("dep-newY")

	c := electionCourt(cur, "deposed", creator, []address{holder}, []int64{1_000_000_000})
	// A SHORT voting window, and this is the whole fixture. With the default
	// 120_960-block window the election takes 138_240 blocks to conclude, which is
	// LONGER than pendingTTLBlocks (120_960) — so the outgoing set's banked
	// signature expired by rule before the new set ever acted, and this test
	// passed whether or not the fix existed. Deleting the clear from
	// installModSet survived the mutation batch because of exactly that.
	//
	// The vulnerability is real on any court whose voting window is shorter than
	// about six days, which is most of them: a court sets its own. So the fixture
	// has to conclude INSIDE the TTL to test the fix rather than the clock.
	c.params.votingBlocks = 200

	testing.SetRealm(testing.NewUserRealm(creator))
	AppointMods(cross(cur), "deposed", 2, oldA, oldB)
	testing.SetRealm(testing.NewUserRealm(holder))
	id := OpenClaim(cross(cur), "deposed", "a claim the old set wanted buried")

	// The outgoing set banks one of the two approvals it needs.
	testing.SetRealm(testing.NewUserRealm(oldA))
	HideItem(cross(cur), "deposed", id, "pretextual")
	if HiddenFromListing("deposed", id) {
		t.Fatal("fixture: one of two must not fire")
	}
	hideAt := runtime.ChainHeight()
	hideKey := "hide:" + strconv.FormatUint(id, 10)
	if n, _ := PendingApproval("deposed", hideKey); n != 1 {
		t.Fatalf("fixture: the old set must have ONE banked approval, got %d", n)
	}

	// The electorate replaces them with a DISJOINT set.
	testing.SetRealm(testing.NewUserRealm(holder))
	cand := RegisterModCandidate(cross(cur), "deposed", 2, newX, newY)
	testing.SetRealm(testing.NewUserRealm(holder))
	OpenElection(cross(cur), "deposed", cand)
	testing.SkipHeights(nominationWindow)
	testing.SetRealm(testing.NewUserRealm(holder))
	ApproveCandidate(cross(cur), "deposed", cand)
	testing.SkipHeights(c.params.votingBlocks)
	testing.SetRealm(testing.NewUserRealm(holder))
	ResolveElection(cross(cur), "deposed")
	if !IsCourtMod("deposed", newX) || IsCourtMod("deposed", oldA) {
		t.Fatal("fixture: the election must have installed the new set")
	}

	// THE PREMISE, asserted rather than assumed: the deposed set's approval is
	// gone because the INSTALL discarded it, and not because it timed out. If a
	// future change lengthens the election past the TTL again, this fires instead
	// of the test quietly going vacuous.
	if runtime.ChainHeight() >= hideAt+pendingTTLBlocks {
		t.Fatal("fixture went vacuous: the election outlived the pending TTL, so " +
			"the banked approval would have expired with or without the fix")
	}

	// ONE member of the incoming set acts. Under the bug, oldA's banked
	// signature completed the 2-of-2 and this hid the claim.
	testing.SetRealm(testing.NewUserRealm(newX))
	HideItem(cross(cur), "deposed", id, "reviewing")
	if HiddenFromListing("deposed", id) {
		t.Fatal("a deposed moderator's approval completed the new set's quorum")
	}
	// And the new set can still act properly, on its own two signatures.
	testing.SetRealm(testing.NewUserRealm(newY))
	HideItem(cross(cur), "deposed", id, "reviewing")
	if !HiddenFromListing("deposed", id) {
		t.Fatal("the incoming set's own two approvals should fire")
	}
}

// The floor of a live election never decreases. This is the invariant the v0.31
// panel named as the one thing standing between a DOMINATED attack and a
// PURCHASABLE OPTION, and it was structural but unwatched: electionFloor nets
// the escrow, so parking stake lowers it, and if the floor were recomputed at
// resolve time an attacker could watch the turnout shortfall and then park
// exactly enough to erase it. Pinning it at open costs the attacker that
// information — they must commit blind, at 20 coins parked per coin of relief.
//
// The second assertion is the point of the test. Asserting only that the pinned
// floor did not move would pass just as well if the parking had done nothing at
// all, so this recomputes the floor live at the current epoch and requires it to
// be STRICTLY LOWER. That is the positive control: the escrow really did move,
// a live implementation really would have quoted a cheaper bar, and the pinned
// one really did ignore it.
func TestElectionFloorIsPinnedAtOpenAndNeverFalls(cur realm, t *testing.T) {
	creator := testutils.TestAddress("epin-creator")
	holder := testutils.TestAddress("epin-holder")
	parker := testutils.TestAddress("epin-parker")
	c := electionCourt(cur, "epin", creator,
		[]address{holder, parker}, []int64{200_000_000, 800_000_000}) // 1,000 CC

	cand := testutils.TestAddress("epin-cand")
	testing.SetRealm(testing.NewUserRealm(holder))
	id := RegisterModCandidate(cross(cur), "epin", 1, cand)
	testing.SetRealm(testing.NewUserRealm(holder))
	OpenElection(cross(cur), "epin", id)

	pinned := ElectionFloorOf("epin")
	uassert.Equal(t, int64(50_000_000), pinned, "a twentieth of the 1,000 CC votable at open")

	// The parker moves 80% of supply into the escrow AFTER the ballot is open —
	// the whole point being that under a live base this is bought turnout relief.
	c.coin.Transfer(parker, c.escrow, 800_000_000)
	testing.SkipHeights(epochBlocks * 2) // seal the epoch that holds the parked balance

	uassert.Equal(t, pinned, ElectionFloorOf("epin"),
		"the open election's floor moved after the escrow grew: the base is live, not pinned")

	// POSITIVE CONTROL — a live recomputation at the current epoch is strictly
	// cheaper, so the assertion above is measuring the pinning and not a no-op.
	live := electionFloor(c, c.coin.Epoch()-1)
	if live >= pinned {
		t.Fatalf("fixture did not move the base: live floor %d is not below the pinned %d", live, pinned)
	}
	// 195 CC, not 200: the nomination bond is itself a transfer into the escrow,
	// so opening the ballot already shrank the votable base by 5 CC. That is
	// consistent — every path that grows the escrow is paid 1:1 by the party that
	// benefits, which is exactly what makes the 20:1 tax on this attack hold.
	uassert.Equal(t, int64(9_750_000), live,
		"a twentieth of the 195 CC still votable — what an attacker would have bought")
}

// RegisterModCandidate is the SECOND way a moderator set enters a court, and
// it validates its argument independently of AppointMods. TestModSetSizeIsCapped
// already covers the 32-member cap on BOTH paths — and caught its mutation —
// but the empty-set rule, the m-of-n range and the zero-address rule on this
// path were unpinned: each panic could be deleted and all eleven election
// tests still passed.
func TestRegisterModCandidateValidatesItsSet(cur realm, t *testing.T) {
	creator := testutils.TestAddress("rc-creator")
	m1 := testutils.TestAddress("rc-m1")
	testCourt(cur, "regcand", creator, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsContains(t, cur, "candidate set may not be empty", func() {
		RegisterModCandidate(cross(cur), "regcand", 1)
	})
	// Both ends of the m-of-n range, so the bound cannot be half-deleted.
	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsContains(t, cur, "m-of-n threshold must be in 1..n", func() {
		RegisterModCandidate(cross(cur), "regcand", 0, m1)
	})
	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsContains(t, cur, "m-of-n threshold must be in 1..n", func() {
		RegisterModCandidate(cross(cur), "regcand", 2, m1)
	})
	// canonicalMembers refuses the zero address on both paths, and nothing
	// else in the suite ever passes one.
	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsContains(t, cur, "moderator address may not be zero", func() {
		RegisterModCandidate(cross(cur), "regcand", 1, m1, "")
	})
	// A MALFORMED address, which is a different failure from the zero one and now
	// reachable for real: these entrypoints are called with strings over the wire,
	// and the argument conversion does not check bech32. Without this guard a
	// typo is seated as a moderator and counted in the threshold.
	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsContains(t, cur, "not a valid address", func() {
		RegisterModCandidate(cross(cur), "regcand", 1, m1, "g1nothingvalidhere")
	})
	// A well-formed set registers, so the five refusals above are about their
	// own reasons and not about a call that was broken to begin with.
	testing.SetRealm(testing.NewUserRealm(creator))
	if id := RegisterModCandidate(cross(cur), "regcand", 1, m1); id == 0 {
		t.Fatal("a well-formed candidate set must register and return an id")
	}
}

// I12's per-court latch: one open election at a time. Without it a court can
// carry two live ballots pinned to different epochs, and whichever resolves
// second silently overwrites the set the first one installed — the same shape
// as the v0.25 deposed-signature bug. The cooldown guard sits AFTER this one,
// so a court with no history can only be refused for the latch.
func TestOnlyOneElectionOpenPerCourt(cur realm, t *testing.T) {
	creator := testutils.TestAddress("oe-creator")
	voter := testutils.TestAddress("oe-voter")
	m1 := testutils.TestAddress("oe-m1")
	m2 := testutils.TestAddress("oe-m2")
	electionCourt(cur, "onelect", creator, []address{voter}, []int64{900_000_000})

	testing.SetRealm(testing.NewUserRealm(voter))
	a := RegisterModCandidate(cross(cur), "onelect", 1, m1)
	testing.SetRealm(testing.NewUserRealm(voter))
	b := RegisterModCandidate(cross(cur), "onelect", 1, m2)

	testing.SetRealm(testing.NewUserRealm(voter))
	OpenElection(cross(cur), "onelect", a)
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "election is already open", func() {
		OpenElection(cross(cur), "onelect", b)
	})
}

// The two ballot-ADMISSION rules, neither of which any election test reached.
// A candidate may hold at most one line, and the board is bounded at
// maxBallotLines so ResolveElection's single-transaction walk stays affordable.
func TestBallotRefusesAFullBoardAndADuplicateLine(cur realm, t *testing.T) {
	creator := testutils.TestAddress("bf-creator")
	opener := testutils.TestAddress("bf-opener")
	second := testutils.TestAddress("bf-second")
	third := testutils.TestAddress("bf-third")
	m1 := testutils.TestAddress("bf-m1")
	m2 := testutils.TestAddress("bf-m2")
	m3 := testutils.TestAddress("bf-m3")
	c := electionCourt(cur, "ballotfl", creator,
		[]address{opener, second, third},
		[]int64{900_000_000, 900_000_000, 900_000_000})

	testing.SetRealm(testing.NewUserRealm(opener))
	a := RegisterModCandidate(cross(cur), "ballotfl", 1, m1)
	testing.SetRealm(testing.NewUserRealm(opener))
	b := RegisterModCandidate(cross(cur), "ballotfl", 1, m2)
	testing.SetRealm(testing.NewUserRealm(opener))
	d := RegisterModCandidate(cross(cur), "ballotfl", 1, m3)
	// OpenElection nominates its own candidate, so `a` is on the board and the
	// opener has spent its one nomination.
	testing.SetRealm(testing.NewUserRealm(opener))
	OpenElection(cross(cur), "ballotfl", a)

	// A DIFFERENT address may not re-list a candidate already on the board.
	// The opener itself would be refused one guard earlier by the
	// one-nomination-per-address rule, so only a second nominator can reach
	// this arm at all.
	testing.SetRealm(testing.NewUserRealm(second))
	uassert.AbortsContains(t, cur, "already on the ballot", func() {
		NominateCandidate(cross(cur), "ballotfl", a)
	})
	// The same address CAN list a different candidate, so the refusal above is
	// about the candidate and not about the nominator.
	testing.SetRealm(testing.NewUserRealm(second))
	NominateCandidate(cross(cur), "ballotfl", b)

	// The board limit. Filling it honestly needs maxBallotLines funded
	// addresses; the line-ADDING path is covered by the nomination just above
	// and by TestElectionDecoyLosesToEarliestNomination, so the full state is
	// constructed and only the refusal is exercised. `third` has not nominated
	// and `d` is not on the board, so with the limit deleted this nomination
	// SUCCEEDS — no neighbouring guard can stand in for it.
	cm := ensureMod(c)
	e := cm.election
	for i := e.lines.Size(); i < maxBallotLines; i++ {
		id := uint64(10_000 + i)
		e.lines.Set(beClaimKey(id), &ballotLine{
			candID: id, nomAt: runtime.ChainHeight(), bond: e.bond, poster: creator,
		})
	}
	if e.lines.Size() != maxBallotLines {
		t.Fatalf("the constructed board must sit exactly at the cap, got %d", e.lines.Size())
	}
	testing.SetRealm(testing.NewUserRealm(third))
	uassert.AbortsContains(t, cur, "ballot is full", func() {
		NominateCandidate(cross(cur), "ballotfl", d)
	})
}

// The four window-and-weight gates on the voting path. The weight pin is the
// load-bearing one: it is what stops an election being decided by CC bought
// after the ballot became visible, and it was entirely unpinned.
func TestVotingWindowAndWeightGates(cur realm, t *testing.T) {
	creator := testutils.TestAddress("vg-creator")
	voter := testutils.TestAddress("vg-voter")
	m1 := testutils.TestAddress("vg-m1")
	m2 := testutils.TestAddress("vg-m2")
	c := electionCourt(cur, "votegate", creator, []address{voter}, []int64{900_000_000})

	testing.SetRealm(testing.NewUserRealm(voter))
	onBallot := RegisterModCandidate(cross(cur), "votegate", 1, m1)
	testing.SetRealm(testing.NewUserRealm(voter))
	offBallot := RegisterModCandidate(cross(cur), "votegate", 1, m2)
	testing.SetRealm(testing.NewUserRealm(voter))
	OpenElection(cross(cur), "votegate", onBallot)

	// Step to the close of the nomination window, where voting opens.
	testing.SkipHeights(nominationWindow)

	// Resolving while the ballot is still live would install on a partial
	// count — whoever leads at that instant, not whoever leads at the close.
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "voting window has not closed", func() {
		ResolveElection(cross(cur), "votegate")
	})

	// A registered candidate nobody nominated is not an approvable line. This
	// guard is what keeps the candidate REGISTRY — permissionless and
	// unbonded — from doubling as the ballot, which is bonded and capped.
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "not on the ballot", func() {
		ApproveCandidate(cross(cur), "votegate", offBallot)
	})

	// Weight is pinned at the epoch the election opened. The latecomer is
	// minted more CC than the honest voter holds and still cannot vote,
	// because it held none at the pin. No epoch is sealed here on purpose:
	// sealing one would need epochBlocks*2 heights, and the fixture must stay
	// inside the voting window or it would measure the CLOSED refusal instead.
	latecomer := testutils.TestAddress("vg-late")
	c.coin.Mint(latecomer, 5_000_000_000)
	testing.SetRealm(testing.NewUserRealm(latecomer))
	uassert.AbortsContains(t, cur, "no voting weight at the pinned epoch", func() {
		ApproveCandidate(cross(cur), "votegate", onBallot)
	})
	// The pinned holder still votes, so the refusal above is about the pin and
	// not about a ballot that was shut for everyone.
	testing.SetRealm(testing.NewUserRealm(voter))
	ApproveCandidate(cross(cur), "votegate", onBallot)

	// voteEnd is inclusive-closed: exactly at it the board is shut, including
	// to the holder who was voting a moment earlier.
	testing.SkipHeights(c.params.votingBlocks)
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "voting has closed", func() {
		ApproveRetain(cross(cur), "votegate")
	})
}

// The lookup helpers behind every election read. Each refuses in TWO distinct
// states that share ONE message, so a fixture reaching only the first leaves the
// second deletable in silence: mustCandidate refuses a court whose candidate
// registry was never created AND a registry that does not hold the id, and
// mustOpenElection refuses a court that never opened a ballot AND one whose
// ballot has resolved. A message assertion cannot tell those apart — only the
// STATE the fixture builds can — which is why each branch gets its own court.
// These are plain reads, so they panic rather than abort.
func TestElectionReadsRefuseEveryMissingState(cur realm, t *testing.T) {
	// mustModRead. StartCourt does not allocate moderation state, so a court
	// nobody has moderated has none, and a query must say so rather than create
	// one on the way past — the read-purity rule check-read-purity.py enforces.
	fresh := testutils.TestAddress("lk-fresh")
	testCourt(cur, "lkfresh", fresh, 10_000_000_000)
	uassert.PanicsContains(t, cur, "no moderation state yet", func() {
		ElectionBondOf("lkfresh")
	})

	// mustCandidate, BRANCH 1 — moderation state exists, the candidate registry
	// does not. AppointMods allocates the courtMod without touching
	// cm.candidates, which is exactly this state and is not reachable by
	// registering and then removing, because nothing removes a candidate.
	creator := testutils.TestAddress("lk-creator")
	m1 := testutils.TestAddress("lk-m1")
	testCourt(cur, "lknoreg", creator, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	AppointMods(cross(cur), "lknoreg", 1, m1)
	uassert.PanicsContains(t, cur, "no such candidate", func() {
		CandidateMembers("lknoreg", 1)
	})

	// mustCandidate, BRANCH 2 — the registry exists and does not hold the id.
	// The registered candidate is read back FIRST, so the refusal below is about
	// the id and not about a registry that failed to appear.
	testing.SetRealm(testing.NewUserRealm(creator))
	id := RegisterModCandidate(cross(cur), "lknoreg", 1, m1)
	if got := CandidateMembers("lknoreg", id); len(got) != 1 || got[0] != m1 {
		t.Fatal("a registered candidate must read back before its absence means anything")
	}
	uassert.PanicsContains(t, cur, "no such candidate", func() {
		CandidateMembers("lknoreg", id+999)
	})

	// mustOpenElection, BRANCH 1 — moderation state and a candidate, no ballot.
	// Registering is deliberately NOT opening: the registry is permissionless
	// and unbonded, the ballot is bonded and capped.
	uassert.PanicsContains(t, cur, "no election is open", func() {
		ElectionBondOf("lknoreg")
	})
}

// mustOpenElection's SECOND refusal, which needs a ballot that has run its
// course rather than one that never existed. A resolved ballot is not an open
// one: without the guard every election read would keep serving a finished
// ballot's pinned figures as though voting were live, and approve() would bank
// votes into a tally nothing will ever count again.
func TestAResolvedElectionIsNoLongerOpen(cur realm, t *testing.T) {
	creator := testutils.TestAddress("lkd-creator")
	voter := testutils.TestAddress("lkd-voter")
	mod := testutils.TestAddress("lkd-mod")
	c := electionCourt(cur, "lkdone", creator, []address{voter}, []int64{900_000_000})

	testing.SetRealm(testing.NewUserRealm(voter))
	id := RegisterModCandidate(cross(cur), "lkdone", 1, mod)
	testing.SetRealm(testing.NewUserRealm(voter))
	OpenElection(cross(cur), "lkdone", id)
	if !ElectionOpen("lkdone") {
		t.Fatal("the ballot must be open before resolving it proves anything")
	}
	// Nobody votes, so this resolves to retain — the point here is the resolved
	// FLAG, not the outcome, and a no-approval ballot reaches it with the fewest
	// moving parts.
	testing.SkipHeights(nominationWindow + c.params.votingBlocks)
	testing.SetRealm(testing.NewUserRealm(voter))
	ResolveElection(cross(cur), "lkdone")

	if ElectionOpen("lkdone") {
		t.Fatal("a resolved ballot must not report as open")
	}
	uassert.PanicsContains(t, cur, "no election is open", func() {
		ElectionBondOf("lkdone")
	})
	// And the write path agrees with the read path: a vote cannot land in it.
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "no election is open", func() {
		ApproveCandidate(cross(cur), "lkdone", id)
	})
}

// THE FLOOR ON ELECTION WEIGHT, and this was the worst-exposed lane: whoever calls
// OpenElection pins the anchor, and the prize is the whole moderator set rather
// than one claim. Measured at 12x the election floor from a one-epoch rental.
//
// The renter does everything right for the old design — acquire, let the epoch
// seal, open the election themselves so the anchor lands inside their holding
// window, sell it all back — and is now refused, because repaying the loan is what
// empties the floor.
//
// PAIRED with the whale who keeps their coin and must be tallied undocked.
func TestElectionWeightIsFlooredByWhatIsStillHeld(cur realm, t *testing.T) {
	creator := testutils.TestAddress("evfl-creator")
	whale := testutils.TestAddress("evfl-whale")
	renter := testutils.TestAddress("evfl-renter")
	newMod := testutils.TestAddress("evfl-newmod")
	c := electionCourt(cur, "evfl", creator,
		[]address{whale}, []int64{500_000_000_000})
	c.coin.Mint(whale, 50_000_000) // bond money

	// Acquire, and seal the epoch that holds it.
	testing.SetRealm(testing.NewUserRealm(whale))
	TransferCC(cross(cur), "evfl", renter, 300_000_000_000)
	testing.SkipHeights(epochBlocks * 2)
	touch(c)

	testing.SetRealm(testing.NewUserRealm(whale))
	cand := RegisterModCandidate(cross(cur), "evfl", 1, newMod)
	// The renter opens it, which is the step that pins the anchor inside their
	// holding window. That much still works — it is what made this rentable.
	testing.SetRealm(testing.NewUserRealm(renter))
	OpenElection(cross(cur), "evfl", cand)
	e := ensureMod(c).election

	pinned := c.coin.PastVotes(renter, e.epoch)
	if pinned <= 0 {
		t.Fatal("fixture is vacuous: the renter has no weight at the pinned epoch")
	}
	if pinned <= electionFloor(c, e.epoch) {
		t.Fatal("fixture is vacuous: the rental must stand ABOVE the floor for " +
			"refusing it to mean anything")
	}
	testing.SkipHeights(nominationWindow)

	// Repay the loan. The anchor is untouched — that is the whole hazard.
	testing.SetRealm(testing.NewUserRealm(renter))
	TransferCC(cross(cur), "evfl", whale, SpendableOf("evfl", renter))
	uassert.Equal(t, int64(0), c.coin.BalanceOf(renter))
	uassert.Equal(t, pinned, c.coin.PastVotes(renter, e.epoch))

	testing.SetRealm(testing.NewUserRealm(renter))
	uassert.AbortsContains(t, cur, "no longer hold", func() {
		ApproveCandidate(cross(cur), "evfl", cand)
	})

	// THE PAIR. The whale held throughout and is tallied at their full snapshot,
	// not at the (larger) balance the repayment left them holding.
	whalePinned := c.coin.PastVotes(whale, e.epoch)
	if whalePinned <= 0 {
		t.Fatal("fixture is vacuous: the whale has no weight at the pinned epoch")
	}
	if c.coin.BalanceOf(whale) <= whalePinned {
		t.Fatal("fixture is vacuous: the whale's live balance must exceed their " +
			"snapshot for this to say anything about the ceiling")
	}
	testing.SetRealm(testing.NewUserRealm(whale))
	ApproveCandidate(cross(cur), "evfl", cand)
	candW, _, turnout := ElectionTally("evfl", cand)
	uassert.Equal(t, whalePinned, candW)
	uassert.Equal(t, whalePinned, turnout)
}

// WEIGHT IS FROZEN AT THE FIRST APPROVAL, and this is not an optimisation.
//
// The floor is a live read and a ballot spans many transactions, so re-deriving it
// per approval lets one voter approve line A while holding little, top up, and
// approve line B at their full snapshot. Line B then carries weight ABOVE the
// turnout recorded at approval A — and install compares maxW against e.turnout, so
// that is a candidate installing on weight the election never counted. The ratio is
// UNBOUNDED: line B reads the snapshot while turnout holds whatever the voter had at
// approval A, so it is snapshot/e for an e of the voter's choosing. (An earlier note
// here said "the panels measured a line at 10x the whole turnout" — that figure was
// measured on the REVERTED design, where both readings were live, and does not
// transfer to this one.)
//
// So: approve early and poor, get rich, approve again. Both lines must read the
// poor figure, and turnout must bound them.
func TestElectionWeightIsFrozenAtFirstApproval(cur realm, t *testing.T) {
	creator := testutils.TestAddress("evfz-creator")
	voter := testutils.TestAddress("evfz-voter")
	helper := testutils.TestAddress("evfz-helper")
	modA := testutils.TestAddress("evfz-moda")
	modB := testutils.TestAddress("evfz-modb")
	// The voter's snapshot is deliberately the SMALLER pile, so the helper can
	// later lift their live balance clear above it. Registering a candidate locks
	// a bond, so the transfers below go through SpendableOf rather than the mint.
	c := electionCourt(cur, "evfz", creator,
		[]address{voter, helper}, []int64{100_000_000_000, 400_000_000_000})
	c.coin.Mint(voter, 50_000_000)
	c.coin.Mint(helper, 50_000_000)

	testing.SetRealm(testing.NewUserRealm(voter))
	candA := RegisterModCandidate(cross(cur), "evfz", 1, modA)
	testing.SetRealm(testing.NewUserRealm(helper))
	candB := RegisterModCandidate(cross(cur), "evfz", 1, modB)

	testing.SetRealm(testing.NewUserRealm(voter))
	OpenElection(cross(cur), "evfz", candA)
	testing.SkipHeights(10)
	testing.SetRealm(testing.NewUserRealm(helper))
	NominateCandidate(cross(cur), "evfz", candB)
	e := ensureMod(c).election
	snapshot := c.coin.PastVotes(voter, e.epoch)
	testing.SkipHeights(nominationWindow)

	// Go poor, keeping a real but much smaller position.
	testing.SetRealm(testing.NewUserRealm(voter))
	TransferCC(cross(cur), "evfz", helper, SpendableOf("evfz", voter)-1_000_000_000)
	poor := c.coin.BalanceOf(voter)
	if poor <= 0 || poor >= snapshot {
		t.Fatalf("fixture is vacuous: need 0 < poor < snapshot, got %d and %d",
			poor, snapshot)
	}

	testing.SetRealm(testing.NewUserRealm(voter))
	ApproveCandidate(cross(cur), "evfz", candA)
	wA, _, turnout := ElectionTally("evfz", candA)
	uassert.Equal(t, poor, wA)
	uassert.Equal(t, poor, turnout)

	// Now get rich again — back above the snapshot, so a re-derived figure would
	// be the snapshot rather than the poor one.
	testing.SetRealm(testing.NewUserRealm(helper))
	TransferCC(cross(cur), "evfz", voter, 200_000_000_000)
	if c.coin.BalanceOf(voter) <= snapshot {
		t.Fatal("fixture is vacuous: the top-up must lift the live balance above " +
			"the snapshot, or re-deriving would give the same answer either way")
	}

	testing.SetRealm(testing.NewUserRealm(voter))
	ApproveCandidate(cross(cur), "evfz", candB)

	// Line B reads the FROZEN figure, not the restored one.
	wB, _, turnout2 := ElectionTally("evfz", candB)
	uassert.Equal(t, poor, wB)
	// One voter is one voter: turnout did not move on the second approval.
	uassert.Equal(t, turnout, turnout2)
	// And the property the whole freeze exists for.
	if wB > turnout2 {
		t.Fatalf("a line carries %d against a turnout of %d — max(line.weight) "+
			"must never exceed turnout", wB, turnout2)
	}
}

// PAYING FOR A BALLOT LINE COSTS YOU THE BOND, AND THE BOND DOES NOT VOTE.
//
// A nominator holding EXACTLY the election floor pays the bond, which leaves their
// balance for the escrow, so their own approval is now worth floor-bond and cannot
// carry the line alone. Holding floor+bond, it can. Measured across court sizes the
// requirement is 110% of the floor on any ordinary court and at most 200% on one
// small enough for the carrotClampMinCC clamp to bind — mustElectionInvariants pins
// electionBondBps < quorumSupplyBps and the clamp pins bond <= floor, so 2x is a
// hard ceiling, not an observation.
//
// THIS IS THE INTENDED PROPERTY, not a rough edge: whoever pays for a line cannot
// also be its sole sufficient approver, so a self-approved set always needs one
// other holder. It is pinned HERE because the obvious "fix" — crediting the
// nominator's own bond back as weight — is a known-bad change that was implemented
// once and reverted: at low votable the bond EQUALS the floor, so the credit alone
// clears the bar from a zero balance, which is a free moderator coup. If someone
// re-adds that credit, the first arm below turns green and this comment is how they
// find out why it should not have.
func TestPayingForALineCostsTheBondItVotesWith(cur realm, t *testing.T) {
	// ARM 1 — exactly the floor, and it is not enough.
	creator := testutils.TestAddress("hc1-creator")
	whale := testutils.TestAddress("hc1-whale") // never votes; supply only
	nom := testutils.TestAddress("hc1-nom")
	mod1 := testutils.TestAddress("hc1-mod")
	c := electionCourt(cur, "hcut1", creator, []address{whale, nom},
		[]int64{950_000_000, 50_000_000})

	testing.SetRealm(testing.NewUserRealm(nom))
	cand := RegisterModCandidate(cross(cur), "hcut1", 1, mod1)
	testing.SetRealm(testing.NewUserRealm(nom))
	OpenElection(cross(cur), "hcut1", cand)
	e := ensureMod(c).election
	// The fixture's whole point: exactly the floor, before the bond is paid.
	uassert.Equal(t, e.floor, c.coin.PastVotes(nom, e.epoch))
	if e.bond <= 0 || e.bond >= e.floor {
		t.Fatalf("fixture is vacuous: a bond of %d against a floor of %d cannot "+
			"demonstrate a partial haircut", e.bond, e.floor)
	}
	uassert.Equal(t, e.floor-e.bond, c.coin.BalanceOf(nom))

	testing.SkipHeights(nominationWindow)
	testing.SetRealm(testing.NewUserRealm(nom))
	ApproveCandidate(cross(cur), "hcut1", cand)
	_, _, turnout := ElectionTally("hcut1", cand)
	// Weighed at the live balance, which the bond reduced — so below the bar.
	uassert.Equal(t, e.floor-e.bond, turnout)
	if turnout >= e.floor {
		t.Fatal("the bond was credited back: the payer must not be able to carry " +
			"the line they paid for, or a zero-balance coup is free at low votable")
	}
	testing.SkipHeights(c.params.votingBlocks)
	testing.SetRealm(testing.NewUserRealm(nom))
	ResolveElection(cross(cur), "hcut1")
	if IsCourtMod("hcut1", mod1) {
		t.Fatal("a line carried only by its own payer, below quorum, must not install")
	}

	// ARM 2 — the pair. floor+bond is enough, so this is a bounded cost and not a
	// wall: the same nominator with the bond covered installs their candidate.
	creator2 := testutils.TestAddress("hc2-creator")
	whale2 := testutils.TestAddress("hc2-whale")
	nom2 := testutils.TestAddress("hc2-nom")
	mod2 := testutils.TestAddress("hc2-mod")
	c2 := electionCourt(cur, "hcut2", creator2, []address{whale2, nom2},
		[]int64{950_000_000, 50_000_000})
	// The bond money POST-seal, which is the only non-circular way to say "the
	// floor plus the bond". Minting it pre-seal raises supply, which raises the
	// floor, which raises the bond: solving h - 0.005(950M+h) >= 0.05(950M+h)
	// gives h >= 55,291,006, and 55,000,000 lands 275,000 short. Post-seal the
	// snapshot stays at exactly the floor and only the live balance moves, so the
	// arm reads as intended: w = min(floor, floor+spare) = floor.
	c2.coin.Mint(nom2, 10_000_000)

	testing.SetRealm(testing.NewUserRealm(nom2))
	cand2 := RegisterModCandidate(cross(cur), "hcut2", 1, mod2)
	testing.SetRealm(testing.NewUserRealm(nom2))
	OpenElection(cross(cur), "hcut2", cand2)
	e2 := ensureMod(c2).election
	if c2.coin.BalanceOf(nom2) < e2.floor {
		t.Fatalf("fixture is vacuous: floor+bond should leave the floor intact, "+
			"balance %d floor %d", c2.coin.BalanceOf(nom2), e2.floor)
	}
	testing.SkipHeights(nominationWindow)
	testing.SetRealm(testing.NewUserRealm(nom2))
	ApproveCandidate(cross(cur), "hcut2", cand2)
	testing.SkipHeights(c2.params.votingBlocks)
	testing.SetRealm(testing.NewUserRealm(nom2))
	ResolveElection(cross(cur), "hcut2")
	if !IsCourtMod("hcut2", mod2) {
		t.Fatal("floor+bond must be enough: the haircut is a bounded cost, not a wall")
	}
}
