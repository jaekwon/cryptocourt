package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// THE ZERO BASE, which is the one arming guard this suite CAN reach. testclock.gno's
// own scope note is right that the virgin arming path is unreachable here — some
// earlier test has always created a court — but EnableTestClockAt checks its argument
// BEFORE calling EnableTestClock, so its two argument guards run in this suite even
// though the arming behind them cannot.
//
// Zero matters more than a negative does. tcNow asserts a positive instant on EVERY
// read, so a zero base does not fail the transaction that set it — it fails every
// later read of every date in the realm, which is the "loud brick" the maxBase comment
// describes from the other end of the range. TestClockNeverReadsTheZeroSentinel covers
// what the clock does with a zero it already holds; this covers refusing to take one.
//
// Asserted on the MESSAGE, and that is the whole method here: with `base <= 0` widened
// to `base < 0` a zero sails past this guard and the call still aborts — from the court
// check inside EnableTestClock, with a completely different complaint. A test that only
// asked "does it abort" would pass on the mutant.
func TestADeclaredBaseOfZeroIsRefusedByItsOwnGuard(cur realm, t *testing.T) {
	deployer := testutils.TestAddress("tcb-deployer")
	resetTestClock(deployer)
	// A COURT OF OUR OWN, and the reason is a fixture dependence I walked into: the
	// first version leaned on testclock.gno's scope note ("some earlier test has
	// always created a court") for its pairing half, so it passed in the full suite
	// and FAILED run alone — with only this test running the realm really is virgin,
	// EnableTestClockAt SUCCEEDS, and the assertion that it be refused is false.
	// Creating the court here makes the count arm deterministic, and it turns out to
	// make that arm reachable from this suite at all, which the scope note did not
	// claim: what is unreachable here is a SUCCESSFUL arming, not the refusal.
	testCourt(cur, "tcb", testutils.TestAddress("tcb-alice"), 1_000_000)

	testing.SetRealm(testing.NewUserRealm(deployer))
	uassert.AbortsContains(t, cur, "must be a positive instant", func() {
		EnableTestClockAt(cross(cur), 0)
	})
	testing.SetRealm(testing.NewUserRealm(deployer))
	uassert.AbortsContains(t, cur, "must be a positive instant", func() {
		EnableTestClockAt(cross(cur), -1)
	})

	// PAIRED, and the pairing is what makes the two above about the ARGUMENT: a
	// perfectly good base gets PAST both argument guards and is refused further in,
	// by the court count, with its own message.
	testing.SetRealm(testing.NewUserRealm(deployer))
	uassert.AbortsContains(t, cur, "already has courts", func() {
		EnableTestClockAt(cross(cur), 1_750_000_000)
	})
	// And 2100 exactly is inside the range, so it too reaches the court check.
	testing.SetRealm(testing.NewUserRealm(deployer))
	uassert.AbortsContains(t, cur, "already has courts", func() {
		EnableTestClockAt(cross(cur), maxBase)
	})
	// One second later is not.
	testing.SetRealm(testing.NewUserRealm(deployer))
	uassert.AbortsContains(t, cur, "before 2100", func() {
		EnableTestClockAt(cross(cur), maxBase+1)
	})
}
