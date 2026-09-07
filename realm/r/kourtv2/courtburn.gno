// The court-creation burn: a minimum GNOT payment, burned, to open a court.
//
// THIS REVERSES A RECORDED DECISION, so it says so rather than quietly
// contradicting it. MODERATION.md §13.5 logged "StartCourt creation fee —
// RESOLVED (v0.8.2): no GNOT fee", and the reasoning was sound: a fee written
// into the source as a constant cannot be sized, because GNOT has no on-chain
// USD oracle, so whatever number is chosen is wrong at some future price and
// nobody can tell when. Court-count floods were left to the per-byte storage
// deposit, which is protocol-set and reprices itself.
//
// WHAT CHANGES THE ANSWER is that this fee is not a constant. It is set by the
// global DAO admin, at whatever the price is on the day, and reset when that
// price moves — which is exactly the oracle the objection said was missing, in
// the form the objection did not consider: a human. The storage deposit still
// does its job; this sits on top for the case the deposit is too cheap to deter
// somebody who wants a hundred slugs.
//
// DEFAULT ZERO, WHICH IS OFF, and that is deliberate rather than unfinished.
// Zero preserves everything v0.8.2 was protecting: no unsizable number is
// baked into the source, and StartCourt stays realm-callable, because a realm
// cannot make a user call and a burn that demanded one would lock every realm
// out of court creation. Set it and the price applies from the next call; set
// it back to zero and the path is exactly what it was. The seed sets a non-zero
// value so the mechanism is visible on a live chain rather than only in tests.
//
// NOT COUNTED AS THE COURT'S BURN. reindexBurn/accrueFranchise are for GNOT a
// buyer chose to sink into a court's curve — the front page ranks on that
// figure precisely because it is voluntary and cannot be faked. A mandatory
// toll every court pays identically adds a constant to every row: it moves no
// ranking, means nothing about a court, and would make the directory's one
// un-sybil-able signal slightly less honest. So it goes to the sink and is
// counted only in the realm-wide BurnedGNOT total.
package kourtv2

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
)

// courtCreationBurnInit is the shipped default: zero, meaning no burn is
// required and StartCourt behaves exactly as it did before this file existed.
const courtCreationBurnInit = int64(0)

var courtCreationBurn = courtCreationBurnInit

// CourtCreationBurn is the µGNOT a new court currently costs to open. Zero
// means the burn is off. Published so a page can quote the price BEFORE the
// user signs a transaction that would otherwise panic on them.
func CourtCreationBurn() int64 { return courtCreationBurn }

// SetCourtCreationBurn prices court creation, in µGNOT. 0 turns the burn off.
//
// Gated on the global DAO admin, matching SetAssociationBondDefault — the two
// are the same kind of knob (a realm-wide default that prices a stranger's
// entry) and splitting their authority would be a distinction with no meaning.
// Not moderator-settable: a court's moderators govern THEIR court, and there is
// no court yet when this price is charged.
func SetCourtCreationBurn(cur realm, amount int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("kourtv2: only the global DAO admin prices court creation")
	}
	mustSanePrice(amount)
	courtCreationBurn = amount
}

// ugnotAmt writes µGNOT as a trimmed decimal, for a refusal a human can read.
//
// It defers to ccAmt because GNOT and CC carry the SAME six decimals, so the
// arithmetic is identical and a second copy of it would be a second thing to
// get wrong. The wrapper exists rather than a bare ccAmt call at the two sites
// so that the denomination is stated where the string is built: a message
// reading "burns 2.5" is a different promise depending on which coin it means.
func ugnotAmt(n int64) string { return ccAmt(n) }

// mustSanePrice refuses a price that cannot mean anything. Its own function
// rather than two lines inside the setter, because the harness cannot reach it
// otherwise: testing.SetRealm's caller override does not survive into the
// closure uassert.AbortsContains runs, so an ADMIN call that is supposed to
// abort cannot be expressed as an abort assertion — measured, not assumed, and
// the arm failed with "only the global DAO admin prices court creation" while
// holding the admin's own address. A pure value check needs no caller and no
// crossing, so lifting it out makes it directly testable while leaving the
// production order intact: authorize first, then validate.
func mustSanePrice(amount int64) {
	if amount < 0 {
		panic("kourtv2: a court-creation burn cannot be negative")
	}
}

// takeCourtCreationBurn collects the creation payment and burns ALL of it, so
// the configured figure is a floor and nothing is ever paid back out. It is
// called by the PUBLIC creation entrypoints only — realm init
// builds the meta court through startCourt directly, before a DAO, an admin or
// a bank balance exists, and charging it there would make the realm undeployable.
//
// THE GUARD IS IsUserCall, NOT IsUser, and the difference is the whole point:
// IsUser also admits a `maketx run` ephemeral realm, which can consume the
// origin-send envelope and call in with it already spent — so the check would
// pass while the coins were gone. Reading unsafe.OriginSend under
// IsCurrent + IsUserCall is the sanctioned inbound-payment shape, and it is the
// same one Buy uses twenty lines into buy.gno.
//
// `cur` is the crossing entrypoint's own realm value, so IsCurrent is checked
// here rather than assumed: this is a secondary realm parameter by the time it
// reaches this function, and a stale one would name the wrong caller.
func takeCourtCreationBurn(cur realm) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	price := courtCreationBurn
	if price <= 0 {
		// OFF. Nothing is read, nothing is required, and in particular no
		// IsUserCall check happens — that is what keeps StartCourt callable by
		// another realm while the burn is unpriced.
		return
	}
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("kourtv2: starting a court burns GNOT, so it must be a direct user call")
	}
	sent := unsafe.OriginSend().AmountOf(gnotDenom)
	if sent < price {
		// Named amounts, both of them: a refusal that does not say what was
		// wanted and what arrived leaves the caller to guess at the difference.
		panic("kourtv2: starting a court burns at least " + ugnotAmt(price) +
			" GNOT, you sent " + ugnotAmt(sent))
	}
	// THE WHOLE PAYMENT BURNS, and that is what makes this a MINIMUM rather
	// than a price with change.
	//
	// The first cut burned `price` and refunded the excess, copying Buy. That
	// version was wrong here, and check-nontransferable caught it: a refund is
	// GNOT LEAVING THE REALM TO A USER, which is the one thing this realm's
	// regulatory position rests on never happening ("the payment is burned,
	// nothing ever redeems" — REGULATIONS.md). Buy's remainder send is the sole
	// sanctioned exception and it exists because a bonding curve genuinely
	// cannot spend the last ugnot; there is no such arithmetic here.
	//
	// Burning all of it removes the refund instead of arguing for it, and the
	// semantics come out cleaner: send at least the minimum and all of it goes
	// to the keyless sink. Nobody is overcharged by surprise, because
	// CourtCreationBurn() publishes the figure and the page attaches exactly
	// it; a caller who deliberately sends more has deliberately burned more.
	// Aborting above reverts the incoming send, so a caller who underpays keeps
	// every coin; only from here does anything move.
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), chain.PackageAddress(burnSinkPath),
		chain.Coins{chain.NewCoin(gnotDenom, sent)})
}
