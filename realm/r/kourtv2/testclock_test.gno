package kourtv2

import (
	"strings"
	"testing"
	"time"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// The latch is the whole safety argument, so these tests attack it rather than
// demonstrate it: a stranger must not arm it, a used realm must not arm it, and
// nothing may reopen it once shut.

// testingTime is the block clock as the harness reports it, for tests that arm
// the latch by hand (the public path is covered by the filetest).
func testingTime() int64 { return time.Now().Unix() }

func resetTestClock(deployer address) {
	tcDeployer, tcArmed, tcSealed, tcSkew, tcBase, tcFloor = deployer, false, false, 0, 0, 0
	tcEverArmed, tcPeakSkew = false, 0
}

// NOTE ON SCOPE: every test in this package shares one realm, and by the time
// any of them runs, some earlier test has created a court — so the VIRGIN
// arming path cannot be reached from here at all. What these tests own is the
// guards and the semantics.
//
// Where the rest of that path lives, stated precisely because this note used to
// credit the filetest with all of it:
//
//   * z_testclock_filetest.gno reaches mustDeployer and no further. A filetest's
//     caller is never the realm's deployer, so the refusal IS the assertion and
//     the gates behind it are unreachable there too.
//   * kourtv2_usedrealm_seeded.txtar and kourtv2_usedrealm_coin.txtar are the
//     only places the usage gate FIRES, one per arm — a txtar is the one harness
//     where the deployer is the caller. It also RUNS, and passes, in
//     kourtv2_testclock.txtar where arming succeeds; that is not coverage of a
//     refusal. Measured: deleting either arm of
//     `m.nextID > 1 || m.coin.TotalSupply() > 0` survives the whole mutation
//     gate, because that gate runs THIS suite.

func TestTestClockSurvivesCourtCreation(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tc-alice")
	bob := testutils.TestAddress("tc-bob")
	resetTestClock(alice)
	tcArmed, tcBase, tcFloor = true, testingTime(), testingTime() // a fresh scenario chain

	// A claim whose settle window is days away — the case no integration test
	// could reach by waiting.
	c := testCourt(cur, "tc1", alice, 50_000_000_000)
	c.coin.Mint(bob, 20_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "tc1", "Can a test walk a 72-hour window?")
	Stake(cross(cur), "tc1", id, sideYES, 9_000_000_000)
	cs := mustClaim(c, id)
	touch(c)
	cs.frozenAt = testingHeight()
	cs.rateAccAtFreeze = c.rateAccFP
	cs.answerHeight = testingHeight()
	cs.answeredAtTime = nowTime()
	cs.answer = sideYES
	cs.answerer = bob

	// Creating a court must NOT disarm it: seeding a court and then advancing
	// time is the whole purpose, and the implicit seal also threw already-written
	// stamps into the future (audit HIGH-4).
	if !TestClockActive() {
		t.Error("starting a court must not disarm the test clock")
	}
}

// Arming BEFORE any court, then advancing, must carry a claim past a deadline
// without a single block of waiting.
func TestTestClockCarriesAClaimPastItsDeadline(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tc-c")
	bob := testutils.TestAddress("tc-d")
	resetTestClock(alice)
	tcArmed, tcBase, tcFloor = true, testingTime(), testingTime() // armed at deploy
	c := testCourt(cur, "tc2", alice, 50_000_000_000)
	// StartCourt leaves the clock alone now; the scenario stays armed.
	c.coin.Mint(bob, 20_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "tc2", "Does the skew move a real gate?")
	Stake(cross(cur), "tc2", id, sideYES, 9_000_000_000)
	cs := mustClaim(c, id)
	testing.SkipHeights(10)
	touch(c)
	cs.frozenAt = testingHeight()
	cs.rateAccAtFreeze = c.rateAccFP
	cs.answerHeight = testingHeight()
	cs.answeredAtTime = nowTime()
	cs.answer = sideYES
	cs.answerer = bob

	// Not yet: the settle window has not passed on any clock.
	uassert.AbortsContains(t, cur, "has not aged", func() {
		SettleUndisputed(cross(cur), "tc2", id)
	})

	// 72 hours in one transaction, no blocks waited.
	testing.SetRealm(testing.NewUserRealm(alice))
	AdvanceTestClock(cross(cur), 72*3600+1)
	SettleUndisputed(cross(cur), "tc2", id)
	if cs.verdictAt == 0 {
		t.Fatal("the advance should have carried the claim past its settle window")
	}
	// And the record's own stamp reflects the skewed clock, consistently.
	if cs.verdictAtTime < cs.answeredAtTime+72*3600 {
		t.Error("the verdict stamp must sit past the window it waited out")
	}
}

func TestTestClockRefusesStrangersAndBackwardsTime(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tc-e")
	mallory := testutils.TestAddress("tc-m")
	resetTestClock(alice)

	// A stranger cannot arm it, even on a virgin realm — the race a public
	// chain would otherwise lose.
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsContains(t, cur, "only the deployer", func() {
		EnableTestClock(cross(cur))
	})
	if TestClockActive() {
		t.Fatal("a stranger armed the clock")
	}
	// A stranger is refused as a stranger — before learning anything about the
	// latch's state (audit LOW-2: the reverse order was free reconnaissance).
	uassert.AbortsContains(t, cur, "only the deployer", func() {
		AdvanceTestClock(cross(cur), 60)
	})
	// Nor seal it.
	uassert.AbortsContains(t, cur, "only the deployer", func() {
		SealTestClock(cross(cur))
	})

	// Armed (the filetest covers the arming path); time only moves forward.
	testing.SetRealm(testing.NewUserRealm(alice))
	tcArmed, tcBase, tcFloor = true, testingTime(), testingTime()
	uassert.AbortsContains(t, cur, "moves forward", func() {
		AdvanceTestClock(cross(cur), -3600)
	})
	uassert.AbortsContains(t, cur, "moves forward", func() {
		AdvanceTestClock(cross(cur), 0)
	})
	before := TestClockSkew()
	AdvanceTestClock(cross(cur), 3600)
	if TestClockSkew() != before+3600 {
		t.Error("the skew must accumulate")
	}

	// Sealing is one-way, and it takes the skew with it.
	SealTestClock(cross(cur))
	if TestClockActive() || TestClockSkew() != 0 {
		t.Error("sealing must disarm and zero the skew")
	}
	uassert.AbortsContains(t, cur, "sealed", func() {
		EnableTestClock(cross(cur))
	})
}

// A realm that already carries courts is not virgin, whoever asks.
func TestTestClockRefusesAUsedRealm(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tc-f")
	resetTestClock(alice)
	_ = testCourt(cur, "tc3", alice, 1_000_000_000) // uses the realm
	tcSealed = false                                // even with the seal cleared by hand,
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "already has courts", func() {
		EnableTestClock(cross(cur)) // the court count still refuses
	})
}

// ------------------------------------------------------------ audit fixes --

// HIGH-1: arming must not hand the wheel to the world. Only the deployer may
// advance an ARMED clock — the first draft checked nothing here, and a proof
// showed a stranger maturing every deadline in the realm with one call.
func TestAdvanceIsDeployerOnlyWhileArmed(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tc-g")
	mallory := testutils.TestAddress("tc-h")
	resetTestClock(alice)
	tcArmed, tcBase, tcFloor = true, testingTime(), testingTime()

	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsContains(t, cur, "only the deployer", func() {
		AdvanceTestClock(cross(cur), 7257600)
	})
	if TestClockSkew() != 0 {
		t.Error("a stranger moved an armed clock")
	}
}

// HIGH-3: two maximal "forward" steps wrapped int64 and walked the clock
// BACKWARDS. Both the step and the running total are capped now.
func TestAdvanceCannotWrapTheClockBackwards(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tc-i")
	resetTestClock(alice)
	tcArmed, tcBase, tcFloor = true, testingTime(), testingTime()
	testing.SetRealm(testing.NewUserRealm(alice))

	maxI64 := int64(9223372036854775807)
	uassert.AbortsContains(t, cur, "at most ten years", func() {
		AdvanceTestClock(cross(cur), maxI64)
	})
	// Walk to the ceiling in legal steps; the one that would cross it is refused.
	for i := 0; i < 10; i++ {
		AdvanceTestClock(cross(cur), maxAdvanceStep)
	}
	uassert.AbortsContains(t, cur, "as far as it may", func() {
		AdvanceTestClock(cross(cur), maxAdvanceStep)
	})
	if tcNow() <= tcBase {
		t.Error("the clock must never end up at or below where it started")
	}
}

// HIGH-4: sealing used to zero the base, so stamps written under a long advance
// landed in the FUTURE and reopened windows that had expired. The floor keeps
// them in the past.
func TestSealingNeverRewindsBelowWhatWasShown(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tc-j")
	resetTestClock(alice)
	tcArmed, tcBase, tcFloor = true, testingTime(), testingTime()
	testing.SetRealm(testing.NewUserRealm(alice))
	AdvanceTestClock(cross(cur), maxAdvanceStep) // ten years out

	stamped := nowTime() // what a claim would have recorded
	SealTestClock(cross(cur))
	if after := nowTime(); after < stamped {
		t.Errorf("sealing rewound the clock: stamp %d, now %d", stamped, after)
	}
	if TestClockActive() {
		t.Error("sealing must disarm")
	}
}

// MEDIUM-1: the zero instant is clock.gno's "this claim predates the stamps"
// sentinel. The clock must never hand it out.
func TestClockNeverReadsTheZeroSentinel(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tc-k")
	resetTestClock(alice)
	tcArmed, tcBase, tcFloor = true, 1, 1
	if nowTime() <= 0 {
		t.Fatal("nowTime() handed out a non-positive instant")
	}
	tcArmed, tcBase, tcSkew, tcFloor = false, 0, 0, 0
	if nowTime() <= 0 {
		t.Fatal("the unarmed clock handed out a non-positive instant")
	}
}

// The disclosure has to outlive the capability. Sealing clears every driving
// flag, and an earlier version cleared the disclosure with them: a chain full of
// invented dates then reported a perfectly clean clock, which is the exact
// moment a reader is most likely to trust a fabricated date. Found by seeding a
// real node and querying it after the seal, not in review.
func TestSealingKeepsTheDisclosure(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tc-seal-disc")
	resetTestClock(alice)
	tcArmed, tcEverArmed, tcBase, tcFloor = true, true, testingTime(), testingTime()
	testing.SetRealm(testing.NewUserRealm(alice))
	AdvanceTestClock(cross(cur), 7257600) // twelve weeks, as the smoke scenario does

	if !TestClockFabricated() {
		t.Fatal("an armed clock must report fabricated dates")
	}
	SealTestClock(cross(cur))

	if TestClockActive() {
		t.Error("sealing must remove the capability")
	}
	if !TestClockFabricated() {
		t.Error("sealing must NOT remove the disclosure — the dates stay invented")
	}
	if got := TestClockPeakSkew(); got != 7257600 {
		t.Errorf("peak skew must survive sealing: want 7257600, got %d", got)
	}
	if TestClockSkew() != 0 {
		t.Error("current skew must be zero once sealed — nothing is being driven")
	}
	if b := testClockBanner(); b == "" {
		t.Error("a sealed test chain must still render its banner")
	} else if !strings.Contains(b, "sealed") || !strings.Contains(b, "fabricated") {
		t.Errorf("the sealed banner must say both sealed and fabricated: %q", b)
	}
}

// Peak skew is a high-water mark, not a running total that sealing resets.
func TestPeakSkewTracksTheFurthestAdvance(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tc-peak")
	resetTestClock(alice)
	tcArmed, tcEverArmed, tcBase, tcFloor = true, true, testingTime(), testingTime()
	testing.SetRealm(testing.NewUserRealm(alice))
	AdvanceTestClock(cross(cur), 3600)
	AdvanceTestClock(cross(cur), 7200)
	if got := TestClockPeakSkew(); got != 10800 {
		t.Errorf("peak must accumulate with the clock: want 10800, got %d", got)
	}
	if TestClockSkew() != 10800 {
		t.Error("while armed, skew and peak agree")
	}
}

// A base near int64's ceiling is refused where it is DECLARED, not discovered
// later by a clock that has stopped answering.
//
// Found by mutation, not review: deleting tcNow's `n <= 0` assertion survived
// the whole corpus, which is a fair verdict only if nothing can reach it. Nothing
// could, through AdvanceTestClock — its two caps hold the SKEW to a century. But
// EnableTestClockAt took any positive base, and a base within that century of the
// ceiling makes tcBase+tcSkew wrap negative on a step that is individually legal.
// The assertion then fires on every read for ever: no date, no Render, no State.
// A test chain that cannot be read is not more honest than one that refuses the
// arming, so maxBase refuses the arming.
func TestABaseTooFarOutIsRefusedRatherThanBricking(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tc-maxbase")
	// The latch is hand-written below and a bare nowTime() is read afterwards. On
	// any failure path that read aborts, this test dies before its own cleanup and
	// the NEXT test in package order inherits an armed clock it never asked for.
	// Measured: under the maxBase mutation row this file's failure also failed
	// zerostamp_test.gno, so the row scored on a cascade rather than on the
	// assertion written for it.
	defer resetTestClock(alice)
	// Make the realm deterministically NON-virgin first. Run alone, this test is
	// otherwise the first thing to touch the realm and the arming below succeeds;
	// leaning on a neighbour's court instead made it pass only in company, which
	// is a test reporting on its neighbours' state.
	resetTestClock(alice)
	_ = testCourt(cur, "tcmb", alice, 1_000_000_000)
	resetTestClock(alice) // clears whatever the court creation left on the latch
	testing.SetRealm(testing.NewUserRealm(alice))

	// The base checks sit behind mustDeployer and ahead of the court and pristine
	// gates, so alice — who IS tcDeployer after resetTestClock — reaches them while
	// the arming itself stays out of reach in this suite. Delete either check and
	// the call aborts with a gate BEHIND it instead: a different message, so both
	// rows stay killable.
	maxI64 := int64(9223372036854775807)
	uassert.AbortsContains(t, cur, "before 2100", func() {
		EnableTestClockAt(cross(cur), maxI64)
	})
	uassert.AbortsContains(t, cur, "before 2100", func() {
		EnableTestClockAt(cross(cur), maxBase+1)
	})
	// The operator error a purely arithmetic cap accepts in silence: a base in
	// MILLISECONDS. It wraps nothing — it simply publishes every date in the year
	// 57438 — so nothing downstream would ever have caught it, and the cap refuses
	// it only by being a real date.
	uassert.AbortsContains(t, cur, "before 2100", func() {
		EnableTestClockAt(cross(cur), 1750000000000)
	})
	// maxBase itself is the last ACCEPTABLE base and must clear the ceiling: it
	// reaches the gate BEHIND the ceiling and is refused by that instead. The
	// message is the assertion — "it aborted" would hold for either reason.
	uassert.AbortsContains(t, cur, "already has courts", func() {
		EnableTestClockAt(cross(cur), maxBase)
	})

	// Arm AT the cap — by hand, since the public path cannot reach a virgin realm
	// here — spend the entire advance budget, then check the property an ARITHMETIC
	// cap got WRONG. maxInt64-maxAdvanceTotal was "exactly wide enough" for
	// tcBase+tcSkew and left tcNow returning exactly maxInt64: no wrap, no abort.
	// What wrapped was the addition every CONSUMER performs on that result, so a
	// claim opened in that block was born past its 12-week timeout — unanswerable,
	// closeable by anyone for a deposit refund, publishing a negative settle stamp.
	// A loud brick traded for silent mis-gating, which is worse.
	//
	// Asserted on the helpers rather than by opening a claim: they are what every
	// gate in the realm calls, and a claim's openedAtTime is nowTime() anyway.
	// `tcNow() > maxBase` was the assertion here first and it was VACUOUS — a
	// wrapped sum aborts inside tcNow, so the comparison could never be the thing
	// that failed.
	resetTestClock(alice)
	tcArmed, tcBase, tcFloor = true, maxBase, maxBase
	testing.SetRealm(testing.NewUserRealm(alice))
	for i := 0; i < 10; i++ {
		AdvanceTestClock(cross(cur), maxAdvanceStep)
	}
	if TestClockSkew() != maxAdvanceTotal {
		t.Errorf("the whole budget must fit above the cap: want %d, got %d",
			maxAdvanceTotal, TestClockSkew())
	}
	stamp := nowTime()
	if got := deadlineTime(stamp, deadClaimSecs); got <= stamp {
		t.Errorf("a deadline stamped at the cap must lie in the future: stamp %d, "+
			"deadline %d", stamp, got)
	}
	if passed, known := pastDeadline(stamp, deadClaimSecs); passed || !known {
		t.Errorf("a claim opened at the cap must not already be past its 12-week "+
			"timeout: passed=%t known=%t", passed, known)
	}

	// And the assertion the cap makes unreachable still works, because a future
	// entrypoint could reintroduce the state some other way. Both boundaries: the
	// negative sum the old bug produced, and ZERO — worse than an abort, being
	// clock.gno's "this claim predates the stamps" sentinel.
	resetTestClock(alice)
	tcArmed, tcBase, tcSkew = true, maxI64, 1
	uassert.PanicsContains(t, cur, "non-positive instant", func() { _ = tcNow() })
	resetTestClock(alice)
	tcArmed, tcBase, tcSkew = true, 0, 0
	uassert.PanicsContains(t, cur, "non-positive instant", func() { _ = tcNow() })
}
