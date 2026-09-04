package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// FOUR THINGS meta.gno's franchise and latch promise in comments and nothing held.
// All four survived the whole suite in a clean tree, not merely a filtered slice — the
// filter's own survivors were checked against the full 17 suites first, because last
// time four of five "gaps" turned out to be the filter.

// A CURVE AT ITS CAP CLAMPS AND KEEPS THE ENTITLEMENT. ClaimMetaFranchise's own comment
// says so — "the curve is at its cap: clamp silently, keep the entitlement" — and
// narrowing `delta <= 0` to `< 0` survived everything. What the mutant does is worse
// than a wrong number: it falls through to `used >= owed` and REMOVES the row, so a
// holder who claims one block too early loses a burn they already paid for, silently
// and permanently.
//
// The cap is occupied directly. mc.minted is the curve position and setting it is what
// a full curve IS; buying to the cap would cost the entire supply cap in GNOT.
func TestAFranchiseSurvivesACurveAtItsCap(cur realm, t *testing.T) {
	who := testutils.TestAddress("frcap-who")
	c := testCourt(cur, "frcap", who, 1_000_000)
	mc := mustCourt(metaSlug)

	accrueFranchise(c, who, 5_000_000)
	owed := FranchiseOf(who)
	if owed != 5_000_000 {
		t.Fatalf("setup: the burn must accrue an entitlement, got %d", owed)
	}

	keep := mc.minted
	mc.minted = mc.crv.Cap()
	defer func() { mc.minted = keep }()
	if d, _ := mc.crv.Minted(mc.minted, owed); d != 0 {
		t.Fatalf("setup: a curve at its cap must mint nothing, got %d", d)
	}

	testing.SetRealm(testing.NewUserRealm(who))
	if got := ClaimMetaFranchise(cross(cur)); got != 0 {
		t.Errorf("a claim against a full curve must mint nothing, got %d", got)
	}
	if got := FranchiseOf(who); got != owed {
		t.Fatalf("the entitlement must survive a full curve: %d, was %d", got, owed)
	}
}

// A PARTIAL FILL KEEPS ITS REMAINDER. `franchise.Set(k, owed-used)` narrowed to
// `franchise.Set(k, owed)` also survived: the holder is minted their partial fill AND
// keeps the whole entitlement, so the next claim mints against a burn already spent.
// That is issuance out of nothing, bounded only by how often the curve frees room.
//
// One unit below the cap, so the fill is genuinely partial and the supply this test
// leaves behind is one unit — and even that is put back, because meta's supply is read
// by every court's deposit floor.
func TestAPartialFranchiseFillKeepsItsRemainder(cur realm, t *testing.T) {
	who := testutils.TestAddress("fpart-who")
	c := testCourt(cur, "fpart", who, 1_000_000)
	mc := mustCourt(metaSlug)

	accrueFranchise(c, who, 900_000_000)
	owed := FranchiseOf(who)
	if owed <= 0 {
		t.Fatal("setup: the burn must accrue an entitlement")
	}

	keepMinted := mc.minted
	mc.minted = mc.crv.Cap() - 1
	delta, used := mc.crv.Minted(mc.minted, owed)
	if delta <= 0 || used <= 0 || used >= owed {
		t.Fatalf("setup: the fill must be PARTIAL — delta=%d used=%d owed=%d",
			delta, used, owed)
	}

	testing.SetRealm(testing.NewUserRealm(who))
	got := ClaimMetaFranchise(cross(cur))
	if got != delta {
		t.Errorf("the claim must mint what the curve allows: %d, want %d", got, delta)
	}
	left := FranchiseOf(who)
	if left >= owed {
		t.Fatalf("a partial fill must SPEND what it used: %d left of %d", left, owed)
	}
	if left != owed-used {
		t.Errorf("the remainder must be exactly what was not spent: %d, want %d",
			left, owed-used)
	}

	// Put meta back as it was found: the coin minted here and the curve position. Every
	// court's deposit floor is a fraction of meta's supply, so a test that leaves it
	// moved is a test that moves other tests' thresholds.
	mc.coin.Burn(who, got)
	mc.minted = keepMinted
	franchise.Remove(who.String())
}

// THE MINT LEAVES META'S ACCRUAL CLOCK CURRENT. ClaimMetaFranchise calls touch(mc)
// before minting and says why in one line — "the mint changes meta's live supply; its
// accrual clock must be current" — and deleting the call survived everything. The
// consequence is not the mint, it is the NEXT accrual: emission prices a period's budget
// from the supply it reads at the roll, so blocks that elapsed under the old supply get
// paid at the new one.
//
// Asserted as the post-condition rather than the effect, because the post-condition is
// what the comment claims and it holds whatever the emission maths does later. The
// clock is deliberately made stale first, or the assertion would pass on a fixture where
// it was current anyway.
func TestClaimingAFranchiseLeavesMetasAccrualClockCurrent(cur realm, t *testing.T) {
	who := testutils.TestAddress("fclk-who")
	c := testCourt(cur, "fclk", who, 1_000_000)
	mc := mustCourt(metaSlug)
	accrueFranchise(c, who, 2_000_000)

	// THE CLOCK IS MADE STALE BY MOVING META'S OWN CURSOR BACK, not by advancing the
	// chain. The first version skipped an epoch and broke a LATER test with "checkpoint:
	// the clock went backwards" from meta's supply checkpoint: the mint below stamps
	// meta's shared ledger at whatever epoch this test is standing in, so a test that
	// advances the height and then writes to META leaves a stamp in the future that the
	// next writer cannot get under. Moving lastAccrual back occupies the same state
	// without touching the world every other test shares.
	mc.lastAccrual = heightNow() - 5
	if mc.lastAccrual >= heightNow() {
		t.Fatalf("setup: the clock must be stale before the claim, %d vs %d",
			mc.lastAccrual, heightNow())
	}

	testing.SetRealm(testing.NewUserRealm(who))
	minted := ClaimMetaFranchise(cross(cur))
	if minted <= 0 {
		t.Fatalf("setup: the claim must actually mint, got %d", minted)
	}
	if mc.lastAccrual != heightNow() {
		t.Fatalf("the mint must leave meta's accrual clock current: %d, now %d",
			mc.lastAccrual, heightNow())
	}
	mc.coin.Burn(who, minted)
}

// RELEASING A LATCH RELEASES YOUR OWN. releaseMetaLatch checks `held.(uint64) == cs.id`
// before removing, and dropping that check survived everything.
//
// WHY IT IS REACHABLE, which is the whole reason this is a test and not a note: the
// release is called at every TERMINAL event, and there are four call sites —
// CloseDeadClaim, OpenRewards, dispute.gno's finalize, and meta.gno's own. Finalize and
// OpenRewards are SEQUENTIAL on the same claim, so an ordinary meta appeal calls its own
// release twice. Between those two calls another appeal on the same target may take the
// freed slot, and the second call then hands that slot away — leaving a live appeal with
// no latch and the target open to a swarm, which is the one thing latchKey exists to
// stop.
//
// Pinned at the unit, because releaseMetaLatch reads nothing but cs.id: building two
// real appeals through the parser costs a five-second fixture and would measure the
// parser, not this.
func TestReleasingALatchOnlyReleasesYourOwn(cur realm, t *testing.T) {
	bind := modParse{verb: verbUnhide, court: "flatch", target: 42, valid: true}
	k := latchKey(bind)

	mine := &claimState{id: 9_001}
	theirs := &claimState{id: 9_002}
	b1, b2 := bind, bind
	meta.bindings.Set(beClaimKey(mine.id), &b1)
	meta.bindings.Set(beClaimKey(theirs.id), &b2)
	// The slot is held by the OTHER appeal — the state a second, idempotent release
	// walks into.
	meta.latches.Set(k, theirs.id)

	releaseMetaLatch(mine)
	held := meta.latches.Get(k)
	if held == nil {
		t.Fatal("a second release must not hand away a slot another appeal holds")
	}
	uassert.Equal(t, theirs.id, held.(uint64))

	// PAIRED: the holder's OWN release does free it, so the check above is ownership
	// and not a latch that cannot be released at all.
	releaseMetaLatch(theirs)
	if meta.latches.Get(k) != nil {
		t.Fatal("the holder's own release must free the slot")
	}
	meta.bindings.Remove(beClaimKey(mine.id))
	meta.bindings.Remove(beClaimKey(theirs.id))
}
