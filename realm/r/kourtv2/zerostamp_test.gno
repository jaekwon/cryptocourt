package kourtv2

import (
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// Every published deadline in this realm reads a DATE now (clock.gno), and every
// one of those gates keeps its old HEIGHT arithmetic as a fallback for claims
// opened before the stamps existed:
//
//	if passed, known := pastDeadline(stamp, secs); (known && ...) ||
//		(!known && <height arithmetic>) { ... }
//
// `pastDeadline` returns known=false for a zero stamp, so a pre-upgrade claim
// silently keeps the deadline it was opened under. That fallback is the whole
// upgrade story for claims already on chain.
//
// ONE of those gates was already covered: clock_test.gno's
// TestPreStampClaimsKeepTheirHeightGate zeroes the stamps and walks
// SettleUndisputed. I did not find it before writing this file, because I searched
// for the FUNCTION names and that test never mentions them — it exercises the
// behaviour instead. A NAME SEARCH MISSES A TEST THAT NAMES THE BEHAVIOUR, and
// the miss reads as an absence of coverage. What was genuinely uncovered, and is
// covered here, is `pastDeadline` itself and the other three gates.
//
// HANDOFF-TESTCLOCK.md records the same fallback as "the gotcha that cost me a
// test": hand-built claim state without stamps tests the height path while looking
// like it tests the clock. A WARNING ABOUT ACCIDENTALLY TESTING A FALLBACK MEANS
// THE FALLBACK ITSELF IS WORTH PINNING — the accident and the gap are one fact
// seen twice.
//
// The stamps are zeroed AFTER the fact rather than by faking an old claim: the
// writers (claim.gno openClaim, answer.gno PostAnswer) always stamp now, so a
// pre-upgrade claim cannot be produced through the front door. Reaching into
// claimState is the only way to build the state this fallback exists for.
func TestAZeroStampFallsBackToTheHeightGate(cur realm, t *testing.T) {
	alice := testutils.TestAddress("zs-alice")

	// Skip to an ABSOLUTE height, derived from the constant each gate reads
	// rather than from a literal. Fatals rather than skipping backwards: a
	// negative delta means an earlier section consumed more blocks than this one
	// assumed, and SkipHeights would either panic obscurely or silently no-op and
	// leave the assertion below testing the wrong side of the boundary.
	skipTo := func(h int64) {
		d := h - heightNow()
		if d < 0 {
			t.Fatalf("fixture: height %d is already behind us (now %d)", h, heightNow())
		}
		testing.SkipHeights(d)
	}

	// ---- 1. pastDeadline's own contract ------------------------------------
	// First, because every gate below routes through it and nothing tested it
	// directly. A FUNCTION EVERY GATE ROUTES THROUGH MAY HAVE NO TEST OF ITS OWN.
	if passed, known := pastDeadline(0, 100); passed || known {
		t.Fatal("a zero stamp must report (false, false) — unknown, not un-passed: " +
			"every caller reads `known` to decide whether to use its height gate")
	}
	now := nowTime()
	if passed, known := pastDeadline(now-101, 100); !passed || !known {
		t.Fatal("a stamp older than its window must report passed and known")
	}
	if passed, known := pastDeadline(now+100, 100); passed || !known {
		t.Fatal("a stamp not yet due must report known but NOT passed")
	}
	// The boundary, both ways — the deadline is stamp+secs INCLUSIVE (>=).
	if passed, _ := pastDeadline(now-100, 100); !passed {
		t.Fatal("exactly at stamp+secs the deadline HAS passed (the gate is >=)")
	}
	if passed, _ := pastDeadline(now-99, 100); passed {
		t.Fatal("one second short of stamp+secs the deadline has NOT passed")
	}

	// ---- 2. CloseDeadClaim: the height gate still holds a young claim -------
	// The refusal arm needs no skip at all: a fresh claim whose stamp is zeroed
	// is governed by `ChainHeight() < openedAt+deadClaimTimeout`, which is true.
	// If the fallback were dropped, `known` would be false, the whole condition
	// false, and this claim would close on its first block.
	c2 := testCourt(cur, "zs2", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id2 := OpenClaim(cross(cur), "zs2", "Does the height gate still hold?")
	cs2 := mustClaim(c2, id2)
	if cs2.openedAtTime == 0 {
		t.Fatal("fixture: openClaim must stamp openedAtTime, or this test proves nothing")
	}
	cs2.openedAtTime = 0 // a claim opened before the stamps existed
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "dead-claim timeout has not passed", func() {
		CloseDeadClaim(cross(cur), "zs2", id2)
	})
	if ClaimClosed("zs2", id2) {
		t.Fatal("a zero-stamp claim closed on its first block — the height fallback is gone")
	}

	// ---- 3. EditClaimTitle: the polish window on its height arm -------------
	// Needs StartCourtP: the default delay is 0, so blocksToSecs(0) is 0 and the
	// KNOWN arm refuses from birth — which is why this window is unreachable on
	// an ordinary court and had to be opted into here.
	bob := testutils.TestAddress("zs-bob")
	testing.SetRealm(testing.NewUserRealm(bob))
	StartCourtP(cross(cur), "zs3", "Polish Court", 100)
	c3 := mustCourt("zs3")
	c3.coin.Mint(bob, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	id3 := OpenClaim(cross(cur), "zs3", "A title with a typoe")
	cs3 := mustClaim(c3, id3)
	cs3.openedAtTime = 0
	openedAt3 := cs3.openedAt
	// Inside the window on the height arm: the edit lands.
	testing.SetRealm(testing.NewUserRealm(bob))
	EditClaimTitle(cross(cur), "zs3", id3, "A title with a typo")
	// Derived from the constant the gate reads, not a literal.
	skipTo(openedAt3 + 100)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "polish window has closed", func() {
		EditClaimTitle(cross(cur), "zs3", id3, "Too late")
	})

	// SettleUndisputed is DELIBERATELY ABSENT, on evidence rather than on taste.
	// clock_test.gno's TestPreStampClaimsKeepTheirHeightGate already zeroes
	// answeredAtTime and walks that gate, and the mutation batch is what proved
	// the overlap: the row deleting session.gno's `(!known && ...)` arm is caught
	// THERE, not here. A section here would have added a second killer for a row
	// that already had one — and it was the only section needing matureOI, which
	// is three stakes plus epoch skips. (Whether removing it actually made the
	// suite faster is NOT established: the before and after timings were taken
	// under different load and are not comparable. It was dropped for being
	// redundant, not for being slow.)
	//
	// I only found the overlap because a row I wrote was caught by a test I had
	// not written. THE BATCH TELLS YOU WHICH OF YOUR TESTS ARE REDUNDANT, not
	// just which guards are unpinned.

	// ---- 5. Past the timeout: PostAnswer refuses, CloseDeadClaim accepts ----
	// Two claims on one court, both stamps zeroed, ONE skip past
	// deadClaimTimeout — so the two gates are read at the same height and the
	// only difference is which entrypoint asks. The big skip goes last: it moves
	// the chain ~1.45M blocks and nothing after it would be cheap.
	dave := testutils.TestAddress("zs-dave")
	c5 := testCourt(cur, "zs5", dave, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(dave))
	idAnswer := OpenClaim(cross(cur), "zs5", "Answerable until the timeout?")
	testing.SetRealm(testing.NewUserRealm(dave))
	idClose := OpenClaim(cross(cur), "zs5", "Closable at the timeout?")
	csA, csC := mustClaim(c5, idAnswer), mustClaim(c5, idClose)
	csA.openedAtTime, csC.openedAtTime = 0, 0
	skipTo(csA.openedAt + deadClaimTimeout)

	testing.SetRealm(testing.NewUserRealm(dave))
	uassert.AbortsContains(t, cur, "past the dead-claim timeout", func() {
		PostAnswer(cross(cur), "zs5", idAnswer, sideYES)
	})
	testing.SetRealm(testing.NewUserRealm(dave))
	CloseDeadClaim(cross(cur), "zs5", idClose)
	if !ClaimClosed("zs5", idClose) {
		t.Fatal("a zero-stamp claim would not close on its height gate")
	}

	// ---- 6. THE OTHER ENCODING: escrowUntilAt's zero SENTINEL ---------------
	// dispute.gno's Finalize does not use pastDeadline. It spells the same idea
	// with a sentinel — `escrowUntilAt != 0` means "the stamp exists" — so nothing
	// written against the pastDeadline shape reaches it. TWO GATES MAY ENCODE ONE
	// CONCEPT DIFFERENTLY, AND A TEST WRITTEN FOR ONE SHAPE MISSES THE OTHER.
	//
	// Which half was unexercised was MEASURED, not guessed, and the measurement
	// contradicted me. I expected the suite to run with escrowUntilAt == 0 and
	// therefore to exercise only the height arm. Splitting the condition into one
	// mutation row per arm showed the reverse: deleting the TIME arm is caught
	// (TestDisputeUpholdPath), while deleting this HEIGHT arm survived — the suite
	// resolves disputes properly, so escrowUntilAt is always set, and the
	// pre-upgrade path was the dead one.
	//
	// Built by hand rather than by resolving a dispute: Finalize's guards ahead of
	// the escrow gate are only verdictAt, disputeOpen and provisional, all of them
	// plain fields. An answer, a bond and a resolution would buy nothing here and
	// would cost every kourtv2 mutation row a slower suite.
	erin := testutils.TestAddress("zs-erin")
	stranger := testutils.TestAddress("zs-stranger")
	c6 := testCourt(cur, "zs6", erin, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(erin))
	id6 := OpenClaim(cross(cur), "zs6", "Does the escrow window fall back to height?")
	cs6 := mustClaim(c6, id6)
	cs6.provisional = sideYES // enough to reach the escrow gate
	cs6.escrowUntilAt = 0     // the pre-upgrade shape: no stamp, only a height
	cs6.escrowUntil = heightNow() + 10

	// One block short, and the caller is a stranger so nothing later can pass.
	skipTo(cs6.escrowUntil - 1)
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "escrow window has not passed", func() {
		Finalize(cross(cur), "zs6", id6)
	})
	// At the block the escrow gate is satisfied, so the NEXT guard speaks instead.
	// A DIFFERENT refusal is the discriminating assertion: "already final" or a
	// silent success would both mean the height arm never governed, and asserting
	// "no panic" here would pass on the participant grace refusing for its own
	// reason. The message is what separates passing the gate from never reaching it.
	skipTo(cs6.escrowUntil)
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "participant-only", func() {
		Finalize(cross(cur), "zs6", id6)
	})

	// ---- 7. THE SAME SENTINEL IN OpenDispute'S REOPEN BRANCH ----------------
	// §6 pinned Finalize and nothing else: the arm-split probe kept surviving here
	// afterwards, which is how I know these are two gates and not one. Each arm of
	// each gate needs its own killer.
	//
	// The reopen branch (dispute.gno, OpenDispute's escrow arm) is the `else` of
	// `provisional < 0`, so it is reached only on a claim that already has a
	// provisional verdict — and its preceding guards are frozenAt, answerer,
	// disputeOpen and verdictAt, all plain fields again.
	frank := testutils.TestAddress("zs-frank")
	c7 := testCourt(cur, "zs7", frank, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(frank))
	id7 := OpenClaim(cross(cur), "zs7", "Can a reopen still read the height?")
	cs7 := mustClaim(c7, id7)
	cs7.frozenAt = heightNow() // there must be an answer to dispute
	cs7.provisional = sideYES  // ...and a provisional verdict, for the reopen branch
	cs7.escrowUntilAt = 0      // the pre-upgrade shape again
	cs7.escrowUntil = heightNow() + 10

	// AT the escrow height the reopen window has closed, on the height arm.
	skipTo(cs7.escrowUntil)
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "escrow window has passed", func() {
		OpenDispute(cross(cur), "zs7", id7)
	})
	// The inverse is NOT asserted here. One block short this branch falls through
	// to the bond and credEligible bars, which refuse a stranger for their own
	// reasons — so "it refuses either way" would prove nothing about which gate
	// spoke, and a passing reopen would need a funded, weight-bearing disputer.
	// The refusal above is anchored on its own message, which is the part that
	// distinguishes this gate from the ones after it.

	// ---- 8. THE RENDER SIDE OF THE SAME SENTINEL ---------------------------
	// deadlineTime is pastDeadline's twin: the gates ask "has it passed?", this
	// one asks "when?", and both must answer "unknowable" for a claim that
	// predates the stamps. Deleting its `stamp == 0` return SURVIVED the whole
	// corpus, because nothing exercised the one surface that shows it —
	// ClaimTimeline's settle row.
	//
	// Without the guard, a claim whose answer carries no stamp publishes
	// `settle:259200:<height>`: not a crash, not a wrong gate, just a
	// real-looking deadline in January 1970 handed to whoever renders it. (The
	// web client does special-case a zero stamp for the LABEL — it prints
	// "≈block N" rather than a date — but it also sorts the ladder by that
	// number, so a zero row climbs above `opened`. The producer owes the
	// sentinel either way; the consumer only half-handles it.)
	//
	// THE ASYMMETRY IS THE POINT: openedAtTime stays real and only the ANSWER's
	// stamp is missing. A fixture that zeroed both could not tell the settle row
	// reading the wrong field from it reading the right one — measured, that
	// mutation is caught here and nowhere else.
	grace := testutils.TestAddress("zs-grace")
	c8 := testCourt(cur, "zs8", grace, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(grace))
	id8 := OpenClaim(cross(cur), "zs8", "What does a pre-stamp claim publish?")
	cs8 := mustClaim(c8, id8)
	if cs8.openedAtTime == 0 {
		t.Fatal("fixture: openClaim must stamp openedAtTime, or the asymmetry " +
			"this section turns on is gone and it proves nothing")
	}
	// A BLOCK APART, so answerHeight and openedAt are different numbers. Opened
	// and answered in the same block they are equal, and the height half of the
	// assertion below then passes against either field — measured: the emit site
	// reading cs.openedAt survived the whole suite until this line existed.
	testing.SkipHeights(1)
	cs8.answerHeight = heightNow()
	// answeredAtTime is left at zero, which is where PostAnswer would have
	// written a stamp. Assigning 0 here was the first draft and it was a NO-OP —
	// nothing but PostAnswer ever writes that field, so the fixture was zeroing
	// something already zero and its comment claimed a shape it did not build.
	if cs8.answeredAtTime != 0 {
		t.Fatal("fixture: a claim that was never answered must carry no answer stamp")
	}

	// The settle row renders only while verdictAt is 0 and the claim is open,
	// which is the state a fresh claim is already in. The trailing ";" anchors
	// the height: ClaimTimeline always appends ";now:", so without it a want of
	// ":1503603" would also match ":15036031".
	tl := ClaimTimeline("zs8", id8)
	want := ";settle:0:" + itoa(cs8.answerHeight+settleDelay) + ";"
	if !strings.Contains(tl, want) {
		t.Errorf("a pre-stamp claim must publish an unknowable settle stamp beside "+
			"its real height: want %q in %q", want, tl)
	}
	// THE COMPLEMENT, on the same claim. Without it, ";settle:0:" is satisfied
	// just as well by a row that is zero for EVERYBODY — measured: hardcoding the
	// emit site to itoa(0) survived the suite while the assertion above passed.
	// The absence-check that stood here instead was dead: ClaimTimeline emits at
	// most one settle row, so it could only ever fire when the assertion above
	// had already failed.
	cs8.answeredAtTime = nowTime()
	if got := ClaimTimeline("zs8", id8); !strings.Contains(got,
		";settle:"+itoa(cs8.answeredAtTime+settleSecs)+":") {
		t.Errorf("a stamped answer must publish its real settle date, not the "+
			"sentinel: %q", got)
	}
}

