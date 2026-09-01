// Package grc20votes is a GRC20-shaped ledger that remembers what every
// holder's voting power used to be.
//
// An analog of OpenZeppelin's ERC20Votes, not a transliteration. Where the
// EVM's shape exists only because the EVM is what it is — opt-in delegation, a
// storage model that charges for every extra word forever — gno gets to do the
// obvious thing instead: delegation defaults to self, and the checkpoint rides
// in the account record a transfer was going to write anyway.
//
// # What a consumer does
//
// A realm allocates one Ledger and keeps it in an unexported package variable:
//
//	var ledger = grc20votes.NewLedger("Kourt Governance", "COURT", 6, 720)
//
//	func Transfer(cur realm, to address, amount int64) {
//		if !cur.IsCurrent() {
//			panic("stale realm")
//		}
//		ledger.Transfer(cur.Previous().Address(), to, amount)
//	}
//
// Nothing here takes a `cur realm`, because a /p/ package cannot declare a
// crossing function. That is not a limitation worked around — it is the right
// split. Authentication belongs to the realm that has a caller to authenticate;
// this package is told WHICH address is acting and does the bookkeeping.
//
// # Why it is safe to keep this in /p/
//
// Every field is unexported and no method hands back an interior pointer, so a
// consumer holds a *Ledger and nothing else. That matters more here than it
// looks: /p/-declared types can be named by other /p/ packages, so an exported
// *account or a method returning one would let a stranger declare a mutator
// over it — and gno's storage-realm borrow would run that mutator under the
// CONSUMING realm's authority. See gno-security-guide.md §3(B) and §4; this
// follows the encapsulation pattern p/demo/tokens/grc20 sets, with the
// authentication moved out to the realm rather than carried on a teller.
//
// The one exception is deliberate: Ledger has no method taking a callback, so
// there is nothing to launder through. Adding one later would need the
// parameter type declared in the consuming realm, not here.
package grc20votes

import (
	"chain"
	"chain/runtime"
	"math/overflow"
	"strconv"

	checkpoint "gno.land/p/kourt/checkpoint/v0"
	bptree "gno.land/p/nt/bptree/v0"
)

// Bps is the basis-point scale, named once because it is load-bearing in three
// places at once here and in any governor reading this ledger: the supply
// ceiling, a rendered percentage, and a quorum. A scale written out separately
// in each is a number that can come to disagree with itself.
const Bps = int64(10000)

// MaxSupply keeps a tally's arithmetic honest for anything weighing this
// ledger. A threshold comparison is yes*Bps >= (yes+no)*threshold, and yes*Bps
// overflows int64 once the supply passes MaxInt64/Bps — a wrapped tally goes
// negative rather than failing loudly, so a won vote reports as lost.
//
// Not a remote bound: six decimals and a billion units in issue is 1e15 base
// units, already past it. Capped at mint, so a tally needs no overflow checks —
// roughly 922 million whole tokens at six decimals.
const MaxSupply = int64(9223372036854775807) / Bps

// Event names are grc20's exactly (p/demo/tokens/grc20: types.gno
// TransferEvent, token.gno chain.Emit), so an indexer following
// Transfer/Approval sees the same stream a stock token produces.
//
// What this does NOT do is implement grc20.Teller. The SECURITY note on
// types.gno's Teller tells consumers to reject anything failing
// IsCanonicalTeller, so satisfying it would be worthless to a careful caller
// and misleading to a careless one.
const (
	mintEvent     = "Mint"
	burnEvent     = "Burn"
	transferEvent = "Transfer"
	approvalEvent = "Approval"

	// delegateChangedEvent has no counterpart in grc20 because grc20 has no
	// delegation. The name is OpenZeppelin's, since anybody indexing a
	// governance token already knows it.
	delegateChangedEvent = "DelegateChanged"
)

// sep joins the two halves of an allowance key. The checkpoint package's
// separator rather than a byte that happens to match it: two constants with the
// same value in different files eventually disagree.
const sep = checkpoint.Sep

// supplyKey checkpoints the supply like any holder, under a key no address can
// take. "~" is not in the bech32 alphabet and an address always begins with
// "g". Not the separator itself, which the checkpoint package refuses as a key:
// one containing the separator shares a page range with its neighbours.
const supplyKey = "~supply"

// account is one holder: what they have, who votes it, and what it was.
//
// The votes series is a value field, not a pointer, so changing it dirties this
// record and nothing else — which is why checkpointing is affordable here.
//
// The record outlives a zero balance. The stock ledger removes a holder at zero
// (grc20 token.gno, led.balances.Remove); doing that here would delete the
// voting history, and an account oscillating through zero would churn keys.
type account struct {
	balance  int64
	delegate address // "" means self — see Delegate
	votes    checkpoint.Series
}

// Ledger is one token's balances and the history of their voting power.
//
// Allocated by the consuming realm, which is what makes this work at all: the
// trees inside carry that realm's storage stamp, so a method here borrows the
// consumer's authority for the write and the storage is billed to them. A /p/
// package's own state is frozen after init and could hold none of this.
// Clock is where this ledger's sense of height comes from. A realm supplies
// one so its OWN clock governs epochs; nil means the chain's, which is what an
// ordinary deployment wants.
//
// It exists because a realm that can fast-forward its clock for testing cannot
// fast-forward this package's: a pure package may not import a realm, and a
// SETTABLE package global would be a capability any caller could take. Bound at
// construction by the realm that owns the ledger, it is neither.
type Clock interface {
	// Height is the block height this ledger should quantise epochs by.
	Height() int64
}

type Ledger struct {
	// clock is nil on an ordinary deployment; see Clock.
	clock    Clock
	name     string
	symbol   string
	decimals int
	id       string

	// epochBlocks quantises the clock. Every change inside one epoch coalesces
	// into a single update of a record already being written, which is what
	// bounds archive growth by wall-clock activity rather than by block
	// production — and it makes the anti-flash-loan property an invariant
	// rather than a discipline, since a transaction cannot outlive its block
	// and a block cannot outlive its epoch.
	epochBlocks int64

	accounts   *bptree.BPTree // address -> *account
	allowances *bptree.BPTree // owner + sep + spender -> int64

	// THIS ARCHIVE IS NEVER TRIMMED, and that is a property of the design rather
	// than an omission. checkpoint.Archive has a Trim, the claim's hourly stake
	// series uses it, and one line here would look like an ordinary storage
	// saving.
	//
	// Trim's own contract is "ValueAt exact AT AND ABOVE keepFrom". Every question
	// in the realm above is anchored at a PAST epoch and reads two values from
	// here — PastVotes for each voter's ceiling and PastTotal for the bar those
	// votes are judged against — so trimming past a live question's epoch makes
	// both inexact, independently of each other. That is the numerator and the
	// denominator drifting to different instants, which is the defect that
	// produced turnout at 200-400% of its own bar and was reverted.
	//
	// What would have to be true to relax it: keepFrom below the oldest epoch any
	// open question is anchored at, which means knowing every open question — a
	// fact this package deliberately does not have. check-epoch-coherence arm 12
	// pins the call sites meanwhile.
	archive *checkpoint.Archive

	supply checkpoint.Series
	total  int64
}

// NewLedger creates an empty ledger. The identity is fixed here rather than
// read from a constant, so one realm can run several and a court can name its
// own coin.
//
// epochBlocks is the quantisation, in blocks. At gno's five-second cadence 720
// is an hour, which is the figure the rest of this design was measured at.
// NewLedgerWithClock is NewLedger with the height source named. A realm whose
// own clock can be fast-forwarded passes itself; everyone else calls NewLedger.
func NewLedgerWithClock(name, symbol string, decimals int, epochBlocks int64, clk Clock) *Ledger {
	l := NewLedger(name, symbol, decimals, epochBlocks)
	l.clock = clk
	return l
}

func NewLedger(name, symbol string, decimals int, epochBlocks int64) *Ledger {
	if name == "" || symbol == "" {
		panic("grc20votes: a token needs a name and a symbol")
	}
	if decimals < 0 || decimals > 18 {
		panic("grc20votes: decimals must be between 0 and 18")
	}
	if epochBlocks <= 0 {
		panic("grc20votes: an epoch has to be at least one block long")
	}
	return &Ledger{
		name: name, symbol: symbol, decimals: decimals,
		// The pkgpath is not knowable from here, so the id is the symbol
		// qualified by whatever the consumer wants. A realm that wants the
		// grc20reg shape passes its own path in the name.
		id:          symbol,
		epochBlocks: epochBlocks,
		accounts:    bptree.NewBPTree32(),
		allowances:  bptree.NewBPTree32(),
		archive:     checkpoint.NewArchive(),
	}
}

// SetID names this token the way an indexer will see it, usually
// "gno.land/r/you/realm.SYMBOL". Called once, at construction time, by the
// realm that knows its own path — a /p/ package cannot ask.
func (l *Ledger) SetID(id string) { l.id = id }

// ------------------------------------------------------------------ reads --

// The GRC20 reads, with the names that standard uses, answering about NOW.
//
// Governance does not read any of these. It asks PastVotes and PastTotal,
// which answer about a sealed epoch — the distinction the whole design turns
// on, and the reason these are grouped apart from them.

func (l *Ledger) Name() string       { return l.name }
func (l *Ledger) Symbol() string     { return l.symbol }
func (l *Ledger) Decimals() int      { return l.decimals }
func (l *Ledger) ID() string         { return l.id }
func (l *Ledger) TotalSupply() int64 { return l.total }

func (l *Ledger) BalanceOf(owner address) int64 {
	if a := l.getAccount(owner); a != nil {
		return a.balance
	}
	return 0
}

func (l *Ledger) Allowance(owner, spender address) int64 {
	if v := l.allowances.Get(string(owner) + sep + string(spender)); v != nil {
		return v.(int64)
	}
	return 0
}

// VotesOf is voting power right now — the sum of every balance delegated here,
// including the holder's own unless they delegated it away.
func (l *Ledger) VotesOf(who address) int64 {
	if a := l.getAccount(who); a != nil {
		return a.votes.Value()
	}
	return 0
}

// DelegateOf is who votes an address's balance. Self unless they said
// otherwise, which is the default nobody has to remember.
func (l *Ledger) DelegateOf(who address) address {
	a := l.getAccount(who)
	if a == nil || a.delegate == "" {
		return who
	}
	return a.delegate
}

// PastVotes is voting power throughout a SEALED epoch. Refusing the current one
// is the anti-flash-loan property as an invariant rather than a convention: a
// transaction runs inside one block, a block inside one epoch, and this will
// not answer for the epoch it is in.
func (l *Ledger) PastVotes(who address, at uint32) int64 {
	l.mustBeSealed(at)
	a := l.getAccount(who)
	if a == nil {
		return 0
	}
	return a.votes.ValueAt(l.archive, string(who), at)
}

// PastTotal is every unit in existence during a sealed epoch, which a quorum is
// a fraction of.
//
// Because delegation defaults to self, everyone's PastVotes sums to exactly
// this. OZ cannot say so: getPastTotalSupply counts all supply while
// getPastVotes counts only DELEGATED supply, so the denominator exceeds the
// achievable numerator and quorum is unreachable where few have delegated.
func (l *Ledger) PastTotal(at uint32) int64 {
	l.mustBeSealed(at)
	return l.supply.ValueAt(l.archive, supplyKey, at)
}

// EngagedTotal is what a governor measures quorum against. Every holder is
// engaged here by definition, since power is self-delegated by default — a
// realm wanting idle weight dropped out of the denominator wraps this.
func (l *Ledger) EngagedTotal(at uint32) int64 { return l.PastTotal(at) }

// WalkSupply visits the supply's CHANGE points, newest first, and stops early
// when fn returns true. An epoch in which supply did not move is not a point:
// a reader forward-fills between them.
//
// A WALK, not a per-epoch read. PastTotal answers one epoch and is the wrong
// shape for drawing a line — a chart over a year of hourly epochs would be
// 8,760 lookups to find the handful of epochs that actually moved. The archive
// already stores only the movements, so this hands them over directly and the
// cost is the number of mints, not the age of the court.
//
// Unsealed on purpose, unlike PastTotal: the newest point may be the running
// epoch, which is exactly the value a live chart wants at its right edge. It
// may still coalesce before the epoch seals, so it is a reading and not a
// record.
func (l *Ledger) WalkSupply(fn func(e uint32, v int64) bool) {
	// The two hot slots hold the newest points and are not in the archive yet.
	if e0 := l.supply.Since(); e0 != 0 {
		if fn(e0, l.supply.Value()) {
			return
		}
	}
	if e1, prev := l.supply.Prev(); e1 != 0 {
		if fn(e1, prev) {
			return
		}
	}
	l.archive.WalkDesc(supplyKey, fn)
}

// Epoch is now. A proposal snapshots Epoch()-1 and stores it; nothing
// re-derives it later.
func (l *Ledger) Epoch() uint32 {
	// 1-based, so zero can mean "before this token existed" — which is what
	// lets an untouched series answer correctly without storing anything.
	return uint32(l.Height()/l.epochBlocks) + 1
}

// Height is this ledger's clock, and the governor's: it is on the Electorate
// interface so a governor weighing votes uses the same height the ledger
// quantised its snapshots by. Falling back to the chain when no clock was
// supplied keeps every existing construction working unchanged.
func (l *Ledger) Height() int64 {
	if l.clock != nil {
		return l.clock.Height()
	}
	return runtime.ChainHeight()
}

// EpochBlocks is the quantisation this ledger was built with, so a consumer
// rendering a deadline in hours does not have to be told twice.
func (l *Ledger) EpochBlocks() int64 { return l.epochBlocks }

func (l *Ledger) mustBeSealed(at uint32) {
	if at == 0 || at >= l.Epoch() {
		panic("grc20votes: that epoch has not been sealed yet")
	}
}

// ----------------------------------------------------------------- writes --
//
// Every one of these takes the acting address rather than reading it. The realm
// above has the `cur realm` and is the only thing that can authenticate; being
// handed an address here is what keeps this package free of a capability it
// would have no way to check.

// Transfer moves `from`'s own tokens.
func (l *Ledger) Transfer(from, to address, amount int64) {
	l.move(from, to, amount)
}

// Approve lets a spender move some of the owner's balance.
func (l *Ledger) Approve(owner, spender address, amount int64) {
	mustBeValid(spender)
	if amount < 0 {
		panic("grc20votes: negative allowance")
	}
	key := string(owner) + sep + string(spender)
	if amount == 0 {
		l.allowances.Remove(key)
	} else {
		l.allowances.Set(key, amount)
	}
	chain.Emit(approvalEvent,
		"token", l.id,
		"owner", owner.String(),
		"spender", spender.String(),
		"value", strconv.Itoa(int(amount)),
	)
}

// TransferFrom spends an allowance.
func (l *Ledger) TransferFrom(spender, from, to address, amount int64) {
	key := string(from) + sep + string(spender)
	allowed := l.Allowance(from, spender)
	if allowed < amount {
		panic("grc20votes: allowance exceeded")
	}
	// Debited before the move. Defence in depth rather than a live fix: nothing
	// in move calls out, so today the order is unobservable and no test can
	// tell the difference. It is written this way for the day something here
	// does call out, when it becomes the difference between spending an
	// allowance once and twice.
	if rest := allowed - amount; rest == 0 {
		l.allowances.Remove(key)
	} else {
		l.allowances.Set(key, rest)
	}
	l.move(from, to, amount)
}

// Mint creates tokens. This package holds no minter: who may call it is the
// consuming realm's rule, because that is where the caller is known.
func (l *Ledger) Mint(to address, amount int64) {
	mustBeValid(to)
	mustBePositive(amount)

	next, ok := overflow.Add64(l.total, amount)
	if !ok || next > MaxSupply {
		panic("grc20votes: supply would exceed what a tally can weigh without overflowing")
	}
	l.total = next
	l.supply.SetAt(l.archive, supplyKey, l.Epoch(), next)

	a := l.openAccount(to)
	a.balance += amount
	l.addVotes(delegateeOf(to, a), amount)

	// Both events, and the Transfer is the one that matters to anybody else.
	//
	// grc20 declares MintEvent and BurnEvent and emits neither: its Mint sends
	// a TRANSFER with an empty `from` and its Burn one with an empty `to`. That
	// is the ERC20 convention, and how anything written against the standard
	// reconstructs balances — sum the Transfers, treat the empty counterparty
	// as the supply change. Emitting only "Mint" matches the names while
	// breaking what they are for.
	//
	// "Mint" is kept because it says plainly what happened. Anything totalling
	// supply should total Transfers and not both, which is safe for a standard
	// indexer since the standard never emits "Mint".
	chain.Emit(transferEvent,
		"token", l.id,
		"from", "",
		"to", to.String(),
		"value", strconv.Itoa(int(amount)),
	)
	chain.Emit(mintEvent,
		"token", l.id,
		"to", to.String(),
		"value", strconv.Itoa(int(amount)),
	)
}

// Burn destroys `from`'s own tokens.
func (l *Ledger) Burn(from address, amount int64) {
	mustBePositive(amount)
	a := l.getAccount(from)
	if a == nil || a.balance < amount {
		panic("grc20votes: insufficient balance")
	}
	a.balance -= amount
	l.addVotes(delegateeOf(from, a), -amount)

	l.total -= amount
	l.supply.SetAt(l.archive, supplyKey, l.Epoch(), l.total)

	// The other half of the convention: a burn is a Transfer to nowhere. See
	// the note in Mint for why both events go out.
	chain.Emit(transferEvent,
		"token", l.id,
		"from", from.String(),
		"to", "",
		"value", strconv.Itoa(int(amount)),
	)
	chain.Emit(burnEvent,
		"token", l.id,
		"from", from.String(),
		"value", strconv.Itoa(int(amount)),
	)
}

// Delegate points an address's voting power at someone else.
//
// Self-delegation is the DEFAULT, which OZ cannot afford: there it would put
// two SSTOREs on every transfer forever, so it is opt-in and everybody is
// surprised by it once. Here the checkpoint lives in a record the transfer
// already writes.
//
// One hop, not transitive: if A delegates to B and B to C, A's weight sits with
// B. Transitivity invites cycles and unbounded walks and buys nothing a second
// call cannot.
func (l *Ledger) Delegate(from, to address) {
	mustBeValid(to)

	if l.getAccount(from) == nil && to == from {
		// Already self-delegated, because everybody is: DelegateOf reads a
		// missing account and a blank delegate the same way, so a record here
		// buys a key to store a fact true of every address that never existed.
		//
		// An address holding nothing CAN still name somebody else, and that has
		// to persist for when it is funded. What it cannot usefully do is name
		// itself.
		return
	}
	a := l.openAccount(from)

	was := delegateeOf(from, a)
	if to == from {
		a.delegate = "" // normalised, so "self" has one representation
	} else {
		a.delegate = to
	}
	now := delegateeOf(from, a)
	if was == now {
		return
	}
	l.addVotes(was, -a.balance)
	l.addVotes(now, a.balance)

	// The only state change here that nothing else reveals. Delegating moves
	// power without moving a coin, so an indexer sees a holder's weight vanish
	// with nothing to explain it, and the only alternative is polling
	// DelegateOf for every address anyone has heard of.
	//
	// OZ also emits DelegateVotesChanged on every power change, which here
	// would fire on every transfer, mint and burn — for something a caller can
	// ask: VotesOf answers now, PastVotes for any sealed epoch. Emitting it
	// would be transliteration.
	chain.Emit(delegateChangedEvent,
		"token", l.id,
		"delegator", from.String(),
		"fromDelegate", was.String(),
		"toDelegate", now.String(),
	)
}

// --------------------------------------------------------------- innards --

func (l *Ledger) move(from, to address, amount int64) {
	mustBeValid(to)
	mustBePositive(amount)
	src := l.getAccount(from)
	if src == nil || src.balance < amount {
		panic("grc20votes: insufficient balance")
	}
	dst := l.openAccount(to)

	src.balance -= amount
	dst.balance += amount

	// Resolved once each. When both sides vote their own balance — the
	// overwhelmingly common case — these are the records already in hand, so a
	// checkpointed transfer dirties the same two objects a plain one would. The one
	// exception is a side's FIRST write in a new epoch, which also rolls one point
	// into the archive (one added page); amortised across the epoch's writes that
	// is ~nothing, but it is not literally two objects at the boundary.
	l.addVotes(delegateeOf(from, src), -amount)
	l.addVotes(delegateeOf(to, dst), amount)

	chain.Emit(transferEvent,
		"token", l.id,
		"from", from.String(),
		"to", to.String(),
		"value", strconv.Itoa(int(amount)),
	)
}

func delegateeOf(self address, a *account) address {
	if a.delegate == "" {
		return self
	}
	return a.delegate
}

// addVotes moves voting power and checkpoints it.
func (l *Ledger) addVotes(who address, delta int64) {
	if delta == 0 {
		return
	}
	a := l.openAccount(who)
	next := a.votes.Value() + delta
	if next < 0 {
		panic("grc20votes: voting power would go negative")
	}
	a.votes.SetAt(l.archive, string(who), l.Epoch(), next)
}

func (l *Ledger) getAccount(who address) *account {
	if v := l.accounts.Get(string(who)); v != nil {
		return v.(*account)
	}
	return nil
}

func (l *Ledger) openAccount(who address) *account {
	if a := l.getAccount(who); a != nil {
		return a
	}
	a := &account{}
	l.accounts.Set(string(who), a)
	return a
}

func mustBeValid(a address) {
	if !a.IsValid() {
		panic("grc20votes: not an address")
	}
}

func mustBePositive(amount int64) {
	if amount <= 0 {
		panic("grc20votes: amount must be positive")
	}
}
