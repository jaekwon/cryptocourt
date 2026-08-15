package govern

import (
	grc20votes "gno.land/p/cryptocourt/grc20votes/v0"
	"chain/runtime"
	"testing"

	bptree "gno.land/p/nt/bptree/v0"
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

func advanceBlocks(n int64) {
	if h := runtime.ChainHeight(); h > testHeight {
		testHeight = h
	}
	testHeight += n
	testing.SetHeight(testHeight)
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
	testing.SetHeight(testHeight)
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
	// A whole new ledger rather than four trees cleared. The token is an
	// allocated value now, so "empty" is what a constructor returns and there
	// is no package state left here to forget one of.
	ledger = grc20votes.NewLedger(tokenName, tokenSymbol, tokenDecimals, epochBlocks)
	ledger.SetID(tokenID)

	proposals = bptree.NewBPTree32()
	openIdx = bptree.NewBPTree32()
	propSeq = 0
	voters = tokenVotes{}

	// The sweep cursor is state like the rest of it. Left behind, it points
	// into the index a previous test built, so where a sweep starts depends on
	// which tests ran before.
	//
	// Measured, not assumed: with the cursor leaking, two mutations of sweep
	// survive that are caught with it reset. Leaking state does not change
	// whether the tests pass — it changes whether they can FAIL, which is the
	// harder thing to notice and the only thing a test is for.
	sweepFrom = ""

	// The kind registry, back to the five the realm ships with.
	//
	// Without this, a test needing a kind can get one from whatever ran before,
	// and assert messages about a kind it never registered. With it, an order
	// dependency fails the ordinary suite instead of needing the isolation
	// sweep to find it.
	//
	// A mutation deleting these two lines survives, and that is correct rather
	// than a gap: every test registers what it needs now, so nothing depends on
	// the reset. It closes a class instead of implementing a behaviour, and
	// there is no test that can tell the difference. The thing that would catch
	// its absence is a NEW test written to lean on a neighbour, which is
	// exactly what it exists to stop.
	kinds = bptree.NewBPTree32()
	installBuiltins()
}
