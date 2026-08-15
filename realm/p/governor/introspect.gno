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

	// The bounds on a proposal's three strings, which doc.gno publishes as a
	// table because they decide what a proposer can say before finding out by
	// transaction.
	MaxTitle    = maxTitle
	MaxPayload  = maxPayload
	MaxKindName = maxKindName

	// MaxBatch is how many members one govern:batch may carry.
	MaxBatch = maxBatch

	// Bps is the basis-point scale every bar here is expressed in.
	Bps = bps

	// MaxReason is the longest failure message a kind can put on the record.
	// A kind returns the string and the governor keeps it for the life of the
	// realm, so it is clipped rather than trusted.
	MaxReason = maxReason

	// Reserved is the prefix the governor's own kinds carry, which Offer
	// refuses so that nothing published can render as a built-in.
	Reserved = reserved
)

// OpenSlots is how many proposals are holding a slot, decided-and-unrun
// included. The number the front page prints beside MaxLive.
func (g *Governor) OpenSlots() int { return g.openIdx.Size() }

// Proposals is how many questions have ever been asked here.
func (g *Governor) Proposals() int { return g.proposals.Size() }

// StoredState is the state that has been WRITTEN DOWN, which is not always the
// state a reader is shown.
//
// State computes the outcome from the rules and the clock, because a proposal
// whose deadline passed is decided whether or not anybody has poked it. Only a
// transaction records that, so between the deadline and the next Settle the two
// differ — and the difference is the whole reason reading is free: a read works
// out the answer and stores nothing.
//
// A caller wanting to know whether the slot has actually been given back, or
// whether there is anything left for Settle to do, wants this one.
func (g *Governor) StoredState(id int64) string { return stateName(g.mustProposal(id).state) }

// Reason is why a proposal ended, or the empty string while it is still open.
// The page prints it; this is the same string.
func (g *Governor) Reason(id int64) string { return g.mustProposal(id).reason }

// EpochOf is the sealed epoch a proposal's weight was read at. Fixed when the
// question was asked, and the reason buying in afterwards buys nothing.
func (g *Governor) EpochOf(id int64) uint32 { return g.mustProposal(id).epoch }

// Snapshot is a proposal's engaged weight and the sealed epoch both it and the
// votes were read at — snapshotted at Propose and reachable no other way (EpochOf
// gives the epoch alone). Engaged is the turnout DENOMINATOR the pool is shown
// against; for a proposal opened with an absolute quorum floor the bar is that
// floor, not a fraction of engaged — read it with QuorumFloor. Scalars, so nothing
// is handed out to write through.
func (g *Governor) Snapshot(id int64) (engaged int64, epoch uint32) {
	p := g.mustProposal(id)
	return p.engaged, p.epoch
}

// QuorumFloor is the absolute turnout a proposal needs when it was opened with
// ProposeWithQuorum, or 0 when the quorum is the rules' QuorumBps fraction of the
// engaged weight. A court renders a floored proposal's bar from this; the engine
// already uses it in the tally and on its own page. Snapshotted at Propose, so it
// is the bar the voters actually face.
func (g *Governor) QuorumFloor(id int64) int64 { return g.mustProposal(id).quorumFloor }

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

// Sweep reclaims the slots of proposals that have finished but were never
// written down.
//
// Propose already calls it when the board is full, which is the path that
// matters. This is the same thing on request, for a caller who would rather
// free a slot than be refused one — permissionless, like Settle, and for the
// same reason: it decides nothing, it only writes down what the rules already
// decided.
func (g *Governor) Sweep() { g.sweep() }

// SetElectorate changes where voting weight comes from, keeping everything
// else — the adopted kinds, every proposal, the slot cursor.
//
// The consuming realm's, like Adopt, and for a narrow purpose: a realm that
// wraps its ledger to drop idle weight out of the quorum denominator swaps the
// wrapper in here rather than rebuilding the governor and losing its registry.
//
// Only sensible before anything is open. A proposal snapshots the epoch it is
// weighed at but reads the electorate live, so changing it under an open vote
// moves the bar the voters were shown — which is the thing per-proposal rules
// exist to prevent, arrived at from the other side.
func (g *Governor) SetElectorate(e Electorate) {
	if e == nil {
		panic("governor: an electorate is required")
	}
	g.voters = e
}

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

// Render is the front page, or one proposal's page when path names an id.
//
// notes are extra lines the consuming realm puts under the token and above the
// governance — who may mint, most of all, which is the realm's fact rather than
// the engine's and cannot be inferred from silence.
//
// Passed in rather than stored. A stored note is a WRITE, and this is a read: a
// realm calling SetNotes from its own Render turned reading a page into
// something that costs storage, which is the defect check-storage exists to
// catch and did.
func (g *Governor) Render(path, notes string) string { return g.render(path, notes) }
