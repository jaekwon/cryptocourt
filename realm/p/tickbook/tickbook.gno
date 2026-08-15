// Package tickbook is a tick-quantised central limit order book: a gas-bounded,
// integer-only venue for a two-sided market on a fixed price grid, with no
// liquidity pool and no custody of its own.
//
// Prices live on a 1..100 grid (a "tick" is a hundredth). One side BIDs to buy
// shares, the other ASKs to sell them; a taker crosses the opposing side best
// price first, up to a limit price and a hard level budget. The book records
// resting quantity and who is owed what; it never moves a share or a coin.
//
// # No custody — the realm escrows, the book accounts
//
// A resting order is a promise: an ask promises SHARES, a bid promises the COIN
// to pay for them. The book holds neither. The consuming realm escrows the
// backing asset when it calls Place and settles the actual asset when it calls
// Take/Collect/Cancel — in the SAME transaction, so a panic in either half rolls
// both back. This is the split cshares uses, and it is what keeps the book a pure
// recorder: it takes no banker and no callback, so there is no Apply-class
// laundering surface (gno-security-guide.md §4). The realm keeps two escrow pools
// per market:
//
//	ask pool: SHARES that ask-makers deposited on Place; a bid-taker's shares are
//	          withdrawn from it, and the coin a bid-taker pays goes INTO it for
//	          ask-makers to Collect.
//	bid pool: COIN that bid-makers escrowed on Place; an ask-taker's coin is
//	          withdrawn from it, and the shares an ask-taker delivers go INTO it
//	          for bid-makers to Collect.
//
// Every deposit is matched by a later withdrawal, so each pool stays solvent
// without the book ever seeing a balance.
//
// # Pull-settled makers, so a Take dirties ONE object
//
// The hot path is Take. All of a side's aggregate state — the two occupancy
// words and 100 ticks of {resting, surv, epoch} — is ONE packed []byte, so
// crossing three levels dirties exactly one object, the same as crossing one.
// Individual maker orders live in a bptree that Take never touches: a maker's
// fill is computed lazily from the tick's accumulator when they Collect or Cancel.
//
// # Pro-rata within a tick, via a survival fraction
//
// Every order at one tick trades at the SAME price, so time priority there is
// fairness-only, not economic. The book fills a tick's makers pro-rata to their
// REMAINING size. It tracks one number per tick — surv, the surviving fraction of
// resting size, scaled — that a fill multiplies down: a fill of f against resting
// r sets surv ← surv·(r−f)/r. A maker who joined when the fraction was s0 with qty
// q has filled q·(s0−surv)/s0. This is the only form that stays correct when a
// maker is partially filled across several takes AND when makers join at different
// times (a plain additive "per-original-unit" accumulator over-credits the
// already-filled). surv rounds UP and fills round DOWN, so makers' fills sum to AT
// MOST the taker's — never more; the remainder is dust that stays safely in the
// realm's pool. This also makes Cancel O(1): settle the filled part, drop the
// order, return the rest — no walking a FIFO queue's mid-order holes.
//
// The floored dust is at most one share per order over its whole life, and Cancel
// caps its refund at the resting the book tracks exactly, so the escrow pool is
// never paid out short. A consuming realm should still set a minimum order size
// (as pmkt does), so a one-share dust is negligible against any real order.
//
// A tick that empties is REUSED: an epoch counter bumps each time resting returns
// to zero, and a maker whose epoch is older than the tick's is, by definition,
// fully filled (their epoch ended by exhausting them) — which is how a stale s0
// baseline never corrupts a reused tick.
//
// # /p/ safety
//
// Every field is unexported; no method returns the []byte, the tree, or an
// *order — reads return values. A /p/ type handed back with a mutator would let a
// borrow run under the consuming realm's authority (borrow rule #2); this follows
// cshares and grc20votes: encapsulate, and leave authentication to the realm.
package tickbook

import (
	"math/bits"
	"math/overflow"

	bptree "gno.land/p/nt/bptree/v0"
)

// Side is which half of the book an order sits on.
type Side uint8

const (
	// Bid buys shares (pays coin); Ask sells shares (delivers shares).
	Bid Side = iota
	Ask
)

const (
	// ticks is the price grid: prices 1..100 map to tick indices 0..99.
	ticks = 100
	// accScale is the survival fraction's fixed-point unit (1.0), a uint64.
	//
	// A fill of f against resting r shrinks a tick's surv by the factor (r-f)/r.
	// For that shrink to MOVE surv on the smallest fill — one share — surv must
	// stay at least as large as r. Since surv = accScale·r/T where T is the peak
	// resting the tick ever held, surv >= r holds exactly when T <= accScale. That
	// is why a tick's resting is capped at maxTickResting = accScale: beyond it,
	// surv would freeze and a one-share fill would credit no maker at all (their
	// coin stranded) — the sub-unit rounding-dominance an order book must not have.
	// 1e18 is ~1000x the court's entire supply cap (~9.2e14), so the cap never
	// binds in practice yet guarantees the fraction always resolves a real fill.
	accScale = int64(1_000_000_000_000_000_000)
	// maxTickResting caps a tick's aggregate resting so the survival fraction can
	// never freeze (see accScale). A Place that would breach it panics.
	maxTickResting = accScale
	// maxLevels caps how many price levels one Take may FILL — the returned
	// `crossed`. Empty ticks between fills are skipped for free (not counted), and
	// the scan is bounded separately by the 100-tick grid, so a Take visits at most
	// 100 ticks and fills at most maxLevels. Take dirties one object regardless of
	// either bound.
	maxLevels = 32

	headerLen = 16 // two 64-bit occupancy words
	tickLen   = 20 // resting int64 (8) + surv uint64 (8) + epoch uint32 (4)
	sideLen   = headerLen + ticks*tickLen
)

// order is one maker's resting order. s0 is the tick's survival fraction when the
// order joined and epoch the tick's epoch then; collected is how much of its fill
// the maker has already pulled.
type order struct {
	maker     address
	side      Side
	tick      uint8
	qty       int64
	s0        int64
	epoch     uint32
	collected int64
}

// Book is one market's two sides plus its resting orders. A consuming realm
// allocates one per claim and keeps it in realm state; it is a heap object, so
// its methods mutate it directly (unlike twap's inline value).
type Book struct {
	bid    []byte         // packed side aggregate (occupancy + 100 ticks)
	ask    []byte         // packed side aggregate
	orders *bptree.BPTree // be8(id) -> *order
	nextID uint64
}

// NewBook builds an empty book. The two side buffers are allocated once and
// mutated in place ever after, so each is a single object across the book's life.
func NewBook() *Book {
	return &Book{
		bid:    make([]byte, sideLen),
		ask:    make([]byte, sideLen),
		orders: bptree.NewBPTree32(),
	}
}

// Price is a tick's grid price, an integer 1..100 (a hundredth of full value). A
// filled share at grid price p costs p/100 of one unit of collateral, so the realm
// turns a returned notional (Σ fill·gridprice) into coin as
// notional·collateralPerShare/100, where collateralPerShare is the realm's own
// coin amount for one whole winning share.
func Price(tick uint8) int64 {
	if tick >= ticks {
		panic("tickbook: tick out of range")
	}
	return int64(tick) + 1
}

// Place rests a maker's order of qty shares at tick on side, and returns its id.
// The realm must have escrowed the backing asset (shares for an ask, qty·price
// coin for a bid) before calling. Place refuses an order that would CROSS the
// book — a bid at or above the best ask, an ask at or below the best bid — so the
// realm must Take the marketable part first and rest only the remainder; this
// keeps the book un-crossed by construction.
func (b *Book) Place(side Side, tick uint8, maker address, qty int64) uint64 {
	mustPositive(qty)
	if tick >= ticks {
		panic("tickbook: tick out of range")
	}
	if side == Bid {
		if ba, ok := b.bestAsk(); ok && tick >= ba {
			panic("tickbook: bid would cross the book; Take first")
		}
	} else {
		if bb, ok := b.bestBid(); ok && tick <= bb {
			panic("tickbook: ask would cross the book; Take first")
		}
	}
	data := b.side(side)
	rest := getI64(data, restOff(tick))
	if rest == 0 {
		// (Re)starting an empty tick: a fresh epoch with a full survival fraction.
		// Any uncollected order from an older epoch is already fully filled, and
		// its stale s0 is ignored because its epoch is now behind the tick's.
		putU32(data, epochOff(tick), getU32(data, epochOff(tick))+1)
		putU64(data, survOff(tick), uint64(accScale))
	}
	s0 := int64(getU64(data, survOff(tick)))
	epoch := getU32(data, epochOff(tick))

	nrest, ok := overflow.Add64(rest, qty)
	if !ok || nrest > maxTickResting {
		panic("tickbook: tick resting would exceed the precision bound")
	}
	putI64(data, restOff(tick), nrest)
	occSet(data, tick)

	b.nextID++
	id := b.nextID
	b.orders.Set(be8(id), &order{maker: maker, side: side, tick: tick, qty: qty, s0: s0, epoch: epoch})
	return id
}

// Take crosses the side OPPOSITE to taker, best price first, filling up to demand
// shares and stopping at limitTick (the worst price the taker will accept: for a
// Bid-taker the highest tick, for an Ask-taker the lowest) or maxLevels levels,
// whichever binds first. It returns the shares filled, the notional in grid units
// (Σ fill·price, which the realm scales to coin), and how many levels it crossed.
//
// A Bid-taker BUYS: it pays notional coin into the ask pool and takes filled
// shares out of it. An Ask-taker SELLS: it delivers filled shares into the bid
// pool and takes notional coin out of it. The realm settles the taker from these
// three numbers immediately; makers settle later via Collect.
func (b *Book) Take(taker Side, limitTick uint8, demand int64) (filled, notional int64, crossed int) {
	mustPositive(demand)
	if limitTick >= ticks {
		panic("tickbook: limit tick out of range")
	}
	if taker != Bid && taker != Ask {
		panic("tickbook: bad side") // don't silently coerce a bad side to Ask
	}
	var data []byte
	var t, end, step int
	if taker == Bid {
		data = b.ask // a buyer crosses asks, lowest first
		t, end, step = 0, int(limitTick), 1
	} else {
		data = b.bid // a seller crosses bids, highest first
		t, end, step = ticks-1, int(limitTick), -1
	}
	occ0 := getU64(data, 0)
	occ1 := getU64(data, 8)
	for step > 0 && t <= end || step < 0 && t >= end {
		if demand == 0 || crossed >= maxLevels {
			break
		}
		if !occHas(occ0, occ1, t) {
			t += step
			continue
		}
		tk := uint8(t)
		rest := getI64(data, restOff(tk))
		if rest <= 0 {
			t += step
			continue
		}
		fill := demand
		if fill > rest {
			fill = rest
		}
		// Shrink the tick's survival fraction by (rest-fill)/rest, rounded UP so a
		// maker's fill (q·(s0-surv)/s0) rounds DOWN — never over-credited. A fill
		// that clears the level pins surv to 0 exactly, so its makers read as fully
		// filled with no rounding slack.
		if fill == rest {
			putU64(data, survOff(tk), 0)
		} else {
			surv := int64(getU64(data, survOff(tk)))
			nsurv, ok := mulDivCeil(surv, rest-fill, rest)
			if !ok {
				panic("tickbook: survival overflow")
			}
			putU64(data, survOff(tk), uint64(nsurv))
		}
		putI64(data, restOff(tk), rest-fill)
		if rest-fill == 0 {
			occ0, occ1 = occClear(occ0, occ1, t)
		}
		part, ok := overflow.Mul64(fill, Price(tk))
		if !ok {
			panic("tickbook: notional overflow")
		}
		notional, ok = overflow.Add64(notional, part)
		if !ok {
			panic("tickbook: notional overflow")
		}
		filled += fill
		demand -= fill
		crossed++
		t += step
	}
	putU64(data, 0, occ0)
	putU64(data, 8, occ1)
	return filled, notional, crossed
}

// Collect settles the newly-filled part of a maker's order: it returns the maker's
// side, the shares newly filled since their last Collect, and those shares'
// notional in grid units. An ask-maker is owed COIN (notional, from the ask pool);
// a bid-maker is owed SHARES (the filled count, from the bid pool). When an order
// is fully filled it is dropped. Only the maker may collect their own order.
func (b *Book) Collect(maker address, id uint64) (side Side, newlyFilled, notional int64) {
	o := b.mustOrder(id)
	if o.maker != maker {
		panic("tickbook: not the maker")
	}
	f := b.orderFilled(o)
	newly := f - o.collected
	if newly < 0 {
		newly = 0 // defensive; fill never falls
	}
	o.collected = f
	if f >= o.qty {
		b.orders.Remove(be8(id)) // fully filled: nothing left to rest or cancel
	}
	n, ok := overflow.Mul64(newly, Price(o.tick))
	if !ok {
		panic("tickbook: notional overflow")
	}
	return o.side, newly, n
}

// Cancel withdraws the UNFILLED remainder of a maker's order and drops it. It
// returns the maker's side, the shares that had filled since the last Collect
// (which the realm settles exactly as a final Collect for this order), and the
// shares refunded. The realm returns the refund's backing asset from escrow: for
// a bid the coin refund·price, for an ask the refund shares. O(1): the
// accumulator makes a maker's fill computable without touching the queue.
func (b *Book) Cancel(maker address, id uint64) (side Side, filled, refunded int64) {
	o := b.mustOrder(id)
	if o.maker != maker {
		panic("tickbook: not the maker")
	}
	f := b.orderFilled(o)
	refund := o.qty - f
	if refund < 0 {
		refund = 0
	}
	if refund > 0 {
		data := b.side(o.side)
		rest := getI64(data, restOff(o.tick))
		// Cap the refund at the resting the book tracks EXACTLY. orderFilled
		// floors, so a maker's sub-share fill can read low and push qty-f above
		// what actually still rests; refunding that would hand back shares a taker
		// already took and leave the realm's escrow pool short. The tracked resting
		// is the true remaining, so capping there keeps the pool solvent — the
		// floored-away dust stays in the pool, which is the safe direction.
		if refund > rest {
			refund = rest
		}
		putI64(data, restOff(o.tick), rest-refund)
		if rest-refund == 0 {
			occ0 := getU64(data, 0)
			occ1 := getU64(data, 8)
			occ0, occ1 = occClear(occ0, occ1, int(o.tick))
			putU64(data, 0, occ0)
			putU64(data, 8, occ1)
		}
	}
	newlyFilled := f - o.collected
	if newlyFilled < 0 {
		newlyFilled = 0
	}
	b.orders.Remove(be8(id))
	return o.side, newlyFilled, refund
}

// ------------------------------------------------------------------- reads --

// RestingAt is the aggregate resting quantity at one tick on a side.
func (b *Book) RestingAt(side Side, tick uint8) int64 {
	if tick >= ticks {
		panic("tickbook: tick out of range")
	}
	return getI64(b.side(side), restOff(tick))
}

// BestBid is the highest occupied bid tick; BestAsk the lowest occupied ask tick.
// ok is false when that side is empty.
func (b *Book) BestBid() (tick uint8, ok bool) { return b.bestBid() }
func (b *Book) BestAsk() (tick uint8, ok bool) { return b.bestAsk() }

// OrderFilled is how many of an order's shares have filled so far (capped at its
// size). Exists reports whether an id is still a live resting order.
func (b *Book) OrderFilled(id uint64) int64 { return b.orderFilled(b.mustOrder(id)) }
func (b *Book) Exists(id uint64) bool       { return b.orders.Get(be8(id)) != nil }

// OrderTick is the price tick a live order rests at, and OrderSide its side. A
// consuming realm needs them to value the coin leg of a Cancel — Cancel returns
// share counts, and coin = count·Price(tick). Value reads; nothing escapes.
func (b *Book) OrderTick(id uint64) uint8 { return b.mustOrder(id).tick }
func (b *Book) OrderSide(id uint64) Side  { return b.mustOrder(id).side }

// Count is how many orders have ever been placed, which is the last id assigned.
func (b *Book) Count() uint64 { return b.nextID }

// ----------------------------------------------------------------- innards --

func (b *Book) side(s Side) []byte {
	if s == Bid {
		return b.bid
	}
	if s == Ask {
		return b.ask
	}
	panic("tickbook: bad side")
}

func (b *Book) bestBid() (uint8, bool) {
	occ0 := getU64(b.bid, 0)
	occ1 := getU64(b.bid, 8)
	for t := ticks - 1; t >= 0; t-- {
		if occHas(occ0, occ1, t) {
			return uint8(t), true
		}
	}
	return 0, false
}

func (b *Book) bestAsk() (uint8, bool) {
	occ0 := getU64(b.ask, 0)
	occ1 := getU64(b.ask, 8)
	for t := 0; t < ticks; t++ {
		if occHas(occ0, occ1, t) {
			return uint8(t), true
		}
	}
	return 0, false
}

func (b *Book) mustOrder(id uint64) *order {
	v := b.orders.Get(be8(id))
	if v == nil {
		panic("tickbook: no such order")
	}
	return v.(*order)
}

// orderFilled computes a maker's fill from its tick's live accumulator. An order
// whose epoch is behind the tick's had its epoch end by exhaustion, so it is fully
// filled. Otherwise the pro-rata-of-remaining share q·(s0−surv)/s0, floored and
// capped at the order's size.
func (b *Book) orderFilled(o *order) int64 {
	data := b.side(o.side)
	if o.epoch < getU32(data, epochOff(o.tick)) {
		return o.qty
	}
	surv := int64(getU64(data, survOff(o.tick)))
	d := o.s0 - surv
	if d <= 0 {
		return 0
	}
	f, ok := mulDivFloor(o.qty, d, o.s0)
	if !ok {
		panic("tickbook: fill overflow")
	}
	if f > o.qty {
		f = o.qty
	}
	return f
}

func mustPositive(qty int64) {
	if qty <= 0 {
		panic("tickbook: quantity must be positive")
	}
}

// --- packed-buffer layout: [0:8] occ word 0, [8:16] occ word 1, then tick t at
// 16+t*20 as {resting int64, surv uint64, epoch uint32}. ticks 0..63 are in occ
// word 0, 64..99 in word 1.

func restOff(tick uint8) int  { return headerLen + int(tick)*tickLen }
func survOff(tick uint8) int  { return headerLen + int(tick)*tickLen + 8 }
func epochOff(tick uint8) int { return headerLen + int(tick)*tickLen + 16 }

func occSet(b []byte, tick uint8) {
	if tick < 64 {
		putU64(b, 0, getU64(b, 0)|(uint64(1)<<tick))
	} else {
		putU64(b, 8, getU64(b, 8)|(uint64(1)<<(tick-64)))
	}
}

func occHas(occ0, occ1 uint64, t int) bool {
	if t < 64 {
		return occ0&(uint64(1)<<uint(t)) != 0
	}
	return occ1&(uint64(1)<<uint(t-64)) != 0
}

func occClear(occ0, occ1 uint64, t int) (uint64, uint64) {
	if t < 64 {
		return occ0 &^ (uint64(1) << uint(t)), occ1
	}
	return occ0, occ1 &^ (uint64(1) << uint(t-64))
}

func getU64(b []byte, off int) uint64 {
	var v uint64
	for i := 0; i < 8; i++ {
		v = (v << 8) | uint64(b[off+i])
	}
	return v
}

func putU64(b []byte, off int, v uint64) {
	for i := 7; i >= 0; i-- {
		b[off+i] = byte(v & 0xff)
		v >>= 8
	}
}

func getU32(b []byte, off int) uint32 {
	var v uint32
	for i := 0; i < 4; i++ {
		v = (v << 8) | uint32(b[off+i])
	}
	return v
}

func putU32(b []byte, off int, v uint32) {
	for i := 3; i >= 0; i-- {
		b[off+i] = byte(v & 0xff)
		v >>= 8
	}
}

func getI64(b []byte, off int) int64 { return int64(getU64(b, off)) }
func putI64(b []byte, off int, v int64) {
	if v < 0 {
		panic("tickbook: negative packed value")
	}
	putU64(b, off, uint64(v))
}

// mulDivFloor and mulDivCeil return floor/ceil of a*b/denom via an exact 128-bit
// intermediate, with ok = false on a negative input, a non-positive denom, or a
// result that would not fit in an int64. Inlined (rather than imported) so a
// reusable order book carries no cross-project math dependency — the survival
// fraction's whole safety argument rests on these rounding directions, so they
// live next to it.
func mulDivFloor(a, b, denom int64) (int64, bool) { return mulDiv(a, b, denom, false) }
func mulDivCeil(a, b, denom int64) (int64, bool)  { return mulDiv(a, b, denom, true) }

func mulDiv(a, b, denom int64, roundUp bool) (int64, bool) {
	if a < 0 || b < 0 || denom <= 0 {
		return 0, false
	}
	hi, lo := bits.Mul64(uint64(a), uint64(b))
	d := uint64(denom)
	if hi >= d {
		// The quotient would overflow int64; also the precondition bits.Div64
		// needs to avoid a panic.
		return 0, false
	}
	q, rem := bits.Div64(hi, lo, d)
	if roundUp && rem != 0 {
		if q == ^uint64(0) {
			return 0, false
		}
		q++
	}
	if q > uint64(1<<63-1) {
		return 0, false
	}
	return int64(q), true
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
