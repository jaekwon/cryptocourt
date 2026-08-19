package govern

import (
	"chain/runtime"
	governor "gno.land/p/kourt/governor/v0"
	grc20votes "gno.land/p/kourt/grc20votes/v0"
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// fakeVotes is an electorate with numbers a test chose.
//
// Reaching exactly a quorum with real balances means solving for the supply,
// and a test that does arithmetic to check arithmetic proves nothing. Here the
// boundary is stated, not derived.
type fakeVotes struct {
	weight  map[string]int64
	total   int64
	engaged int64 // zero means "all of it", which is what most tests want
	epoch   uint32
}

func (f *fakeVotes) PastVotes(who address, at uint32) int64 { return f.weight[string(who)] }
func (f *fakeVotes) PastTotal(at uint32) int64              { return f.total }

// EngagedTotal is the quorum's denominator. Defaults to the whole total, so
// every test that does not care about engagement behaves as it always did; a
// test that does sets engaged and gets a smaller bar.
func (f *fakeVotes) EngagedTotal(at uint32) int64 {
	// Zero means "all of it". Anything else is returned verbatim, INCLUDING a
	// negative: a fake that quietly repaired a bad value would hide the very
	// case the governor refuses at the door.
	if f.engaged != 0 {
		return f.engaged
	}
	return f.total
}
func (f *fakeVotes) Epoch() uint32 { return f.epoch }

// Height satisfies governor.Electorate. These tests drive height with
// testing.SkipHeights, so the chain's own height is the right answer; the
// interface method exists so a REALM can substitute its own clock.
func (f *fakeVotes) Height() int64 { return runtime.ChainHeight() }

// Quorum and threshold are counted at their exact boundaries, at the deadline.
//
// Not by early passage: with most of the electorate silent the outcome is
// genuinely undecided, and a proposal that closed early there would be closing
// on votes nobody cast. The boundary that matters is the final tally.
//
// Off-by-one here is not cosmetic: a comparison that should be >= and is >
// defeats a proposal that met its bar precisely, and the difference only ever
// shows up on the one vote that lands on the line.
func TestTheBarsAreCountedAtTheirExactBoundary(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()

	yes := testutils.TestAddress("q-yes")
	no := testutils.TestAddress("q-no")
	ab := testutils.TestAddress("q-abstain")

	// 1000 in issue. Quorum 30%, threshold 60%.
	// A distinct payload per case: a proposal that has succeeded keeps its slot
	// in the open index until it is executed, so re-asking the identical
	// question is refused — correctly, and it would look like a bug here.
	run := 0
	// The fake the current run was built over. Kept rather than fished back out
	// of the engine: the electorate goes in through the constructor now and
	// there is nothing to type-assert it out of.
	var fake *fakeVotes
	newRun := func() int64 {
		run++
		f := &fakeVotes{
			weight: map[string]int64{
				string(yes): 180, string(no): 120, string(ab): 700,
			},
			total: 1000, epoch: 9,
		}
		fake = f
		engine = governor.New(f, ledger)
		engine.Adopt(setFee{name: "q/kind"}, Rules{
			QuorumBps: 3000, ThresholdBps: 6000, VotingBlocks: 100,
			GraceBlocks: 1_000_000,
		})
		testing.SetRealm(testing.NewUserRealm(yes))
		return Propose(cross(cur), "q/kind", strconv.Itoa(run), "on the line")
	}

	// Exactly quorum: 180+120 = 300 of 1000 is 30.00%, the bar itself.
	// Exactly threshold: 180 of 300 is 60.00%, also the bar itself.
	id := newRun()
	testing.SetRealm(testing.NewUserRealm(yes))
	Vote(cross(cur), id, "yes")
	testing.SetRealm(testing.NewUserRealm(no))
	Vote(cross(cur), id, "no")
	advanceBlocks(200)
	if got := State(id); got != "succeeded" {
		t.Errorf("exactly on both bars = %q, want succeeded — meeting a "+
			"threshold means meeting it, and a > where a >= belongs defeats "+
			"every proposal that lands on the line", got)
	}

	// One vote short of quorum: 299 of 1000. Same yes:no ratio, so only the
	// turnout differs.
	id = newRun()
	f := fake
	f.weight[string(no)] = 119
	testing.SetRealm(testing.NewUserRealm(yes))
	Vote(cross(cur), id, "yes")
	testing.SetRealm(testing.NewUserRealm(no))
	Vote(cross(cur), id, "no")
	advanceBlocks(200)
	if got := State(id); got == "succeeded" {
		t.Errorf("299 of 1000 passed a 30%% quorum")
	}

	// Abstain is turnout but not agreement: it carries quorum and stays out
	// of the threshold entirely.
	id = newRun()
	f = fake
	f.weight[string(yes)] = 1
	f.weight[string(no)] = 0
	testing.SetRealm(testing.NewUserRealm(yes))
	Vote(cross(cur), id, "yes")
	testing.SetRealm(testing.NewUserRealm(ab))
	Vote(cross(cur), id, "abstain")
	advanceBlocks(200)
	if got := State(id); got != "succeeded" {
		t.Errorf("one yes and a large abstain = %q, want succeeded: the "+
			"abstention is turnout, and the threshold is of yes+no alone", got)
	}

	// And a voter with nothing is refused rather than counted as zero.
	id = newRun()
	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("q-nobody")))
	uassert.AbortsContains(t, cur, "no voting power", func() {
		Vote(cross(cur), id, "yes")
	})
}

// A different electorate entirely, with the governor unchanged.
//
// The seam claims that everything in governor.gno, rules.gno and batch.gno is
// about proposals rather than about tokens, and that the only thing tying it to
// this realm's ledger is three methods. That is the argument for the engine
// being reusable, and it had never been tested with anything but this token and
// a fake shaped exactly like it.
//
// So: one address, one vote. No balances, no checkpoints, no delegation — a
// membership roll of the kind a council would keep, which is what
// p/nt/commondao uses and what this design deliberately did not. If quorum,
// threshold, the early-decision arithmetic and the deadline all still behave,
// the seam is real.
type council struct {
	members map[string]bool
	epoch   uint32
}

func (c *council) PastVotes(who address, at uint32) int64 {
	if c.members[string(who)] {
		return 1
	}
	return 0
}
func (c *council) PastTotal(at uint32) int64    { return int64(len(c.members)) }
func (c *council) EngagedTotal(at uint32) int64 { return int64(len(c.members)) }
func (c *council) Epoch() uint32                { return c.epoch }

// Height satisfies governor.Electorate; see the note on fakeVotes.
func (c *council) Height() int64 { return runtime.ChainHeight() }

func TestTheGovernorWorksOnAnElectorateThatIsNotAToken(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()

	a := testutils.TestAddress("council-a")
	b := testutils.TestAddress("council-b")
	c := testutils.TestAddress("council-c")
	engine.SetElectorate(&council{
		members: map[string]bool{string(a): true, string(b): true, string(c): true},
		epoch:   7,
	})

	// Two thirds of three is two, and a third of three is one.
	engine.Adopt(moody{name: "council/thing"}, Rules{
		QuorumBps: 6600, ThresholdBps: 6600, VotingBlocks: 100, GraceBlocks: 1_000_000,
	})
	moodyCheckFails, moodyDoFails, moodyRan = false, false, 0

	testing.SetRealm(testing.NewUserRealm(a))
	id := Propose(cross(cur), "council/thing", "x", "a council decision")

	// One of three is short of a two-thirds quorum, so nothing is decided.
	Vote(cross(cur), id, "yes")
	if got := State(id); got != "active" {
		t.Fatalf("one vote of three is %q, want active — a third cannot reach a "+
			"two-thirds quorum", got)
	}

	// Two of three reaches quorum AND is unbeatable by the third, so the early
	// decision fires on a membership roll exactly as it does on a supply.
	testing.SetRealm(testing.NewUserRealm(b))
	Vote(cross(cur), id, "yes")
	if got := State(id); got != "succeeded" {
		t.Errorf("two votes of three is %q, want succeeded", got)
	}

	// And a non-member has no vote at all, which is the electorate refusing
	// rather than the governor knowing anything about membership.
	stranger := testutils.TestAddress("not-a-member")
	testing.SetRealm(testing.NewUserRealm(stranger))
	id2 := Propose(cross(cur), "council/thing", "y", "another")
	uassert.AbortsContains(t, cur, "no voting power at that epoch", func() {
		Vote(cross(cur), id2, "yes")
	})

	// A defeat works the same way: one for, two against.
	testing.SetRealm(testing.NewUserRealm(a))
	Vote(cross(cur), id2, "yes")
	testing.SetRealm(testing.NewUserRealm(b))
	Vote(cross(cur), id2, "no")
	testing.SetRealm(testing.NewUserRealm(c))
	Vote(cross(cur), id2, "no")
	if got := State(id2); got != "defeated" {
		t.Errorf("one for and two against is %q, want defeated", got)
	}

	// And the deadline, which is the one part of the seam's claim that nothing
	// here exercised. A question nobody answers has to close on the clock
	// rather than sit open forever, and on a council that means the turnout bar
	// is measured against a member count instead of a supply.
	//
	// Nobody votes on this one, so it cannot be decided early: with three
	// members unheard from, the threshold is still reachable and the
	// early-defeat arithmetic correctly leaves it alone. The clock is the only
	// thing that can end it.
	testing.SetRealm(testing.NewUserRealm(a))
	id3 := Propose(cross(cur), "council/thing", "z", "one nobody answers")
	if got := State(id3); got != "active" {
		t.Fatalf("an unanswered proposal is %q before its deadline, want active", got)
	}
	advanceBlocks(200)
	if got := State(id3); got != "defeated" {
		t.Errorf("an unanswered proposal is %q after its deadline, want "+
			"defeated — a council question with no answer has to close on the "+
			"clock, and the turnout it failed is a fraction of the roll", got)
	}
}

// A defeat that is certain closes at once, like a victory that is certain.
//
// The early-success rule has been there from the start, with a comment saying
// waiting out the clock on a settled question is latency and not deliberation.
// The same sentence applies to a loss and the code did not — a decided YES
// closed immediately while a decided NO sat out its deadline, holding one of
// sixty-four slots and asking a question that had already been answered.
//
// This side is the commoner one, because a proposal that is going to lose
// usually loses by everybody ignoring it.
func TestADecidedDefeatDoesNotWaitOutTheClock(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()

	a := testutils.TestAddress("d-a")
	b := testutils.TestAddress("d-b")
	c := testutils.TestAddress("d-c")
	engine.SetElectorate(&council{
		members: map[string]bool{string(a): true, string(b): true, string(c): true},
		epoch:   7,
	})
	engine.Adopt(moody{name: "council/thing"}, Rules{
		QuorumBps: 6600, ThresholdBps: 6600, VotingBlocks: 100000, GraceBlocks: 1_000_000,
	})
	moodyCheckFails, moodyDoFails, moodyRan = false, false, 0

	testing.SetRealm(testing.NewUserRealm(a))
	id := Propose(cross(cur), "council/thing", "doomed", "will lose")

	// One against, two still to vote: not settled — both could vote yes and
	// carry it, so the question is live.
	Vote(cross(cur), id, "no")
	if got := State(id); got != "active" {
		t.Fatalf("one vote against of three is %q, want active — the other two "+
			"could still carry it", got)
	}

	// Two against. Even if the last member votes yes, one of three cannot
	// reach two thirds, so the answer is fixed and the proposal closes now
	// rather than in a hundred thousand blocks.
	testing.SetRealm(testing.NewUserRealm(b))
	Vote(cross(cur), id, "no")
	if got := State(id); got != "defeated" {
		t.Errorf("two against of three is %q, want defeated — the last vote "+
			"cannot change it", got)
	}
	if r := engine.Reason(id); r != "threshold can no longer be reached" {
		t.Errorf("it was defeated for %q, which does not say why it closed "+
			"early", engine.Reason(id))
	}

	// And the slot came back, which is the point: a list bounded at governor.MaxLive
	// should not be held by settled business.
	if State(id) == "active" {
		t.Error("a settled defeat is still holding its slot")
	}

	// The last member cannot vote on it, because it is over.
	testing.SetRealm(testing.NewUserRealm(c))
	uassert.AbortsContains(t, cur, "that proposal is closed", func() {
		Vote(cross(cur), id, "yes")
	})
}

// The tally is exercised at the supply ceiling, where it was designed to just
// barely fit.
//
// grc20votes.MaxSupply exists because yes*bps overflows int64 above MaxInt64/bps, and a
// wrapped tally does not fail loudly — it goes negative, and a vote that was
// won gets reported as lost. The cap was chosen to make that impossible.
//
// What was checked was the CAP: that minting stops there, and that
// grc20votes.MaxSupply*bps is still positive. What was never checked is a vote actually
// counted at it, through every branch that multiplies — and the early-defeat
// rule added two more multiplications to that path, which is the kind of change
// that quietly reintroduces the bug a bound was created to prevent.
//
// Driven through the fake electorate rather than by minting the cap, because
// this is about the governor's arithmetic and not the ledger's.
func TestTheTallyHoldsAtTheSupplyCeiling(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()

	whale := testutils.TestAddress("q-whale")
	minnow := testutils.TestAddress("q-minnow")

	// The whole supply, at the cap, held by one address.
	engine.SetElectorate(&fakeVotes{
		weight: map[string]int64{string(whale): grc20votes.MaxSupply},
		total:  grc20votes.MaxSupply, epoch: 9,
	})
	engine.Adopt(moody{name: "ceiling/thing"}, Rules{
		QuorumBps: 6600, ThresholdBps: 6600, VotingBlocks: 1000, GraceBlocks: 1_000_000,
	})
	moodyCheckFails, moodyDoFails, moodyRan = false, false, 0

	testing.SetRealm(testing.NewUserRealm(whale))
	id := Propose(cross(cur), "ceiling/thing", "everything", "the whole supply votes")
	Vote(cross(cur), id, "yes")
	if got := State(id); got != "succeeded" {
		t.Errorf("the entire supply voting yes is %q, want succeeded — at the "+
			"cap the tally is one multiplication away from MaxInt64, and a "+
			"wrapped one reports a win as a loss", got)
	}
	yes, no, ab, total := Tally(id)
	if yes != grc20votes.MaxSupply || no != 0 || ab != 0 || total != grc20votes.MaxSupply {
		t.Errorf("Tally at the ceiling = %d/%d/%d of %d, want %d/0/0 of %d",
			yes, no, ab, total, grc20votes.MaxSupply, grc20votes.MaxSupply)
	}

	// And the early-defeat arithmetic at the same scale: a third for, two
	// thirds against, nothing left to cast.
	resetLedger()
	third := grc20votes.MaxSupply / 3
	engine.SetElectorate(&fakeVotes{
		weight: map[string]int64{string(whale): grc20votes.MaxSupply - third, string(minnow): third},
		total:  grc20votes.MaxSupply, epoch: 9,
	})
	engine.Adopt(moody{name: "ceiling/thing"}, Rules{
		QuorumBps: 6600, ThresholdBps: 6600, VotingBlocks: 1000, GraceBlocks: 1_000_000,
	})
	testing.SetRealm(testing.NewUserRealm(minnow))
	id2 := Propose(cross(cur), "ceiling/thing", "doomed", "a third in favour")
	Vote(cross(cur), id2, "yes")
	testing.SetRealm(testing.NewUserRealm(whale))
	Vote(cross(cur), id2, "no")
	if got := State(id2); got != "defeated" {
		t.Errorf("a third for and two thirds against at the ceiling is %q, want "+
			"defeated", got)
	}

	// Every number the page reports is still positive, which is the symptom a
	// wrap would show.
	y, n, _, tot := Tally(id2)
	if y <= 0 || n <= 0 || tot <= 0 {
		t.Errorf("the tally went non-positive at the ceiling: %d/%d of %d", y, n, tot)
	}
}

// Nothing passes without somebody voting for it.
//
// Abstain is documented as turnout without support: it counts towards quorum
// and stays out of the threshold. It did not stay out. The threshold compares
// yes against yes+no, and when everybody abstains both are zero — so the
// comparison was 0 >= 0, and the proposal passed IMMEDIATELY, with nobody in
// favour, on the strength of an empty denominator.
//
// A governance proposal carried by an empty denominator is the worst shape a
// bug can take here: every number on the page is correct, the state is
// "succeeded", and no arithmetic a reader checks disagrees with it.
func TestNothingPassesWithoutSomebodyInFavour(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()

	a := testutils.TestAddress("ab-a")
	b := testutils.TestAddress("ab-b")
	engine.SetElectorate(&fakeVotes{
		weight: map[string]int64{string(a): 60, string(b): 40},
		total:  100, epoch: 9,
	})
	moodyCheckFails, moodyDoFails, moodyRan = false, false, 0
	engine.Adopt(moody{name: "ab/thing"}, Rules{
		QuorumBps: 2000, ThresholdBps: 6600, VotingBlocks: 50, GraceBlocks: 1_000_000,
	})

	// Everybody turns out, nobody supports it.
	testing.SetRealm(testing.NewUserRealm(a))
	id := Propose(cross(cur), "ab/thing", "x", "nobody is in favour")
	Vote(cross(cur), id, "abstain")
	testing.SetRealm(testing.NewUserRealm(b))
	Vote(cross(cur), id, "abstain")

	if got := State(id); got != "defeated" {
		t.Fatalf("with the whole electorate abstaining the proposal is %q, "+
			"want defeated — nobody voted for it", got)
	}
	if r := engine.Reason(id); r != "nobody voted in favour" {
		t.Errorf("it was defeated for %q, which does not say what happened",
			engine.Reason(id))
	}
	// The deadline never arrives; it was settled the moment the last vote
	// landed, because nothing could change it.
	advanceBlocks(100)
	if got := State(id); got != "defeated" {
		t.Errorf("after the deadline it is %q", got)
	}

	// A threshold of zero does not change it. "Passes on any support" still
	// requires support.
	//
	// resetLedger puts the REAL electorate back — it resets voters along with
	// the trees — so the fake has to be restored after each one, or the next
	// Propose is refused with "nothing was in issue at that epoch". The name
	// says ledger; it resets the governor too.
	resetLedger()
	engine.SetElectorate(&fakeVotes{
		weight: map[string]int64{string(a): 60, string(b): 40},
		total:  100, epoch: 9,
	})
	engine.Adopt(moody{name: "ab/thing"}, Rules{
		QuorumBps: 2000, ThresholdBps: 0, VotingBlocks: 50, GraceBlocks: 1_000_000,
	})
	testing.SetRealm(testing.NewUserRealm(a))
	id2 := Propose(cross(cur), "ab/thing", "y", "a bar on the floor")
	Vote(cross(cur), id2, "abstain")
	testing.SetRealm(testing.NewUserRealm(b))
	Vote(cross(cur), id2, "abstain")
	if got := State(id2); got != "defeated" {
		t.Errorf("with a zero threshold and no support the proposal is %q, "+
			"want defeated", got)
	}

	// The other way to reach a deadline with no support: enough abstentions to
	// clear quorum, and plenty of votes still uncast — so the early defeat
	// cannot fire, because somebody could still turn up in favour. Nobody
	// does, and it runs out of clock with yes at zero.
	//
	// This is the case the guard at the DEADLINE exists for, and the
	// all-abstained test above cannot reach it: there, nothing was left to
	// cast, so it was settled before the clock mattered.
	resetLedger()
	engine.SetElectorate(&fakeVotes{
		weight: map[string]int64{string(a): 60, string(b): 40},
		total:  1000, epoch: 9, // most of the electorate never votes
	})
	engine.Adopt(moody{name: "ab/thing"}, Rules{
		QuorumBps: 500, ThresholdBps: 6600, VotingBlocks: 50, GraceBlocks: 1_000_000,
	})
	testing.SetRealm(testing.NewUserRealm(a))
	idQ := Propose(cross(cur), "ab/thing", "q", "quorum by abstention alone")
	Vote(cross(cur), idQ, "abstain")
	if got := State(idQ); got != "active" {
		t.Fatalf("with 940 votes uncast the proposal is %q, want active — "+
			"somebody could still vote for it", got)
	}
	advanceBlocks(100)
	if got := State(idQ); got != "defeated" {
		t.Errorf("a proposal that reached its deadline on abstentions alone is "+
			"%q, want defeated — sixty of a thousand abstaining cleared the "+
			"five percent quorum, and nobody voted in favour", got)
	}

	// And one vote in favour is enough to carry that one, so the guard refuses
	// nothing it should allow.
	resetLedger()
	engine.SetElectorate(&fakeVotes{
		weight: map[string]int64{string(a): 60, string(b): 40},
		total:  100, epoch: 9,
	})
	engine.Adopt(moody{name: "ab/thing"}, Rules{
		QuorumBps: 2000, ThresholdBps: 0, VotingBlocks: 50, GraceBlocks: 1_000_000,
	})
	testing.SetRealm(testing.NewUserRealm(b))
	id3 := Propose(cross(cur), "ab/thing", "z", "one voice for")
	Vote(cross(cur), id3, "yes")
	if got := State(id3); got != "succeeded" {
		t.Errorf("forty of a hundred in favour against a zero threshold is "+
			"%q, want succeeded", got)
	}
}

// A broken electorate settles on its first vote, which is the failure mode and
// not a bug to be fixed here.
//
// This realm's token cannot reach the state — everybody's power sums to the
// supply exactly, and there is a test for it after every operation that moves
// any. But the documented way to reuse this governor is to fork it and swap the
// electorate, so what happens with a wrong one is worth knowing and worth
// pinning.
//
// What happens: the first vote decides. The arithmetic for "no remaining vote
// could change this" works from a total that is not true, so it concludes
// early and confidently. Clamping the tally does not help: yes*bps beats
// yes*Threshold whenever the threshold is under a hundred percent, so the first
// voter carries it either way.
//
// The lesson is on the electorate interface: the governor cannot check this
// and cannot recover from it. This test exists so that the failure is
// documented behaviour rather than a surprise.
func TestABrokenElectorateSettlesOnItsFirstVote(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()

	// Every caller holds a hundred; the whole electorate is ten.
	a := testutils.TestAddress("br-a")
	b := testutils.TestAddress("br-b")
	engine.SetElectorate(&fakeVotes{
		weight: map[string]int64{string(a): 100, string(b): 100},
		total:  10, epoch: 9,
	})
	engine.Adopt(moody{name: "broken/thing"}, Rules{
		QuorumBps: 6600, ThresholdBps: 9900, VotingBlocks: 50, GraceBlocks: 1_000_000,
	})
	moodyCheckFails, moodyDoFails, moodyRan = false, false, 0

	testing.SetRealm(testing.NewUserRealm(a))
	id := Propose(cross(cur), "broken/thing", "x", "over a broken roll")
	Vote(cross(cur), id, "yes")

	// Carried by one voter at a ninety-nine percent threshold, with an equal
	// holder still unheard. That is what a roll whose parts exceed its whole
	// does to a governor, and no arithmetic here can undo it.
	if got := State(id); got != "succeeded" {
		t.Fatalf("over a broken electorate the first vote left it %q; this "+
			"test records what such a roll does, so a change here means the "+
			"failure mode moved and the interface note needs rewriting", got)
	}
	testing.SetRealm(testing.NewUserRealm(b))
	uassert.AbortsContains(t, cur, "that proposal is closed", func() {
		Vote(cross(cur), id, "no")
	})

	// Every number it reports is still a number, which is the least it owes a
	// reader.
	yes, no, ab, total := Tally(id)
	if yes < 0 || no < 0 || ab < 0 || total < 0 {
		t.Errorf("the tally went negative: %d/%d/%d of %d", yes, no, ab, total)
	}
}

// Early defeat has a boundary too, and it is the one the success side already
// had a test for.
//
// A proposal is abandoned as soon as the threshold cannot be reached even with
// every remaining vote in favour. "Cannot be reached" has to mean strictly
// short of the bar, because meeting a threshold exactly is meeting it — the
// success check says so with a >=, and the two have to agree about the line
// they share or a question dies on the arithmetic that would have carried it.
//
// The numbers are chosen to land exactly there. With a 60% threshold the best
// possible outcome equals the bar when the unvoted remainder is one and a half
// times the no vote, so 400 against and 600 unheard from is the case: 600 of a
// possible 1000 is 60.00%, the bar itself.
func TestAProposalThatCanStillExactlyReachTheThresholdSurvives(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()

	yes := testutils.TestAddress("edge-yes")
	no := testutils.TestAddress("edge-no")
	engine.SetElectorate(&fakeVotes{
		weight: map[string]int64{string(yes): 600, string(no): 400},
		total:  1000, epoch: 9,
	})
	engine.Adopt(setFee{name: "edge/kind"}, Rules{
		QuorumBps: 3000, ThresholdBps: 6000, VotingBlocks: 100, GraceBlocks: 1_000_000,
	})

	testing.SetRealm(testing.NewUserRealm(yes))
	id := Propose(cross(cur), "edge/kind", "1", "on the line, against")

	testing.SetRealm(testing.NewUserRealm(no))
	Vote(cross(cur), id, "no")

	// 400 against, 600 not yet heard from. The best case is exactly 60%, so the
	// threshold CAN still be reached and the question is still open.
	if got := State(id); got != "active" {
		t.Fatalf("state = %q, want active — the best remaining outcome lands "+
			"exactly on the threshold, and a <= where a < belongs abandons "+
			"every proposal that could still just reach its bar", got)
	}

	// And it really can be won from there, which is what makes the survival
	// meaningful rather than a stay of execution.
	testing.SetRealm(testing.NewUserRealm(yes))
	Vote(cross(cur), id, "yes")
	if got := State(id); got != "succeeded" {
		t.Errorf("state = %q, want succeeded — 600 yes to 400 no is 60.00%%, "+
			"the bar itself", got)
	}
}

// Quorum divides by the ENGAGED weight; everything else still divides by the
// whole supply.
//
// An electorate may drop idle weight out of the bar — a fixed low quorum is
// unreachable at launch and trivial later, and moving the denominator is what
// keeps it meaningful at both ends. The bookkeeping belongs to whoever
// implements the interface; the governor only has to divide by the right
// number.
//
// Weight outside the engaged set can still VOTE. It simply is not counted in
// the bar, which is why "votes that could still be cast" stays on the total: a
// proposal must not close early on the belief that silent weight cannot arrive.
func TestQuorumDividesByTheEngagedWeightNotTheWholeSupply(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()

	a := testutils.TestAddress("eng-a")
	idle := testutils.TestAddress("eng-idle")
	// A thousand in issue, a hundred of it engaged. A 50% quorum is 500 against
	// the supply and 50 against the engaged part.
	engine.SetElectorate(&fakeVotes{
		weight:  map[string]int64{string(a): 60, string(idle): 940},
		total:   1000,
		engaged: 100,
		epoch:   9,
	})
	engine.Adopt(setFee{name: "eng/kind"}, Rules{
		QuorumBps: 5000, ThresholdBps: 5000, VotingBlocks: 100, GraceBlocks: 100,
	})

	testing.SetRealm(testing.NewUserRealm(a))
	id := Propose(cross(cur), "eng/kind", "1", "sixty of a thousand")
	Vote(cross(cur), id, "yes")
	advanceBlocks(200)

	// Sixty is 6% of the supply and 60% of the engaged weight. Against the
	// supply this fails quorum; against the engaged part it clears it.
	if got := State(id); got != "succeeded" {
		t.Errorf("a turnout of 60 against 100 engaged is %q, want succeeded — "+
			"quorum is still dividing by the whole supply", got)
	}

	// And the page says what it measured against, or a reader checks the
	// arithmetic and gets a different answer from the realm.
	if page := Render(strconv.FormatInt(id, 10)); !strings.Contains(page, "turnout 60 of 100,") {
		t.Errorf("the page reports turnout against something other than the "+
			"engaged weight:\n%s", page)
	}

	// The early-close arithmetic is unchanged: it still asks what the whole
	// supply could yet do. Idle weight can vote, so a proposal must not settle
	// on the belief that it cannot.
	engine.SetElectorate(&fakeVotes{
		weight:  map[string]int64{string(a): 60, string(idle): 940},
		total:   1000,
		engaged: 100,
		epoch:   9,
	})
	testing.SetRealm(testing.NewUserRealm(a))
	open := Propose(cross(cur), "eng/kind", "2", "still open")
	Vote(cross(cur), open, "yes")
	if got := State(open); got != "active" {
		t.Errorf("state is %q before the deadline, want active: 940 unheard-from "+
			"could still outvote 60, and dividing 'what could still be cast' by "+
			"the engaged weight would close this early", got)
	}
	// The idle holder votes, and it counts.
	testing.SetRealm(testing.NewUserRealm(idle))
	Vote(cross(cur), open, "no")
	if _, no, _, _ := Tally(open); no != 940 {
		t.Errorf("unengaged weight voted %d, want 940 — engagement is a bar, "+
			"not a franchise", no)
	}
}

// An electorate that engages nobody is refused at the door; one that engages
// MORE than exists is clamped down to the snapshot supply, so the bar is
// unreachable-but-valid rather than the proposal aborting. A court deliberately
// hosts claims too big for its electorate to decide, so an over-large engaged
// weight must not abort — it must simply make quorum unreachable.
func TestAnImpossibleEngagedWeightIsClamped(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()

	a := testutils.TestAddress("eng-bad")
	engine.Adopt(setFee{name: "bad/kind"}, Rules{
		QuorumBps: 5000, ThresholdBps: 5000, VotingBlocks: 100, GraceBlocks: 100,
	})

	// Engages more than exists: clamped to the total, the proposal proceeds, and
	// the snapshot reports the clamped figure.
	engine.SetElectorate(&fakeVotes{weight: map[string]int64{string(a): 10}, total: 100, engaged: 1000, epoch: 9})
	testing.SetRealm(testing.NewUserRealm(a))
	id := Propose(cross(cur), "bad/kind", "1", "engages more than exists")
	if engaged, _ := engine.Snapshot(id); engaged != 100 {
		t.Errorf("engaged weight should clamp to the total 100, got %d", engaged)
	}

	// Engages nobody (non-positive): still refused at the door.
	engine.SetElectorate(&fakeVotes{weight: map[string]int64{string(a): 10}, total: 100, engaged: -1, epoch: 9})
	testing.SetRealm(testing.NewUserRealm(a))
	uassert.AbortsContains(t, cur, "has to be positive", func() {
		Propose(cross(cur), "bad/kind", "2", "engages nobody")
	})
}
