package governor

import (
	"chain/runtime"
	"testing"

	grc20votes "gno.land/p/cryptocourt/grc20votes/v0"
	"gno.land/p/nt/testutils/v0"
)

// The engine's tests drive it against the real ledger.
//
// A /p/ package may import another, and this one is in a _test file only — the
// shipped engine names no concrete electorate, which is the whole point of the
// Electorate seam. What the seam is FOR is that a governor can be driven by
// something else; what the tests want is realism, and a fake electorate proves
// less about paging, checkpoints and epochs than the thing itself does.
//
// governor_test.gno has the other half: a council that is not a token at all,
// where the quorum boundary can be stated rather than solved for.

const (
	testEpochBlocks = int64(720)
	testTokenName   = "Test Governance"
	testTokenSymbol = "TEST"
	testDecimals    = 6
)

// The addresses are constants, which they have to be.
//
// A /p/ package's state is frozen after init: Realm.DidUpdate panics with
// "package is immutable post-init" on a write to a real /p/-stamped object
// outside init, and a test file is part of the package. So NOTHING here may be
// a mutable package-level var — not a shared fixture, not a high-water clock,
// not a "who is acting now". Anything that changes during a test is a local.
//
// That is the same rule the engine itself is built to, seen from the tests: it
// is why a Governor is a value the caller allocates rather than package state,
// and the tests cannot cheat where the code cannot.
var (
	gAlice = testutils.TestAddress("galice")
	gBob   = testutils.TestAddress("gbob")
	gCarl  = testutils.TestAddress("gcarl")
	gDave  = testutils.TestAddress("gdave") // a fourth holder, for tests that need a non-voter
	gNemo  = testutils.TestAddress("gnemo") // never mints, votes, or holds — the "nobody" address
)

// fresh is a governor with nothing proposed, over a ledger with nothing minted.
//
// No reset: both are values, so "empty" is what the constructors return. That
// is the difference the /p/ split makes to the tests — there is no package
// state left to forget to clear, which is what an isolation sweep exists to
// catch.
func fresh() (*Governor, *grc20votes.Ledger) {
	led := grc20votes.NewLedger(testTokenName, testTokenSymbol, testDecimals, testEpochBlocks)
	return New(led, led), led
}

// dispatch is what a consuming realm supplies to Execute. There is no `cur` in
// a test to mint a sub-realm from, so the token is the zero realm — which is
// exactly what the Dispatch type permits, and why Kind.Do takes one as a
// parameter rather than reaching for it.
func dispatch(k Kind, subpath, payload string) error {
	var none realm
	return k.Do(0, none, payload)
}

// The clock is read from the chain rather than tracked.
//
// The realm's tests carry a high-water mark, because they share one ledger
// across the suite and its checkpoints refuse a backwards write. Here every
// test allocates its own, so there is no earlier checkpoint to contradict and
// nothing to remember — which is just as well, since a package-level int64
// could not be written to anyway.
func advanceBlocks(n int64) { testing.SetHeight(runtime.ChainHeight() + n) }

func advanceEpochs(n int64) { advanceBlocks(n * testEpochBlocks) }

func advanceTo(h int64) {
	if now := runtime.ChainHeight(); h < now {
		panic("advanceTo: the clock only moves forward")
	}
	testing.SetHeight(h)
}

// mustPanicContains is uassert.AbortsContains without the realm argument, which
// a /p/ test cannot supply: taking `cur realm` here would declare a crossing
// function, and a pure package may not have one.
func mustPanicContains(t *testing.T, want string, fn func()) {
	t.Helper()
	defer func() {
		r := recover()
		if r == nil {
			t.Errorf("expected a panic containing %q; nothing panicked", want)
			return
		}
		got, _ := r.(string)
		if !contains(got, want) {
			t.Errorf("panicked with %q, want something containing %q", got, want)
		}
	}()
	fn()
}

func mustNotPanic(t *testing.T, fn func()) {
	t.Helper()
	defer func() {
		if r := recover(); r != nil {
			t.Errorf("did not expect a panic, got %v", r)
		}
	}()
	fn()
}

func contains(s, sub string) bool {
	if len(sub) > len(s) {
		return false
	}
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
