package court

import (
	"chain/runtime"

	tickbook "gno.land/p/cryptocourt/tickbook/v0"
)

// The market on a claim is a no-custody tick order book (tickbook): it records
// resting orders and computes fills; the COURT moves the actual shares and coin
// through its escrow, keeping two pools per claim — YES shares that ask-makers
// deposited, and CC that bid-makers escrowed. A tick is a tickbook index 0..99;
// the price is tick+1, in CC per share (a full share is worth priceScale = 100).
//
// Only YES shares trade on the book. A NO position is just a YES sell (mint a set,
// keep NO, sell YES) — the complete-set mint is where NO comes from.

// RestSell rests an order to SELL qty YES shares at a price, escrowing the shares
// until it fills or is cancelled. Returns the order id. It refuses an order that
// would CROSS the book (a seller who wants to hit resting bids uses TakeSell) —
// the escrow transfer then rolls back with the panic, so nothing is stranded.
func RestSell(cur realm, courtSlug string, claimID uint64, tick int, qty int64) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	maker := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	mustTradeable(cs)
	mustTick(tick)
	mustOrderSize(c, qty)

	c.shares.Transfer(claimID, outcomeYES, maker, c.escrow, qty) // escrow the shares
	return cs.book.Place(tickbook.Ask, uint8(tick), maker, qty)
}

// RestBid rests an order to BUY qty YES shares at a price, escrowing the coin it
// would cost (qty · price). Returns the order id. Refuses a crossing order (use
// TakeBuy to hit resting asks).
func RestBid(cur realm, courtSlug string, claimID uint64, tick int, qty int64) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	maker := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	mustTradeable(cs)
	mustTick(tick)
	mustOrderSize(c, qty)

	cost := qty * tickbook.Price(uint8(tick)) // CC to escrow
	c.coin.Transfer(maker, c.escrow, cost)
	return cs.book.Place(tickbook.Bid, uint8(tick), maker, qty)
}

// TakeBuy buys up to demand YES shares by crossing resting asks cheapest-first, up
// to limitTick (the highest price the buyer will pay). It pays the notional CC into
// escrow (for the ask-makers to Collect) and takes the filled shares out. Returns
// the shares filled and the coin paid.
func TakeBuy(cur realm, courtSlug string, claimID uint64, limitTick int, demand int64) (filled, notional int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	taker := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	mustTradeable(cs)
	mustTick(limitTick)
	f, n, _ := cs.book.Take(tickbook.Bid, uint8(limitTick), demand)
	if f == 0 {
		panic("court: nothing rested to buy at that limit")
	}
	c.coin.Transfer(taker, c.escrow, n)                        // pay coin in
	c.shares.Transfer(claimID, outcomeYES, c.escrow, taker, f) // take shares out
	observePrice(cs, n/f)
	return f, n
}

// TakeSell sells up to demand YES shares by crossing resting bids highest-first,
// down to limitTick (the lowest price the seller will accept). It delivers the
// filled shares into escrow (for the bid-makers) and takes the notional CC out.
func TakeSell(cur realm, courtSlug string, claimID uint64, limitTick int, demand int64) (filled, notional int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	taker := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	mustTradeable(cs)
	mustTick(limitTick)
	f, n, _ := cs.book.Take(tickbook.Ask, uint8(limitTick), demand)
	if f == 0 {
		panic("court: nothing rested to sell into at that limit")
	}
	c.shares.Transfer(claimID, outcomeYES, taker, c.escrow, f) // deliver shares in
	c.coin.Transfer(c.escrow, taker, n)                        // take coin out
	observePrice(cs, n/f)
	return f, n
}

// Collect pays a maker the fills accrued on their order since they last collected:
// coin for a filled ask, shares for a filled bid. Only the maker may collect their
// own order (the tickbook checks it against the acting address).
func Collect(cur realm, courtSlug string, claimID, orderID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	maker := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	side, newlyFilled, notional := cs.book.Collect(maker, orderID)
	if newlyFilled == 0 {
		return
	}
	if side == tickbook.Ask {
		c.coin.Transfer(c.escrow, maker, notional) // sold shares → coin owed
	} else {
		// Reclaim, not Transfer: a bid-maker who filled but hasn't collected must be
		// able to pull the bought shares out of escrow even after the claim resolves
		// (Transfer would refuse a resolved claim, stranding a winner's shares).
		c.shares.Reclaim(claimID, outcomeYES, c.escrow, maker, newlyFilled) // bought shares owed
	}
}

// CancelOrder withdraws a maker's unfilled remainder and settles any fills. For an
// ask: the filled part pays coin, the unfilled shares return. For a bid: the filled
// part delivers shares, the unfilled coin returns.
func CancelOrder(cur realm, courtSlug string, claimID, orderID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	maker := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)

	tick := cs.book.OrderTick(orderID) // read before Cancel removes the order
	price := tickbook.Price(tick)
	side, filled, refunded := cs.book.Cancel(maker, orderID)
	// The share legs use Reclaim, not Transfer, so a maker can still withdraw their
	// escrowed shares after the claim resolves (Transfer refuses a resolved claim).
	if side == tickbook.Ask {
		if filled > 0 {
			c.coin.Transfer(c.escrow, maker, filled*price) // proceeds of what sold
		}
		if refunded > 0 {
			c.shares.Reclaim(claimID, outcomeYES, c.escrow, maker, refunded) // unsold shares back
		}
	} else {
		if filled > 0 {
			c.shares.Reclaim(claimID, outcomeYES, c.escrow, maker, filled) // shares bought
		}
		if refunded > 0 {
			c.coin.Transfer(c.escrow, maker, refunded*price) // unspent escrow back
		}
	}
}

// observePrice records the just-traded average price into the claim's price twap —
// the pre-answer price a 3-round close settles at reads this (§3.7).
func observePrice(cs *claimState, gridPrice int64) {
	cs.price = cs.price.Observe(runtime.ChainHeight(), gridPrice)
}

// ------------------------------------------------------------------ reads --

// BestBid and BestAsk are the top of book (tick indices; ok=false when that side
// is empty). RestingAt is the aggregate resting size at one side and tick.
func BestBid(courtSlug string, claimID uint64) (tick int, ok bool) {
	t, o := mustClaim(mustCourt(courtSlug), claimID).book.BestBid()
	return int(t), o
}

func BestAsk(courtSlug string, claimID uint64) (tick int, ok bool) {
	t, o := mustClaim(mustCourt(courtSlug), claimID).book.BestAsk()
	return int(t), o
}

// TrailingPrice is the flash-resistant average traded price over a window, and
// whether it is mature (a 3-round close must have a mature pre-answer price).
func TrailingPrice(courtSlug string, claimID uint64, window int64) (avg int64, mature bool) {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	return cs.price.Average(runtime.ChainHeight(), window)
}

func mustTick(tick int) {
	if tick < 0 || tick > 99 {
		panic("court: a price tick is 0..99 (price = tick+1)")
	}
}

// mustTradeable refuses a trade once a claim has resolved. The share legs already
// fail through cshares' open-claim guard, but a resting bid escrows only coin (no
// share leg), so without this an order could rest on a resolved claim where it can
// never fill — recoverable by CancelOrder, but pointless. Making the closed market
// explicit here means the post-resolution boundary is one obvious check, not an
// emergent property a reader has to reconstruct from every leg.
func mustTradeable(cs *claimState) {
	if cs.finalized {
		panic("court: this claim has resolved — its market is closed")
	}
}

func mustOrderSize(c *Court, qty int64) {
	if qty < c.params.minOrderShares {
		panic("court: order below the court's minimum size")
	}
}
