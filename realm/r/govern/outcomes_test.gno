package govern

import (
	"chain/runtime"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// moody is a kind whose answer changes with the world.
type moody struct{}

var (
	moodyCheckFails bool
	moodyDoFails    bool
	moodyRan        int
)

func (moody) Name() string             { return "moody/thing" }
func (moody) Describe(p string) string { return "do the moody thing: " + p }

func (moody) Check(p string) error {
	if moodyCheckFails {
		if moodyErrText != "" {
			return govErr(moodyErrText)
		}
		return govErr("the world moved")
	}
	return nil
}

// moodyPanics makes Do panic AFTER doing some of its work, which is how a
// buggy handler fails rather than the tidy error return every test uses.
var moodyPanics bool

func (moody) Do(_ int, rlm realm, p string) error {
	moodyRan++
	if moodyPanics {
		panic("moody: something went wrong halfway")
	}
	if moodyDoFails {
		if moodyErrText != "" {
			return govErr(moodyErrText)
		}
		return govErr("it did not work")
	}
	return nil
}

// moodyErrText lets a test choose how long the failure message is, which is
// the only way to reach the clip on the way into the record.
var moodyErrText string

// moodVoter is the only holder in these tests' stated electorate.
var moodVoter = testutils.TestAddress("mood-voter")

// arm sets up the electorate and the kind, and does no more than that.
//
// Deliberately not the proposing and voting as well: testing.SetRealm is keyed
// by FRAME INDEX, so called from a helper the override lands on the helper's
// caller and the next crossing call from the test body stops being a user
// call. Whatever a test needs SetRealm for has to be written in the test body.
// A helper also may not take a realm named cur — only the first realm argument
// of a crossing function may be called that — which is the other half of why
// this one arms state and returns.
func arm(rules Rules) {
	voters = &fakeVotes{
		weight: map[string]int64{string(moodVoter): 100},
		total:  100, epoch: 9,
	}
	kinds.Set("moody/thing", &entry{kind: moody{}, live: true, rules: rules})
}

// Check runs twice: when the proposal opens, and again immediately before Do.
//
// The second call is the whole point and has been argued for since the design
// note without ever being shown. A proposal sound a week ago need not be sound
// now, and the alternative to re-checking is discovering that inside Do, with
// half of it already applied.
func TestAProposalIsCheckedAgainBeforeItRuns(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	real_ := voters
	defer func() { voters = real_; moodyCheckFails, moodyDoFails = false, false }()

	moodyCheckFails, moodyDoFails, moodyRan = false, false, 0
	arm(Rules{QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 10})
	testing.SetRealm(testing.NewUserRealm(moodVoter))
	id := Propose(cross(cur), "moody/thing", "a", "moody")
	Vote(cross(cur), id, "yes")
	if got := State(id); got != "succeeded" {
		t.Fatalf("the proposal is %q, want succeeded", got)
	}

	// The world moves between the vote and the execution.
	moodyCheckFails = true
	Execute(cross(cur), id)

	if got := State(id); got != "failed" {
		t.Fatalf("state = %q, want failed", got)
	}
	if moodyRan != 0 {
		t.Errorf("Do ran %d times on a proposal that no longer checks out — the "+
			"second Check exists precisely so it does not", moodyRan)
	}
	if p := mustProposal(id); p.reason == "" {
		t.Error("a failure with no reason recorded")
	}
}

// A handler that fails records the failure and finishes, rather than leaving
// the proposal to be retried forever.
func TestAFailingHandlerEndsTheProposal(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	real_ := voters
	defer func() { voters = real_; moodyCheckFails, moodyDoFails = false, false }()

	moodyCheckFails, moodyDoFails, moodyRan = false, true, 0
	arm(Rules{QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 10})
	testing.SetRealm(testing.NewUserRealm(moodVoter))
	id := Propose(cross(cur), "moody/thing", "b", "moody")
	Vote(cross(cur), id, "yes")
	Execute(cross(cur), id)

	if got := State(id); got != "failed" {
		t.Fatalf("state = %q, want failed", got)
	}
	if moodyRan != 1 {
		t.Errorf("Do ran %d times, want 1", moodyRan)
	}
	// And it is finished: a second attempt is refused rather than running the
	// handler again.
	uassert.AbortsContains(t, cur, "not waiting to be executed", func() {
		Execute(cross(cur), id)
	})
	if moodyRan != 1 {
		t.Errorf("a finished proposal ran its handler again (%d times)", moodyRan)
	}
}

// The delay is a delay. Nothing runs inside it, however decided the vote.
func TestNothingRunsInsideTheDelay(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	real_ := voters
	defer func() { voters = real_ }()

	moodyCheckFails, moodyDoFails, moodyRan = false, false, 0
	arm(Rules{QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 10, DelayBlocks: 5000})
	testing.SetRealm(testing.NewUserRealm(moodVoter))
	id := Propose(cross(cur), "moody/thing", "c", "moody")
	Vote(cross(cur), id, "yes")
	uassert.AbortsContains(t, cur, "still in the delay window", func() {
		Execute(cross(cur), id)
	})
	if moodyRan != 0 {
		t.Errorf("the handler ran inside the delay")
	}

	advanceBlocks(6000)
	Execute(cross(cur), id)
	if got := State(id); got != "executed" {
		t.Fatalf("after the delay = %q, want executed", got)
	}
}

// The roll survives until the kind has had its turn with it.
//
// ReleaseRoll refuses an open proposal for an obvious reason — the roll is what
// refuses a second vote. The second window is less obvious and is the one worth
// a test: between succeeding and executing, the proposal is finished as far as
// voting goes, but the kind has not run yet, and Execute is where a kind that
// pays out to the people who voted reads them. Releasing there is free to do,
// permissionless like everything else here, and would leave the kind with an
// empty roll.
//
// So a stranger tries it in that window and is refused, and the same stranger
// succeeds the moment the kind has run.
func TestTheRollCannotBeReclaimedOutFromUnderTheKind(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	real_ := voters
	defer func() { voters = real_ }()

	moodyCheckFails, moodyDoFails, moodyRan = false, false, 0
	arm(Rules{QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 10, DelayBlocks: 50})
	testing.SetRealm(testing.NewUserRealm(moodVoter))
	id := Propose(cross(cur), "moody/thing", "c", "moody")
	Vote(cross(cur), id, "yes")
	if got := State(id); got != "succeeded" {
		t.Fatalf("the proposal is %q; this test needs one waiting to run", got)
	}

	testing.SetRealm(testing.NewUserRealm(gCarl))
	uassert.AbortsContains(t, cur, "has not run yet", func() {
		ReleaseRoll(cross(cur), id)
	})
	if p := mustProposal(id); p.voted == nil {
		t.Fatal("the roll went anyway, so the kind will run against nothing")
	}

	advanceBlocks(60)
	Execute(cross(cur), id)
	if moodyRan != 1 {
		t.Fatalf("the kind ran %d times, so what follows proves nothing", moodyRan)
	}
	// Now it is nobody's, and carl takes the deposit for tidying up.
	ReleaseRoll(cross(cur), id)
	if p := mustProposal(id); p.voted != nil {
		t.Error("an executed proposal would not give up its roll")
	}
}

// A proposal nobody executes stops being executable.
//
// It is a decision about a world that has moved on, and gno's own govdao had
// to bolt on a reject path precisely because proposals could otherwise sit
// forever.
func TestAnUnexecutedProposalExpires(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	real_ := voters
	defer func() { voters = real_ }()

	moodyCheckFails, moodyDoFails, moodyRan = false, false, 0
	arm(Rules{
		QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 10,
		DelayBlocks: 10, GraceBlocks: 100,
	})
	testing.SetRealm(testing.NewUserRealm(moodVoter))
	id := Propose(cross(cur), "moody/thing", "d", "moody")
	Vote(cross(cur), id, "yes")

	advanceBlocks(10000)
	if got := State(id); got != "expired" {
		t.Fatalf("state = %q, want expired", got)
	}
	uassert.AbortsContains(t, cur, "not waiting to be executed", func() {
		Execute(cross(cur), id)
	})
	if moodyRan != 0 {
		t.Errorf("an expired proposal still ran")
	}
	// And its slot is back, so an expired proposal does not sterilise the list.
	if openIdx.Has(digest("moody/thing", "d")) {
		t.Error("an expired proposal is still holding its slot")
	}
}

// The delay runs from when the outcome is RECORDED, not from when the votes
// stopped mattering.
//
// Those were the same thing before reads stopped writing: a decisive vote
// settled itself in the same transaction. They come apart for a proposal that
// wins on its deadline instead, because nobody has to be there when a deadline
// passes — the outcome is then only computed by the next read and only written
// by the next transaction.
//
// Pinned because it is a real answer to a question a reader would guess the
// other way, and because it decides who waits: the timelock cannot be shortened
// by leaving a proposal unnoticed, and it cannot be started by anybody except
// somebody willing to send a transaction saying so. Settle is permissionless
// precisely so that is never a privileged position.
func TestTheDelayRunsFromWhenTheOutcomeIsRecorded(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = moodVoter
	quiet := testutils.TestAddress("d-quiet")
	testing.SetRealm(testing.NewUserRealm(moodVoter))
	// 400 of 1000, against a 30% quorum and a 50% threshold. That clears
	// quorum, so it can win — but not decisively: the 600 still uncast could
	// all vote no and beat it, so the outcome waits for the deadline, which is
	// the case where the two readings of "when does the delay start" differ.
	Mint(cross(cur), moodVoter, 400)
	Mint(cross(cur), quiet, 600)
	advanceEpochs(1)

	moodyCheckFails, moodyDoFails, moodyRan = false, false, 0
	kinds.Set("moody/thing", &entry{kind: moody{}, live: true, rules: Rules{
		QuorumBps: 3000, ThresholdBps: 5000, VotingBlocks: 100, DelayBlocks: 1000,
	}})
	testing.SetRealm(testing.NewUserRealm(moodVoter))
	id := Propose(cross(cur), "moody/thing", "e", "deadline win")
	Vote(cross(cur), id, "yes")
	if got := State(id); got != "active" {
		t.Fatalf("with 400 still uncast the outcome is not settled: %q", got)
	}

	// The deadline passes with nobody watching, and a long time goes by.
	advanceBlocks(50000)
	if got := State(id); got != "succeeded" {
		t.Fatalf("after the deadline a reader sees %q, want succeeded", got)
	}

	// Recording it now starts the clock now. Executing immediately is refused
	// even though the vote concluded fifty thousand blocks ago.
	Settle(cross(cur), id)
	uassert.AbortsContains(t, cur, "still in the delay window", func() {
		Execute(cross(cur), id)
	})
	if moodyRan != 0 {
		t.Fatal("the handler ran without waiting out the delay")
	}

	advanceBlocks(1001)
	Execute(cross(cur), id)
	if got := State(id); got != "executed" {
		t.Fatalf("after the delay = %q, want executed", got)
	}
}

// The windows are counted at their exact block, the way the bars are counted
// at their exact vote.
//
// Quorum and threshold have had a boundary test for a long time. The clock did
// not, and two off-by-ones lived there in perfect comfort: voting that stayed
// open one block past its deadline, and a grace period that ended one block
// early. Every other test in this file passes with both of them in, because
// every other test asks its question from the middle of a window where being
// one block out changes no answer.
func TestTheWindowsAreCountedAtTheirExactBlock(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	real_ := voters
	defer func() { voters = real_ }()
	moodyCheckFails, moodyDoFails, moodyRan = false, false, 0

	// Nobody votes on this one, so the deadline is the only thing that can
	// decide it and the only question left is which block it lands on.
	// Deliberately not a round number, and not one any other test uses. Reusing
	// the 10 that every other rules literal in this file carries would let a
	// window that ignored the rule and hardcoded a constant match by
	// coincidence.
	const window = int64(37)
	arm(Rules{QuorumBps: 5000, ThresholdBps: 5000, VotingBlocks: window})
	testing.SetRealm(testing.NewUserRealm(moodVoter))
	id := Propose(cross(cur), "moody/thing", "closing", "moody")

	// Pinned before anything is measured against it. The two assertions below
	// read the deadline off the proposal, which makes them a statement about
	// WHICH block ends the window and not about how long it is — so without
	// this line a window of the wrong length moves both of them together and
	// neither can fail. Same trap the archive-paging test documents: an
	// assertion parameterised by the thing it is checking cannot fail.
	p0 := mustProposal(id)
	if got := p0.closes - p0.opened; got != window {
		t.Fatalf("the voting window is %d blocks against the %d the rules asked "+
			"for, so every deadline in the system is off by %d",
			got, window, got-window)
	}
	closes := p0.closes

	advanceTo(closes - 1)
	if got := State(id); got != "active" {
		t.Errorf("one block before the deadline the state is %q, want active — "+
			"the last block of the voting window is not votable", got)
	}
	advanceTo(closes)
	if got := State(id); got != "defeated" {
		t.Errorf("on the deadline block the state is %q, want defeated — the "+
			"window stays open a block longer than the rules say it does", got)
	}

	// Grace is measured from when the outcome was written down, so this one
	// has to succeed before there is anything to measure.
	const grace = int64(61)
	arm(Rules{
		QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 10,
		DelayBlocks: 5, GraceBlocks: grace,
	})
	id2 := Propose(cross(cur), "moody/thing", "grace", "moody")
	Vote(cross(cur), id2, "yes")
	p := mustProposal(id2)
	if p.state != stateSucceeded {
		t.Fatal("the second proposal did not succeed on the vote, so there is " +
			"no grace period here to measure and the rest of this proves nothing")
	}
	// The literal, not p.rules.GraceBlocks, for the reason given above: read
	// back from the proposal it would track a wrong value instead of catching
	// it.
	last := p.ready + grace

	advanceTo(last)
	if got := State(id2); got != "succeeded" {
		t.Errorf("on the last block of the grace period the state is %q, want "+
			"succeeded — an execution the rules still allow would be refused", got)
	}
	advanceTo(last + 1)
	if got := State(id2); got != "expired" {
		t.Errorf("one block past the grace period the state is %q, want expired", got)
	}

	// And the delay, which sits between the two above and had no boundary of
	// its own. Moving it a block early passed every test in this suite,
	// including both halves of this one: the voting deadline and the grace
	// period are measured from different marks, so neither notices.
	//
	// A timelock is the one window where being a block out is not a rounding
	// difference. It exists so somebody who dislikes a decision can act before
	// it takes effect, and an execution that lands early is one that lands
	// before the last person watching the clock expected it to be possible.
	const delay = int64(29)
	arm(Rules{
		QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 10,
		DelayBlocks: delay, GraceBlocks: 500,
	})
	id3 := Propose(cross(cur), "moody/thing", "delay", "moody")
	settledAt := runtime.ChainHeight()
	Vote(cross(cur), id3, "yes")
	p3 := mustProposal(id3)
	if p3.state != stateSucceeded {
		t.Fatal("the third proposal did not succeed on the vote, so there is " +
			"no timelock here to measure")
	}
	// Pinned before anything is measured against it, for the same reason the
	// voting window is: read the mark off the proposal and a delay of the wrong
	// length moves both assertions together, so neither can fail.
	if got := p3.ready - settledAt; got != delay {
		t.Fatalf("the timelock is %d blocks against the %d the rules asked for",
			got, delay)
	}

	advanceTo(p3.ready - 1)
	uassert.AbortsContains(t, cur, "still in the delay window", func() {
		Execute(cross(cur), id3)
	})
	// The PAGE at the same two blocks. Execute and the page must not each test
	// `now < ready` for themselves: a boundary moved on one side only leaves
	// the page offering to run what Execute refuses, or counting down past a
	// block it can already be run at.
	if page := Render("3"); !strings.Contains(page, "Waiting") {
		t.Errorf("one block before the timelock ends the page does not say it "+
			"is waiting:\n%s", page)
	}
	advanceTo(p3.ready)
	if page := Render("3"); !strings.Contains(page, "Executable now") {
		t.Errorf("on the first executable block the page still says waiting, so "+
			"it disagrees with Execute by a block:\n%s", page)
	}
	uassert.NotAborts(t, cur, func() {
		Execute(cross(cur), id3)
	})
	if got := State(id3); got != "executed" {
		t.Errorf("on the first block past the timelock the state is %q, want "+
			"executed — the delay lasts a block longer than the rules say", got)
	}
}

// A chain too young to have sealed an epoch cannot hold a vote, and says so.
//
// Weight is read at a SEALED epoch, and before the first one closes there is no
// electorate to read — not an empty one, an unanswerable one. The distinction
// matters: treating it as nobody-holding-anything would open proposals that are
// instantly quorum-failed, which reads as the holders declining rather than as
// the question being premature.
//
// This lives here rather than only in the chain tests because on a chain it can
// be observed exactly once. A chain passes its first epoch and never comes
// back, so an assertion that needs a young one runs on a fresh node and silently
// stops running afterwards.
func TestAChainTooYoungToHaveSealedAnEpochCannotVote(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	real_ := voters
	defer func() { voters = real_ }()

	arm(Rules{QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 10})
	// Epoch 1 is the first epoch, so the last sealed one is epoch zero, which
	// is to say there is not one.
	voters = &fakeVotes{
		weight: map[string]int64{string(moodVoter): 100},
		total:  100, epoch: 1,
	}

	testing.SetRealm(testing.NewUserRealm(moodVoter))
	uassert.AbortsContains(t, cur, "too young to vote", func() {
		Propose(cross(cur), "moody/thing", "premature", "before the first epoch")
	})
}

// A proposal that won on its deadline cannot be cancelled either, even though
// nobody has written the win down yet.
//
// This is the same veto as TestCancelBelongsToTheProposerAndOnlyWhileItIsOpen,
// reached through a different door, and that test cannot see it: its proposal
// settles the moment the decisive vote lands, so the stored state is already
// succeeded by the time Cancel is called.
//
// A proposal that clears quorum without being decisive settles on its DEADLINE
// instead — and nobody has to be present when a deadline passes. The outcome is
// then true but unrecorded: State() computes it for a reader, while the stored
// state is still active. Cancel settles first for exactly this reason. Without
// that, a proposer who watched their proposal win could take it back, and the
// record would show a withdrawal rather than a defeat.
func TestAWinRecordedByNobodyStillCannotBeCancelled(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	real_ := voters
	defer func() { voters = real_ }()
	minter = moodVoter
	quiet := testutils.TestAddress("c-quiet")

	testing.SetRealm(testing.NewUserRealm(moodVoter))
	// 400 of 1000 against a 30% quorum: enough to clear it, not enough to
	// decide it, so the answer waits for the clock.
	Mint(cross(cur), moodVoter, 400)
	Mint(cross(cur), quiet, 600)
	advanceEpochs(1)

	moodyCheckFails, moodyDoFails, moodyRan = false, false, 0
	kinds.Set("moody/thing", &entry{kind: moody{}, live: true, rules: Rules{
		QuorumBps: 3000, ThresholdBps: 5000, VotingBlocks: 100, DelayBlocks: 1000,
	}})
	testing.SetRealm(testing.NewUserRealm(moodVoter))
	id := Propose(cross(cur), "moody/thing", "uncancellable", "deadline win")
	Vote(cross(cur), id, "yes")
	if got := State(id); got != "active" {
		t.Fatalf("with 600 still uncast this should not be decided yet: %q", got)
	}

	// The deadline passes and nobody says anything. Nothing has written the
	// outcome down: State computes it, the stored state has not moved.
	advanceBlocks(200)
	if got := State(id); got != "succeeded" {
		t.Fatalf("after the deadline a reader sees %q, want succeeded", got)
	}
	if p := mustProposal(id); p.state != stateActive {
		t.Fatalf("something already recorded the outcome, so this test is no "+
			"longer about an unrecorded one (stored state %d)", p.state)
	}

	uassert.AbortsContains(t, cur, "too late to cancel", func() {
		Cancel(cross(cur), id)
	})
	if got := State(id); got != "succeeded" {
		t.Errorf("the proposer withdrew a proposal that had already won: %q", got)
	}
}

// Anybody may write down an outcome, and the timelock starts when they do.
//
// Settle is permissionless on purpose, and the reason only shows up in the case
// where a proposal wins on its deadline: nobody has to be present when a
// deadline passes, so the decision is real before it is recorded, and the delay
// runs from the recording.
//
// If only the proposer could record it, a proposer who lost interest — or who
// disliked the result — could sit on a decision the holders had taken and stall
// its execution until the grace period killed it. Nobody could do anything
// about it, because Execute refuses until the outcome is written and the delay
// has run. Announcing must never be a privileged position, and this is the test
// that says so.
func TestAnybodyMayRecordAnOutcome(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	real_ := voters
	defer func() { voters = real_ }()
	minter = moodVoter
	quiet := testutils.TestAddress("s-quiet")
	stranger := testutils.TestAddress("s-stranger")

	testing.SetRealm(testing.NewUserRealm(moodVoter))
	Mint(cross(cur), moodVoter, 400)
	Mint(cross(cur), quiet, 600)
	advanceEpochs(1)

	moodyCheckFails, moodyDoFails, moodyRan = false, false, 0
	kinds.Set("moody/thing", &entry{kind: moody{}, live: true, rules: Rules{
		QuorumBps: 3000, ThresholdBps: 5000, VotingBlocks: 100, DelayBlocks: 1000,
	}})
	testing.SetRealm(testing.NewUserRealm(moodVoter))
	id := Propose(cross(cur), "moody/thing", "recorded-by-a-stranger", "deadline win")
	Vote(cross(cur), id, "yes")

	// The deadline passes unattended, so the win is true and unwritten.
	advanceBlocks(200)
	if p := mustProposal(id); p.state != stateActive {
		t.Fatalf("the outcome was already recorded, so this test is not about "+
			"an unrecorded one (stored state %d)", p.state)
	}

	// Somebody with no stake in it and no part in proposing records the result.
	testing.SetRealm(testing.NewUserRealm(stranger))
	Settle(cross(cur), id)

	p := mustProposal(id)
	if p.state != stateSucceeded {
		t.Fatalf("a stranger could not record the outcome: stored state %d", p.state)
	}
	// And the clock started when they said so, not when the votes stopped
	// mattering.
	if p.ready == 0 {
		t.Error("the outcome was recorded without starting the timelock")
	}
	uassert.AbortsContains(t, cur, "still in the delay window", func() {
		Execute(cross(cur), id)
	})
}

// What a kind writes into the permanent record is clipped, and clipped
// somewhere a character can survive.
//
// An adopted kind is trusted with far more than a string — the holders voted it
// the power to run — so this is not about a hostile one. It is about a buggy
// one whose error carries a whole response body, landing in a proposal that is
// kept for the life of the realm and rendered every time anybody opens it.
//
// The rune boundary is the part worth testing rather than assuming: cutting a
// byte string at a fixed length lands mid-character about three times in four
// for multi-byte text, and the result is a record that no longer decodes.
func TestAKindsFailureMessageIsClippedAtARuneBoundary(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	real_ := voters
	defer func() {
		voters = real_
		moodyCheckFails, moodyDoFails, moodyErrText = false, false, ""
	}()

	// Every character three bytes, so a cut at any fixed byte length that is
	// not a multiple of three would land inside one.
	long := ""
	for i := 0; i < 400; i++ {
		long += "違"
	}
	moodyCheckFails, moodyDoFails, moodyRan, moodyErrText = false, true, 0, long
	arm(Rules{QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 10})

	testing.SetRealm(testing.NewUserRealm(moodVoter))
	id := Propose(cross(cur), "moody/thing", "verbose", "a talkative failure")
	Vote(cross(cur), id, "yes")
	Execute(cross(cur), id)

	p := mustProposal(id)
	if got := len(p.reason); got > maxReason+4 {
		t.Errorf("the stored reason is %d bytes, want no more than about %d — "+
			"a kind can write what it likes into a record kept forever",
			got, maxReason)
	}
	if len(p.reason) >= len(long) {
		t.Fatal("the reason was not clipped at all, so the rest proves nothing")
	}
	// Still decodable: every byte accounted for by a whole rune.
	body := p.reason
	if n := len(body); n >= 3 && body[n-3:] == "…" {
		body = body[:n-3]
	}
	runes := 0
	for i := 0; i < len(body); {
		c := body[i]
		switch {
		case c < 0x80:
			i++
		case c&0xE0 == 0xC0:
			i += 2
		case c&0xF0 == 0xE0:
			i += 3
		case c&0xF8 == 0xF0:
			i += 4
		default:
			t.Fatalf("byte %d of the clipped reason is a continuation byte, so "+
				"the cut landed inside a character", i)
		}
		runes++
		if i > len(body) {
			t.Fatalf("the clipped reason ends %d bytes into a character", i-len(body))
		}
	}
	if runes == 0 {
		t.Error("nothing survived the clip")
	}

	// The other way a kind writes into the record: a Check that has gone stale
	// between the vote and the execution. Same clip, different line — and one
	// the first line's test says nothing about.
	resetLedger()
	// Check has to PASS at the door and fail later — that is what "stale"
	// means. Set before Propose, it refuses the proposal outright and the long
	// message comes back as the abort, which asserts nothing about the record.
	moodyCheckFails, moodyDoFails, moodyRan = false, false, 0
	arm(Rules{QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 10})
	testing.SetRealm(testing.NewUserRealm(moodVoter))
	stale := Propose(cross(cur), "moody/thing", "stale", "will not check out")
	Vote(cross(cur), stale, "yes")

	moodyCheckFails = true
	Execute(cross(cur), stale)

	sp := mustProposal(stale)
	if sp.state != stateFailed {
		t.Fatalf("the stale proposal is state %d, want failed", sp.state)
	}
	if got := len(sp.reason); got > maxReason+4 {
		t.Errorf("the stale-check reason is %d bytes, want no more than about "+
			"%d", got, maxReason)
	}
}

// What a handler may and may not do while it is running.
//
// The latch is checked by Propose, Vote and Execute, and NOT by Offer, Settle
// or Cancel. Nothing said so and nothing tested it, which makes a deliberate
// line look like three places somebody forgot.
//
// The line is about manufacturing governance. A handler that could open a
// question or cast a vote mid-execution would be legislating during its own
// enactment, against the electorate of a decision already taken. The ones it
// may still call grant it nothing it did not have: Offer is ungated and
// registering a kind confers no power, because adoption is a separate vote;
// Settle only writes down a conclusion the rules already reached, and anybody
// may call it from anywhere; Cancel is the proposer's own, and a realm that
// proposed something may withdraw it whenever it likes.
//
// Guarding those would be defending a case that takes nothing, which is the
// kind of check that reads as protection and is decoration.
//
// The latch is set here rather than reached through a handler that re-enters.
// A kind calling back in does it through a nested crossing call, and the abort
// that comes out of one does not arrive as the abort of the OUTER call — it
// escapes uassert entirely. What is being tested is the rule, and the rule is
// this variable.
func TestWhatAHandlerMayDoWhileItIsRunning(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	real_ := voters
	defer func() { voters = real_; executing = false }()

	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(setFee{}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 100,
	})
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(gAlice))
	live := Propose(cross(cur), "fee", "601", "something to act on")

	// From here on, pretend a handler is running.
	executing = true

	uassert.AbortsContains(t, cur, "cannot propose from inside an execution", func() {
		Propose(cross(cur), "fee", "602", "legislating mid-enactment")
	})
	uassert.AbortsContains(t, cur, "cannot vote from inside an execution", func() {
		Vote(cross(cur), live, "yes")
	})
	uassert.AbortsContains(t, cur, "re-entrant execution", func() {
		Execute(cross(cur), live)
	})

	// And the three that are deliberately not guarded, because none of them
	// hands a handler anything it did not already have.
	Settle(cross(cur), live)
	if got := State(live); got != "active" {
		t.Errorf("settling an undecided proposal changed it to %q", got)
	}
	// A name nothing else has taken: resetLedger clears the ledger and the
	// proposals, and deliberately not the KIND registry — a name is bound to
	// its code forever, which is a rule about the realm's whole lifetime and
	// not about one test. So kinds accumulate across the package, and offering
	// one another test already offered fails with "that name is taken", which
	// is the rule working.
	namedAs = "latch/probe"
	Offer(cross(cur), named{}, Rules{QuorumBps: 1, ThresholdBps: 1, VotingBlocks: 10, GraceBlocks: 100})
	if entryOf("latch/probe") == nil {
		t.Error("Offer was refused while a handler was running, which takes " +
			"nothing from anybody and is not what the latch is for")
	}
	Cancel(cross(cur), live)
	if got := State(live); got != "canceled" {
		t.Errorf("the proposer could not withdraw their own proposal: %q", got)
	}

	executing = false
}

// Retiring a kind kills decisions already taken under it, and says so.
//
// The description is checked against the BEHAVIOUR here rather than on its own,
// because a disclosure that is merely present is worth nothing — what matters
// is that it is true. Holders voting to retire a kind are also voting, whether
// they know it or not, to fail every proposal of that kind that has been
// decided and not yet run.
//
// Execute refuses a kind that is no longer adopted and records the proposal as
// failed. That is the right behaviour — the holders withdrew the power — but it
// is invisible from the retire proposal unless the page says so.
func TestRetiringAKindKillsDecisionsAlreadyTakenUnderIt(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	real_ := voters
	defer func() { voters = real_ }()

	moodyCheckFails, moodyDoFails, moodyRan = false, false, 0
	arm(Rules{QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 10})

	// A decision taken, waiting to run.
	testing.SetRealm(testing.NewUserRealm(moodVoter))
	id := Propose(cross(cur), "moody/thing", "doomed", "decided before the retirement")
	Vote(cross(cur), id, "yes")
	if got := State(id); got != "succeeded" {
		t.Fatalf("the proposal is %q, want succeeded", got)
	}

	// The page a holder reads before retiring warns them.
	warning := Preview("govern:retire", "moody/thing")
	if !strings.Contains(warning, "already been decided and not yet run") {
		t.Errorf("retiring does not disclose what it does to decisions already "+
			"taken:\n%s", warning)
	}

	// And it is true: retire the kind, and the decision dies.
	e := entryOf("moody/thing")
	e.live = false

	Execute(cross(cur), id)
	if got := State(id); got != "failed" {
		t.Errorf("after retiring the kind the decided proposal is %q, want "+
			"failed — the warning above would be describing something that "+
			"does not happen", got)
	}
	if moodyRan != 0 {
		t.Errorf("the handler ran %d times for a retired kind", moodyRan)
	}
	if p := mustProposal(id); !strings.Contains(p.reason, "retired") {
		t.Errorf("the failure reason is %q, which does not point at the "+
			"retirement", p.reason)
	}
}

// The terms a holder is asked to grant carry a duration, not only a block
// count.
//
// Correctness never depends on the wall clock: a period is exactly the number
// of blocks it says. But "120960 blocks to vote" does not tell somebody whether
// that is an afternoon or a season, and this is the text read before granting a
// power. Both are shown and the approximation is marked as one.
func TestAdoptionTermsCarryADuration(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	kinds.Set("dur/probe", &entry{kind: moody{}, live: false, rules: Rules{
		QuorumBps: 2000, ThresholdBps: 6600,
		VotingBlocks: 7 * 24 * 60 * 60 / 5,
		DelayBlocks:  2 * 24 * 60 * 60 / 5,
		GraceBlocks:  14 * 24 * 60 * 60 / 5,
	}})
	page := Preview("govern:adopt", "dur/probe")
	for _, want := range []string{
		"120960 blocks (about 7 days)",
		"34560 blocks (about 2 days)",
		"241920 blocks (about 14 days)",
	} {
		if !strings.Contains(page, want) {
			t.Errorf("the adoption terms do not say %q:\n%s", want, page)
		}
	}

	// Short periods read in the units they belong in, or an hour would be
	// rendered as zero days.
	kinds.Set("dur/short", &entry{kind: moody{}, live: false, rules: Rules{
		QuorumBps: 1, ThresholdBps: 1, VotingBlocks: 720, DelayBlocks: 12,
	}})
	page = Preview("govern:adopt", "dur/short")
	if !strings.Contains(page, "720 blocks (about 1 hour)") {
		t.Errorf("an hour-long vote is not rendered in hours:\n%s", page)
	}
	if !strings.Contains(page, "12 blocks (about 1 minute)") {
		t.Errorf("a one-minute delay is not rendered in minutes:\n%s", page)
	}
}

// A handler that PANICS leaves the proposal to be tried again; one that returns
// an error finishes it. Both are legitimate and they are not interchangeable.
//
// The difference is the whole rollback story in gno. An error is recorded, so
// the proposal is over and its slot comes back. A panic aborts the transaction,
// so nothing is written — not even the failure — and the decision is still
// standing, waiting for somebody to try again or for the grace period to end
// it.
//
// A Kind author picks between them by knowing this, so it is on Kind.Do where
// they will read it.
func TestAPanickingHandlerLeavesTheProposalToBeRetried(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	real_ := voters
	defer func() { voters = real_; moodyPanics = false }()
	moodyCheckFails, moodyDoFails, moodyRan, moodyPanics = false, false, 0, false
	arm(Rules{QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 10})

	testing.SetRealm(testing.NewUserRealm(moodVoter))
	id := Propose(cross(cur), "moody/thing", "boom", "a handler that panics")
	Vote(cross(cur), id, "yes")

	moodyPanics = true
	uassert.AbortsContains(t, cur, "something went wrong halfway", func() {
		Execute(cross(cur), id)
	})

	// Still standing, still holding its slot, and the re-entrancy latch is
	// clear — that last one is why Execute clears it with a defer rather than
	// on the line after Do. A latch left set by a panicking handler would stop
	// the governor executing anything, ever again.
	if got := State(id); got != "succeeded" {
		t.Errorf("after an aborted execution the proposal is %q, want succeeded "+
			"— an abort writes nothing, including the failure", got)
	}
	if !openIdx.Has(digest("moody/thing", "boom")) {
		t.Error("the proposal gave up its slot on an execution that never happened")
	}
	if executing {
		t.Fatal("the re-entrancy latch is still set after a handler panicked, " +
			"so nothing can ever be executed again")
	}

	// Anybody may try again, and it fails the same way.
	uassert.AbortsContains(t, cur, "something went wrong halfway", func() {
		Execute(cross(cur), id)
	})
	if got := State(id); got != "succeeded" {
		t.Errorf("a second attempt left it %q", got)
	}

	// And when the handler stops panicking, the decision still stands and runs.
	moodyPanics = false
	Execute(cross(cur), id)
	if got := State(id); got != "executed" {
		t.Errorf("once the handler worked the proposal is %q, want executed", got)
	}

	// The contrast: an error is recorded, and there is no second attempt.
	resetLedger()
	moodyCheckFails, moodyDoFails, moodyRan = false, true, 0
	arm(Rules{QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 10})
	testing.SetRealm(testing.NewUserRealm(moodVoter))
	other := Propose(cross(cur), "moody/thing", "tidy", "a handler that reports")
	Vote(cross(cur), other, "yes")
	Execute(cross(cur), other)
	if got := State(other); got != "failed" {
		t.Errorf("a handler that returned an error left the proposal %q, want "+
			"failed — the two ways of failing must not look the same", got)
	}
	uassert.AbortsContains(t, cur, "not waiting to be executed", func() {
		Execute(cross(cur), other)
	})
}

// The latch is set BY Execute, for the duration of the handler.
//
// The sibling test above sets `executing` by hand and checks that Propose, Vote
// and Execute all refuse while it is set. That proves the guards read the
// variable; it proves nothing about anybody writing it, and deleting the two
// lines in Execute that do left every test in this suite green.
//
// Observed from inside a running handler, because that is the only place the
// property exists. Not by making the handler call back in: a nested crossing
// call that aborts does not surface as the abort of the outer one, it escapes
// uassert entirely, which is the same reason the sibling test is shaped the way
// it is.
var sawLatch, ranAtAll bool

type peeker struct{}

func (peeker) Name() string             { return "peek/latch" }
func (peeker) Describe(p string) string { return "look at the latch" }
func (peeker) Check(p string) error     { return nil }

func (peeker) Do(_ int, rlm realm, p string) error {
	ranAtAll, sawLatch = true, executing
	return nil
}

func TestTheLatchIsSetWhileAHandlerRuns(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	sawLatch, ranAtAll = false, false
	defer func() { executing = false }()

	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(peeker{}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 100,
	})
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "peek/latch", "x", "run something")
	Vote(cross(cur), id, "yes")
	Execute(cross(cur), id)

	if !ranAtAll {
		t.Fatal("the handler never ran, so it saw nothing")
	}
	if !sawLatch {
		t.Error("a handler ran with the re-entrancy latch clear: everything it " +
			"calls back into the governor would be accepted, and the guards " +
			"that read the latch are unreachable")
	}
	if executing {
		t.Error("the latch is still set after the handler returned")
	}
}
