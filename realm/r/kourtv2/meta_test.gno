package kourtv2

import (
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// The parser accepts only exact schemas; a near-miss is an ordinary claim, so
// it can never masquerade as binding. Pure — touches no state.
func TestMetaParser(cur realm, t *testing.T) {
	ok := []struct {
		title string
		verb  string
		court string
		tgt   uint64
	}{
		{"mod:unhide:foo/7", verbUnhide, "foo", 7},
		{"mod:clear:foo-bar/1", verbClear, "foo-bar", 1},
		{"mod:hide:x9/42", verbHide, "x9", 42},
		{"mod:setmods:foo/3", verbSetmods, "foo", 3},
		{"mod:suspend:foo", verbSuspend, "foo", 0},
		{"mod:unsuspend:foo", verbUnsuspend, "foo", 0},
	}
	for _, c := range ok {
		p := parseModTitle(c.title)
		if !p.valid || p.verb != c.verb || p.court != c.court || p.target != c.tgt {
			t.Fatalf("should parse %q", c.title)
		}
	}
	bad := []string{
		"xmod:hide:foo/1", "mod:hide:foo", "mod:hide:foo/", "mod:hide:/1",
		"mod:hide:foo/0", "mod:hide:FOO/1", "mod:bogus:foo/1", "mod:suspend:foo/1",
		"mod:hide:foo/abc", "ordinary claim title", "mod:",
	}
	for _, ti := range bad {
		if parseModTitle(ti).valid {
			t.Fatalf("should NOT parse %q", ti)
		}
	}
	// The setmods latch is keyed per COURT, so two different candidate sets on
	// one court contend for the same slot (unlimited parallel installs on one
	// court were how a banked-verdict attack would have worked).
	a := latchKey(modParse{verb: verbSetmods, court: "foo", target: 1})
	b := latchKey(modParse{verb: verbSetmods, court: "foo", target: 2})
	if a != b {
		t.Fatal("setmods must share one latch per court")
	}
	if latchKey(modParse{verb: verbUnhide, court: "foo", target: 1}) ==
		latchKey(modParse{verb: verbUnhide, court: "foo", target: 2}) {
		t.Fatal("item verbs latch per target")
	}
}

// The meta court is a SINGLETON created at realm init, and gno resets the block
// height between test functions — so every test that drives meta's lifecycle
// must live in one function, or a later test writes a coin checkpoint at a
// lower epoch than an earlier one ("the clock went backwards"). Hence one
// sequential scenario covering every execution guard.
// Enforces I8: ExecuteMetaVerdict's fixed check order, exactly-once execution,
// direction-scoped cooldown, and the PostAnswer latch.
func TestMetaLifecycleGuards(cur realm, t *testing.T) {
	alice := testutils.TestAddress("mtx-alice")
	bob := testutils.TestAddress("mtx-bob")
	mc := mustCourt(metaSlug)
	mc.coin.Mint(alice, 500_000_000_000)
	mc.coin.Mint(bob, 500_000_000_000)
	// Seal the epoch holding these mints before anything reads a floor. Meta's
	// answerability floor is a fraction of SEALED supply (v0.15), so until this
	// lands it reads the pre-history case and answers with the dust arm.
	testing.SkipHeights(epochBlocks * 2)

	// appeal drives a meta claim to VERDICT_FINAL on the undisputed route.
	// The stake is DERIVED from the live floor rather than a literal: meta's
	// answerability floor is a fraction of meta supply (v0.15), so a constant
	// here would silently stop clearing it the next time the fraction moves.
	// matureOI stakes its amount three times, so one floor's worth per round is
	// 3× headroom — ample against emission drift during the epoch skips.
	appeal := func(title string) uint64 {
		testing.SkipHeights(1) // the target must strictly predate the appeal
		testing.SetRealm(testing.NewUserRealm(alice))
		id := OpenClaim(cross(cur), metaSlug, title)
		matureOI(cur, metaSlug, id, alice, 2*effMinAnswerX(mc))
		testing.SetRealm(testing.NewUserRealm(alice))
		PostAnswer(cross(cur), metaSlug, id, sideYES)
		testing.SkipHeights(settleDelay + 1)
		testing.SetRealm(testing.NewUserRealm(alice))
		SettleUndisputed(cross(cur), metaSlug, id)
		return id
	}

	// ---- 1. a RESTORATIVE verb executes from silence, exactly once ----------
	testCourt(cur, "mtx1", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	t1 := OpenClaim(cross(cur), "mtx1", "hidden by mods")
	testing.SetRealm(testing.NewUserRealm(alice))
	HideItem(cross(cur), "mtx1", t1, "spam")

	ap1 := appeal("mod:unhide:mtx1/1")
	testing.SetRealm(testing.NewUserRealm(alice))
	ExecuteMetaVerdict(cross(cur), ap1)
	if HiddenFromListing("mtx1", t1) {
		t.Fatal("a restorative verdict should clear the courtMod bit")
	}
	if !AppealExecuted(ap1) {
		t.Fatal("the appeal should be marked executed")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "already executed", func() {
		ExecuteMetaVerdict(cross(cur), ap1)
	})

	// ---- 2. an AGGRESSIVE verb is REFUSED on silence ------------------------
	testCourt(cur, "mtx2", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	OpenClaim(cross(cur), "mtx2", "target")
	ap2 := appeal("mod:hide:mtx2/1")
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "decided contested vote", func() {
		ExecuteMetaVerdict(cross(cur), ap2)
	})
	if HiddenFromListing("mtx2", 1) {
		t.Fatal("silence must never hide")
	}

	// ---- 3. a NO-OP unhide stamps nothing -----------------------------------
	testCourt(cur, "mtx3", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	OpenClaim(cross(cur), "mtx3", "never hidden")
	before := ModLogLen("mtx3", 1)
	ap3 := appeal("mod:unhide:mtx3/1")
	testing.SetRealm(testing.NewUserRealm(alice))
	ExecuteMetaVerdict(cross(cur), ap3)
	if ModLogLen("mtx3", 1) != before {
		t.Fatal("a no-op unhide must not write a moderation act (no cooldown stamp)")
	}

	// ---- 4. the EXECUTION EXPIRY: a verdict is not a sleeper round ----------
	testCourt(cur, "mtx4", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	t4 := OpenClaim(cross(cur), "mtx4", "target")
	testing.SetRealm(testing.NewUserRealm(alice))
	HideItem(cross(cur), "mtx4", t4, "spam")
	ap4 := appeal("mod:unhide:mtx4/1")
	testing.SkipHeights(mc.params.votingBlocks + 2)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "expired", func() {
		ExecuteMetaVerdict(cross(cur), ap4)
	})
	if !HiddenFromListing("mtx4", t4) {
		t.Fatal("an expired verdict must change nothing")
	}

	// ---- 5. the STRICT PREDATE guard ---------------------------------------
	testCourt(cur, "mtx5", alice, 10_000_000_000)
	testing.SkipHeights(1)
	testing.SetRealm(testing.NewUserRealm(alice))
	ap5 := OpenClaim(cross(cur), metaSlug, "mod:unhide:mtx5/1")
	testing.SkipHeights(2)
	testing.SetRealm(testing.NewUserRealm(alice)) // the target claim is born AFTER the appeal
	OpenClaim(cross(cur), "mtx5", "created after the appeal")
	matureOI(cur, metaSlug, ap5, alice, 2*effMinAnswerX(mc))
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), metaSlug, ap5, sideYES)
	testing.SkipHeights(settleDelay + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	SettleUndisputed(cross(cur), metaSlug, ap5)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "does not predate", func() {
		ExecuteMetaVerdict(cross(cur), ap5)
	})

	// ---- 6b. the LATCH RELEASES at a terminal transition --------------------
	// ap2 was correctly refused (aggressive verb on silence). Its latch must NOT
	// outlive the appeal claim: it used to be freed only on a SUCCESSFUL
	// execution, so every refused/expired/voted-down appeal held its target's
	// review slot forever — permanently bricking that target's appeals lane and
	// permanently reverting PostAnswer for it.
	if AppealLatchHolder(verbHide, "mtx2", 1) != ap2 {
		t.Fatal("the refused appeal should hold its slot until a terminal transition")
	}
	testing.SkipHeights(priorityWindowBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), metaSlug, ap2)
	if AppealLatchHolder(verbHide, "mtx2", 1) != 0 {
		t.Fatal("a terminal transition must free the target's review slot")
	}

	// ---- 6c. the ballot must SHOW what it is asking voters to approve -------
	// Without this the electorate votes on an opaque title string and cannot see
	// which addresses a setmods appeal would seat — the amplifier that made the
	// bait-and-switch finding worth a HIGH.
	testing.SkipHeights(1)
	testing.SetRealm(testing.NewUserRealm(alice))
	seatMe := testutils.TestAddress("mtx-seat")
	candID := RegisterModCandidate(cross(cur), "mtx1", 1, seatMe)
	testing.SetRealm(testing.NewUserRealm(alice))
	shown := OpenClaim(cross(cur), metaSlug,
		"mod:setmods:mtx1/"+strconv.FormatUint(candID, 10))
	page := Render(metaSlug + "/" + strconv.FormatUint(shown, 10))
	if !strings.Contains(page, "Review request") || !strings.Contains(page, "setmods") {
		t.Fatalf("a valid appeal must render its action:\n%s", page)
	}
	if !strings.Contains(page, seatMe.String()) {
		t.Fatalf("a setmods appeal must list the addresses it would seat:\n%s", page)
	}
	// An appeal naming a candidate that does not exist yet is the bait-and-switch
	// shape and must be called out, not rendered blank.
	testing.SetRealm(testing.NewUserRealm(alice))
	ghost := OpenClaim(cross(cur), metaSlug, "mod:setmods:mtx1/9999")
	gp := Render(metaSlug + "/" + strconv.FormatUint(ghost, 10))
	if !strings.Contains(gp, "does not exist yet") {
		t.Fatalf("an unregistered candidate must be flagged:\n%s", gp)
	}

	// ---- 6. FIRST-TO-ANSWER takes the target's review slot ------------------
	testCourt(cur, "mtx6", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	t6 := OpenClaim(cross(cur), "mtx6", "contested target")
	testing.SetRealm(testing.NewUserRealm(alice))
	HideItem(cross(cur), "mtx6", t6, "spam")
	testing.SkipHeights(1)
	testing.SetRealm(testing.NewUserRealm(alice))
	first := OpenClaim(cross(cur), metaSlug, "mod:unhide:mtx6/1")
	testing.SetRealm(testing.NewUserRealm(bob))
	second := OpenClaim(cross(cur), metaSlug, "mod:unhide:mtx6/1")
	matureOI(cur, metaSlug, first, alice, 2*effMinAnswerX(mc))
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), metaSlug, first, sideYES)
	if AppealLatchHolder(verbUnhide, "mtx6", 1) != first {
		t.Fatal("the first answerer should hold the review slot")
	}
	matureOI(cur, metaSlug, second, bob, 2*effMinAnswerX(mc))
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "review slot", func() {
		PostAnswer(cross(cur), metaSlug, second, sideYES)
	})

	// ---- 8. the SUPPLY-RELATIVE floors, and the front-run they used to allow --
	// v0.15. Meta's answerability and deposit floors are fractions of ITS OWN
	// supply, because that supply tracks platform-wide burn and params have no
	// retune path. The fixed 100 CC they replaced was wrong at both ends: near
	// launch it was ~10% of meta supply, which made FILING an appeal cost more
	// than DECIDING one — the incumbency-lock-by-price that mustElectionInvariants
	// forbids in the election lane and that the appeals lane never guarded.
	supply := mc.coin.PastTotal(mc.coin.Epoch() - 1)
	wantX := supply * answerXFloorBps / 10000
	uassert.Equal(t, wantX, effMinAnswerX(mc), "answerability is a fraction of meta supply")
	uassert.Equal(t, supply*depositFloorBps/10000, effMinDeposit(mc),
		"the deposit has its own fraction, unpegged from answerability/100")
	// The property the deploy invariant certifies, checked on real state.
	filing := wantX * (10000 + answerBondBps) / 10000
	if deciding := supply * quorumSupplyBps / 10000; filing >= deciding {
		t.Fatalf("filing an appeal (%d) must cost less than winning the vote (%d)", filing, deciding)
	}

	// THE FRONT-RUN. effMinAnswerX used to read live TotalSupply(), and
	// ClaimMetaFranchise mints into supply — so a whale sitting on an unclaimed
	// entitlement could mint in the same block as an honest PostAnswer, push the
	// floor above that appellant's X̄, and revert the answer. Repeatably, for
	// free, keeping coins they were owed anyway. Reading the last SEALED epoch
	// closes it: a same-epoch mint moves TotalSupply and moves nothing else.
	beforeX, beforeD := effMinAnswerX(mc), effMinDeposit(mc)
	liveBefore := mc.coin.TotalSupply()
	mc.coin.Mint(bob, 400_000_000_000) // a whale claims a huge franchise, now
	if mc.coin.TotalSupply() <= liveBefore {
		t.Fatal("the fixture must actually move live supply for this to prove anything")
	}
	uassert.Equal(t, beforeX, effMinAnswerX(mc), "a same-epoch mint must not move the answerability floor")
	uassert.Equal(t, beforeD, effMinDeposit(mc), "a same-epoch mint must not move the deposit floor")

	// ---- 9. a MANUFACTURED CONTEST cannot seize authority (v0.15) -----------
	// The forge that survived the decidedRounds guard: hold 5% of meta supply,
	// self-answer, have a confederate dispute, then vote your own weight to
	// UPHOLD with nobody opposing. The round is quorate, so it decides and
	// stamps route="vote" — a contested-LOOKING verdict bought with zero
	// adversarial weight. credEligible is the test that sees through it (it
	// asks whether the OVERTURN side carried >= floor/4), and until v0.15 only
	// `setmods` consulted it, leaving suspend/unsuspend purchasable this way.
	testCourt(cur, "mtx9", alice, 10_000_000_000)
	testing.SkipHeights(epochBlocks * 2) // seal, and let the target predate
	sup9 := CourtSuspended("mtx9")
	if sup9 {
		t.Fatal("fixture: mtx9 must start unsuspended")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	ap9 := OpenClaim(cross(cur), metaSlug, "mod:suspend:mtx9")
	matureOI(cur, metaSlug, ap9, alice, 2*effMinAnswerX(mc))
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), metaSlug, ap9, sideYES)

	// The confederate disputes AND upholds. Bob never staked, so he is not a
	// participant and may vote — which is the point: v0.30's participant guard
	// stops the answerer voting their own verdict, and an attacker answers that
	// by using a second address, exactly as this fixture now does. The guard is
	// hygiene; credEligible is the defence.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), metaSlug, ap9)
	testing.SetRealm(testing.NewUserRealm(bob))
	VoteDispute(cross(cur), metaSlug, ap9, "no") // uphold, unopposed
	testing.SkipHeights(mc.params.votingBlocks + 1)
	ResolveDispute(cross(cur), metaSlug, ap9)

	cs9 := mustClaim(mc, ap9)
	if cs9.decidedRounds != 1 || Provisional(metaSlug, ap9) != sideYES {
		t.Fatal("fixture: the round must DECIDE and uphold, or this proves nothing")
	}
	if cs9.credEligible {
		t.Fatal("fixture: nobody opposed, so the round must NOT be credEligible")
	}
	testing.SkipHeights(cs9.escrowUntil - runtimeHeight() + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), metaSlug, ap9)

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "weight voted against it", func() {
		ExecuteMetaVerdict(cross(cur), ap9)
	})
	if CourtSuspended("mtx9") {
		t.Fatal("a manufactured contest must not suspend a court's moderators")
	}

	// ---- 10. a stale verdict cannot overturn the GLOBAL DAO -----------------
	// The global DAO is the legal backstop, and its suspension verbs used to
	// stamp nothing at all — so a meta verdict filed BEFORE a global decision
	// could execute after it and silently undo it. Here the global DAO suspends
	// mtx10 and then clears it while the appeal is in flight; the appeal's
	// `suspend` verdict must refuse rather than re-suspend a court the backstop
	// just released. Only OPPOSITE-direction acts refuse — a same-direction one
	// has already achieved the verdict's goal.
	carol := testutils.TestAddress("mtx-carol")
	mc.coin.Mint(carol, 100_000_000_000) // enough to clear floor/4, not to outvote alice
	testCourt(cur, "mtx10", alice, 10_000_000_000)
	testing.SkipHeights(epochBlocks * 2) // seal the mint AND let the target predate

	testing.SetRealm(testing.NewUserRealm(alice))
	ap10 := OpenClaim(cross(cur), metaSlug, "mod:suspend:mtx10")
	matureOI(cur, metaSlug, ap10, alice, 2*effMinAnswerX(mc))
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), metaSlug, ap10, sideYES)

	// A genuinely contested round: carol carries real overturn weight (>= floor/4,
	// so credEligible is set) and bob's larger uphold carries it.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), metaSlug, ap10)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), metaSlug, ap10, "yes")
	// Bob upholds, not alice: alice answered and staked, so the participant guard
	// refuses her. Bob holds more than carol, so the uphold still carries while
	// carol's weight still clears floor/4 and sets credEligible.
	testing.SetRealm(testing.NewUserRealm(bob))
	VoteDispute(cross(cur), metaSlug, ap10, "no")
	testing.SkipHeights(mc.params.votingBlocks + 1)
	ResolveDispute(cross(cur), metaSlug, ap10)

	cs10 := mustClaim(mc, ap10)
	if cs10.decidedRounds != 1 || Provisional(metaSlug, ap10) != sideYES {
		t.Fatal("fixture: the round must DECIDE and uphold")
	}
	if !cs10.credEligible {
		t.Fatal("fixture: carol's overturn weight must make the round credEligible")
	}

	// The global DAO acts while the verdict is in flight: suspend, then clear.
	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalSuspendSet(cross(cur), "mtx10")
	testing.SetRealm(testing.NewUserRealm(dadmin))
	ClearCourtSuspension(cross(cur), "mtx10")
	if CourtSuspended("mtx10") {
		t.Fatal("fixture: the global DAO must have released the court")
	}

	testing.SkipHeights(cs10.escrowUntil - runtimeHeight() + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), metaSlug, ap10)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "global DAO changed this court's suspension", func() {
		ExecuteMetaVerdict(cross(cur), ap10)
	})
	if CourtSuspended("mtx10") {
		t.Fatal("a stale verdict must not re-suspend a court the global DAO released")
	}

	// ---- 11. the predate guard's OTHER TWO ARMS -----------------------------
	// Section 5 covers the target CLAIM. The court arm and the candidate arm were
	// both deletable without any test noticing, and they are not the same guard:
	// each names a different thing that must already have existed when voters
	// judged the appeal.
	//
	// THE COURT ARM. The parse is stored when the appeal opens and existence is
	// only checked at execution, so an appeal can name a court that does not exist
	// yet. Without this guard an attacker files against a name, wins a vote on a
	// court nobody could inspect because it was not there, and creates it
	// afterwards.
	testing.SetRealm(testing.NewUserRealm(alice))
	ap11 := OpenClaim(cross(cur), metaSlug, "mod:unhide:mtx11/1")
	testing.SkipHeights(2)
	testCourt(cur, "mtx11", alice, 10_000_000_000) // the COURT is born after the appeal
	testing.SetRealm(testing.NewUserRealm(alice))
	OpenClaim(cross(cur), "mtx11", "a claim in a court that postdates the appeal")
	matureOI(cur, metaSlug, ap11, alice, 2*effMinAnswerX(mc))
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), metaSlug, ap11, sideYES)
	testing.SkipHeights(settleDelay + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	SettleUndisputed(cross(cur), metaSlug, ap11)
	testing.SetRealm(testing.NewUserRealm(alice))
	// The COURT message, not the shared "does not predate" substring: all three
	// arms share that phrase, so asserting it loosely would let the claim guard
	// stand in for this one.
	uassert.AbortsContains(t, cur, "target court does not predate", func() {
		ExecuteMetaVerdict(cross(cur), ap11)
	})

	// ---- 12. the CANDIDATE arm, which guards a named attack ----------------
	// Registration is permissionless with a predictable per-court counter, so
	// without this guard an attacker opens setmods against an id that is not
	// allocated yet, wins the vote on a candidate set nobody could inspect, and
	// only then registers their own puppet set at exactly that id.
	testCourt(cur, "mtx12", alice, 10_000_000_000)
	testing.SkipHeights(epochBlocks * 2) // the court must predate, so only the CANDIDATE is late
	testing.SetRealm(testing.NewUserRealm(alice))
	ap12 := OpenClaim(cross(cur), metaSlug, "mod:setmods:mtx12/1")
	testing.SkipHeights(2)

	// The puppet set is registered AFTER the appeal that installs it — id 1, the
	// first and therefore predictable allocation on a fresh court.
	puppet := testutils.TestAddress("mtx12-puppet")
	testing.SetRealm(testing.NewUserRealm(alice))
	if got := RegisterModCandidate(cross(cur), "mtx12", 1, puppet); got != 1 {
		t.Fatalf("fixture: the attack needs the predictable first id, got %d", got)
	}

	matureOI(cur, metaSlug, ap12, alice, 2*effMinAnswerX(mc))
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), metaSlug, ap12, sideYES)
	// setmods is AGGRESSIVE, so it needs a decided, credEligible contest — the
	// same shape section 10 builds. carol carries the overturn weight, bob upholds.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), metaSlug, ap12)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), metaSlug, ap12, "yes")
	testing.SetRealm(testing.NewUserRealm(bob))
	VoteDispute(cross(cur), metaSlug, ap12, "no")
	testing.SkipHeights(mc.params.votingBlocks + 1)
	ResolveDispute(cross(cur), metaSlug, ap12)
	cs12 := mustClaim(mc, ap12)
	if cs12.decidedRounds != 1 || !cs12.credEligible {
		t.Fatal("fixture: setmods needs a decided, credEligible round to reach the guard")
	}
	testing.SkipHeights(cs12.escrowUntil - runtimeHeight() + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), metaSlug, ap12)

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "candidate set does not predate", func() {
		ExecuteMetaVerdict(cross(cur), ap12)
	})
	if IsCourtMod("mtx12", puppet) {
		t.Fatal("a candidate registered after the appeal must not be installable")
	}

	// ---- 13. a claim with NO BINDING APPEAL executes nothing ----------------
	// The binding is written at PostAnswer and only for a title that parses as a
	// `mod:` instruction, so an ordinary claim filed on the review court reaches
	// execution with nothing bound to it. Deleting this guard does not merely let a
	// no-op through: the very next line dereferences the binding, so the refusal
	// becomes a nil dereference. A clean error and a VM panic are different
	// behaviours, and only one of them is a refusal.
	testing.SetRealm(testing.NewUserRealm(alice))
	ap13 := OpenClaim(cross(cur), metaSlug, "an ordinary claim, not a mod instruction")
	matureOI(cur, metaSlug, ap13, alice, 2*effMinAnswerX(mc))
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), metaSlug, ap13, sideYES)
	testing.SkipHeights(settleDelay + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	SettleUndisputed(cross(cur), metaSlug, ap13)
	if Provisional(metaSlug, ap13) != sideYES {
		t.Fatal("fixture: the appeal must carry a final YES, so only the binding is missing")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "carries no binding appeal", func() {
		ExecuteMetaVerdict(cross(cur), ap13)
	})

	// ---- 14. a NO verdict executes nothing ---------------------------------
	// Nothing else stops this one. The verdict is read from `provisional`, the
	// field a dispute OVERTURNS, so a valid instruction that the electorate voted
	// DOWN must not act — otherwise losing an appeal and winning it do the same
	// thing.
	testCourt(cur, "mtx14", alice, 10_000_000_000)
	testing.SkipHeights(epochBlocks * 2) // the target must predate the appeal
	testing.SetRealm(testing.NewUserRealm(alice))
	OpenClaim(cross(cur), "mtx14", "a claim to leave alone")
	testing.SkipHeights(2) // predate is STRICT, and check 2 runs before check 3
	testing.SetRealm(testing.NewUserRealm(alice))
	ap14 := OpenClaim(cross(cur), metaSlug, "mod:unhide:mtx14/1")
	matureOI(cur, metaSlug, ap14, alice, 2*effMinAnswerX(mc))
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), metaSlug, ap14, sideNO) // the electorate says NO
	testing.SkipHeights(settleDelay + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	SettleUndisputed(cross(cur), metaSlug, ap14)
	if Provisional(metaSlug, ap14) != sideNO {
		t.Fatalf("fixture: the verdict must be NO, got %d", Provisional(metaSlug, ap14))
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "the verdict was not YES", func() {
		ExecuteMetaVerdict(cross(cur), ap14)
	})

	// ---- 15. a LOCAL INSTALL between verdict and execution refuses ----------
	// setmods anchors its staleness on verdictAt rather than openedAt, deliberately:
	// the local electorate is always faster than a meta appeal, so an openedAt
	// anchor would hand the local set a permanent free veto and meta's duty cycle
	// would be zero. But an install landing AFTER the verdict must still refuse —
	// otherwise meta overwrites a set the court chose while the appeal was in the
	// post-verdict queue, which is the one window the anchor leaves open.
	testCourt(cur, "mtx15", alice, 10_000_000_000)
	// Top up. Fifteen sections of stakes are still LOCKED — nothing here ever
	// withdraws — so alice's spendable balance has been drawn down to roughly 29.6k
	// CC while matureOI needs three stakes of 2x the answer floor, about 44.5k.
	// Minting converges rather than chasing its own tail: the floor is basis points
	// of supply, so adding S raises the requirement by a small fraction of S. carol
	// is topped up in the same proportion because credEligible needs her overturn
	// weight to stay above a quarter of a floor that also moves with supply.
	mc.coin.Mint(alice, 200_000_000_000)
	mc.coin.Mint(carol, 100_000_000_000)
	testing.SkipHeights(epochBlocks * 2) // seal the mint before the floors read it
	newMod15 := testutils.TestAddress("mtx15-new")
	testing.SetRealm(testing.NewUserRealm(alice))
	cand15 := RegisterModCandidate(cross(cur), "mtx15", 1, newMod15)
	testing.SkipHeights(epochBlocks * 2) // court AND candidate must predate the appeal

	testing.SetRealm(testing.NewUserRealm(alice))
	ap15 := OpenClaim(cross(cur), metaSlug,
		"mod:setmods:mtx15/"+strconv.FormatUint(cand15, 10))
	matureOI(cur, metaSlug, ap15, alice, 2*effMinAnswerX(mc))
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), metaSlug, ap15, sideYES)
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), metaSlug, ap15)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), metaSlug, ap15, "yes")
	testing.SetRealm(testing.NewUserRealm(bob))
	VoteDispute(cross(cur), metaSlug, ap15, "no")
	testing.SkipHeights(mc.params.votingBlocks + 1)
	ResolveDispute(cross(cur), metaSlug, ap15)
	cs15 := mustClaim(mc, ap15)
	if cs15.decidedRounds != 1 || !cs15.credEligible {
		t.Fatal("fixture: setmods needs a decided, credEligible round to reach the guard")
	}
	testing.SkipHeights(cs15.escrowUntil - runtimeHeight() + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), metaSlug, ap15)

	// The court installs its OWN set after the verdict. alice is the creator and no
	// election has spent her appointment power, so this is the ordinary local route.
	localMod := testutils.TestAddress("mtx15-local")
	// STRICTLY after: the guard compares setActHeight > verdictAt, and the escrow
	// skip above is a no-op once escrowUntil has already passed, so without a block
	// here the install shares the verdict's height and the comparison reads equal.
	testing.SkipHeights(1)
	testing.SetRealm(testing.NewUserRealm(alice))
	AppointMods(cross(cur), "mtx15", 1, localMod)

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "moderator set changed after this verdict", func() {
		ExecuteMetaVerdict(cross(cur), ap15)
	})
	// The local choice stands, and meta's candidate never lands.
	if !IsCourtMod("mtx15", localMod) || IsCourtMod("mtx15", newMod15) {
		t.Fatal("a stale setmods verdict must not overwrite the court's own install")
	}

	// ---- 16. a PROVISIONALLY CLOSED claim is not a verdict ------------------
	// `verdictAt == 0 || provClose` looks like one guard and is two. The first arm
	// is masked: an undecided claim still carries provisional == -1, so the YES
	// check one line down refuses it anyway. The provClose arm is the one that has
	// to exist on its own — three failed rounds close a claim WITHOUT deciding it,
	// leaving everyone whole and `provisional` still sitting on the posted answer.
	// If that answer was YES, the YES check passes and only this arm refuses.
	//
	// The state is set directly rather than driven through three failed rounds,
	// because the PATH there is already covered by
	// TestDisputeFailedRoundsToProvClose; what is under test here is the guard's
	// reaction to that state. Reusing ap15 also pins the CHECK ORDER: the verdict
	// test is step 3 and the setmods staleness test is step 7, so the message must
	// change from the staleness one asserted above to this one.
	cs15.provClose = true
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "no final verdict", func() {
		ExecuteMetaVerdict(cross(cur), ap15)
	})
	cs15.provClose = false // leave the fixture as section 15 left it
}

// metaRealmPath is a STRING CONSTANT, and meta's escrow is derived from it,
// because init() has no `cur` to ask for the realm's own address. Every other
// court gets cur.Address() — the genuine one, straight from the crossing frame.
// So the two derivations must agree, and comparing them is the whole check.
//
// If that constant ever drifts from the deploy path — a rename, a fork, a v3
// deployed beside this one — meta's escrow silently becomes an address nobody
// holds the key to. Every appeal bond and deposit routed through the review
// court would be paid into it, and a realm is write-once, so there is no
// version of this that gets repaired afterwards. It is the cheapest possible
// assertion against the most expensive possible typo.
//
// A unit test, not a runtime guard: the only way to make this false is to edit
// the constant or move the realm, and both happen here, in the repository,
// where a test catches them. A per-call runtime check would charge every user
// gas forever to guard against a mistake no user can make.
func TestMetaEscrowIsThisRealm(cur realm, t *testing.T) {
	alice := testutils.TestAddress("mesc-alice")
	testCourt(cur, "mescrow", alice, 1_000_000)

	fromConstant := CourtEscrow(metaSlug) // chain.PackageAddress(metaRealmPath)
	fromFrame := CourtEscrow("mescrow")   // cur.Address()
	if fromConstant != fromFrame {
		t.Fatalf("metaRealmPath does not name this realm: the review court's "+
			"escrow is %s but the realm's own address is %s — every appeal bond "+
			"would be paid to an account nobody controls",
			fromConstant, fromFrame)
	}
	if fromConstant == "" {
		t.Fatal("the review court's escrow must not be the zero address")
	}
}
