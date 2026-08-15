package court

import (
	"chain/runtime"

	grc20votes "gno.land/p/cryptocourt/grc20votes/v0"
)

const (
	outcomeYES = 0
	outcomeNO  = 1

	// priceScale is the CC-base-units value of a full winning share, and equals the
	// tickbook price grid's top (1..100). A share is worth 0..priceScale CC, so a
	// book price tick (1..100) is CC-per-share DIRECTLY — book notional needs no
	// rescaling and cannot overflow. A complete set (one YES + one NO) is therefore
	// worth exactly priceScale CC. Open interest X is measured in CC (= sets ×
	// priceScale), so it is directly comparable to CC supply, votable, and bonds.
	priceScale = 100
)

// MintSet locks qty units of the court coin as collateral and gives the caller qty
// YES shares and qty NO shares of a claim — a complete set is worth exactly one
// unit, redeemable any time (RedeemSet). The collateral moves into the court's
// escrow; cshares records the shares. This is the only way open interest (X) grows.
//
// The court-wide open interest is capped at the governance fraction of supply
// (§3.5a: default 20%), so no coalition can qualify once and win across many
// claims. Every change re-observes the claim's open-interest twap, which is what
// the quorum floor and the answerability gate read as a flash-resistant X̄.
func MintSet(cur realm, courtSlug string, claimID uint64, qty int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if qty <= 0 {
		panic("court: quantity must be positive")
	}
	mustMintable(cs)

	collateral := qty * priceScale // CC locked per set

	// OI ceiling (§3.5a), all in CC. supply*bps stays in int64 (supply ≤ 9.2e14,
	// *10000 < 9.2e18); collateral ≤ ceiling ≤ supply, also bounded.
	ceiling := c.coin.TotalSupply() * c.params.oiCeilingBps / grc20votes.Bps
	if c.oi+collateral > ceiling {
		panic("court: the court-wide open-interest ceiling would be breached")
	}

	// Collateral (CC) into escrow, then the shares. Same tx: a panic in either
	// rolls both back, so a set is always exactly priceScale CC of collateral.
	c.coin.Transfer(who, c.escrow, collateral)
	c.shares.MintSet(claimID, who, qty)
	c.oi += collateral
	observeOI(cs, claimX(c, claimID))
}

// RedeemSet burns qty of every outcome and returns the qty units of collateral,
// paid out of escrow. Open interest shrinks by qty. Because collateral only ever
// left the caller into escrow, the pool is always solvent.
func RedeemSet(cur realm, courtSlug string, claimID uint64, qty int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if qty <= 0 {
		panic("court: quantity must be positive")
	}
	mustMintable(cs)

	owed := c.shares.RedeemSet(claimID, who, qty)   // panics if the caller lacks a full set
	c.coin.Transfer(c.escrow, who, owed*priceScale) // pay the collateral back out of escrow
	c.oi -= owed * priceScale
	observeOI(cs, claimX(c, claimID))
}

// observeOI records the claim's current open interest into its twap ring, at the
// current height. The court MUST observe on every change (mint/redeem/resolve), or
// a stale tail lets a spike become the whole trailing average (the twap freshness
// contract).
func observeOI(cs *claimState, x int64) {
	cs.oi = cs.oi.Observe(runtime.ChainHeight(), x)
}

// claimX is the claim's open interest X in CC (outstanding sets × priceScale) —
// the unit the quorum floor, the answer bond, and the dispute bond are all in.
func claimX(c *Court, claimID uint64) int64 {
	return c.shares.Supply(claimID) * priceScale
}

// mustMintable refuses a set mint or redeem once a claim has a provisional verdict.
// The tokenomics locks collateral for the escrow window ("the money is slow"), and
// freezing the set supply here is what makes the resolution fee a fraction of an
// unchanging collateral — and stops a matched-set holder from redeeming out at par to
// dodge the fee on their winning leg. Book transfers move shares between holders
// without changing supply, so they are unaffected; trading itself closes at Finalize.
func mustMintable(cs *claimState) {
	if cs.provisional >= 0 || cs.provClose {
		panic("court: the claim is resolving; sets are frozen until finalize")
	}
}

// ------------------------------------------------------------------ reads --

// SharesOf is who's YES/NO balance on a claim.
func SharesOf(courtSlug string, claimID uint64, outcome int, who address) int64 {
	return mustCourt(courtSlug).shares.BalanceOf(claimID, outcome, who)
}

// ClaimX is the claim's open interest in CC — what bonds and the quorum floor key
// off. ClaimSupply (claim.gno) is the same figure in raw sets (X / priceScale).
func ClaimX(courtSlug string, claimID uint64) int64 {
	return claimX(mustCourt(courtSlug), claimID)
}

// TrailingOI is the flash-resistant open interest X̄ over the given window, and
// whether the ring is mature enough to trust — a caller gating a vote or an answer
// on it MUST require mature (the twap contract). window is in blocks.
func TrailingOI(courtSlug string, claimID uint64, window int64) (avg int64, mature bool) {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	return cs.oi.Average(runtime.ChainHeight(), window)
}

// OIStaleBy is how far the current height has drifted from the claim's last
// open-interest observation — a flash-sensitive read should require this small.
func OIStaleBy(courtSlug string, claimID uint64) int64 {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	return cs.oi.StaleBy(runtime.ChainHeight())
}
