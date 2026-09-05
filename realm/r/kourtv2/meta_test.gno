package kourtv2

import (
	"strconv"
	"strings"
	"testing"
	"time"

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
		{"mod:newfolder:foo/5", verbNewfolder, "foo", 5},
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
		// newfolder takes the same target shape as the other id verbs, so the
		// same near-misses have to fail for it: no id, a zero id, a bad slug.
		"mod:newfolder:foo", "mod:newfolder:foo/", "mod:newfolder:foo/0",
		"mod:newfolder:FOO/1", "mod:newfolder:foo/abc",
		// The `mod:` prefix gate, which every other entry above fails to reach:
		// each of them dies one line later on the missing verb separator, so
		// deleting the prefix check leaves them all still invalid. The verb only
		// has to START AT INDEX 4, and "why " is four characters — so this is an
		// ordinary English title that becomes a BINDING suspend appeal against
		// court "foo" the moment the prefix gate stops holding.
		"why suspend:foo",
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
	// newfolder shares setmods' reasoning and must share its shape: keyed per
	// COURT, or an attacker banks parallel folder installs and discharges them
	// one after another.
	if latchKey(modParse{verb: verbNewfolder, court: "foo", target: 1}) !=
		latchKey(modParse{verb: verbNewfolder, court: "foo", target: 2}) {
		t.Fatal("newfolder must share one latch per court")
	}
	if latchKey(modParse{verb: verbNewfolder, court: "foo", target: 1}) ==
		latchKey(modParse{verb: verbNewfolder, court: "bar", target: 1}) {
		t.Fatal("...but not across courts")
	}
	/* RESTORATIVE, and asserted because the classification IS the design. If
	   newfolder ever joins the aggressive set it stops executing from silence,
	   and an uncontested folder proposal — the ordinary case — can never carry. */
	if verbIsAggressive(verbNewfolder) {
		t.Fatal("newfolder must be restorative, or an uncontested proposal can never carry")
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
	OpenRewards(cross(cur), metaSlug, ap2)
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
	testing.SkipHeights(cs9.escrowUntil - heightNow() + 1)
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

	testing.SkipHeights(cs10.escrowUntil - heightNow() + 1)
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
	testing.SkipHeights(cs12.escrowUntil - heightNow() + 1)
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
	testing.SkipHeights(cs15.escrowUntil - heightNow() + 1)
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

	// ---- 17. THE VERBS THAT LAND -------------------------------------------
	// Everything above tests the GATE: which appeals are refused, and why. Only
	// sections 1 and 4 ever execute one, and both are `unhide` — so of the six
	// verbs applyMetaVerb dispatches, the suite had watched exactly one actually
	// apply. Inverting the rest changed nothing any test could see: `clear`
	// SETTING the bit it is named for clearing, `suspend` UNsuspending,
	// `unsuspend` SUSPENDING, all five survived a mutation run. A suite that only
	// ever refuses a verb never learns what it does.
	//
	// The route to a decided, credible contest is driven end to end three times
	// above (10, 12, 15) — each time to reach a REFUSAL, and each time paying for
	// a dispute, a quorate vote, a resolve and an escrow wait. What is under test
	// from here down is the effect applied once the gate opens, so the gate's
	// contested-route preconditions are set directly rather than re-earned four
	// more times. The fields are exactly the three ExecuteMetaVerdict step 4
	// reads.
	decide := func(id uint64) uint64 {
		cs := mustClaim(mc, id)
		cs.route = "vote"
		cs.decidedRounds = 1
		cs.credEligible = true
		return id
	}
	aggressive := func(title string) uint64 { return decide(appeal(title)) }

	// Sixteen sections of stakes are still locked and nothing here withdraws, so
	// the five appeals below need their own funding. See section 15 on why
	// minting converges instead of chasing the floor it raises.
	mc.coin.Mint(alice, 900_000_000_000)
	testing.SkipHeights(epochBlocks * 2) // seal the mint before any floor reads it

	testCourt(cur, "mtx17", alice, 10_000_000_000)
	testing.SkipHeights(epochBlocks * 2) // the court must predate the appeal
	testing.SetRealm(testing.NewUserRealm(alice))
	t17 := OpenClaim(cross(cur), "mtx17", "a claim the review court will hide")
	if HiddenFromListing("mtx17", t17) {
		t.Fatal("fixture: mtx17's claim must start visible")
	}
	tgt17 := "mtx17/" + strconv.FormatUint(t17, 10)

	// hide LANDS. It is the one aggressive verb exempt from credEligible, on the
	// ground that it is low-harm and globally reversible.
	ap17 := aggressive("mod:hide:" + tgt17)
	testing.SetRealm(testing.NewUserRealm(alice))
	ExecuteMetaVerdict(cross(cur), ap17)
	if !HiddenFromListing("mtx17", t17) {
		t.Fatal("a hide verdict must actually hide the claim")
	}

	// The no-op unhide's SECOND disjunct: mod state now EXISTS for this claim
	// (the hide wrote it) but the COURT bit is not set, so a meta unhide has
	// nothing to clear. Section 3's claim has no mod state at all and cannot
	// reach this arm.
	//
	// What this pins is the COMPOSITE, and the distinction matters. applyMetaVerb's
	// pre-check and clearCourtBitByMeta's own `clm == nil || !clm.court` are the
	// same test written twice, so NEITHER COPY IS INDIVIDUALLY OBSERVABLE —
	// delete one and the other still holds. The seeding side effect is invisible
	// too, deliberately: ModThreshold and IsCourtMod both answer for an
	// unallocated set exactly as they answer for a set ensureMod has just seeded.
	// Deleting BOTH is what this catches, and the second assertion is why it is
	// worth catching — the meta bit must survive an unhide, or `unhide` quietly
	// becomes `clear` and the review court's own hides fall to the cheaper
	// restorative route that needs no contest at all.
	before17 := ModLogLen("mtx17", t17)
	ap17b := appeal("mod:unhide:" + tgt17)
	testing.SetRealm(testing.NewUserRealm(alice))
	ExecuteMetaVerdict(cross(cur), ap17b)
	if ModLogLen("mtx17", t17) != before17 {
		t.Fatal("an unhide with no court bit to clear must not write a moderation act")
	}
	if !HiddenFromListing("mtx17", t17) {
		t.Fatal("an unhide must not clear the review court's OWN hide; that is what clear is for")
	}

	// clear LANDS. Restorative, so it executes from silence.
	ap17c := appeal("mod:clear:" + tgt17)
	testing.SetRealm(testing.NewUserRealm(alice))
	ExecuteMetaVerdict(cross(cur), ap17c)
	if HiddenFromListing("mtx17", t17) {
		t.Fatal("a clear verdict must clear the review court's own hide")
	}
	if ModLogLen("mtx17", t17) <= before17 {
		t.Fatal("a landed clear must write a moderation act")
	}

	// ---- 18. suspend and unsuspend, both LANDING ---------------------------
	// Section 9 proves a manufactured contest cannot suspend and section 10 proves
	// a stale verdict cannot. Neither ever watched a good one succeed, so with both
	// arms transposed the review court would disarm a moderator set on `unsuspend`
	// and rearm it on `suspend`, and every assertion above would still pass.
	testCourt(cur, "mtx18", alice, 10_000_000_000)
	testing.SkipHeights(epochBlocks * 2)
	if CourtSuspended("mtx18") {
		t.Fatal("fixture: mtx18 must start unsuspended")
	}
	ap18 := aggressive("mod:suspend:mtx18")
	testing.SetRealm(testing.NewUserRealm(alice))
	ExecuteMetaVerdict(cross(cur), ap18)
	if !CourtSuspended("mtx18") {
		t.Fatal("a suspend verdict must suspend the moderator set")
	}

	// The release, on a SECOND appeal opened after the suspension landed. The
	// pair is the point: a set that can be disarmed and never rearmed is a
	// one-way ratchet, and suspend/unsuspend share one latch per court — so this
	// also shows a successful execution frees that latch for the opposite verb.
	ap18b := aggressive("mod:unsuspend:mtx18")
	testing.SetRealm(testing.NewUserRealm(alice))
	ExecuteMetaVerdict(cross(cur), ap18b)
	if CourtSuspended("mtx18") {
		t.Fatal("an unsuspend verdict must release the moderator set")
	}

	// ---- 19. setmods LANDS, and the two effects it must NOT have -----------
	// Sections 12 and 15 refuse a setmods on staleness; this one installs. The
	// threshold is 2-of-2 so the candidate's OWN m and n are observable rather
	// than coinciding with the 1-of-1 an unallocated set reports.
	testCourt(cur, "mtx19", alice, 10_000_000_000)
	modA := testutils.TestAddress("mtx19-a")
	modB := testutils.TestAddress("mtx19-b")
	testing.SetRealm(testing.NewUserRealm(alice))
	cand19 := RegisterModCandidate(cross(cur), "mtx19", 2, modA, modB)
	testing.SkipHeights(epochBlocks * 2) // court AND candidate must predate the appeal
	ap19 := aggressive("mod:setmods:mtx19/" + strconv.FormatUint(cand19, 10))
	testing.SetRealm(testing.NewUserRealm(alice))
	ExecuteMetaVerdict(cross(cur), ap19)

	if !IsCourtMod("mtx19", modA) || !IsCourtMod("mtx19", modB) {
		t.Fatal("a setmods verdict must seat the candidate set")
	}
	if IsCourtMod("mtx19", alice) {
		t.Fatal("a setmods verdict must REPLACE the incumbent set, not extend it")
	}
	if m, n := ModThreshold("mtx19"); m != 2 || n != 2 {
		t.Fatalf("the candidate's own threshold must be installed, got %d-of-%d", m, n)
	}

	// installedByMeta. A set the review court seated may not seed claims: seeding
	// waives the deposit AND the fee while the emission slices still mint, so a
	// captured review court seating puppets would otherwise hand them a free
	// claim faucet. installModSet derives this flag from the SAME argument the
	// two election stamps read, which is what makes that argument's value
	// observable at all.
	testing.SetRealm(testing.NewUserRealm(modA))
	uassert.AbortsContains(t, cur, "may not seed claims", func() {
		OpenClaimSeeded(cross(cur), "mtx19", "a free claim for a seated puppet")
	})

	// creatorUnseated — the other election-only effect, and the one with teeth.
	// A court that has never held an election keeps its creator's free, instant
	// AppointMods repair path, and one cheap meta appeal must not destroy it:
	// otherwise capturing the review court once permanently removes a court's
	// ability to fix itself without running a full election.
	//
	// LAST in the section on purpose. AppointMods is a local act and clears
	// installedByMeta, so the seed refusal has to be observed before it runs.
	repair := testutils.TestAddress("mtx19-repair")
	testing.SetRealm(testing.NewUserRealm(alice))
	AppointMods(cross(cur), "mtx19", 1, repair)
	if !IsCourtMod("mtx19", repair) || IsCourtMod("mtx19", modA) {
		t.Fatal("the creator's appointment power must survive a meta install")
	}

	// And the taint LIFTS with the set that carried it — a creator appointment is
	// a local act, so the set it installs may seed again. Without this the
	// refusal above would be a one-way door: a single meta install would cost the
	// court its seeding verb permanently, which is a harsher remedy than the vet
	// that set the flag ever votes for.
	testing.SetRealm(testing.NewUserRealm(repair))
	OpenClaimSeeded(cross(cur), "mtx19", "a locally appointed set may seed again")

	// ---- 20. setmods MUST NOT DO WHAT unsuspend IS FORBIDDEN TO DO ----------
	// Both verbs end at the same write, cm.suspended = false — unsuspend through
	// unsuspendSet, setmods through installModSet's re-arm rule. Until v0.55 only
	// the suspend/unsuspend arm of ExecuteMetaVerdict's staleness switch consulted
	// suspendActByGlobal, and GlobalSuspendSet never moves setActHeight, so
	// nothing on the setmods path examined the global act at all.
	//
	// Section 10 proves the unsuspend half. This is the same act aimed through
	// setmods, and it USED TO SUCCEED: the verb name was the only difference, so
	// `setmods` was a cheaper `unsuspend` than `unsuspend`.
	testCourt(cur, "mtx20", alice, 10_000_000_000)
	newMod20 := testutils.TestAddress("mtx20-new")
	testing.SetRealm(testing.NewUserRealm(alice))
	cand20 := RegisterModCandidate(cross(cur), "mtx20", 1, newMod20)
	testing.SkipHeights(epochBlocks * 2) // court AND candidate must predate the appeal

	// The appeal opens BEFORE the global act, which is the staleness case the
	// guard is scoped to (suspendActByGlobal > cs.openedAt).
	ap20 := aggressive("mod:setmods:mtx20/" + strconv.FormatUint(cand20, 10))

	// Establish the global threshold rather than inheriting section 10's: purgeM
	// is package-global, and a test that leans on a neighbour's setup is
	// reporting on the neighbour.
	dadmin20 := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin20))
	SetPurgeThreshold(cross(cur), 1)
	testing.SetRealm(testing.NewUserRealm(dadmin20))
	GlobalSuspendSet(cross(cur), "mtx20")
	if !CourtSuspended("mtx20") {
		t.Fatal("fixture: the global DAO must have suspended the set, or nothing below means anything")
	}

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "the global DAO changed this court's suspension", func() {
		ExecuteMetaVerdict(cross(cur), ap20)
	})
	// A refusal must leave BOTH halves untouched — the suspension standing and the
	// set unseated. Asserting only the flag would pass on a verdict that installed
	// the set and then panicked, which is a partial effect, not a refusal.
	if !CourtSuspended("mtx20") {
		t.Fatal("a setmods verdict predating a global DAO suspension cleared it — " +
			"the same act the guard refuses when it is spelled `unsuspend`")
	}
	if IsCourtMod("mtx20", newMod20) {
		t.Fatal("the refused verdict seated its candidate set anyway")
	}
	// The verdict must stay UNexecuted, or the refusal costs the appellant their
	// appeal as well: a re-appeal is the sanctioned way out, and it only works if
	// this one did not consume its exactly-once flag.
	if AppealExecuted(ap20) {
		t.Fatal("a refused verdict must not be marked executed")
	}

	// ---- 21. ...AND THE REFUSAL IS DIRECTION-SCOPED, BOTH WAYS ---------------
	// Section 20 pins that the guard FIRES. Dropping the `cm.suspended &&` half of
	// it broke no test at all — measured, as a survivor in the mutation batch — so
	// the direction-scoping every reviewer called "free" was the unpinned half.
	// A FIX THAT CAN FAIL MUST FAIL CLOSED BOTH WAYS, and only this arm says so.
	//
	// ClearCourtSuspension is the discriminating call: it stamps
	// suspendActByGlobal and leaves cm.suspended FALSE. So a clear landing after
	// the appeal opened satisfies the stale term and fails the direction term, and
	// a legitimate install must still land. Without the scoping, the global DAO's
	// own act of UNsuspending a court would block the very verdict that seats its
	// replacement moderators.
	// The SAME verdict, once the global DAO clears. ClearCourtSuspension is the
	// discriminating call: it stamps suspendActByGlobal — so the stale term is
	// still satisfied, exactly as it was a moment ago — and leaves cm.suspended
	// FALSE, so the direction term now fails and the install must land. Reusing
	// ap20 is what makes this an A/B on ONE bit: same appeal, same court, same
	// candidate, same window, opposite direction.
	//
	// No new appeal, deliberately. Staking LOCKS rather than transfers (lock.gno),
	// so twenty-one appeals' stakes are all still held and alice's SPENDABLE
	// balance will not fund another one. Topping her up would raise meta's sealed
	// supply, and the answerability floor is a fraction of it, so every earlier
	// section's derived stake would move with it.
	testing.SetRealm(testing.NewUserRealm(dadmin20))
	ClearCourtSuspension(cross(cur), "mtx20")
	if CourtSuspended("mtx20") {
		t.Fatal("fixture: the global clear must have lifted the suspension")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	ExecuteMetaVerdict(cross(cur), ap20)
	if !IsCourtMod("mtx20", newMod20) {
		t.Fatal("a global CLEAR after the appeal opened refused a legitimate " +
			"setmods install — the guard has lost its direction scope")
	}

	// ---- 21. `mod:newfolder` — the court creates its own folder -------------
	/* THE EXECUTION HALF of the verb. The proposal half is folders_test's, which
	   proves registering creates nothing; this proves a carried verdict does,
	   and that everything the moderator path checks is re-checked here. */
	testCourt(cur, "mtxf", alice, 10_000_000_000)
	// bob is not a moderator of mtxf. That is the point: the court adopts a
	// folder proposed by somebody with no authority to file one.
	testing.SetRealm(testing.NewUserRealm(bob))
	fprop := RegisterFolderProposal(cross(cur), "mtxf", "Origins", "where it began", 0)
	if FolderCount("mtxf") != 0 {
		t.Fatal("fixture: a proposal must not have created anything yet")
	}

	apf := appeal("mod:newfolder:mtxf/" + strconv.FormatUint(fprop, 10))
	testing.SetRealm(testing.NewUserRealm(alice))
	ExecuteMetaVerdict(cross(cur), apf)
	if FolderCount("mtxf") != 1 {
		t.Fatal("a carried newfolder verdict should create the folder")
	}
	if nm := FolderName("mtxf", 1); nm != "Origins" {
		t.Fatalf("the folder should carry the proposal's name, got %q", nm)
	}
	if d := FolderDesc("mtxf", 1); d != "where it began" {
		t.Fatalf("...and its description, got %q", d)
	}
	// RESTORATIVE: it executed from silence, with no dispute and no vote. If the
	// verb is ever reclassified aggressive this is the assertion that fails.
	if !AppealExecuted(apf) {
		t.Fatal("newfolder should carry on the undisputed route")
	}
	// Exactly once, like every other verb.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "already executed", func() {
		ExecuteMetaVerdict(cross(cur), apf)
	})

	/* A PROPOSAL REGISTERED AFTER ITS APPEAL IS REFUSED. Registration is
	   permissionless with a predictable per-court counter, so without this an
	   attacker opens an appeal against an unallocated id, wins a vote on a
	   folder nobody could read, and registers the real payload afterwards —
	   the same attack the setmods candidate guard names. */
	apf2 := appeal("mod:newfolder:mtxf/2")
	testing.SetRealm(testing.NewUserRealm(bob))
	RegisterFolderProposal(cross(cur), "mtxf", "Late", "registered after the appeal", 0)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "does not predate this appeal", func() {
		ExecuteMetaVerdict(cross(cur), apf2)
	})

	/* AND IT PAYS ITS AUTHOR, NOT ITS STAKERS. The accuracy slice is zeroed for
	   a newfolder appeal — paying stakers by conviction for agreeing with a
	   proposal is a vote bought out of the reward pool. The author slice is
	   untouched: proposing a folder the court adopts is the work being paid for.
	   Asserted as the PAIR, because "winners == 0" alone would also pass on a
	   claim that pays nobody anything. */
	{
		mcf := mustCourt(metaSlug)
		csf := mustClaim(mcf, apf)
		if !csf.noAccuracy {
			t.Fatal("a newfolder appeal must be flagged to pay no accuracy slice")
		}
		w, a, _ := drawSplit(csf, 1_000_000)
		if w != 0 {
			t.Fatalf("newfolder should pay no accuracy slice, got %d", w)
		}
		if a == 0 {
			t.Fatal("...but it must still pay its author — that is the reward being offered")
		}
	}
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

// THE APPEAL WINDOW IS ONE VOTE LONG, AND ITS LAST INSTANT STILL COUNTS.
//
// Execution expiry stops a party banking K decided appeals and discharging one
// after each local election. It was covered only in the crudest way: deleting the
// guard was caught, but shortening the window by ONE UNIT survived on both arms —
// measured, by mutating it. So the `>` that makes the deadline inclusive carried
// real behaviour with nothing holding it, and converting to seconds could have
// moved it a second in either direction unnoticed.
//
// Pinned on the predicate rather than through ExecuteMetaVerdict, deliberately.
// Reaching that function needs a court, a hidden target, a matured ring, an
// answer and a settlement, and the resulting fixture is coupled to the meta
// lane's own clock — a first attempt at it failed on state left by other tests
// rather than on anything this window does. The wiring (that the guard is
// reached at all) is held by the corpus row `meta: an expired verdict may still
// execute`, which the suite already kills; what was missing, and is here, is the
// EDGE.
func TestTheMetaExecutionWindowKeepsItsInclusiveEdge(cur realm, t *testing.T) {
	const votingBlocks = int64(120_960) // the default, as a literal on purpose
	window := blocksToSecs(votingBlocks)

	// ---- THE STAMP GOVERNS ----
	cs := &claimState{verdictAt: heightNow(), verdictAtTime: nowTime()}
	bumpTo := func(target int64) {
		d := target - nowTime()
		if d < 0 {
			t.Fatalf("fixture: %d is already behind us (now %d)", target, nowTime())
		}
		ctx := testing.GetContext()
		ctx.Time = ctx.Time.Add(time.Duration(d) * time.Second)
		testing.SetContext(ctx)
	}
	frozenH := heightNow()

	if metaVerdictExpired(cs, votingBlocks) {
		t.Fatal("a verdict stamped this instant cannot already have expired")
	}
	// AT the deadline it is still live — this is the `>` and the whole point.
	bumpTo(cs.verdictAtTime + window)
	uassert.Equal(t, frozenH, heightNow()) // no block mined
	if metaVerdictExpired(cs, votingBlocks) {
		t.Fatalf("at verdictAtTime+%d the window must still be open: the guard is `>`, "+
			"so its last instant counts", window)
	}
	// One second later it is not.
	bumpTo(cs.verdictAtTime + window + 1)
	uassert.Equal(t, frozenH, heightNow())
	if !metaVerdictExpired(cs, votingBlocks) {
		t.Fatalf("one second past verdictAtTime+%d the window must be shut", window)
	}

	// ---- AND A PRE-STAMP VERDICT READS HEIGHT, TO ITS EXACT BLOCK ----
	old := &claimState{verdictAt: heightNow(), verdictAtTime: 0}
	if metaVerdictExpired(old, votingBlocks) {
		t.Fatal("a pre-stamp verdict recorded this block cannot already have expired")
	}
	testing.SkipHeights(votingBlocks)
	uassert.Equal(t, old.verdictAt+votingBlocks, heightNow())
	if metaVerdictExpired(old, votingBlocks) {
		t.Fatalf("at verdictAt+%d the height arm must still be open", votingBlocks)
	}
	testing.SkipHeights(1)
	if !metaVerdictExpired(old, votingBlocks) {
		t.Fatalf("one block past verdictAt+%d the height arm must be shut", votingBlocks)
	}
}
