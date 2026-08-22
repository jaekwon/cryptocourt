package kourtv2

import "testing"

// supersedeOrdered IS THE WHOLE ORDERING RULE, and neither of its two branches was
// pinned at its boundary. A sweep of every cap comparison in the realm left both
// surviving: narrowing either `>=` to `>` refuses a re-filing opened EXACTLY when the
// claim it re-files could have died.
//
// WHY THAT MATTERS RATHER THAN BEING A ROUNDING QUIBBLE. The rule exists so a
// re-filing cannot be back-dated ahead of the death it claims to follow — an edge
// asserting "this replaces that dead claim" when the claim was still live. The
// deadline is 12 weeks. At exactly 12 weeks the claim CAN have died (deadClaimTimeout
// is the same 12 weeks on the height clock), so the re-filing is legitimate and the
// realm must accept it. Refusing it makes the earliest legal re-filing arrive one
// second, or one block, later than the design says — invisible except to whoever
// files at the boundary and is told their claim is too early.
//
// TESTED DIRECTLY, because supersedeOrdered is a pure function of two claimStates and
// the boundary is arithmetic on two fields. Driving it through SupersedeClaim would
// need a court, two claims, a death and a clock wound forward 12 weeks, all to reach
// the same comparison; the existing SupersedeClaim tests already cover that path's
// authority and cap arms. What was missing is the last legal value, and this is where
// it lives.
//
// BOTH BRANCHES, because they are chosen by a condition rather than run together:
// the time clock is used only when BOTH claims carry an openedAtTime, and the height
// fallback covers pre-upgrade claims that do not. A test of one leaves the other's
// arithmetic free — and it is the same off-by-one in both.
func TestARefilingIsLegalExactlyAtTheDeathDeadline(t *testing.T) {
	// THE TIME BRANCH: both sides carry a wall-clock stamp.
	to := &claimState{openedAtTime: 1_000_000, openedAt: 500}
	atCap := &claimState{openedAtTime: 1_000_000 + deadClaimSecs, openedAt: 500}
	under := &claimState{openedAtTime: 1_000_000 + deadClaimSecs - 1, openedAt: 500}

	if !supersedeOrdered(atCap, to) {
		t.Fatalf("a re-filing opened exactly %d seconds after the claim it re-files "+
			"is legal — that is when the claim could have died", deadClaimSecs)
	}
	if supersedeOrdered(under, to) {
		t.Fatal("one second before the deadline the claim could not yet have died, " +
			"so the re-filing must be refused")
	}

	// THE HEIGHT FALLBACK: `to` has no wall-clock stamp, so the condition is false
	// and the comparison moves to openedAt. The fixture asserts that it really did
	// take this branch — if both sides carried a time the arm above would run twice
	// and this one never.
	hTo := &claimState{openedAt: 1_000}
	hAt := &claimState{openedAt: 1_000 + deadClaimTimeout, openedAtTime: 9}
	hUnder := &claimState{openedAt: 1_000 + deadClaimTimeout - 1, openedAtTime: 9}
	if hTo.openedAtTime != 0 {
		t.Fatal("setup: the height branch is only reached when a side has no " +
			"openedAtTime")
	}
	if !supersedeOrdered(hAt, hTo) {
		t.Fatalf("on the height clock a re-filing exactly %d blocks later is legal",
			deadClaimTimeout)
	}
	if supersedeOrdered(hUnder, hTo) {
		t.Fatal("one block before the height deadline the re-filing must be refused")
	}

	// AND THE BRANCH CHOICE ITSELF: with both stamps present the time clock decides,
	// so a pair that clears the height deadline but not the time one is refused.
	// Without this, moving the condition to `||` would go unnoticed.
	mixed := &claimState{openedAtTime: 1_000_001, openedAt: 500 + deadClaimTimeout}
	if supersedeOrdered(mixed, to) {
		t.Fatal("both sides carry a time stamp, so the time clock decides and one " +
			"second is not twelve weeks")
	}
}
