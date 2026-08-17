// Buy: the one-way bonding curve, V2 disposition — the GNOT is BURNED (PLAN
// §3.7). No treasury exists, nothing ever redeems, and no "backing" figure is
// read or rendered: CC is participation, not a claim on assets.
package courtv2

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
)

const gnotDenom = "ugnot"

// burnSinkPath derives the keyless burn address (pin P14): a sub-realm
// identity of THIS realm that is never created. Only courtv2 itself could ever
// instantiate it (realm.Sub is parent-only), and it never does — so no key,
// no code, no path to the coins, ever.
const burnSinkPath = "gno.land/r/cryptocourt/courtv2:burned"

// Buy mints CC for GNOT on the one-way curve and burns the GNOT. Returns the
// CC minted; the unspent remainder of the payment is refunded. The curve is
// the only GNOT-side mint and its position is monotonic — the same stretch is
// never sold twice.
func Buy(cur realm, slug string) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	// Payment auth (V1 AUDIT.md obligation, unchanged): a DIRECT user call —
	// IsUserCall, not IsUser, so a maketx-run ephemeral realm cannot pre-consume
	// the coin envelope. Reading unsafe.OriginSend under IsCurrent+IsUserCall is
	// the sanctioned inbound-payment pattern (what AGENTS.md flags is
	// unsafe.PreviousRealm, not this).
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("courtv2: a buy must be a direct user call")
	}
	buyer := prev.Address()

	c := mustCourt(slug)
	if buyer == cur.Address() {
		panic("courtv2: the court's own address may not buy")
	}
	touch(c)

	sent := unsafe.OriginSend().AmountOf(gnotDenom)
	if sent <= 0 {
		panic("courtv2: send GNOT to buy the coin")
	}

	delta, spent := c.crv.Minted(c.minted, sent)
	if delta <= 0 {
		// Aborting reverts the incoming send — the buyer keeps their GNOT.
		panic("courtv2: payment too small to mint a coin")
	}
	c.minted += delta // monotonic curve position
	c.coin.Mint(buyer, delta)
	// Track cumulative GNOT burned into this court and keep the directory's
	// burn-ordered index in step. Burned GNOT is the one un-sybil-able signal a
	// court can accrue — you cannot fake having burned real money — which is why
	// the front page ranks on it (MODERATION.md §3.2). Render-layer only: no
	// money path reads the index.
	reindexBurn(c, spent)
	// Accrue this burn toward the buyer's appeals-layer weight (meta.gno). It
	// only ACCRUES — nothing is minted until the buyer claims — so meta's supply
	// tracks the engaged electorate rather than every passerby.
	accrueFranchise(c, buyer, spent)

	// BURN the spent GNOT: send it to the keyless sink. Verifiable on-chain;
	// never described as a scarcity feature (§7.4 / Munchee).
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), chain.PackageAddress(burnSinkPath),
		chain.Coins{chain.NewCoin(gnotDenom, spent)})

	if r := sent - spent; r > 0 {
		b.SendCoins(cur.Address(), buyer, chain.Coins{chain.NewCoin(gnotDenom, r)})
	}
	return delta
}

// -------------------------------------------------------------------- reads --

// CurvePosition is the monotonic total ever minted by the curve (emission
// mints separately — see EmittedTotal).
func CurvePosition(slug string) int64 { return mustCourt(slug).minted }

// BurnSink is the keyless address the GNOT goes to — published so anyone can
// audit the burn against bank balances.
func BurnSink() address { return chain.PackageAddress(burnSinkPath) }

// BurnedGNOT is the sink's live balance — the audit read for the burn.
func BurnedGNOT() int64 {
	b := banker.NewReadonlyBanker()
	return b.GetCoins(chain.PackageAddress(burnSinkPath)).AmountOf(gnotDenom)
}

// CoinBalanceOf is who's court-coin balance (a value read).
func CoinBalanceOf(slug string, who address) int64 { return mustCourt(slug).coin.BalanceOf(who) }
