package kourtv2

import "testing"

// THE META COURT'S WEEKLY EMISSION BUDGET, pinned at the only moment it is still
// the number the source declares. This file is named to sort FIRST for that
// reason, and the reason is measured rather than assumed.
//
// metaWeeklyBudget is a money constant with no row and no symbolic test
// reference, which are the two ways a change to it could have been noticed, and
// both were absent. The obvious fixture — advance the emission clock a week and
// compare what was minted against the budget — CANNOT be written anywhere later
// in this suite, and it is worth recording exactly why, because the KNOWN-GAPS
// note used to propose it:
//
//   - THE BUDGET IS GONE BY THEN. absBudget steps down by stepDownNum/stepDownDen
//     on every period roll, and the meta court is a realm-init singleton shared by
//     every test in the package. Measured from a test that sorts last, it reads
//     90_486_461 — about fourteen step-downs — so no late test can name the
//     shipped figure at all.
//   - THE CLOCK IS FROZEN BY THEN. A skip of a full period followed by Poke moved
//     neither cumAccrual nor absBudget, because an earlier test arms the test
//     clock and heightNow() stops tracking the chain.
//   - AND META EMITS NOTHING ON A FRESH DEPLOY, so the mirror-image fixture in a
//     filetest is no better: rollPeriod leaves curPeriodBudget at 0 while supply
//     is 0, the filetests here cannot advance height, and no exported reader
//     returns the budget.
//
// So this is a calibration pin, the same shape as
// TestDefaultParamsAreTheCalibratedValues and for the same reason: the number is
// a policy, the expectation is a LITERAL, and a deliberate change is expected to
// edit the pin in the same commit. What it does NOT assert is the emission
// arithmetic downstream of the budget; that is covered by the rows on accrual and
// open the rewards, which do not depend on this figure's value.
func TestTheMetaCourtsWeeklyBudgetIsTheCalibratedValue(t *testing.T) {
	c := mustCourt(metaSlug)
	const wantBudget = int64(100_000_000) // 100 CC/week (§13.8), before any step-down
	if got := c.absBudget; got != wantBudget {
		t.Errorf("the meta court's weekly budget is %d, the design says %d — if that "+
			"change is deliberate, edit this pin in the same commit. If it is NOT, a "+
			"test file sorting before this one has rolled meta's emission and this "+
			"pin can no longer see the shipped figure", got, wantBudget)
	}
	// No second arm here on purpose. The pairing this rule usually asks for — an
	// ordinary court, which must carry NO absolute budget — cannot be built in a file
	// that sorts first without putting a court into the directory that every later
	// test then sees, and the directory's ordering and counts are themselves asserted
	// elsewhere. The meta-only branch in startCourt is covered by the rows on it.
}
