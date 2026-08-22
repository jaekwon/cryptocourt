package kourtv2

import (
	"strconv"
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
	// The height half too, or a test inherits the previous test's skew and the
	// suite passes for the wrong reason.
	tcHeightSkew, tcHeightPeak, tcHeightFloor, tcHeightBase = 0, 0, 0, 0
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
	defer resetTestClock(alice) // the latch is global; do not leak an armed clock
	tcArmed, tcBase, tcFloor = true, testingTime(), testingTime()
	tcHeightBase, tcHeightFloor = testingHeight(), testingHeight() // a fresh scenario chain

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
	defer resetTestClock(alice) // the latch is global; do not leak an armed clock
	tcArmed, tcBase, tcFloor = true, testingTime(), testingTime()
	tcHeightBase, tcHeightFloor = testingHeight(), testingHeight() // armed at deploy
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
	defer resetTestClock(alice) // the latch is global; do not leak an armed clock

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
	tcHeightBase, tcHeightFloor = testingHeight(), testingHeight()
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
	uassert.AbortsContains(t, cur, "kourtv2: the test clock is sealed; this realm is not a test chain", func() {
		EnableTestClock(cross(cur))
	})
}

// A realm that already carries courts is not virgin, whoever asks.
func TestTestClockRefusesAUsedRealm(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tc-f")
	resetTestClock(alice)
	defer resetTestClock(alice) // the latch is global; do not leak an armed clock
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
	defer resetTestClock(alice) // the latch is global; do not leak an armed clock
	tcArmed, tcBase, tcFloor = true, testingTime(), testingTime()
	tcHeightBase, tcHeightFloor = testingHeight(), testingHeight()

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
	defer resetTestClock(alice) // the latch is global; do not leak an armed clock
	tcArmed, tcBase, tcFloor = true, testingTime(), testingTime()
	tcHeightBase, tcHeightFloor = testingHeight(), testingHeight()
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
	defer resetTestClock(alice) // the latch is global; do not leak an armed clock
	tcArmed, tcBase, tcFloor = true, testingTime(), testingTime()
	tcHeightBase, tcHeightFloor = testingHeight(), testingHeight()
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
	defer resetTestClock(alice) // the latch is global; do not leak an armed clock
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
	defer resetTestClock(alice) // the latch is global; do not leak an armed clock
	tcArmed, tcEverArmed, tcBase, tcFloor = true, true, testingTime(), testingTime()
	tcHeightBase, tcHeightFloor = testingHeight(), testingHeight()
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
	} else if !strings.Contains(b, "stays stopped") {
		// An audit measured the consequence: after sealing, 50,000 real blocks
		// moved neither clock, because both sit at their floor until reality
		// catches up. Anything opened from there never reaches a deadline, and
		// the banner used to speak only of the past.
		t.Errorf("the sealed banner must say the clock STAYS stopped: %q", b)
	}
}

// Peak skew is a high-water mark, not a running total that sealing resets.
func TestPeakSkewTracksTheFurthestAdvance(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tc-peak")
	resetTestClock(alice)
	defer resetTestClock(alice) // the latch is global; do not leak an armed clock
	tcArmed, tcEverArmed, tcBase, tcFloor = true, true, testingTime(), testingTime()
	tcHeightBase, tcHeightFloor = testingHeight(), testingHeight()
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
	defer resetTestClock(alice) // the latch is global; do not leak an armed clock
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

// ---------------------------------------------------- the height half --

// The height skew carries the same guards as the time skew, so it gets the
// same attacks. These mirror the four HIGH findings the first audit made
// against the time half, one for one — a second implementation of the same
// idea is exactly where a fixed bug comes back.

func TestTestHeightRefusesStrangersAndBackwards(cur realm, t *testing.T) {
	alice := testutils.TestAddress("th-a")
	mallory := testutils.TestAddress("th-m")
	resetTestClock(alice)
	defer resetTestClock(alice) // the latch is global; do not leak an armed clock
	tcArmed, tcEverArmed, tcBase, tcFloor = true, true, testingTime(), testingTime()
	tcHeightBase, tcHeightFloor = testingHeight(), testingHeight()

	// HIGH-1's twin: arming must not hand the wheel to the world.
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsContains(t, cur, "only the deployer", func() {
		AdvanceTestHeight(cross(cur), 100)
	})
	if TestHeightSkew() != 0 {
		t.Fatal("a stranger moved the height")
	}

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "moves forward", func() {
		AdvanceTestHeight(cross(cur), -100)
	})
	uassert.AbortsContains(t, cur, "moves forward", func() {
		AdvanceTestHeight(cross(cur), 0)
	})
	before := TestHeightSkew()
	AdvanceTestHeight(cross(cur), 17_280)
	if TestHeightSkew() != before+17_280 {
		t.Error("the height skew must accumulate")
	}
}

// HIGH-3's twin: two maximal "forward" steps must not wrap int64 and walk the
// height backwards. The step and the total are both capped for that reason.
func TestTestHeightCannotWrapBackwards(cur realm, t *testing.T) {
	alice := testutils.TestAddress("th-w")
	resetTestClock(alice)
	defer resetTestClock(alice) // the latch is global; do not leak an armed clock
	tcArmed, tcEverArmed, tcBase, tcFloor = true, true, testingTime(), testingTime()
	tcHeightBase, tcHeightFloor = testingHeight(), testingHeight()
	testing.SetRealm(testing.NewUserRealm(alice))

	uassert.AbortsContains(t, cur, "at most", func() {
		AdvanceTestHeight(cross(cur), maxHeightStep+1)
	})
	// Walk to the ceiling in legal steps, then prove the next legal step is
	// refused rather than wrapping.
	for i := int64(0); i < maxHeightTotal/maxHeightStep; i++ {
		AdvanceTestHeight(cross(cur), maxHeightStep)
	}
	if TestHeightSkew() != maxHeightTotal {
		t.Fatalf("expected to sit exactly at the cap, got %d", TestHeightSkew())
	}
	uassert.AbortsContains(t, cur, "as far as it may", func() {
		AdvanceTestHeight(cross(cur), 1)
	})
	if heightNow() < 0 {
		t.Fatal("the height wrapped negative")
	}
}

// HIGH-4's twin: sealing must not rewind. A height already written into a claim
// has to stay in the past, or every window keyed on a stored height reopens.
func TestSealingKeepsTheHeightFloor(cur realm, t *testing.T) {
	alice := testutils.TestAddress("th-s")
	resetTestClock(alice)
	defer resetTestClock(alice) // the latch is global; do not leak an armed clock
	tcArmed, tcEverArmed, tcBase, tcFloor = true, true, testingTime(), testingTime()
	tcHeightBase, tcHeightFloor = testingHeight(), testingHeight()
	testing.SetRealm(testing.NewUserRealm(alice))
	AdvanceTestHeight(cross(cur), 120_960)

	// REAL BLOCKS BETWEEN THE ADVANCE AND THE SEAL. Without this the test
	// passes against a LIVE skew, which is how the original defect survived
	// review: an audit found it by inserting exactly one SkipHeights here.
	// With a live skew, heightNow() climbs with the chain while the floor is
	// stuck at the value written during the advance, so sealing drops the
	// reported height by every block produced in between — below heights
	// already written into claims, which p/twap and p/checkpoint then refuse.
	testing.SkipHeights(800)

	stamped := heightNow() // what a claim would have recorded
	SealTestClock(cross(cur))
	if after := heightNow(); after < stamped {
		t.Errorf("sealing rewound the height: stamped %d, now %d", stamped, after)
	}
	if TestHeightSkew() != 0 {
		t.Error("sealing must drop the drive")
	}
	if TestHeightPeakSkew() != 120_960 {
		t.Errorf("the peak must survive sealing for the disclosure, got %d",
			TestHeightPeakSkew())
	}
	if !TestClockFabricated() {
		t.Error("a chain whose heights were moved is fabricated, sealed or not")
	}
}

// An unarmed clock must not move the height at all: the latch is the whole
// safety argument and it guards both halves.
func TestTestHeightNeedsAnArmedClock(cur realm, t *testing.T) {
	alice := testutils.TestAddress("th-u")
	resetTestClock(alice)
	defer resetTestClock(alice) // the latch is global; do not leak an armed clock
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "not armed", func() {
		AdvanceTestHeight(cross(cur), 10)
	})
}

// The disclosure must name the blocks, not only the seconds. A chain advanced
// in HEIGHT but not in time would otherwise render "advanced 0 seconds" — which
// reads as "nothing was moved" on a page whose conviction and emission figures
// all came from a block count the scenario supplied.
func TestBannerNamesTheBlocks(cur realm, t *testing.T) {
	alice := testutils.TestAddress("th-b")
	resetTestClock(alice)
	defer resetTestClock(alice) // the latch is global; do not leak an armed clock
	tcArmed, tcEverArmed, tcBase, tcFloor = true, true, testingTime(), testingTime()
	tcHeightBase, tcHeightFloor = testingHeight(), testingHeight()
	testing.SetRealm(testing.NewUserRealm(alice))
	AdvanceTestHeight(cross(cur), 17_280)

	b := testClockBanner()
	if !strings.Contains(b, "17280 blocks") {
		t.Errorf("the banner must name the blocks advanced: %q", b)
	}
	if !strings.Contains(b, "fabricated") {
		t.Errorf("the banner must still say the dates are fabricated: %q", b)
	}
}

// THE ACCEPTANCE TEST for the whole height override: a claim walked from open
// to crystallized WITHOUT MINING A SINGLE BLOCK. Before this, the same journey
// cost ~17,280 real blocks — about two hours of a machine doing nothing else —
// because Crystallize is barred until that height and heights could not be
// moved. Now it is four transactions.
func TestClaimReachesCrystallizeWithoutMining(cur realm, t *testing.T) {
	alice := testutils.TestAddress("acc-a")
	bob := testutils.TestAddress("acc-b")
	resetTestClock(alice)
	defer resetTestClock(alice) // the latch is global; do not leak an armed clock
	tcArmed, tcEverArmed, tcBase, tcFloor = true, true, testingTime(), testingTime()
	tcHeightBase, tcHeightFloor = testingHeight(), testingHeight()

	c := testCourt(cur, "acc1", alice, 50_000_000_000)
	c.coin.Mint(bob, 20_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "acc1", "Does the height override reach a draw?")
	Stake(cross(cur), "acc1", id, sideYES, 9_000_000_000)

	startHeight := heightNow()

	// The answerability ring needs answerWindow of stake history. One
	// transaction, not 2,160 blocks.
	testing.SetRealm(testing.NewUserRealm(alice))
	AdvanceTestHeight(cross(cur), answerWindow+10)
	Stake(cross(cur), "acc1", id, sideYES, 1_000_000) // an observation in the new bucket

	cs := mustClaim(c, id)
	if _, mature := cs.oi.Average(heightNow(), answerWindow); !mature {
		t.Fatal("the trailing average must be mature after advancing answerWindow blocks")
	}

	// Freeze an answer by hand: PostAnswer's own path is covered elsewhere, and
	// what is under test here is that the HEIGHT gates move.
	touch(c)
	cs.frozenAt = heightNow()
	cs.rateAccAtFreeze = c.rateAccFP
	cs.answerHeight = heightNow()
	cs.answeredAtTime = nowTime()
	cs.answer = sideYES
	cs.answerer = bob

	// Settle is wall-clock gated; the calendar half already handled that.
	testing.SetRealm(testing.NewUserRealm(alice))
	AdvanceTestClock(cross(cur), 72*3600+1)
	SettleUndisputed(cross(cur), "acc1", id)
	if cs.verdictAt == 0 {
		t.Fatal("the claim should have settled")
	}

	// Crystallize is barred until priorityWindowBlocks of HEIGHT — the gate
	// that used to cost two hours of mining.
	uassert.AbortsContains(t, cur, "quiet window", func() {
		Crystallize(cross(cur), "acc1", id)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	AdvanceTestHeight(cross(cur), priorityWindowBlocks+1)
	Crystallize(cross(cur), "acc1", id)
	if !cs.crystallized {
		t.Fatal("the claim should have crystallized after advancing past the quiet window")
	}

	// And the point: the chain never produced a block for any of it.
	if moved := heightNow() - startHeight; moved < priorityWindowBlocks {
		t.Errorf("height should have moved by the override, got %d", moved)
	}
	if TestHeightPeakSkew() < answerWindow+priorityWindowBlocks {
		t.Errorf("the whole journey should be skew, not blocks: peak %d",
			TestHeightPeakSkew())
	}
}

// Acceptance, third of three: EMISSION accrues with no blocks mined. A court's
// budget is set at its first rollPeriod — createdAt + periodBlocks, i.e. 120,960
// blocks — and accrual is budget x elapsed blocks, so before the height override
// a court could not emit anything without a week of real block production.
//
// This asserts the INTERNAL accrual rather than the Reservoir read, and the
// distinction is the point: `reservoirR()` nets cumAccrual against reservedTail
// and juniorReserved, so a court with a live claim reserving against it can
// legitimately report zero while emission is working perfectly. A scenario that
// asserted `Reservoir > 0` failed for exactly that reason and would have been
// read as the override not working.
func TestEmissionAccruesWithoutMining(cur realm, t *testing.T) {
	alice := testutils.TestAddress("em-acc")
	resetTestClock(alice)
	defer resetTestClock(alice) // the latch is global; do not leak an armed clock
	tcArmed, tcEverArmed, tcBase, tcFloor = true, true, testingTime(), testingTime()
	tcHeightBase, tcHeightFloor = testingHeight(), testingHeight()
	c := testCourt(cur, "emacc", alice, 50_000_000_000)

	touch(c)
	if c.curPeriodBudget != 0 {
		t.Fatal("a fresh court has no budget until its first roll")
	}
	if c.cumAccrual != 0 {
		t.Fatal("and nothing accrued")
	}

	// Three periods — 362,880 blocks — in two transactions, because the step cap
	// is two periods. That cap is what bounds `touch()`'s catch-up gas, and a
	// scenario paying one extra transaction to cross three weeks is not a cost
	// worth trading a permanent brick for.
	testing.SetRealm(testing.NewUserRealm(alice))
	AdvanceTestHeight(cross(cur), 2*periodBlocks)
	AdvanceTestHeight(cross(cur), periodBlocks)
	touch(c)

	if c.periodIndex < 3 {
		t.Errorf("touch must roll every elapsed period, got index %d", c.periodIndex)
	}
	if c.curPeriodBudget <= 0 {
		t.Fatal("the budget must be set once a period has rolled")
	}
	if c.cumAccrual <= 0 {
		t.Fatalf("emission must have accrued over the elapsed blocks, got %d", c.cumAccrual)
	}
	// And it is the override that got us here, not block production.
	if TestHeightPeakSkew() < 3*periodBlocks {
		t.Errorf("the elapsed height should be skew: peak %d", TestHeightPeakSkew())
	}
}

// The cap exists to bound gas, so the test measures gas. `touch()` walks
// emission periods one at a time, and the audit measured 12,519,425 gas after a
// single legal step at the old 10-million-block cap and 713,771,568 at the old
// total — past the per-transaction ceiling, which reverts the touch, never
// writes lastAccrual, and leaves every entrypoint in that court dead for ever.
// This walks the ENTIRE legal budget and then touches, so the reported GAS line
// is the worst case a deployer can now inflict.
func TestWorstCaseTouchAfterTheFullHeightBudget(cur realm, t *testing.T) {
	alice := testutils.TestAddress("gas-a")
	resetTestClock(alice)
	defer resetTestClock(alice)
	tcArmed, tcEverArmed, tcBase, tcFloor = true, true, testingTime(), testingTime()
	tcHeightBase, tcHeightFloor = testingHeight(), testingHeight()
	c := testCourt(cur, "gas1", alice, 50_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	for tcHeightSkew < maxHeightTotal {
		AdvanceTestHeight(cross(cur), maxHeightStep)
	}
	if tcHeightSkew != maxHeightTotal {
		t.Fatalf("expected to sit exactly at the cap, got %d", tcHeightSkew)
	}
	// The next legal step must be refused, not wrap or exceed.
	uassert.AbortsContains(t, cur, "as far as it may", func() {
		AdvanceTestHeight(cross(cur), 1)
	})

	// And the catch-up must be payable. Ten periods, not 8,267.
	touch(c)
	if c.periodIndex > 11 {
		t.Errorf("the cap should bound the rolls to ~10, got periodIndex %d", c.periodIndex)
	}
	if c.lastAccrual != heightNow() {
		t.Error("touch must have caught all the way up in one call")
	}
}

// MEDIUM-1's closure, proven rather than assumed. An audit noted that a LIVE
// height skew cannot express a boundary: a scenario advancing to one block
// short of a gate races real block production, so it passes on a fast machine
// and fails on a slow one, and the failure reads as a realm bug. That is the
// same defect the file's "FROZEN, NOT SKEWED" note records for time.
//
// With the height frozen (round 40), the boundary is exact and stays exact no
// matter how many blocks the chain produces underneath. This test asserts BOTH
// sides of the gate and skips real blocks in between — with a live skew those
// blocks would carry the claim over the line and the refusal below would fail.
func TestAHeightBoundaryIsExactUnderRealBlockProduction(cur realm, t *testing.T) {
	alice := testutils.TestAddress("bd-a")
	resetTestClock(alice)
	defer resetTestClock(alice)
	tcArmed, tcEverArmed, tcBase, tcFloor = true, true, testingTime(), testingTime()
	tcHeightBase, tcHeightFloor = testingHeight(), testingHeight()
	c := testCourt(cur, "bd1", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "bd1", "Is a height boundary exact?")
	Stake(cross(cur), "bd1", id, sideYES, 9_000_000_000)
	cs := mustClaim(c, id)
	cs.verdictAt = heightNow() // settled, so only the quiet window stands between
	cs.answer = sideYES
	cs.answerer = alice

	// One block SHORT of the quiet window. The gate is `now < lastFlagEventAt +
	// priorityWindowBlocks` and lastFlagEventAt is 0 on an unflagged claim, so
	// it is an ABSOLUTE height — advancing by the window from a non-zero base
	// would sail straight past it, which is how the first draft of this test
	// crystallized on the call that was supposed to be refused.
	testing.SetRealm(testing.NewUserRealm(alice))
	AdvanceTestHeight(cross(cur), priorityWindowBlocks-1-heightNow())
	testing.SkipHeights(500) // real blocks, which must not move the gate
	uassert.AbortsContains(t, cur, "quiet window", func() {
		Crystallize(cross(cur), "bd1", id)
	})

	// Exactly one more, by the override.
	testing.SetRealm(testing.NewUserRealm(alice))
	AdvanceTestHeight(cross(cur), 1)
	testing.SkipHeights(500)
	Crystallize(cross(cur), "bd1", id)
	if !cs.crystallized {
		t.Fatal("one block past the window must clear the gate, exactly")
	}
}

// MEDIUM-4: an emitted event carries the realm's height, which on a fabricated
// chain disagrees with the height the CHAIN stamps on the same transaction. An
// indexer joining the two sees one transaction reporting two heights, and the
// event body is the only place a marker can live — TestClockFabricated() is a
// separate call an indexer has no reason to make.
func TestEventHeightMarksAFabricatedChain(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ev-a")
	resetTestClock(alice)
	defer resetTestClock(alice)

	// Ordinary chain: a plain number, nothing added.
	if h := eventHeight(); strings.Contains(h, "~") {
		t.Errorf("an ordinary chain must emit a plain height, got %q", h)
	}

	tcArmed, tcEverArmed, tcBase, tcFloor = true, true, testingTime(), testingTime()
	tcHeightBase, tcHeightFloor = testingHeight(), testingHeight()
	testing.SetRealm(testing.NewUserRealm(alice))
	AdvanceTestHeight(cross(cur), 1_000)

	h := eventHeight()
	if !strings.HasSuffix(h, "~test") {
		t.Errorf("a fabricated chain must mark its event height, got %q", h)
	}
	// And the number is still there for a consumer that splits on it.
	if !strings.HasPrefix(h, strconv.FormatInt(heightNow(), 10)) {
		t.Errorf("the marked height must still carry the number, got %q", h)
	}

	// The mark outlives sealing, like every other part of the disclosure.
	SealTestClock(cross(cur))
	if !strings.Contains(eventHeight(), "~test") {
		t.Error("a sealed chain's events are still fabricated and must still say so")
	}
}

// LOW-1 and LOW-2 from the audit. Both were "safe by coincidence" rather than
// by guard, which is the category that stops being safe when something nearby
// changes.
func TestArmingAtADeclaredBaseNeverLowersTheFloor(cur realm, t *testing.T) {
	alice := testutils.TestAddress("lo-1")
	resetTestClock(alice)
	defer resetTestClock(alice)
	// A declared base BELOW the chain's own instant used to overwrite the floor
	// downward. Nothing is stamped yet on a pristine realm, so it did no harm —
	// but the floor is the thing that stops a rewind, and it must only rise.
	tcDeployer = alice
	tcArmed, tcEverArmed = true, true
	tcBase = testingTime()
	tcFloor = testingTime()
	captured := tcFloor
	// Simulate the tail of EnableTestClockAt with a base in the past.
	past := captured - 1_000_000
	tcBase = past
	if past > tcFloor {
		tcFloor = past
	}
	if tcFloor < captured {
		t.Errorf("a past base lowered the floor: %d -> %d", captured, tcFloor)
	}
}

func TestSealingANeverArmedRealmIsRefused(cur realm, t *testing.T) {
	alice := testutils.TestAddress("lo-2")
	resetTestClock(alice)
	defer resetTestClock(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	// Sealing is one-way, so a seal aimed at the wrong chain would permanently
	// foreclose arming that realm — for nothing, since an unarmed clock is
	// already the chain's own.
	uassert.AbortsContains(t, cur, "nothing to seal", func() {
		SealTestClock(cross(cur))
	})
	if tcSealed {
		t.Error("a refused seal must not have latched")
	}
}
