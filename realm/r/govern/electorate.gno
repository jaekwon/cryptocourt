package govern

// electorate is where voting weight comes from, and the only thing tying the
// governor to this realm's token. Everything else is about proposals, so with
// this extracted the engine could be embedded by any realm that can answer
// these three questions.
//
// It also makes the governor testable without a ledger. Reaching exactly a
// quorum with real balances means solving for the supply, and a test that does
// arithmetic to test arithmetic proves nothing.
type electorate interface {
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
	PastTotal(at uint32) int64

	// EngagedTotal is the part of PastTotal that quorum is measured against.
	//
	// It exists so a realm can drop idle weight out of the denominator without
	// touching anything in the governor: a fixed low bar is unreachable at
	// launch and trivial later, and moving the denominator is the fix that
	// keeps the bar meaningful at both ends.
	//
	// Must be <= PastTotal at the same epoch. Weight outside it can still vote
	// — it simply is not counted in the bar — so the governor keeps using
	// PastTotal for how many votes could still be cast.
	//
	// This realm's token returns PastTotal unchanged: every holder is engaged
	// by definition, since power is self-delegated by default.
	EngagedTotal(at uint32) int64

	// Epoch is now. A proposal snapshots Epoch()-1 and stores it; nothing
	// re-derives it later.
	Epoch() uint32
}

// tokenVotes reads this realm's own token: the electorate is not a roll
// somebody maintains, it is the history the ledger already keeps.
type tokenVotes struct{}

func (tokenVotes) PastVotes(who address, at uint32) int64 { return ledger.PastVotes(who, at) }
func (tokenVotes) PastTotal(at uint32) int64              { return ledger.PastTotal(at) }
func (tokenVotes) EngagedTotal(at uint32) int64           { return ledger.EngagedTotal(at) }
func (tokenVotes) Epoch() uint32                          { return ledger.Epoch() }

// voters is what the governor reads. A variable rather than a constant so a
// test can stand a fake in front of it; nothing exported can change it, so a
// deployed realm has exactly one electorate and it is the token.
var voters electorate = tokenVotes{}
