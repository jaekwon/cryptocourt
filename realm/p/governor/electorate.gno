package governor

import (
	bptree "gno.land/p/nt/bptree/v0"
)

// Electorate is where voting weight comes from, and the only thing tying this
// engine to any particular token. Everything else here is about proposals, so
// with this extracted the engine can be driven by anything that can answer
// four questions.
//
// It also makes the governor testable without a ledger. Reaching exactly a
// quorum with real balances means solving for the supply, and a test that does
// arithmetic to test arithmetic proves nothing.
//
// EVERY QUESTION HERE IS ABOUT A SEALED PAST EPOCH, which is what keeps the
// Token/Electorate split below honest — Electorate about then, Token about now.
// A live per-address read (VotesOf) was added here while fixing rented weight and
// removed again when the fix was reverted; RENTEDWEIGHT.md records why. Anything
// re-adding it is re-opening that decision, not making a small change.
type Electorate interface {
	// PastVotes is what an address could vote at a sealed epoch.
	PastVotes(who address, at uint32) int64

	// PastTotal is everything that existed then, which quorum is a fraction
	// of. Taken at the same epoch as the votes it is compared against, or a
	// quorum could be met against a supply that no longer exists.
	//
	// It must be at least the sum of every PastVotes at that epoch. The
	// governor subtracts what has been cast from this to decide whether a
	// question is already settled, so a roll whose parts exceed its whole
	// reports votes that cannot exist and settles early. Measured, not feared:
	// one voter reporting a hundred against a claimed total of ten carried a
	// proposal at a 99% threshold.
	//
	// This realm's token satisfies it exactly, and a test says so after every
	// operation that moves power. Anything swapped in here needs its own. The
	// governor cannot check it and cannot recover from it — a clamp was tried.
	//
	// It must also stay at or below maxWeighable (MaxInt64/bps): the tally
	// computes yes*bps, and a supply above that overflows int64 into a negative
	// tally — a won vote reported as lost. grc20votes caps its supply there
	// exactly; the governor refuses a proposal whose snapshot supply exceeds it,
	// so a swapped-in electorate that ignores the ceiling fails loudly at the door.
	PastTotal(at uint32) int64

	// EngagedTotal is the part of PastTotal that quorum is measured against.
	//
	// It exists so a realm can drop idle weight out of the denominator without
	// touching anything in the governor: a fixed low bar is unreachable at
	// launch and trivial later, and moving the denominator is the fix that
	// keeps the bar meaningful at both ends.
	//
	// Should be <= PastTotal at the same epoch. Weight outside it can still vote
	// — it simply is not counted in the bar — so the governor keeps using
	// PastTotal for how many votes could still be cast. If it exceeds PastTotal
	// the governor clamps it down to PastTotal, so an electorate that over-reports
	// engagement makes the bar unreachable-but-valid rather than aborting.
	//
	// This realm's token returns PastTotal unchanged: every holder is engaged
	// by definition, since power is self-delegated by default.
	EngagedTotal(at uint32) int64

	// Epoch is now. A proposal snapshots Epoch()-1 and stores it; nothing
	// re-derives it later.
	Epoch() uint32

	// Height is the block height the governor gates on: when voting opens and
	// closes, when a delay has elapsed, when a proposal may execute.
	//
	// It comes from the electorate rather than from the chain so that a realm
	// whose clock can be fast-forwarded moves the VOTES with it. Reading
	// runtime.ChainHeight() here instead would leave a test chain able to age
	// everything except the one thing a dispute waits on, and would let the
	// governor and the ledger disagree about what epoch it is.
	Height() int64
}

// Token is what a page needs to name the thing being voted: an identity and a
// live supply. Separate from Electorate because they answer about different
// times — Electorate about a sealed epoch, Token about now — and a realm may
// well have one without the other.
//
// p/kourt/grc20votes.Ledger satisfies both, which is the ordinary case.
type Token interface {
	Name() string
	Symbol() string
	Decimals() int
	TotalSupply() int64
}

// New creates a governor with no kinds adopted and nothing proposed, and
// installs the built-in kinds that govern the governor itself.
//
// The minter kind is NOT among them: who may create supply is a policy about a
// caller, and a pure package has no caller. A realm wanting one registers it
// with InstallBuiltin.
func New(voters Electorate, token Token) *Governor {
	if voters == nil || token == nil {
		panic("governor: a governor needs an electorate and a token")
	}
	g := &Governor{
		voters:    voters,
		token:     token,
		kinds:     bptree.NewBPTree32(),
		proposals: bptree.NewBPTree32(),
		openIdx:   bptree.NewBPTree32(),
	}
	g.installBuiltins()
	return g
}

// InstallBuiltin adopts a kind under the reserved prefix, which Offer refuses.
//
// For the consuming realm only, and it is unexported state that makes that
// true: reaching this needs the *Governor, which the realm keeps to itself.
// A realm uses it for a power that is its own rather than the engine's — the
// mint being the example.
func (g *Governor) InstallBuiltin(k Kind, r Rules) {
	name := k.Name()
	if !isReserved(name) {
		panic("governor: a built-in has to carry the reserved prefix")
	}
	mustBeUsableName(name)
	g.mustBeSaneRules(r)
	g.kinds.Set(name, &entry{kind: k, rules: r, live: true})
}
