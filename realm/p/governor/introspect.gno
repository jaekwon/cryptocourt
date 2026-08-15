package governor

// What a consumer can ask that the pages already say.
//
// Render publishes most of this — the slot count, a proposal's epoch, why one
// ended — and a caller that has to scrape a markdown page for a number the
// engine holds is an engine with an incomplete API. These are the reads that
// close that gap.
//
// None of them hands back a pointer. That is the rule the whole package is
// built to (gno-security-guide.md §3(B)): a /p/-declared type can be named by
// another /p/ package, so an exported *proposal or a live tree handle would let
// a stranger declare a mutator over it and have the storage-realm borrow run it
// under the CONSUMING realm's authority. Counts, copies and strings only.

// The board's dimensions, which the front page prints and a caller may want to
// reason about before proposing.
const (
	// MaxLive is how many proposals may stand at once.
	MaxLive = maxLive

	// MaxOpen is how many of those an ordinary kind may fill. The difference
	// is kept for the governor's own kinds, so a flood of one thing cannot
	// stop the holders changing the rules.
	MaxOpen = maxOpen

	// GovLanes is that difference.
	GovLanes = govLanes

	// Reserved is the prefix the governor's own kinds carry, which Offer
	// refuses so that nothing published can render as a built-in.
	Reserved = reserved
)

// OpenSlots is how many proposals are holding a slot, decided-and-unrun
// included. The number the front page prints beside MaxLive.
func (g *Governor) OpenSlots() int { return g.openIdx.Size() }

// Proposals is how many questions have ever been asked here.
func (g *Governor) Proposals() int { return g.proposals.Size() }

// Reason is why a proposal ended, or the empty string while it is still open.
// The page prints it; this is the same string.
func (g *Governor) Reason(id int64) string { return g.mustProposal(id).reason }

// EpochOf is the sealed epoch a proposal's weight was read at. Fixed when the
// question was asked, and the reason buying in afterwards buys nothing.
func (g *Governor) EpochOf(id int64) uint32 { return g.mustProposal(id).epoch }

// RollSize is how many addresses are on a proposal's voter roll.
//
// Zero can mean two things and HasRoll separates them: nobody has voted yet, or
// the roll was reclaimed after the proposal finished.
func (g *Governor) RollSize(id int64) int {
	p := g.mustProposal(id)
	if p.voted == nil {
		return 0
	}
	// The sentinel Propose plants is not a voter. See rollSentinel.
	n := p.voted.Size()
	if p.voted.Has(rollSentinel) {
		n--
	}
	return n
}

// HasRoll reports whether a proposal is still holding its voter roll, or has
// given it back through ReleaseRoll.
func (g *Governor) HasRoll(id int64) bool { return g.mustProposal(id).voted != nil }

// KindStatus is whether a name has been offered here, and whether the holders
// have adopted it. Both false for a name nobody has published.
func (g *Governor) KindStatus(name string) (offered, live bool) {
	e := g.entryOf(name)
	if e == nil {
		return false, false
	}
	return true, e.live
}

// KindRules is the terms a kind was adopted on. A copy: Rules is a plain struct
// of numbers, so handing one back gives away nothing to write through.
func (g *Governor) KindRules(name string) (Rules, bool) {
	e := g.entryOf(name)
	if e == nil {
		return Rules{}, false
	}
	return e.rules, true
}

// Digest is the key a question occupies in the open index, derived from the
// kind and payload that define it. Exported because it is a pure function of
// two public strings, and because what it is FOR is worth knowing: a proposer
// chooses their payload and so chooses their key, which is why the slot sweep
// rotates rather than always starting at the low end.
func (g *Governor) Digest(kind, payload string) string { return g.digest(kind, payload) }

// Adopt installs a kind as live without a vote.
//
// The consuming realm's, and nobody else's — reaching it needs the *Governor,
// which a realm keeps unexported. That is the same authority the realm already
// has by holding the engine at all, so this grants nothing new; what it does is
// make the un-voted path explicit and greppable rather than something a realm
// improvises by reaching into a tree.
//
// For a realm's OWN powers, and for arming a governor in a test. Anything a
// stranger publishes goes through Offer and an adoption vote, which is the
// distinction the whole design turns on: publishing code and letting that code
// hold the governor's authority are different decisions taken by different
// actors.
//
// A realm that exposes this through a crossing function has given governance
// away. So would exposing Propose without its rules, or Execute without its
// timelock; the engine cannot stop a consumer publishing the wrong thing, and
// says so here because this is the one most obviously worth not publishing.
func (g *Governor) Adopt(k Kind, r Rules) {
	name := k.Name()
	mustBeUsableName(name)
	g.mustBeSaneRules(r)
	g.kinds.Set(name, &entry{kind: k, rules: r, live: true})
}
