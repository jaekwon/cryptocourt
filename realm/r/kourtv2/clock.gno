package kourtv2

// The two clocks, and which one governs what (owner ruling, v0.46).
//
// A PUBLISHED DEADLINE — the settle window, the reopen window, the dead-claim
// timeout, the polish window — now gates on BLOCK TIME and is stored as a unix
// timestamp. Heights are kept beside every one of them for reference, but they
// no longer decide anything a user plans around. The reason is that a height
// only means a date if the chain's pace never changes, and pace changes: a
// halt, an upgrade, or a parameter tune silently re-times every deadline
// denominated in blocks. A date does not move.
//
// THE QUALIFIED-ANSWERER HEAD START IS NOT IN THAT LIST, and this line is here
// because it used to be. answer.gno gates it on `priorityWindowBlocks`, pure
// height, and the seconds twin this file declared beside settleSecs was read by
// nothing — so the list promised a conversion that had not happened. That is
// not a harmless overstatement: someone planned a wall-clock test of the head
// start from a txtar on the strength of it, and the test could not exist. If
// the gate does move, put it back in the list and give it a constant then.
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
// ONLY THE ONES THAT ARE READ, still — a seconds constant nothing reads is worse
// than absent, because it asserts a deadline is wall-clock when the gate is
// height. Each arrives in the same commit as the gate that reads it.
// One remains unconverted: the qualified-answerer head start, still
// `priorityWindowBlocks` (answer.gno).
const (
	settleSecs    = int64(72 * 3600)      // 72h: an undisputed answer settles
	deadClaimSecs = int64(12 * 7 * 86400) // 12 weeks: an unanswered claim dies
	// finalizeGraceSecs is the week Crystallize and Finalize stay
	// participant-only. Read by crystallize.gno; dispute.gno's Finalize still
	// counts blocks and converts next.
	finalizeGraceSecs = int64(7 * 86400)
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
// heightNow is the ONLY height read in this realm. Everything accounting —
// conviction per block, emission periods, vote closes, twap maturity, the
// quality quiet window — reads it, so a test chain can advance them all
// together rather than mining. On an ordinary chain tcHeightSkew is zero and
// this is exactly runtime.ChainHeight().
//
// The floor matters for the same reason the time floor does: once sealed, the
// skew is dropped, and without a floor the chain would report a height BELOW
// ones it already wrote into claims — reopening every window keyed on a stored
// height. scripts/check-height-shim.py enforces that nothing bypasses this.
func heightNow() int64 {
	var h int64
	if tcArmed {
		h = tcHeightBase + tcHeightSkew // frozen: only AdvanceTestHeight moves it
	} else {
		h = runtime.ChainHeight()
		if h < tcHeightFloor {
			h = tcHeightFloor // a sealed test chain never falls below what it showed
		}
	}
	return h
}

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
	// THE DISPUTE, which the chart could not draw because nothing reported it.
	// A reader could see an answer dated years ago and a vote still running with
	// nothing between them. The height comes from the governor, which has had it
	// all along — DisputeVoteCloses asks for the same four numbers and keeps
	// only the deadline.
	// Carried here rather than in a reader of its own so the chart gets it in
	// the read it already makes, at no extra round trip.
	if cs.disputeOpen && cs.proposalID != 0 {
		opened, _, _, _ := c.gov.Timings(cs.proposalID)
		out += ";dispute:" + itoa(cs.disputeOpenedTime) + ":" + itoa(opened)
	}
	out += ";now:" + itoa(nowTime()) + ":" + itoa(heightNow())
	// Fabricated, not Active: the marker has to survive sealing, or a seeded
	// chain's timeline goes quiet the moment it stops being drivable.
	if TestClockFabricated() {
		// A consumer plotting these dates must be able to tell a test chain
		// from a real one without reading prose.
		// seconds:blocks. The second field was a reserved 0 until the override
		// grew a height half; a consumer that trusted the dates also needs to
		// know the HEIGHTS were moved, since every block-denominated figure on
		// the page — conviction, emission, the trailing average — derives from
		// a block count the scenario supplied.
		out += ";testclock:" + itoa(TestClockPeakSkew()) + ":" + itoa(TestHeightPeakSkew())
	}
	return out
}

// realmClock hands this realm's height to the pure packages that need it.
// grc20votes quantises vote epochs by it and the governor gates every voting
// window on it, and neither may import a realm — so the realm supplies the
// height instead of them reading the chain. Without this a fast-forwarded test
// chain could age conviction, emission and every deadline EXCEPT the votes,
// which is the one thing a dispute waits on.
//
// Stateless by design: it holds nothing, so persisting it inside the ledger
// stores a reference and no data.
type realmClock struct{}

// Height satisfies grc20votes.Clock and, through the ledger, the governor's
// Electorate.
func (realmClock) Height() int64 { return heightNow() }

// eventHeight is the height an EMITTED EVENT should carry, as a string.
//
// It is heightNow() — the realm's own clock, so an event agrees with the state
// written in the same transaction. On a fabricated chain that disagrees with
// the height the CHAIN stamps on the transaction, and an indexer joining the
// two would see one transaction reporting two heights with nothing to tell it
// which is which. So a fabricated height says so, in the value itself: an
// ordinary chain emits "4812", a seeded one emits "121861~test". A consumer
// that splits on the tilde gets the number; one that does not gets something
// obviously not a plain height rather than a plausible lie.
func eventHeight() string {
	h := strconv.FormatInt(heightNow(), 10)
	if TestClockFabricated() {
		return h + "~test"
	}
	return h
}
