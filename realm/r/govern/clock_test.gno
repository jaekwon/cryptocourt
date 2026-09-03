package govern

import (
	governor "gno.land/p/kourt/governor/v0"
	grc20votes "gno.land/p/kourt/grc20votes/v0"
	"chain/runtime"
	"testing"
	"time"

)

// The test harness is not a chain, and the difference matters here.
//
// gno resets the block height between tests, so ChainHeight() starts low again
// in each one. This ledger's checkpoints assume a clock that only ever moves
// forward — that assumption is why height is the clock rather than block time,
// and setAt panics if it is violated — so tests have to supply what the
// harness does not.
//
// A package-level high-water mark, and every advance measured from it rather
// than from whatever the harness last reset to.
var testHeight int64

// clockBaseUnix is gno's own test-genesis timestamp, and it has to be THAT
// number rather than any convenient one. The harness fabricates a height, so it
// must fabricate the matching time — but a base that disagrees with the clock
// the VM starts at makes the first advance a discontinuity: a proposal stamped
// before any advance carries the VM's time, and the first setClock then jumps
// the clock 465 million seconds past its deadline. Anchoring here means the
// fabricated clock is the same clock, moved forward.
const clockBaseUnix = int64(1_234_567_890)

// setClock moves BOTH clocks, and that is the whole point of it.
//
// The harness used to fabricate a height with testing.SetHeight and leave block
// time alone. That was invisible while the governor gated on height, and stopped
// being invisible the moment a voting deadline became a date: a proposal's
// closesTime is written from the wall clock, so a fixture that advanced 200
// blocks without advancing time left every proposal permanently open, and two
// tests reported "active, want defeated" for a reason that had nothing to do
// with what they were testing.
//
// A REAL CHAIN CANNOT ADVANCE ONE WITHOUT THE OTHER, so neither may this. The
// time is derived from the height rather than tracked separately, which makes
// the lockstep structural: there is no sequence of calls that can desynchronise
// them, and the forward-only guarantee the checkpoints depend on carries to the
// clock for free.
func setClock(h int64) {
	ctx := testing.GetContext()
	ctx.Height = h
	ctx.Time = time.Unix(clockBaseUnix+h*5, 0)
	testing.SetContext(ctx)
}

func advanceBlocks(n int64) {
	if h := runtime.ChainHeight(); h > testHeight {
		testHeight = h
	}
	testHeight += n
	setClock(testHeight)
}

// resumeClock puts the height back where the last test left it.
//
// Every test must call this before it writes anything. The harness rewinds
// between tests, so a test that mints before advancing is writing a checkpoint
// at a height BELOW one already recorded — which is exactly the backwards
// clock setAt refuses, and rightly.
func resumeClock() { advanceBlocks(0) }

// advanceEpochs seals the current epoch and moves into a later one, which is
// what a test needs before it can ask any historical question.
func advanceEpochs(n int64) { advanceBlocks(n * epochBlocks) }

// advanceTo moves the clock to an exact height, for a test that cares which
// block a window ends on rather than how long it lasts.
//
// advanceBlocks cannot express that: it counts from a high-water mark the test
// does not know, so "one block before the deadline" is not something it can
// say. Refuses to go backwards for the same reason setAt does.
func advanceTo(h int64) {
	if cur := runtime.ChainHeight(); cur > testHeight {
		testHeight = cur
	}
	if h < testHeight {
		panic("advanceTo: the clock only moves forward")
	}
	testHeight = h
	setClock(testHeight)
}

// resetLedger gives a test an empty token and an empty governor.
//
// Package state is shared by every test in a realm, so without this each one
// inherits whatever the last left behind — and the compensation is worse than
// the problem: tests start sizing their stakes against TotalSupply() so that a
// holder still has a majority of a supply they cannot predict. That works until
// somebody adds a file that mints, at which point an unrelated test fails and
// the breakage lands on whoever was writing something else.
//
// The clock is deliberately NOT reset. Heights must only ever move forward —
// the checkpoints refuse a backwards write — so the high-water mark carries
// across, and a fresh ledger simply starts recording at a later epoch.
func resetLedger() {
	// A whole new ledger and a whole new governor. Both are values now, so
	// "empty" is what the constructors return and there is no package state
	// left here to forget one of.
	ledger = grc20votes.NewLedger(tokenName, tokenSymbol, tokenDecimals, epochBlocks)
	ledger.SetID(tokenID)
	engine = governor.New(ledger, ledger)
	engine.InstallBuiltin(minterKind{}, governor.BootstrapRules())
}
