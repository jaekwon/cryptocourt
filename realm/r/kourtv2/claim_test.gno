package kourtv2

import (
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// The claim lifecycle's guards, a cluster the mutation harness found entirely
// unpinned: CloseDeadClaim on an ANSWERED claim, a double close, and OpenClaim's title
// bounds all failed no test. The answered case is the serious one — a claim with an
// answer has a bond in escrow and a settle path, and "dying" instead would refund the
// deposit, mark it closed, and leave Crystallize panicking on `closed` forever. It is
// reachable because deadClaimTimeout and the answerability window are both 12 weeks, so
// an answer landing near the end leaves a claim that is both answered and past the
// timeout.
func TestCloseDeadClaimRefusesAnsweredAndRepeatCloses(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ded-alice")
	c := testCourt(cur, "ded", alice, 50_000_000_000)

	// An ANSWERED claim settles; it does not die.
	testing.SetRealm(testing.NewUserRealm(alice))
	answered := OpenClaim(cross(cur), "ded", "answered, so it settles")
	matureOI(cur, "ded", answered, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "ded", answered, sideYES)
	testing.SkipHeights(deadClaimTimeout + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "it settles, it does not die", func() {
		CloseDeadClaim(cross(cur), "ded", answered)
	})
	if acs := mustClaim(c, answered); acs.closed || acs.deposit == 0 {
		t.Fatalf("a refused close must not have closed or refunded: closed=%t deposit=%d",
			acs.closed, acs.deposit)
	}

	// An UNANSWERED claim past the timeout dies exactly once.
	testing.SetRealm(testing.NewUserRealm(alice))
	dead := OpenClaim(cross(cur), "ded", "nobody answered this")
	testing.SkipHeights(deadClaimTimeout + 1)
	before := c.coin.BalanceOf(alice)
	CloseDeadClaim(cross(cur), "ded", dead)
	dcs := mustClaim(c, dead)
	if !dcs.closed || dcs.deposit != 0 || dcs.fee != 0 {
		t.Fatalf("the close must refund the deposit and burn the fee: closed=%t dep=%d fee=%d",
			dcs.closed, dcs.deposit, dcs.fee)
	}
	refunded := c.coin.BalanceOf(alice) - before
	if refunded <= 0 {
		t.Fatalf("the author must get their deposit back: %d", refunded)
	}
	// And a second close is refused rather than paying again. The field zeroing above
	// already makes the payout exactly-once, so this pins the CONTRACT: the call is an
	// error, not a silent no-op a caller can loop on.
	uassert.AbortsContains(t, cur, "already closed", func() {
		CloseDeadClaim(cross(cur), "ded", dead)
	})
	if got := c.coin.BalanceOf(alice) - before; got != refunded {
		t.Fatalf("a refused second close must pay nothing more: %d vs %d", got, refunded)
	}
}

// OpenClaim's title bounds, also unpinned. The title is attacker-chosen and reaches
// every render path, so an unbounded one is storage and page cost; an empty one renders
// a claim nobody can identify.
func TestOpenClaimBoundsTheTitle(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tit-alice")
	testCourt(cur, "tit", alice, 50_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "1..200 characters", func() {
		OpenClaim(cross(cur), "tit", "")
	})
	long := ""
	for i := 0; i < 201; i++ {
		long += "x"
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "1..200 characters", func() {
		OpenClaim(cross(cur), "tit", long)
	})
	// Both boundaries are ACCEPTED, so the guard is not rejecting everything.
	testing.SetRealm(testing.NewUserRealm(alice))
	OpenClaim(cross(cur), "tit", "x")
	testing.SetRealm(testing.NewUserRealm(alice))
	OpenClaim(cross(cur), "tit", long[:200])
}

// StartCourt's slug uniqueness, unpinned: overwriting a taken slug replaces the Court
// value the tree holds, orphaning every claim, position and escrowed balance under it
// while the coin ledger keeps the funds. Three of my own test-slug collisions this
// session surfaced this panic as a SETUP failure, which is not the same as asserting it.
func TestStartCourtRefusesATakenSlug(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sct-alice")
	bob := testutils.TestAddress("sct-bob")
	c := testCourt(cur, "sct", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "sct", "a claim that must not be orphaned")

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "that slug is taken", func() {
		StartCourt(cross(cur), "sct", "Impostor Court")
	})
	// The original court and its claim survive untouched.
	if mustCourt("sct") != c {
		t.Fatal("a refused StartCourt must not replace the court")
	}
	if mustClaim(c, id).title != "a claim that must not be orphaned" {
		t.Fatal("the existing claim must survive")
	}
}

// THE CONSERVATION CHECK THAT DID NOT EXIST.
//
// `Court.deposit` is documented in court.gno as "sum of escrowed deposits+fees, for the
// conservation checks". It is written in six places — one increment at OpenClaim and a
// decrement at each of the five sites that dispose a claim's deposit or fee — and until
// now it was READ NOWHERE. No conservation check consulted it, no accessor exposed it,
// no test looked at it. So every one of those decrements could be deleted with nothing
// to notice: the claim's own fields stayed right, the coin moved correctly, and only a
// number nobody read went wrong.
//
// That is the same shape as the last three finds, taken one step further — not a guard
// whose failure shows up on another tree, but a ledger with no reader at all. The fix is
// not another guard; it is to make the field mean what its comment says. This asserts the
// invariant the comment describes:
//
//	c.deposit == Σ over live claims of (cs.deposit + cs.fee)
//
// which every decrement site is required to maintain, so one assertion pins all of them.
func TestCourtDepositLedgerMatchesItsClaims(cur realm, t *testing.T) {
	check := func(c *Court, when string) { ledgerMatchesClaims(t, c, when) }

	alice := testutils.TestAddress("cdl-alice")
	bob := testutils.TestAddress("cdl-bob")
	c := testCourt(cur, "cdl", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.params.escrowMinBlocks = 450_000 // three failed rounds must fit
	c.params.escrowMaxBlocks = 450_000
	// Arm the priority gate and qualify the answerer, so answering takes their one
	// slot and provCloseClaim has a slot to give back. provClose is the THIRD
	// terminal path, and the other two (SettleUndisputed, Finalize) each had this
	// release unpinned.
	for _, a := range []address{alice, testutils.TestAddress("cdl-q2"),
		testutils.TestAddress("cdl-q3")} {
		for i := 0; i < priorityNetRecord; i++ {
			creditUpheld(c, a)
		}
	}

	// Two claims: one to drive to provClose, one to leave for the dead-claim timeout.
	testing.SetRealm(testing.NewUserRealm(alice))
	answered := OpenClaim(cross(cur), "cdl", "answered, then closed without a decision")
	dead := OpenClaim(cross(cur), "cdl", "never answered")
	check(c, "after opening two claims")
	if c.deposit <= 0 {
		t.Fatal("setup: opening claims must escrow deposits")
	}

	matureOI(cur, "cdl", answered, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "cdl", answered, sideYES)
	if mayAnswerInPriority(c, alice) {
		t.Fatal("setup: answering in priority must take the answerer's one slot")
	}

	// Three failed rounds close it without a decision: provCloseClaim refunds BOTH the
	// deposit and the fee, so both decrements must fire.
	for round := 0; round < maxFailedRounds; round++ {
		testing.SetRealm(testing.NewUserRealm(bob))
		OpenDispute(cross(cur), "cdl", answered)
		testing.SkipHeights(c.params.votingBlocks + 1)
		ResolveDispute(cross(cur), "cdl", answered)
	}
	acs := mustClaim(c, answered)
	if !acs.provClose {
		t.Fatalf("setup: three failed rounds must close the claim: failedRounds=%d",
			acs.failedRounds)
	}
	check(c, "after provClose refunded a deposit and fee")
	// RE-DERIVED (S3). This asserted `tierFinal && tier == tierLowX`, which WAS the
	// defect: provClose is a close without a decision, so nobody was found at fault
	// and the same function refunds the deposit AND fee precisely because it is not a
	// conclusive low — then treated it as junk for the draw. It now lands at the plain
	// default MID and stays UNFINALIZED, which is load-bearing rather than incidental:
	// latching tierFinal here would make provCloseClaim's own guard self-blocking and
	// the claim would pay 0 forever.
	if acs.tierFinal || acs.tier != tierMidX {
		t.Fatalf("a provClose must land at the default MID and stay unfinalized: "+
			"final=%v tier=%d", acs.tierFinal, acs.tier)
	}
	if !mayAnswerInPriority(c, alice) {
		t.Fatal("and must give the answerer's priority slot back")
	}

	// And the dead claim: deposit refunded, fee BURNED — again both decrements.
	testing.SkipHeights(deadClaimTimeout)
	testing.SetRealm(testing.NewUserRealm(bob)) // permissionless
	CloseDeadClaim(cross(cur), "cdl", dead)
	check(c, "after a dead claim refunded its deposit and burned its fee")

	// Nothing is left escrowed on either claim, so the ledger must be empty — the
	// assertion that a ledger merely drifting DOWN would also have to satisfy.
	if c.deposit != 0 {
		t.Fatalf("with both claims disposed the ledger must be empty, got %d", c.deposit)
	}
}

// The invariant court.gno's `deposit` field says it exists for, shared by the fixtures
// that drive each disposal path: the court's ledger equals what its claims still hold.
func ledgerMatchesClaims(t *testing.T, c *Court, when string) {
	t.Helper()
	total := int64(0)
	for id := uint64(1); id <= c.nextID; id++ {
		cs := mustClaim(c, id)
		total += cs.deposit + cs.fee
	}
	if c.deposit != total {
		t.Fatalf("%s: the court's deposit ledger says %d, its claims hold %d",
			when, c.deposit, total)
	}
}

// The other two disposal paths that must maintain the same ledger: a claim that
// CRYSTALLIZES (deposit and fee released at the draw) and a claim whose conclusive LOW
// burns them. Their own court, so neither claim's windows are pushed around by the
// other fixture's clock.
func TestCourtDepositLedgerAcrossDrawAndBurn(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cdl2-alice")
	bob := testutils.TestAddress("cdl2-bob")
	carol := testutils.TestAddress("cdl2-carol")
	c := testCourt(cur, "cdl2", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	drawn := OpenClaim(cross(cur), "cdl2", "a claim that reaches its draw")
	junk := OpenClaim(cross(cur), "cdl2", "a claim the crowd votes junk")
	ledgerMatchesClaims(t, c, "after opening two claims")

	matureOI(cur, "cdl2", drawn, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "cdl2", drawn, sideYES)
	matureOI(cur, "cdl2", junk, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "cdl2", junk, sideYES)

	// The junk claim first: a conclusive low burns the deposit AND the fee.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenFlag(cross(cur), "cdl2", junk)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "cdl2", junk, qualityLow)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), "cdl2", junk)
	if jcs := mustClaim(c, junk); jcs.deposit != 0 || jcs.fee != 0 {
		t.Fatalf("setup: a conclusive low must burn the deposit and fee: %d/%d",
			jcs.deposit, jcs.fee)
	}
	ledgerMatchesClaims(t, c, "after a conclusive low burned a deposit and fee")

	// Then the drawn claim through settle and crystallize.
	SettleUndisputed(cross(cur), "cdl2", drawn)
	testing.SkipHeights(100_000) // cross a period so the reservoir has a budget
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "cdl2", drawn)
	if dcs := mustClaim(c, drawn); dcs.deposit != 0 || dcs.fee != 0 {
		t.Fatalf("setup: crystallize must release the deposit and fee: %d/%d",
			dcs.deposit, dcs.fee)
	}
	ledgerMatchesClaims(t, c, "after a claim crystallized")

	if c.deposit != 0 {
		t.Fatalf("both claims disposed: the ledger must be empty, got %d", c.deposit)
	}
}

// THE BODY. COURTS_STRUCTURE.md §4 gives it two properties and both are load
// bearing, so both are pinned here: it is bounded, and it goes through the same
// moderation gate as the title.
//
// The gate is the one that matters. The body is the bigger text surface of the
// two by a factor of ten, so a ClaimBody read that returned the field directly
// would let a purged claim answer with exactly the text the purge exists to
// remove — and the title tombstone above it would make the page look moderated
// while it leaked.
func TestClaimBodyIsBoundedAndModerated(cur realm, t *testing.T) {
	alice := testutils.TestAddress("bdy-alice")
	testCourt(cur, "bdy", alice, 50_000_000_000)

	long := ""
	for i := 0; i < maxClaimBodyLen+1; i++ {
		long += "x"
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "claim body is at most", func() {
		OpenClaimP(cross(cur), "bdy", "bounded?", long)
	})
	// The boundary itself is accepted, so the guard is not refusing everything.
	testing.SetRealm(testing.NewUserRealm(alice))
	OpenClaimP(cross(cur), "bdy", "at the boundary", long[:maxClaimBodyLen])

	// A body survives the round trip, and OpenClaim still works with none.
	testing.SetRealm(testing.NewUserRealm(alice))
	withBody := OpenClaimP(cross(cur), "bdy", "has a body",
		"What would settle this: the published inspection report.")
	uassert.True(t, strings.Contains(ClaimBody("bdy", withBody), "inspection report"))
	testing.SetRealm(testing.NewUserRealm(alice))
	noBody := OpenClaim(cross(cur), "bdy", "has no body")
	uassert.Equal(t, "", ClaimBody("bdy", noBody))

	// PURGED: the body reads empty, and the title still carries the tombstone.
	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeClaim(cross(cur), "bdy", withBody, "CSAM")
	uassert.Equal(t, "", ClaimBody("bdy", withBody))
	uassert.True(t, strings.Contains(ClaimTitle("bdy", withBody), "removed"))
}

// An ordinary court's filing deposit is its OWN fraction of supply, not the dust.
//
// effMinDeposit is max(minClaimDepositCC, ordDepositFloorBps of supply) for every
// court but meta, and court.gno says why that fraction exists at all: it was unpegged
// from effMinAnswerX/100, "which failed §5.3 arithmetically: a 50-row flood parked
// half of ONE self-answer escape".
//
// NOTHING ASSERTED THE BPS ARM. Measured: raising ordDepositFloorBps from 1 to 5
// survived the whole kourtv2 suite. Its sibling ordAnswerXFloorBps is CAUGHT — by
// TestAnswerBondCapBindsWhenTheFloorIsBelowIt, a test written ABOUT that floor — so
// the answer-bond floor was pinned and the deposit floor declared on the next line of
// court.gno was not.
//
// THE SEAL COMES FROM matureOI, NOT FROM A BARE SkipHeights, and that is the whole
// shape of this fixture. supplyFloor reads PastTotal(epoch-1), so the FIRST claim on
// a fresh court is always priced at the dust arm and the bps constant is unreachable.
// Advancing the clock directly does reach it — and leaks: a bare
// SkipHeights(epochBlocks+1) here moved the epoch under
// TestTheAssociationCapsBindAtTheirStatedNumbers, which then aborted on "not enough CC"
// in AddAssociation. It passes alone and failed only in company, which is the reason this
// repo's standing rule is to run the FULL suite before believing a green one.
//
// So the epoch is sealed the way the answer-floor test seals it, by maturing the OI
// ring on a throwaway first claim, and the assertion lands on a SECOND claim opened
// afterwards.
func TestAnOrdinaryCourtsDepositFloorIsItsOwnFractionOfSupply(cur realm, t *testing.T) {
	alice := testutils.TestAddress("odep-alice")
	const supply = int64(500_000_000_000) // 500k CC; 0.01% of it is 50 CC, well over dust
	c := testCourt(cur, "odep", alice, supply)

	testing.SetRealm(testing.NewUserRealm(alice))
	first := OpenClaim(cross(cur), "odep", "a throwaway to seal an epoch")
	matureOI(cur, "odep", first, alice, 350_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "odep", "what does filing cost here")

	// THE EXPECTATION IS A LITERAL, AND THAT IS THE POINT. Writing it as
	// `supply * ordDepositFloorBps / 10000` reads better and CANNOT FAIL: the
	// mutation moves the constant, the expectation moves with it, and the assertion
	// passes either way. Measured — the first version of this test was written that
	// way and the row still SURVIVED after it landed. 50 CC is 0.01% of 500k CC,
	// stated once here so the number this court charges is pinned rather than
	// re-derived from the thing under test.
	const wantDeposit = int64(50_000_000)
	got := mustClaim(c, id).deposit
	if got != wantDeposit {
		t.Errorf("deposit = %d, want %d — 0.01%% of a %d supply",
			got, wantDeposit, supply)
	}
	// THE ARM THAT MAKES THE ONE ABOVE MEAN SOMETHING. Without it a fixture that
	// silently fell back to dust would pass while measuring nothing — and it did
	// exactly that once, which is how the leak above was found.
	if got == c.params.minClaimDepositCC {
		t.Error("the deposit fell back to the dust floor, so the bps arm this test " +
			"exists for was never reached")
	}
}

// THE OI RING IS A WEEK OF HOURLY BUCKETS, and nothing said so. twapBuckets sizes
// the ring that conviction and the trailing-average quorum are computed from — the
// most load-bearing of the six unrowed constants after the two money floors — and
// it had neither a row nor a symbolic test reference.
//
// Both expectations are LITERALS. `twapBuckets*8` would move together with the
// constant it is supposed to hold still, which is the trap the deposit-floor pin
// above fell into on its first draft.
//
// The ring is a VALUE type whose methods return a new Ring, so the second arm
// fills a COPY and the claim's own ring is never touched. Nothing leaks out of
// this test, which is why it can afford 400 observations.
func TestTheOpenInterestRingIsExactlyAWeekOfHourlyBuckets(cur realm, t *testing.T) {
	alice := testutils.TestAddress("oiring-alice")
	c := testCourt(cur, "oiring", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "oiring", "how wide is the ring")

	cs := mustClaim(c, id)
	if got := len(cs.oi.Bytes()); got != 1344 {
		t.Errorf("the OI ring's buffer is %d bytes, want 1344 — a week of 168 hourly "+
			"buckets at 8 bytes each", got)
	}
	// AND IT CAPS AT A WEEK. Filling well past capacity is the arm that would still
	// fail if the buffer were sized right but the window were not: `filled` is what
	// maturity is judged on, so this is the number a quorum actually sees.
	r := cs.oi
	for k := int64(0); k < 400; k++ {
		r = r.Observe(heightNow()+k*epochBlocks, (k+1)*1_000_000)
	}
	if got := r.Filled(); got != 168 {
		t.Errorf("400 hourly observations filled %d buckets, want 168: the ring caps at "+
			"a week, and any other number is a different trailing window", got)
	}
}
