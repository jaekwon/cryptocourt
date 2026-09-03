package kourtv2

import (
	"strconv"
	"strings"
	"testing"
	"time"

	sanitize "gno.land/p/nt/markdown/sanitize/v0"
	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// topHasRow reports whether a row is IN the ranked index, which is a different
// question from whether its text renders there. Both index-drop mutations
// survived an assertion phrased as "the text is not in Top": the text gate
// withheld it either way, so the assertion held with the index-drop deleted.
func topHasRow(slug string, claimID, rowID uint64) bool {
	head := strconv.FormatUint(rowID, 10) + "|"
	for _, line := range strings.Split(BoardTop(slug, claimID, 0, 64), "\n") {
		if strings.HasPrefix(line, head) {
			return true
		}
	}
	return false
}

// legalFixture: a live claim with one top-level comment on it, and the row's id.
func legalFixture(cur realm, slug string, who address) (uint64, uint64) {
	_, id := boardFixture(cur, slug, who)
	testing.SetRealm(testing.NewUserRealm(who))
	row := PostComment(cross(cur), slug, id, 0, "something a notice might name")
	return id, row
}

func TestTheBoardCodeSetIsClosed(cur realm, t *testing.T) {
	// The whole point of a closed set: a code outside it cannot be recorded, so
	// the vocabulary that appears on a person's page is the deploy's vocabulary.
	for _, ok := range []string{boardCodeSpam, boardCodeOffTopic, boardCodeAbuse,
		boardCodeImpersonation, boardCodeIllegal} {
		mustBoardCode(ok) // must not panic
		if !strings.Contains(BoardCodes(), ok) {
			t.Fatal("a code the switch accepts must be one a client can discover: " + ok)
		}
	}
	for _, bad := range []string{"", "SPAM", "spam ", "because I said so", "dmca"} {
		func() {
			defer func() {
				if recover() == nil {
					t.Fatal("mustBoardCode accepted a code outside the set: " + bad)
				}
			}()
			mustBoardCode(bad)
		}()
	}
}

// The authority perimeter on the three legal verbs. Each refusal is its own
// call because the messages cannot tell two entrypoints apart.
func TestTheLegalVerbsRefuseEveryoneButTheGlobalDAO(cur realm, t *testing.T) {
	alice := testutils.TestAddress("bl1-alice")
	stranger := testutils.TestAddress("bl1-stranger")

	// ESTABLISH THE DIRECTORY ADMIN FIRST, AND ON A THROWAWAY. directoryAdmin is
	// the FIRST court creator in the package, so whenever this test ran before
	// any other, alice — the court moderator whose refusal the loop below is the
	// whole point of — WAS the bootstrap global-DAO member, and all three of her
	// arms inverted from "refused" to "allowed". The isolation sweep caught it;
	// with neighbours the test passed and proved the opposite of its name.
	testCourt(cur, "bl1b", testutils.TestAddress("bl1-boot"), 10_000_000_000)
	dadmin := DirectoryAdmin()
	if dadmin == alice || dadmin == stranger {
		t.Fatal("neither subject of this test may be the bootstrap DAO member, " +
			"or its refusals assert the reverse of what they say")
	}

	id, row := legalFixture(cur, "bl1", alice)

	// A COURT MODERATOR IS NOT ENOUGH, and alice is this court's 1-of-1 mod set.
	// Without this arm the perimeter would read the same if it merely refused
	// non-moderators, which is the weaker gate these verbs must not have.
	for _, who := range []address{stranger, alice} {
		testing.SetRealm(testing.NewUserRealm(who))
		uassert.AbortsContains(t, cur, "only a global DAO member may globally hide a comment", func() {
			GlobalHideRow(cross(cur), "bl1", id, row, "dmca")
		})
		testing.SetRealm(testing.NewUserRealm(who))
		uassert.AbortsContains(t, cur, "only a global DAO member may clear a global comment hide", func() {
			GlobalClearRow(cross(cur), "bl1", id, row)
		})
		testing.SetRealm(testing.NewUserRealm(who))
		uassert.AbortsContains(t, cur, "only a global DAO member may purge", func() {
			PurgeBoardRow(cross(cur), "bl1", id, row, "csam")
		})
	}

	// THE CONTROL. Without it the six refusals prove nothing: a fixture with a
	// bad slug or a row that does not exist would refuse identically.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalHideRow(cross(cur), "bl1", id, row, "dmca")
	if BoardRowState("bl1", id, row) != "g" {
		t.Fatal("the bootstrap DAO member's own hide must land, or the six refusals prove nothing")
	}
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalClearRow(cross(cur), "bl1", id, row)
	if BoardRowState("bl1", id, row) != "." {
		t.Fatal("a clear must lift the redaction it just set")
	}
}

// A redaction withholds on EVERY surface — that is the difference from the
// author's hide, whose deep link still serves.
func TestAGlobalHideWithholdsTheTextOnEverySurface(cur realm, t *testing.T) {
	alice := testutils.TestAddress("bl2-alice")
	id, row := legalFixture(cur, "bl2", alice)
	dadmin := DirectoryAdmin()

	// Before: the text is on the wire, on the page, and in the ranked index.
	if !strings.Contains(BoardNewest("bl2", id, 0, 10), "something a notice might name") {
		t.Fatal("the fixture must put the text on the wire first")
	}
	deep := renderBoardRow("bl2", id, strconv.FormatUint(row, 10))
	if !strings.Contains(deep, "something a notice might name") {
		t.Fatal("the fixture must put the text on its deep link first")
	}

	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalHideRow(cross(cur), "bl2", id, row, "dmca")

	// The wire: marked, and empty.
	wire := BoardNewest("bl2", id, 0, 10)
	if strings.Contains(wire, "something a notice might name") {
		t.Fatal("a redacted comment's text must not reach the wire")
	}
	if !strings.Contains(wire, "|g|") {
		t.Fatal("the wire must say WHY it is not there: g, not h")
	}
	// The deep link — the surface an author hide deliberately leaves serving.
	deep = renderBoardRow("bl2", id, strconv.FormatUint(row, 10))
	if strings.Contains(deep, "something a notice might name") {
		t.Fatal("a redacted comment must withhold at its own link too, unlike a self-hide")
	}
	if !strings.Contains(deep, "Withheld pending a legal determination") {
		t.Fatal("the page must say the text is withheld rather than silently show nothing")
	}
	// The ranked index — the ROW, not its text. Asking whether the text is in
	// Top proves nothing here, because boardTextFor withholds it whether or not
	// the index was ever touched.
	if topHasRow("bl2", id, row) {
		t.Fatal("Top must not carry a rank for text nobody may read")
	}
}

// The put-back, and the reason the pair exists: §512(g) restores the SPECIFIC
// material, so a row must come back without touching any other row.
func TestAClearRestoresOneRowAndArmsTheReSetWindow(cur realm, t *testing.T) {
	alice := testutils.TestAddress("bl3-alice")
	id, row := legalFixture(cur, "bl3", alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	other := PostComment(cross(cur), "bl3", id, 0, "an untouched neighbour")
	dadmin := DirectoryAdmin()

	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalHideRow(cross(cur), "bl3", id, row, "dmca")
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalClearRow(cross(cur), "bl3", id, row)

	if !strings.Contains(renderBoardRow("bl3", id, strconv.FormatUint(row, 10)), "something a notice might name") {
		t.Fatal("a cleared row must read again")
	}
	if BoardRowState("bl3", id, other) != "." {
		t.Fatal("clearing one row must not have touched its neighbour")
	}
	if !strings.Contains(BoardTop("bl3", id, 0, 10), "something a notice might name") {
		t.Fatal("a cleared row must return to the ranked index")
	}

	// Clearing twice is a refusal, not a second arming of the window: an
	// idempotent clear would let one member re-arm the window at will.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	uassert.AbortsContains(t, cur, "not globally hidden", func() {
		GlobalClearRow(cross(cur), "bl3", id, row)
	})

	// INSIDE the window, a re-set takes m-of-n. purgeM is 1 on the bootstrap DAO,
	// so the proof that the windowed branch was taken is not that it refused —
	// it is that it went through approveAction at all. Widen the DAO so 1 is not
	// enough and the branch becomes observable.
	//
	// AND PUT IT BACK AT THE END. The global DAO is package state, not fixture
	// state: leaving purgeM at 2 made the purge test two files down fail, because
	// its single signature no longer fired. The threshold is restored below.
	mod2 := testutils.TestAddress("bl3-mod2")
	testing.SetRealm(testing.NewUserRealm(dadmin))
	AddGlobalMod(cross(cur), mod2)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 2)

	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalHideRow(cross(cur), "bl3", id, row, "dmca") // one signature, inside the window
	if BoardRowState("bl3", id, row) != "." {
		t.Fatal("one key must not re-set a redaction a clear lifted inside the window")
	}
	testing.SetRealm(testing.NewUserRealm(mod2))
	GlobalHideRow(cross(cur), "bl3", id, row, "dmca") // the second
	if BoardRowState("bl3", id, row) != "g" {
		t.Fatal("m-of-n inside the window must still be able to re-set")
	}

	// PAST the window the single key is enough again — which is what makes the
	// arm above a WINDOW and not a permanent escalation.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalClearRow(cross(cur), "bl3", id, row)
	testing.SkipHeights(reSetWindowBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalHideRow(cross(cur), "bl3", id, row, "dmca")
	if BoardRowState("bl3", id, row) != "g" {
		t.Fatal("past the window one key must be enough again, or the window is not a window")
	}

	// The restore, and it is load-bearing for every test that runs after this one.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	RemoveGlobalMod(cross(cur), mod2)
}

// THE ROW'S COUNTER-NOTICE WINDOW IS THE CLAIM'S, MEASURED THE SAME WAY.
//
// TestAClearRestoresOneRowAndArmsTheReSetWindow above walks it with SkipHeights,
// which moves height and time together at 5s a block and so cannot say which
// clock the gate read. §512(g) is written in days, and this is the second gate
// enforcing it — on a board row rather than a claim. Both go through
// reSetWindowOpen, so the statute has one implementation and not two that could
// be converted separately or retuned apart.
//
// The bracket is the LITERAL 1_209_600 seconds and never the constant, for the
// reason the claim-level pin gives: an assertion written as the constant moves
// with the code it is supposed to hold still.
func TestTheBoardReSetWindowRunsOnTheWallClock(cur realm, t *testing.T) {
	const windowSecs = int64(1_209_600) // fourteen days
	alice := testutils.TestAddress("blw-alice")
	id, row := legalFixture(cur, "blw", alice)
	dadmin := DirectoryAdmin()

	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalHideRow(cross(cur), "blw", id, row, "dmca")
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalClearRow(cross(cur), "blw", id, row) // arms the window

	c := mustCourt("blw")
	cs := mustClaim(c, id)
	r := mustBoardRow(cs, row)
	if r.globalClearedAtTime == 0 {
		t.Fatal("fixture: the clear must stamp the moment, or this pins the height arm")
	}
	clearedTime, clearedAt := r.globalClearedAtTime, r.globalClearedAt

	// purgeM is 1 on the bootstrap DAO, so a lone key always fires and the
	// windowed branch is invisible. Widen it — and PUT IT BACK, because the global
	// DAO is package state and a stray threshold breaks tests in other files.
	mod2 := testutils.TestAddress("blw-mod2")
	testing.SetRealm(testing.NewUserRealm(dadmin))
	AddGlobalMod(cross(cur), mod2)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 2)

	frozenH := heightNow()
	bumpTo := func(target int64) {
		d := target - nowTime()
		if d < 0 {
			t.Fatalf("fixture: %d is already behind us (now %d)", target, nowTime())
		}
		ctx := testing.GetContext()
		ctx.Time = ctx.Time.Add(time.Duration(d) * time.Second)
		testing.SetContext(ctx)
	}

	// ONE SECOND INSIDE: a lone key must not win the reversal race.
	bumpTo(clearedTime + windowSecs - 1)
	uassert.Equal(t, frozenH, heightNow())
	uassert.True(t, heightNow() < clearedAt+reSetWindowBlocks) // blocks say "inside" throughout
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalHideRow(cross(cur), "blw", id, row, "dmca")
	if BoardRowState("blw", id, row) != "." {
		t.Fatalf("one key re-set the row %d seconds after the clear, still inside a "+
			"%d-second window", nowTime()-clearedTime, windowSecs)
	}

	// ONE SECOND OUT, no block mined: the single key is enough again, which is
	// what makes this a window rather than a permanent escalation.
	bumpTo(clearedTime + windowSecs)
	uassert.Equal(t, frozenH, heightNow())
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalHideRow(cross(cur), "blw", id, row, "dmca")
	if BoardRowState("blw", id, row) != "g" {
		t.Errorf("the window outlasted its stated %d seconds", windowSecs)
	}

	// ---- AND A PRE-STAMP ROW STILL READS HEIGHT, TO ITS EXACT BLOCK ----
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalClearRow(cross(cur), "blw", id, row)
	r2 := mustBoardRow(cs, row)
	r2.globalClearedAtTime = 0 // the pre-upgrade shape: a height, no stamp
	target := r2.globalClearedAt + reSetWindowBlocks
	if d := target - 1 - heightNow(); d > 0 {
		testing.SkipHeights(d)
	}
	uassert.Equal(t, target-1, heightNow())
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalHideRow(cross(cur), "blw", id, row, "dmca")
	if BoardRowState("blw", id, row) != "." {
		t.Fatal("one key re-set a pre-stamp row one block short of its window")
	}
	testing.SkipHeights(1)
	uassert.Equal(t, target, heightNow())
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalHideRow(cross(cur), "blw", id, row, "dmca")
	if BoardRowState("blw", id, row) != "g" {
		t.Errorf("a pre-stamp row's window outlasted its stated %d blocks", reSetWindowBlocks)
	}

	// The restore, load-bearing for every test that runs after this one.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	RemoveGlobalMod(cross(cur), mod2)
}

// A purge destroys the BYTES. Not a flag over text that stays in state — that is
// the whole difference from every other purge in the realm.
func TestAPurgeDestroysTheBytesAndLeavesTheStub(cur realm, t *testing.T) {
	alice := testutils.TestAddress("bl4-alice")
	id, row := legalFixture(cur, "bl4", alice)
	dadmin := DirectoryAdmin()

	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeBoardRow(cross(cur), "bl4", id, row, "csam")

	if BoardRowState("bl4", id, row) != "x" {
		t.Fatal("a purged row must say so")
	}
	// THE POINT. Not "it does not render" — the bytes are gone from state.
	cs := mustClaim(mustCourt("bl4"), id)
	if mustBoardRow(cs, row).text != "" {
		t.Fatal("a purge must zero the text, not merely flag it: a runbook that says " +
			"remove-within-72h is not discharged by a bit over bytes still in state")
	}
	// The stub: who wrote it and when survive, so the record still says a
	// comment was here.
	if mustBoardRow(cs, row).author != alice {
		t.Fatal("a purge must leave the attribution; it removes the text, not the fact")
	}
	if !strings.Contains(BoardNewest("bl4", id, 0, 10), "|x|") {
		t.Fatal("an enumerated purged row must be marked, not omitted")
	}
	if !strings.Contains(renderBoardRow("bl4", id, strconv.FormatUint(row, 10)), "Removed") {
		t.Fatal("the page must say removed, which is a different fact from withheld")
	}
	if topHasRow("bl4", id, row) {
		t.Fatal("a purged row must leave the ranked index: a rank over destroyed " +
			"text is a slot in the ordering that nothing can ever fill")
	}
	// A purge takes a code from the OPEN legal set, not the closed editorial one.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	uassert.AbortsContains(t, cur, "category code", func() {
		PurgeBoardRow(cross(cur), "bl4", id, row, "")
	})
}

// A row can be under two authorities at once, and clearing one must not clear
// the other. This is why the legal bits are separate fields from `hidden`.
func TestAnAuthorHideAndARedactionAreIndependent(cur realm, t *testing.T) {
	alice := testutils.TestAddress("bl5-alice")
	id, row := legalFixture(cur, "bl5", alice)
	dadmin := DirectoryAdmin()

	testing.SetRealm(testing.NewUserRealm(alice))
	HideOwnComment(cross(cur), "bl5", id, row, true)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalHideRow(cross(cur), "bl5", id, row, "dmca")
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalClearRow(cross(cur), "bl5", id, row)

	cs := mustClaim(mustCourt("bl5"), id)
	r := mustBoardRow(cs, row)
	if !r.hiddenByAuthor {
		t.Fatal("clearing a redaction must not clear the author's own hide")
	}
	if boardMark(r) != "h" {
		t.Fatal("with the redaction gone the author's hide is the remaining state")
	}
	// THE LISTING NOTICE. While both states are on, the page must say the
	// STRONGER one. The author's "withdrawn, it still reads at its own link" is
	// false of a redacted row and understates a legal act as a personal choice.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalHideRow(cross(cur), "bl5", id, row, "dmca")
	// THE NOTICE MOVED, THE RULE DID NOT. Hidden rows leave the listing entirely
	// now — collected behind one link rather than stubbed one apiece — so the
	// page that has to say the STRONGER state is the hidden page.
	listing := renderBoardPage("bl5", id)
	if strings.Contains(listing, "Withheld pending") || strings.Contains(listing, "Withdrawn from") {
		t.Fatal("a hidden row has no stub in the listing at all:\n" + listing)
	}
	held := renderBoardHidden("bl5", id)
	if strings.Contains(held, "Withdrawn from the listing by its author") {
		t.Fatal("a row that is both self-hidden and redacted must not render the " +
			"author's softer notice: a redaction is not a personal choice")
	}
	if !strings.Contains(held, "Withheld pending a legal determination") {
		t.Fatal("the hidden page must carry the redaction notice")
	}
	// AND NOT THE TEXT. A global withholding is pending a legal determination;
	// reprinting it here would be the realm undoing its own act.
	if strings.Contains(held, "something a notice might name") {
		t.Fatal("a redacted row's text must not be republished:\n" + held)
	}
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalClearRow(cross(cur), "bl5", id, row)

	// And the row must NOT be back in the ranked index — the other authority
	// still has it hidden, so a clear that re-indexed it would publish a row its
	// author withdrew.
	if strings.Contains(BoardTop("bl5", id, 0, 10), "something a notice might name") {
		t.Fatal("a clear must not re-index a row the other authority still hides")
	}
}

// boardMark is the one place four states become one character, and three wire
// paths read it. Ordering matters: a purged row that is also hidden reads "x",
// because the fact that the bytes are gone outranks who withdrew it.
func TestBoardMarkRanksTheStatesByWhichFactIsStronger(cur realm, t *testing.T) {
	r := &boardRow{}
	uassert.Equal(t, ".", boardMark(r))
	r.hiddenByAuthor = true
	uassert.Equal(t, "h", boardMark(r))
	r.global = true
	uassert.Equal(t, "g", boardMark(r))
	r.purged = true
	uassert.Equal(t, "x", boardMark(r))
	r.hiddenByAuthor, r.global = false, false
	uassert.Equal(t, "x", boardMark(r))
}

// Every legal act lands in the moderation log, addressed by the comment it
// touched — otherwise a redaction is a thing that happened to a page with no
// record of who did it or to what.
func TestEveryLegalActLandsInTheModerationLog(cur realm, t *testing.T) {
	alice := testutils.TestAddress("bl6-alice")
	id, row := legalFixture(cur, "bl6", alice)
	dadmin := DirectoryAdmin()
	rid := "#" + strconv.FormatUint(row, 10)

	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalHideRow(cross(cur), "bl6", id, row, "dmca")
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalClearRow(cross(cur), "bl6", id, row)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeBoardRow(cross(cur), "bl6", id, row, "csam")

	log := renderModLog("bl6")
	for _, want := range []string{
		"board-global-hide" + rid + ":dmca",
		"board-global-clear" + rid,
		"board-purge" + rid + ":csam",
	} {
		// Through the page's own escaper, not the raw string: renderModLog runs
		// every code through sanitize.InlineText, which escapes the "-" and "#"
		// these codes are built from. Asserting the raw form failed for a reason
		// that had nothing to do with the log, and hard-coding backslashes would
		// pin today's escape set rather than the behaviour.
		if !strings.Contains(log, sanitize.InlineText(want)) {
			t.Fatal("the moderation log does not record " + want + ":\n" + log)
		}
	}
	if !strings.Contains(log, dadmin.String()) {
		t.Fatal("the log must name who acted")
	}
	// THE ID SURVIVES A LOG PURGE. It lives in the code, not the reason, and
	// PurgeModLogRow removes reasons — so a log purge must not erase which
	// comment an act was about.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeModLogRow(cross(cur), "bl6", id, 1, "csam")
	if !strings.Contains(renderModLog("bl6"), sanitize.InlineText("board-global-hide"+rid)) {
		t.Fatal("purging a log row's reason must not take the comment id with it")
	}
}

// boardTextFor's own guard is DEFENCE IN DEPTH — every wire path checks
// boardMark before calling it, so no end-to-end test can reach it with a
// withheld row. Deleting it therefore survived the whole suite. Pinned as a unit
// instead of left as a gap: the guard's value is precisely that it holds when a
// future caller forgets the check, and only a direct call can assert that.
func TestTheWireGateWithholdsOnItsOwnWithoutHelpFromItsCallers(cur realm, t *testing.T) {
	for _, tc := range []struct {
		name string
		row  *boardRow
		want string
	}{
		{"readable", &boardRow{text: "visible"}, "visible"},
		{"hidden by its author", &boardRow{text: "visible", hiddenByAuthor: true}, ""},
		{"hidden by a moderator", &boardRow{text: "visible", hiddenByMod: true}, ""},
		{"redacted", &boardRow{text: "visible", global: true}, ""},
		{"purged", &boardRow{text: "visible", purged: true}, ""},
	} {
		if got := boardTextFor(tc.row); got != tc.want {
			t.Fatal("boardTextFor handed out text for a " + tc.name + " row: " + got)
		}
	}
}

// A hosting-is-offence order against a 400-row board cannot be answered one row
// at a time inside 72 hours. §7.5 refuses a reclaim crank, so the range verb is
// the only way the existing rows are reachable at all.
func TestABoardPurgeIsBatchedResumableAndVotedOnce(cur realm, t *testing.T) {
	alice := testutils.TestAddress("bpr-alice")
	bob := testutils.TestAddress("bpr-bob")
	// boardFixture bootstraps the directory admin itself now, so the subjects of
	// this test can never BE it. The assertion stays as the tripwire: run alone,
	// this test once made alice — whose refusal is the point of the perimeter loop
	// below — the bootstrap global-DAO member, and her "refused" call actually
	// ordered the board destroyed.
	_, id := boardFixture(cur, "bpr", alice)
	dadmin := ensureGlobalDAO().admin
	if dadmin == alice || dadmin == bob {
		t.Fatal("neither subject of this test may be the bootstrap DAO member")
	}
	c := mustCourt("bpr")
	cs := mustClaim(c, id)

	// MORE ROWS THAN ONE BATCH HOLDS, which takes nine authors because the
	// per-author cap is 8. A fixture inside the batch bound cannot tell a bounded
	// loop from an unbounded one, and both the bound and the resume cursor
	// survived deletion until this fixture crossed 64.
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)
	authors := []address{alice, bob}
	for i := 0; i < 7; i++ {
		authors = append(authors, testutils.TestAddress("bpr-w"+strconv.Itoa(i)))
	}
	for _, w := range authors {
		c.coin.Mint(w, 20_000_000_000)
		r := getStanding(c, w)
		r.score = sup * ladderFor(c).t3Bps / 10_000
		r.tokens = postsPerDayAt(ladderFor(c), 3)
	}
	for _, w := range authors {
		for i := 0; i < maxBoardRowsPerAuthor; i++ {
			testing.SetRealm(testing.NewUserRealm(w))
			PostComment(cross(cur), "bpr", id, 0, "row "+strconv.Itoa(i))
		}
	}
	total := cs.board.Size()
	if total <= maxBatchRows {
		t.Fatal("the fixture must exceed one batch, got " + strconv.Itoa(total))
	}

	// A court moderator is not enough — this is the verb that answers a court's
	// own capture, and alice is this court's 1-of-1 mod set.
	for _, who := range []address{alice, bob} {
		testing.SetRealm(testing.NewUserRealm(who))
		uassert.AbortsContains(t, cur, "only a global DAO member may purge", func() {
			PurgeBoardRange(cross(cur), "bpr", id, 0, "csam")
		})
	}

	// TWO GLOBAL MEMBERS, so purgeM can be 2 and "the decision is voted once"
	// becomes observable: at purgeM 1 every call fires on its own signature and a
	// verb that re-voted every batch would look identical. Restored at the end —
	// the global DAO is package state, and leaving purgeM at 2 has already broken
	// a test two files away this session.
	mod2 := testutils.TestAddress("bpr-gmod")
	testing.SetRealm(testing.NewUserRealm(dadmin))
	AddGlobalMod(cross(cur), mod2)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 2)
	// NOT DEFERRED, and that is a correction. testing.SetRealm inside a deferred
	// closure does not take effect — the deferred body runs as whatever caller
	// the test last set, so a restore that needs the admin refuses. This one
	// happened to work only because the body's last SetRealm was already dadmin;
	// its twin in boardmod_test.gno was not, and refused. The restore is inline
	// at the end, and every call that needs the raised threshold comes first.

	// One signature does not start it.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeBoardRange(cross(cur), "bpr", id, 0, "csam")
	if BoardPurgeOrdered("bpr", id) {
		t.Fatal("one key must not order a whole board destroyed")
	}
	testing.SetRealm(testing.NewUserRealm(mod2))
	next := PurgeBoardRange(cross(cur), "bpr", id, 0, "csam")

	// THE ORDER IS VISIBLE FROM THE FIRST BATCH, not from the last: a page that
	// waited for completion would show the material an order named while the
	// remaining batches ran.
	if !BoardPurgeOrdered("bpr", id) {
		t.Fatal("the purge order must be recorded on the first act")
	}
	if !strings.Contains(renderModLog("bpr"), sanitize.InlineText("board-purge-all")) {
		t.Fatal("and must reach the moderation log")
	}

	// Resumable, and nothing is skipped between batches.
	if next == 0 {
		t.Fatal("a board larger than one batch must return a resume cursor")
	}
	// AND A SINGLE MEMBER FINISHES IT. The order was voted; the mechanical
	// completion is not re-voted, or a 500-row board is eight coordinated votes
	// against a 72-hour clock.
	guard := 0
	for next != 0 {
		guard++
		if guard > 50 {
			t.Fatal("the cursor is not advancing")
		}
		testing.SetRealm(testing.NewUserRealm(dadmin))
		next = PurgeBoardRange(cross(cur), "bpr", id, next, "csam")
	}

	// RESTORE HERE, before the first assertion that can t.Fatal. Every call that
	// needed purgeM at 2 is above this line; everything below is a read. An
	// earlier version restored at the very end and, when the test failed early,
	// took five tests in other files down with it — and the defer that was meant
	// to fix that could not, because testing.SetRealm does not take effect inside
	// a deferred closure.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	RemoveGlobalMod(cross(cur), mod2)

	// EVERY row's bytes are gone — not a flag over text still in state.
	left := 0
	cs.board.Iterate("", "", func(_ string, v any) bool {
		r := v.(*boardRow)
		if r.text != "" || !r.purged {
			left++
		}
		return false
	})
	if left != 0 {
		t.Fatal(strconv.Itoa(left) + " rows survived a whole-board purge with their text")
	}
	// The stubs remain: the record still says comments were here and who wrote them.
	if cs.board.Size() != total {
		t.Fatal("a purge removes text, not the fact that a comment existed")
	}
	if !strings.Contains(BoardNewest("bpr", id, 0, 5), "|x|") {
		t.Fatal("purged rows must be marked on the wire, not omitted")
	}

	// THE DECISION IS VOTED ONCE. A second range call on an already-ordered board
	// does not open a fresh proposal — otherwise finishing a 500-row board would
	// be eight coordinated votes against a 72-hour clock.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	if got := PurgeBoardRange(cross(cur), "bpr", id, 0, "csam"); got != 0 {
		t.Fatal("a completed board must report itself done")
	}
	// Nothing is left ranked: Top must not carry a rank for destroyed text.
	if BoardTop("bpr", id, 0, 10) != "" {
		t.Fatal("a purged board must leave the ranked index empty")
	}
	// A code from the OPEN legal set is still required on every call.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	uassert.AbortsContains(t, cur, "category code", func() {
		PurgeBoardRange(cross(cur), "bpr", id, 0, "")
	})
}

// AUDIT D3: a PURGED row could be upvoted, and the vote could never do anything.
//
// UpvoteComment reads the court's purge flag and never the ROW's. Hidden and
// redacted rows accumulating score is deliberate — both states are reversible,
// and board.gno pins that unhiding restores the correct rank. A purge is the one
// state that is not: the bytes are gone, there is no un-purge, and scoreIndexPut
// refuses the row for ever. So the vote spent a scarce daily allowance on an act
// whose effect is unreachable by construction.
//
// That is the same rule the write path already keeps — every refusal before the
// throttle, so a rejected call costs no allowance — applied to a call that was
// not rejected and should have been. One gate, no capability lost.
func TestAPurgedCommentCannotBeUpvoted(cur realm, t *testing.T) {
	alice := testutils.TestAddress("pv-alice")
	bob := testutils.TestAddress("pv-bob")
	_, id := boardFixture(cur, "pv", alice)
	c := mustCourt("pv")
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)

	testing.SetRealm(testing.NewUserRealm(alice))
	row := PostComment(cross(cur), "pv", id, 0, "something later destroyed")
	c.coin.Mint(bob, 20_000_000_000)
	br := getStanding(c, bob)
	br.score = sup * ladderFor(c).t1Bps / 10_000
	br.tokens = postsPerDayAt(ladderFor(c), 1)

	dadmin := ensureGlobalDAO().admin
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeBoardRow(cross(cur), "pv", id, row, "csam")
	if BoardRowState("pv", id, row) != "x" {
		t.Fatal("the fixture must purge the row")
	}

	before := PostsAvailable("pv", bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "destroyed", func() {
		UpvoteComment(cross(cur), "pv", id, row)
	})
	if PostsAvailable("pv", bob) != before {
		t.Fatal("a refused upvote must cost no allowance")
	}
	if CommentScore("pv", id, row) != 0 {
		t.Fatal("a purged row must not accumulate a score it can never use")
	}

	// A HIDDEN row still takes votes, and that difference is the point: a hide is
	// reversible, so the score banked under it is not wasted.
	testing.SetRealm(testing.NewUserRealm(alice))
	live := PostComment(cross(cur), "pv", id, 0, "still here")
	testing.SetRealm(testing.NewUserRealm(alice))
	HideOwnComment(cross(cur), "pv", id, live, true)
	testing.SetRealm(testing.NewUserRealm(bob))
	if UpvoteComment(cross(cur), "pv", id, live) <= 0 {
		t.Fatal("a hidden row must still bank score — unhiding restores the rank")
	}
}

// AUDIT D10: three interactions between legal states that nothing exercised.
// Each verb's own gates were tested; the states meeting each other were not.
func TestTheLegalStatesInteractWithoutWasteOrSilence(cur realm, t *testing.T) {
	alice := testutils.TestAddress("d10-alice")
	// AFTER the fixture, always. ensureGlobalDAO panics outright when no court
	// exists yet — the DAO has no admin to seed from — so reading it first works
	// only when a neighbour has already made a court. That is the same
	// run-alone/run-together split the directory-admin trap produced, arriving
	// from the other direction.
	_, id := boardFixture(cur, "d10", alice)
	dadmin := ensureGlobalDAO().admin
	if dadmin == alice {
		t.Fatal("the fixture must not make the subject the DAO admin")
	}
	c := mustCourt("d10")
	cs := mustClaim(c, id)
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)
	r := getStanding(c, alice)
	r.score = sup * ladderFor(c).t3Bps / 10_000
	r.tokens = postsPerDayAt(ladderFor(c), 3)

	testing.SetRealm(testing.NewUserRealm(alice))
	row := PostComment(cross(cur), "d10", id, 0, "text that a notice will name")
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeBoardRow(cross(cur), "d10", id, row, "csam")
	logAfterPurge := renderModLog("d10")

	// (1) A SECOND PURGE IS A NO-OP, not a fresh act. PurgeModLogRow states the
	// rule for its own log — "already tombstoned; a second purge is a no-op, not
	// an error" — and the board verb did not follow it, so a repeat consumed an
	// m-of-n proposal and wrote another log row for an act with no effect.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeBoardRow(cross(cur), "d10", id, row, "csam")
	if renderModLog("d10") != logAfterPurge {
		t.Fatal("a second purge of the same row must record nothing new")
	}

	// (2) REDACTING A PURGED ROW IS REFUSED. The bytes are already gone, so the
	// act cannot change what anyone sees — but it used to set r.global, arm the
	// re-set window, write a log row claiming a redaction, and emit an event.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	uassert.AbortsContains(t, cur, "already destroyed", func() {
		GlobalHideRow(cross(cur), "d10", id, row, "dmca")
	})
	if mustBoardRow(cs, row).global {
		t.Fatal("a purged row must not carry a redaction bit it cannot act on")
	}
	if renderModLog("d10") != logAfterPurge {
		t.Fatal("a refused redaction must record nothing")
	}

	// (3) A REDACTED CLAIM DOES NOT REDACT ITS BOARD, and the board must say so.
	// The separation is deliberate — §7.6 exists so one infringing comment does
	// not force the whole claim to be redacted — but the converse leaves the
	// discussion of a redacted claim fully readable, and an operator answering a
	// notice needs to know the board is a second surface.
	testing.SetRealm(testing.NewUserRealm(alice))
	live := PostComment(cross(cur), "d10", id, 0, "still readable after the claim is hidden")
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalHide(cross(cur), "d10", id, "dmca")
	if !TextRedacted("d10", id) {
		t.Fatal("the fixture must redact the claim")
	}
	page := renderBoardPage("d10", id)
	if !strings.Contains(page, "still readable after the claim is hidden") {
		t.Fatal("the board is a separate surface; a claim redaction does not reach it")
	}
	if !strings.Contains(page, "claim itself is withheld") {
		t.Fatalf("the board must say its claim is under a legal act:\n%s", page)
	}
	_ = live
}

// AUDIT D12: a notice arrives AFTER the claim settles, which is the ordinary
// case rather than the edge one — and no legal act had ever been tested there.
//
// The board closes to comments and votes at settlement (D3), and the legal verbs
// deliberately carry no boardOpen gate: an obligation to remove material does not
// expire because a market did. Nothing exercised that, so the absence of the gate
// was indistinguishable from an oversight.
func TestTheLegalLaneOutlivesTheClaim(cur realm, t *testing.T) {
	alice := testutils.TestAddress("d12l-alice")
	_, id := boardFixture(cur, "d12l", alice) // before the DAO read; see D10
	dadmin := ensureGlobalDAO().admin
	c := mustCourt("d12l")
	cs := mustClaim(c, id)
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)
	r := getStanding(c, alice)
	r.score = sup * ladderFor(c).t3Bps / 10_000
	r.tokens = postsPerDayAt(ladderFor(c), 3)

	testing.SetRealm(testing.NewUserRealm(alice))
	one := PostComment(cross(cur), "d12l", id, 0, "material a notice will name")
	testing.SetRealm(testing.NewUserRealm(alice))
	two := PostComment(cross(cur), "d12l", id, 0, "more of the same")

	// The claim settles. Comments and votes are closed from here.
	cs.verdictAt = heightNow()
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "board is closed", func() {
		PostComment(cross(cur), "d12l", id, 0, "too late")
	})

	// REDACTION still works, and so does its put-back.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalHideRow(cross(cur), "d12l", id, one, "dmca")
	if BoardRowState("d12l", id, one) != "g" {
		t.Fatal("a redaction must work on a settled claim")
	}
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalClearRow(cross(cur), "d12l", id, one)
	if BoardRowState("d12l", id, one) != "." {
		t.Fatal("and so must the counter-notice put-back")
	}

	// PURGE still works, and still destroys the bytes.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeBoardRow(cross(cur), "d12l", id, two, "csam")
	if mustBoardRow(cs, two).text != "" || BoardRowState("d12l", id, two) != "x" {
		t.Fatal("a purge must work on a settled claim")
	}

	// And so does the WHOLE-BOARD verb, which is what a hosting-is-offence order
	// against an old claim actually needs.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	if next := PurgeBoardRange(cross(cur), "d12l", id, 0, "csam"); next != 0 {
		t.Fatal("a two-row board should finish in one batch")
	}
	if mustBoardRow(cs, one).text != "" {
		t.Fatal("the range purge must reach every row on a settled claim")
	}
}
