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

var (
	gAlice = testutils.TestAddress("galice")
	gBob   = testutils.TestAddress("gbob")
	gCarl  = testutils.TestAddress("gcarl")

	// actor is whoever the test is currently acting as. The realm above reads
	// this from `cur.Previous()`; here it is passed in, so a test says who is
	// acting by assigning it.
	actor address
)

// fresh is a governor with nothing proposed, over a ledger with nothing minted.
//
// No reset: both are values, so "empty" is what the constructors return. That
// is the difference the /p/ split makes to the tests — there is no package
// state left to forget to clear, which is what an isolation sweep exists to
// catch.
func fresh() (*Governor, *grc20votes.Ledger) {
	led := grc20votes.NewLedger(testTokenName, testTokenSymbol, testDecimals, testEpochBlocks)
	g := New(led, led)
	actor = gAlice
	resumeClock()
	return g, led
}

// dispatch is what a consuming realm supplies to Execute. There is no `cur` in
// a test to mint a sub-realm from, so the token is the zero realm — which is
// exactly what the Dispatch type permits, and why Kind.Do takes one as a
// parameter rather than reaching for it.
func dispatch(k Kind, subpath, payload string) error {
	var none realm
	return k.Do(0, none, payload)
}

// The clock only moves forward, because the checkpoints refuse a backwards
// write. gno resets the height between tests, so the high-water mark is carried
// here and every test resumes from it rather than from wherever the harness
// left the height.
var testHeight int64

func advanceBlocks(n int64) {
	if h := runtime.ChainHeight(); h > testHeight {
		testHeight = h
	}
	testHeight += n
	testing.SetHeight(testHeight)
}

func resumeClock() { advanceBlocks(0) }

func advanceEpochs(n int64) { advanceBlocks(n * testEpochBlocks) }

func advanceTo(h int64) {
	if cur := runtime.ChainHeight(); cur > testHeight {
		testHeight = cur
	}
	if h < testHeight {
		panic("advanceTo: the clock only moves forward")
	}
	testHeight = h
	testing.SetHeight(testHeight)
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
