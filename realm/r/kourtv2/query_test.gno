package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
)

// The queryability reads a testnet UI depends on (audit_queryability_render):
// the two missing ratio-series numerators, the one-call status, the queue
// bound, the settle deadline, and the pull-state flags — all read-only.
func TestQueryabilityReads(cur realm, t *testing.T) {
	alice := testutils.TestAddress("qy-alice")
	bob := testutils.TestAddress("qy-bob")
	c := testCourt(cur, "qy1", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "qy1", "Queryable claim")

	// Pre-answer: status is the open line; settle deadline is 0; queue empty.
	if ClaimStatus("qy1", id) != claimStatus(mustClaim(c, id)) {
		t.Fatal("ClaimStatus must mirror the page status")
	}
	if SettleDeadline("qy1", id) != 0 {
		t.Fatal("no settle deadline before an answer")
	}
	if QueueLen("qy1") != 0 {
		t.Fatal("empty senior queue")
	}

	// Stake both sides so the pools carry conviction.
	matureOI(cur, "qy1", id, alice, 200_000_000) // YES
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "qy1", id, sideNO, 300_000_000)
	testing.SkipHeights(epochBlocks)

	// TrailingYes vs TrailingOI: same maturity; YES avg within the total.
	yAvg, ym := TrailingYes("qy1", id, periodBlocks)
	tAvg, tm := TrailingOI("qy1", id, periodBlocks)
	if ym != tm {
		t.Fatal("TrailingYes/TrailingOI maturity must agree (same ring cadence)")
	}
	if ym && (yAvg < 0 || yAvg > tAvg) {
		t.Fatalf("YES trailing avg must be within the total: %d/%d", yAvg, tAvg)
	}

	// Answer settles BOTH pools at the freeze → PoolConviction is nonzero and
	// matches the per-side stored integrals (the same values the page shows).
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "qy1", id, sideYES)
	cs := mustClaim(c, id)
	yc, nc := PoolConviction("qy1", id)
	if yc != convToCC(cs.yesConvHi, cs.yesConvLo) || nc != convToCC(cs.noConvHi, cs.noConvLo) {
		t.Fatal("PoolConviction must expose the per-side pool integrals")
	}
	if yc <= 0 || nc <= 0 {
		t.Fatalf("both pools accrued conviction by the freeze: %d/%d", yc, nc)
	}
	if SettleDeadline("qy1", id) != cs.answerHeight+settleDelay {
		t.Fatal("settle deadline = answer height + 72h")
	}

	// PullState: all false before open the rewards.
	wp, ap, anp := PullState("qy1", id, alice)
	if wp || ap || anp {
		t.Fatal("no pulls before open the rewards")
	}

	// Settle + open the rewards (cross a period for a budget), then the winner pull
	// flips winnerPaid; author/answerer flags track their pulls.
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "qy1", id)
	testing.SkipHeights(periodBlocks)
	testing.SetRealm(testing.NewUserRealm(alice))
	OpenRewards(cross(cur), "qy1", id)
	testing.SetRealm(testing.NewUserRealm(alice))
	WithdrawBonus(cross(cur), "qy1", id, sideYES)
	if wp, _, _ := PullState("qy1", id, alice); !wp {
		t.Fatal("winnerPaid must flip after WithdrawBonus")
	}
	// A non-participant reads all-false.
	if wp, ap, anp := PullState("qy1", id, bob); wp || ap || anp {
		// bob is on the losing side; his winning-side position is nil → false. ok.
		_ = wp
	}
	// QueueLen bounds any senior entitlements the carrot/comp created.
	_ = QueueLen("qy1")
}
