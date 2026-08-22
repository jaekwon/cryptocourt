package kourtv2

import (
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
)

// approveAction IS THE WHOLE m-of-n MACHINE — every moderation act and every global
// DAO act routes through it — and a sweep of it caught eight of twelve. These pin
// three of the four that survived. Each is a way for FEWER signatures than the
// threshold to move an act, or for a signature to say something its signer did not.
//
// The fourth survivor is the TTL boundary, below.

// AN APPROVAL IS SPENT WHEN IT FIRES. `pending.Remove(key)` on the firing path was
// deletable with nothing failing, and what that buys is not a leak of storage: the
// entry stays with its m approvers, so the NEXT single member to approve the same key
// pushes the count to m+1 and fires the act again. One signature then re-executes an
// m-of-n decision, for as long as the entry lives.
//
// The ordering is the test: fire, UNDO, then approve once. Without the undo the
// re-fire is invisible, because the act's effect is already in place — which is
// exactly why the existing m-of-n tests miss it.
func TestAFiredApprovalIsSpentRatherThanLeftBanked(cur realm, t *testing.T) {
	creator := testutils.TestAddress("auth1-creator")
	m1 := testutils.TestAddress("auth1-m1")
	m2 := testutils.TestAddress("auth1-m2")
	m3 := testutils.TestAddress("auth1-m3")
	testCourt(cur, "auth1", creator, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	id := OpenClaim(cross(cur), "auth1", "a claim to hide twice")
	testing.SetRealm(testing.NewUserRealm(creator))
	AppointMods(cross(cur), "auth1", 2, m1, m2, m3)

	// Two signatures hide it.
	testing.SetRealm(testing.NewUserRealm(m1))
	HideItem(cross(cur), "auth1", id, "off-topic")
	testing.SetRealm(testing.NewUserRealm(m2))
	HideItem(cross(cur), "auth1", id, "off-topic")
	if !HiddenFromListing("auth1", id) {
		t.Fatal("setup: two of three must hide the claim")
	}

	// Two more undo it, on a different key.
	testing.SetRealm(testing.NewUserRealm(m1))
	UnhideItem(cross(cur), "auth1", id, "reconsidered")
	testing.SetRealm(testing.NewUserRealm(m2))
	UnhideItem(cross(cur), "auth1", id, "reconsidered")
	if HiddenFromListing("auth1", id) {
		t.Fatal("setup: two of three must unhide it again")
	}

	// ONE signature must not re-fire the spent approval.
	testing.SetRealm(testing.NewUserRealm(m3))
	HideItem(cross(cur), "auth1", id, "off-topic")
	if HiddenFromListing("auth1", id) {
		t.Fatal("one signature re-fired an m-of-2 approval that had already fired")
	}

	// PAIRED: a second signature still hides it, so the refusal above is the spend
	// and not a fixture that stopped being able to hide anything.
	testing.SetRealm(testing.NewUserRealm(m1))
	HideItem(cross(cur), "auth1", id, "off-topic")
	if !HiddenFromListing("auth1", id) {
		t.Fatal("a fresh pair of signatures must still hide the claim")
	}
}

// A BANKED SIGNATURE IS STALE ON ITS DEADLINE BLOCK, not one block later.
// approveAction discards an entry when `now >= openedAt+pendingTTLBlocks`, and the
// operator survived: no fixture visited the edge, because the stale test skips a whole
// TTL and the live test skips nothing.
//
// Both halves, on two courts, because the state is consumed either way: one block
// SHORT of the deadline the banked signature still counts and the act fires; ON the
// deadline it does not.
func TestABankedSignatureExpiresOnItsDeadlineBlock(cur realm, t *testing.T) {
	m1 := testutils.TestAddress("auth2-m1")
	m2 := testutils.TestAddress("auth2-m2")

	// One block short: the pair still fires.
	creator := testutils.TestAddress("auth2-creator")
	testCourt(cur, "auth2", creator, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	early := OpenClaim(cross(cur), "auth2", "hidden just in time")
	testing.SetRealm(testing.NewUserRealm(creator))
	AppointMods(cross(cur), "auth2", 2, m1, m2)
	testing.SetRealm(testing.NewUserRealm(m1))
	HideItem(cross(cur), "auth2", early, "off-topic")
	testing.SkipHeights(pendingTTLBlocks - 1)
	testing.SetRealm(testing.NewUserRealm(m2))
	HideItem(cross(cur), "auth2", early, "off-topic")
	if !HiddenFromListing("auth2", early) {
		t.Fatal("one block short of the deadline a banked signature must still count")
	}

	// ON the deadline: the banked signature is gone, so the second approval opens a
	// fresh proposal and nothing fires.
	creator3 := testutils.TestAddress("auth3-creator")
	testCourt(cur, "auth3", creator3, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(creator3))
	late := OpenClaim(cross(cur), "auth3", "not hidden in time")
	testing.SetRealm(testing.NewUserRealm(creator3))
	AppointMods(cross(cur), "auth3", 2, m1, m2)
	testing.SetRealm(testing.NewUserRealm(m1))
	HideItem(cross(cur), "auth3", late, "off-topic")
	testing.SkipHeights(pendingTTLBlocks)
	testing.SetRealm(testing.NewUserRealm(m2))
	HideItem(cross(cur), "auth3", late, "off-topic")
	if HiddenFromListing("auth3", late) {
		t.Fatal("a signature banked a full TTL ago must not count on the deadline block")
	}
	// PAIRED: the fresh proposal DOES fire on its own second signature.
	testing.SetRealm(testing.NewUserRealm(m1))
	HideItem(cross(cur), "auth3", late, "off-topic")
	if !HiddenFromListing("auth3", late) {
		t.Fatal("the fresh proposal must fire once it has its own two signatures")
	}
}

// SEATING A KEY DISCARDS THE BANKED SIGNATURES, on the path that once did not.
// seatGlobalMember's comment records the hole as history: AddGlobalMod cleared the
// banked approvals when the member set changed and TransferGlobalAdmin did not, which
// made the transfer "the STRICTLY BETTER route for an admin wanting to complete a stuck
// purge: seat a fresh key without resetting the signatures banked against the old set."
// Both paths share those lines now. The wipe is there and nothing held it — the fix was one line
// and the test for it was never written, which is the shape a regression comes back in.
//
// The act chosen is a PURGE, because that is the irreversible one the comment names.
func TestTransferringTheGlobalSeatDiscardsBankedSignatures(cur realm, t *testing.T) {
	alice := testutils.TestAddress("auth4-alice")
	testCourt(cur, "auth4", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "auth4", "a claim someone wants gone")

	// THE LIVE ADMIN, not DirectoryAdmin(): the global DAO is a package singleton and
	// its seat can have been moved by an earlier test in the same process. Reading it
	// is what makes this test order-independent.
	dadmin := ensureGlobalDAO().admin
	g2 := testutils.TestAddress("auth4-g2")
	fresh := testutils.TestAddress("auth4-fresh")
	testing.SetRealm(testing.NewUserRealm(dadmin))
	AddGlobalMod(cross(cur), g2)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 2)

	// One signature banked.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeClaim(cross(cur), "auth4", id, "CSAM")
	if strings.Contains(Render("auth4/"+itoa(int64(id))), "removed") {
		t.Fatal("setup: one of two must not purge")
	}

	// The seat moves to a key that is not yet a member, which seats it — and that is
	// a membership change, so every banked signature is void.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	TransferGlobalAdmin(cross(cur), fresh)

	// The second signature is now the FIRST of a fresh proposal.
	testing.SetRealm(testing.NewUserRealm(g2))
	PurgeClaim(cross(cur), "auth4", id, "CSAM")
	if strings.Contains(Render("auth4/"+itoa(int64(id))), "removed") {
		t.Fatal("a signature banked before the seat moved must not count toward the purge")
	}

	// PAIRED: a second signature on the fresh proposal does purge it, so the refusal
	// above is the wipe and not a threshold nobody can reach.
	testing.SetRealm(testing.NewUserRealm(fresh))
	PurgeClaim(cross(cur), "auth4", id, "CSAM")
	if !strings.Contains(Render("auth4/"+itoa(int64(id))), "removed") {
		t.Fatal("two signatures gathered after the change must purge")
	}

	// PUT THE SEAT BACK. The global DAO is one object for the whole package, so a test
	// that moves the admin seat breaks every later test that manages membership — which
	// is how this one first failed, with "only the global DAO admin manages membership"
	// from a test three functions further down. Transferring to an EXISTING member seats
	// nobody and wipes nothing, so the restore is not itself an act under test.
	testing.SetRealm(testing.NewUserRealm(fresh))
	TransferGlobalAdmin(cross(cur), dadmin)
	if ensureGlobalDAO().admin != dadmin {
		t.Fatal("the seat must be restored, or every later test inherits this one")
	}
}

// THE REASON THAT LANDS IS THE ONE THE SET SIGNED UP TO. approveAction stores the
// reason when it OPENS a proposal and returns that stored copy when the proposal
// fires; returning the firing caller's own argument instead survived the sweep. It is
// not a cosmetic difference on a purge: the reason IS the statutory category code that
// the tombstone shows in place of the text, forever, on every surface. Whoever signs
// last would choose it alone, which is the one thing an m-of-n act must not let a
// single member do.
//
// Pinned as shipped rather than treated as a toss-up: the first approver's text is
// what the later signatures were added TO, so it is the only copy that every approver
// can be said to have agreed with.
func TestTheReasonRecordedIsTheOneTheProposalOpenedWith(cur realm, t *testing.T) {
	alice := testutils.TestAddress("auth5-alice")
	testCourt(cur, "auth5", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "auth5", "a claim with two opinions about why")

	dadmin := ensureGlobalDAO().admin
	second := testutils.TestAddress("auth5-second")
	testing.SetRealm(testing.NewUserRealm(dadmin))
	AddGlobalMod(cross(cur), second)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 2)

	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeClaim(cross(cur), "auth5", id, "OPENEDWITH")
	testing.SetRealm(testing.NewUserRealm(second))
	PurgeClaim(cross(cur), "auth5", id, "FIREDWITH")

	page := Render("auth5/" + itoa(int64(id)))
	if !strings.Contains(page, "removed") {
		t.Fatalf("setup: two signatures must purge the claim: %s", page)
	}
	if !strings.Contains(page, "OPENEDWITH") {
		t.Errorf("the tombstone must carry the code the proposal opened with: %s", page)
	}
	if strings.Contains(page, "FIREDWITH") {
		t.Error("the last signer's own text must not become the statutory code")
	}
}
