package governor

import (
	"chain"
	"crypto/sha256"
	"strconv"
	"strings"

	bptree "gno.land/p/nt/bptree/v0"
	ufmt "gno.land/p/nt/ufmt/v0"
)

// A proposal is a KIND and a PAYLOAD, both strings.
//
// Forced, and better than the alternative. MsgCall.Args is []string
// (gno.land/pkg/sdk/vm/msgs.go) and convertArgToGno switches on
// gno.BaseOf(argT), so scalars and named scalars like `address` convert; a
// struct, interface, pointer or func panics with "unexpected type in contract
// arg". An entrypoint taking one is uncallable by transaction.
//
// A []byte converts too, base64-decoded, so the string is a choice: a payload
// arrives as text a voter can read, where bytes would arrive as base64.
//
// A proposer cannot supply a closure either. A realm can persist one, but
// MsgRun forces the ephemeral package private and the save walk refuses it
// (realm.go, "cannot persist function or method from the private realm").
//
// The property that falls out is what OpenZeppelin cannot offer: Describe and
// Do consume the identical string, so what voters read IS what runs.
type Kind interface {
	// Name is the registry key.
	Name() string

	// Describe renders a payload for the people voting on it.
	//
	// It must be a total function of the payload ALONE. Read live state here
	// and two voters at different heights are deciding different questions
	// while looking at the same page.
	Describe(payload string) string

	// Check validates a payload against the world as it is now. Called when
	// the proposal opens AND again immediately before Do.
	//
	// The second call is the point. A proposal that was sound a week ago need
	// not be sound now, and the alternative is discovering that inside Do,
	// half-applied.
	Check(payload string) error

	// Do performs it. Non-crossing, taking the realm as data, so a /p/ package
	// could implement this unchanged — crossing functions are illegal outside
	// a realm.
	//
	// Returning an error and panicking are different decisions. An error
	// FINISHES the proposal: recorded failed, slot returned, no retry. Say so
	// when the answer will not change.
	//
	// A panic ABORTS the transaction, writing nothing — including the failure
	// — so the proposal stays Succeeded and anybody may try again. Say so when
	// a retry could work, or when half-finishing is worse than not starting:
	// an abort is the only rollback gno offers. govern:batch depends on it.
	Do(_ int, rlm realm, payload string) error
}

// Rules are per kind, never global. Renaming a parameter and spending the
// reserve should not need the same turnout, which is why one global quorum is
// always wrong for something.
//
// Basis points as int64, never float64: gno's own govdao compares against a
// float 66.66, and a threshold decided by binary floating point is a rounding
// argument waiting to happen. yes*bps >= (yes+no)*ThresholdBps is exact.
//
// bps is named once because it is load-bearing in three places at once: the
// tally, the rendered percentages and the supply ceiling. A scale written out
// separately in each is a number that can come to disagree with itself.
const bps = int64(10000)

// maxWeighable is the largest snapshot supply a tally can weigh without yes*bps
// overflowing int64 (and going negative, which reads a won vote as lost). The
// Electorate contract requires PastTotal to stay within it; grc20votes caps its
// own supply here exactly, so for that token this ceiling is never approached. It
// is checked at the Propose door for a swapped-in electorate that does not.
const maxWeighable = int64(9223372036854775807) / bps

type Rules struct {
	QuorumBps int64 // of the snapshot supply, counting abstain as turnout

	// ThresholdBps is the share of yes+no (abstain excluded) that yes must reach.
	// The comparison is INCLUSIVE — yes*bps >= (yes+no)*ThresholdBps — so at 5000
	// a 50-50 tie PASSES. A realm wanting a strict majority sets 5001 or more; the
	// bootstrap and gno's govdao use a 6600 supermajority.
	ThresholdBps int64

	// ProposeBps is what a proposer must hold, as a fraction of the snapshot
	// supply, to open a question at all.
	//
	// Attention control, not spam control: opening a proposal already costs a
	// new key's worth of deposit. The list is what holders read, and a list
	// nobody reads is a governor nobody governs. Zero means anyone may
	// propose — right for a small realm, wrong for a public token.
	ProposeBps   int64
	VotingBlocks int64
	DelayBlocks  int64 // succeeded -> executable; the timelock
	GraceBlocks  int64 // executable -> expired
}

const (
	stateActive int8 = iota
	stateDefeated
	stateSucceeded
	stateExecuted
	stateFailed
	stateCanceled
	stateExpired
)

// proposal is one question, frozen.
type proposal struct {
	id       int64
	kind     string
	payload  string
	title    string
	proposer address

	// Both copied when the proposal opens: the rules, so a later change cannot
	// move the bar earlier voters faced; the snapshot epoch, so the electorate
	// is the one that existed when the question was asked.
	rules Rules
	epoch uint32
	total int64 // supply at that epoch, so quorum has a fixed denominator

	// engaged is the quorum's DENOMINATOR; total is everything in issue. Equal
	// for this realm's token and not necessarily for another: an electorate may
	// drop idle weight out of the bar while that weight can still vote. So
	// quorum divides by engaged, and "what could still be cast" divides by
	// total.
	engaged int64

	// quorumFloor, when positive, is an ABSOLUTE turnout the proposal needs
	// instead of the rules' QuorumBps fraction of engaged — a figure the consumer
	// computed itself (a court's max(5% supply, min(1×X̄, ⅓ votable))) and passed
	// through ProposeWithQuorum. Snapshotted here like every other bar, so it
	// cannot move under an open vote. Zero means the bps formula applies, which is
	// every ordinary caller.
	quorumFloor int64

	opened int64
	closes int64
	ready  int64 // set when it succeeds
	state  int8
	reason string

	yes, no, abstain int64
	// voted exists only to refuse a second vote from the same address. Nothing
	// renders it and nothing else reads it.
	//
	// A tree per proposal rather than one shared tree keyed by (id, voter),
	// for cleanup rather than cost: this buys a whole node on the first vote
	// (~4,500 bytes) where a shared tree would cost one entry, but dropping it
	// is one assignment and the deposit goes back to whoever settles. Clearing
	// a range out of a shared tree is a removal per voter, unbounded, and
	// bptree forbids removing during iteration.
	//
	// Dropped the moment the proposal closes: Vote refuses a closed proposal
	// before it looks here, so the tree would be rent on something nobody can
	// consult. The roll survives in the Voted events.
	voted *bptree.BPTree
}

// entry is a kind and whether it may actually be proposed. Separate, because
// publishing code is something a realm does and letting that code hold this
// governor's authority is something the holders do. One registration call fuses
// them, and then whoever may register can grant themselves any power with no
// vote.
type entry struct {
	kind  Kind
	rules Rules
	live  bool
}

// maxLive bounds how many questions can be open at once. A security parameter,
// not a storage one: it is the only thing between a determined proposer and a
// list nobody can read.
//
// Cancel frees a slot outright. Time only makes one RECLAIMABLE — a read can
// work out that a proposal is over but cannot write it down — so the slot
// comes back when somebody calls Settle, or when sweep finds it on the next
// Propose. Reading this as "time frees a slot" is how the reclaim came to be
// something a proposer could hold shut; see the cursor sweep keeps.
//
// The open section of the front page has no length cap of its own, so its
// worst case is this many rows at maxTitle and maxKindName each: 14,220 bytes,
// which is a page. Ten thousand slots would be 2.2MB, which is not. A test
// holds the product against a ceiling, so raising either number fails it.
const maxLive = 64

// govLanes is how many of those slots only the governor's own kinds may take.
//
// Without it the sixty-four are a commons and any one kind may hold all of
// them. Sixty-four proposals of some cheap kind with a long voting window, and
// nothing else can be asked until that window runs out — including the
// govern:rules vote that would shorten the window. The realm stays up and stops
// being governable, which is the one failure it must not have, because every
// other kind of congestion is something the holders can vote their way out of.
//
// Priced rather than assumed: the bootstrap terms put ProposeBps at zero, so
// any holder may propose, and sixty-four proposals is about 56 GNOT of deposit
// — refundable, and held for one bootstrap voting window of a week.
//
// Eight rather than one. The governor has five kinds of its own and they are
// not alternatives: retuning a kind, adopting another, and retiring a third can
// all be live questions at once, and a lane of one would mean the first of them
// blocks the rest. Eight leaves room for a second round of each.
//
// This does NOT stop the governor's own kinds crowding each other out, and it
// is not meant to. A realm whose holders have filled the governance lane with
// governance is congested by its own doing and can wait; a realm shut out of
// governance by a kind it adopted for something else cannot.
const govLanes = 8

// maxOpen is what any other kind may fill, which is the number a proposer
// actually meets. maxLive stays the bound on the front page, since the lane is
// a reallocation of the sixty-four and not an addition to them.
const maxOpen = maxLive - govLanes

var (
	errNoSuchKind          = govErr("no kind by that name has been offered")
	errAlreadyLive         = govErr("that kind is already adopted")
	errNotLive             = govErr("that kind is not adopted")
	errCannotRetireBuiltin = govErr("the governor's own kinds cannot be retired")
)

// Governor is one governing body: which powers it has adopted, every question
// it has been asked, and where its slot reclaim had got to.
//
// Allocated by the consuming realm, which is what makes this a library rather
// than a realm. A /p/ package's own state is frozen after init, so nothing
// durable could live at package level; the trees below carry the consumer's
// storage stamp, and every method here borrows the consumer's authority back
// for the write.
//
// Every field is unexported and no method hands one out. /p/-declared types can
// be named by other /p/ packages, so an exported *proposal or a method
// returning one would let a stranger declare a mutator over it — and the
// storage-realm borrow would run that mutator under the CONSUMING realm's
// authority. See gno-security-guide.md §3(B) and §4.
type Governor struct {
	voters Electorate
	token  Token

	kinds     *bptree.BPTree // name -> *entry
	proposals *bptree.BPTree // enc(id) -> *proposal
	openIdx   *bptree.BPTree // digest -> enc(id), the live ones

	propSeq int64

	// executing is the re-entrancy latch: a kind calling back in while its own
	// Do runs would see a proposal mid-execution.
	executing bool

	// sweepFrom is where the next slot reclaim starts scanning, and it rotates.
	// The index is keyed by digest(kind, payload) and a proposer chooses their
	// payload, so they choose their key: park a few long-running proposals on
	// the lowest keys and a FIXED window never sees past them, freeing nothing
	// while the rest of the list is finished business. Beating the lowest of
	// fifty-six random keys is a few hundred hashes offline.
	sweepFrom string
}

// reserved names the governor's own kinds. Offer refuses this prefix, so no
// realm can publish something that renders as a built-in.
const reserved = "govern:"

// isReserved reports whether a name belongs to the governor itself.
//
// One predicate, two callers: Offer refusing to publish under the prefix, and
// govern:retire refusing to withdraw something carrying it. It was written
// twice, and a weakened retire copy would let the holders withdraw
// govern:adopt — after which no kind could ever be adopted again and no
// proposal could restore it.
func isReserved(name string) bool {
	return len(name) >= len(reserved) && name[:len(reserved)] == reserved
}

// NewRules builds the terms a kind would pass on. A realm cannot allocate
// another realm's struct — govern.Rules{...} written elsewhere is refused with
// "cannot allocate ... in realm" — so the value comes into existence here and
// the caller passes numbers. Without it, Offer was uncallable from outside this
// package.
func NewRules(quorumBps, thresholdBps, votingBlocks, delayBlocks, graceBlocks, proposeBps int64) Rules {
	return Rules{
		QuorumBps: quorumBps, ThresholdBps: thresholdBps,
		VotingBlocks: votingBlocks, DelayBlocks: delayBlocks,
		GraceBlocks: graceBlocks, ProposeBps: proposeBps,
	}
}

// Offer shelves a kind. It takes effect on nothing.
//
// Ungated, because an offered kind can do nothing. What it buys is a name
// pointing at published, immutable code the holders are later asked to approve.
//
// The two-step exists because MsgCall.Args is []string: an account cannot hand
// over a Kind, only a realm can construct one. If adopting required passing
// the value, only realms could grow the governor — and that decision has to
// belong to the holders. Offer is the realm's half; the vote is theirs.
func (g *Governor) Offer(who address, k Kind, r Rules) {
	name := k.Name()
	mustBeUsableName(name)
	if isReserved(name) {
		panic("govern: that prefix belongs to the governor")
	}
	g.mustBeSaneRules(r)

	// A name, once offered, is bound to that code forever.
	//
	// The alternative — allowing a re-offer while the kind is not yet adopted —
	// is a live attack, not an untidiness. Offer harmless code, wait for an
	// adoption proposal to open on it, then re-offer under the same name while
	// the vote runs. The holders read the first Describe, approve it, and Do
	// dispatches to the second. gno's own daokit has this shape and records it
	// as a TODO; here the vote would be a signature on a blank cheque.
	//
	// Pinning the value into the proposal would also close it, at the cost of
	// a Kind stored per proposal and a rule about which copy wins. Refusing
	// the rewrite is smaller and matches how the chain already behaves: a
	// realm cannot be redeployed at its path either. A realm with new code
	// publishes a new name — treasury/spend/v2 — which the holders then have
	// to adopt knowingly, which is the entire point.
	if g.entryOf(name) != nil {
		panic("govern: that name is taken; publish a new one rather than " +
			"rewriting what may already be under a vote")
	}
	g.kinds.Set(name, &entry{kind: k, rules: r})

	// The terms go out with it. A holder deciding whether to adopt this is
	// deciding on the code AND on the bar it would pass at, and the two are
	// bound together from here — Offer refuses to rewrite either.
	chain.Emit(kindOfferedEvent,
		"name", name,
		"offerer", who.String(),
		"quorumBps", strconv.FormatInt(r.QuorumBps, 10),
		"thresholdBps", strconv.FormatInt(r.ThresholdBps, 10),
		"votingBlocks", strconv.FormatInt(r.VotingBlocks, 10),
		"delayBlocks", strconv.FormatInt(r.DelayBlocks, 10),
		"graceBlocks", strconv.FormatInt(r.GraceBlocks, 10),
		"proposeBps", strconv.FormatInt(r.ProposeBps, 10),
	)
}

// maxTitle bounds the headline, which goes on the shared page. Every open
// proposal's title is concatenated into Render(""), and the only cap there is
// on the decided tail — so the page every holder reads is as long as the open
// titles put together. Anything needing more room is what the payload is for.
const maxTitle = 120

// maxPayload bounds the argument. Looser than the title on purpose: this is
// what the proposal actually says, a batch carries up to maxBatch members in
// one, and the cost falls on the proposer — Render lists titles, so nobody
// loads a payload without asking for that proposal by number.
const maxPayload = 4096

// maxKindName bounds a name. Offer is ungated, so it is chosen by whoever
// turns up, and everything that renders a proposal renders it.
const maxKindName = 64

// mustBeUsableName refuses a name that cannot be used everywhere a name is
// used.
//
// A kind's name is not only a registry key. It is the first field of a batch
// member line, and parseBatch ends that field at the first SPACE; it goes into
// the digest that decides whether two proposals are the same question; and it
// is rendered on a page somebody has to read before voting. A name that works
// in one of those and not the others is a kind that is quietly unusable.
//
// A space is the one that looks harmless and is not. "my kind" offers and
// proposes perfectly well, and then a batch reads everything after the space
// as the payload — so the member resolves to a kind called "my", the batch is
// refused with "no kind called my", and nothing points at the name.
//
// Printable ASCII, no space. That is what every kind here already uses — fee,
// treasury/spend, govern:adopt — and it is the largest set that works in all
// three places at once.
func mustBeUsableName(name string) {
	if name == "" {
		panic("govern: a kind needs a name")
	}
	if len(name) > maxKindName {
		panic("govern: that name is too long")
	}
	for i := 0; i < len(name); i++ {
		if c := name[i]; c <= ' ' || c > '~' {
			panic("govern: a kind name must be printable ASCII with no spaces")
		}
	}
}

// mustBeUsableTitle bounds the one piece of free prose an ungated caller puts
// on a page everybody reads.
//
// A title goes onto the front page inside a markdown list item, so a newline
// ends that item and starts a row of the proposer's own — a forged proposal
// with a state and a link they choose:
//
//   - [#1](:1) **x
//   - [#999](:999) **Ratified by the foundation** — `govern:minter` · succeeded
//
// The bootstrap kinds ask for no stake, so that cost nothing but a transaction.
//
// Control characters, not printable-ASCII: a title is prose and keeps spaces
// and any language. Markdown within a line is left alone — it cannot leave the
// row it belongs to, and structure is the part a reader cannot check.
func mustBeUsableTitle(title string) {
	if len(title) > maxTitle {
		panic("govern: that title is too long")
	}
	if err := TextOnly(title); err != nil {
		panic("govern: a title " + err.Error())
	}
}

// TextOnly reports whether a string is text rather than page structure.
//
// Exported because it is a kind author's problem. A payload comes from whoever
// proposes — any address at all when ProposeBps is zero — and Describe renders
// it onto a page others vote from, so a raw payload hands page structure to a
// stranger. The built-ins are safe by accident: their payloads are kind names
// and addresses, which cannot hold a newline. It bites the first kind that
// takes free text.
//
//	func (k mykind) Check(payload string) error {
//		if len(payload) > 280 {
//			return errTooLong
//		}
//		return govern.TextOnly(payload)
//	}
//
// Control characters, not printable-ASCII, so prose in any language survives —
// every byte of a multi-byte character is >= 0x80. Markdown within a line is
// allowed: it cannot leave the row it belongs to.
//
// The governor cannot apply this to payloads itself; govern:batch is defined
// in terms of newlines. Only a kind knows its own grammar.
func TextOnly(s string) error {
	for i := 0; i < len(s); i++ {
		if c := s[i]; c < 0x20 || c == 0x7f {
			return errNotTextOnly
		}
	}
	return nil
}

var errNotTextOnly = govErr("cannot contain control characters")

// saneRules is the one definition of terms this realm will accept — one
// function, two callers, after two copies drifted apart.
//
// Both copies missed ProposeBps. Above a hundred percent it asks a proposer to
// hold more than everything, so nobody can open a question under that kind:
// adopted and unusable. And govern:rules accepted only five of the six terms,
// so the one field where a bad value bricks a kind was the one nobody could
// retune. It takes all six now.
func saneRules(r Rules) error {
	if r.QuorumBps < 0 || r.QuorumBps > bps || r.ThresholdBps < 0 || r.ThresholdBps > bps {
		return govErr("basis points out of range")
	}
	if r.ProposeBps < 0 || r.ProposeBps > bps {
		// Exactly bps is allowed: "only somebody holding the entire supply may
		// propose this" is a coherent, if severe, thing to want.
		return govErr("a proposer cannot be asked to hold more than the whole supply")
	}
	if r.VotingBlocks <= 0 {
		return govErr("a vote needs a period")
	}
	if r.GraceBlocks <= 0 {
		// A decision has to be able to expire, because never expiring leaks a
		// slot.
		//
		// A Succeeded proposal keeps its place in the open index until it is
		// executed, because until then a duplicate would be a second live copy
		// of the same question. With no grace period there is nothing that ever
		// ends it: Cancel refuses a decided proposal, Settle and sweep find
		// nothing to change, and the slot is held for the life of the realm.
		// Sixty-four like that and nobody can open a proposal again.
		//
		// Refusing zero is what makes "every proposal eventually gives its slot
		// back" true by construction, and it agrees with what this realm
		// already says about grace: a decision nobody executed is a decision
		// about a world that has moved.
		return govErr("a decision has to expire; a grace period of zero holds " +
			"its slot for the life of the realm")
	}
	if r.DelayBlocks < 0 {
		// GraceBlocks < 0 needs no test here: the GraceBlocks <= 0 return above
		// already refuses it. Negative behaves as zero everywhere it is used, so
		// this refuses a value that means nothing rather than one that does harm —
		// and stops it being stored and rendered as a term somebody agreed to.
		return govErr("a period cannot be negative")
	}
	return nil
}

func (g *Governor) mustBeSaneRules(r Rules) {
	if err := saneRules(r); err != nil {
		panic("govern: " + err.Error())
	}
}

// init makes the governor able to govern itself, and nothing else. These are
// live from the first block because adopting a kind is itself a kind, so there
// is nothing to bootstrap them with. Everything beyond must be offered and
// adopted, so not even the deployer can add a power without a vote.

// BootstrapRules are the terms the governor governs ITSELF on.
//
// Exported because a consuming realm registering a power of its own —
// the mint, most of all — should govern it on the same terms rather than
// inventing a second set that can drift from these.
func BootstrapRules() Rules {
	return Rules{
		// A fifth of the supply has to turn out. Low enough to reach with
		// dispersed holders, high enough that a handful cannot decide alone
		// while everybody else is asleep.
		QuorumBps: 2000,

		// Two thirds of what was cast, not half. A simple majority is the
		// wrong bar for changing the rules of the game — these kinds decide
		// who may mint and what powers exist — and 6600 is exact where gno's
		// own govdao carries 66.66 as a float64 and compares with >=.
		ThresholdBps: 6600,

		// A week to vote, so holders in any timezone get a turn. It is a
		// DEADLINE and not a duration: a vote nothing further could change
		// closes on the arithmetic, so an agreed decision does not wait it out.
		VotingBlocks: 7 * 24 * 60 * 60 / 5,

		// Two days between deciding and doing, which is what a timelock is
		// for: time for somebody who dislikes the outcome to sell, leave, or
		// argue before it takes effect.
		DelayBlocks: 2 * 24 * 60 * 60 / 5,

		// A fortnight to execute, and then the decision expires. A proposal
		// nobody executed for two weeks is a decision about a world that has
		// moved, and gno's own govdao had to bolt on a reject path precisely
		// because proposals could otherwise sit forever.
		GraceBlocks: 14 * 24 * 60 * 60 / 5,
	}
}

// installBuiltins registers the kinds the governor governs itself with.
func (g *Governor) installBuiltins() {
	// The terms the governor governs ITSELF on. See BootstrapRules.
	bootstrap := BootstrapRules()
	g.kinds.Set(adoptKind{}.Name(), &entry{kind: adoptKind{}, rules: bootstrap, live: true})
	g.kinds.Set(retireKind{}.Name(), &entry{kind: retireKind{}, rules: bootstrap, live: true})
	g.kinds.Set(rulesKind{}.Name(), &entry{kind: rulesKind{}, rules: bootstrap, live: true})
	g.kinds.Set(batchKind{}.Name(), &entry{kind: batchKind{}, rules: bootstrap, live: true})
}

// adoptKind turns an offered kind live. Its payload is only a name, so what
// the holders read is exactly what they are approving.
type adoptKind struct{}

func (k adoptKind) Name() string { return reserved + "adopt" }

func (k adoptKind) describe(g *Governor, payload string) string {
	out := "adopt the kind `" + payload + "`, letting it be proposed and executed"
	e := g.entryOf(payload)
	if e == nil {
		return out + "\n\n_Nothing has been offered under that name._"
	}
	// The terms, not just the name: a holder approving a power needs to see how
	// easily it can be used. A hostile realm offers a spending kind with a
	// hundredth of a percent quorum and a one-block vote, and the adoption
	// reads exactly like an honest one.
	//
	// Still a total function of the payload — an offered name is bound to its
	// code permanently, and govern:rules refuses to retune an unadopted kind,
	// so none of this can move between proposing and executing.
	out += ufmt.Sprintf("\n\nIt would pass on:"+
		"\n- quorum: %s of the supply"+
		"\n- threshold: %s of votes cast"+
		"\n- time to vote: %s"+
		"\n- delay before it can run: %s"+
		"\n- expires after: %s",
		pct(e.rules.QuorumBps), pct(e.rules.ThresholdBps),
		span(e.rules.VotingBlocks), span(e.rules.DelayBlocks), span(e.rules.GraceBlocks))
	// Always rendered, including when it is zero — which is when it matters
	// most. Zero means Propose skips the stake check, so any address may open
	// a proposal holding nothing, and omitting the line read as "not
	// applicable" rather than "anybody". A permissive default is the term a
	// page most needs to say out loud.
	out += "\n- who may propose: " + proposerBar(e.rules.ProposeBps)
	return out
}

func (k adoptKind) check(g *Governor, payload string) error {
	e := g.entryOf(payload)
	if e == nil {
		return errNoSuchKind
	}
	if e.live {
		return errAlreadyLive
	}
	return nil
}

func (k adoptKind) run(g *Governor, dispatch Dispatch, payload string) error {
	e := g.entryOf(payload)
	if e == nil {
		return errNoSuchKind
	}
	e.live = true
	return nil
}

// retireKind withdraws one. Offered-but-not-live is the resting state, so a
// retired kind can be adopted again without the realm re-offering it.
type retireKind struct{}

func (k retireKind) Name() string { return reserved + "retire" }

func (k retireKind) describe(g *Governor, payload string) string {
	return "retire the kind `" + payload + "`, so it can no longer be proposed" +
		"\n\nThis also kills any proposal of that kind that has already been " +
		"decided and not yet run: Execute refuses a kind that is no longer " +
		"adopted, and records the proposal as failed. Retiring is not only " +
		"about the future."
}

func (k retireKind) check(g *Governor, payload string) error {
	e := g.entryOf(payload)
	if e == nil {
		return errNoSuchKind
	}
	if !e.live {
		return errNotLive
	}
	if isReserved(payload) {
		return errCannotRetireBuiltin
	}
	return nil
}

func (k retireKind) run(g *Governor, dispatch Dispatch, payload string) error {
	e := g.entryOf(payload)
	if e == nil {
		return errNoSuchKind
	}
	e.live = false
	return nil
}

// Propose opens a question. One maketx call, two strings — which is the whole
// design and the reason the payload is not a struct.
//
// The quorum is the rules' QuorumBps fraction of the engaged weight. A consumer
// that computes its own absolute bar — a court sizing quorum to a claim's open
// interest — uses ProposeWithQuorum instead.
func (g *Governor) Propose(who address, kind, payload, title string) int64 {
	return g.propose(who, kind, payload, title, 0)
}

// ProposeWithQuorum is Propose with an ABSOLUTE turnout the question needs,
// replacing the rules' QuorumBps fraction for this one proposal. The figure is
// the consumer's to compute (a court's max(5% supply, min(1×X̄, ⅓ votable))) and
// is snapshotted here, so the bar cannot move under an open vote. A non-positive
// floor is refused — a caller wanting the bps formula calls Propose.
//
// Additive: Propose is unchanged and passes zero, which every existing user does.
func (g *Governor) ProposeWithQuorum(who address, kind, payload, title string, quorumFloor int64) int64 {
	if quorumFloor <= 0 {
		panic("govern: a quorum floor has to be positive; use Propose for the bps bar")
	}
	return g.propose(who, kind, payload, title, quorumFloor)
}

func (g *Governor) propose(who address, kind, payload, title string, quorumFloor int64) int64 {
	if g.executing {
		panic("govern: cannot propose from inside an execution")
	}
	// Checked before anything else is done with them: these are the two
	// strings an ungated caller supplies, and they are persisted for the life
	// of the realm.
	mustBeUsableTitle(title)
	if len(payload) > maxPayload {
		panic("govern: that payload is too long")
	}
	k := g.kindOf(kind)
	if err := g.checkKind(k, payload); err != nil {
		panic("govern: " + err.Error())
	}

	// The electorate is the checkpointed supply at the last sealed epoch. Not a
	// hand-kept roll: the token already remembers who held what, and asking it is
	// what makes the weight historical.
	//
	// THIS ALONE DOES NOT MAKE WEIGHT UNRENTABLE, and an earlier version of this
	// comment claimed it did. The anchor is derived HERE, at propose time, by
	// whoever proposes — so a renter buys float, waits ONE epoch for the
	// checkpoint to seal, proposes (pinning the anchor to a window in which they
	// hold), sells, and votes with weight they no longer own. Measured end to end:
	// 300 B of pinned weight cast at 600x a quorum floor with a live balance of
	// zero and one epoch of capital at risk. What this line buys on its own is
	// only that weight cannot be acquired AFTER the question exists. The rental is
	// unpriced; RENTEDWEIGHT.md records the measurement and the open decision.
	at := g.voters.Epoch() - 1
	if at == 0 {
		panic("govern: no sealed epoch yet — the chain is too young to vote")
	}
	total := g.voters.PastTotal(at)
	if total <= 0 {
		panic("govern: nothing was in issue at that epoch")
	}
	if total > maxWeighable {
		// The ceiling the tally silently assumed. grc20votes caps here so it never
		// trips; a swapped-in electorate that does not would overflow yes*bps into
		// a negative tally — a won vote reported as lost. Refused at the door,
		// where it reads as a misconfigured electorate rather than the governor
		// miscounting.
		panic("govern: the snapshot supply exceeds what a tally can weigh")
	}
	// Snapshotted with the rest, so a bar cannot move under an open vote.
	engaged := g.voters.EngagedTotal(at)
	if engaged <= 0 {
		// An electorate that engages nobody makes every quorum TRIVIAL, which is
		// the opposite of what this comment said for a long time and the reason
		// the guard is load-bearing rather than tidy. The bar is
		// `cast*bps >= engaged*QuorumBps`; at engaged == 0 the right-hand side is
		// zero and the comparison holds for any turnout, including none — so
		// quorum stops existing, and at the deadline one yes vote carries the
		// question however few showed up.
		//
		// Reachable with an honest electorate rather than a broken one:
		// EngagedTotal is there so a realm can drop idle weight out of the
		// denominator, and one where all weight is idle returns zero truthfully.
		panic("govern: the engaged weight has to be positive")
	}
	if engaged > total {
		// Clamp rather than refuse. A court deliberately hosts claims too big for
		// its electorate to decide, and an EngagedTotal above the snapshot supply
		// should make the bar unreachable-but-valid, not abort the proposal.
		// Clamping to total keeps rest = total - cast non-negative in the tally.
		// The token this ships with returns engaged == total, so this never fires
		// for it — it is here for a replacement electorate.
		engaged = total
	}

	rules := g.rulesOf(kind)
	if rules.ProposeBps > 0 {
		// The numbers, not just the verdict. The realm knows the bar and what
		// the caller held; withholding both leaves somebody to work out from
		// the terms page what they are short of, and the epoch matters most of
		// all — a holder refused here may well hold plenty NOW and nothing at
		// the sealed epoch this is weighed at, which reads as a bug rather than
		// as the anti-flash-loan rule doing its job.
		if held := g.voters.PastVotes(who, at); held*bps < total*rules.ProposeBps {
			panic(ufmt.Sprintf("govern: not enough voting power to open this: "+
				"%s of the supply is required, and you held %d of %d at epoch %d",
				pct(rules.ProposeBps), held, total, at))
		}
	}
	// Everything may fill the board except the last few slots, which the
	// governor's own kinds keep — see govLanes.
	limit := maxLive
	if !isReserved(kind) {
		limit = maxOpen
	}
	if g.openIdx.Size() >= limit {
		// Try to reclaim before refusing: a full list is usually full of
		// finished business nobody has written down.
		g.sweep()
	}
	if g.openIdx.Size() >= limit {
		if limit < maxLive {
			panic("govern: too many proposals are already open; the last " +
				"few slots are kept for the governor's own kinds")
		}
		panic("govern: too many proposals are already open")
	}
	d := g.digest(kind, payload)
	if v := g.openIdx.Get(d); v != nil {
		// Settle the one already standing here before refusing on its account.
		//
		// The index holds finished proposals too — a read can work out that a
		// proposal lost but cannot write it down, and the sweep above only
		// runs when the list is FULL. So without this, a question defeated on
		// its deadline and left unrecorded blocks the same question from being
		// asked again, and the refusal says "already open" about something
		// that closed.
		//
		// Targeted rather than a scan: the one proposal actually in the way,
		// on the rare path where a digest collides at all.
		if pv := g.proposals.Get(v.(string)); pv != nil {
			g.settle(pv.(*proposal))
		}
	}
	if g.openIdx.Has(d) {
		panic("govern: an identical proposal is already open")
	}
	now := g.voters.Height()
	g.propSeq++
	p := &proposal{
		id: g.propSeq, kind: kind, payload: payload, title: title, proposer: who,
		rules: rules, epoch: at, total: total, engaged: engaged,
		quorumFloor: quorumFloor,
		opened:      now, closes: now + rules.VotingBlocks,
		// The voter roll is bought here, by the proposer, including its first
		// node — see rollSentinel just below the Set. Whoever asks, pays.
		//
		// The alternative is to let the first voter buy it, on the argument
		// that a proposal nobody answers should cost nothing to leave
		// unanswered. That saving only ever accrues to a proposal that failed,
		// and it charges the first voter eleven times what the second pays.
		// Being early is the wrong thing to tax.
		//
		// Fanout 32 on purpose. A narrower tree makes that first node cheaper
		// (2,699 bytes at fanout 8 against 4,955) until the ninth voter, where
		// the tree splits and that vote costs 5,476 — thirteen times what the
		// eighth paid, for arriving in the wrong order. See
		// docs/DESIGN.md.
		state: stateActive, voted: bptree.NewBPTree32(),
	}
	p.voted.Set(rollSentinel, ballot(0))
	g.proposals.Set(enc(uint64(g.propSeq)), p)
	g.openIdx.Set(d, enc(uint64(g.propSeq)))

	chain.Emit(proposalOpenedEvent,
		"id", strconv.FormatInt(g.propSeq, 10),
		"kind", kind,
		"proposer", who.String(),
		"epoch", strconv.FormatUint(uint64(at), 10),
	)
	return g.propSeq
}

// Vote records a choice, weighed at the proposal's snapshot.
func (g *Governor) Vote(who address, id int64, choice string) {
	g.castVote(who, id, choice, "")
}

// VoteWithReason is Vote with a note the voter wants on the record — the same
// pair OpenZeppelin has. Two entrypoints rather than one optional argument
// because MsgCall carries a fixed list of strings and gno has no optional
// parameters.
//
// The reason is emitted and never stored: it rides the Voted event, so the
// voter pays gas for the bytes and the ledger carries none of them. Storing it
// would be a new key per vote, on the path this design keeps cheapest.
//
// Bounded by maxReason. Not filtered through TextOnly, unlike a title: the
// realm never renders this on a page, so a consumer that displays it is
// responsible for its own escaping, as with any event field.
func (g *Governor) VoteWithReason(who address, id int64, choice, reason string) {
	if len(reason) > maxReason {
		panic("govern: that reason is too long")
	}
	g.castVote(who, id, choice, reason)
}

func (g *Governor) castVote(who address, id int64, choice, reason string) {
	if g.executing {
		panic("govern: cannot vote from inside an execution")
	}
	p := g.mustProposal(id)
	g.settle(p)
	if p.state != stateActive {
		panic("govern: that proposal is closed")
	}
	if p.voted.Has(string(who)) {
		panic("govern: already voted")
	}
	// Weighed as of the snapshot AND CAPPED AT WHAT IS STILL HELD. Buying in
	// after the question was asked buys nothing (the snapshot caps it); selling
	// out afterwards now costs exactly what was sold (the live balance caps it).
	//
	// THE SECOND HALF IS NEW, AND IT IS A FIX FOR A MEASURED HOLE, not a
	// tightening for its own sake. The snapshot alone was documented in propose()
	// as making weight "impossible to rent". It did not: the anchor is
	// `g.voters.Epoch() - 1` AT PROPOSE TIME, and the proposer is whoever asks —
	// so an attacker acquires float, waits ONE epoch for the checkpoint to seal,
	// opens the proposal themselves (pinning the anchor to a window in which they
	// hold), SELLS EVERYTHING BACK, and then votes with the full weight they no
	// longer own. Measured end to end on a court coin: 300 B of pinned weight
	// voted at 600x the quorum floor with a live balance of zero and one epoch of
	// capital at risk.
	//
	// The old comment's "selling out afterwards costs nothing" was true and is
	// the standard snapshot-governance tradeoff — but it is only safe when the
	// anchor PRECEDES the acquisition. Here the actor chooses the anchor, which
	// is what turns an accepted property into a rental market.
	//
	// min() rather than live-only: live-only weighting is what snapshot voting
	// exists to prevent, since it lets weight borrowed inside the voting window
	// decide the vote. Capping keeps both guarantees — you must have held it THEN
	// and hold it NOW — and it strictly narrows what any voter can do.
	//
	// CONSISTENT WITH EXISTING DOCTRINE, not a new rule: coin sitting in an
	// escrow does not vote (that is precisely what votableAt nets out), so a
	// voter who has since committed coin as a bond or deposit losing that much
	// weight is the same rule everyone else is already under.
	// Weighed as of the snapshot, so buying in after the question was asked buys
	// nothing, and selling out afterwards costs nothing.
	//
	// THE SECOND HALF IS A KNOWN, MEASURED EXPOSURE, not an oversight, and it is
	// NOT closed here. See propose() for the mechanism and RENTEDWEIGHT.md for the
	// two candidate fixes and why neither shipped: capping at the voter's live
	// weight charges whoever PAYS to initiate a proceeding (measured, it pushed a
	// holder of exactly the election floor under it by the fee they paid to
	// nominate), and requiring the weight to have existed a week earlier
	// disenfranchises every recent acquirer (measured, it refused an ordinary vote
	// in this realm's own tests). Both were implemented and reverted.
	w := g.voters.PastVotes(who, p.epoch)
	if w <= 0 {
		panic("govern: no voting power at that epoch")
	}
	switch choice {
	case "yes":
		p.yes += w
	case "no":
		p.no += w
	case "abstain":
		// Turnout, not indifference. Showing up to decline is a different
		// statement from silence, and it counts towards quorum while staying
		// out of the threshold.
		p.abstain += w
	default:
		panic("govern: choice must be yes, no or abstain")
	}
	// For a long time nothing read this — only Has() was ever asked of the
	// tree — and it was kept anyway, on the measurement that swapping the whole
	// value for a bool saves ONE byte per vote, because what a vote costs is
	// the address key and the tree's own entry overhead rather than the value
	// hanging off it. VoteOf reads it now, which is what the byte was for.
	p.voted.Set(string(who), packBallot(choice, w))
	g.settle(p)

	// The reason rides along only when there is one. An empty attribute on
	// every vote would cost every voter gas to say nothing, and would leave an
	// indexer unable to tell a voter who declined to explain from one whose
	// client cannot ask.
	if reason == "" {
		chain.Emit(votedEvent,
			"id", strconv.FormatInt(id, 10),
			"voter", who.String(),
			"choice", choice,
			"weight", strconv.FormatInt(w, 10),
		)
		return
	}
	chain.Emit(votedEvent,
		"id", strconv.FormatInt(id, 10),
		"voter", who.String(),
		"choice", choice,
		"weight", strconv.FormatInt(w, 10),
		"reason", reason,
	)
}

// ballot is one vote as cast. The weight is what the tally used; the choice is
// here so a kind can pay the side that voted with it, which is the whole reason
// VoteOf exists — a scheme that pays only the winners gives a juror expecting to
// lose no reason to turn up, which suppresses the honest side during exactly
// the manipulation a vote is meant to stop.
// A ballot is one int64, not a struct.
//
// The tree hands out each value as its own object for lazy loading, and a
// struct there is a SECOND object per vote — measured at 846 bytes a vote
// against 454 for a scalar. A vote is the one thing in this realm that happens
// thousands of times, so 405 bytes of object header is the wrong place to spend
// on tidiness.
//
// weight*4 + the choice. Two bits for three choices, and the weight is bounded
// by maxSupply, which is MaxInt64/10000 — so the shift cannot overflow with
// four orders of magnitude to spare.
type ballot int64

const (
	ballotYes int64 = iota
	ballotNo
	ballotAbstain
)

func packBallot(choice string, weight int64) ballot {
	switch choice {
	case "yes":
		return ballot(weight<<2 | ballotYes)
	case "no":
		return ballot(weight<<2 | ballotNo)
	case "abstain":
		return ballot(weight<<2 | ballotAbstain)
	}
	// Unreachable: castVote refuses anything else before it gets here. Panics
	// rather than defaulting, because a silent default would file a vote under
	// a choice nobody made.
	panic("govern: not a choice: " + choice)
}

func (b ballot) unpack() (choice string, weight int64) {
	switch int64(b) & 3 {
	case ballotYes:
		choice = "yes"
	case ballotNo:
		choice = "no"
	default:
		choice = "abstain"
	}
	return choice, int64(b) >> 2
}

// rollSentinel is the key Propose writes into a new voter roll, so that the
// roll's first node is bought by the person asking the question rather than by
// whoever happens to answer it first.
//
// A bptree allocates nothing until its first key, and its leaf carries
// fanout-sized backing arrays, so that first key costs about eleven times an
// ordinary insert. Left to the first voter, that is a tax on being early —
// which is the worst moment to put one, since a proposal with no votes yet is
// the one that needs the first.
//
// The empty string, because it is the one key no address can be: an address is
// bech32 and bech32 is never empty. Readers taking an address from outside are
// still told to refuse it, since "" arrives as a valid Go string from anybody
// who wants to ask.
const rollSentinel = ""

// VoteOf is how an address voted, for a kind that has to pay them.
//
// One address at a time, on purpose. A list of every voter is an unbounded
// return, and handing back the tree itself would be a live mutator holding this
// realm's authority — so payouts are pull-based: each claimant asks about
// themselves.
//
// Answers only while the roll survives. It is dropped by ReleaseRoll, so a kind
// that pays out should either do it inside Do, where the roll is certainly
// intact, or tell its claimants that the window closes when somebody reclaims
// the deposit.
func (g *Governor) VoteOf(id int64, who address) (choice string, weight int64, ok bool) {
	p := g.mustProposal(id)
	if p.voted == nil || who == rollSentinel {
		return "", 0, false
	}
	v := p.voted.Get(string(who))
	if v == nil {
		return "", 0, false
	}
	choice, weight = v.(ballot).unpack()
	return choice, weight, true
}

// wouldBe is what the rules and the clock say a proposal's state is, without
// writing anything down.
//
// Split out from settle because reads must not mutate. Render walks every
// proposal, and a settle-on-read there is an unbounded write hiding inside a
// function that looks like a query — discarded harmlessly when it IS a query,
// and a surprise when some realm calls Render inside a transaction.
//
// Every multiplication here is safe because the supply is capped at maxSupply.
// yes, no and abstain are each bounded by the snapshot total, and total*bps
// fits in int64 by construction.
func (g *Governor) wouldBe(p *proposal, now int64) (int8, string) {
	switch p.state {
	case stateActive:
		cast := turnout(p)
		// The bar: an absolute floor the consumer set for this proposal, or the
		// rules' QuorumBps fraction of the engaged weight when it did not.
		var quorum bool
		if p.quorumFloor > 0 {
			quorum = cast >= p.quorumFloor
		} else {
			quorum = cast*bps >= p.engaged*p.rules.QuorumBps
		}
		// Every vote not yet cast, all of which could still say no. Negative if
		// an electorate's parts exceed its whole, which this token cannot do
		// and a replacement might; a clamp here changed no outcome, because a
		// broken roll settles on the first vote either way. The contract is on
		// the electorate instead, where somebody swapping one will read it.
		rest := p.total - cast
		// p.yes > 0 is not redundant, and leaving it out was a real hole.
		//
		// The threshold compares yes against yes+no. When everybody ABSTAINS
		// both are zero, the comparison is 0 >= 0, and the proposal passed —
		// immediately, with nobody in favour, on the strength of an empty
		// denominator. Abstain is documented as turnout without support and it
		// was carrying proposals.
		//
		// Nothing passes without somebody voting for it, whatever the
		// threshold is set to.
		if quorum && p.yes > 0 && p.yes*bps >= (p.yes+p.no+rest)*p.rules.ThresholdBps {
			// Decided even if every remaining vote goes against. Waiting out
			// the clock on a settled question is latency, not deliberation —
			// and it is only computable because the denominator was
			// snapshotted, which is a third reason to snapshot.
			return stateSucceeded, ""
		}
		// And the same argument the other way, which was missing.
		//
		// If the threshold cannot be reached even with every remaining vote in
		// favour, the question is as settled as one that has already won — and
		// this side is the more common one, because a proposal that is going
		// to lose usually loses by everybody ignoring it.
		//
		// It was asymmetric for no reason anybody could have defended: a
		// decided YES closed at once while a decided NO sat out its deadline,
		// holding a slot in a list bounded at maxLive, asking a question that
		// had already been answered.
		if p.yes+rest == 0 {
			// Nobody in favour and nobody left who could be. Settled, whatever
			// the clock says — this is the all-abstained case, which now loses
			// at once instead of sitting out its deadline having already
			// failed.
			return stateDefeated, "nobody voted in favour"
		}
		if (p.yes+rest)*bps < (p.yes+rest+p.no)*p.rules.ThresholdBps {
			return stateDefeated, "threshold can no longer be reached"
		}
		if now >= p.closes {
			if quorum && p.yes > 0 && p.yes*bps >= forAndAgainst(p)*p.rules.ThresholdBps {
				return stateSucceeded, ""
			}
			if !quorum {
				return stateDefeated, "quorum not reached"
			}
			return stateDefeated, "threshold not reached"
		}
		return stateActive, p.reason

	case stateSucceeded:
		if at, expires := expiresAt(p); expires && now > at {
			// A proposal nobody executed for a long time is a decision about a
			// world that has moved. gno's own govdao has no deadline at all
			// and had to bolt on a reject path because proposals could sit
			// forever.
			return stateExpired, "not executed within the grace period"
		}
	}
	return p.state, p.reason
}

// settle writes down what wouldBe worked out. Only ever called from a
// transaction, because only a transaction can record anything.
func (g *Governor) settle(p *proposal) {
	now := g.voters.Height()
	next, reason := g.wouldBe(p, now)
	if next == p.state {
		return
	}
	g.setState(p, next, reason)
	if next == stateSucceeded {
		// The delay runs from when the outcome is WRITTEN DOWN, not from when
		// the votes stopped mattering. Those differ for a proposal that wins on
		// its deadline: nobody has to be present when a deadline passes, so the
		// outcome is only recorded by the next transaction.
		//
		// Right way round — a timelock exists so people can react, and there is
		// nothing to react to until the decision is announced. Settle is
		// permissionless so announcing is never a privileged position.
		p.ready = now + p.rules.DelayBlocks
		return
	}
}

// Execute runs a passed proposal. Permissionless on purpose: after the vote
// and the delay there is nothing left to decide, so there is nobody left to
// trust with the decision.
// Dispatch runs an adopted kind. The consuming realm supplies it, because it is
// the only thing that can: minting the sub-realm token a kind is handed needs a
// live `cur`, and a /p/ package has none.
//
// It receives the kind, the sub-path to mint under, and the payload — and
// NOTHING ELSE. No pointer into governor or ledger state passes through here,
// which is what makes dispatching third-party code safe: gno-security-guide.md
// §3(C) is about a victim invoking a caller-supplied value while holding its
// own authority, and the damage in that class is done through a pointer
// parameter. There is none to give.
//
// The realm's implementation is one line:
//
//	func(k governor.Kind, sub, payload string) error {
//		return k.Do(0, cur.Sub(sub), payload)
//	}
type Dispatch func(k Kind, subpath, payload string) error

func (g *Governor) Execute(who address, id int64, run Dispatch) {
	if run == nil {
		// The engine holds no capability of its own, so without a dispatcher
		// there is nothing that could run a kind. Refused before anything is
		// written, so a caller who forgot one can supply it and retry.
		panic("govern: a dispatcher is required to run a kind")
	}
	if g.executing {
		panic("govern: re-entrant execution")
	}
	p := g.mustProposal(id)
	g.settle(p)
	if p.state != stateSucceeded {
		panic("govern: that proposal is not waiting to be executed")
	}
	if now := g.voters.Height(); inDelay(p, now) {
		// Says when, because "not yet" without a when is an invitation to poll.
		// The proposal page has carried this figure all along; the refusal a
		// caller actually receives did not.
		panic(ufmt.Sprintf("govern: still in the delay window: executable at "+
			"height %d, %d blocks away", p.ready, p.ready-now))
	}
	e := g.entryOf(p.kind)
	if e == nil || !e.live {
		// The holders withdrew this power while the proposal was waiting.
		// Recorded as a failure rather than a panic: the proposal is finished
		// either way, and a panic would leave it Succeeded forever, retried by
		// anyone, failing identically each time.
		g.setState(p, stateFailed, "the kind was retired before this could run")
		return
	}
	k := e.kind

	// Checked again, against the world as it is now rather than as it was when
	// the question was asked.
	if err := g.checkKind(k, p.payload); err != nil {
		g.setState(p, stateFailed, "no longer valid: "+err.Error())
		return
	}

	// Deferred, not cleared on the next line. If Do panics the transaction
	// aborts and the flag rolls back with everything else — but a recover
	// anywhere between here and there would leave the latch set and the
	// governor permanently unable to run anything again.
	g.executing = true
	defer func() { g.executing = false }()
	// The kind gets a SUB-REALM, never the realm's own capability — which is
	// why the sub-path is computed here and handed out, rather than left to
	// whoever writes the Dispatch.
	//
	// A live cur inside a foreign kind's Do has IsCurrent() true and the
	// consuming realm's PkgPath, so it is not "the realm as data", it is that
	// realm's authority, handed to code the holders adopted for one purpose.
	// With it a kind can cross() into any realm that trusts the consumer and be
	// seen as it, issue its tokens, and drain its banker. Adopting a treasury
	// kind would grant reach over every realm that names this one.
	//
	// cur.Sub gives a distinct pkgpath and a distinct address, and the VM
	// refuses RealmIssue for a sub-realm outright. A governed realm therefore
	// gates on the sub-path of the power it granted, which is also more useful
	// than gating on the governor as a whole.
	var err error
	if b, ok := asBuiltin(k); ok {
		// The governor's own kinds act on the governor. They are handed it
		// directly and never a sub-realm: there is no outside world for them
		// to reach, so there is nothing to grant.
		err = b.run(g, run, p.payload)
	} else {
		err = run(k, subPathOf(p.kind), p.payload)
	}

	if err != nil {
		g.setState(p, stateFailed, err.Error())
		return
	}
	g.setState(p, stateExecuted, "")
}

// ReleaseRoll drops a finished proposal's voter roll and refunds its deposit to
// whoever calls.
//
// The roll does not go when a proposal settles, because a kind that pays out to
// the people who voted has to ask after the fact, and pull-based claiming means
// the last claim can be a long way after execution. So it is reclaimed on
// request instead: nobody is obliged to, and whoever does is paid for it — the
// same bargain Settle makes for the slot.
//
// Refused twice over. While a proposal is open, because Vote reads the roll to
// refuse a second vote and dropping it early would let everybody vote twice.
// And while it has SUCCEEDED but not yet run, because that is exactly the
// window in which the kind has not read it yet — Execute is where a kind that
// pays its voters looks, so a stranger could otherwise empty the roll in the
// block before execution and leave the kind with nobody to pay. Waiting for the
// execution to land costs the reclaimer nothing; there is no deadline on this.
func (g *Governor) ReleaseRoll(who address, id int64) {
	p := g.mustProposal(id)
	g.settle(p)
	switch p.state {
	case stateActive:
		panic("govern: that proposal is still open; its roll is what refuses a second vote")
	case stateSucceeded:
		panic("govern: that proposal has not run yet; the roll is what it runs against")
	}
	p.voted = nil
}

// Settle advances a proposal's state and frees its slot if it is finished.
//
// Needed because a read cannot persist: State and Render will tell you a
// proposal is defeated and tell you again tomorrow, since the transition they
// computed died with the query. Without a way to record it, the open list is a
// resource anybody can exhaust — fill every slot with proposals that will lose
// and nothing ever reclaims them.
//
// Permissionless, because it decides nothing: it writes down a conclusion the
// rules already reached.
func (g *Governor) Settle(who address, id int64) {
	g.settle(g.mustProposal(id))
}

// sweep frees the slots of a few finished proposals. Bounded, and run when
// somebody proposes — the moment a full list matters, paid for by whoever wants
// the room. Unbounded here would make one unlucky proposer tidy the history.
//

const sweepScan = 8

func (g *Governor) sweep() {
	// openIdx cannot exceed maxLive — Propose refuses at the bound — so the
	// whole ring is a handful of windows. Trying them until one frees a slot is
	// still a BOUNDED scan; the bound that matters here is the index's, not the
	// history's, and it is the history that the per-window limit exists to keep
	// one unlucky proposer from paying to tidy.
	for w := 0; w <= maxLive/sweepScan; w++ {
		before := g.openIdx.Size()
		g.sweepWindow()
		if g.openIdx.Size() < before {
			return
		}
	}
}

func (g *Governor) sweepWindow() {
	const scan = sweepScan

	// Collected first, acted on after: settle removes from openIdx, and bptree
	// says a tree must not be modified during iteration (tree.gno). Calling it
	// from the callback removed the key the cursor stood on.
	//
	// No failure was observed and that is not evidence of safety — at this size
	// the tree tolerates it. The symptom, if it does not, is a slot that never
	// comes back, months later, under load.
	seen := 0
	last := ""
	var ids []string
	var stale []string
	g.openIdx.Iterate(g.sweepFrom, "", func(k string, v any) bool {
		seen++
		last = k
		if g.proposals.Get(v.(string)) == nil {
			stale = append(stale, k)
		} else {
			ids = append(ids, v.(string))
		}
		return seen >= scan
	})
	// Where to resume. A short window means the end of the index was reached,
	// so the next one starts over; otherwise it starts just past the last key
	// looked at. Appending a NUL gives the smallest string above a key, and the
	// keys are all the same length, so nothing can sort between the two.
	if seen < scan {
		g.sweepFrom = ""
	} else {
		g.sweepFrom = last + "\x00"
	}

	for _, key := range ids {
		if p := g.proposals.Get(key); p != nil {
			g.settle(p.(*proposal))
		}
	}
	// Index entries whose proposal has gone entirely, which settle cannot
	// reach because there is nothing left to settle.
	for _, k := range stale {
		g.openIdx.Remove(k)
	}
}

// Cancel withdraws a proposal. Only the proposer, only while it is still open.
func (g *Governor) Cancel(who address, id int64) {
	p := g.mustProposal(id)
	if who != p.proposer {
		panic("govern: only the proposer may cancel")
	}
	g.settle(p)
	if p.state != stateActive {
		panic("govern: too late to cancel")
	}
	// The one transition out of active that the rules do not make.
	g.setState(p, stateCanceled, "")
}

// ----------------------------------------------------------------- reading --

// State advances the clock before answering, so a reader never sees a proposal
// that is active only because nobody has poked it.
func (g *Governor) State(id int64) string {
	p := g.mustProposal(id)
	// The pure form: asking what a proposal's state is must not change it.
	st, _ := g.wouldBe(p, g.voters.Height())
	switch st {
	case stateActive:
		return "active"
	case stateDefeated:
		return "defeated"
	case stateSucceeded:
		return "succeeded"
	case stateExecuted:
		return "executed"
	case stateFailed:
		return "failed"
	case stateCanceled:
		return "canceled"
	default:
		return "expired"
	}
}

// Preview renders what a payload would say, before anybody proposes it — so an
// interface can show somebody their proposal, and Check refuses a malformed one
// without spending a transaction.
//
// It also pins the thing the extension point rests on: govern calling INTO a
// kind in another realm. A stored interface value is re-resolved from the store
// on every call, so the method that runs is the offering realm's code.
//
// Reads whether or not the kind is adopted. What a payload would say is not a
// power, and refusing to preview an unadopted one makes the adoption vote
// harder to judge rather than safer.
func (g *Governor) Preview(kind, payload string) string {
	// The same bound Propose applies, at the cheaper door. Propose is a
	// transaction and this is a read, so an unbounded payload here is the
	// easier of the two to hand over — and it reaches the same Describe and
	// Check with it. Bounding one door and not the other is not bounding
	// anything.
	if len(payload) > maxPayload {
		return "that payload is too long"
	}
	e := g.entryOf(kind)
	if e == nil {
		return "no kind by that name has been offered"
	}
	out := g.describeKind(e.kind, payload)
	if err := g.checkKind(e.kind, payload); err != nil {
		out += "\n\n_This would be refused: " + err.Error() + "_"
	}
	if !e.live {
		out += "\n\n_This kind has not been adopted, so it cannot be proposed yet._"
	}
	return out
}

// Describe is what the vote is about, rendered by the kind from the payload
// alone — the same string Do will be handed.
func (g *Governor) Describe(id int64) string {
	p := g.mustProposal(id)
	return g.describeOf(p)
}

// HasVoted reports whether an address has already voted on a proposal.
//
// OpenZeppelin has hasVoted; without it the only way to find out is to send a
// vote and be refused, spending a transaction to learn what the realm knows. A
// wallet needs it before deciding whether to offer the buttons.
//
// Keeps answering after a proposal closes, because the roll survives until
// somebody calls ReleaseRoll. Once it has been released this answers false, so
// it is "is their vote still on record here", not "did they ever" — the
// permanent record of who voted is the Voted events.
func (g *Governor) HasVoted(id int64, who address) bool {
	p := g.mustProposal(id)
	return p.voted != nil && who != rollSentinel && p.voted.Has(string(who))
}

// Timings is a proposal's clock: when it opened, when voting closes, when it
// becomes executable, and when that chance lapses. The companion to Tally —
// without it, anything showing a countdown parsed the page, which is prose
// written for people.
//
// Two of these are zero rather than absent, and both zeroes mean something:
//
//	ready == 0    the outcome is not recorded yet, so the timelock has not
//	              started. Settle starts it, and anybody may call it.
//	expires == 0  it never expires, which is what a grace period of zero means
//	              everywhere else in this realm.
func (g *Governor) Timings(id int64) (opened, closes, ready, expires int64) {
	p := g.mustProposal(id)
	at, ever := expiresAt(p)
	if !ever {
		at = 0
	}
	return p.opened, p.closes, p.ready, at
}

// Tally is the vote so far: yes, no, abstain, and the supply they are weighed
// against.
//
// The fourth number is the one worth having. Every bar here is a fraction —
// quorum of the snapshot supply, threshold of what was cast — so three counts
// without their denominator cannot be checked against anything. It is the
// supply at the proposal's snapshot epoch, not the supply now.
func (g *Governor) Tally(id int64) (yes, no, abstain, total int64) {
	p := g.mustProposal(id)
	return p.yes, p.no, p.abstain, p.total
}

// Render is the governance page.
//
// It matters more here than a Render usually does. This design's whole claim
// over one that carries code is that what a voter reads IS what executes —
// Describe and Do consume the same string. That claim is only worth anything
// if somebody actually reads it, so the description is on the page rather than
// behind a call nobody makes.
func (g *Governor) render(path, notes string) string {
	if path != "" {
		return g.renderOne(path)
	}
	out := ufmt.Sprintf("# %s (%s)\n\n", g.token.Name(), g.token.Symbol())

	// The token first, because the governance below is only meaningful in
	// terms of it: every quorum is a fraction of this supply and every vote is
	// weighed out of it.
	out += ufmt.Sprintf("- supply: %s %s (%d at %d decimals)\n",
		g.units(g.token.TotalSupply()), g.token.Symbol(), g.token.TotalSupply(), g.token.Decimals())
	out += notes
	out += ufmt.Sprintf("- epoch: %d (votes are weighed at sealed epochs)\n\n", g.voters.Epoch())
	out += "## governance\n\n"

	var open, ready, done string
	nOpen := 0
	now := g.voters.Height()

	// The open list IS openIdx: a proposal holds its slot until it reaches a
	// final state, so what is in there is exactly what belongs above the fold.
	// Bounded by maxLive rather than by how many questions have ever been
	// asked.
	g.openIdx.Iterate("", "", func(_ string, v any) bool {
		pv := g.proposals.Get(v.(string))
		if pv == nil {
			return false
		}
		p := pv.(*proposal)
		st, _ := g.wouldBe(p, now)
		if st != stateActive && st != stateSucceeded {
			// Finished, and still holding its slot because nobody has written
			// that down. The scan below reaches it as history, which is what
			// it is.
			return false
		}
		if st == stateSucceeded {
			ready += proposalLine(p, st)
		} else {
			open += proposalLine(p, st)
		}
		nOpen++
		return false
	})

	// Newest first, and it stops as soon as the tail is full.
	//
	// The cap is on the WORK, not just on what gets appended. One pass over
	// every proposal the realm has ever held, computing each state and
	// truncating at the end, would grow forever while the page stayed the same
	// size — and this is the read every holder makes.
	g.proposals.ReverseIterate("", "", func(_ string, v any) bool {
		if len(done) >= 2000 {
			return true
		}
		p := v.(*proposal)
		st, _ := g.wouldBe(p, now)
		if st == stateActive || st == stateSucceeded {
			return false // already above, from g.openIdx
		}
		done += proposalLine(p, st)
		return false
	})

	// Split by what the reader is asked to DO, not by which list the realm
	// keeps them in. Both hold a slot, but a decided proposal waiting out its
	// timelock is not something to vote on, and putting it under a heading that
	// means "still being voted on" tells the reader to do the wrong thing.
	//
	// The slot count belongs to the page rather than to either section. nOpen
	// counts everything holding a slot, decided-and-unrun included, so under a
	// voting heading it would sit above a shorter list — and vanish entirely
	// when every slot is held by decided proposals, which is when being full
	// matters most.
	// And the lane, once it is the only thing left. Below that point the count
	// is the whole story; at or above it, a holder reads free slots and is
	// refused anyway, which is the page contradicting the realm.
	out += ufmt.Sprintf("%d of %d slots in use", nOpen, maxLive)
	if nOpen >= maxOpen {
		out += ufmt.Sprintf("; the last %d are kept for the governor's own kinds, "+
			"so nothing else can be opened until one comes back", maxLive-maxOpen)
	}
	out += ".\n\n"
	if open == "" {
		out += "_Nothing to vote on._\n"
	} else {
		out += "### to vote on\n\n" + open
	}
	if ready != "" {
		out += "\n### decided, waiting to be run\n\n" + ready
	}
	if done != "" {
		out += "\n### finished\n\n" + done
	}
	return out
}

func (g *Governor) renderOne(path string) string {
	id, err := strconv.ParseInt(path, 10, 64)
	if err != nil {
		return "# not a proposal id\n"
	}
	v := g.proposals.Get(enc(uint64(id)))
	if v == nil {
		return "# no such proposal\n"
	}
	p := v.(*proposal)
	st, reason := g.wouldBe(p, g.voters.Height())

	out := ufmt.Sprintf("# #%d — %s\n\n", p.id, p.title)
	// The description first, and rendered by the kind from the payload alone.
	// This is the text the vote is about.
	out += g.describeOf(p) + "\n\n"
	out += ufmt.Sprintf("- kind: `%s`\n- proposer: %s\n- state: **%s**\n",
		p.kind, p.proposer.String(), stateName(st))
	if reason != "" {
		out += "- reason: " + reason + "\n"
	}
	// The snapshot supply, rendered as the header renders the live one — it is
	// the same quantity, and it was raw here and in units there.
	//
	// The tally BELOW stays raw on purpose. Its stated job is to let a reader
	// check the arithmetic rather than take the state on trust, and mixing
	// units into numbers somebody is about to multiply would take that away.
	// Two renderings of the same kind of figure, for two different jobs, on one
	// page — which is worth saying because it looks like the inconsistency it
	// was just fixed for.
	out += ufmt.Sprintf("- weighed at epoch %d, when %s %s was in issue (%d)\n",
		p.epoch, g.units(p.total), g.token.Symbol(), p.total)
	out += ufmt.Sprintf("\n## votes\n\n- yes %d\n- no %d\n- abstain %d\n",
		p.yes, p.no, p.abstain)
	// Both bars, as counted, so a reader can check the arithmetic rather than
	// take the state on trust.
	cast := turnout(p)
	// Percentages, not basis points. The realm counts in bps because integers
	// are exact where a float is an argument waiting to happen, and pct() exists
	// precisely so that choice does not reach the page — a holder asked to read
	// "needs 6600 bps" is being asked to do arithmetic to find out whether their
	// vote mattered.
	// Against ENGAGED, because that is what quorum divides by. Equal to total
	// for this realm; an electorate that drops idle weight would otherwise show
	// a bar nobody is being measured against.
	//
	// A consumer-set absolute floor is rendered as the count it is, not a
	// fraction of engaged — the tally compares cast against that number, so the
	// page must show it or it contradicts the state it is describing.
	if p.quorumFloor > 0 {
		out += ufmt.Sprintf("\nturnout %d of %d, needs %d · ", cast, p.engaged, p.quorumFloor)
	} else {
		out += ufmt.Sprintf("\nturnout %d of %d, needs %s · ", cast, p.engaged, pct(p.rules.QuorumBps))
	}
	// Three cases, not two. The threshold weighs yes against yes+no, so it has
	// nothing to weigh when every vote was an abstention — but that is not the
	// same as nobody voting, and collapsing them prints a line that contradicts
	// itself:
	//
	//	turnout 1000 of 1000, needs 20.00% · no votes cast
	//
	// The whole supply voted. Saying so on the left and denying it on the right
	// is worst for the one case this realm treats most carefully: an
	// all-abstained proposal is the one that would otherwise pass with nobody
	// in favour, which is why the support bar exists at all.
	switch {
	case forAndAgainst(p) > 0:
		out += ufmt.Sprintf("yes is %d of %d cast, needs %s\n",
			p.yes, forAndAgainst(p), pct(p.rules.ThresholdBps))
	case p.abstain > 0:
		out += "every vote was an abstention, so the threshold has nothing to weigh\n"
	default:
		out += "no votes cast\n"
	}

	// When voting closes. The block below was written for the succeeded state
	// on the reasoning that it is the one state where a reader has something to
	// do and no way to know when — which was right, and stopped one state
	// short: an active proposal is where they have the most to do.
	//
	// The subtraction is safe. wouldBe returns a terminal state once now has
	// reached p.closes, so a proposal reading active has not.
	if st == stateActive {
		out += ufmt.Sprintf("\n_Voting closes in %d blocks, at height %d._\n",
			p.closes-g.voters.Height(), p.closes)
	}

	// What happens next, for a decision that has been taken and not yet done.
	//
	// Without this the page says "succeeded" and stops, which is the one state
	// where a reader has something to DO and no way to know when. It is also
	// the state that looks most like nothing is happening: the proposal sits on
	// the open list, apparently unfinished, while a timelock it cannot see runs
	// down.
	if st == stateSucceeded {
		now := g.voters.Height()
		expiry, expires := expiresAt(p)
		switch {
		case p.state != stateSucceeded:
			// Decided and not yet written down — what a proposal winning on its
			// DEADLINE looks like, since nobody has to be present when one
			// passes.
			//
			// p.ready is zero until then, so the lines below would be
			// arithmetic against nothing — "succeeded" and "expired" printed
			// together. Saying what is actually needed is the useful thing
			// anyway, because anybody may Settle it.
			out += "\n_Decided, and nobody has recorded it yet. The delay " +
				"starts when somebody calls Settle — anybody may._\n"
		case inDelay(p, now):
			out += ufmt.Sprintf("\n_Waiting: executable in %d blocks, at height %d._\n",
				p.ready-now, p.ready)
		case expires && now > expiry:
			out += "\n_Expired: nobody executed it in time._\n"
		case expires:
			out += ufmt.Sprintf("\n**Executable now**, until height %d.\n", expiry)
		default:
			out += "\n**Executable now.**\n"
		}
	}
	return out
}

// proposerBar renders the stake a proposer must hold, where zero is not "none
// required" so much as "no check at all".
func proposerBar(bps int64) string {
	if bps <= 0 {
		return "anybody, holding nothing"
	}
	return pct(bps) + " of the supply"
}

// turnout is every vote cast, abstentions included. One definition because it
// was two: the tally computed it and the page computed it again, so the quorum
// a proposal was DECIDED by and the figure a holder READ could diverge. That
// line has already produced two page-versus-state contradictions.
//
// Abstain counts here because it counts towards quorum, which is why the
// support bar exists separately.
func turnout(p *proposal) int64 { return p.yes + p.no + p.abstain }

// forAndAgainst is what the threshold weighs: the votes that took a side.
//
// Abstentions are deliberately absent — they count towards quorum and not
// towards the bar — and that rule was written once in the tally and again on
// the page, which is how a page comes to disagree with the state it describes.
func forAndAgainst(p *proposal) int64 { return p.yes + p.no }

// inDelay is whether a decided proposal is still inside its timelock.
//
// Execute refuses while this holds and the page counts down while it holds, and
// those two must not disagree by even a block: a page offering to run what
// Execute will refuse is the same defect as a page calling a live proposal
// expired. One definition, so a boundary cannot be moved on one side only.
func inDelay(p *proposal, now int64) bool { return now < p.ready }

// expiresAt is when a decided proposal stops being executable, and whether it
// ever does. saneRules refuses a grace of zero, so in practice it always does.
//
// One definition because it is easy to write three: the tally testing
// `now > ready+grace`, the page testing it again, and the page printing the sum
// a third time as the height it offers to run until. Three independent copies
// of one deadline is how a page comes to print "succeeded" and "expired"
// together.
func expiresAt(p *proposal) (int64, bool) {
	// Nothing expires before the outcome is written down, because the window is
	// measured from p.ready and p.ready is zero until Settle sets it. Adding a
	// grace period to nothing gives a deadline in the realm's first hour, which
	// is how a page once printed "succeeded" and "expired" together.
	//
	// The page guards that by checking the recorded state before it asks; the
	// guard belongs here, where the arithmetic is. Timings walked straight into
	// it the moment it exposed this to a caller who had not read the page's
	// comment.
	// saneRules refuses a grace of zero, so that arm is defence rather than
	// policy; p.ready is the live one.
	if p.rules.GraceBlocks <= 0 || p.ready == 0 {
		return 0, false
	}
	return p.ready + p.rules.GraceBlocks, true
}

// span renders a period in blocks, with roughly how long that is.
//
// Correctness never depends on the wall clock, but "120960 blocks to vote"
// does not tell a reader whether that is an afternoon or a season. Both are
// printed and the approximation is marked as one.
//
// Five seconds a block, the same assumption the bootstrap rules were chosen
// under. At another cadence the block counts are still exact and the hours are
// not, which is why they are hedged.
func span(blocks int64) string {
	if blocks <= 0 {
		return "no period"
	}
	secs := blocks * 5
	switch {
	case secs < 60*60:
		return ufmt.Sprintf("%d blocks (about %s)", blocks, plural(secs/60, "minute"))
	case secs < 48*60*60:
		return ufmt.Sprintf("%d blocks (about %s)", blocks, plural(secs/3600, "hour"))
	default:
		return ufmt.Sprintf("%d blocks (about %s)", blocks, plural(secs/86400, "day"))
	}
}

// plural writes a count with its unit, in the number the count deserves.
//
// "1 hours" reads as something a machine wrote, and a page that reads as
// machine-written gets skimmed — which is a poor outcome for the text somebody
// is meant to study before granting a power.
func plural(n int64, unit string) string {
	if n == 1 {
		return "1 " + unit
	}
	return ufmt.Sprintf("%d %ss", n, unit)
}

// units renders a base-unit amount the way a holder counts it. The ledger is
// integers all the way down, which is exact and unreadable: "supply: 1000"
// beside "decimals: 6" asks somebody to divide before they know whether they
// hold a millionth of the token or all of it. Both are printed — this for
// reading, the raw figure for checking.
//
// scale is 10^decimals for the token being rendered — computed, not a constant,
// because Go has no constant exponentiation and the engine does not know what token
// it renders until given one (TestTheEngineRendersTheTokensOwnScale checks it).
// Decimals is CLAMPED to 18 first: 10^19 overflows int64 (and 10^k for k≥64 wraps to
// 0, which would divide-by-zero in units()), so an unclamped power on a pathological
// token would corrupt or panic Render. Render is a read, so a clamp on the rare bad
// token is the right trade; grc20votes reports a small fixed decimals and is unaffected.
func (g *Governor) scale() int64 {
	d := g.token.Decimals()
	if d > 18 {
		d = 18
	}
	out := int64(1)
	for i := 0; i < d; i++ {
		out *= 10
	}
	return out
}

func (g *Governor) units(n int64) string {
	whole := n / g.scale()
	frac := n % g.scale()
	// The sign has to be taken from n, not from the whole part. Integer
	// division truncates towards zero, so everything between -1 and 0 has a
	// whole part of exactly 0 — and a "-0" that FormatInt prints as "0". Taking
	// the minus from whole therefore dropped it for that entire range, and
	// -0.5 rendered as 0.5: not a near miss but the opposite number.
	sign := ""
	if n < 0 {
		sign = "-"
		whole, frac = -whole, -frac
	}
	out := strconv.FormatInt(frac, 10)
	for len(out) < g.token.Decimals() {
		out = "0" + out
	}
	// Trailing zeroes are noise; a whole number should read as one.
	for len(out) > 1 && out[len(out)-1] == '0' {
		out = out[:len(out)-1]
	}
	if out == "0" {
		return sign + strconv.FormatInt(whole, 10)
	}
	return sign + strconv.FormatInt(whole, 10) + "." + out
}

// proposalLine is one row of the governance list.
func proposalLine(p *proposal, st int8) string {
	return ufmt.Sprintf("- [#%d](:%d) **%s** — `%s` · %s\n",
		p.id, p.id, p.title, p.kind, stateName(st))
}

// maxReason bounds what a kind may write into the permanent record.
//
// An adopted kind is trusted — the holders voted it the power to run — so this
// is not a defence against a hostile one, which could do far worse than store a
// long string. It is a defence against a buggy one: an error carrying a whole
// response body or a stack of context lands in a proposal that is kept forever
// and rendered every time somebody opens it.
const maxReason = 256

// clip truncates at a rune boundary, so a cut message stays valid UTF-8 rather
// than ending in half a character.
func clip(s string) string {
	if len(s) <= maxReason {
		return s
	}
	// Walk back to the first byte that is not a continuation byte. Cutting
	// BEFORE that byte is already a whole-rune prefix — the character it
	// begins is simply left out.
	//
	// Backing off one further, to drop the lead byte as well, is wrong and
	// looked right: it takes the cut inside the character before, which is how
	// this was first written. The test that caught it decodes what survives
	// rather than measuring it.
	n := maxReason
	for n > 0 && s[n]&0xC0 == 0x80 {
		n--
	}
	return s[:n] + "…"
}

// proposalSettledEvent is the single announcement of an outcome.
//
// One event with a state on it rather than one event per outcome, because the
// per-outcome shape is what let four of the six transitions go unannounced:
// Executed and Failed were emitted at two of Execute's paths, its other
// failure path and the retired-kind path said nothing, and a proposal that
// simply LOST — the ordinary result — was never announced anywhere. It opened,
// it collected votes, and then nothing was ever said about it again.
const (
	// kindOfferedEvent is the only announcement a kind gets before it is
	// adopted, and the only one at all if it never is.
	//
	// The registry is never iterated — an ungated one is unbounded, and walking
	// it would put somebody's spam on the page holders read — so without this
	// an offered kind could be found only by guessing its name, and the
	// extension point was undiscoverable.
	//
	// Adoption gets no event: it happens through a proposal, which is already
	// announced when it opens and when it settles.
	kindOfferedEvent = "KindOffered"

	proposalOpenedEvent  = "ProposalOpened"
	votedEvent           = "Voted"
	proposalSettledEvent = "ProposalSettled"
)

// setState is the only writer of p.state, and does everything that follows from
// a proposal reaching one, so no new code path has to remember. Called only
// with a state out of stateActive: nothing transitions back in.
//
// Three things:
//
//   - the reason is clipped, so a kind cannot write an unbounded string into a
//     record kept for the life of the realm;
//   - the slot goes, unless the proposal SUCCEEDED and is pending execution;
//   - the outcome is announced.
//
// Not the voter roll, which outlives the decision. A kind that pays the people
// who voted has to ask after the proposal has finished, so the roll goes on
// request instead, at ReleaseRoll — permissionless, with the deposit going to
// whoever calls it, which is the same bargain Settle makes for the slot.
func (g *Governor) setState(p *proposal, st int8, reason string) {
	p.state, p.reason = st, clip(reason)
	if st != stateSucceeded {
		g.release(p)
	}
	chain.Emit(proposalSettledEvent,
		"id", strconv.FormatInt(p.id, 10),
		"state", stateName(st),
		"reason", p.reason,
	)
}

func stateName(s int8) string {
	switch s {
	case stateActive:
		return "active"
	case stateDefeated:
		return "defeated"
	case stateSucceeded:
		return "succeeded"
	case stateExecuted:
		return "executed"
	case stateFailed:
		return "failed"
	case stateCanceled:
		return "canceled"
	}
	return "expired"
}

func (g *Governor) entryOf(name string) *entry {
	if v := g.kinds.Get(name); v != nil {
		return v.(*entry)
	}
	return nil
}

// subPathOf maps a kind name onto a legal sub-realm path.
//
// Sub takes '/'-separated segments of [a-z0-9] with '_.-' inside a segment, and
// a kind name is any printable ASCII without spaces — "govern:adopt" among
// them. Anything outside the alphabet becomes '-', which keeps the mapping
// total, stable and readable: a governed realm gating on this sees the power it
// granted rather than the governor as a whole.
func subPathOf(kind string) string {
	out := []byte(kind)
	for i := 0; i < len(out); i++ {
		c := out[i]
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9':
		case c >= 'A' && c <= 'Z':
			out[i] = c + ('a' - 'A')
		default:
			out[i] = '-'
		}
	}
	return string(out)
}

// liveEntry is what a proposal needs: a kind the holders have adopted.
//
// The two failures are told apart because the remedy differs. A name nobody
// offered is a typo; a name that IS offered and not adopted is waiting on a
// vote, and "no such kind" points that reader at their spelling when what they
// need is govern:adopt. Preview has always distinguished them.
func (g *Governor) liveEntry(name string) *entry {
	e := g.entryOf(name)
	if e == nil {
		panic("govern: no such kind: " + name)
	}
	if !e.live {
		panic("govern: the kind " + name + " has been offered but not adopted, " +
			"so it cannot be proposed yet — the holders adopt it with govern:adopt")
	}
	return e
}

func (g *Governor) kindOf(name string) Kind { return g.liveEntry(name).kind }

// anyKind is the kind whether or not it is still adopted.
//
// Reading is not doing. Retiring a kind withdraws the power to run it; it must
// not also erase the record of what was already proposed under it — and it did,
// because everything that renders a proposal went through the live lookup and
// panicked. One retirement would have taken every historical page with it.
func (g *Governor) anyKind(name string) Kind {
	e := g.entryOf(name)
	if e == nil {
		return nil
	}
	return e.kind
}

// describeOf renders a proposal, surviving a kind that has since been retired
// or was never offered here at all.
func (g *Governor) describeOf(p *proposal) string {
	k := g.anyKind(p.kind)
	if k == nil {
		return "_the kind `" + p.kind + "` is no longer registered, so this " +
			"proposal can no longer describe itself. Its payload was:_\n\n" +
			g.indented(p.payload)
	}
	return g.describeKind(k, p.payload)
}

// indented puts EVERY line of a payload inside the code block. Four spaces in
// front of the whole string indents line one and leaves the rest as live
// markdown, and payloads may contain newlines — govern:batch is defined in
// terms of them.
//
// Reached only when a kind has been retired or was never registered, which is
// the one place a payload is rendered with nothing left to have vetted it: the
// validation belonged to that kind's Check.
func (g *Governor) indented(s string) string {
	return "    " + strings.ReplaceAll(s, "\n", "\n    ")
}

func (g *Governor) rulesOf(name string) Rules { return g.liveEntry(name).rules }

func (g *Governor) mustProposal(id int64) *proposal {
	v := g.proposals.Get(enc(uint64(id)))
	if v == nil {
		panic("govern: no such proposal")
	}
	return v.(*proposal)
}

// Errors a kind returns. Values rather than strings built at the call site, so
// a caller can compare them and Describe cannot drift from Check.

type govError struct{ s string }

func (e *govError) Error() string { return e.s }
func govErr(s string) error       { return &govError{s} }

// digest identifies a question by what it asks, not by who asked it.
//
// Only ever used to refuse a duplicate while one is open. Identity stays a
// sequence number, because a number renders, sorts and paginates and a hash
// does none of those — OpenZeppelin derives the whole proposal id from the
// hash and pays for it every time a UI wants a list in order.
func (g *Governor) digest(kind, payload string) string {
	h := sha256.Sum256([]byte(kind + "\x00" + payload))
	return string(h[:16])
}

// release frees a proposal's slot in the open index. Idempotent, because
// settle can reach a terminal state from more than one path.
func (g *Governor) release(p *proposal) { g.openIdx.Remove(g.digest(p.kind, p.payload)) }
