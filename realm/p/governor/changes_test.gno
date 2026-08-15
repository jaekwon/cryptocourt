package governor

import "testing"

// stated is an electorate whose totals are declared outright, for the boundary
// cases a council (whose total is its member count) cannot reach: an engaged
// weight above the supply, and a supply past the tally's overflow ceiling.
type stated struct {
	total, engaged int64
	epoch          uint32
}

func (stated) PastVotes(who address, at uint32) int64 { return 0 }
func (s stated) PastTotal(at uint32) int64            { return s.total }
func (s stated) EngagedTotal(at uint32) int64         { return s.engaged }
func (s stated) Epoch() uint32                        { return s.epoch }

func govFor(e Electorate) *Governor {
	g := New(e, coin{supply: 1})
	g.kinds.Set("fee", &entry{kind: setFee{name: "fee", ran: new(int64)}, live: true, rules: Rules{
		QuorumBps: 5000, ThresholdBps: 5000, VotingBlocks: 100, GraceBlocks: 1000,
	}})
	return g
}

// F1: a snapshot supply past what a tally can weigh (yes*bps) is refused at the
// door, rather than carried into a tally that overflows int64 and reads a won
// vote as lost. grc20votes caps its own supply at the ceiling, so this only ever
// fires for a swapped-in electorate that ignores the contract.
func TestSupplyPastTheCeilingIsRefused(t *testing.T) {
	g := govFor(&stated{total: maxWeighable + 1, engaged: maxWeighable + 1, epoch: 2})
	mustPanicContains(t, "exceeds what a tally can weigh", func() {
		g.Propose(gAlice, "fee", "1", "too big to weigh")
	})
	// Exactly at the ceiling is accepted.
	ok := govFor(&stated{total: maxWeighable, engaged: maxWeighable, epoch: 2})
	id := ok.Propose(gAlice, "fee", "1", "right at the ceiling")
	if ok.State(id) != "active" {
		t.Fatal("a supply exactly at the ceiling should be accepted")
	}
}

// Change #1: an EngagedTotal above the snapshot supply is clamped to it, so the
// proposal proceeds with an unreachable-but-valid bar rather than aborting — a
// court hosts claims too big for its electorate to decide. Also exercises
// Snapshot (change #3).
func TestEngagedAboveSupplyIsClamped(t *testing.T) {
	g := govFor(&stated{total: 100, engaged: 1000, epoch: 2})
	id := g.Propose(gAlice, "fee", "1", "engages more than exists")
	engaged, epoch := g.Snapshot(id)
	if engaged != 100 {
		t.Fatalf("engaged should clamp to the total 100, got %d", engaged)
	}
	if epoch != 1 {
		t.Fatalf("snapshot epoch should be 1, got %d", epoch)
	}
}

// F2: the threshold comparison is inclusive. At 5000 one yes of two settles at
// once, because the only remaining vote going no would tie and a tie PASSES —
// that early settlement IS the inclusive boundary. At 5001 a lone yes does not
// settle (a tie would fail), and the second vote makes the tie final: defeated.
func TestTieBoundaryAtThreshold(t *testing.T) {
	pass, _, _ := armed(t, gAlice, gBob) // ThresholdBps 5000
	idp := pass.Propose(gAlice, "fee", "1", "tie at 5000")
	pass.Vote(gAlice, idp, "yes")
	if got := pass.State(idp); got != "succeeded" {
		t.Fatalf("one yes of two at 5000 settles a passing tie, got %q", got)
	}

	fail, _, _ := armed(t, gAlice, gBob)
	fail.kinds.Set("fee", &entry{kind: setFee{name: "fee", ran: new(int64)}, live: true, rules: Rules{
		QuorumBps: 5000, ThresholdBps: 5001, VotingBlocks: 100, GraceBlocks: 1000,
	}})
	idf := fail.Propose(gAlice, "fee", "1", "tie at 5001")
	fail.Vote(gAlice, idf, "yes")
	if got := fail.State(idf); got != "active" {
		t.Fatalf("at 5001 a lone yes must not settle a failing tie, got %q", got)
	}
	fail.Vote(gBob, idf, "no")
	if got := fail.State(idf); got != "defeated" {
		t.Fatalf("a 50-50 tie at ThresholdBps 5001 should fail, got %q", got)
	}
}

// Change #2: ProposeWithQuorum replaces the bps bar with an absolute turnout for
// one proposal. A council of three has a bps bar (5000) of two votes; a floor of
// three needs all three — so two votes that would settle under the bps bar fall
// short under the floor, and the third makes quorum.
func TestProposeWithQuorumRaisesTheBar(t *testing.T) {
	g, _, _ := armed(t, gAlice, gBob, gCarl)
	id := g.ProposeWithQuorum(gAlice, "fee", "1", "needs three", 3)
	if g.QuorumFloor(id) != 3 {
		t.Fatalf("QuorumFloor should read back the floor 3, got %d", g.QuorumFloor(id))
	}
	g.Vote(gAlice, id, "yes")
	g.Vote(gBob, id, "yes")
	if got := g.State(id); got != "active" {
		t.Fatalf("two votes under a floor of three is short of quorum; want active, got %q", got)
	}
	g.Vote(gCarl, id, "yes")
	if got := g.State(id); got != "succeeded" {
		t.Fatalf("three votes meets the floor and carries; want succeeded, got %q", got)
	}

	// A bps proposal reports floor 0.
	if bpsID := g.Propose(gAlice, "fee", "2", "bps bar"); g.QuorumFloor(bpsID) != 0 {
		t.Fatalf("a bps proposal has no floor; want 0, got %d", g.QuorumFloor(bpsID))
	}

	// A non-positive floor is refused — Propose is the bps path.
	mustPanicContains(t, "quorum floor has to be positive", func() {
		g.ProposeWithQuorum(gAlice, "fee", "9", "bad floor", 0)
	})
}

// A documented past bug with no regression test until now: everybody abstaining
// left yes==no==0, and 0>=0 passed the threshold. Abstain is turnout without
// support, so an all-abstain proposal must DEFEAT.
func TestAllAbstainDefeats(t *testing.T) {
	g, _, _ := armed(t, gAlice, gBob)
	id := g.Propose(gAlice, "fee", "1", "all abstain")
	g.Vote(gAlice, id, "abstain")
	g.Vote(gBob, id, "abstain")
	if got := g.State(id); got != "defeated" {
		t.Fatalf("all-abstain should defeat with 'nobody voted in favour', got %q", got)
	}
}
