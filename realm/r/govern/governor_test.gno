package govern

import (
	governor "gno.land/p/cryptocourt/governor/v0"
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
	ufmt "gno.land/p/nt/ufmt/v0"
)

// setFee is a kind that exists to be governed: it does one small thing, and
// its payload is a string, because a proposal's payload is always a string.
// A settable name, because Adopt registers a kind under k.Name() and several
// fixtures want the same behaviour under a different name. Registering by hand
// used to allow a key that disagreed with Name(); nothing does now, and a
// registry whose key could differ from the kind's own name is a registry that
// can dispatch the wrong code.
type setFee struct{ name string }

var feeBps int64

func (k setFee) Name() string {
	if k.name == "" {
		return "fee"
	}
	return k.name
}

func (setFee) Describe(payload string) string {
	// A total function of the payload. Nothing here reads live state, so two
	// voters at different heights read the same question.
	return "set the fee to " + payload + " bps"
}

func (setFee) Check(payload string) error {
	n, err := parseBps(payload)
	if err != nil {
		return err
	}
	if n < 0 || n > 10000 {
		return errOutOfRange
	}
	return nil
}

func (setFee) Do(_ int, rlm realm, payload string) error {
	n, err := parseBps(payload)
	if err != nil {
		return err
	}
	feeBps = n
	return nil
}

var errOutOfRange = newErr("fee out of range")

type simpleErr struct{ s string }

func (e *simpleErr) Error() string { return e.s }
func newErr(s string) error        { return &simpleErr{s} }

func parseBps(s string) (int64, error) {
	if s == "" {
		return 0, newErr("empty fee")
	}
	n := int64(0)
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, newErr("fee must be digits")
		}
		n = n*10 + int64(c-'0')
	}
	return n, nil
}

// offerAndAdopt shelves a kind and marks it live without a vote.
//
// Standing in for the adoption proposal in tests that are about something
// else. The adoption path itself is exercised properly in
// TestAKindCannotBeProposedUntilItIsAdopted, which is where it belongs.
func offerAndAdopt(k Kind, r Rules) {
	// A grace period if the fixture did not name one.
	//
	// Registering by hand used to bypass the rules check; Adopt does not, and
	// refuses a grace of zero because a decided proposal with no expiry holds
	// its slot for the life of the realm. Most of these fixtures are not about
	// grace and never set it, so the helper supplies one — the tests that ARE
	// about it set it themselves and are unaffected.
	if r.GraceBlocks == 0 {
		// Long enough that no fixture outlives it. These tests were written
		// when registering a kind by hand bypassed the rules check and a grace
		// of zero meant "never expires"; Adopt refuses zero now, because a
		// decided proposal with no expiry holds its slot for the life of the
		// realm. A million blocks is the same intent said legally — the suite's
		// longest advance is about 52,000.
		r.GraceBlocks = 1_000_000
	}
	engine.Adopt(k, r)
}

var (
	gAlice = testutils.TestAddress("galice")
	gBob   = testutils.TestAddress("gbob")
	gCarl  = testutils.TestAddress("gcarl")
)

// The headline: a proposal is two strings, an account votes its checkpointed
// weight, and what executes is what was described.
func TestAProposalIsTwoStringsAndItRuns(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(setFee{}, Rules{
		QuorumBps: 2000, ThresholdBps: 5000,
		VotingBlocks: 10 * epochBlocks, DelayBlocks: 0, GraceBlocks: 100,
	})
	Mint(cross(cur), gAlice, 600)
	Mint(cross(cur), gBob, 400)

	// Seal the epoch the proposal will snapshot.
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "fee", "250", "lower the fee")

	if got := Describe(id); got != "set the fee to 250 bps" {
		t.Errorf("described as %q", got)
	}
	if got := State(id); got != "active" {
		t.Errorf("a fresh proposal is %q", got)
	}

	// Alice alone is 600 of 1000: past quorum, past threshold, and unbeatable
	// by the 400 that remain. It should close on the arithmetic rather than
	// waiting out the clock.
	Vote(cross(cur), id, "yes")
	if got := State(id); got != "succeeded" {
		t.Fatalf("state after a decisive vote = %q, want succeeded — a foregone "+
			"conclusion should not wait out the timer", got)
	}

	Execute(cross(cur), id)
	if got := State(id); got != "executed" {
		t.Fatalf("state after execute = %q", got)
	}
	if feeBps != 250 {
		t.Errorf("the fee is %d, want 250 — the payload that was described is "+
			"the payload that ran", feeBps)
	}
}

// Weight comes from the snapshot, so a vote cannot be bought after the
// question is asked.
func TestVotingPowerIsSnapshotted(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(setFee{}, Rules{
		QuorumBps: 1, ThresholdBps: 5000,
		VotingBlocks: 10 * epochBlocks,
	})
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "fee", "10", "after you")

	// Carl is paid AFTER the snapshot. His tokens are real and his vote is
	// not: this is the property that makes a vote unrentable.
	Mint(cross(cur), gCarl, 100000)

	// A panic inside a crossing call is an ABORT, not a recoverable panic, so
	// a deferred recover never sees it and the whole test binary stops instead.
	// AbortsContains is the only way to assert a refusal here.
	testing.SetRealm(testing.NewUserRealm(gCarl))
	uassert.AbortsContains(t, cur, "no voting power at that epoch", func() {
		Vote(cross(cur), id, "no")
	})
}

// Quorum is a fraction of the supply at the snapshot, and failing it defeats
// the proposal however lopsided the votes cast were.
func TestQuorumIsAFractionOfTheSnapshot(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(setFee{}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: epochBlocks / 2,
	})
	Mint(cross(cur), gAlice, 100)
	Mint(cross(cur), gBob, 900)
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "fee", "1", "unanimous and irrelevant")
	Vote(cross(cur), id, "yes") // 100 of 1000: unanimous, and 10% turnout

	advanceEpochs(1)
	if got := State(id); got != "defeated" {
		t.Fatalf("state = %q, want defeated — every vote cast was yes, and "+
			"quorum still was not met", got)
	}
}

// spend is a second kind, used to prove that offering one grants nothing.
type spend struct{}

var spent int64

func (spend) Name() string                   { return "treasury/spend" }
func (spend) Describe(p string) string       { return "pay out " + p }
func (spend) Check(p string) error           { _, err := parseBps(p); return err }
func (spend) Do(_ int, rlm realm, p string) error {
	n, err := parseBps(p)
	if err != nil {
		return err
	}
	spent += n
	return nil
}

// Offering a kind grants nothing. Only a vote does.
//
// This is the security property the two-step exists for: publishing code is
// something any realm may do, and letting that code hold this governor's
// authority is something only the holders may do. Fused into one call — which
// is what a plain Register is — whoever may register can grant themselves
// every power the governor has, with no vote anywhere.
func TestAKindCannotBeProposedUntilItIsAdopted(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	// Enough to carry the built-in rules on her own. Package state is shared
	// across tests in one file, so the supply is whatever earlier tests left —
	// sized against it rather than against a number that was right once.
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)

	// Anyone may offer, including someone with no tokens and no standing.
	testing.SetRealm(testing.NewUserRealm(gCarl))
	Offer(cross(cur), spend{}, Rules{
		QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 10 * epochBlocks,
		GraceBlocks: 100,
	})

	// And it does nothing at all until adopted — but the refusal says WHICH of
	// the two failures it is. "no such kind" was the old wording and it pointed
	// the reader at their spelling when the name is fine and the vote is what
	// is missing. Preview has always distinguished them; the propose path used
	// to deny the offer existed.
	testing.SetRealm(testing.NewUserRealm(gAlice))
	uassert.AbortsContains(t, cur, "offered but not adopted", func() {
		Propose(cross(cur), "treasury/spend", "5", "pay me")
	})
	uassert.AbortsContains(t, cur, "govern:adopt", func() {
		Propose(cross(cur), "treasury/spend", "5", "pay me")
	})
	// A name nobody offered is the other failure, and still reads as one.
	uassert.AbortsContains(t, cur, "no such kind: nobody/offered", func() {
		Propose(cross(cur), "nobody/offered", "5", "pay me")
	})

	// The holders adopt it, through the ordinary machinery.
	id := Propose(cross(cur), "govern:adopt", "treasury/spend", "adopt spending")
	// The name AND the terms. A holder approving a power without seeing how
	// easily it can be used has approved the wrong thing.
	desc := Describe(id)
	if !strings.Contains(desc, "adopt the kind `treasury/spend`") {
		t.Fatalf("the adoption proposal reads %q", desc)
	}
	for _, want := range []string{"quorum: 0.01%", "threshold: 50.00%", "time to vote:"} {
		if !strings.Contains(desc, want) {
			t.Errorf("the adoption proposal does not say %q:\n%s", want, desc)
		}
	}
	Vote(cross(cur), id, "yes")
	advanceBlocks(3 * 24 * 60 * 60 / 5) // past the delay
	Execute(cross(cur), id)
	if got := State(id); got != "executed" {
		t.Fatalf("adoption ended %q", got)
	}

	// Now, and only now, it can be proposed.
	id2 := Propose(cross(cur), "treasury/spend", "7", "pay me, properly this time")
	Vote(cross(cur), id2, "yes")
	Execute(cross(cur), id2)
	if spent != 7 {
		t.Errorf("spent = %d, want 7", spent)
	}
}

// The governor's own kinds are not up for grabs: a realm cannot publish
// something that renders as a built-in, and the built-ins cannot be retired
// out from under the holders.
func TestTheGovernorsOwnKindsAreProtected(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	testing.SetRealm(testing.NewUserRealm(gCarl))
	uassert.AbortsContains(t, cur, "prefix belongs to the governor", func() {
		Offer(cross(cur), impostor{}, Rules{QuorumBps: 1, ThresholdBps: 1, VotingBlocks: 10, GraceBlocks: 100})
	})
}

// The other half of that protection, which is an asymmetry rather than a ban:
// a built-in cannot be RETIRED, but it can be RETUNED.
//
// Both directions matter and they pull opposite ways. Retiring govern:adopt
// would freeze the kind set permanently — adopting a kind is itself a kind, so
// there would be nothing left that could ever grant a power again. Retiring
// govern:rules would freeze every term forever. So the governor.Reserved prefix is
// refused there, and that refusal is load-bearing rather than tidy.
//
// Retuning is the opposite: the holders SHOULD be able to move their own bar,
// including the bar for adoption itself. A governor that cannot change what it
// takes to grant a power is stuck with whatever its deployer guessed on day
// one. So this goes through the whole path — propose, vote, timelock, execute
// — because the direct Check call the sibling test makes would pass even if
// Propose refused the governor.Reserved prefix somewhere upstream.
func TestABuiltInCanBeRetunedButNotRetired(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)

	beforeRules, _ := KindRules("govern:adopt")
	before := beforeRules.QuorumBps
	if before != 2000 {
		t.Fatalf("adoption starts at a %d bps quorum, want the bootstrap 2000", before)
	}

	// Move the bar for adoption itself, by vote, under the old bar.
	rid := Propose(cross(cur), "govern:rules", "govern:adopt quorum=100",
		"make it easier to adopt kinds")
	Vote(cross(cur), rid, "yes")
	advanceBlocks(3 * 24 * 60 * 60 / 5)
	Execute(cross(cur), rid)
	if got := State(rid); got != "executed" {
		t.Fatalf("retuning a built-in ended %q, want executed", got)
	}
	afterRules, _ := KindRules("govern:adopt")
	if got := afterRules.QuorumBps; got != 100 {
		t.Errorf("the adoption quorum is %d bps, want the 100 the holders voted "+
			"for — the governor cannot move its own bar", got)
	}

	// And the direction that stays shut, through Propose rather than through a
	// direct Check, so nothing upstream can quietly let it past.
	uassert.AbortsContains(t, cur, "cannot be retired", func() {
		Propose(cross(cur), "govern:retire", "govern:adopt", "freeze the governor")
	})
}

type impostor struct{}

func (impostor) Name() string                        { return "govern:adopt" }
func (impostor) Describe(p string) string            { return "" }
func (impostor) Check(p string) error                { return nil }
func (impostor) Do(_ int, rlm realm, p string) error { return nil }

// Changing the rules is itself a proposal, and it cannot move the bar under a
// vote already in progress.
func TestRulesChangeCannotMoveTheBarUnderAnOpenVote(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(setFee{}, Rules{
		QuorumBps: 5000, ThresholdBps: 5000, VotingBlocks: 50 * epochBlocks,
		GraceBlocks: 100,
	})
	Mint(cross(cur), gAlice, 900)
	Mint(cross(cur), gBob, 10)
	advanceEpochs(1)

	// Bob opens a proposal under a 50% quorum he cannot possibly meet.
	testing.SetRealm(testing.NewUserRealm(gBob))
	stuck := Propose(cross(cur), "fee", "11", "bob tries")
	Vote(cross(cur), stuck, "yes")
	if got := State(stuck); got != "active" {
		t.Fatalf("bob's proposal is %q, want active", got)
	}

	// Alice lowers the quorum for that kind, by vote.
	testing.SetRealm(testing.NewUserRealm(gAlice))
	rid := Propose(cross(cur), "govern:rules", "fee quorum=1", "lower the fee quorum")
	if got := Describe(rid); got != "change the rules for `fee`:\n- quorum -> 1 bps (0.01%)" {
		t.Fatalf("the rules proposal reads %q", got)
	}
	Vote(cross(cur), rid, "yes")
	advanceBlocks(3 * 24 * 60 * 60 / 5)
	Execute(cross(cur), rid)
	if got := State(rid); got != "executed" {
		t.Fatalf("the rules change ended %q", got)
	}

	// Bob's proposal kept the rules it opened under. If it had not, lowering a
	// quorum would retroactively pass every proposal that was failing it.
	if got := State(stuck); got == "succeeded" || got == "executed" {
		t.Fatalf("an open proposal became %q when the rules changed beneath it — "+
			"a vote must be decided by the bar its voters were shown", got)
	}

	// A proposal opened AFTER the change gets the new bar.
	fresh := Propose(cross(cur), "fee", "12", "after the change")
	Vote(cross(cur), fresh, "yes")
	if got := State(fresh); got != "succeeded" {
		t.Errorf("a proposal opened after the change is %q, want succeeded", got)
	}
}

// A malformed payload is refused when the proposal opens, not discovered
// halfway through applying it.
func TestAMalformedRulesPayloadIsRefusedAtTheDoor(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)

	// Registered here rather than relied on from another test. resetLedger does
	// not clear the kind registry, so "fee" is usually still lying around from
	// whatever ran before; run alone, this test would refuse every payload with
	// "no kind by that name has been offered" instead of the messages it is
	// checking for. An assertion on the shared "govern:" prefix would match
	// that too, which is how such a dependency stays invisible.
	engine.Adopt(setFee{}, Rules{
		QuorumBps: 5000, ThresholdBps: 5000, VotingBlocks: 100, GraceBlocks: 1_000_000,
	})

	// Each case names the message it expects rather than just "govern:".
	//
	// The generic prefix was what this asserted, and it passes whichever guard
	// happens to fire — so it could not tell a precise refusal from an
	// accidental one. Two of these are refused twice over: a negative term is
	// caught by the parser AND would be caught again by saneRules downstream,
	// so deleting the parser's check left the payload still refused and this
	// test still green. Naming the message is what makes the parser's guard
	// load-bearing.
	for _, c := range []struct{ payload, want string }{
		{"fee", "expected a kind name and at least one key=value"},
		{"fee quorum", "expected key=value"},
		{"fee quorum=", "expected key=value"},
		{"fee quorum=abc", "expected a non-negative number for quorum"},
		{"fee quorum=-1", "expected a non-negative number for quorum"},
		{"fee voting=-1", "expected a non-negative number for voting"},
		{"fee wobble=10", "unknown field wobble"},
		{"nosuchkind quorum=10", "no kind by that name has been offered"},
		{"fee quorum=10001", "basis points out of range"},
		{"fee voting=0", "a vote needs a period"},
		{"fee propose=10001", "cannot be asked to hold more than the whole supply"},
	} {
		uassert.AbortsContains(t, cur, c.want, func() {
			Propose(cross(cur), "govern:rules", c.payload, "bad")
	})
	}
}

// Two identical open proposals split the vote between them so neither reaches
// quorum, and both occupy the list. The second is refused.
func TestAnIdenticalProposalIsRefusedWhileOneIsOpen(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(setFee{}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 50 * epochBlocks,
	})
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(gAlice))
	first := Propose(cross(cur), "fee", "77", "set it to 77")
	uassert.AbortsContains(t, cur, "identical proposal is already open", func() {
		Propose(cross(cur), "fee", "77", "set it to 77, again")
	})

	// A different payload is a different question, so it is allowed.
	Propose(cross(cur), "fee", "78", "set it to 78")

	// And once the first is out of the way, the same question may be asked
	// again — refusing it forever would let one defeated proposal permanently
	// block a subject.
	Cancel(cross(cur), first)
	Propose(cross(cur), "fee", "77", "asking again, properly")
}

// A proposer can be required to hold a stake. The list is what holders read,
// and a list nobody reads is a governor nobody governs.
func TestAProposerCanBeRequiredToHoldAStake(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(spend{}, Rules{
		QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 50 * epochBlocks,
		ProposeBps: 1000, // a tenth of the supply
	})
	Mint(cross(cur), gAlice, 999)
	Mint(cross(cur), gBob, 1)
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(gBob))
	uassert.AbortsContains(t, cur, "not enough voting power", func() {
		Propose(cross(cur), "treasury/spend", "1", "bob wants a say")
	})

	testing.SetRealm(testing.NewUserRealm(gAlice))
	Propose(cross(cur), "treasury/spend", "2", "alice has one")
}

// The page is the product.
//
// This design's whole claim over one that carries code is that what a voter
// reads is what executes. That is worth nothing unless the description is
// actually on the page, so the page is tested like anything else.
func TestThePageShowsWhatIsBeingVotedOn(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(setFee{}, Rules{
		QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 50 * epochBlocks,
	})
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "fee", "321", "a readable proposal")

	list := Render("")
	if !strings.Contains(list, "a readable proposal") {
		t.Errorf("the index does not list an open proposal:\n%s", list)
	}
	if !strings.Contains(list, "to vote on") {
		t.Errorf("the index does not separate what is still open:\n%s", list)
	}

	one := Render(strconv.FormatInt(id, 10))
	// The description the kind renders from the payload — the same string Do
	// will be handed — has to be on the page, not behind a call.
	if !strings.Contains(one, "set the fee to 321 bps") {
		t.Errorf("the proposal page does not say what it would do:\n%s", one)
	}
	if !strings.Contains(one, "weighed at epoch") {
		t.Errorf("the page does not say which electorate decides it:\n%s", one)
	}

	Vote(cross(cur), id, "yes")
	one = Render(strconv.FormatInt(id, 10))
	if !strings.Contains(one, "yes is") {
		t.Errorf("the page does not show the arithmetic a reader would check:\n%s", one)
	}

	if got := Render("nonsense"); !strings.Contains(got, "not a proposal id") {
		t.Errorf("a bad path renders %q", got)
	}
	if got := Render("999999"); !strings.Contains(got, "no such proposal") {
		t.Errorf("an unknown id renders %q", got)
	}
}

// Retiring a kind withdraws the power to run it. It must not also erase the
// record of what was proposed under it.
//
// Rendering a proposal must not demand a LIVE kind. If it does, a single
// retirement takes every historical page with it — the archive of what the
// holders decided, destroyed by the act of deciding one more thing.
func TestRetiringAKindDoesNotBreakItsHistory(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(spend{}, Rules{
		QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 50 * epochBlocks,
		DelayBlocks: 10 * epochBlocks,
	})
	Mint(cross(cur), gAlice, 900)
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(gAlice))
	old := Propose(cross(cur), "treasury/spend", "3", "spend a little")
	Vote(cross(cur), old, "yes")
	if got := State(old); got != "succeeded" {
		t.Fatalf("the proposal is %q, want succeeded", got)
	}

	// The holders take the power back while it waits out its delay.
	rid := Propose(cross(cur), "govern:retire", "treasury/spend", "no more spending")
	Vote(cross(cur), rid, "yes")
	advanceBlocks(3 * 24 * 60 * 60 / 5)
	Execute(cross(cur), rid)
	if got := State(rid); got != "executed" {
		t.Fatalf("the retirement ended %q", got)
	}

	// Reading still works. Without the guard this panics, taking the whole page
	// with it.
	if got := Describe(old); !strings.Contains(got, "pay out 3") {
		t.Errorf("the retired kind's proposal no longer describes itself: %q", got)
	}
	page := Render(strconv.FormatInt(old, 10))
	if !strings.Contains(page, "pay out 3") {
		t.Errorf("the proposal page lost its description:\n%s", page)
	}
	if !strings.Contains(Render(""), "spend a little") {
		t.Error("the index lost a proposal whose kind was retired")
	}

	// And executing it fails cleanly rather than panicking, so it reaches a
	// terminal state instead of sitting Succeeded forever to be retried by
	// anyone, identically, until the grace period runs out.
	Execute(cross(cur), old)
	if got := State(old); got != "failed" {
		t.Fatalf("executing a retired kind ended %q, want failed", got)
	}
}

// swapper is two different behaviours behind one name.
type swapper struct{ tag int64 }

var swapped int64

func (swapper) Name() string             { return "swap/me" }
func (s swapper) Describe(p string) string {
	if s.tag == 1 {
		return "harmless: does nothing at all"
	}
	return "hostile: takes everything"
}
func (swapper) Check(p string) error { return nil }
func (s swapper) Do(_ int, rlm realm, p string) error {
	swapped = s.tag
	return nil
}

// A name, once offered, is bound to that code.
//
// Otherwise: offer something harmless, wait for the adoption vote to open,
// re-offer hostile code under the same name while holders are voting, and the
// vote they cast on the first Describe adopts the second Do. The holders'
// signature ends up on a blank cheque.
func TestAnOfferedNameCannotBeRewritten(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	testing.SetRealm(testing.NewUserRealm(gCarl))
	Offer(cross(cur), swapper{tag: 1}, Rules{
		QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 50 * epochBlocks,
		GraceBlocks: 100,
	})
	if got := (swapper{tag: 1}).Describe(""); got != "harmless: does nothing at all" {
		t.Fatalf("the fixture is wrong: %q", got)
	}

	// The rewrite is refused outright, whether or not a vote is open.
	uassert.AbortsContains(t, cur, "that name is taken", func() {
		Offer(cross(cur), swapper{tag: 2}, Rules{
			QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 50 * epochBlocks,
			GraceBlocks: 100,
	})
	})

	// What holders would read is still what would run.
	e, ok := KindRules("swap/me")
	if !ok {
		t.Fatal("the offer vanished")
	}
	_ = e
	if got := Preview("swap/me", ""); !strings.Contains(got, "harmless: does nothing at all") {
		t.Errorf("the registered kind is %q — it was swapped", got)
	}
}

// The minter was the last unilateral power, and it was the biggest.
//
// New supply is new voting power, so an unbounded minter can out-vote every
// holder at will and no proposal can stop them — the vote would be decided by
// tokens minted to defeat it. Holders can now take that power, or end it.
func TestTheMinterCanBeHandedOverOrGivenUp(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Mint(cross(cur), gAlice, 900)
	advanceEpochs(1)

	// Hand it to Bob by vote.
	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "govern:minter", gBob.String(), "bob mints now")
	if got := Describe(id); got != "hand the power to mint to "+gBob.String() {
		t.Fatalf("the proposal reads %q", got)
	}
	Vote(cross(cur), id, "yes")
	advanceBlocks(3 * 24 * 60 * 60 / 5)
	Execute(cross(cur), id)
	if Minter() != gBob {
		t.Fatalf("the minter is %s, want bob", Minter().String())
	}

	// Alice can no longer mint; Bob can.
	testing.SetRealm(testing.NewUserRealm(gAlice))
	uassert.AbortsContains(t, cur, "only the minter may mint", func() {
		Mint(cross(cur), gAlice, 1)
	})
	testing.SetRealm(testing.NewUserRealm(gBob))
	Mint(cross(cur), gBob, 1)

	// And it can be ended outright, which is a promise no address can make
	// while it still holds the power to break it.
	advanceEpochs(1)
	testing.SetRealm(testing.NewUserRealm(gAlice))
	end := Propose(cross(cur), "govern:minter", "none", "fix the supply")
	if got := Describe(end); got != "give up the power to mint, permanently — the supply becomes fixed" {
		t.Fatalf("the renunciation reads %q", got)
	}
	Vote(cross(cur), end, "yes")
	advanceBlocks(3 * 24 * 60 * 60 / 5)
	Execute(cross(cur), end)

	fixed := TotalSupply()
	testing.SetRealm(testing.NewUserRealm(gBob))
	uassert.AbortsContains(t, cur, "supply is fixed", func() {
		Mint(cross(cur), gBob, 1)
	})
	if TotalSupply() != fixed {
		t.Errorf("the supply moved after it was fixed: %d, want %d", TotalSupply(), fixed)
	}

	// Put it back so later tests in this file can still mint.
	minter = gAlice
}

// Adopting a power means adopting the terms it can be used on, and neither
// can move between the vote and the execution.
func TestTheTermsCannotBeSwappedUnderAnAdoptionVote(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Mint(cross(cur), gAlice, 900)
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(gCarl))
	Offer(cross(cur), termSwap{}, Rules{
		QuorumBps: 5000, ThresholdBps: 6600, VotingBlocks: 50 * epochBlocks,
		GraceBlocks: 100,
	})

	// A holder reads the terms on the adoption page.
	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "govern:adopt", "term/swap", "adopt it")
	if !strings.Contains(Describe(id), "quorum: 50.00%") {
		t.Fatalf("the terms are not on the page:\n%s", Describe(id))
	}

	// Retuning it while that vote is open is refused. Otherwise a holder
	// approves a 50% quorum and gets whatever it was changed to — the same
	// swap the immutable-name rule closes, moved from the code to the terms.
	uassert.AbortsContains(t, cur, "not adopted", func() {
		Propose(cross(cur), "govern:rules", "term/swap quorum=1", "sneak")
	})

	// And re-offering under the name is refused too, so neither half can move.
	testing.SetRealm(testing.NewUserRealm(gCarl))
	uassert.AbortsContains(t, cur, "that name is taken", func() {
		Offer(cross(cur), termSwap{}, Rules{
			QuorumBps: 1, ThresholdBps: 1, VotingBlocks: 1, GraceBlocks: 1,
	})
	})

	// What was read is what is adopted.
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Vote(cross(cur), id, "yes")
	advanceBlocks(3 * 24 * 60 * 60 / 5)
	Execute(cross(cur), id)
	if e, ok := KindRules("term/swap"); !ok || e.QuorumBps != 5000 {
		t.Fatalf("adopted with different terms than were shown: %+v", e)
	}
}

type termSwap struct{}

func (termSwap) Name() string                        { return "term/swap" }
func (termSwap) Describe(p string) string            { return "does nothing" }
func (termSwap) Check(p string) error                { return nil }
func (termSwap) Do(_ int, rlm realm, p string) error { return nil }

// The front page has to say what the governance is denominated in.
//
// Every quorum below it is a fraction of this supply, so a reader who cannot
// see the supply cannot check any of it — and that the supply is FIXED, when
// it is, is the strongest promise the realm makes and cannot be inferred from
// silence.
func TestTheFrontPageSaysWhatTheVotesAreMadeOf(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	page := Render("")
	for _, want := range []string{tokenSymbol, "supply:", "epoch:", "governance"} {
		if !strings.Contains(page, want) {
			t.Errorf("the front page does not mention %q:\n%s", want, page)
		}
	}
	if !strings.Contains(page, "minter:") {
		t.Errorf("the page does not say who can mint:\n%s", page)
	}
	// The epoch by NUMBER, not just the label. A reader uses it to work out
	// which epoch votes are weighed at — the page says "weighed at sealed
	// epochs" and expects them to subtract one — so an off-by-one here sends
	// them to the wrong epoch with no way to tell. Rendering Epoch()-1 passed
	// every test in the realm while the label was all anybody asserted.
	if want := "epoch: " + strconv.FormatUint(uint64(Epoch()), 10); !strings.Contains(page, want) {
		t.Errorf("the header does not carry the current epoch as %q:\n%s", want, page)
	}

	was := minter
	minter = ""
	if page = Render(""); !strings.Contains(page, "supply is fixed") {
		t.Errorf("with minting given up, the page does not say so:\n%s", page)
	}
	minter = was
}

// A batch is several decisions taken as one, and it cannot reach a power the
// holders never granted.
func TestABatchIsAllOrNothing(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(setFee{}, Rules{QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 50 * epochBlocks})
	offerAndAdopt(spend{}, Rules{QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 50 * epochBlocks})
	Mint(cross(cur), gAlice, 900)
	advanceEpochs(1)

	feeBps, spent = 0, 0
	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "govern:batch", "fee 250\ntreasury/spend 4", "two things at once")

	// Each member described by its own kind from its own payload. A batch that
	// summarised its members in its own words would reintroduce, one level up,
	// exactly the description gap this design exists to close.
	desc := Describe(id)
	for _, want := range []string{"or none of them", "set the fee to 250 bps", "pay out 4"} {
		if !strings.Contains(desc, want) {
			t.Errorf("the batch does not describe %q:\n%s", want, desc)
		}
	}

	Vote(cross(cur), id, "yes")
	// The batch runs under the batch kind's own rules, not its members' — so
	// the built-in two-day delay applies even though the members have none.
	// That is the right way round: the batch is the decision being taken.
	advanceBlocks(3 * 24 * 60 * 60 / 5)
	Execute(cross(cur), id)
	if feeBps != 250 || spent != 4 {
		t.Fatalf("after the batch: fee=%d spent=%d, want 250 and 4", feeBps, spent)
	}
}

// A batch cannot smuggle in a power that was never adopted.
func TestABatchCannotReachAnUnadoptedKind(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(setFee{}, Rules{QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 50 * epochBlocks})
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)

	// Offered, deliberately never adopted.
	testing.SetRealm(testing.NewUserRealm(gCarl))
	Offer(cross(cur), sneaky{}, Rules{QuorumBps: 1, ThresholdBps: 1, VotingBlocks: 10, GraceBlocks: 100})

	testing.SetRealm(testing.NewUserRealm(gAlice))
	uassert.AbortsContains(t, cur, "not adopted", func() {
		Propose(cross(cur), "govern:batch", "fee 1\nsneaky/thing x", "smuggle")
	})
	// And a batch of batches is refused, because the description would be a
	// tree of unbounded depth and the whole point is that somebody reads it.
	uassert.AbortsContains(t, cur, "cannot contain a batch", func() {
		Propose(cross(cur), "govern:batch", "fee 1\ngovern:batch fee 2", "nested")
	})
	// One member is not a batch; propose it directly.
	uassert.AbortsContains(t, cur, "at least two members", func() {
		Propose(cross(cur), "govern:batch", "fee 1", "lonely")
	})
}

type sneaky struct{}

func (sneaky) Name() string                        { return "sneaky/thing" }
func (sneaky) Describe(p string) string            { return "does something unapproved" }
func (sneaky) Check(p string) error                { return nil }
func (sneaky) Do(_ int, rlm realm, p string) error { return nil }

// A batch validates its members when it is PROPOSED, not only when it runs.
//
// Nothing re-checks a member in between. Do calls each member's Do straight
// out and panics if one returns an error, so a batch carrying a member that
// cannot pass its own Check is a batch that gets described, voted on and
// approved — and then aborts on every attempt to run it, changing nothing,
// until the grace period ends it. The holders would have approved something
// that was never capable of happening.
func TestABatchValidatesItsMembersBeforeTheVote(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(setFee{}, Rules{QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 50 * epochBlocks})
	offerAndAdopt(spend{}, Rules{QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 50 * epochBlocks})
	Mint(cross(cur), gAlice, 900)
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(gAlice))
	// 99999 bps is more than everything; setFee's own Check is what refuses it,
	// which is the point — the batch does not need to know what a fee is.
	uassert.AbortsContains(t, cur, "out of range", func() {
		Propose(cross(cur), "govern:batch", "fee 99999\ntreasury/spend 4", "one bad member")
	})
	// The good half of the same batch still proposes, so the refusal above is
	// about the bad member and not about batches in general.
	id := Propose(cross(cur), "govern:batch", "fee 250\ntreasury/spend 4", "both fine")
	if State(id) != "active" {
		t.Fatalf("a batch of two valid members is %q", State(id))
	}
}

// A batch is bounded.
//
// Describe walks every member, and a proposal nobody can render is a proposal
// nobody can vote on. Written against governor.MaxBatch rather than against 16, because
// the claim being made is that a bound exists, not what it is set to.
func TestABatchIsBounded(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(setFee{}, Rules{QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 50 * epochBlocks})
	Mint(cross(cur), gAlice, 900)
	advanceEpochs(1)

	lines := make([]string, 0, governor.MaxBatch+1)
	for i := 0; i < governor.MaxBatch; i++ {
		lines = append(lines, "fee "+strconv.Itoa(i+1))
	}
	testing.SetRealm(testing.NewUserRealm(gAlice))

	// Exactly at the bound is allowed, so the refusal below is a bound and not
	// an off-by-one that quietly costs a member.
	id := Propose(cross(cur), "govern:batch", strings.Join(lines, "\n"), "at the bound")
	if State(id) != "active" {
		t.Fatalf("a batch of exactly governor.MaxBatch members is %q", State(id))
	}
	if got := len(strings.Split(Describe(id), "\n")); got < governor.MaxBatch {
		t.Errorf("the description has %d lines for %d members", got, governor.MaxBatch)
	}

	lines = append(lines, "fee 9999")
	uassert.AbortsContains(t, cur, "too many members", func() {
		Propose(cross(cur), "govern:batch", strings.Join(lines, "\n"), "over the bound")
	})
}

// Handing the mint to something that is not an address is refused at the door.
//
// It matters more here than anywhere else in the realm, because the failure is
// silent and terminal. Do would set minter to a string no account can ever
// present, which is renunciation — the supply fixed forever — arrived at by a
// proposal that said "hand the power to mint to g1typo" and was voted through
// by people reading exactly that.
//
// The two refusals are the same refusal: "none" is the only non-address this
// kind accepts, and it is spelled out precisely so that giving up the supply
// cannot happen by sending a field that is merely wrong.
func TestTheMintCannotBeHandedToSomethingThatIsNotAnAddress(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Mint(cross(cur), gAlice, 900)
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(gAlice))
	for _, bad := range []string{"g1typo", "", "nobody", "  "} {
		uassert.AbortsContains(t, cur, "not an address", func() {
			Propose(cross(cur), "govern:minter", bad, "hand it over")
	})
	}
	if Minter() != gAlice {
		t.Fatalf("the minter moved to %q on a refused proposal", Minter().String())
	}

	// Handing it to whoever already holds it is refused too: it reads as a
	// transfer, costs a vote, and does nothing.
	uassert.AbortsContains(t, cur, "already the minter", func() {
		Propose(cross(cur), "govern:minter", gAlice.String(), "no change")
	})

	// A real address still works, so the refusals above are about the payload.
	id := Propose(cross(cur), "govern:minter", gBob.String(), "a real one")
	if State(id) != "active" {
		t.Fatalf("handing the mint to a valid address is %q", State(id))
	}
	minter = gAlice
}

// named is a kind whose name the test chooses, so one type can stand in for
// every name worth refusing.
type named struct{}

var namedAs string

func (named) Name() string                        { return namedAs }
func (named) Describe(p string) string            { return "named: " + p }
func (named) Check(p string) error                { return nil }
func (named) Do(_ int, rlm realm, p string) error { return nil }

// A kind's name has to work everywhere a name is used.
//
// It is a registry key, the first field of a batch member line, part of the
// digest that decides whether two proposals ask the same question, and text on
// a page. Offer is ungated, so the name is picked by whoever turns up, and a
// name that works in one of those places and not the others is a kind that is
// quietly unusable.
//
// The space is the one worth having a test for. "my kind" offers and proposes
// without complaint; only a batch notices, because parseBatch ends the kind at
// the first space and then reports "no kind called my" — which points at
// neither the name nor the offer that accepted it.
// The digest separates the kind from the payload, because concatenation does
// not.
//
// openIdx is keyed by this, so two proposals that hash alike are one slot: the
// second is refused as "an identical proposal is already open" while asking a
// different question. Without the separator that is constructible rather than
// astronomical — kind "fee" with payload "250" and kind "fee2" with payload
// "50" are both perfectly ordinary, and both spell "fee250".
//
// WHICH byte separates them is half the mechanism, and the name rule is the
// other half. A separator a name may legally contain does not separate
// anything: with "-", the kind "fee" and payload "-250" spell the same string
// as the kind "fee-" and payload "250", and "fee-" is a perfectly good name.
// It has to be a byte no name may contain, which is why it is NUL.
//
// The converse is not defended here and cannot be: engine.Digest("fee", "\x00250")
// and engine.Digest("fee\x00", "250") genuinely do collide. Nothing about hashing
// prevents that — it is prevented by Offer refusing a name with a NUL in it,
// which is asserted where that rule lives.
func TestTheDigestSeparatesTheKindFromThePayload(t *testing.T) {
	if engine.Digest("fee", "250") == engine.Digest("fee2", "50") {
		t.Error("two different proposals share a digest, so opening one blocks " +
			"the other from ever being asked while it is live")
	}
	// A payload MAY contain the separator, so the separator has to be a byte
	// the kind cannot. This is the assertion a printable one fails.
	if engine.Digest("fee", "-250") == engine.Digest("fee-", "250") {
		t.Error("the separator is a byte a name may contain, so it does not " +
			"separate: two valid kinds collide across it")
	}
	// Still a function of the question: the same one twice is the same digest.
	if engine.Digest("fee", "250") != engine.Digest("fee", "250") {
		t.Error("the same proposal digests differently on two calls")
	}
	// And different questions under one kind stay different.
	if engine.Digest("fee", "250") == engine.Digest("fee", "251") {
		t.Error("two payloads under one kind share a digest")
	}
}

// Cancel belongs to the proposer, and only while the question is still open.
//
// Two separate powers, and neither had a test. The second is the one that would
// matter: a proposer who can withdraw a proposal AFTER it succeeded holds a
// unilateral veto over a decision the holders already took. They ask a
// question, lose it, and take it back — and the record shows a cancellation
// rather than a defeat, so nothing about the outcome survives to argue with.
//
// The first is a denial of governance rather than a theft: a cancel anybody can
// call means every proposal is withdrawn the moment it opens, by whoever
// objects to it.
func TestCancelBelongsToTheProposerAndOnlyWhileItIsOpen(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	// A high quorum, so a single vote does not decide it and the proposal
	// stays open long enough for a stranger to try.
	offerAndAdopt(setFee{}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 50 * epochBlocks,
	})
	Mint(cross(cur), gAlice, 600)
	Mint(cross(cur), gBob, 400)
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "fee", "120", "alice asks")

	// A stranger cannot take it off the list.
	testing.SetRealm(testing.NewUserRealm(gBob))
	uassert.AbortsContains(t, cur, "only the proposer may cancel", func() {
		Cancel(cross(cur), id)
	})
	if got := State(id); got != "active" {
		t.Fatalf("after a stranger's cancel the state is %q, want active", got)
	}

	// The holders decide it. Alice and Bob together are the whole electorate,
	// so this clears the ninety percent quorum and settles.
	Vote(cross(cur), id, "yes")
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Vote(cross(cur), id, "yes")
	if got := State(id); got != "succeeded" {
		t.Fatalf("the vote did not decide it: %q", got)
	}

	// And now its own proposer cannot take it back.
	uassert.AbortsContains(t, cur, "too late to cancel", func() {
		Cancel(cross(cur), id)
	})
	if got := State(id); got != "succeeded" {
		t.Errorf("the proposer cancelled a decision the holders had already "+
			"taken: state is %q, want succeeded", got)
	}
}

// NewRules is the extension point's front door, and it is six numbers in a row.
//
// It exists because a realm cannot allocate another realm's struct: an offering
// realm writing govern.Rules{...} is refused by the VM, so the struct is built
// in here and the caller passes numbers instead. Which makes these six
// positions the only thing between an offering realm and terms it never chose —
// swap quorum and threshold and the result is still a plausible set of rules,
// governing a kind on a bar nobody agreed to.
//
// Six distinct values, so no permutation of them passes. The filetest that
// calls this exercises the path but asserts nothing about where the numbers
// land, so neither a swapped pair nor a dropped field would fail there.
func TestNewRulesPutsEachNumberWhereItBelongs(t *testing.T) {
	r := NewRules(11, 22, 33, 44, 55, 66)
	for _, c := range []struct {
		name string
		got  int64
		want int64
	}{
		{"QuorumBps", r.QuorumBps, 11},
		{"ThresholdBps", r.ThresholdBps, 22},
		{"VotingBlocks", r.VotingBlocks, 33},
		{"DelayBlocks", r.DelayBlocks, 44},
		{"GraceBlocks", r.GraceBlocks, 55},
		{"ProposeBps", r.ProposeBps, 66},
	} {
		if c.got != c.want {
			t.Errorf("NewRules put %d in %s, want %d — the argument at that "+
				"position went somewhere else", c.got, c.name, c.want)
		}
	}
}

// A question defeated on its deadline can be asked again, without anyone
// having to tidy up first.
//
// The open index holds finished proposals until somebody records their
// outcome, and a read cannot record anything. So a proposal that lost when its
// deadline passed — with nobody present, which is the normal way for a
// deadline to pass — went on occupying its own subject. Asking again was
// refused with "an identical proposal is already open", about a proposal that
// was closed.
//
// That is the worst shape a wrong refusal can take: it names a real rule, it
// points at a real proposal, and the only way to discover it is untrue is to
// call State on the thing blocking you.
func TestAQuestionSettledByItsDeadlineCanBeAskedAgain(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	// A quorum nobody will reach, so it loses when the clock runs out rather
	// than on the arithmetic.
	offerAndAdopt(setFee{}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 100,
	})
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(gAlice))
	first := Propose(cross(cur), "fee", "310", "ask once")

	// The deadline passes unattended. The proposal is defeated and nothing has
	// written that down.
	advanceBlocks(200)
	if got := State(first); got != "defeated" {
		t.Fatalf("after its deadline the proposal is %q, want defeated", got)
	}
	if StoredState(first) != "active" {
		t.Fatalf("something recorded the outcome already, so this test is not "+
			"about an unrecorded one (stored state %s)", StoredState(first))
	}

	// The same question, asked again, by anyone, with no tidying first.
	second := Propose(cross(cur), "fee", "310", "ask again")
	if second == first {
		t.Fatal("the second proposal reused the first's id")
	}
	if got := State(second); got != "active" {
		t.Errorf("the new proposal is %q, want active", got)
	}
	// And the old one kept its outcome rather than being reopened.
	if got := State(first); got != "defeated" {
		t.Errorf("the defeated proposal is now %q", got)
	}

	// The refusal still fires when one genuinely IS open: the second is live.
	uassert.AbortsContains(t, cur, "identical proposal is already open", func() {
		Propose(cross(cur), "fee", "310", "and again")
	})
}

// A packed ballot survives the round trip, including at the top of the range.
//
// The choice and the weight share one int64 because a struct in the voter roll
// is a second object per vote — 846 bytes against 454, on every vote, forever.
// The price of that is two bits of arithmetic between what a voter said and
// what VoteOf reports, and arithmetic between a write and a read is exactly
// what a test is for.
//
// grc20votes.MaxSupply is the case worth naming: it is MaxInt64/10000, so shifting it left
// by two is safe with room to spare — but "safe with room to spare" is the sort
// of claim that is true until somebody raises a cap, and this fails loudly if
// anybody does.
// The proposer buys the roll's first node, and nobody can see what with.
//
// A bptree allocates nothing until its first key, so the roll's first node used
// to be bought by whoever voted first — eleven times an ordinary vote, charged
// for arriving early. Propose plants a sentinel instead.
//
// Which puts a key in the roll that is not a voter, and that is the part worth
// testing. It must be a key no address can be, it must not be reported as
// having voted, and it must not be in the way of anybody who really votes. The
// empty string is the choice; the assertions below are what make it safe rather
// than merely plausible, since "" reaches a read as an ordinary Go string from
// anybody who cares to send it.
func TestTheRollIsBoughtByTheProposerAndNotByTheFirstVoter(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(setFee{}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 100,
	})
	Mint(cross(cur), gAlice, 600)
	Mint(cross(cur), gBob, 400)
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "fee", "410", "who pays for the roll")

	// Bought before anybody votes. This is the whole point of the change: on
	// the old code the roll was an empty tree here and the next Set paid for
	// the node.
	if !engine.HasRoll(id) || engine.RollSize(id) != 1-1 {
		t.Fatal("a fresh proposal's roll has no first node, so whoever votes " +
			"first is still paying eleven times for it")
	}

	// And it is nobody. Both reads that take an address from outside are asked,
	// because the sentinel is a real key in a real tree and Has would say yes.
	if HasVoted(id, "") {
		t.Error("the empty address is reported as having voted; the sentinel " +
			"is showing through as a voter")
	}
	if _, _, ok := VoteOf(id, ""); ok {
		t.Error("VoteOf answers for the empty address, so a kind paying its " +
			"voters would pay the sentinel")
	}
	// Nor does it count for anybody else who has not voted.
	if HasVoted(id, gBob) {
		t.Error("bob has not voted and the roll says he has")
	}

	// It is not in anybody's way either: alice votes into the node she paid
	// for, and the refusal of a second vote still works.
	Vote(cross(cur), id, "yes")
	if !HasVoted(id, gAlice) {
		t.Fatal("alice voted and the roll did not record it")
	}
	uassert.AbortsContains(t, cur, "already voted", func() {
		Vote(cross(cur), id, "yes")
	})
	if yes, no, abstain, _ := Tally(id); yes != 600 || no != 0 || abstain != 0 {
		t.Errorf("tally %d/%d/%d after one vote of 600, want 600/0/0",
			yes, no, abstain)
	}
	// The tally is not the place to look for the sentinel, tempting as it is.
	// Weights are counted into p.yes as the votes arrive; the roll is only ever
	// asked WHETHER a key is there and, by VoteOf, what one key's ballot says.
	// So giving the sentinel a weight of the whole supply would change nothing
	// anybody can observe, and the two reads above are the entire surface.

	// And it goes with the rest of the roll rather than outliving it.
	advanceBlocks(200)
	Settle(cross(cur), id)
	ReleaseRoll(cross(cur), id)
	if engine.HasRoll(id) {
		t.Error("the released roll is still there")
	}
}

// A finished proposal keeps its voter roll until somebody reclaims it.
//
// There is a sound-looking argument for dropping it the moment a proposal
// settles: Vote refuses a closed proposal before it ever looks at the roll, so
// from the moment a proposal is decided the tree is an object nobody in this
// realm can reach.
//
// Nobody in THIS realm. A kind that pays out to the people who voted asks after
// the fact, and pull-based claiming means the last claim can be a long way
// after execution — so the one reader the roll had left was the one dropping it
// early made impossible. It stays now, and ReleaseRoll ends it on request:
// permissionless, refunded to whoever calls, which is the bargain Settle
// already makes for the slot.
//
// Both halves are asserted here, because either alone is a bug. A roll that
// never goes is rent forever; a roll that goes while the proposal is open lets
// everybody vote twice.
func TestAFinishedProposalKeepsItsVoterRollUntilSomebodyReclaimsIt(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	// A quorum one voter cannot reach on their own, so the proposal is still
	// open after alice votes and the set has something to do. With a quorum of
	// 1, alice's 600 decides it outright — the proposal settles inside her own
	// Vote call, and every assertion below measures a different state than the
	// one it names.
	offerAndAdopt(setFee{}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 100,
	})
	Mint(cross(cur), gAlice, 600)
	Mint(cross(cur), gBob, 400)
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "fee", "410", "decide it")

	// While it is open the set is doing its job.
	Vote(cross(cur), id, "yes")
	if got := State(id); got != "active" {
		t.Fatalf("one vote of 600 against a 90%% quorum settled it: %q", got)
	}
	if !engine.HasRoll(id) || !HasVoted(id, gAlice) {
		t.Fatal("an open proposal is not recording who voted, so it cannot " +
			"refuse a second vote")
	}
	uassert.AbortsContains(t, cur, "already voted", func() {
		Vote(cross(cur), id, "no")
	})

	// And it cannot be released while it is open, which is the check standing
	// between "reclaim the deposit" and "let everybody vote twice".
	uassert.AbortsContains(t, cur, "still open", func() {
		ReleaseRoll(cross(cur), id)
	})

	// The deadline decides it. The roll stays, because the outcome is when a
	// kind starts asking who voted, not when it stops.
	advanceBlocks(200)
	Settle(cross(cur), id)
	if got := State(id); got != "defeated" {
		t.Fatalf("the proposal is %q, want defeated", got)
	}
	if !engine.HasRoll(id) || !HasVoted(id, gAlice) {
		t.Fatal("a decided proposal has forgotten who voted, so nothing " +
			"downstream can pay them")
	}
	if choice, weight, ok := VoteOf(id, gAlice); !ok || choice != "yes" || weight != 600 {
		t.Errorf("VoteOf on a decided proposal says %q/%d/%v, want yes/600/true",
			choice, weight, ok)
	}

	// A late voter is still refused — by the state, which is the check that was
	// doing the work all along, and the reason keeping the roll is safe.
	testing.SetRealm(testing.NewUserRealm(gBob))
	uassert.AbortsContains(t, cur, "that proposal is closed", func() {
		Vote(cross(cur), id, "no")
	})

	// Anybody may reclaim it, so bob does — he neither proposed nor voted on
	// this one, and the refund goes to whoever pays the transaction.
	ReleaseRoll(cross(cur), id)
	if engine.HasRoll(id) {
		t.Error("the roll was released and the proposal is still holding it")
	}
	if _, _, ok := VoteOf(id, gAlice); ok {
		t.Error("VoteOf still answers from a released roll")
	}
	if HasVoted(id, gAlice) {
		t.Error("HasVoted still answers from a released roll")
	}
	// Twice is not an error. Anybody may call it, so two people racing to
	// reclaim the same roll is ordinary rather than an attack, and the second
	// one simply finds nothing to do.
	ReleaseRoll(cross(cur), id)

	// Withdrawal takes a proposal out of active too, and it is the one
	// transition the rules do not make, so it needs saying separately.
	testing.SetRealm(testing.NewUserRealm(gAlice))
	second := Propose(cross(cur), "fee", "411", "then think better of it")
	Vote(cross(cur), second, "yes")
	Cancel(cross(cur), second)
	if !engine.HasRoll(second) {
		t.Fatal("a cancelled proposal dropped its roll on its own; releasing " +
			"is supposed to be the only thing that does that")
	}
	ReleaseRoll(cross(cur), second)
	if engine.HasRoll(second) {
		t.Error("a cancelled proposal would not release its roll")
	}
}

// The two strings a proposer supplies are bounded, because the realm keeps
// them and the page shows them.
//
// The kind's NAME has been bounded since the day it turned out that a name goes
// four places at once. The same argument applies to a title and it was not
// made: every open proposal's title is concatenated into the front page, and
// that section has no cap — the 2000-character limit in Render is on the
// decided tail, a different list. So the page every holder reads was as long as
// the open titles put together, and one proposer chose that.
//
// Different bounds on purpose, and asserted at each one, so a swap between them
// fails: the title is a headline on a shared page, the payload is the argument
// and is mostly the proposer's own cost.
func TestAProposalsStringsAreBounded(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(setFee{}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 50 * epochBlocks,
	})
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)

	rep := func(n int) string {
		out := ""
		for i := 0; i < n; i++ {
			out += "a"
		}
		return out
	}

	testing.SetRealm(testing.NewUserRealm(gAlice))
	uassert.AbortsContains(t, cur, "title is too long", func() {
		Propose(cross(cur), "fee", "1", rep(governor.MaxTitle+1))
	})
	uassert.AbortsContains(t, cur, "payload is too long", func() {
		Propose(cross(cur), "fee", rep(governor.MaxPayload+1), "fine title")
	})

	// Exactly at each bound is allowed, so these are bounds rather than
	// off-by-ones that quietly cost a character.
	atTitle := Propose(cross(cur), "fee", "2", rep(governor.MaxTitle))
	if State(atTitle) != "active" {
		t.Errorf("a title of exactly governor.MaxTitle was refused")
	}
	// The payload has to stay something setFee accepts, so pad the number with
	// leading zeroes rather than letters.
	pad := "3"
	for len(pad) < governor.MaxPayload {
		pad = "0" + pad
	}
	atPayload := Propose(cross(cur), "fee", pad, "at the payload bound")
	if State(atPayload) != "active" {
		t.Errorf("a payload of exactly governor.MaxPayload was refused")
	}
}

// The front page lists each proposal once, on the right side of the fold.
//
// Render builds the open half from openIdx and the decided half from a reverse
// scan, which is what bounds the work — but it means one proposal can be found
// by both passes, and a proposal whose slot has not been reclaimed is found by
// the pass that does NOT match its computed state. Both cases have to come out
// as exactly one line, in the right section.
func TestTheFrontPageListsEachProposalOnce(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(setFee{}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 100,
	})
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(gAlice))
	// One that will lose on its deadline and NOT be settled: it keeps its slot,
	// so openIdx still holds it while its computed state is defeated.
	stale := Propose(cross(cur), "fee", "501", "unsettled loser")
	advanceBlocks(200)
	if got := State(stale); got != "defeated" {
		t.Fatalf("the stale proposal is %q, want defeated", got)
	}
	if State(stale) != "defeated" {
		t.Fatal("the stale proposal already gave up its slot, so this test is " +
			"no longer about one that has not")
	}
	// And one genuinely open.
	live := Propose(cross(cur), "fee", "502", "still being decided")

	page := Render("")
	for _, id := range []int64{stale, live} {
		mark := ufmt.Sprintf("[#%d]", id)
		if n := strings.Count(page, mark); n != 1 {
			t.Errorf("proposal %d appears %d times on the page, want 1:\n%s",
				id, n, page)
		}
	}

	// The live one is above the fold and the stale one is history. Located by
	// the section each falls in rather than by a fixed offset, because the
	// page has three sections now and which ones appear depends on what
	// exists.
	cut := strings.Index(page, "### finished")
	if cut < 0 {
		t.Fatalf("the page has no finished section, so there is nothing to be "+
			"on the wrong side of:\n%s", page)
	}
	toVoteOn, history := page[:cut], page[cut:]
	if !strings.Contains(toVoteOn, ufmt.Sprintf("[#%d]", live)) {
		t.Errorf("the open proposal is not in the voting section:\n%s", page)
	}
	if !strings.Contains(history, ufmt.Sprintf("[#%d]", stale)) {
		t.Errorf("a proposal that lost on its deadline is not in the finished "+
			"section, though it is still holding its slot:\n%s", page)
	}
}

// Preview refuses the same oversized payload Propose does.
//
// Propose got a bound last; Preview did not, and Preview is the cheaper door —
// a read rather than a transaction — handing the identical string to the
// identical Describe and Check. Bounding one door and not the other is not
// bounding anything, which is the same mistake as bounding a kind's name and
// leaving its title unbounded, made twice in a row.
func TestPreviewRefusesWhatProposeWouldRefuse(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(setFee{}, Rules{
		QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 10,
	})

	over := "1"
	for len(over) <= governor.MaxPayload {
		over = "0" + over
	}
	if got := Preview("fee", over); !strings.Contains(got, "too long") {
		t.Errorf("Preview accepted a payload Propose refuses:\n%s", got[:60])
	}

	// At the bound it works and still describes, so this is a bound rather
	// than a wall.
	at := "7"
	for len(at) < governor.MaxPayload {
		at = "0" + at
	}
	if got := Preview("fee", at); !strings.Contains(got, "set the fee to") {
		t.Errorf("Preview refused a payload of exactly governor.MaxPayload:\n%s", got)
	}
}

// The governor's own terms are the strictest in the realm, at their exact
// boundaries.
//
// Every other kind's rules are chosen by whoever offers it and can be retuned
// by a vote. These five numbers are the only ones nobody voted for, and what
// runs under them is adopting a power, retiring one, retuning terms, and moving
// the mint — the decisions that change what the governor can do at all.
//
// Both bars were unpinned. Dropping the quorum to nothing and the supermajority
// to a simple majority each left every test passing, which means the realm's
// constitution could have been relaxed by an edit nobody would notice in
// review.
//
// The quorum is pinned to the basis point here — 199 fails, 200 passes. The
// supermajority is pinned to within about ten, because doing better needs a
// supply of ten thousand to express 65.99% in whole tokens, and the arithmetic
// itself is already checked at its exact boundary by
// TestTheBarsAreCountedAtTheirExactBoundary. What this adds is that the
// GOVERNOR'S OWN kinds run on those numbers rather than on some other pair.
func TestTheGovernorsOwnTermsAreASupermajority(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	bigVoter := testutils.TestAddress("c-big")
	smallVoter := testutils.TestAddress("c-small")

	testing.SetRealm(testing.NewUserRealm(gAlice))
	// 660 and 340 of a thousand: exactly 66.00% for, which is the bar.
	Mint(cross(cur), bigVoter, 660)
	Mint(cross(cur), smallVoter, 340)
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(bigVoter))
	exact := Propose(cross(cur), "govern:minter", gBob.String(), "exactly the bar")
	Vote(cross(cur), exact, "yes")
	// Decided on that vote alone, and the arithmetic is the interesting part:
	// 660 for against a supply of 1000 clears two thirds EVEN IF every one of
	// the remaining 340 votes against, so nothing further could change it and
	// it closes then and there. Trying to cast that 340 afterwards is refused
	// with "that proposal is closed", which is how this test first failed.
	if got := State(exact); got != "succeeded" {
		t.Errorf("660 of a supply of 1000 voting for is %q, want succeeded — "+
			"that is exactly the two thirds the governor asks of itself, and "+
			"unbeatable by the rest", got)
	}
	testing.SetRealm(testing.NewUserRealm(smallVoter))
	uassert.AbortsContains(t, cur, "that proposal is closed", func() {
		Vote(cross(cur), exact, "no")
	})

	// One vote short of it. The same electorate, one token moved across.
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Mint(cross(cur), bigVoter, 659)
	Mint(cross(cur), smallVoter, 341)
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(bigVoter))
	under := Propose(cross(cur), "govern:minter", gBob.String(), "one short")
	Vote(cross(cur), under, "yes")
	testing.SetRealm(testing.NewUserRealm(smallVoter))
	Vote(cross(cur), under, "no")
	advanceBlocks(130000) // past the week-long deadline
	if got := State(under); got != "defeated" {
		t.Errorf("659 of 1000 for is %q, want defeated — a simple majority is "+
			"not enough to move the governor's own powers", got)
	}

	// And turnout alone can sink it. A fifth has to show up.
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Mint(cross(cur), bigVoter, 199)
	Mint(cross(cur), smallVoter, 801)
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(bigVoter))
	quiet := Propose(cross(cur), "govern:minter", gBob.String(), "nobody came")
	Vote(cross(cur), quiet, "yes")
	advanceBlocks(130000)
	if got := State(quiet); got != "defeated" {
		t.Errorf("199 of 1000 turning out is %q, want defeated — unanimous "+
			"among the fifth who voted, and short of the fifth required", got)
	}
	// Settled before the reason is read, because State COMPUTES an outcome and
	// only a transaction records one. Reading p.reason off an unsettled
	// proposal gets the empty string it was created with, which is how this
	// assertion first failed — against the read/write split this realm is
	// built on.
	Settle(cross(cur), quiet)
	if r := engine.Reason(quiet); r != "quorum not reached" {
		t.Errorf("it was defeated for %q, want the quorum — the bar it missed "+
			"was turnout, not agreement", engine.Reason(quiet))
	}

	// And exactly the fifth clears it: 199 fails above, 200 passes here, which
	// is what makes this a bar rather than a range.
	//
	// Last, and after everything the earlier ids are used for. resetLedger
	// resets propSeq as well as the trees, so a proposal on the far side of one
	// gets id 1 again — putting this block earlier made Settle(quiet) reach
	// THIS proposal instead, and the assertion above read a reason belonging to
	// a different question.
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Mint(cross(cur), bigVoter, 200)
	Mint(cross(cur), smallVoter, 800)
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(bigVoter))
	justEnough := Propose(cross(cur), "govern:minter", gBob.String(), "exactly a fifth")
	Vote(cross(cur), justEnough, "yes")
	advanceBlocks(130000)
	if got := State(justEnough); got != "succeeded" {
		t.Errorf("200 of 1000 turning out unanimously is %q, want succeeded — "+
			"that is exactly the fifth the governor asks for", got)
	}
}

// A completely full open list still renders a page somebody can load.
//
// That is what governor.MaxLive is FOR — the comment on it says it is the only thing
// between a determined proposer and a list nobody can read — and raising it to
// ten thousand passed every test. The bound existed and nothing depended on it.
//
// This is the assertion that ties the numbers together. The open section of the
// front page has no length cap of its own: every open proposal's title goes on
// it, so the page's worst case is governor.MaxLive titles at governor.MaxTitle each. Change
// either, or give the open section an unbounded field, and this fails. A page
// of a couple of megabytes is not a page.
func TestAFullOpenListStillRendersAPage(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))

	// The worst case is every field at its maximum, and the KIND is a field:
	// proposalLine renders it beside the title, so governor.MaxKindName is on this page
	// sixty-four times too. Using a short name like "fee" measures a page
	// nobody would be given by somebody trying.
	longKind := ""
	for len(longKind) < governor.MaxKindName {
		longKind += "k"
	}
	namedAs = longKind
	// A grace period because the governor.Reserved rows below are govern:rules
	// proposals against this kind, and a retune to a grace of zero is refused.
	offerAndAdopt(named{}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 100 * epochBlocks,
		GraceBlocks: 1000,
	})
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)

	title := ""
	for len(title) < governor.MaxTitle {
		title += "T"
	}

	testing.SetRealm(testing.NewUserRealm(gAlice))
	for i := 0; i < governor.MaxOpen; i++ {
		Propose(cross(cur), longKind, strconv.Itoa(i), title)
	}
	for i := 0; i < governor.GovLanes; i++ {
		Propose(cross(cur), governor.Reserved+"rules",
			longKind+" quorum="+strconv.Itoa(100+i), title)
	}
	if engine.OpenSlots() != governor.MaxLive {
		t.Fatalf("the open list holds %d of %d slots, so this is not measuring "+
			"a full one", engine.OpenSlots(), governor.MaxLive)
	}
	// And it is genuinely full: one more of either sort is refused.
	uassert.AbortsContains(t, cur, "too many proposals are already open", func() {
		Propose(cross(cur), longKind, "9999", title)
	})
	uassert.AbortsContains(t, cur, "too many proposals are already open", func() {
		Propose(cross(cur), governor.Reserved+"rules", longKind+" quorum=999", title)
	})

	page := Render("")
	t.Logf("a full open list renders %d bytes", len(page))
	// Sixty-four rows of a hundred-and-twenty title plus a sixty-four
	// character kind plus a link. Thirty-two thousand is loose enough to
	// survive somebody rewording a line, and tight enough that raising any of
	// the three numbers that multiply here cannot pass.
	if len(page) > 32_000 {
		t.Errorf("the front page is %d bytes with the list full, which is not a "+
			"page anybody loads", len(page))
	}
	// It really did list them, rather than being small by omission.
	if n := strings.Count(page, "](:"); n < governor.MaxLive {
		t.Errorf("the page links %d proposals of %d open", n, governor.MaxLive)
	}
	// And each row still says what KIND it is, which is the whole reason a
	// scanner can tell a treasury spend from a rename without opening either.
	// Dropping that field would make the page smaller, so a size assertion
	// alone rewards it.
	if n := strings.Count(page, longKind); n < governor.MaxOpen {
		t.Errorf("the page names the kind on %d rows of %d — a reader cannot "+
			"tell these apart without opening each one", n, governor.MaxOpen)
	}
}

// A proposal's page says what happens next, and does not contradict itself.
//
// "succeeded" is the one state where a reader has something to DO and no way to
// work out when — the proposal sits on the open list looking unfinished while a
// timelock it cannot see runs down.
//
// The three cases are genuinely different and the difference is not cosmetic.
// p.ready is set when the outcome is RECORDED, so for a proposal decided by its
// deadline and not yet settled it is zero, and every line computed from it is
// arithmetic against nothing — which prints "succeeded" and "expired" one line
// apart.
func TestAProposalsPageSaysWhatHappensNext(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	quiet := testutils.TestAddress("n-quiet")
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(setFee{}, Rules{
		QuorumBps: 2000, ThresholdBps: 6600,
		VotingBlocks: 10, DelayBlocks: 500, GraceBlocks: 1000,
	})
	Mint(cross(cur), gAlice, 600)
	Mint(cross(cur), quiet, 400)
	advanceEpochs(1)

	// 600 of 1000 clears quorum but is not decisive against the 400 uncast, so
	// this waits for its deadline — the case where the outcome outruns the
	// record.
	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "fee", "250", "lower the fee")
	Vote(cross(cur), id, "yes")
	advanceBlocks(50)
	if got := State(id); got != "succeeded" {
		t.Fatalf("after its deadline the proposal is %q, want succeeded", got)
	}

	page := Render("1")
	if !strings.Contains(page, "nobody has recorded it yet") {
		t.Errorf("a decided-but-unrecorded proposal does not say so:\n%s", page)
	}
	if strings.Contains(page, "Expired") {
		t.Errorf("the page calls a live proposal expired, from a delay that "+
			"has not started:\n%s", page)
	}

	// Recorded. Now the delay is real and the page can count it.
	Settle(cross(cur), id)
	page = Render("1")
	if !strings.Contains(page, "executable in") {
		t.Errorf("a recorded proposal inside its delay does not say when it "+
			"can run:\n%s", page)
	}
	// The HEIGHT, not just the phrase. A mutation naming p.closes here instead
	// of p.ready passed every test in the realm — so the page could have sent a
	// reader back at the wrong block, which is the entire content of the line.
	ready := timingReady(id)
	if !strings.Contains(page, "at height "+strconv.FormatInt(ready, 10)) {
		t.Errorf("the waiting line does not name the height %d it becomes "+
			"executable at:\n%s", ready, page)
	}

	// Past the delay, inside the grace period.
	advanceBlocks(600)
	if page = Render("1"); !strings.Contains(page, "Executable now") {
		t.Errorf("a proposal past its delay does not say it can be run:\n%s", page)
	}
	// And until when, by height. Dropping the grace from that sum told a reader
	// their window closed at the block it opened.
	until := ready + 1000
	if !strings.Contains(page, "until height "+strconv.FormatInt(until, 10)) {
		t.Errorf("the executable line does not name the height %d the window "+
			"closes at:\n%s", until, page)
	}

	// And past the grace period it is gone, which State agrees with — the two
	// must not disagree, which is the bug this test exists for.
	advanceBlocks(2000)
	page = Render("1")
	if got := State(id); got != "expired" {
		t.Fatalf("State says %q past the grace period", got)
	}
	if strings.Contains(page, "Executable now") {
		t.Errorf("the page offers to run an expired proposal:\n%s", page)
	}
	// The percentages are percentages, not basis points.
	if !strings.Contains(page, "20.00%") || !strings.Contains(page, "66.00%") {
		t.Errorf("the bars are not rendered as percentages:\n%s", page)
	}
}

// The front page groups proposals by what the reader is being asked to do.
//
// Both an active proposal and a decided one waiting out its timelock hold a
// slot. Under one heading called "open" a decision already taken looks like a
// question still being asked, with the only clue the state at the end of its
// own line.
//
// They ask different things of a holder. One wants a vote; the other wants
// somebody to run it.
func TestTheFrontPageGroupsByWhatToDo(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	quiet := testutils.TestAddress("g-quiet")
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(setFee{}, Rules{
		QuorumBps: 2000, ThresholdBps: 6600,
		VotingBlocks: 10, DelayBlocks: 5000, GraceBlocks: 100000,
	})
	Mint(cross(cur), gAlice, 600)
	Mint(cross(cur), quiet, 400)
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(gAlice))
	decided := Propose(cross(cur), "fee", "250", "already decided")
	Vote(cross(cur), decided, "yes")
	advanceBlocks(50)
	Settle(cross(cur), decided)
	if got := State(decided); got != "succeeded" {
		t.Fatalf("the first proposal is %q, want succeeded", got)
	}
	stillOpen := Propose(cross(cur), "fee", "260", "still being asked")

	page := Render("")
	vote := strings.Index(page, "### to vote on")
	wait := strings.Index(page, "### decided, waiting to be run")
	if vote < 0 || wait < 0 {
		t.Fatalf("the page does not have both sections:\n%s", page)
	}
	// Each in its own section, located by position rather than by presence:
	// both are on the page either way, and the whole point is WHICH heading
	// they fall under.
	openMark := ufmt.Sprintf("[#%d]", stillOpen)
	waitMark := ufmt.Sprintf("[#%d]", decided)
	if i := strings.Index(page, openMark); i < vote || i > wait {
		t.Errorf("the proposal still being voted on is not under 'to vote "+
			"on':\n%s", page)
	}
	if i := strings.Index(page, waitMark); i < wait {
		t.Errorf("a decided proposal is listed as something to vote on:\n%s", page)
	}

	// And with nothing to vote on, the page says so rather than omitting the
	// section — otherwise a reader cannot tell "nothing to do" from "this page
	// is broken".
	Cancel(cross(cur), stillOpen)
	if page = Render(""); !strings.Contains(page, "Nothing to vote on") {
		t.Errorf("with no open questions the page does not say so:\n%s", page)
	}
	if !strings.Contains(page, "waiting to be run") {
		t.Errorf("the decided proposal vanished with the voting section:\n%s", page)
	}

	// The supply reads as the token, with the raw figure beside it for
	// checking against every other number on the page.
	if !strings.Contains(page, "0.001 "+tokenSymbol) {
		t.Errorf("the supply is not rendered at the token's decimals:\n%s", page)
	}
	if !strings.Contains(page, "1000 at 6 decimals") {
		t.Errorf("the raw supply is not shown beside it:\n%s", page)
	}
}

// Every term is checkable at the door, and every term is retunable afterwards.
//
// Two halves of one gap. The validator is easy to write twice — Offer panics,
// govern:rules returns — and two copies claiming to enforce the same thing
// drift apart; the term they both stop checking is what a proposer must hold.
// The retune path is just as easy to write for five of the six terms, with
// ProposeBps the one left out.
//
// Those compound. Above a hundred percent, ProposeBps asks a proposer to hold
// more than everything, so nobody can open a question under that kind — and it
// was the one term nobody could retune, so the kind was adopted, unusable and
// unfixable. The only field where a bad value bricks a kind was the only field
// with neither a check nor a cure.
// Every one of the governor's own kinds is protected, not just the one that
// was checked.
//
// The existing test named govern:adopt, which is the most alarming to lose —
// retire it and no kind can ever be adopted again, with no proposal able to
// restore it. But the rule is about the prefix, and a rule tested through one
// example is a rule tested for one example.
//
// The prefix test is one predicate for both callers, Offer and govern:retire.
// Written twice it drifts, and this is the copy where drifting is
// unrecoverable.
// Adoption refuses what it should, which is worth more here than anywhere else.
//
// Adopting is the act that GRANTS a power: everything else in this realm
// decides how a power is used, and this decides whether it exists. Its two
// refusals had no test at all.
//
// Neither failure is catastrophic on its own — adopting an unoffered name
// panics rather than granting anything, and adopting a live kind sets a flag
// that is already set. What they cost is the two-step itself. The whole design
// rests on publishing code and granting it authority being separate decisions,
// taken by different people at different times, and a Check that waves either
// through turns a vote into a formality that happens to pass.
// Nothing can be proposed before there is anybody to decide it.
//
// A realm that has sealed an epoch but never minted has an electorate of zero.
// Without this refusal a proposal opens against it and can never be resolved by
// anybody: every would-be voter is turned away with "no voting power at that
// epoch", because at that epoch nobody had any. It occupies a slot until its
// deadline and then loses for want of support.
//
// Which is the launch order in doc.gno seen from the other side — mint the
// supply before anything else — and the failure if it is ignored. governor.MaxLive is
// sixty-four, so somebody proposing before the token exists can fill the list
// with questions nobody is able to answer.
func TestNothingCanBeProposedBeforeThereIsAnElectorate(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	// An epoch passes with nothing minted, so there IS a sealed epoch — the
	// realm is past its cold start — and still nobody in it.
	advanceEpochs(1)
	if got := PastTotalVotes(Epoch() - 1); got != 0 {
		t.Fatalf("the sealed epoch holds %d, want 0 — this test needs an empty "+
			"electorate", got)
	}

	testing.SetRealm(testing.NewUserRealm(gAlice))
	uassert.AbortsContains(t, cur, "nothing was in issue at that epoch", func() {
		Propose(cross(cur), "govern:minter", gBob.String(), "before anybody holds anything")
	})
	if engine.OpenSlots() != 0 {
		t.Errorf("a proposal nobody could vote on took %d slots", engine.OpenSlots())
	}

	// Mint, seal, and the same proposal is fine — so the refusal is about the
	// electorate being empty and not about anything else.
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Mint(cross(cur), gAlice, 100)
	advanceEpochs(1)
	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "govern:minter", gBob.String(), "now there is somebody")
	if State(id) != "active" {
		t.Errorf("with an electorate the proposal is %q", State(id))
	}
}

// A batch payload survives the whitespace a human types, and says so when a
// line is not a member.
//
// The payload is one member per line, typed into a wallet or a forum post, so
// it arrives with a trailing newline and sometimes a blank line between
// members. parseBatch skips blanks for exactly that reason and nothing tested
// it: without the skip a trailing newline is a member with no payload, and the
// batch is refused with a message about the empty line rather than about
// anything the proposer did wrong.
//
// The other half is the refusal itself. A line with no space is almost always a
// typo — a kind name and no argument — and a batch is the wrong place to
// discover that, since the alternative is finding out during execution with
// earlier members already applied.
func TestABatchPayloadToleratesWhitespaceAndRefusesHalfLines(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(setFee{}, Rules{QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 50 * epochBlocks})
	offerAndAdopt(spend{}, Rules{QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 50 * epochBlocks})
	Mint(cross(cur), gAlice, 900)
	advanceEpochs(1)

	// What a person actually types: a trailing newline, a blank line between
	// members, and indentation.
	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "govern:batch",
		"fee 250\n\n  treasury/spend 4  \n", "typed by a human")
	if State(id) != "active" {
		t.Fatalf("a batch with ordinary whitespace was refused: %q", State(id))
	}
	desc := Describe(id)
	for _, want := range []string{"do all 2 of these", "set the fee to 250 bps", "pay out 4"} {
		if !strings.Contains(desc, want) {
			t.Errorf("the batch does not describe %q:\n%s", want, desc)
		}
	}

	// A line that is not a member is refused at the door, naming the line.
	uassert.AbortsContains(t, cur, "expected `<kind> <payload>`", func() {
		Propose(cross(cur), "govern:batch", "fee 250\ntreasury/spend", "a half line")
	})
	// Including when it is the first one.
	uassert.AbortsContains(t, cur, "expected `<kind> <payload>`", func() {
		Propose(cross(cur), "govern:batch", "fee\ntreasury/spend 4", "a half line first")
	})
}

// The quorum's denominator is the sealed supply, not the supply now.
//
// TestVotingPowerIsSnapshotted holds the numerator: a balance acquired after a
// proposal opens carries no weight on it. Nothing held the DENOMINATOR, and the
// two have to be taken at the same moment or the fraction compares a past
// numerator against a present total.
//
// The gap is exploitable in the cheap direction. Mint into the current epoch
// and every proposal opened before the next one seals is measured against a
// supply that none of its voters own: their weights come from the sealed epoch
// and sum to the old total, while quorum asks for a fraction of the new one. A
// tenfold mint makes a proposal roughly ten times harder to carry, and the
// proposer's own stake requirement rises with it.
//
// This is the same asymmetry as PastVotes having a sealed-epoch guard while
// PastTotalVotes had none, found the same way: mutating the implementation
// behind an interface, which nothing calls directly and therefore nothing had
// tested on its own.
func TestTheQuorumDenominatorIsAlsoSnapshotted(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)

	// The supply is multiplied AFTER the epoch the vote will be weighed at.
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Mint(cross(cur), gBob, 9000)
	if got := TotalSupply(); got != 10000 {
		t.Fatalf("the supply is %d, want 10000 — this test needs it to have "+
			"moved since the sealed epoch", got)
	}

	offerAndAdopt(setFee{}, Rules{
		QuorumBps: 5000, ThresholdBps: 5000, VotingBlocks: 50 * epochBlocks,
		GraceBlocks: 100,
	})
	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "fee", "310", "weighed against the sealed supply")

	_, _, _, total := Tally(id)
	if total != 1000 {
		t.Errorf("the proposal is weighed against %d, want 1000 — the supply "+
			"at the sealed epoch, not the supply now", total)
	}

	// And the PAGE agrees. Tally is what a program reads and the page is what a
	// holder reads; a mutation switching the rendered denominator to the live
	// supply passed every test in this realm. The page could have shown turnout
	// against 10,000 while the state was decided against 1,000 — in the one
	// case the snapshot exists for — and a reader checking the arithmetic would
	// have got a different answer from the realm and been right.
	if page := Render(strconv.FormatInt(id, 10)); !strings.Contains(page, "turnout 0 of 1000,") {
		t.Errorf("the page weighs turnout against something other than the "+
			"sealed supply of 1000:\n%s", page)
	}

	// And the arithmetic follows: alice held everything that existed when the
	// epoch sealed, so her vote alone is the whole electorate and carries it.
	// Against the live supply it would be a tenth, and nothing could pass.
	Vote(cross(cur), id, "yes")
	if got := State(id); got != "succeeded" {
		t.Errorf("the holder of the entire sealed supply voting yes left it "+
			"%q — a mint after the snapshot moved a bar that was already set", got)
	}
}

// The same number reads the same way wherever a holder meets it.
//
// Periods appear on two pages: the adoption proposal that grants a kind its
// terms, and the rules proposal that changes one. They were rendered
// differently — "34560 blocks (about 2 days)" when granted, and a bare "34560
// blocks" when changed — so the reader who most needs to compare the two, the
// one voting on a change, was the one shown less.
func TestAPeriodReadsTheSameOnBothPages(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	engine.Adopt(moody{}, Rules{
		QuorumBps: 2000, ThresholdBps: 6600,
		VotingBlocks: 100, DelayBlocks: 34560, GraceBlocks: 241920,
	})

	change := Preview("govern:rules", "span/probe delay=34560")
	if !strings.Contains(change, "34560 blocks (about 2 days)") {
		t.Errorf("a rules change renders a period without its duration:\n%s", change)
	}
	// And the bars still render as percentages, which is the other half of the
	// same idea.
	change = Preview("govern:rules", "span/probe quorum=3000")
	if !strings.Contains(change, "30.00%") {
		t.Errorf("a rules change renders a bar without its percentage:\n%s", change)
	}

	// Now the adoption page for a kind with the same delay, which is where a
	// holder saw the duration already.
	namedAs = "span/other"
	engine.Offer(alice, named{}, Rules{
		QuorumBps: 2000, ThresholdBps: 6600,
		VotingBlocks: 100, DelayBlocks: 34560, GraceBlocks: 241920,
	})
	grant := Preview("govern:adopt", "span/other")
	if !strings.Contains(grant, "34560 blocks (about 2 days)") {
		t.Errorf("the adoption page renders a period without its duration:\n%s", grant)
	}
}

// The supply reads the same on a proposal's page as on the front page, and the
// tally stays raw.
//
// Both are deliberate and they look contradictory, which is why they are
// pinned together. The snapshot supply is the same quantity the header shows,
// so it is shown the same way. The tally is not a quantity to read, it is an
// arithmetic a reader is invited to check — "yes is 600 of 600 cast, needs
// 66.00%" only works if the numbers are the ones being multiplied.
//
// Rendering the tally in whole tokens would round the check away, which is a
// worse outcome than the inconsistency it would tidy.
func TestTheProposalPageRendersSupplyLikeTheFrontPage(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(setFee{}, Rules{
		QuorumBps: 2000, ThresholdBps: 6600, VotingBlocks: 50 * epochBlocks,
	})
	Mint(cross(cur), gAlice, 1500000) // 1.5 COURT at six decimals
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "fee", "250", "check the numbers")

	front := Render("")
	if !strings.Contains(front, "1.5 "+tokenSymbol) {
		t.Fatalf("the front page does not render the supply in tokens:\n%s", front)
	}

	page := Render(strconv.FormatInt(id, 10))
	if !strings.Contains(page, "1.5 "+tokenSymbol) {
		t.Errorf("the proposal page renders the snapshot supply differently "+
			"from the front page:\n%s", page)
	}
	// The raw figure is there too, because everything below is measured
	// against it. Asserted on the whole phrase rather than on the number: the
	// number appears in the turnout line as well, so a bare Contains passed
	// while the snapshot line said "(0)".
	if !strings.Contains(page, "was in issue (1500000)") {
		t.Errorf("the proposal page drops the raw snapshot figure:\n%s", page)
	}

	// And the tally is raw, so the arithmetic on the line below it can be
	// checked by hand.
	Vote(cross(cur), id, "yes")
	page = Render(strconv.FormatInt(id, 10))
	if !strings.Contains(page, "yes 1500000") {
		t.Errorf("the tally is not in the units its own arithmetic uses:\n%s", page)
	}
	if !strings.Contains(page, "turnout 1500000 of 1500000") {
		t.Errorf("the turnout line is not checkable against the tally:\n%s", page)
	}
}

// units renders a base-unit amount, and it has to be total.
//
// Its two callers today are supply figures, which cannot be negative, so the
// negative cases below are not reachable from the realm as it stands. They are
// here because the function already had a branch for them — it took the
// absolute value of the fraction — and a branch that exists is a promise that
// the case is handled. It was not: the sign lives in the whole part, which is
// zero for everything between -1 and 0, so half the negative range rendered as
// its own opposite.
//
// The scale is checked against tokenDecimals rather than assumed. pct derives
// its divisor from the constant for exactly this reason; units was written with
// the literal instead, so a change to the decimals would have moved every
// padded fraction and left the divisor behind.
// A batch cannot run a kind that an earlier member of the same batch retired.
//
// Check walks every member and requires each one live, which is why the guard
// in Do that repeats the question looks like belt and braces — and a mutation
// deleting it survived the whole suite. It is not belt and braces. Check runs
// once, before any member has done anything; the members then run in order,
// and one of them can be govern:retire. So a batch of "retire fee" followed by
// "fee 250" passes Check with both kinds live and reaches the second member
// with the first already having taken the power away.
//
// The batch aborts rather than recording a failure, which is what the
// all-or-nothing promise means: nothing happened, including the retirement.
// Asserted through the handler's own effect rather than through the registry,
// because this harness does not unwind package state on an abort the way a
// chain does — the abort is the observation, and feeBps is the evidence that
// the second member never ran.
func TestABatchCannotRunAKindAnEarlierMemberRetired(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	feeBps = 0
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(setFee{}, Rules{QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 50 * epochBlocks})
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "govern:batch", "govern:retire fee\nfee 250",
		"retire it and then use it")
	Vote(cross(cur), id, "yes")
	if got := State(id); got != "succeeded" {
		t.Fatalf("the batch is %q, want succeeded — Check accepted it, which is "+
			"the premise of this test", got)
	}
	// govern:batch is a built-in, so it runs on the bootstrap timelock.
	advanceBlocks(3 * 24 * 60 * 60 / 5)

	uassert.AbortsContains(t, cur, "no longer adopted", func() {
		Execute(cross(cur), id)
	})
	if feeBps != 0 {
		t.Errorf("the fee is %d: a batch member ran under a power the batch "+
			"itself had already withdrawn", feeBps)
	}
}

// A batch that fails halfway leaves nothing behind — not even the failure.
//
// This is the all-or-nothing promise, and it is stated in three places: the
// comment on batchKind, doc.gno's "what it will not do", and docs/DESIGN.md. Nothing
// tested it. Turning the panic in batchKind.Do into a returned error — which is
// how every other kind reports failure, and therefore the tidying somebody
// would do — left the whole suite green.
//
// The two are very different. A returned error records the proposal as Failed
// and KEEPS whatever the earlier members already did, which is the one outcome
// a batch promises cannot happen. The panic aborts the transaction, and
// aborting is the only rollback gno has.
//
// What that looks like from outside is the assertion below: the proposal is
// still Succeeded. Nothing was written, including the failure, so it can be
// tried again and will fail identically until the world changes or the grace
// period ends it. That is the honest reading of a transaction that did not
// happen.
//
// The unwinding of the first member's effect cannot be shown here — this
// harness does not roll package state back on an abort the way a chain does —
// so what is asserted is the abort, which is the mechanism that does the
// rolling back, and the state that was not recorded because of it.
func TestAFailedBatchLeavesNothingBehindNotEvenTheFailure(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	feeBps, moodyRan = 0, 0
	moodyCheckFails, moodyDoFails = false, true
	defer func() { moodyDoFails = false; moodyRan = 0 }()

	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(setFee{}, Rules{QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 50 * epochBlocks})
	engine.Adopt(moody{}, Rules{
		QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 50 * epochBlocks, GraceBlocks: 1_000_000,
	})
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "govern:batch", "fee 250\nmoody/thing x",
		"one that works and one that does not")
	Vote(cross(cur), id, "yes")
	advanceBlocks(3 * 24 * 60 * 60 / 5)

	uassert.AbortsContains(t, cur, "batch member 2", func() {
		Execute(cross(cur), id)
	})
	if moodyRan != 1 {
		t.Fatalf("the failing member ran %d times, want 1 — if it never ran, "+
			"the abort came from somewhere else", moodyRan)
	}
	if got := State(id); got != "succeeded" {
		t.Errorf("after a batch failed halfway the proposal is %q, want "+
			"succeeded — a returned error would record it as failed and keep "+
			"what the first member did, which is the outcome a batch promises "+
			"cannot happen", got)
	}
}

// The front page stops growing, however long the history gets.
//
// The finished section walks every proposal the realm has ever held, newest
// first, and stops once it has enough. Deleting that stop left the suite green
// — every other test has a handful of proposals, where capped and uncapped
// produce the same page.
//
// It is the read every holder makes, and the one whose cost nobody sees until
// it is too late: the page looked identical the whole way, while the work
// behind it grew with the archive forever. This realm shipped that once and
// removed it.
func TestTheFrontPageStopsGrowingWithTheHistory(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)

	engine.Adopt(setFee{name: "hist/kind"}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 50, GraceBlocks: 1_000_000,
	})
	testing.SetRealm(testing.NewUserRealm(gAlice))
	var ids []int64
	for i := 0; i < governor.MaxOpen; i++ {
		ids = append(ids, Propose(cross(cur), "hist/kind", strconv.Itoa(i), "history"))
	}
	// Nobody voted, so every one of them loses on its deadline.
	advanceBlocks(100)
	for _, id := range ids {
		Settle(cross(cur), id)
	}

	page := Render("")
	rows := strings.Count(page, "](:")
	if rows >= len(ids) {
		t.Errorf("the page lists %d rows for %d finished proposals: the "+
			"history section has no cap, so this page grows forever and the "+
			"work behind it grows with the archive", rows, len(ids))
	}
	if rows == 0 {
		t.Fatal("the page lists nothing at all, so the cap is not what is " +
			"being measured here")
	}

	// Newest first, so the most recent decision is on the page and the oldest
	// is what got dropped. A cap that kept the wrong end would be worse than
	// none: the page would freeze on the realm's first week forever.
	newest := "](:" + strconv.FormatInt(ids[len(ids)-1], 10) + ")"
	if !strings.Contains(page, newest) {
		t.Errorf("the newest finished proposal is missing from the page, so "+
			"the cap is keeping the oldest rather than the newest:\n%s", page)
	}
	oldest := "](:" + strconv.FormatInt(ids[0], 10) + ")"
	if strings.Contains(page, oldest) {
		t.Errorf("the oldest of %d finished proposals is still listed, so the "+
			"cap is not dropping anything", len(ids))
	}
}

// A proposal's own page says what state it is in.
//
// Blanking the state left every test green: the page still rendered, the
// heading and the description and the tally were all correct, and the one line
// telling a reader whether the thing had passed said "- state: ****".
func TestAProposalsPageNamesItsState(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)

	engine.Adopt(setFee{name: "state/kind"}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 50, GraceBlocks: 1_000_000,
	})
	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "state/kind", "7", "what state am i in")

	page := Render(strconv.FormatInt(id, 10))
	if !strings.Contains(page, "**active**") {
		t.Errorf("an open proposal's page does not say it is active:\n%s", page)
	}

	// And it follows the proposal rather than being written once.
	advanceBlocks(100)
	page = Render(strconv.FormatInt(id, 10))
	if !strings.Contains(page, "**defeated**") {
		t.Errorf("a proposal past its deadline does not say it is defeated:\n%s", page)
	}
}

// A proposal whose kind has gone renders its payload as text, not as page.
//
// describeOf's fallback exists for a kind that has been retired or was never
// registered here, and it puts the payload in an indented code block. The four
// spaces were written once, in front of the whole string — which indents the
// first line and leaves every other one as live markdown.
//
// Payloads may contain newlines; govern:batch is defined in terms of them. So a
// payload could carry a heading and a row that reads like a proposal, on the
// page for a proposal whose kind nobody can consult any more. It is the one
// place a payload is rendered with nothing left to have vetted it: the checking
// belonged to that kind's Check, and the kind is what is missing.
// The pages say what a zero MEANS, term by term, because it differs per term.
//
// Zero is the value a governance page is worst at: it is the default, and it is
// what somebody types to switch a thing off. Across the six terms it means
// three different things, and one of them is refused outright.
//
//	delay=0    no timelock
//	propose=0  no stake check at all, so any address may open one holding
//	           nothing — and the line was omitted entirely, which reads as
//	           "not applicable" rather than "anybody"
//	grace=0    REFUSED. Read as "never expires" it leaks a slot for the life
//	           of the realm: a Succeeded proposal keeps its place until it
//	           runs, and nothing ends one that has no grace period.
//	voting=0   refused; a vote needs a period
func TestTheTermsPagesSayWhatAZeroMeans(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	testing.SetRealm(testing.NewUserRealm(gCarl))
	namedAs = "terms/thing"
	Offer(cross(cur), named{}, NewRules(2000, 5100, 100, 0, 1000, 0))

	page := Preview("govern:adopt", "terms/thing")
	// A zero delay reads as no delay, which is what it means.
	if !strings.Contains(page, "delay before it can run: no period") {
		t.Errorf("a zero delay does not read as no delay:\n%s", page)
	}
	// The sixth term, which must not vanish when it is zero — which is when it
	// matters most, because zero means any address may open one holding
	// nothing.
	if !strings.Contains(page, "who may propose: anybody, holding nothing") {
		t.Errorf("the page does not say who may propose when the answer is "+
			"'anybody' — the most permissive term is the one it left out:\n%s", page)
	}
	// And a real bar still renders as a fraction of the supply.
	namedAs = "gated/thing"
	testing.SetRealm(testing.NewUserRealm(gCarl))
	Offer(cross(cur), named{}, NewRules(2000, 5100, 100, 0, 1000, 500))
	if got := Preview("govern:adopt", "gated/thing"); !strings.Contains(got,
		"who may propose: 5.00% of the supply") {
		t.Errorf("a real proposer bar stopped rendering as a fraction:\n%s", got)
	}

	// A grace of zero is refused rather than rendered, on both paths that could
	// set one: offering a kind, and retuning an adopted one.
	namedAs = "forever/thing"
	testing.SetRealm(testing.NewUserRealm(gCarl))
	uassert.AbortsContains(t, cur, "a decision has to expire", func() {
		Offer(cross(cur), named{}, NewRules(2000, 5100, 100, 0, 0, 0))
	})
	if got := Preview("govern:rules", "govern:adopt grace=0"); !strings.Contains(
		got, "a decision has to expire") {
		t.Errorf("a proposal to stop decisions expiring is not refused:\n%s", got)
	}
	// A real grace still renders as a duration.
	if got := Preview("govern:rules", "govern:adopt grace=17280"); !strings.Contains(got, "17280 blocks") {
		t.Errorf("a non-zero grace stopped rendering as a span:\n%s", got)
	}
}

// The page must not deny the votes it has just counted.
//
// The threshold weighs yes against yes+no and has nothing to weigh when every
// vote was an abstention. That is not the same as nobody voting, and a page
// that treats them alike prints "turnout 1000 of 1000, needs 20.00% · no votes
// cast" — asserting and denying the same fact on one line.
//
// It is the worst case to get wrong. An all-abstained proposal is the one that
// would pass with nobody in favour, and the support bar exists because of it,
// so this is the page whose reader most needs it right.
func TestAnAllAbstainedPageDoesNotSayNobodyVoted(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)
	engine.Adopt(setFee{name: "ab/kind"}, Rules{
		QuorumBps: 2000, ThresholdBps: 5000, VotingBlocks: 100000, GraceBlocks: 1_000_000,
	})
	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "ab/kind", "5", "everybody abstains")
	Vote(cross(cur), id, "abstain")

	page := Render(strconv.FormatInt(id, 10))
	if strings.Contains(page, "no votes cast") {
		t.Errorf("the page says no votes were cast on a proposal the whole "+
			"supply abstained on:\n%s", page)
	}
	if !strings.Contains(page, "every vote was an abstention") {
		t.Errorf("the page does not explain why the threshold is empty:\n%s", page)
	}
	// The OTHER half of the same line. Abstentions count towards quorum — that
	// is the whole reason the support bar had to exist — so the turnout must
	// show them. Asserting only the threshold half left a mutation free to
	// render "turnout 0 of 1000" beside "every vote was an abstention", which
	// contradicts itself exactly as the old wording did.
	if !strings.Contains(page, "turnout 1000 of 1000") {
		t.Errorf("the turnout does not count the abstentions it just described, "+
			"though abstain counts towards quorum:\n%s", page)
	}
	// And the genuinely silent case still reads as silence.
	quiet := Propose(cross(cur), "ab/kind", "6", "nobody votes")
	if got := Render(strconv.FormatInt(quiet, 10)); !strings.Contains(got, "no votes cast") {
		t.Errorf("a proposal nobody voted on stopped saying so:\n%s", got)
	}
}

// The slot count is a fact about the realm, not about the section under it.
//
// nOpen counts everything holding a slot, which includes proposals already
// decided and waiting to be run. As part of the "to vote on" heading it
// therefore sat above a list shorter than itself — "3 of 64 slots used" with
// two rows beneath it — and a reader counts the rows.
//
// The other half is worse. With every slot held by decided proposals the count
// vanished with the heading, so a realm that was refusing new proposals for
// being full rendered as a quiet one with nothing to vote on.
func TestTheSlotCountBelongsToThePageNotTheSection(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)
	engine.Adopt(setFee{name: "waiting/k"}, Rules{
		QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 100000,
		DelayBlocks: 99999, GraceBlocks: 999999,
	})
	engine.Adopt(setFee{name: "voting/k"}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 100000, GraceBlocks: 1_000_000,
	})

	// One decided and waiting, two still open: three slots, two votable rows.
	testing.SetRealm(testing.NewUserRealm(gAlice))
	decided := Propose(cross(cur), "waiting/k", "1", "decided already")
	Vote(cross(cur), decided, "yes")
	Propose(cross(cur), "voting/k", "2", "open one")
	Propose(cross(cur), "voting/k", "3", "open two")

	page := Render("")
	if !strings.Contains(page, "3 of 64 slots in use.") {
		t.Errorf("the page does not report the slots it is holding:\n%s", page)
	}
	// The count must not be attached to the heading whose list is shorter.
	if strings.Contains(page, "to vote on (3") {
		t.Errorf("the slot count is back on the voting heading, above a list of "+
			"two:\n%s", page)
	}

	// And with NOTHING votable, the page still says it is holding a slot.
	//
	// resetLedger reinstalls the built-in kinds and clears everything else, so
	// the kind has to be registered again — which is the reset doing its job:
	// it caught this test relying on registry state surviving it.
	resetLedger()
	engine.Adopt(setFee{name: "waiting/k"}, Rules{
		QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 100000,
		DelayBlocks: 99999, GraceBlocks: 999999,
	})
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)
	only := Propose(cross(cur), "waiting/k", "9", "the only one, decided")
	Vote(cross(cur), only, "yes")
	quiet := Render("")
	if !strings.Contains(quiet, "1 of 64 slots in use.") {
		t.Errorf("a realm holding a slot with nothing votable reports no slots "+
			"at all, so being full looks like being quiet:\n%s", quiet)
	}
	if !strings.Contains(quiet, "Nothing to vote on") {
		t.Errorf("the page stopped saying there is nothing to vote on:\n%s", quiet)
	}
}

// The page a holder votes from says how long they have.
//
// The "what happens next" block was written for the succeeded state, on the
// reasoning that it is the one state where a reader has something to do and no
// way to know when. That is right, and it stopped one state short: an ACTIVE
// proposal is where the reader has the most to do, and the page gave them the
// tally, both bars and the state without ever saying when voting ended.
func TestAnActiveProposalSaysWhenVotingCloses(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)
	const window = int64(4321)
	engine.Adopt(setFee{name: "clock/k"}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: window, GraceBlocks: 1_000_000,
	})
	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "clock/k", "5", "how long have i got")

	page := Render(strconv.FormatInt(id, 10))
	if !strings.Contains(page, "Voting closes in") {
		t.Errorf("an open proposal does not say when voting closes:\n%s", page)
	}
	// The HEIGHT as well as the countdown, because a countdown read at one
	// block is wrong at the next and a height is not.
	_, closes, _, _ := Timings(id)
	if !strings.Contains(page, strconv.FormatInt(closes, 10)) {
		t.Errorf("the page does not name the closing height %d:\n%s", closes, page)
	}

	// It counts down rather than being written once.
	advanceBlocks(window / 2)
	later := Render(strconv.FormatInt(id, 10))
	if later == page {
		t.Errorf("the page is identical %d blocks later, so the countdown is "+
			"not counting:\n%s", window/2, later)
	}

	// And a closed proposal does not claim voting is still open.
	advanceBlocks(window)
	if got := Render(strconv.FormatInt(id, 10)); strings.Contains(got, "Voting closes in") {
		t.Errorf("a proposal past its deadline still says voting closes:\n%s", got)
	}
}

// A refusal says what would fix it, where the realm already knows.
//
// Two of them withheld numbers they were holding. "not enough voting power to
// open this" left a proposer to work out from the terms page what they were
// short of — and, worse, said nothing about WHEN the weight was measured, so a
// holder with plenty now and nothing at the sealed epoch read the
// anti-flash-loan rule as a bug. "still in the delay window" said not yet
// without saying when, which is an invitation to poll.
func TestARefusalSaysWhatWouldFixIt(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)
	// A bar bob cannot clear: he holds nothing at the sealed epoch.
	engine.Adopt(setFee{name: "bar/k"}, Rules{
		QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 1000,
		DelayBlocks: 700, GraceBlocks: 9000, ProposeBps: 2500,
	})

	testing.SetRealm(testing.NewUserRealm(gBob))
	uassert.AbortsContains(t, cur, "25.00% of the supply is required", func() {
		Propose(cross(cur), "bar/k", "5", "bob tries")
	})
	// The epoch it was weighed at, BY NUMBER. Asserting the phrase alone lets
	// the wrong epoch pass — which is the failure this whole message exists to
	// prevent, since holding plenty now and nothing then is the case that reads
	// as a fault rather than as the rule working.
	at := Epoch() - 1
	uassert.AbortsContains(t, cur, "at epoch "+strconv.FormatUint(uint64(at), 10), func() {
		Propose(cross(cur), "bar/k", "5", "bob tries")
	})
	// And what he actually held, which is nothing. Every number in a message
	// needs its own assertion — pinning the phrase and the bar alone lets both
	// the epoch and the holding be reported wrongly.
	uassert.AbortsContains(t, cur, "you held 0 of 1000", func() {
		Propose(cross(cur), "bar/k", "5", "bob tries")
	})

	// And the timelock names the height rather than saying "not yet".
	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "bar/k", "6", "alice can")
	Vote(cross(cur), id, "yes")
	uassert.AbortsContains(t, cur, "executable at height "+strconv.FormatInt(timingReady(id), 10), func() {
		Execute(cross(cur), id)
	})
}

// A batch's description and its failure message count members the same way.
//
// Two independent `i+1`s, in two files, for one number a reader uses to join
// them up: the description lists "2. **kind** — ..." and a failed execution
// says "batch member 2 (kind) failed". If either drifted, somebody reading a
// failure would go and look at the wrong member — and a batch is the one kind
// where members are told apart only by position.
//
// Numbering the description from zero passed every test in the realm. Both
// numbers are pinned here, together, because the property is that they AGREE
// and neither one alone can carry it.
func TestABatchNumbersItsMembersTheSameWayTwice(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	feeBps, moodyRan = 0, 0
	moodyCheckFails, moodyDoFails = false, true
	defer func() { moodyDoFails = false; moodyRan = 0 }()

	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(setFee{}, Rules{QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 50 * epochBlocks})
	engine.Adopt(moody{}, Rules{
		QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 50 * epochBlocks, GraceBlocks: 1_000_000,
	})
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)

	// Three members, and the one that fails is in the middle so an off-by-one
	// in either direction names a different kind.
	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "govern:batch",
		"fee 1\nmoody/thing x\nfee 2", "three, the middle one fails")

	// The description numbers from one, and the failing member is second.
	desc := Describe(id)
	if !strings.Contains(desc, "2. **moody/thing**") {
		t.Errorf("the description does not list the failing member as 2:\n%s", desc)
	}
	if strings.Contains(desc, "0. **fee**") {
		t.Errorf("the description numbers its members from zero:\n%s", desc)
	}

	// And the failure names the same number.
	Vote(cross(cur), id, "yes")
	advanceBlocks(3 * 24 * 60 * 60 / 5)
	uassert.AbortsContains(t, cur, "batch member 2 (moody/thing)", func() {
		Execute(cross(cur), id)
	})
}

// A kind's Do gets a SUB-REALM, not this realm's own capability.
//
// The interface calls rlm "the realm as data". It was not: Execute passed its
// live cur straight through, so inside a foreign kind's Do, IsCurrent() was
// true and PkgPath() was "gno.land/r/cryptocourt/govern". That is govern's authority,
// handed to code adopted for one purpose — enough to cross() into any realm
// that trusts govern and be seen as it, to issue this realm's tokens, and to
// call Mint as the realm itself.
//
// Adoption is meant to grant one power. It granted the governor's identity.
func TestAKindGetsASubRealmNotTheGovernorsOwn(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	capturedPath, capturedAddr, capturedRan = "", "", false
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	offerAndAdopt(capturer{}, Rules{QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 50})
	Mint(cross(cur), gAlice, 1000)
	advanceEpochs(1)
	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "capture/realm", "x", "what does a kind receive")
	Vote(cross(cur), id, "yes")
	Execute(cross(cur), id)

	if !capturedRan {
		t.Fatal("the handler never ran, so it captured nothing")
	}
	// The sub-path names the power, so a governed realm can gate on the kind
	// it granted rather than on the governor as a whole.
	if !strings.Contains(capturedPath, "#capture-realm") {
		t.Errorf("a kind received the realm %q, want a sub-realm naming the "+
			"kind — this is the governor's own capability if it is not", capturedPath)
	}
	if strings.HasSuffix(capturedPath, "/govern") {
		t.Errorf("a kind received the governor's own pkgpath (%q): it can act "+
			"as govern anywhere govern is trusted", capturedPath)
	}
	// And a distinct address, so every Previous()-based gate — Mint's among
	// them — stops matching.
	if capturedAddr == "" {
		t.Fatal("no address captured")
	}
	if capturedAddr == string(minter) {
		t.Error("the kind's address is the minter's: an adopted kind could mint")
	}
}

var (
	capturedPath, capturedAddr string
	capturedRan                bool
)

type capturer struct{}

func (capturer) Name() string             { return "capture/realm" }
func (capturer) Describe(p string) string { return "capture the realm handed over" }
func (capturer) Check(p string) error     { return nil }

func (capturer) Do(_ int, rlm realm, p string) error {
	capturedRan = true
	capturedPath = rlm.PkgPath()
	capturedAddr = string(rlm.Address())
	return nil
}

// A decided proposal always gives its slot back, because a grace of zero is
// refused.
//
// A Succeeded proposal keeps its place in the open index until it runs — until
// then a duplicate would be a second live copy of the same question. With no
// grace period nothing ever ended one: Cancel refuses a decided proposal,
// Settle and sweep find nothing to change, and the slot was held for the life
// of the realm. Sixty-four like that and nobody could open a proposal again.
//
// No panicking handler is needed to reach it. Any grace-zero proposal that
// nobody executes does it, and the offerer example offered with a grace of zero
// as the shape to copy.
func TestAGraceOfZeroIsRefusedSoEverySlotComesBack(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	testing.SetRealm(testing.NewUserRealm(gCarl))
	namedAs = "noexpiry/thing"
	uassert.AbortsContains(t, cur, "a decision has to expire", func() {
		Offer(cross(cur), named{}, NewRules(2000, 5100, 100, 0, 0, 0))
	})
	if offered, _ := engineKind("noexpiry/thing"); offered {
		t.Error("a kind whose decisions never expire was registered anyway")
	}

	// A negative one is refused by the same line, and says the same thing.
	testing.SetRealm(testing.NewUserRealm(gCarl))
	namedAs = "negexpiry/thing"
	uassert.AbortsContains(t, cur, "a decision has to expire", func() {
		Offer(cross(cur), named{}, NewRules(2000, 5100, 100, 0, -1, 0))
	})
}

// The mint is governed on the BOOTSTRAP terms, which nothing asserted.
//
// New supply is new voting power, so an unchecked minter can out-vote every
// holder at will — which makes govern:minter the one power whose terms must not
// be cheap. Installed on a 0.01% quorum with a one-block vote and no timelock it
// would still be installed, still adoptable, and still read as governed.
//
// This pins the terms the LIVE engine carries. It does not pin init()'s own line,
// because resetLedger re-installs the same kind with the same rules when it
// rebuilds the engine — one decision written in two places, which is the drift
// this codebase elsewhere fixes by having one function and two callers. Noted in
// PLAN 13 rather than refactored here: the mint is a money path and the change is
// the owner's to take.
func TestTheMintIsGovernedOnTheBootstrapTerms(t *testing.T) {
	name := governor.Reserved + "minter"
	offered, live := engineKind(name)
	if !offered || !live {
		t.Fatalf("%s is offered=%v live=%v — without it the mint can never move, "+
			"and no proposal could restore it", name, offered, live)
	}
	got, ok := KindRules(name)
	if !ok {
		t.Fatalf("%s carries no terms", name)
	}
	want := governor.BootstrapRules()
	if got != want {
		t.Errorf("the mint is governed on quorum=%d threshold=%d voting=%d delay=%d "+
			"grace=%d, where the bootstrap terms are %d/%d/%d/%d/%d",
			got.QuorumBps, got.ThresholdBps, got.VotingBlocks, got.DelayBlocks, got.GraceBlocks,
			want.QuorumBps, want.ThresholdBps, want.VotingBlocks, want.DelayBlocks, want.GraceBlocks)
	}
}
