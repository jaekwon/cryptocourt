package governor

import (
	"strconv"
	"strings"
	"testing"
)

// council is an electorate that is not a token: one address, one vote.
//
// The whole point of the Electorate seam, and the reason it is worth having a
// second implementation in the package's own tests — quorum and threshold at
// their exact boundaries are the arithmetic most worth testing and the hardest
// to reach by minting, because reaching exactly 30% of a real supply means
// solving for it. Against a stated electorate the boundary is just stated.
type council struct {
	members []address
	epoch   uint32
}

func (c *council) PastVotes(who address, at uint32) int64 {
	for _, m := range c.members {
		if m == who {
			return 1
		}
	}
	return 0
}
func (c *council) PastTotal(at uint32) int64    { return int64(len(c.members)) }
func (c *council) EngagedTotal(at uint32) int64 { return c.PastTotal(at) }
func (c *council) Epoch() uint32                { return c.epoch }

// coin is the minimum a page needs to name what is being voted.
type coin struct{ supply int64 }

func (coin) Name() string         { return "Test Coin" }
func (coin) Symbol() string       { return "TEST" }
func (coin) Decimals() int        { return 6 }
func (c coin) TotalSupply() int64 { return c.supply }

// setFee is a kind that records what it was told, so a test can see whether Do
// actually ran and with what.
type setFee struct {
	name string
	ran  *int64
}

func (k setFee) Name() string {
	if k.name == "" {
		return "fee"
	}
	return k.name
}
func (setFee) Describe(payload string) string {
	return "set the fee to " + payload
}
func (setFee) Check(payload string) error {
	n, err := strconv.ParseInt(payload, 10, 64)
	if err != nil || n < 0 {
		return govErr("a fee has to be a non-negative number")
	}
	return nil
}
func (k setFee) Do(_ int, rlm realm, payload string) error {
	n, _ := strconv.ParseInt(payload, 10, 64)
	*k.ran = n
	return nil
}

func armed(t *testing.T, members ...address) (*Governor, *council, *int64) {
	t.Helper()
	c := &council{members: members, epoch: 2}
	ran := int64(-1)
	g := New(c, coin{supply: int64(len(members))})
	g.kinds.Set("fee", &entry{kind: setFee{ran: &ran}, live: true, rules: Rules{
		QuorumBps: 5000, ThresholdBps: 5000, VotingBlocks: 100,
		GraceBlocks: 1000,
	}})
	return g, c, &ran
}

// A governor drives a question from asked to executed against an electorate
// that is not a token at all.
//
// This is the seam working: no balances, no checkpoints, no delegation, and
// every stage of the lifecycle still behaves.
func TestAGovernorRunsOnAnElectorateThatIsNotAToken(t *testing.T) {
	g, _, ran := armed(t, gAlice, gBob, gCarl)

	id := g.Propose(gAlice, "fee", "250", "set it to 250")
	if got := g.State(id); got != "active" {
		t.Fatalf("a fresh proposal is %q", got)
	}

	// Two of three is past a 50% quorum and carries the threshold, so the
	// arithmetic decides it without waiting for the deadline.
	g.Vote(gAlice, id, "yes")
	if got := g.State(id); got != "active" {
		t.Fatalf("one of three votes settled it: %q", got)
	}

	// A second vote from one member is refused while it is still open, which is
	// the roll doing its job. Asked here rather than after it settles, because
	// a closed proposal refuses everybody for a different reason and would
	// answer this question by accident.
	mustPanic(t, "govern: already voted", func() { g.Vote(gAlice, id, "no") })

	g.Vote(gBob, id, "yes")
	if got := g.State(id); got != "succeeded" {
		t.Fatalf("two of three yes votes leaves it %q, want succeeded", got)
	}

	// And it runs, through the dispatcher the consumer supplies. No delay to
	// wait out — the fixture sets DelayBlocks to zero — and the grace period
	// is what would end it if nobody did.
	g.Execute(gCarl, id, dispatch)
	if got := g.State(id); got != "executed" {
		t.Fatalf("after Execute the proposal is %q", got)
	}
	if *ran != 250 {
		t.Errorf("the kind recorded %d, want the 250 the proposal described", *ran)
	}
}

// The engine holds no capability, so Execute cannot run a kind without one
// being handed in.
//
// The Dispatch seam is the whole of why the engine is a /p/ package: minting
// the sub-realm token a kind is given needs a live `cur`, and a pure package
// has none. Passing nil is the shape of forgetting to supply one.
func TestExecuteNeedsADispatcherFromTheConsumer(t *testing.T) {
	// Three members, so two yes votes are needed and the second is what
	// decides it — one would settle a two-member council on its own.
	g, _, _ := armed(t, gAlice, gBob, gCarl)
	id := g.Propose(gAlice, "fee", "7", "seven")
	g.Vote(gAlice, id, "yes")
	g.Vote(gBob, id, "yes")

	mustPanic(t, "govern: a dispatcher is required to run a kind", func() {
		g.Execute(gAlice, id, nil)
	})
	// And the proposal is untouched, so a missing dispatcher is a refusal
	// rather than a failed execution nobody can retry.
	if got := g.State(id); got != "succeeded" {
		t.Errorf("a refused Execute left the proposal %q", got)
	}
}

// Two governors in one program do not see each other.
//
// The reason this is a value rather than package state: a realm running
// several courts needs several governors, and /p/ package state is frozen
// after init in any case.
func TestTwoGovernorsAreIndependent(t *testing.T) {
	a, _, _ := armed(t, gAlice, gBob, gCarl)
	b, _, _ := armed(t, gCarl)

	ida := a.Propose(gAlice, "fee", "1", "in a")
	idb := b.Propose(gCarl, "fee", "1", "in b")

	if ida != idb {
		t.Errorf("the two governors share a sequence: %d and %d", ida, idb)
	}
	a.Vote(gAlice, ida, "yes")
	a.Vote(gBob, ida, "yes")
	if got := a.State(ida); got != "succeeded" {
		t.Fatalf("a's proposal is %q", got)
	}
	if got := b.State(idb); got != "active" {
		t.Errorf("b's proposal is %q after a's was decided — the two share state", got)
	}
}

// The built-in kinds act on the governor that owns them.
//
// Each carries a *Governor, which is a cycle: the kind is a value in that
// governor's own registry. Worth a test because a kind holding the WRONG
// governor would work perfectly in a program with only one.
func TestABuiltInActsOnItsOwnGovernor(t *testing.T) {
	a, _, _ := armed(t, gAlice, gBob)
	b, _, _ := armed(t, gCarl)

	// A kind offered to A only.
	var ran int64
	a.Offer(gAlice, setFee{name: "toll/k", ran: &ran}, Rules{
		QuorumBps: 5000, ThresholdBps: 5000, VotingBlocks: 100, GraceBlocks: 1000,
	})
	if a.entryOf("toll/k") == nil {
		t.Fatal("A did not record the offer")
	}
	if b.entryOf("toll/k") != nil {
		t.Error("a kind offered to A turned up in B; the two share a registry")
	}
	// And each governor's built-ins are its own, which is what the *Governor
	// each carries is for. Adopting in A must not adopt in B.
	if a.entryOf(reserved+"adopt") == b.entryOf(reserved+"adopt") {
		t.Error("both governors installed the same built-in value")
	}
}

// mustPanic is uassert.PanicsWithMessage without the realm argument, which a
// /p/ test cannot supply: taking `cur realm` here would declare a crossing
// function, and a pure package may not have one.
func mustPanic(t *testing.T, want string, fn func()) {
	t.Helper()
	defer func() {
		r := recover()
		if r == nil {
			t.Errorf("expected a panic saying %q; nothing panicked", want)
			return
		}
		got, ok := r.(string)
		if !ok || got != want {
			t.Errorf("panicked with %v, want %q", r, want)
		}
	}()
	fn()
}

// A governor renders the token it was given, not a token it assumed.
//
// The decimal scale is computed from Token.Decimals(), because the engine does
// not know what it is rendering until it is handed one. Hardcoding six works
// perfectly for every token that has six, which is why this uses two.
func TestTheEngineRendersTheTokensOwnScale(t *testing.T) {
	c := &council{members: []address{gAlice}, epoch: 2}
	two := New(c, penny{})
	six := New(c, coin{supply: 1234})

	// 1234 base units is 12.34 at two decimals and 0.001234 at six. Chosen
	// because it has no trailing zeroes: units trims those on purpose, so a
	// rounder number renders the same at both scales and would let a hardcoded
	// six pass.
	if got := two.units(1234); got != "12.34" {
		t.Errorf("a two-decimal token renders 1234 as %q, want 12.34", got)
	}
	if got := six.units(1234); got != "0.001234" {
		t.Errorf("a six-decimal token renders 1234 as %q, want 0.001234", got)
	}
	// And the page carries the same scale, since that is where a holder reads it.
	if page := two.Render("", ""); !contains(page, "12.34 PENNY") {
		t.Errorf("the front page does not render the supply at the token's "+
			"own scale:\n%s", page)
	}
}

// penny is a token with a scale that is not the one anybody would hardcode.
type penny struct{}

func (penny) Name() string       { return "Penny" }
func (penny) Symbol() string     { return "PENNY" }
func (penny) Decimals() int      { return 2 }
func (penny) TotalSupply() int64 { return 1234 }

// A governor needs both of its seams filled.
//
// Neither can be checked later: a nil electorate panics at the first vote, deep
// inside arithmetic, and a nil token panics when somebody reads the page —
// both a long way from the line that forgot to supply one.
func TestAGovernorNeedsAnElectorateAndAToken(t *testing.T) {
	c := &council{members: []address{gAlice}, epoch: 2}
	mustPanic(t, "governor: a governor needs an electorate and a token", func() {
		New(nil, coin{})
	})
	mustPanic(t, "governor: a governor needs an electorate and a token", func() {
		New(c, nil)
	})
}

// SetElectorate refuses nil, because nothing downstream can.
//
// A governor with no electorate does not fail where the mistake was made — it
// fails at the first vote, inside arithmetic, a long way from the line that
// dropped it.
func TestSetElectorateRefusesNothing(t *testing.T) {
	g, led := fresh()
	mustPanic(t, "governor: an electorate is required", func() {
		g.SetElectorate(nil)
	})
	// And the old one is still in place, so a refused swap changes nothing.
	led.Mint(gAlice, 100)
	advanceEpochs(1)
	if got := g.voters.PastTotal(led.Epoch() - 1); got != 100 {
		t.Errorf("the electorate reports %d after a refused swap, want 100", got)
	}
}

// InstallBuiltin is for powers under the reserved prefix, and refuses anything
// else.
//
// It exists because Offer refuses that prefix — which is what stops a stranger
// publishing something that renders as a built-in. A realm reaching this with
// an ordinary name has confused its own power with the governor's, and would
// be installing a kind nobody voted to adopt.
func TestInstallBuiltinIsForReservedNamesOnly(t *testing.T) {
	g, _ := fresh()
	var ran int64
	mustPanic(t, "governor: a built-in has to carry the reserved prefix", func() {
		g.InstallBuiltin(setFee{name: "toll/k", ran: &ran}, Rules{
			QuorumBps: 5000, ThresholdBps: 5000, VotingBlocks: 100, GraceBlocks: 1000,
		})
	})
	if g.entryOf("toll/k") != nil {
		t.Error("the refused built-in was installed anyway")
	}
	// And a reserved one goes in, adopted, without a vote — which is the whole
	// point and why this is the realm's to call and nobody else's.
	g.InstallBuiltin(setFee{name: reserved + "toll", ran: &ran}, Rules{
		QuorumBps: 5000, ThresholdBps: 5000, VotingBlocks: 100, GraceBlocks: 1000,
	})
	e := g.entryOf(reserved + "toll")
	if e == nil || !e.live {
		t.Error("a reserved built-in was not installed live")
	}
}

// The introspection surface answers what the pages already print.
//
// A consumer that has to scrape markdown for a number the engine holds is an
// engine with an incomplete API — and a realm's tests are the first consumer to
// find out. Each of these is a read the front page or a proposal page already
// publishes in words.
// TestVoteOfMatchesTallyLeg pins the load-bearing invariant the cryptocourt court's
// fee split depends on: each voter's VoteOf weight equals their contribution to Tally,
// and Σ(ballot weights) == yes+no+abstain exactly. If these diverged, the court's
// ClaimAdjFee bound Σ floor(pool·w/W) ≤ pool would break and over-pay. A big
// non-voting holder keeps the proposal from early-deciding so all three ballots land.
func TestVoteOfMatchesTallyLeg(t *testing.T) {
	g, led := fresh()
	led.Mint(gDave, 100000) // dominant, never votes → the vote stays open for all three
	led.Mint(gAlice, 600)
	led.Mint(gBob, 377)
	led.Mint(gCarl, 111)
	advanceEpochs(1)

	var ran int64
	g.Adopt(setFee{ran: &ran}, Rules{
		QuorumBps: 5000, ThresholdBps: 5000, VotingBlocks: 100, GraceBlocks: 1000,
	})
	id := g.Propose(gAlice, "fee", "250", "set it")
	g.Vote(gAlice, id, "yes")
	g.Vote(gBob, id, "no")
	g.Vote(gCarl, id, "abstain")

	yes, no, abstain, _ := g.Tally(id)

	assertBallot := func(who address, wantChoice string, wantLeg int64) {
		t.Helper()
		ch, w, ok := g.VoteOf(id, who)
		if !ok {
			t.Fatalf("VoteOf(%s): expected a %s ballot, got ok=false", wantChoice, wantChoice)
		}
		if ch != wantChoice {
			t.Fatalf("VoteOf choice %q != %q", ch, wantChoice)
		}
		if w != wantLeg {
			t.Fatalf("VoteOf %s weight %d != its tally leg %d", wantChoice, w, wantLeg)
		}
	}
	assertBallot(gAlice, "yes", yes)
	assertBallot(gBob, "no", no)
	assertBallot(gCarl, "abstain", abstain)

	if yes+no+abstain != 600+377+111 {
		t.Fatalf("Σ tally %d != cast total 1088 — the VoteOf/Tally identity is broken", yes+no+abstain)
	}
	// A non-voter reads back ok=false — no phantom weight, no roll-sentinel leak.
	if _, _, ok := g.VoteOf(id, gNemo); ok {
		t.Fatal("a non-voter must read VoteOf ok=false")
	}
}

func TestTheEngineAnswersWhatItsPagesPrint(t *testing.T) {
	g, led := fresh()
	led.Mint(gAlice, 600)
	led.Mint(gBob, 400)
	advanceEpochs(1)

	var ran int64
	g.Adopt(setFee{ran: &ran}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 100, GraceBlocks: 1000,
	})
	if offered, live := g.KindStatus("fee"); !offered || !live {
		t.Fatalf("after Adopt the kind reads offered=%v live=%v", offered, live)
	}
	if _, ok := g.KindRules("fee"); !ok {
		t.Error("an adopted kind reports no rules")
	}
	if _, ok := g.KindRules("nothing/here"); ok {
		t.Error("a name nobody published reports rules")
	}
	// Offered and adopted are different states, and the distinction is the
	// whole of what Offer grants: publishing code and letting that code hold
	// the governor's authority are separate decisions. A KindStatus that
	// collapsed them would report every published kind as runnable.
	g.Offer(gBob, setFee{name: "toll/k", ran: &ran}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 100, GraceBlocks: 1000,
	})
	if offered, live := g.KindStatus("toll/k"); !offered || live {
		t.Errorf("an offered, unadopted kind reads offered=%v live=%v", offered, live)
	}
	if offered, live := g.KindStatus("nothing/here"); offered || live {
		t.Errorf("a name nobody published reads offered=%v live=%v", offered, live)
	}

	if got := g.OpenSlots(); got != 0 {
		t.Fatalf("a fresh governor holds %d slots", got)
	}
	id := g.Propose(gAlice, "fee", "250", "lower it")
	if got := g.OpenSlots(); got != 1 {
		t.Errorf("one proposal takes %d slots", got)
	}
	if got := g.Proposals(); got != 1 {
		t.Errorf("one question asked reads as %d", got)
	}
	if got := g.EpochOf(id); got != led.Epoch()-1 {
		t.Errorf("the proposal was weighed at epoch %d, want the last sealed one %d",
			got, led.Epoch()-1)
	}

	// The roll is bought at Propose and holds nobody until somebody votes. The
	// sentinel is not a voter and must not be counted as one.
	if !g.HasRoll(id) {
		t.Fatal("a fresh proposal has no roll, so nobody could be refused a second vote")
	}
	if got := g.RollSize(id); got != 0 {
		t.Errorf("a roll nobody has voted on holds %d — the sentinel is being counted", got)
	}
	g.Vote(gAlice, id, "yes")
	if got := g.RollSize(id); got != 1 {
		t.Errorf("after one vote the roll holds %d", got)
	}

	// Why it ended, which the page prints and nothing else exposed.
	if got := g.Reason(id); got != "" {
		t.Errorf("a proposal that succeeded outright gives the reason %q", got)
	}

	// And the digest, which is the key a question occupies — the thing a
	// proposer chooses by choosing their payload.
	if a, b := g.Digest("fee", "250"), g.Digest("fee", "251"); a == b {
		t.Error("two different payloads share a key")
	}
	if a, b := g.Digest("fee", "250"), g.Digest("fee/x", "250"); a == b {
		t.Error("the kind and the payload are not separated in the key")
	}

	// Released, the roll is gone and says so distinctly from holding nobody.
	advanceBlocks(2000)
	g.Settle(gCarl, id)
	g.ReleaseRoll(gCarl, id)
	if g.HasRoll(id) {
		t.Error("the roll was released and still reads as held")
	}
	if got := g.RollSize(id); got != 0 {
		t.Errorf("a released roll holds %d", got)
	}
}

// Adopt holds its terms to the same sanity Offer does.
//
// It is the un-voted path, so nothing downstream will catch a bad value: a
// grace of zero leaks a slot for the life of the realm, and a proposer bar
// above the whole supply makes a kind nobody can ever propose under. Refusing
// at the door is the only place left.
func TestAdoptChecksItsTermsLikeOfferDoes(t *testing.T) {
	g, _ := fresh()
	var ran int64
	sane := Rules{QuorumBps: 5000, ThresholdBps: 5000, VotingBlocks: 100, GraceBlocks: 1000}

	// A grace of zero: the case where nothing ever ends a decided proposal.
	bad := sane
	bad.GraceBlocks = 0
	mustPanicContains(t, "grace period of zero", func() {
		g.Adopt(setFee{name: "a/k", ran: &ran}, bad)
	})
	if offered, _ := g.KindStatus("a/k"); offered {
		t.Error("the refused kind was installed anyway")
	}

	// And a proposer bar nobody can clear.
	bad = sane
	bad.ProposeBps = 10001
	mustPanicContains(t, "more than the whole supply", func() {
		g.Adopt(setFee{name: "b/k", ran: &ran}, bad)
	})

	// And the NAME, which is checked the same way and for a longer list of
	// reasons: it goes in the registry, in a proposal, on a page, and into the
	// sub-path a kind is handed, so anything unprintable or oversized breaks
	// one of those far from here.
	mustPanicContains(t, "printable ASCII", func() {
		g.Adopt(setFee{name: "bad\nname", ran: &ran}, sane)
	})
	mustPanicContains(t, "printable ASCII", func() {
		g.Adopt(setFee{name: " ", ran: &ran}, sane)
	})

	// The sane one goes in.
	g.Adopt(setFee{name: "c/k", ran: &ran}, sane)
	if _, live := g.KindStatus("c/k"); !live {
		t.Error("a sane kind was not adopted")
	}
}

// The two INPUT BOUNDS nothing pinned. Mutating maxPayload (4096 -> 40960) and maxBatch
// (16 -> 160) both survived the whole suite, while maxTitle, maxKindName, maxLive and
// maxOpen were all caught — so these two were the gaps rather than a general one. The
// batch GUARD is covered (TestABatchIsBounded catches its removal); it was only the VALUE
// that nothing held.
//
// The inputs below are LITERALS, and the first version of this test got that wrong: it
// built them as maxPayload+1 and maxBatch+1, so doubling the constant doubled the test's
// input and both mutations still survived a test written to catch them. That is the same
// derived-expectation defect recorded against the court's constants — a fixture that reads
// the number it is checking can only prove the code agrees with itself. Value pins and
// literal boundaries together: the pin fails if the number moves, the boundary fails if
// either the number or the `len(...) >` guard moves.
func TestPayloadAndBatchBoundsHoldAtTheirLimit(t *testing.T) {
	if maxPayload != 4096 {
		t.Errorf("maxPayload is %d, the design says 4096 — edit this pin if deliberate",
			maxPayload)
	}
	if maxBatch != 16 {
		t.Errorf("maxBatch is %d, the design says 16 — edit this pin if deliberate",
			maxBatch)
	}

	g, _, _ := armed(t, gAlice, gBob, gCarl)

	// One byte over the documented limit is refused FOR BEING TOO LONG.
	mustPanic(t, "govern: that payload is too long", func() {
		g.Propose(gAlice, "fee", strings.Repeat("9", 4097), "over")
	})

	// Exactly at it, the length guard must be silent. The fee kind refuses a
	// 4096-digit payload for its own reasons, so the assertion is that the complaint is
	// NOT about length — which is what an off-by-one in the bound would change.
	func() {
		defer func() {
			r := recover()
			if r == nil {
				return // accepted outright is fine too
			}
			if got, ok := r.(string); ok && got == "govern: that payload is too long" {
				t.Errorf("a payload of exactly 4096 bytes must not be refused for length")
			}
		}()
		g.Propose(gAlice, "fee", strings.Repeat("9", 4096), "at the limit")
	}()

	// maxBatch is enforced in parseBatch, which reports rather than panics.
	batch := func(n int) string {
		lines := make([]string, n)
		for i := range lines {
			lines[i] = "fee " + strconv.Itoa(i+1)
		}
		return strings.Join(lines, "\n")
	}
	if _, err := parseBatch(batch(16)); err != nil {
		t.Errorf("a batch of exactly 16 members must parse: %v", err)
	}
	if _, err := parseBatch(batch(17)); err == nil {
		t.Errorf("a batch of 17 members must be refused")
	}
}

// countingDispatch is a dispatcher that records how many times it was asked to
// run a kind, so a double execution is a number rather than an inference.
type countingDispatch struct{ n int }

func (c *countingDispatch) run(k Kind, sub, pay string) error {
	c.n++
	return dispatch(k, sub, pay)
}

// reenterer is a dispatcher that calls back into the governor that is running
// it, keeping whatever it was refused with.
//
// A struct with methods rather than closures: a func literal declared INSIDE
// another func literal, capturing the outer one's locals, crashes the GnoVM
// outright (nil dereference in doOpFuncLit -> GetPointerToIntDirect). Legal Go,
// so worth writing down — a test here has to keep its closures one level deep,
// which a method's deferred recover is.
type reenterer struct {
	g      *Governor
	id     int64
	other  int64
	inner   *countingDispatch
	reVote  any
	reExec  any
	rePropo any
}

func (r *reenterer) tryVote() {
	defer func() { r.reVote = recover() }()
	r.g.Vote(gCarl, r.other, "yes")
}

func (r *reenterer) tryExecute() {
	defer func() { r.reExec = recover() }()
	r.g.Execute(gCarl, r.id, r.inner.run)
}

func (r *reenterer) tryPropose() {
	defer func() { r.rePropo = recover() }()
	r.g.Propose(gCarl, "fee", "13", "asked from inside an execution")
}

func (r *reenterer) run(k Kind, sub, pay string) error {
	r.tryVote()
	r.tryExecute()
	r.tryPropose()
	return dispatch(k, sub, pay)
}

// Nothing may re-enter the governor while a kind is running, and until now
// nothing tested it — three guards, all of them dead in every fixture.
//
// The Dispatch seam is what makes this reachable rather than theoretical. A kind
// is CODE THE HOLDERS ADOPTED, run with a live realm, and the dispatcher that
// invokes it belongs to the consuming realm; so the one thing an executing kind
// certainly can do is call back into the governor that is running it. Two of
// those calls have to be refused:
//
//	Execute, because the proposal is still SUCCEEDED at that moment — the state
//	only becomes executed after the run returns. A re-entrant Execute therefore
//	passes the state check and runs the kind A SECOND TIME, which for a kind that
//	pays or mints is the whole exploit.
//
//	Vote, because a tally that moves while a decision derived from it is being
//	carried out is a tally that can contradict the thing it authorised.
//
//	Propose, because a kind that can open questions while running is a kind that
//	can fill the book — bounded at maxLive — from inside a transaction nobody
//	else can interleave with.
//
// Both are refused by one latch, so the sharpest mutation is not either guard
// but `g.executing = true` itself: delete that line and both go quiet at once.
// That is what this test is really holding.
//
// The vote aims at a SECOND, still-open proposal on purpose. Voting on the
// proposal being executed would be refused for being closed, which would answer
// this question by accident and pass with the latch removed.
func TestExecutionCannotReEnterTheGovernor(t *testing.T) {
	g, _, ran := armed(t, gAlice, gBob, gCarl)
	id := g.Propose(gAlice, "fee", "11", "eleven")
	g.Vote(gAlice, id, "yes")
	g.Vote(gBob, id, "yes")
	if got := g.State(id); got != "succeeded" {
		t.Fatalf("setup: the proposal is %q, want succeeded", got)
	}
	other := g.Propose(gAlice, "fee", "12", "twelve")

	inner := &countingDispatch{}
	r := &reenterer{g: g, id: id, other: other, inner: inner}
	g.Execute(gCarl, id, r.run)

	if r.reVote == nil {
		t.Error("a kind voted from inside its own execution; that must be refused")
	} else if got, _ := r.reVote.(string); !contains(got, "cannot vote from inside an execution") {
		t.Errorf("the re-entrant vote was refused with %q", got)
	}
	if r.reExec == nil {
		t.Error("a kind executed a proposal from inside an execution; that must be refused")
	} else if got, _ := r.reExec.(string); !contains(got, "re-entrant execution") {
		t.Errorf("the re-entrant execution was refused with %q", got)
	}
	if r.rePropo == nil {
		t.Error("a kind opened a proposal from inside an execution; that must be refused")
	} else if got, _ := r.rePropo.(string); !contains(got, "cannot propose from inside an execution") {
		t.Errorf("the re-entrant proposal was refused with %q", got)
	}
	if inner.n != 0 {
		t.Errorf("the kind ran %d extra time(s) from inside its own execution — a "+
			"proposal that pays or mints would have done it twice", inner.n)
	}

	// And the refusals do not break the legitimate execution they interrupted:
	// both guards fire before their function touches any state, so a recovered
	// re-entry leaves nothing half-written.
	if got := g.State(id); got != "executed" {
		t.Errorf("the proposal is %q after its kind ran, want executed", got)
	}
	if *ran != 11 {
		t.Errorf("the kind recorded %d, want the 11 the proposal described", *ran)
	}
	if yes, _, _, _ := g.Tally(other); yes != 0 {
		t.Errorf("the still-open proposal recorded %d yes weight from inside an "+
			"execution", yes)
	}
}

// councilWithBar is a four-member council whose kind carries a proposer bar, so
// one member holds exactly a quarter of the electorate and the bar can be stated
// at, above and below that quarter.
func councilWithBar(bar int64) *Governor {
	c := &council{members: []address{gAlice, gBob, gCarl, gDave}, epoch: 2}
	g := New(c, coin{supply: 4})
	ran := int64(-1)
	g.kinds.Set("fee", &entry{kind: setFee{ran: &ran}, live: true, rules: Rules{
		QuorumBps: 5000, ThresholdBps: 5000, VotingBlocks: 100,
		GraceBlocks: 1000, ProposeBps: bar,
	}})
	return g
}

// The proposer bar refuses only what falls SHORT of it, found surviving: the
// comparison is `held*bps < total*ProposeBps`, so a holder standing exactly at
// the bar may ask. Nothing tested that, and the two quorum bars either side of
// it in the same function both have boundary tests — this one was simply missed.
//
// It matters in the direction the mutation goes. Making it exclusive turns a
// stated bar of "a quarter of the supply" into "more than a quarter", which is
// unmeetable by exactly the holder the number was chosen to admit; and a court
// computing a bar as a fraction of its own supply lands on the boundary as a
// matter of course rather than by coincidence.
func TestTheProposerBarIsMetAtItsExactValue(t *testing.T) {
	// One of four members is 2500 bps of the electorate.
	at := councilWithBar(2500)
	id := at.Propose(gAlice, "fee", "1", "exactly a quarter")
	if got := at.State(id); got != "active" {
		t.Errorf("a holder standing exactly at the bar was refused: state %q", got)
	}
	// One basis point above what they hold, and they are short.
	over := councilWithBar(2501)
	mustPanicContains(t, "not enough voting power to open this", func() {
		over.Propose(gAlice, "fee", "1", "a hair short")
	})
	// And the roll's first node is bought here, by the proposer, before any vote
	// has been cast — the sentinel is present and is the only thing present.
	// Left to the first voter it would cost them about eleven times an ordinary
	// insert, which is a tax on being early.
	p := at.mustProposal(id)
	if p.voted == nil {
		t.Fatal("a fresh proposal has no voter roll at all")
	}
	if got := p.voted.Size(); got != 1 {
		t.Errorf("the fresh roll holds %d keys, want just the proposer-bought "+
			"sentinel", got)
	}
}

// A withdrawn proposal is recorded as WITHDRAWN, found surviving: swapping
// stateCanceled for stateDefeated changed nothing any test could see. Both are
// terminal and both free the slot, so the tally, the book and the refunds are all
// correct either way — the only thing that differs is what the record says
// happened, and a proposer taking their own question back is not the electorate
// rejecting it. Anything reading the outcome to decide whether the question was
// answered would be told that it was.
func TestACancellationIsRecordedAsOne(t *testing.T) {
	g, _, _ := armed(t, gAlice, gBob, gCarl)
	id := g.Propose(gAlice, "fee", "1", "asked and withdrawn")
	g.Cancel(gAlice, id)
	if got := g.State(id); got != "canceled" {
		t.Errorf("a withdrawn proposal reads %q, want canceled", got)
	}
}

// maxReason's boundary, found surviving: the clip test in the realm suite drives
// a 1,200-byte failure message, which is cut whichever side of the bound the
// comparison falls on, so an off-by-one there was invisible.
//
// The lengths are LITERALS on purpose. Written as maxReason and maxReason+1 the
// inputs would move with the constant, both sides of the comparison would shift
// together, and the test would pass with the bound doubled — the derived-
// expectation defect this repo has now committed once and documented twice.
func TestTheReasonBoundIsWhereItSays(t *testing.T) {
	if maxReason != 256 {
		t.Fatalf("maxReason is %d; this test states 256/257 outright so that it "+
			"fails when the bound moves rather than moving with it", maxReason)
	}
	at := strings.Repeat("a", 256)
	if got := clip(at); got != at {
		t.Errorf("a reason exactly at the bound was cut to %d bytes", len(got))
	}
	over := strings.Repeat("a", 257)
	got := clip(over)
	if got == over {
		t.Errorf("a reason of %d bytes was kept whole; the bound is 256", len(over))
	}
	if n := len(got); n > 256+len("…") {
		t.Errorf("a clipped reason is %d bytes, past the bound plus its ellipsis", n)
	}
}

// refuses and accepts state what saneRules must do with one set of terms.
func refuses(t *testing.T, what string, r Rules) {
	t.Helper()
	if err := saneRules(r); err == nil {
		t.Errorf("saneRules accepted %s", what)
	}
}

func accepts(t *testing.T, what string, r Rules) {
	t.Helper()
	if err := saneRules(r); err != nil {
		t.Errorf("saneRules refused %s: %v", what, err)
	}
}

// Every leg of saneRules, five of which nothing held.
//
// This is the one definition of terms the realm will accept, and its own comment
// records that it exists because two copies drifted apart and BOTH missed
// ProposeBps. The legs that were tested were the two with a story attached — a
// grace of zero, and a proposer bar above the whole supply. The NEGATIVE legs had
// nothing, and they are the ones that do damage rather than merely bricking a
// kind:
//
//	a negative quorum makes quorum TRIVIAL, not strict. The bar is
//	`cast*bps >= engaged*QuorumBps`, so a negative right-hand side is satisfied by
//	any turnout including none.
//
//	a negative threshold passes anything, since `yes*bps >= forAndAgainst*neg`
//	holds for every tally.
//
// Together they are a kind that any single holder can carry at will, adopted by a
// vote whose page rendered the terms as percentages nobody reads twice. The two
// upper bounds are the milder direction — a kind adopted and then unusable — and
// were equally unheld.
func TestEveryTermIsCheckedForSanity(t *testing.T) {
	if bps != 10000 {
		t.Fatalf("bps is %d; the bounds below are stated as 10000/10001 outright so "+
			"they fail when the scale moves rather than moving with it", bps)
	}
	sane := Rules{
		QuorumBps: 5000, ThresholdBps: 5000,
		VotingBlocks: 100, DelayBlocks: 10, GraceBlocks: 1000,
	}
	accepts(t, "ordinary terms", sane)

	b := sane
	b.QuorumBps = -1
	refuses(t, "a negative quorum, which makes quorum trivial rather than strict", b)
	b = sane
	b.QuorumBps = 10001
	refuses(t, "a quorum above the whole supply", b)
	b = sane
	b.ThresholdBps = -1
	refuses(t, "a negative threshold, which passes every tally", b)
	b = sane
	b.ThresholdBps = 10001
	refuses(t, "a threshold above every vote cast", b)
	b = sane
	b.ProposeBps = -1
	refuses(t, "a negative proposer bar", b)
	b = sane
	b.ProposeBps = 10001
	refuses(t, "a proposer bar above the whole supply", b)
	b = sane
	b.VotingBlocks = 0
	refuses(t, "a vote with no period", b)
	b = sane
	b.VotingBlocks = -1
	refuses(t, "a negative voting period", b)
	b = sane
	b.GraceBlocks = 0
	refuses(t, "a grace of zero, which holds its slot for the life of the realm", b)
	b = sane
	b.DelayBlocks = -1
	refuses(t, "a negative delay", b)

	// And the values exactly AT each bound, every one of which is a coherent
	// thing to want — so the guards must not over-refuse in closing the above.
	b = sane
	b.QuorumBps = 0
	accepts(t, "a quorum of zero: any turnout at all decides", b)
	b = sane
	b.QuorumBps = 10000
	accepts(t, "a quorum of everything: the whole supply must turn out", b)
	b = sane
	b.ThresholdBps = 0
	accepts(t, "a threshold of zero", b)
	b = sane
	b.ThresholdBps = 10000
	accepts(t, "a threshold of unanimity", b)
	b = sane
	b.ProposeBps = 10000
	accepts(t, "only the holder of the entire supply may propose", b)
	b = sane
	b.DelayBlocks = 0
	accepts(t, "no timelock, which is a choice and not a mistake", b)
	b = sane
	b.VotingBlocks, b.GraceBlocks = 1, 1
	accepts(t, "one block to vote and one to run", b)
}

// A kind's name has to work in all three places a name is used, and three of the
// four legs that enforce that were unheld — only the SPACE was tested.
//
// The last assertion is a different claim from the rest: that Offer APPLIES the
// check. Offer and Adopt each call mustBeUsableName themselves, and every test
// that reached it went through Adopt — so deleting Offer's call left the function
// working perfectly and nothing noticed. Two entry points to one validator need
// two tests, or one of them is unguarded.
func TestAKindNameMustBeUsableEverywhere(t *testing.T) {
	if maxKindName != 64 {
		t.Fatalf("maxKindName is %d; the lengths below are stated as 64/65 outright", maxKindName)
	}
	mustPanicContains(t, "a kind needs a name", func() { mustBeUsableName("") })
	mustPanicContains(t, "too long", func() { mustBeUsableName(strings.Repeat("k", 65)) })
	// Every byte of a multi-byte character is >= 0x80, which the upper bound
	// refuses — a name is a registry key, a batch field and a sub-path, not prose.
	mustPanicContains(t, "printable ASCII", func() { mustBeUsableName("kïnd") })
	// The two edges that must pass: the longest allowed name, and the printable
	// extremes either side of the range.
	mustNotPanic(t, func() { mustBeUsableName(strings.Repeat("k", 64)) })
	mustNotPanic(t, func() { mustBeUsableName("!~") })

	// Offer's own call, which nothing exercised.
	g, _ := fresh()
	mustPanicContains(t, "printable ASCII", func() {
		g.Offer(gAlice, setFee{name: "bad name", ran: new(int64)}, BootstrapRules())
	})
	if offered, _ := g.KindStatus("bad name"); offered {
		t.Error("a kind with an unusable name was shelved anyway")
	}
}

// adopt and retire each state three preconditions, and only the built-in one was
// held. They are what stop a proposal being opened that cannot do what it says:
// the check runs at Propose AND again at Execute, so an unmet precondition is a
// refusal at the door rather than a proposal that passes a vote and then fails.
func TestAdoptAndRetireCheckTheirPreconditions(t *testing.T) {
	g, _ := fresh()

	// Nothing offered under the name at all.
	if err := (adoptKind{}).check(g, "nothing/here"); err == nil {
		t.Error("adopting a name nothing was offered under was accepted")
	}
	if err := (retireKind{}).check(g, "nothing/here"); err == nil {
		t.Error("retiring a name nothing was offered under was accepted")
	}

	// Offered but not live: adoptable, and not retirable.
	g.Offer(gAlice, setFee{name: "shelved/k", ran: new(int64)}, BootstrapRules())
	if err := (adoptKind{}).check(g, "shelved/k"); err != nil {
		t.Errorf("a shelved kind cannot be adopted: %v", err)
	}
	if err := (retireKind{}).check(g, "shelved/k"); err == nil {
		t.Error("retiring a kind that was never live was accepted")
	}

	// Live: retirable, and not adoptable a second time.
	g.Adopt(setFee{name: "live/k", ran: new(int64)}, BootstrapRules())
	if err := (retireKind{}).check(g, "live/k"); err != nil {
		t.Errorf("a live kind cannot be retired: %v", err)
	}
	if err := (adoptKind{}).check(g, "live/k"); err == nil {
		t.Error("adopting an already-live kind was accepted")
	}

	// The built-ins, however live, are not withdrawable — and the BARE PREFIX
	// counts as reserved. A kind named exactly "govern:" would otherwise sit on a
	// page beside the governor's own kinds looking like one of them, and would
	// take the reserved lanes Propose keeps for them.
	if err := (retireKind{}).check(g, reserved+"adopt"); err == nil {
		t.Error("govern:adopt can be retired — after which nothing could ever be " +
			"adopted again and no proposal could restore it")
	}
	if !isReserved(reserved) {
		t.Error(`the bare prefix "govern:" is not treated as reserved`)
	}
}
