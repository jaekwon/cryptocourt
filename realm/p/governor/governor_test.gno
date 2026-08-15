package governor

import (
	"strconv"
	"testing"

	"gno.land/p/nt/testutils/v0"
)

var (
	alice = testutils.TestAddress("galice")
	bob   = testutils.TestAddress("gbob")
	carl  = testutils.TestAddress("gcarl")
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

// dispatch is what a consuming realm supplies. In a test there is no `cur` to
// mint a sub-realm from, so the token is nil — which is exactly what the type
// permits and why Do takes it as a parameter rather than reaching for one.
func dispatch(k Kind, subpath, payload string) error {
	var none realm
	return k.Do(0, none, payload)
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
	g, _, ran := armed(t, alice, bob, carl)

	id := g.Propose(alice, "fee", "250", "set it to 250")
	if got := g.State(id); got != "active" {
		t.Fatalf("a fresh proposal is %q", got)
	}

	// Two of three is past a 50% quorum and carries the threshold, so the
	// arithmetic decides it without waiting for the deadline.
	g.Vote(alice, id, "yes")
	if got := g.State(id); got != "active" {
		t.Fatalf("one of three votes settled it: %q", got)
	}

	// A second vote from one member is refused while it is still open, which is
	// the roll doing its job. Asked here rather than after it settles, because
	// a closed proposal refuses everybody for a different reason and would
	// answer this question by accident.
	mustPanic(t, "govern: already voted", func() { g.Vote(alice, id, "no") })

	g.Vote(bob, id, "yes")
	if got := g.State(id); got != "succeeded" {
		t.Fatalf("two of three yes votes leaves it %q, want succeeded", got)
	}

	// And it runs, through the dispatcher the consumer supplies. No delay to
	// wait out — the fixture sets DelayBlocks to zero — and the grace period
	// is what would end it if nobody did.
	g.Execute(carl, id, dispatch)
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
	g, _, _ := armed(t, alice, bob, carl)
	id := g.Propose(alice, "fee", "7", "seven")
	g.Vote(alice, id, "yes")
	g.Vote(bob, id, "yes")

	mustPanic(t, "govern: a dispatcher is required to run a kind", func() {
		g.Execute(alice, id, nil)
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
	a, _, _ := armed(t, alice, bob, carl)
	b, _, _ := armed(t, carl)

	ida := a.Propose(alice, "fee", "1", "in a")
	idb := b.Propose(carl, "fee", "1", "in b")

	if ida != idb {
		t.Errorf("the two governors share a sequence: %d and %d", ida, idb)
	}
	a.Vote(alice, ida, "yes")
	a.Vote(bob, ida, "yes")
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
	a, _, _ := armed(t, alice, bob)
	b, _, _ := armed(t, carl)

	// A kind offered to A only.
	var ran int64
	a.Offer(alice, setFee{name: "toll/k", ran: &ran}, Rules{
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
