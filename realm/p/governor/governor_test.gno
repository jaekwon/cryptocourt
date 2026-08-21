package governor

import (
	"chain/runtime"
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

// Height satisfies Electorate; see the note in changes_test.gno.
func (c *council) Height() int64 { return runtime.ChainHeight() }

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
// TestVoteOfMatchesTallyLeg pins the load-bearing invariant the kourt court's
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
	g       *Governor
	id      int64
	other   int64
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

// recordingDispatch keeps the sub-path each member was dispatched under, which
// is the only way to observe the one thing a batch promises about authority.
type recordingDispatch struct {
	paths []string
}

func (d *recordingDispatch) run(k Kind, sub, pay string) error {
	d.paths = append(d.paths, sub)
	return dispatch(k, sub, pay)
}

// Each batch member is handed ITS OWN sub-realm, not the batch's, found
// surviving — and it is the sharpest thing in batch.gno.
//
// A batch is a way to decide several things at once. It is not a way to launder
// one kind's authority into another's, and the sub-path is the whole of that
// distinction: a governed realm gates on the sub-path of the power it granted,
// so a member dispatched under `govern-batch` is seen as the batch rather than as
// the power it is. Adopt a batch once and every member reaches everything any
// member could — which is precisely the escalation the per-member sub-path
// prevents.
//
// Nothing could see it because the sub-path is only visible to the DISPATCHER,
// which the consuming realm supplies. A test that supplies a recording one is the
// only observer there can be.
func TestABatchGivesEachMemberItsOwnSubRealm(t *testing.T) {
	g, _, _ := armed(t, gAlice, gBob, gCarl)
	// Retune the built-in for the test the way armed does: BootstrapRules carries
	// a two-day timelock, and this test is about the dispatch rather than the wait.
	g.kinds.Set(reserved+"batch", &entry{kind: batchKind{}, live: true, rules: Rules{
		QuorumBps: 5000, ThresholdBps: 5000, VotingBlocks: 100, GraceBlocks: 1000,
	}})
	one, two := int64(-1), int64(-1)
	g.Adopt(setFee{name: "treasury/spend", ran: &one}, BootstrapRules())
	g.Adopt(setFee{name: "toll", ran: &two}, BootstrapRules())

	id := g.Propose(gAlice, reserved+"batch", "treasury/spend 100\ntoll 250", "two at once")
	g.Vote(gAlice, id, "yes")
	g.Vote(gBob, id, "yes")
	if got := g.State(id); got != "succeeded" {
		t.Fatalf("setup: the batch is %q, want succeeded", got)
	}

	rec := &recordingDispatch{}
	g.Execute(gCarl, id, rec.run)
	if got := g.State(id); got != "executed" {
		t.Fatalf("the batch is %q after running, want executed", got)
	}
	if len(rec.paths) != 2 {
		t.Fatalf("the batch dispatched %d members, want 2", len(rec.paths))
	}
	// Neither member may arrive under the batch's own path — that is the mutation
	// this test exists for, stated before the positive form so the failure names it.
	batchPath := subPathOf(reserved + "batch")
	for i, got := range rec.paths {
		if got == batchPath {
			t.Errorf("member %d was dispatched under the BATCH's sub-realm %q — one "+
				"adoption would grant every member the reach of all of them", i+1, got)
		}
	}
	if got, want := rec.paths[0], subPathOf("treasury/spend"); got != want {
		t.Errorf("the first member ran under %q, want %q", got, want)
	}
	if got, want := rec.paths[1], subPathOf("toll"); got != want {
		t.Errorf("the second member ran under %q, want %q", got, want)
	}
	// And both actually ran, so the paths above are not from a batch that did
	// nothing.
	if one != 100 || two != 250 {
		t.Errorf("the members recorded %d and %d, want 100 and 250", one, two)
	}
}

// A batch's PAGE has to survive members that are missing or not adopted, found
// surviving in three places at once.
//
// Reachable through Preview, which is a read taking caller-supplied strings — a
// UI showing somebody their proposal before they pay for it — so the describe
// path sees names that Check would refuse and must not panic on them. The
// `anyKind` there is load-bearing for a second reason: `kindOf` demands a LIVE
// kind, and a batch proposal that has already been voted on hits exactly that
// state the moment one of its members is retired, so a page rendered with kindOf
// would panic on a proposal that already exists.
func TestABatchsPageSurvivesAMemberThatIsGoneOrNotAdopted(t *testing.T) {
	g, _ := fresh()

	// A member nothing was ever offered under: the page says so.
	out := g.Preview(reserved+"batch", "nosuch/kind 1\nother/kind 2")
	if !contains(out, "no kind by that name") {
		t.Errorf("a batch naming an unknown member rendered as:\n%s", out)
	}

	// A member OFFERED but not adopted: described from its own kind, because
	// judging an adoption vote is exactly when a reader needs to see it.
	g.Offer(gAlice, setFee{name: "shelved/k", ran: new(int64)}, BootstrapRules())
	g.Adopt(setFee{name: "live/k", ran: new(int64)}, BootstrapRules())
	out = g.Preview(reserved+"batch", "shelved/k 1\nlive/k 2")
	if !contains(out, "set the fee to 1") {
		t.Errorf("a shelved member was not described on the page:\n%s", out)
	}

	// And a malformed batch explains itself rather than rendering blank.
	out = g.Preview(reserved+"batch", "onlyonemember 1")
	if !contains(out, "malformed batch") {
		t.Errorf("a malformed batch rendered as:\n%s", out)
	}
}

// A member line splits at its FIRST space and the payload is trimmed, so a batch
// somebody lined up by eye still parses. The trim was unheld, and it is also what
// makes the `sp <= 0` guard above it equivalent to `sp < 0`: with the line already
// trimmed, a first space at index zero cannot happen.
func TestABatchLineSplitsAtItsFirstSpace(t *testing.T) {
	ms, err := parseBatch("fee   250\n  toll 1  ")
	if err != nil {
		t.Fatalf("a batch with ordinary spacing was refused: %v", err)
	}
	if len(ms) != 2 {
		t.Fatalf("parsed %d members, want 2", len(ms))
	}
	if ms[0].kind != "fee" || ms[0].payload != "250" {
		t.Errorf("first member is %q/%q, want fee/250", ms[0].kind, ms[0].payload)
	}
	if ms[1].kind != "toll" || ms[1].payload != "1" {
		t.Errorf("second member is %q/%q, want toll/1", ms[1].kind, ms[1].payload)
	}
}

// Every one of the six rules fields lands on the term it names. Four were held
// only incidentally and two — threshold and delay — not at all.
//
// The routing is the whole of what applyRules does, and a swap is invisible to
// nearly everything downstream: the change set parses, applyRules cannot fail,
// saneRules passes because the values are all in range, the proposal executes, and
// the kind is left passing on a bar nobody agreed to. The two that were unheld are
// the two that do the most damage that way — `delay=X` landing on GraceBlocks
// moves the EXPIRY instead of the timelock, so a decision runs immediately and
// stops being executable early; `threshold=X` landing on QuorumBps swaps a bar on
// votes CAST for a bar on the whole electorate, which are different questions with
// the same units.
//
// Six DISTINCT values, so no swap can hide behind two fields sharing a number, and
// the payload is parsed rather than hand-built so the key names are pinned too.
func TestEveryRulesFieldLandsOnItsOwnTerm(t *testing.T) {
	name, set, err := parseRules("fee quorum=11 threshold=22 voting=33 delay=44 grace=55 propose=66")
	if err != nil {
		t.Fatalf("a well-formed six-field change was refused: %v", err)
	}
	if name != "fee" {
		t.Errorf("the kind parsed as %q, want fee", name)
	}
	if len(set) != 6 {
		t.Fatalf("parsed %d fields, want 6", len(set))
	}

	got := Rules{}
	applyRules(&got, set)
	if got.QuorumBps != 11 {
		t.Errorf("quorum landed as %d, want 11", got.QuorumBps)
	}
	if got.ThresholdBps != 22 {
		t.Errorf("threshold landed as %d, want 22", got.ThresholdBps)
	}
	if got.VotingBlocks != 33 {
		t.Errorf("voting landed as %d, want 33", got.VotingBlocks)
	}
	if got.DelayBlocks != 44 {
		t.Errorf("delay landed as %d, want 44", got.DelayBlocks)
	}
	if got.GraceBlocks != 55 {
		t.Errorf("grace landed as %d, want 55", got.GraceBlocks)
	}
	if got.ProposeBps != 66 {
		t.Errorf("propose landed as %d, want 66", got.ProposeBps)
	}

	// And a field left OUT keeps what it had — which is what makes lengthening one
	// delay a short line, and is also the second way a misrouted field shows up:
	// it moves a term the proposal never mentioned.
	after := Rules{QuorumBps: 1, ThresholdBps: 2, VotingBlocks: 3,
		DelayBlocks: 4, GraceBlocks: 5, ProposeBps: 6}
	_, one, err := parseRules("fee delay=99")
	if err != nil {
		t.Fatalf("a one-field change was refused: %v", err)
	}
	applyRules(&after, one)
	if after.DelayBlocks != 99 {
		t.Errorf("the delay landed as %d, want 99", after.DelayBlocks)
	}
	if after.QuorumBps != 1 || after.ThresholdBps != 2 || after.VotingBlocks != 3 ||
		after.GraceBlocks != 5 || after.ProposeBps != 6 {
		t.Errorf("a one-field change moved something else: quorum=%d threshold=%d "+
			"voting=%d grace=%d propose=%d; want 1/2/3/5/6",
			after.QuorumBps, after.ThresholdBps, after.VotingBlocks,
			after.GraceBlocks, after.ProposeBps)
	}
}

// deepToken reports more decimals than 10^d can hold in an int64. Pathological —
// grc20votes clamps its own to 0..18 — but New validates nothing about a token, so
// the engine has to survive one.
type deepToken struct{ d int }

func (deepToken) Name() string       { return "Deep" }
func (deepToken) Symbol() string     { return "DEEP" }
func (t deepToken) Decimals() int    { return t.d }
func (deepToken) TotalSupply() int64 { return 1_000_000 }

// scale() clamps a token's decimals before exponentiating, found surviving.
//
// 10^19 already overflows int64, and 10^k for k >= 64 wraps to exactly ZERO
// because every power of ten carries that many factors of two — so an unclamped
// scale divides by zero in units(), and units() is on the front page. Render is a
// READ, so a page that panics is a page nobody can look at, on a token nobody can
// fix from outside.
func TestScaleClampsAPathologicalTokensDecimals(t *testing.T) {
	g := New(&council{members: []address{gAlice}, epoch: 2}, deepToken{d: 64})
	if got := g.scale(); got <= 0 {
		t.Fatalf("scale() is %d — 10^64 wraps to zero and units() would divide by it", got)
	}
	// And the page renders at all, which is the property the clamp is for.
	mustNotPanic(t, func() { _ = g.Render("", "") })
}

// The units rendering, three of whose four rules were unheld.
//
// Called directly rather than through a page: these are exact string claims and a
// page assertion would smother them in the rest of the markdown.
func TestTheUnitsRenderingIsExact(t *testing.T) {
	g, _, _ := armed(t, gAlice)
	if g.token.Decimals() != 6 {
		t.Fatalf("this test states its expectations at 6 decimals; the token has %d",
			g.token.Decimals())
	}
	// A whole number reads as one, with no trailing ".0".
	if got := g.units(1_000_000); got != "1" {
		t.Errorf("a whole token renders as %q, want \"1\"", got)
	}
	// A fraction keeps its significant digits and drops the rest.
	if got := g.units(1_500_000); got != "1.5" {
		t.Errorf("one and a half renders as %q, want \"1.5\"", got)
	}
	// The smallest unit is zero-padded to the token's decimals, not printed as
	// though it were a tenth.
	if got := g.units(1); got != "0.000001" {
		t.Errorf("one base unit renders as %q, want \"0.000001\"", got)
	}
	// And the SIGN comes from the amount, not from its whole part. Integer division
	// truncates towards zero, so everything between -1 and 0 has a whole part of
	// exactly 0 and a minus taken from there is dropped — which renders -0.5 as
	// 0.5, the opposite number rather than a near miss. Not reachable through this
	// realm's own pages (a negative supply is refused at Propose), but units() is a
	// helper with a stated contract and this is it.
	if got := g.units(-500_000); got != "-0.5" {
		t.Errorf("minus a half renders as %q, want \"-0.5\"", got)
	}
}

// A span says HOURS up to two days, and days beyond, found surviving because the
// only durations any test rendered were the bootstrap terms — and 2 days is exactly
// on the boundary, so it reads the same whichever side the comparison falls.
//
// The choice is deliberate: "36 hours" is a figure somebody can hold against a
// deadline, where "1 day" for the same period is both vaguer and wrong by a third.
func TestASpanSaysHoursUpToTwoDays(t *testing.T) {
	// 36 hours at five seconds a block.
	if got := span(25_920); !contains(got, "36 hours") {
		t.Errorf("a thirty-six hour period renders as %q", got)
	}
	// The last block below two days is still hours; two days exactly is days.
	if got := span(34_559); !contains(got, "47 hours") {
		t.Errorf("one block short of two days renders as %q", got)
	}
	if got := span(34_560); !contains(got, "2 days") {
		t.Errorf("two days exactly renders as %q", got)
	}
	// And the singular, on both sides of the unit change.
	if got := span(720); !contains(got, "1 hour)") {
		t.Errorf("one hour renders as %q", got)
	}
}

// A proposal row is its own markdown list item, found surviving: drop the trailing
// newline and every row on the page runs into the one before it, collapsing the
// whole list into a single item. Nothing noticed because the page assertions all
// look for substrings, which survive being glued together.
func TestAProposalRowIsItsOwnListItem(t *testing.T) {
	g, _, _ := armed(t, gAlice, gBob, gCarl)
	a := g.Propose(gAlice, "fee", "1", "the first question")
	b := g.Propose(gAlice, "fee", "2", "the second question")
	if a == b {
		t.Fatal("setup: two proposals share an id")
	}
	page := g.Render("", "")
	// Each row begins a line of its own, so each is preceded by a newline.
	if got := strings.Count(page, "\n- [#"); got != 2 {
		t.Errorf("the page has %d rows beginning a line, want 2 — rows that do not "+
			"end their list item collapse into one\n%s", got, page)
	}
}

// An active proposal's countdown counts DOWN, found surviving. The existing test
// asserts the line is present; nothing asserted the number on it, so reversing the
// subtraction — printing how long ago voting would have closed — read as fine.
func TestTheCountdownToCloseCountsDown(t *testing.T) {
	g, _, _ := armed(t, gAlice, gBob, gCarl)
	id := g.Propose(gAlice, "fee", "1", "asked just now")
	// The fixture's kind votes for 100 blocks and nothing has advanced the clock,
	// so the whole window is still ahead.
	page := g.Render(strconv.FormatInt(id, 10), "")
	if !contains(page, "closes in 100 blocks") {
		t.Errorf("the page does not count down from the full voting window:\n%s", page)
	}
}

// A consumer-set ABSOLUTE quorum is rendered as the count it is, found surviving.
//
// ProposeWithQuorum replaces the rules' bps fraction with a number the consumer
// computed — a court sizing quorum to a claim's open interest — and the tally then
// compares turnout against that number outright. Render the percentage instead and
// the page states a bar the proposal is not being measured against: a reader works
// out from it that the vote has or has not cleared, and is wrong.
//
// The tally side of this was tested (TestProposeWithQuorumRaisesTheBar). The PAGE
// side was not, which is the half a holder actually reads.
func TestAnAbsoluteQuorumIsRenderedAsTheCountItIs(t *testing.T) {
	g, _, _ := armed(t, gAlice, gBob, gCarl)
	id := g.ProposeWithQuorum(gAlice, "fee", "1", "an absolute bar", 2)
	page := g.Render(strconv.FormatInt(id, 10), "")
	if !contains(page, "needs 2 ·") {
		t.Errorf("the page does not state the absolute floor the tally applies:\n%s", page)
	}
	// And not the bps bar the floor replaced, which is still sitting in the rules.
	if contains(page, "needs "+pct(5000)+" ·") {
		t.Errorf("the page states the bps quorum that the floor replaced:\n%s", page)
	}
}

// THE INVARIANT electorate.gno SAYS THIS ENGINE CANNOT CHECK, finally checked.
//
// electorate.gno's contract on PastTotal is the strongest claim in the package:
// "It must be at least the sum of every PastVotes at that epoch ... a roll whose
// parts exceed its whole reports votes that cannot exist and settles early.
// Measured, not feared: one voter reporting a hundred against a claimed total of
// ten carried a proposal at a 99% threshold ... The governor cannot check it and
// cannot recover from it — a clamp was tried."
//
// It had no test. It is the invariant a reverted change to kourtv2 broke, by
// adding a way to hand the engine a weight it had not derived: `cast` exceeded
// `p.total` and `rest := p.total - cast` went negative, so the early arms compared
// an inflated `yes` against a denominator snapshotted at (total - abstain) — a
// proposal passing on support that did not exist. A permissionless verdict flip,
// and nothing in either suite noticed.
//
// The wording here used to say the arm "dropped `no` out of the test entirely".
// That was wrong: turnout is yes+no+abstain, so yes+no+rest is identically
// total-abstain and `no` is not in the early-succeed comparison under ANY version
// of the code. TestTheEarlyArmsIgnoreNoAndACapOnlyDelays demonstrates it.
//
// The guard against a RE-INTRODUCED weight parameter is lexical
// (check-epoch-coherence.py, arm 3). This is the behavioural half: it asserts the
// bound holds on a real tally after every ballot, so that any future path which
// over-credits a voter fails here rather than in production.
func TestPartsNeverExceedTheWhole(cur realm, t *testing.T) {
	g, c, _ := armed(t, gAlice, gBob, gCarl)
	id := g.Propose(gAlice, "fee", "250", "parts vs whole")
	// The WHOLE, read from the electorate at the proposal's own epoch — the same
	// figure propose() snapshots into p.total, and the one `rest` is computed
	// against. Snapshot() returns (engaged, epoch), not the total.
	total := c.PastTotal(c.epoch)
	if total <= 0 {
		t.Fatal("fixture is vacuous: no electorate to bound the tally against")
	}

	// One ballot of each kind, and the bound re-checked after EVERY one: an
	// over-credit on any single vote is what breaks the early-decide arms, and
	// those are evaluated on the way through, not at the close.
	for i, v := range []address{gAlice, gBob, gCarl} {
		choice := []string{"yes", "no", "abstain"}[i]
		g.Vote(v, id, choice)
		yes, no, abstain, _ := g.Tally(id)
		if cast := yes + no + abstain; cast > total {
			t.Fatalf("after %d vote(s) cast=%d exceeds total=%d — rest is now "+
				"negative and the early-decide arms are reading a lie",
				i+1, cast, total)
		}
	}

	// And every recorded ballot is accounted for in the tally, so the bound above
	// is measured on the real accumulators rather than on a stale read.
	yes, no, abstain, _ := g.Tally(id)
	sum := int64(0)
	for _, v := range []address{gAlice, gBob, gCarl} {
		_, w, ok := g.VoteOf(id, v)
		if !ok {
			t.Fatal("a ballot that was cast is not recorded")
		}
		sum += w
	}
	if sum != yes+no+abstain {
		t.Fatalf("recorded ballots sum to %d, tally says %d", sum, yes+no+abstain)
	}
}

// weighted is an electorate with real per-address weights, which `council` cannot
// provide: it gives every member exactly 1, and no positive cap is below 1, so the
// clamp is untestable against it.
type weighted struct {
	w     map[string]int64
	total int64
	epoch uint32
}

func (e *weighted) PastVotes(who address, at uint32) int64 { return e.w[string(who)] }
func (e *weighted) PastTotal(at uint32) int64              { return e.total }
func (e *weighted) EngagedTotal(at uint32) int64           { return e.total }
func (e *weighted) Epoch() uint32                          { return e.epoch }
func (e *weighted) Height() int64                          { return runtime.ChainHeight() }

func weightedGov(t *testing.T, w map[string]int64, total int64) *Governor {
	t.Helper()
	e := &weighted{w: w, total: total, epoch: 2}
	g := New(e, coin{supply: total})
	g.kinds.Set("fee", &entry{kind: setFee{}, live: true, rules: Rules{
		QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 100000, GraceBlocks: 1_000_000,
	}})
	return g
}

// A CAP LOWERS THE TALLY, and it is the tallied figure that is recorded.
//
// This is the mechanism a whole panel found the suite blind to: ablating the clamp
// while keeping the `cap <= 0` refusal left all 293 kourtv2 tests green, which makes
// deleting it a SILENT revert to snapshot-only weight. This test is the detector.
func TestACapLowersTheTalliedWeight(cur realm, t *testing.T) {
	g := weightedGov(t, map[string]int64{string(gAlice): 1000}, 10_000)
	id := g.Propose(gAlice, "fee", "1", "capped")

	g.VoteWithCap(gAlice, id, "yes", 400)

	yes, _, _, _ := g.Tally(id)
	if yes != 400 {
		t.Fatalf("tallied %d, want the cap 400 — the clamp did not bind", yes)
	}
	_, w, ok := g.VoteOf(id, gAlice)
	if !ok || w != 400 {
		t.Fatalf("recorded ballot %d (ok=%v), want 400 — the record must match "+
			"the tally or every pro-rata payout downstream diverges", w, ok)
	}
}

// A CAP ABOVE THE SNAPSHOT CHANGES NOTHING. The ceiling is the engine's own read,
// so a consumer cannot raise weight — which is the property that makes a supplied
// figure safe here where a supplied WEIGHT was a permissionless verdict flip.
func TestACapAboveTheSnapshotCannotRaiseWeight(cur realm, t *testing.T) {
	g := weightedGov(t, map[string]int64{string(gAlice): 1000}, 10_000)
	id := g.Propose(gAlice, "fee", "1", "cap above")

	g.VoteWithCap(gAlice, id, "yes", 9_999_999)

	yes, _, _, _ := g.Tally(id)
	if yes != 1000 {
		t.Fatalf("tallied %d, want the snapshot 1000 — a cap must not raise", yes)
	}
}

// A NON-POSITIVE CAP IS REFUSED. Zero is not an edge case: a renter who has sold
// everything HAS a live balance of zero, so treating zero as "uncapped" — which the
// plan for this change originally did — hands the full rented weight straight back.
func TestANonPositiveCapIsRefused(cur realm, t *testing.T) {
	g := weightedGov(t, map[string]int64{string(gAlice): 1000}, 10_000)
	id := g.Propose(gAlice, "fee", "1", "zero cap")

	mustPanic(t, "govern: a vote cap must be positive; use Vote for no cap",
		func() { g.VoteWithCap(gAlice, id, "yes", 0) })
	mustPanic(t, "govern: a vote cap must be positive; use Vote for no cap",
		func() { g.VoteWithCap(gAlice, id, "yes", -1) })

	if yes, no, ab, _ := g.Tally(id); yes+no+ab != 0 {
		t.Fatalf("a refused cap still moved the tally: %d/%d/%d", yes, no, ab)
	}
	// And the ordinary path it must NOT refuse.
	g.VoteWithCap(gAlice, id, "yes", 500)
	if yes, _, _, _ := g.Tally(id); yes != 500 {
		t.Fatalf("tallied %d after a legal cap, want 500", yes)
	}
}

// PARTS NEVER EXCEED THE WHOLE, with a capped voter in the mix. A cap can only
// shrink an addend, so the bound the early-decide arms rest on is preserved — but
// it is asserted rather than argued, because `rest := p.total - cast` going negative
// is the failure that produced a verdict flip once already.
func TestACappedTallyStillRespectsTheWhole(cur realm, t *testing.T) {
	g := weightedGov(t, map[string]int64{
		string(gAlice): 4000, string(gBob): 3000, string(gCarl): 2000,
	}, 10_000)
	id := g.Propose(gAlice, "fee", "1", "capped whole")

	g.VoteWithCap(gAlice, id, "yes", 1500)
	g.Vote(gBob, id, "no")
	g.VoteWithCap(gCarl, id, "abstain", 500)

	yes, no, ab, _ := g.Tally(id)
	if cast := yes + no + ab; cast > 10_000 {
		t.Fatalf("cast %d exceeds the whole 10000 — rest is negative and the "+
			"early-decide arms are reading a lie", cast)
	}
	if yes != 1500 || no != 3000 || ab != 500 {
		t.Fatalf("tally %d/%d/%d, want 1500/3000/500 — capped addends should be "+
			"the cap and uncapped ones the snapshot", yes, no, ab)
	}
}

// THE EARLY-DECIDE ARMS, WITH THEIR ACTUAL ALGEBRA, AND WHAT A CAP DOES TO THEM.
//
// This is the site the reverted design broke, and the comments describing that
// breakage were wrong about how. They said a supplied weight made the early-succeed
// arm "reduce to yes*bps >= (total - abstain)*ThresholdBps, dropping `no` out of the
// test entirely". But turnout is yes+no+abstain and rest is total-cast, so
//
//	yes + no + rest  ==  total - abstain
//
// IDENTICALLY — always, bug or no bug. `no` is not in the early-succeed comparison
// and never was, so its absence cannot have been the defect. Written out, the two
// arms are:
//
//	early-succeed   yes*bps        >= (total - abstain)*T
//	early-defeat    (total - no - abstain)*bps  <  (total - abstain)*T
//
// The real defect was an inflated NUMERATOR against a snapshotted denominator: a
// supplied weight is not drawn from p.total, so `yes` could exceed anything the
// electorate held while (total - abstain) stayed put — passing on support that did
// not exist. And negatively: rest < 0 shrinks (yes+rest), so the defeat arm could
// fire on a question still open.
//
// A CEILING has the opposite sign in both arms, which is what makes it safe:
// capping lowers yes (early-succeed harder), lowers abstain (raising the bar, so
// harder again), and lowers no (early-defeat harder). It can only ever DELAY.
func TestTheEarlyArmsIgnoreNoAndACapOnlyDelays(cur realm, t *testing.T) {
	total := int64(10_000)
	// ARM 1 — `no` does not enter early-succeed. Two proposals, identical yes and
	// abstain, wildly different no, same decision. This is the assertion that
	// refutes the old comment rather than merely not repeating it.
	for _, tc := range []struct {
		name string
		no   int64
	}{{"no-opposition", 0}, {"heavy-opposition", 3000}} {
		g := weightedGov(t, map[string]int64{
			string(gAlice): 6000, string(gBob): 3000, string(gCarl): 1000,
		}, total)
		id := g.Propose(gCarl, "fee", "1", tc.name)
		g.Vote(gAlice, id, "yes") // 6000 >= (10000-0)*5000/10000 = 5000
		if got := g.State(id); got != "succeeded" {
			t.Fatalf("%s: yes 6000 of a 10000 whole must early-succeed on the "+
				"yes-vs-(total-abstain) test alone, got %q", tc.name, got)
		}
	}

	// ARM 2 — ABSTAIN does enter it, by shrinking the denominator. The same yes
	// that was short becomes sufficient once someone abstains, which is the half of
	// the arm the old comment got right.
	g := weightedGov(t, map[string]int64{
		string(gAlice): 4000, string(gBob): 3000, string(gCarl): 3000,
	}, total)
	id := g.Propose(gCarl, "fee", "1", "abstain shrinks the bar")
	g.Vote(gAlice, id, "yes") // 4000 < 5000: not yet
	if got := g.State(id); got != "active" {
		t.Fatalf("fixture is vacuous: 4000 must be short of the 5000 bar so the "+
			"abstain below can be what moves it, got %q", got)
	}
	g.Vote(gBob, id, "abstain") // bar becomes (10000-3000)*0.5 = 3500 <= 4000
	if got := g.State(id); got != "succeeded" {
		t.Fatalf("an abstain shrinks total-abstain and should decide this: %q", got)
	}

	// ARM 3 — A CAP ONLY DELAYS. Same weights, same block, no clock movement: the
	// uncapped proposal decides and the capped one does not.
	up := weightedGov(t, map[string]int64{
		string(gAlice): 6000, string(gBob): 4000,
	}, total)
	a := up.Propose(gBob, "fee", "1", "uncapped")
	up.Vote(gAlice, a, "yes")
	if got := up.State(a); got != "succeeded" {
		t.Fatalf("fixture is vacuous: the uncapped arm must decide, got %q", got)
	}
	dn := weightedGov(t, map[string]int64{
		string(gAlice): 6000, string(gBob): 4000,
	}, total)
	b := dn.Propose(gBob, "fee", "1", "capped")
	dn.VoteWithCap(gAlice, b, "yes", 4000) // 4000 < 5000
	if got := dn.State(b); got != "active" {
		t.Fatalf("a cap must DELAY the early success, not skip past it: %q", got)
	}

	// And the invariant both arms rest on, which is the thing that actually broke:
	// the parts never exceed the whole, so rest is never negative.
	yes, no, ab, _ := dn.Tally(b)
	if cast := yes + no + ab; cast > total {
		t.Fatalf("cast %d exceeds the whole %d: rest is negative and both early "+
			"arms are reading a lie", cast, total)
	}
}
