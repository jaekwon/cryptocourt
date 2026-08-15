// Package cshares is a conditional-share ledger: the collateral-conserving core
// of a prediction market, with the collateral itself left to the caller.
//
// A CLAIM has N outcomes. Minting a complete SET — one share of every outcome —
// locks one unit of collateral; redeeming a matched set returns it; shares of a
// single outcome trade freely; and when a claim RESOLVES, the winning outcome's
// shares each redeem for one unit and the losers for nothing. The invariant that
// makes it sound is conservation: while a claim is open, every outcome's shares
// sum to exactly the number of sets outstanding, which is exactly the collateral
// owed.
//
// # What this package does NOT do
//
// It never touches the collateral token. It records shares and the set count;
// the consuming realm moves the actual coin, in the SAME crossing transaction, so
// a panic in either half rolls both back. That is the whole reason this can be a
// /p/ and pmkt's ledger — welded to ugnot, a banker, and its own oracle — could
// not: a conditional-share engine that custodies no value is reusable by any
// market, any collateral, any way of deciding the winner.
//
//	func MintSet(cur realm, id uint64, qty int64) {
//		if !cur.IsCurrent() { panic("stale realm") }
//		user := cur.Previous().Address()
//		coin.Transfer(user, escrowAddr, qty)  // the coin leg — the realm's job
//		shares.MintSet(id, user, qty)          // the share leg — this package
//	}
//
// The two invariants have two owners: this package asserts its half (every
// outcome sums to supply); the realm asserts the other (escrow balance >= total
// supply across claims). Neither can see the other's, which is why the split is
// stated rather than assumed.
//
// # /p/ safety
//
// Every field is unexported and no method returns a *claim or a tree — reads
// return values. A /p/-declared type handed back with exported Set/Remove would
// let a stranger's borrow run a mutator under the CONSUMING realm's authority
// (gno-security-guide.md §4, borrow rule #2). This follows grc20votes' pattern:
// encapsulate, and move authentication out to the realm.
package cshares

import (
	"math/bits"
	"math/overflow"

	bptree "gno.land/p/nt/bptree/v0"
)

// Status is a claim's lifecycle.
type Status uint8

const (
	// Open: sets mint and redeem, shares trade.
	Open Status = iota
	// Resolved: a winning outcome is set; winning shares pay, losers are void.
	Resolved
	// Closed: a binary claim settled at a FRACTIONAL price p=num/den — outcome 0
	// redeems at p, outcome 1 at 1−p. This is the "close at pre-answer TWAP" a
	// winner-take-all Resolve cannot express; conservation still holds because the
	// two prices sum to 1, so total payout is exactly supply.
	Closed
)

// maxOutcomes bounds a claim's outcome count. Binary is 2; the engine is
// N-capable so a court can host multi-way claims without a rewrite, but a ceiling
// keeps the complete-set loop and the per-outcome key byte bounded.
const maxOutcomes = 16

type claim struct {
	status Status
	winner int8  // -1 while open; the winning outcome once resolved
	supply int64 // sets outstanding while open; winning shares owed once resolved
	num    int64 // Closed only: outcome-0 price is num/den, outcome-1 is (den−num)/den
	den    int64
}

// Ledger holds every claim's shares and set counts. A consuming realm allocates
// one and keeps it in an unexported package var; there is no per-claim object of
// its own beyond a tiny record, so opening a claim allocates no new tree.
type Ledger struct {
	name      string
	outcomes  uint8
	nextID    uint64
	claims    *bptree.BPTree // be8(id)                       -> *claim
	shares    *bptree.BPTree // be8(id)+holder -> packed []int64, one per outcome
	approvals *bptree.BPTree // owner+operator                -> bool
}

// NewLedger builds an empty ledger whose claims each have `outcomes` outcomes
// (2 for a yes/no court).
func NewLedger(name string, outcomes uint8) *Ledger {
	if outcomes < 2 || outcomes > maxOutcomes {
		panic("cshares: outcomes must be 2..16")
	}
	return &Ledger{
		name:      name,
		outcomes:  outcomes,
		claims:    bptree.NewBPTree32(),
		shares:    bptree.NewBPTree32(),
		approvals: bptree.NewBPTree32(),
	}
}

// Name and Outcomes are the ledger's fixed identity.
func (l *Ledger) Name() string  { return l.name }
func (l *Ledger) Outcomes() int { return int(l.outcomes) }

// OpenClaim registers a new, open claim and returns its id. Ids are assigned in
// order, so the be8 key sorts by age for a paginated render.
func (l *Ledger) OpenClaim() uint64 {
	l.nextID++
	id := l.nextID
	l.claims.Set(be8(id), &claim{status: Open, winner: -1})
	return id
}

// MintSet locks qty sets for acct: +qty shares of every outcome, +qty to supply.
// The caller moves qty units of collateral into escrow in the same transaction
// and MUST pay it — this package records only the shares. Minting to an arbitrary
// acct is intentional (a paid gift); the realm decides who may call and for whom.
//
// The supply overflow is checked BEFORE any write, the same fail-atomic discipline
// RedeemSet uses. This matters because a panic here is same-realm (the consuming
// realm allocated this Ledger), so a caller with a recover in its stack would
// otherwise commit a half-credited claim and break conservation. Checking first
// also covers every outcome for free: each balance is at most supply, so if
// supply+qty does not overflow, no single balance can either.
func (l *Ledger) MintSet(id uint64, acct address, qty int64) {
	mustPositive(qty)
	c := l.mustOpen(id)
	next, ok := overflow.Add64(c.supply, qty)
	if !ok {
		panic("cshares: supply overflow")
	}
	bal := l.pos(id, acct)
	for o := range bal {
		bal[o] += qty // each balance <= old supply <= next, which did not overflow
	}
	l.setPos(id, acct, bal)
	c.supply = next
}

// RedeemSet burns qty shares of every outcome from acct. Like Transfer it trusts
// acct — the realm must have authenticated it. It requires acct to hold at least
// qty of each outcome, checked before any debit so a shortfall on the last
// outcome cannot leave acct partially burned. It returns qty (the collateral to
// release); the realm MUST pay that out of escrow in the same tx — otherwise
// shares are burned with nothing paid back.
func (l *Ledger) RedeemSet(id uint64, acct address, qty int64) int64 {
	mustPositive(qty)
	c := l.mustOpen(id)
	bal := l.pos(id, acct)
	for o := range bal {
		if bal[o] < qty {
			panic("cshares: insufficient shares to redeem a set")
		}
	}
	for o := range bal {
		bal[o] -= qty
	}
	l.setPos(id, acct, bal)
	c.supply -= qty
	return qty
}

// Transfer moves qty of one outcome's shares between holders. Supply is
// untouched — a transfer moves nothing in or out of the collateral pool.
//
// Like grc20votes, this authenticates NOTHING: it moves `from`'s shares on the
// realm's word. The consuming realm MUST have verified that the caller is `from`
// (or is authorised to act for it) before calling — a /p/ package has no caller
// to check. For the operator-approval path, use TransferFrom.
func (l *Ledger) Transfer(id uint64, outcome int, from, to address, qty int64) {
	l.mustOpen(id) // no trading a resolved claim; redeem winnings or Reclaim instead
	l.move(id, outcome, from, to, qty)
}

// TransferFrom moves shares on behalf of `owner`, which requires `owner` to have
// approved `spender` as an operator. There is no per-outcome allowance; approval
// is all-or-nothing across a holder's claims, the ERC-1155 shape.
func (l *Ledger) TransferFrom(spender, owner address, id uint64, outcome int, to address, qty int64) {
	if spender != owner && !l.IsApproved(owner, spender) {
		panic("cshares: not approved")
	}
	l.mustOpen(id) // no trading a resolved claim
	l.move(id, outcome, owner, to, qty)
}

// Reclaim moves qty of one outcome's shares between holders REGARDLESS of the
// claim's status — the settlement counterpart to Transfer. A market realm escrows
// makers' shares at its own address while orders rest or fills await collection;
// when the claim later resolves, the maker must still be able to pull those shares
// back out to redeem them. Transfer refuses (mustOpen); Reclaim does not, because
// this is settlement, not trading. It is otherwise identical: supply is untouched
// (nothing enters or leaves the collateral pool), and it authenticates NOTHING —
// the realm MUST have verified the caller owns `from`'s escrow claim. Restrict the
// `from` you pass to your own escrow address; never expose Reclaim from arbitrary
// holder to arbitrary holder, or it becomes a post-resolution Transfer.
func (l *Ledger) Reclaim(id uint64, outcome int, from, to address, qty int64) {
	l.mustGet(id) // exists; any status — settlement is allowed after resolution
	l.move(id, outcome, from, to, qty)
}

// SetOperatorApproval lets operator move all of owner's shares, or revokes it.
func (l *Ledger) SetOperatorApproval(owner, operator address, approved bool) {
	key := approvalKey(owner, operator)
	if approved {
		l.approvals.Set(key, true)
	} else {
		l.approvals.Remove(key)
	}
}

// IsApproved reports whether operator may move owner's shares.
func (l *Ledger) IsApproved(owner, operator address) bool {
	return l.approvals.Get(approvalKey(owner, operator)) != nil
}

// Resolve fixes the winning outcome. Only an open claim, only a real outcome. The
// consuming realm decides WHO may call this (a settled vote); this package only
// records it. After it, supply is reinterpreted as winning shares still owed —
// which equals the old supply, because every outcome summed to supply.
func (l *Ledger) Resolve(id uint64, winner int) {
	c := l.mustOpen(id)
	if winner < 0 || winner >= int(l.outcomes) {
		panic("cshares: winner out of range")
	}
	c.status = Resolved
	c.winner = int8(winner)
}

// RedeemWinning pays acct one unit per winning share and clears all of acct's
// shares in the claim (winners paid, losers void). Like Transfer it trusts acct —
// the realm must have authenticated it. It returns the amount owed, which the
// realm MUST pay out of escrow in the same tx; ignoring the return clears the
// shares without paying. Pull-based, so resolution never iterates holders.
func (l *Ledger) RedeemWinning(id uint64, acct address) int64 {
	c := l.mustGet(id)
	if c.status != Resolved {
		panic("cshares: claim is not resolved")
	}
	bal := l.pos(id, acct)
	won := bal[c.winner]
	l.setPos(id, acct, make([]int64, int(l.outcomes))) // clear all: winners paid, losers void
	c.supply -= won                                    // remaining coin owed shrinks by what was just paid
	return won
}

// CloseAt settles a BINARY claim at a fractional price p = num/den: outcome 0's
// shares each redeem for p, outcome 1's for 1−p. This is the "close at pre-answer
// TWAP" a winner-take-all Resolve cannot express. Only an open, binary claim; the
// realm decides WHO may call it (a settled 3-failed-round close). Because the two
// prices sum to 1, every set (one of each outcome) is still worth exactly one unit,
// so conservation is preserved: total payout is exactly supply.
func (l *Ledger) CloseAt(id uint64, num, den int64) {
	c := l.mustOpen(id)
	if l.outcomes != 2 {
		panic("cshares: CloseAt is for binary claims only")
	}
	if den <= 0 || num < 0 || num > den {
		panic("cshares: close price out of range")
	}
	c.status = Closed
	c.num, c.den = num, den
}

// RedeemClosed pays acct for a closed claim: floor(y0·p) + floor(y1·(1−p)) where
// y0/y1 are its outcome-0/outcome-1 shares. Like the other redeems it trusts acct
// (the realm authenticates), returns the amount owed for the realm to pay out of
// escrow, and clears the position. The floor keeps dust in the pool (safe).
func (l *Ledger) RedeemClosed(id uint64, acct address) int64 {
	c := l.mustGet(id)
	if c.status != Closed {
		panic("cshares: claim is not closed")
	}
	bal := l.pos(id, acct)
	// 128-bit intermediate so y·num cannot overflow even near the supply cap.
	pay := mulDivFloor(bal[0], c.num, c.den) + mulDivFloor(bal[1], c.den-c.num, c.den)
	l.setPos(id, acct, make([]int64, int(l.outcomes)))
	c.supply -= pay
	return pay
}

// ------------------------------------------------------------------- reads --

// BalanceOf is acct's share count of one outcome of a claim.
func (l *Ledger) BalanceOf(id uint64, outcome int, holder address) int64 {
	if outcome < 0 || outcome >= int(l.outcomes) {
		panic("cshares: outcome out of range")
	}
	return l.balance(id, uint8(outcome), holder)
}

// Supply is sets outstanding while open, or winning shares still owed once
// resolved — the collateral this claim accounts for, and the court's open
// interest (the quantity the tokenomics calls X).
func (l *Ledger) Supply(id uint64) int64 { return l.mustGet(id).supply }

// StatusOf and WinnerOf report a claim's lifecycle. WinnerOf is -1 until resolved.
func (l *Ledger) StatusOf(id uint64) Status { return l.mustGet(id).status }
func (l *Ledger) WinnerOf(id uint64) int    { return int(l.mustGet(id).winner) }

// CloseFractionOf is a closed claim's price fraction (num, den) — outcome 0's
// price is num/den. (0, 0) for a claim that was not closed at a fraction.
func (l *Ledger) CloseFractionOf(id uint64) (num, den int64) {
	c := l.mustGet(id)
	return c.num, c.den
}

// Exists reports whether a claim id has been opened.
func (l *Ledger) Exists(id uint64) bool { return l.claims.Get(be8(id)) != nil }

// Count is how many claims have been opened, which is also the last id.
func (l *Ledger) Count() uint64 { return l.nextID }

// ----------------------------------------------------------------- innards --

// move shifts qty of one outcome's shares between holders. It does NOT check the
// claim's status — the caller decides: Transfer/TransferFrom guard mustOpen (no
// trading a resolved claim), Reclaim guards only mustGet (settlement of escrowed
// shares is allowed after resolution). Either way the claim's existence is verified
// by the caller's guard before we index it.
func (l *Ledger) move(id uint64, outcome int, from, to address, qty int64) {
	mustPositive(qty)
	if outcome < 0 || outcome >= int(l.outcomes) {
		panic("cshares: outcome out of range")
	}
	o := outcome
	if from == to {
		// A self-transfer moves nothing; validate it COULD, then stop, so it does
		// not rewrite the holder's object twice to no effect.
		if l.pos(id, from)[o] < qty {
			panic("cshares: insufficient shares")
		}
		return
	}
	fb := l.pos(id, from)
	if fb[o] < qty {
		panic("cshares: insufficient shares")
	}
	fb[o] -= qty
	l.setPos(id, from, fb)
	tb := l.pos(id, to)
	next, ok := overflow.Add64(tb[o], qty)
	if !ok {
		panic("cshares: balance overflow")
	}
	tb[o] = next
	l.setPos(id, to, tb)
}

// pos returns holder's balance of every outcome of a claim as a fresh slice
// (all zero if the holder has no position). A holder's whole position for a claim
// is ONE key, so reading or writing it touches one object — not one per outcome —
// which is what makes a binary MintSet dirty a single share leaf instead of two.
func (l *Ledger) pos(id uint64, holder address) []int64 {
	out := make([]int64, int(l.outcomes))
	if v := l.shares.Get(posKey(id, holder)); v != nil {
		s := v.(string)
		for o := 0; o < int(l.outcomes); o++ {
			out[o] = int64(getBE8(s, o*8))
		}
	}
	return out
}

// setPos writes holder's whole position. An all-zero position frees the key and
// its deposit; otherwise the N balances pack big-endian into one []byte value.
func (l *Ledger) setPos(id uint64, holder address, bal []int64) {
	nonzero := false
	for _, b := range bal {
		if b != 0 {
			nonzero = true
			break
		}
	}
	key := posKey(id, holder)
	if !nonzero {
		l.shares.Remove(key)
		return
	}
	buf := make([]byte, len(bal)*8)
	for o, b := range bal {
		putBE8(buf, o*8, uint64(b))
	}
	l.shares.Set(key, string(buf))
}

// balance is holder's count of one outcome — one slot of its packed position.
func (l *Ledger) balance(id uint64, outcome uint8, holder address) int64 {
	return l.pos(id, holder)[outcome]
}

func (l *Ledger) mustGet(id uint64) *claim {
	v := l.claims.Get(be8(id))
	if v == nil {
		panic("cshares: no such claim")
	}
	return v.(*claim)
}

func (l *Ledger) mustOpen(id uint64) *claim {
	c := l.mustGet(id)
	if c.status != Open {
		panic("cshares: claim is not open")
	}
	return c
}

func mustPositive(qty int64) {
	if qty <= 0 {
		panic("cshares: quantity must be positive")
	}
}

// posKey is a claim's fixed-width id, then the holder. A holder's whole position
// for the claim — every outcome, packed as N big-endian int64s — lives under this
// one key. The id prefix is fixed-width and order-preserving, so a claim's whole
// holder set is one contiguous range for a render that needs it.
func posKey(id uint64, holder address) string {
	return be8(id) + string(holder)
}

// getBE8/putBE8 read and write one big-endian int64 (as a uint64 — balances are
// non-negative) at a byte offset inside a packed position value.
func getBE8(s string, off int) uint64 {
	var v uint64
	for i := 0; i < 8; i++ {
		v = (v << 8) | uint64(s[off+i])
	}
	return v
}

func putBE8(b []byte, off int, v uint64) {
	for i := 7; i >= 0; i-- {
		b[off+i] = byte(v & 0xff)
		v >>= 8
	}
}

// approvalKey encodes (owner, operator) so the boundary between the two
// variable-length halves is unambiguous for ANY bytes an address holds, rather
// than trusting that an address contains no chosen delimiter. The owner is
// length-prefixed with a fixed two-byte big-endian count: ("a\x00b","c") and
// ("a","b\x00c"), which a bare "\x00" delimiter would map to the same key, get
// distinct prefixes (3 vs 1) and cannot collide. Valid bech32 addresses are
// fixed-width and NUL-free, so the realm's normal path never approaches this;
// the prefix makes it hold even if a realm forwards an odd address.
func approvalKey(owner, operator address) string {
	o := string(owner)
	if len(o) > 0xffff {
		panic("cshares: address too long for an approval key")
	}
	return string([]byte{byte(len(o) >> 8), byte(len(o))}) + o + string(operator)
}

// mulDivFloor returns floor(a*b/denom) via a 128-bit intermediate, so a share
// count times a price numerator cannot overflow int64. Safe for a,b ≥ 0 and
// denom > 0 with b ≤ denom (RedeemClosed's shape): then the high word of a*b is
// always below denom, so bits.Div64 never traps.
func mulDivFloor(a, b, denom int64) int64 {
	hi, lo := bits.Mul64(uint64(a), uint64(b))
	q, _ := bits.Div64(hi, lo, uint64(denom))
	return int64(q)
}

// be8 is a big-endian, fixed-width, order-preserving key for a uint64.
func be8(u uint64) string {
	var b [8]byte
	for i := 7; i >= 0; i-- {
		b[i] = byte(u & 0xff)
		u >>= 8
	}
	return string(b[:])
}
