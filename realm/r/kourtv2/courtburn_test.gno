package kourtv2

import (
	"chain"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

/* NO CLOSURE WRAPS AN AUTHORIZED CALL IN THIS FILE, and that is a harness
   constraint rather than a style choice. The first version put every test body
   inside a withBurn(price, func(){...}) helper so the global price was always
   restored. Every authorized call inside it was then refused —
   SetCourtCreationBurn came back "only the global DAO admin prices court
   creation" while holding the admin's own address — and a probe reading
   cur.Previous() the same way panicked with "frame not found: cannot seek
   beyond origin caller override". testing.SetRealm's override does not reach a
   cross() made from inside a nested closure, so the caller the guard sees is
   not the one the fixture set.
   The price is therefore saved and restored with a plain defer at test scope,
   and every authorized call sits in the test body. uassert.AbortsContains still
   takes a closure, which is fine for REFUSALS; the one place an authorized call
   must also abort — the negative-amount arm — sets its caller INSIDE that
   closure, which does work.

   THE PRICE IS A PACKAGE GLOBAL. Gno test files in a package share one process,
   so a test that left the burn priced would make every other test's StartCourt
   demand a payment it does not send, and the failures would land far from here.
   Deferred rather than assigned at the end, so an abort still puts it back. */

// fund attaches `amt` µGNOT to the next call, funding the realm so the coins
// the banker moves actually exist: IssueCoins puts them in the realm's account,
// SetOriginSend declares them as the envelope.
//
// IT DELIBERATELY DOES NOT SET THE CALLER. An earlier version did, and every
// paid StartCourt then failed "must be a direct user call": testing.SetRealm's
// override does not survive the helper's RETURN, so by the time the test made
// its cross() the caller was no longer the user. buy_test.gno's fundAndBuy sets
// the caller too, but it also makes its call inside itself — same frame, so it
// works there and cannot work here. Every caller in this file is therefore set
// on the line before the call it applies to.
func fund(amt int64) {
	testing.IssueCoins(chain.PackageAddress(realmPath),
		chain.Coins{{Denom: "ugnot", Amount: amt}})
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: amt}})
}

// THE DEFAULT IS OFF, and this is the arm that keeps it that way. The whole
// argument for shipping zero is that a court can still be opened by anyone,
// including another realm, exactly as before — so if a future edit gives the
// constant a value, this fails first and names the promise that broke.
func TestCourtCreationBurnShipsOff(cur realm, t *testing.T) {
	if courtCreationBurnInit != 0 {
		t.Fatalf("the shipped default must be off, got %d", courtCreationBurnInit)
	}
	prev := courtCreationBurn
	defer func() { courtCreationBurn = prev }()
	courtCreationBurn = 0

	alice := testutils.TestAddress("ccb-off")
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(alice))
	// No payment attached, and none demanded.
	StartCourt(cross(cur), "ccb1", "Free Court")
	if !Exists("ccb1") {
		t.Fatal("an unpriced court must open with no payment attached")
	}
	// AND IT IS STILL REALM-CALLABLE, which is the property v0.8.2 chose and
	// the reason the off path returns BEFORE the IsUserCall check rather than
	// after it. A code realm cannot make a user call, so if that guard ever
	// moves above the price check, this is what catches it.
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/kourt/notacourt"))
	StartCourt(cross(cur), "ccb2", "Realm Court")
	if !Exists("ccb2") {
		t.Fatal("an unpriced court must be openable by another realm")
	}
}

func TestSetCourtCreationBurnIsAdminOnly(cur realm, t *testing.T) {
	prev := courtCreationBurn
	defer func() { courtCreationBurn = prev }()
	courtCreationBurn = 0

	// A COURT MUST EXIST FIRST, and this test used to assume one did. Run on its
	// own it panicked "no court exists yet; the global DAO has no admin":
	// ensureGlobalDAO builds from directoryAdmin, which the FIRST StartCourt in
	// the package sets, so the fixture was silently depending on another test
	// file having run before it. Opening one here makes the test true alone.
	maker := testutils.TestAddress("ccb-maker")
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(maker))
	if !Exists("ccb0") {
		StartCourt(cross(cur), "ccb0", "Admin Fixture Court")
	}

	// READ FROM THE GATE'S OWN SOURCE. ensureGlobalDAO().admin is the field the
	// guard compares against; DirectoryAdmin() is a different read that only
	// happens to agree, and a literal address would pass or fail depending on
	// which test file created the first court.
	admin := ensureGlobalDAO().admin
	stranger := testutils.TestAddress("ccb-stranger")
	if stranger == admin {
		t.Fatal("the fixture needs a non-admin address")
	}

	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "only the global DAO admin", func() {
		SetCourtCreationBurn(cross(cur), 5_000_000)
	})
	if CourtCreationBurn() != 0 {
		t.Fatal("a refused call must not move the price")
	}

	// THE NEGATIVE PRICE, tested through mustSanePrice rather than through the
	// setter. An admin call that must abort cannot be written as an abort
	// assertion here: the caller override does not survive into the closure, so
	// the admin arrives as somebody else and the ADMIN guard fires first. The
	// value check is therefore its own function in courtburn.gno, which needs
	// no caller — see the note there. This does mean the arm does not prove the
	// setter CALLS it; that is what the next-to-last check in this test does,
	// by reading the price back after a legal set.
	// PanicsContains, not AbortsContains, and the difference is real: an ABORT
	// is what a crossing call raises, and mustSanePrice is a plain in-package
	// function, so its panic escaped the abort assertion and failed the test
	// outright inside mustSanePrice.
	uassert.PanicsContains(t, cur, "cannot be negative", func() {
		mustSanePrice(-1)
	})
	// And the sane side, so the arm is not just "it panics at something".
	uassert.NotPanics(t, cur, func() { mustSanePrice(0) })

	// THE CONTROL, and the only arm that proves the gate distinguishes callers:
	// the stranger arm above would pass for ANY non-admin caller, including a
	// fixture that failed to set one at all.
	testing.SetRealm(testing.NewUserRealm(admin))
	SetCourtCreationBurn(cross(cur), 5_000_000)
	if got := CourtCreationBurn(); got != 5_000_000 {
		t.Fatalf("the admin prices creation: %d", got)
	}
	// And zero turns it back off — the documented way to undo it.
	testing.SetRealm(testing.NewUserRealm(admin))
	SetCourtCreationBurn(cross(cur), 0)
	if got := CourtCreationBurn(); got != 0 {
		t.Fatalf("zero must turn the burn off: %d", got)
	}
}

// THE COIN ACTUALLY MOVES, measured by DIFFERENCING the sink rather than by
// reading an absolute: other tests in this package burn GNOT through Buy, so
// the sink's total is whatever they left it at and an equality against a
// literal would pass or fail on test ordering.
func TestCourtCreationBurnBurnsTheWholePayment(cur realm, t *testing.T) {
	const price = int64(3_000_000)
	prev := courtCreationBurn
	defer func() { courtCreationBurn = prev }()
	courtCreationBurn = price

	alice := testutils.TestAddress("ccb-pays")

	before := BurnedGNOT()
	fund(price)
	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourt(cross(cur), "ccb3", "Paid Court")
	testing.SetOriginSend(nil)
	if got := BurnedGNOT() - before; got != price {
		t.Fatalf("the sink must gain the payment: %d vs %d", got, price)
	}

	// NOT THE COURT'S OWN BURN. The directory ranks on burnedGNOT because that
	// figure is voluntary; a toll every court pays identically would be rank
	// noise. If this ever starts counting, the front page quietly changes
	// meaning, so it is asserted rather than left to a comment.
	if got := CourtBurnedGNOT("ccb3"); got != 0 {
		t.Fatalf("the creation burn is not the court's own burn: %d", got)
	}

	// A MINIMUM, NOT A PRICE WITH CHANGE: overpaying burns the overpayment too.
	// Watched at BOTH ends, because a sink that grew by the full payment is
	// still consistent with coin having gone back to the payer from somewhere
	// else — only the payer's balance rules out a refund, and a refund is the
	// behaviour check-nontransferable forbids.
	before = BurnedGNOT()
	payerBefore := ugnotOf(alice)
	fund(price*3)
	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourt(cross(cur), "ccb4", "Generous Court")
	testing.SetOriginSend(nil)
	if got := BurnedGNOT() - before; got != price*3 {
		t.Fatalf("the whole payment burns, not just the minimum: %d vs %d", got, price*3)
	}
	if got := ugnotOf(alice) - payerBefore; got != 0 {
		t.Fatalf("nothing is ever paid back out: the payer moved by %d", got)
	}
}

func TestCourtCreationBurnRefusesUnderpaymentAndNonUserCalls(cur realm, t *testing.T) {
	const price = int64(4_000_000)
	prev := courtCreationBurn
	defer func() { courtCreationBurn = prev }()
	courtCreationBurn = price

	alice := testutils.TestAddress("ccb-short")

	// UNDERPAYMENT NAMES BOTH FIGURES. A refusal that says only "not enough"
	// leaves the caller to work out the difference, which is the complaint that
	// rewrote the CC lock messages. Pinned as the whole sentence, including the
	// formatter's output, so a change to either number or to ugnotAmt's
	// trimming shows up here.
	fund(price-1)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "burns at least 4 GNOT, you sent 3.999999", func() {
		StartCourt(cross(cur), "ccb5", "Short Court")
	})
	testing.SetOriginSend(nil)
	if Exists("ccb5") {
		t.Fatal("a refused creation must not leave a court behind")
	}

	// A REALM CALLER IS REFUSED ONCE THE BURN IS PRICED — the mirror of the
	// off-path arm in the first test. Same payment, different caller kind.
	testing.IssueCoins(chain.PackageAddress(realmPath),
		chain.Coins{{Denom: "ugnot", Amount: price}})
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: price}})
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/kourt/notacourt"))
	uassert.AbortsContains(t, cur, "must be a direct user call", func() {
		StartCourt(cross(cur), "ccb6", "Realm Court")
	})
	testing.SetOriginSend(nil)

	// The control: the same payment from a USER call succeeds, so the guard
	// rejects the caller kind rather than the payment.
	fund(price)
	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourt(cross(cur), "ccb7", "Paid Court")
	testing.SetOriginSend(nil)
	if !Exists("ccb7") {
		t.Fatal("a user call paying the minimum must open the court")
	}
}

// StartCourtP charges too. It is a separate entrypoint with its own body, so
// "StartCourt is priced" says nothing about it — and an unpriced twin would be
// a free door standing beside the paid one.
func TestStartCourtPAlsoCharges(cur realm, t *testing.T) {
	const price = int64(2_000_000)
	prev := courtCreationBurn
	defer func() { courtCreationBurn = prev }()
	courtCreationBurn = price

	alice := testutils.TestAddress("ccb-p")

	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "burns at least", func() {
		StartCourtP(cross(cur), "ccb8", "Polished", 10)
	})

	before := BurnedGNOT()
	fund(price)
	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourtP(cross(cur), "ccb9", "Polished", 10)
	testing.SetOriginSend(nil)
	if got := BurnedGNOT() - before; got != price {
		t.Fatalf("StartCourtP burns the same minimum: %d vs %d", got, price)
	}
}
