package governor

import (
	"strconv"
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

func (coin) Name() string          { return "Test Coin" }
func (coin) Symbol() string        { return "TEST" }
func (coin) Decimals() int         { return 6 }
func (c coin) TotalSupply() int64  { return c.supply }

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
	if page := two.Render(""); !contains(page, "12.34 PENNY") {
		t.Errorf("the front page does not render the supply at the token's "+
			"own scale:\n%s", page)
	}
}

// penny is a token with a scale that is not the one anybody would hardcode.
type penny struct{}

func (penny) Name() string         { return "Penny" }
func (penny) Symbol() string       { return "PENNY" }
func (penny) Decimals() int        { return 2 }
func (penny) TotalSupply() int64   { return 1234 }

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
