package kourtv2

// The two clocks, and which one governs what (owner ruling, v0.46).
//
// A PUBLISHED DEADLINE — the settle window, the reopen window, the dead-claim
// timeout, the polish window, the qualified-answerer head start — now gates on
// BLOCK TIME and is stored as a unix timestamp. Heights are kept beside every
// one of them for reference, but they no longer decide anything a user plans
// around. The reason is that a height only means a date if the chain's pace
// never changes, and pace changes: a halt, an upgrade, or a parameter tune
// silently re-times every deadline denominated in blocks. A date does not move.
//
// An ACCOUNTING CLOCK stays on height, deliberately: conviction accrues per
// block (rate × blocks), emission periods are counted in blocks, the coin's
// voting snapshots are height epochs, and the stake-history grain buckets
// heights. Those are not promises to a reader; they are the units the money
// math is defined in, and re-denominating them would change what claims pay.
//
// Block time is proposer-written and therefore nudgeable by a few seconds
// where height is pure consensus counting. That is the cost of the trade, and
// it is the right one for a deadline measured in days: seconds of drift at the
// boundary are invisible, while a pace change is not.
//
// PRE-UPGRADE CLAIMS carry zero timestamps. Every gate below falls back to its
// original height arithmetic when the stamp is missing, so a claim opened
// before this change keeps exactly the deadline it was opened under.

import (
	"chain/runtime"
	"strconv"
)

// Durations in seconds, each the wall-clock meaning its block constant was
// chosen to express (at the 5s cadence those constants assumed).
const (
	settleSecs       = int64(72 * 3600)      // 72h: an undisputed answer settles
	deadClaimSecs    = int64(12 * 7 * 86400) // 12 weeks: an unanswered claim dies
	priorityWindow   = int64(24 * 3600)      // 24h: qualified answerers hold the front
	finalizeGraceSec = int64(7 * 86400)      // 7 days: participants finalize first
)

// nowTime is the block's timestamp in unix seconds — through the test-clock
// shim (testclock.gno), which is inert unless a throwaway chain armed it.
func nowTime() int64 { return tcNow() }

// deadlineTime answers a claim-scoped deadline in wall-clock terms, or 0 when
// this claim predates the stamps (the caller then keeps its height gate).
func deadlineTime(stamp, secs int64) int64 {
	if stamp == 0 {
		return 0
	}
	return stamp + secs
}

// pastDeadline reports whether the block clock has passed stamp+secs, and
// whether the stamp existed at all. A caller with no stamp falls back to the
// height arithmetic it used before the stamps existed.
func pastDeadline(stamp, secs int64) (passed, known bool) {
	if stamp == 0 {
		return false, false
	}
	return nowTime() >= stamp+secs, true
}

// blocksToSecs converts a court-configured block window (the polish window is
// still configured in blocks, being a court parameter) to seconds at the
// cadence the parameter was written against.
func blocksToSecs(b int64) int64 { return b * 5 }

// heightNow is the reference height recorded beside every stamp.
func heightNow() int64 { return runtime.ChainHeight() }

func itoa(v int64) string { return strconv.FormatInt(v, 10) }

// ClaimTimeline is one read for a claim's whole clock: what already happened,
// stamped in wall-clock seconds by the chain itself, and what is still to come.
//
//	"opened:<unix>:<height>;answered:<unix>:<height>;verdict:<unix>:<height>;
//	 settle:<unix>:<height>;reopen:<unix>:<height>;now:<unix>:<height>"
//
// Past events carry the block's own timestamp — no arithmetic, nothing
// derived. Future rows carry the deadline the realm will actually gate on
// (a timestamp) with its reference height beside it. A field is omitted when
// it has not happened; a zero unix stamp means the claim predates the stamps
// and only its height is knowable.
func ClaimTimeline(courtSlug string, claimID uint64) string {
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	out := "opened:" + itoa(cs.openedAtTime) + ":" + itoa(cs.openedAt)
	if cs.answerHeight != 0 {
		out += ";answered:" + itoa(cs.answeredAtTime) + ":" + itoa(cs.answerHeight)
		if cs.verdictAt == 0 && !cs.closed {
			out += ";settle:" + itoa(deadlineTime(cs.answeredAtTime, settleSecs)) +
				":" + itoa(cs.answerHeight+settleDelay)
		}
	}
	if cs.verdictAt != 0 {
		out += ";verdict:" + itoa(cs.verdictAtTime) + ":" + itoa(cs.verdictAt)
	}
	if cs.escrowUntil != 0 {
		out += ";reopen:" + itoa(cs.escrowUntilAt) + ":" + itoa(cs.escrowUntil)
	}
	out += ";now:" + itoa(nowTime()) + ":" + itoa(heightNow())
	// Fabricated, not Active: the marker has to survive sealing, or a seeded
	// chain's timeline goes quiet the moment it stops being drivable.
	if TestClockFabricated() {
		// A consumer plotting these dates must be able to tell a test chain
		// from a real one without reading prose.
		out += ";testclock:" + itoa(TestClockPeakSkew()) + ":0"
	}
	return out
}
