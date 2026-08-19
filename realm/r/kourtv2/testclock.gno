package kourtv2

// The test clock: a one-shot latch that lets a THROWAWAY chain walk claims
// through deadlines measured in days, and that a chain anybody has already
// used can never open (owner ruling, 2026-08-18; hardened after an audit).
//
// Why it lives in the realm at all. Published deadlines gate on wall-clock time
// (clock.gno), which is the right unit for a promise to a reader — but it makes
// end-to-end testing impossible on a real node, because no test can wait 72
// hours, and the integration harness has no way to skew a chain's clock. There
// is no dev-only build of this realm to hide such a knob in. So the knob is
// here, and its safety is structural rather than conventional.
//
// WHAT THE LATCH ACTUALLY PROMISES — stated exactly, because the first draft of
// this comment overclaimed and an audit called it out. It does NOT say "a real
// deployment can never open this". It says: only the address that deployed the
// package, and only while the realm is PRISTINE — no user court, and the meta
// court seated by init carrying no claims and no coin. In practice that is the
// deploying transaction's own window. A deployer who arms their own production
// chain in that window has armed it; no code can prevent an operator from
// deciding to run a test chain.
//
//  1. init() records the deployer. MsgAddPackage sets OriginCaller, and init is
//     the only moment that address can be read without a later caller
//     influencing it (meta.gno relies on the same fact to seat the meta court).
//  2. Arming requires that address, on a pristine realm, once.
//  3. Only the deployer may advance or seal. An armed chain is a test chain,
//     and it stays one — creating courts does NOT disarm it, because seeding a
//     court and then advancing time is the entire point.
//  4. Sealing is one-way and never rewinds: the clock floor is kept, so a
//     stamp already written can never end up in the future.
//
// FROZEN, NOT SKEWED. While armed the clock reads base+advanced, where base was
// captured at arming — real time stops passing. A skew added to a live clock
// cannot express a boundary: an integration test that advances to one second
// short of a deadline still crosses it, because the seconds a node spends
// mining the intervening blocks are added underneath. That was found by the
// first integration test written against this feature, not in review.
//
// What it deliberately cannot do: rewind (advance is forward-only and both the
// step and the total are capped, so int64 cannot wrap into a negative — an audit
// proved two maximal "forward" steps otherwise walked the clock backwards, and
// capping the advance turned out to be only half of it, since a declared BASE
// near the ceiling wraps the same sums; see maxBase); touch heights (conviction,
// emission and voting epochs are denominated in blocks and must stay honest); or
// hide (TestClockActive is public AND read by Render and ClaimTimeline, so a
// reader is never shown a fabricated date without being told).

import (
	"time"

	unsafe "chain/runtime/unsafe"
)

const (
	// maxAdvanceStep bounds one step, maxAdvanceTotal the sum. Ten and a
	// hundred years: far past any deadline this realm has (the longest is the
	// 12-week dead-claim timeout), and far short of the int64 wrap that made
	// two "forward" steps move the clock backwards.
	maxAdvanceStep  = int64(10 * 365 * 86400)
	maxAdvanceTotal = int64(100 * 365 * 86400)
	// maxBase is the latest instant a scenario may DECLARE. A base of any size
	// used to be accepted, and one near int64's ceiling wraps tcBase+tcSkew
	// NEGATIVE on an advance that was individually legal — tcNow's non-positive
	// assertion then fires on EVERY read for ever after, so the realm stops
	// answering (every deadline, every Render, every State) instead of the
	// mistake being refused in the transaction that made it.
	//
	// THIS IS A PLAUSIBILITY CAP, AND THE FIRST VERSION WAS AN ARITHMETIC ONE:
	// maxInt64 - maxAdvanceTotal, sized so tcNow's own sum could not wrap. That
	// was the same mistake one level out. Every CONSUMER of tcNow adds again —
	// deadlineTime and pastDeadline compute stamp+secs, a reopen stamps
	// nowTime()+blocksToSecs(...) — so at an arithmetic cap's boundary tcNow
	// returns exactly maxInt64 and THOSE wrap: a claim is born past its 12-week
	// timeout, unanswerable, closeable by anyone, publishing a negative settle
	// stamp. A loud brick traded for silent mis-gating, which is worse.
	//
	// A real date removes the class rather than the two additions I could
	// enumerate: a base below 2100 plus the century of advance leaves every
	// downstream sum nine orders of magnitude clear of the ceiling, whatever
	// windows get added later. It also refuses the operator error an arithmetic
	// cap arms happily — a base in MILLISECONDS, which wraps nothing and simply
	// publishes dates in the year 57438.
	//
	// And arithmetic alone could not have been made sound here in any case: the
	// downstream addend is UNBOUNDED. escrowMaxBlocks is a court parameter checked
	// only for max >= min >= 1 (court.gno), and blocksToSecs multiplies by five, so
	// no headroom computed from today's window constants stays correct.
	maxBase = int64(4102444800) // 2100-01-01T00:00:00Z
)

var (
	tcDeployer address // captured at deploy; the only address that may drive it
	tcArmed    bool    // the clock is frozen+advanced and every surface says so
	tcSealed   bool    // one-way: once true, arming is impossible forever
	tcSkew     int64   // seconds advanced by the scenario; only ever grows
	tcBase     int64   // block time captured at arming; the clock FREEZES here
	tcFloor    int64   // the highest instant this clock ever showed; never rewound past
	// tcEverArmed outlives sealing. Disarming stops the clock being DRIVEN, but
	// the stamps a scenario already wrote stay fabricated forever, so the
	// disclosure has to outlive the capability. Sealing used to clear every flag
	// and leave a chain of invented dates presenting itself as an honest one.
	tcEverArmed bool
	tcPeakSkew  int64 // the furthest the clock was ever advanced; kept past sealing
)

func init() { tcDeployer = unsafe.OriginCaller() }

// mustDeployer is the single gate on every write here. Ordered deployer-first
// so a stranger learns nothing about the latch's state (an audit noted the
// reverse order was free reconnaissance for exactly the race this defends).
func mustDeployer(cur realm) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	if cur.Previous().Address() != tcDeployer {
		panic("kourtv2: only the deployer may drive the test clock")
	}
}

// EnableTestClock arms the clock. Deployer only, once, and only while nothing
// has happened yet: no user court, and the meta court seated by init still
// carrying no claims and no coin. A realm with history is not a test chain.
func EnableTestClock(cur realm) {
	mustDeployer(cur)
	if tcSealed {
		panic("kourtv2: the test clock is sealed; this realm is not a test chain")
	}
	if tcArmed {
		panic("kourtv2: the test clock is already armed")
	}
	if CourtCount() > 1 {
		panic("kourtv2: this realm already has courts; the test clock cannot be armed")
	}
	// The meta court exists from init and is a fully working court — it takes
	// coin and claims. Court COUNT alone would call a realm with months of
	// activity on it "virgin", which an audit demonstrated.
	m := mustCourt(metaSlug)
	if m.nextID > 1 || m.coin.TotalSupply() > 0 {
		panic("kourtv2: this realm has been used; the test clock cannot be armed")
	}
	tcArmed = true
	tcEverArmed = true // never cleared again, not even by sealing
	tcBase = time.Now().Unix() // the clock stops here until the scenario moves it
	// The cap applies to the CAPTURED base too, or the invariant tcBase <= maxBase
	// holds at only one of this field's two writers. Block time is the proposer's
	// (clock.gno says so), and the chains this latch targets are hand-rolled
	// single-operator ones, so a genesis_time in milliseconds is a likelier way to
	// arrive here than clock drift — and it publishes year-57438 dates without
	// wrapping anything.
	//
	// NOT MEASURABLE, and deliberately not billed for: no harness reaches this
	// line. The unit suite stops at the court gate above (an earlier test has
	// always seated one), a filetest's caller is never the deployer, and a txtar
	// cannot set a chain's genesis time. A mutation row for it would survive for
	// ever, so there is none — same treatment as mustDeployer's IsCurrent arm.
	if tcBase > maxBase {
		panic("kourtv2: this chain's own clock reads past 2100; check its genesis time")
	}
	tcFloor = tcBase
}

// EnableTestClockAt arms the clock at a CHOSEN instant instead of the deploying
// block's own time. A scenario file that declares its base produces the same
// dates on every run — without this, tcBase is whatever the node happened to
// think when the arming transaction landed, so absolute dates drift on every
// reseed and no scenario can assert one.
func EnableTestClockAt(cur realm, base int64) {
	// Deployer first, before the argument is even read. mustDeployer's own comment
	// gives the reason — a stranger must learn nothing here — and an
	// argument-validity oracle is that same shape even when the only secret is a
	// constant. EnableTestClock checks again below; a redundant gate is the safer
	// failure mode, and it keeps this entrypoint's first line the same as every
	// other crossing function's in the realm.
	mustDeployer(cur)
	if base <= 0 {
		panic("kourtv2: the test clock's base must be a positive instant")
	}
	if base > maxBase {
		panic("kourtv2: the test clock's base must be an instant before 2100")
	}
	EnableTestClock(cur)
	tcBase = base
	tcFloor = base
}

// AdvanceTestClock moves the clock forward by secs. Deployer only: arming must
// not hand the steering wheel to the world, which the first draft did.
func AdvanceTestClock(cur realm, secs int64) {
	mustDeployer(cur)
	if !tcArmed {
		panic("kourtv2: the test clock is not armed")
	}
	if secs <= 0 || secs > maxAdvanceStep {
		panic("kourtv2: the test clock moves forward, by at most ten years a step")
	}
	if tcSkew > maxAdvanceTotal-secs {
		panic("kourtv2: the test clock has advanced as far as it may")
	}
	tcSkew += secs
	if tcSkew > tcPeakSkew {
		tcPeakSkew = tcSkew
	}
	if n := tcBase + tcSkew; n > tcFloor {
		tcFloor = n
	}
}

// SealTestClock closes the window for good. Deployer only, and it does NOT
// rewind: the floor keeps the highest instant this chain ever showed, so every
// stamp already written stays in the past. Without that, sealing after a long
// advance threw stamps into the future and REOPENED windows that had expired.
func SealTestClock(cur realm) {
	mustDeployer(cur)
	sealTestClock()
}

// sealTestClock is the internal one-way latch.
func sealTestClock() {
	tcSealed = true
	tcArmed = false
	tcSkew = 0
	tcBase = 0
}

// TestClockActive reports whether the clock can still be DRIVEN — armed and not
// yet sealed. It is a capability question, not a disclosure one: a sealed test
// chain answers false while still being full of invented dates. Ask
// TestClockFabricated before believing a date on this chain.
func TestClockActive() bool { return tcArmed }

// TestClockFabricated reports whether this chain's dates were ever set by hand.
// True from the moment the clock is armed and true forever after, including
// past sealing, because sealing removes the steering wheel and not the history.
// This is the accessor Render and any front end should key their warning on.
func TestClockFabricated() bool { return tcEverArmed }

// TestClockSkew is the seconds the clock is currently advanced (0 once sealed).
func TestClockSkew() int64 { return tcSkew }

// TestClockPeakSkew is the furthest the clock was ever advanced, kept past
// sealing so a seeded chain can still say how far its dates were pushed.
func TestClockPeakSkew() int64 { return tcPeakSkew }

// tcNow is the clock every published deadline reads. Never rewinds below the
// floor, and never returns the zero sentinel that clock.gno reads as "this
// claim predates the stamps".
func tcNow() int64 {
	var n int64
	if tcArmed {
		n = tcBase + tcSkew // frozen: only AdvanceTestClock moves it
	} else {
		n = time.Now().Unix()
		if n < tcFloor {
			n = tcFloor // a sealed test chain never falls back below what it showed
		}
	}
	// An assertion of last resort, and deliberately kept after maxBase made the
	// wrap that reached it unreachable through the entrypoints. Zero is
	// clock.gno's "this claim predates the stamps" sentinel, so a clock quietly
	// handing it out does not fail — it silently reclassifies every live claim as
	// pre-stamp. Refusing to answer is the correct behaviour for a clock that
	// cannot say what time it is.
	if n <= 0 {
		panic("kourtv2: the clock read a non-positive instant")
	}
	return n
}
