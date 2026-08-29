package kourtv2

import (
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// boardFixture: a live claim, and an address that may post on it.
func boardFixture(cur realm, slug string, who address) (*Court, uint64) {
	// THE DIRECTORY-ADMIN TRAP, CLOSED AT ITS ROOT. `directoryAdmin` is the FIRST
	// court creator in the package and the global DAO's bootstrap member, so any
	// test whose fixture creates the first court makes its OWN subject the global
	// DAO — and every "a moderator is not enough" arm silently inverts from
	// refused to allowed. It has done that three times this session, each time
	// invisible when the suite runs together and each time caught only by
	// check-isolation, which is NOT part of `make check`.
	//
	// modFixture already bootstraps a throwaway court for this reason. Doing it
	// here removes the trap for every board test at once, rather than leaving each
	// one to remember. The extra court is one slug and no claims.
	testCourt(cur, slug+"z", testutils.TestAddress("boot-"+slug), 10_000_000_000)
	c := postingFixture(cur, slug, who, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(who))
	id := OpenClaim(cross(cur), slug, "a claim with something to discuss")
	testing.SetRealm(testing.NewUserRealm(who))
	BuyCommentPass(cross(cur), slug)
	return c, id
}

func TestACommentCostsAPostAndLandsNewestFirst(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cm1-alice")
	_, id := boardFixture(cur, "cm1", alice)

	before := PostsAvailable("cm1", alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	r1 := PostComment(cross(cur), "cm1", id, 0, "the first thing")
	uassert.Equal(t, before-1, PostsAvailable("cm1", alice))
	testing.SetRealm(testing.NewUserRealm(alice))
	r2 := PostComment(cross(cur), "cm1", id, 0, "the second thing")
	uassert.Equal(t, int(2), BoardSize("cm1", id))

	// NEWEST FIRST: the second row leads.
	page := BoardNewest("cm1", id, 0, 10)
	lines := strings.Split(strings.TrimSpace(page), "\n")
	uassert.Equal(t, 2, len(lines))
	if !strings.HasPrefix(lines[0], strconv.FormatUint(r2, 10)+"|") || !strings.HasPrefix(lines[1], strconv.FormatUint(r1, 10)+"|") {
		t.Fatalf("newest must lead: %q", page)
	}
	if !strings.Contains(lines[0], "the second thing") {
		t.Fatalf("the row must carry its text: %q", lines[0])
	}

	// Offset pages a STABLE prefix: append-only, so an offset held from an
	// earlier read still points at the same row.
	uassert.Equal(t, 1, len(strings.Split(strings.TrimSpace(BoardNewest("cm1", id, 1, 10)), "\n")))
}



func TestRepliesAreOneLevelDeep(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cm2-alice")
	_, id := boardFixture(cur, "cm2", alice)

	testing.SetRealm(testing.NewUserRealm(alice))
	top := PostComment(cross(cur), "cm2", id, 0, "is this ambiguous about X?")
	testing.SetRealm(testing.NewUserRealm(alice))
	kid := PostComment(cross(cur), "cm2", id, top, "no, X is out of scope")

	// A reply is not on the top-level page, and its parent reports it.
	page := BoardNewest("cm2", id, 0, 10)
	uassert.Equal(t, 1, len(strings.Split(strings.TrimSpace(page), "\n")))
	if !strings.Contains(page, "|1|") {
		t.Fatalf("the parent must report one reply: %q", page)
	}
	if !strings.Contains(BoardReplies("cm2", id, top), "out of scope") {
		t.Fatal("the reply must be readable under its parent")
	}

	// DEPTH ONE: a reply to a reply is refused. Pagination is undefinable on a
	// tree, and deep replies are how a flooder reorders a page without posting
	// more.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "one level deep", func() {
		PostComment(cross(cur), "cm2", id, kid, "and a reply to the reply")
	})
	// A parent that does not exist is refused too, rather than silently becoming
	// top-level.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "no such comment", func() {
		PostComment(cross(cur), "cm2", id, 9999, "orphan")
	})
}

func TestARefusedCommentCostsNoAllowance(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cm3-alice")
	_, id := boardFixture(cur, "cm3", alice)
	before := PostsAvailable("cm3", alice)

	// EVERY REFUSAL SITS ABOVE THE THROTTLE. A mistyped parent, an empty body or
	// an over-long one must not burn a post the poster never made — the allowance
	// refills slowly enough that this is a real cost, not an inconvenience.
	for _, bad := range []struct{ parent uint64; text string }{
		{9999, "orphan"},
		{0, ""},
		{0, "   "},
		{0, strings.Repeat("x", maxBoardTextLen+1)},
	} {
		testing.SetRealm(testing.NewUserRealm(alice))
		uassert.AbortsContains(t, cur, "kourtv2:", func() {
			PostComment(cross(cur), "cm3", id, bad.parent, bad.text)
		})
	}
	uassert.Equal(t, before, PostsAvailable("cm3", alice))
	uassert.Equal(t, int(0), BoardSize("cm3", id))
}

func TestSelfHideIsADiscoveryBitAndNotADelete(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cm4-alice")
	bob := testutils.TestAddress("cm4-bob")
	c, id := boardFixture(cur, "cm4", alice)
	c.coin.Mint(bob, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	row := PostComment(cross(cur), "cm4", id, 0, "something regretted")
	wrote := CommentsWrittenBy("cm4", id, alice)

	testing.SetRealm(testing.NewUserRealm(alice))
	HideOwnComment(cross(cur), "cm4", id, row, true)

	// The row KEEPS its place, its id and its author; only the text goes. It also
	// still counts against the cap — otherwise self-hide would be a way to post
	// nine comments by hiding one.
	page := BoardNewest("cm4", id, 0, 10)
	if !strings.Contains(page, strconv.FormatUint(row, 10)+"|") || !strings.Contains(page, "|h|") {
		t.Fatalf("a hidden row stays, marked: %q", page)
	}
	if strings.Contains(page, "something regretted") {
		t.Fatal("a hidden row must not carry its text")
	}
	uassert.Equal(t, int(1), BoardSize("cm4", id))
	uassert.Equal(t, wrote, CommentsWrittenBy("cm4", id, alice))

	// And only its own author.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "only a comment's author", func() {
		HideOwnComment(cross(cur), "cm4", id, row, true)
	})
}

func TestTheBoardClosesAtEveryTerminalStateAndOnAPurgedCourt(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cm5-alice")
	c, id := boardFixture(cur, "cm5", alice)
	uassert.True(t, BoardOpen("cm5", id))

	// A DEAD CLAIM is terminal without ever crystallizing — which is why the gate
	// reads the verdict/closed pair the rest of the realm uses and not
	// `crystallized`.
	cs := mustClaim(c, id)
	cs.closed = true
	uassert.False(t, BoardOpen("cm5", id))
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "board is closed", func() {
		PostComment(cross(cur), "cm5", id, 0, "too late")
	})
	cs.closed = false
	cs.verdictAt = heightNow() // the other terminal shape
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "board is closed", func() {
		PostComment(cross(cur), "cm5", id, 0, "also too late")
	})
	cs.verdictAt = 0

	// AUDIT D3: AND VOTING STOPS TOO, which nothing tested. Deleting
	// UpvoteComment's boardOpen gate left the suite green — every vote test ran on
	// a live claim. It matters more than it looks: a settled board takes no new
	// comments, so a standing-weighted vote after settlement re-ranks a record
	// nobody can reply to. "What is here stays" has to include the order it is in.
	bob := testutils.TestAddress("cm5-bob")
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)
	c.coin.Mint(bob, 20_000_000_000)
	br := getStanding(c, bob)
	br.score = sup * ladderFor(c).t1Bps / 10_000
	br.tokens = postsPerDayAt(ladderFor(c), 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	row := PostComment(cross(cur), "cm5", id, 0, "a comment to be ranked, or not")

	cs.closed = true
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "board is closed", func() {
		UpvoteComment(cross(cur), "cm5", id, row)
	})
	cs.closed = false
	cs.verdictAt = heightNow()
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "board is closed", func() {
		UpvoteComment(cross(cur), "cm5", id, row)
	})
	cs.verdictAt = 0
	// The control: on a live claim the same vote lands, so the two refusals are
	// about the terminal state and not about a voter who could never vote.
	testing.SetRealm(testing.NewUserRealm(bob))
	if UpvoteComment(cross(cur), "cm5", id, row) <= 0 {
		t.Fatal("the same vote must land on a live claim")
	}

	// A purged court accretes no new content: tombstoning the render would not
	// stop the rows arriving.
	ensureMod(c).courtPurged = true
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "purged", func() {
		PostComment(cross(cur), "cm5", id, 0, "onto a purged court")
	})
	// ...and takes no new votes either, for the same reason.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "purged", func() {
		UpvoteComment(cross(cur), "cm5", id, row)
	})
}

func TestThePerAuthorCapIsFlatAndPerClaim(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cm6-alice")
	c, id := boardFixture(cur, "cm6", alice)

	// Lift alice to the top rung so the THROTTLE is not what refuses her — this
	// pins the page-composition cap, which is flat across levels on purpose.
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)
	getStanding(c, alice).score = sup * ladderFor(c).t3Bps / 10_000
	uassert.Equal(t, int64(3), PostLevel("cm6", alice))

	for i := 0; i < maxBoardRowsPerAuthor; i++ {
		testing.SetRealm(testing.NewUserRealm(alice))
		PostComment(cross(cur), "cm6", id, 0, "one of many")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "comments on this claim", func() {
		PostComment(cross(cur), "cm6", id, 0, "one too many")
	})

	// PER CLAIM: the same author starts fresh on a different claim, because the
	// grief this bounds is concentration on one page.
	testing.SetRealm(testing.NewUserRealm(alice))
	other := OpenClaim(cross(cur), "cm6", "a different question")
	testing.SetRealm(testing.NewUserRealm(alice))
	PostComment(cross(cur), "cm6", other, 0, "and here I may speak")
	uassert.Equal(t, int(1), BoardSize("cm6", other))
}

func TestTheBoardRoutesRenderAndTheDeepLinkSurvivesAHide(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cm7-alice")
	_, id := boardFixture(cur, "cm7", alice)
	sid := strconv.FormatUint(id, 10)

	testing.SetRealm(testing.NewUserRealm(alice))
	row := PostComment(cross(cur), "cm7", id, 0, "a comment with **markup** in it")
	srow := strconv.FormatUint(row, 10)

	page := Render("cm7/" + sid + "/board")
	if !strings.Contains(page, "Comments on claim "+sid) {
		t.Fatalf("the board page must render: %q", page)
	}
	// The badge says who has money on the question — legible composition, not a
	// ranking.
	if !strings.Contains(page, "author") {
		t.Fatalf("the author badge must show: %q", page)
	}

	// THE PER-ROW DEEP LINK IS THE I3 ANALOG: a hide is a discovery bit, and a
	// discovery bit may not remove text from a deep link. So the listing withholds
	// it and its own route still serves it.
	testing.SetRealm(testing.NewUserRealm(alice))
	HideOwnComment(cross(cur), "cm7", id, row, true)
	listing := Render("cm7/" + sid + "/board")
	if strings.Contains(listing, "with **markup** in it") {
		t.Fatal("a hidden row must not render its text in the listing")
	}
	deep := Render("cm7/" + sid + "/board/" + srow)
	if !strings.Contains(deep, "Comment "+srow) || !strings.Contains(deep, "markup") {
		t.Fatalf("the deep link must still serve a hidden row: %q", deep)
	}

	// And the shapes that are not a board row are refused rather than rendered.
	for _, p := range []string{
		"cm7/" + sid + "/board/notanumber",
		"cm7/" + sid + "/board/9999",
		"cm7/" + sid + "/" + alice.String() + "/extra",
	} {
		if got := Render(p); !strings.Contains(got, "Not found") {
			t.Fatalf("%q rendered a page: %q", p, got)
		}
	}
}

func TestTheStandingPageRendersCapabilitiesNotADossier(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cm8-alice")
	c, _ := boardFixture(cur, "cm8", alice)

	page := Render("cm8/me/" + alice.String())
	for _, want := range []string{"level", "a day", "high-water mark", "entry pass",
		"How standing is earned", "Adjudicated"} {
		if !strings.Contains(page, want) {
			t.Fatalf("the standing page must carry %q:\n%s", want, page)
		}
	}
	// The rungs are quoted in THIS court's terms, so a reader can see what the
	// next level actually costs here rather than in bps.
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)
	if !strings.Contains(page, strconv.FormatInt(sup*ladderFor(c).t1Bps/10_000, 10)) {
		t.Fatalf("the rungs must be quoted in standing, not only in bps:\n%s", page)
	}

	// /me with no address is the rules and nothing about anybody.
	idx := Render("cm8/me")
	if strings.Contains(idx, alice.String()) {
		t.Fatal("the index must not name an address")
	}
	if !strings.Contains(idx, "Standing in") {
		t.Fatalf("the index must render: %q", idx)
	}
	// A malformed address is refused, not rendered as a page about nobody.
	if got := Render("cm8/me/not-an-address"); !strings.Contains(got, "Not found") {
		t.Fatalf("a bad address rendered a page: %q", got)
	}
}

// topFixture: a claim with three commenters, and standing for two of them.
func topFixture(cur realm, t *testing.T, slug string) (*Court, uint64, address, address, address) {
	alice := testutils.TestAddress(slug + "-alice") // the claim's author
	bob := testutils.TestAddress(slug + "-bob")
	carol := testutils.TestAddress(slug + "-carol")
	c, id := boardFixture(cur, slug, alice)
	for _, w := range []address{bob, carol} {
		c.coin.Mint(w, 10_000_000_000)
		testing.SetRealm(testing.NewUserRealm(w))
		BuyCommentPass(cross(cur), slug)
	}
	return c, id, alice, bob, carol
}

func TestTopRanksByTheStandingOfWhoUpvoted(cur realm, t *testing.T) {
	c, id, alice, bob, carol := topFixture(cur, t, "cm9")

	testing.SetRealm(testing.NewUserRealm(bob))
	first := PostComment(cross(cur), "cm9", id, 0, "posted first, unremarkable")
	testing.SetRealm(testing.NewUserRealm(carol))
	second := PostComment(cross(cur), "cm9", id, 0, "posted second, the good one")

	// COLD START NEEDS NO CONSTANT. With nothing upvoted, every row scores zero
	// and ties break on the row id, so Top IS Newest.
	top := strings.Split(strings.TrimSpace(BoardTop("cm9", id, 0, 10)), "\n")
	if !strings.HasPrefix(top[0], strconv.FormatUint(second, 10)+"|") {
		t.Fatalf("an unvoted board must read newest-first: %q", top)
	}

	// alice earns standing and lifts the older row above the newer.
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)
	getStanding(c, alice).score = sup * ladderFor(c).t2Bps / 10_000
	testing.SetRealm(testing.NewUserRealm(alice))
	got := UpvoteComment(cross(cur), "cm9", id, first)
	uassert.Equal(t, getStanding(c, alice).score, got)

	top = strings.Split(strings.TrimSpace(BoardTop("cm9", id, 0, 10)), "\n")
	if !strings.HasPrefix(top[0], strconv.FormatUint(first, 10)+"|") {
		t.Fatalf("the upvoted row must lead Top: %q", top)
	}
	// And NEWEST IS UNMOVED — that is the whole point of two orderings.
	newest := strings.Split(strings.TrimSpace(BoardNewest("cm9", id, 0, 10)), "\n")
	if !strings.HasPrefix(newest[0], strconv.FormatUint(second, 10)+"|") {
		t.Fatalf("Top must not reorder Newest: %q", newest)
	}
}

func TestAnUpvoteIsOncePerAddressCostsAPostAndNeedsStanding(cur realm, t *testing.T) {
	c, id, alice, bob, carol := topFixture(cur, t, "cma")
	testing.SetRealm(testing.NewUserRealm(bob))
	row := PostComment(cross(cur), "cma", id, 0, "worth a vote")

	// NO STANDING, NO WEIGHT. A zero-weight vote would be a free write that moves
	// nothing, which is a flood surface with no upside.
	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsContains(t, cur, "you have none here yet", func() {
		UpvoteComment(cross(cur), "cma", id, row)
	})

	sup := c.coin.PastTotal(c.coin.Epoch() - 1)
	getStanding(c, alice).score = sup * ladderFor(c).t1Bps / 10_000
	before := PostsAvailable("cma", alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	UpvoteComment(cross(cur), "cma", id, row)
	// A vote is a state write, so it draws on the same allowance a comment does.
	uassert.Equal(t, before-1, PostsAvailable("cma", alice))
	uassert.True(t, HasUpvoted("cma", id, row, alice))

	// Once per address: the second attempt is refused, and the score is unmoved.
	score := CommentScore("cma", id, row)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "already upvoted", func() {
		UpvoteComment(cross(cur), "cma", id, row)
	})
	uassert.Equal(t, score, CommentScore("cma", id, row))

	// Not your own, and not a reply — only top-level rows are ranked.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "your own comment", func() {
		UpvoteComment(cross(cur), "cma", id, row)
	})
	testing.SetRealm(testing.NewUserRealm(bob))
	kid := PostComment(cross(cur), "cma", id, row, "a reply")
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "only top-level", func() {
		UpvoteComment(cross(cur), "cma", id, kid)
	})
}

func TestTheScoreIndexHoldsOnlyVisibleRowsAndNeverTwice(cur realm, t *testing.T) {
	c, id, alice, bob, _ := topFixture(cur, t, "cmb")
	testing.SetRealm(testing.NewUserRealm(bob))
	row := PostComment(cross(cur), "cmb", id, 0, "here then gone then back")
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)
	getStanding(c, alice).score = sup * ladderFor(c).t2Bps / 10_000

	cs := mustClaim(c, id)
	uassert.Equal(t, 1, cs.boardScore.Size())

	// RE-KEYING MUST NOT LEAVE A SECOND ENTRY. The old key is removed by the
	// value STORED on the row, not by one recomputed from a score that has since
	// moved — otherwise the row renders twice, at two different ranks.
	testing.SetRealm(testing.NewUserRealm(alice))
	UpvoteComment(cross(cur), "cmb", id, row)
	uassert.Equal(t, 1, cs.boardScore.Size())
	uassert.Equal(t, 1, len(strings.Split(strings.TrimSpace(BoardTop("cmb", id, 0, 10)), "\n")))

	// HIDDEN ROWS LEAVE THE INDEX, so a tombstone cannot hold a rank, and a page
	// of Top never has to filter — bptree's offset iteration counts rows VISITED,
	// not rows kept, so filtering would short-page by an attacker-chosen amount.
	testing.SetRealm(testing.NewUserRealm(bob))
	HideOwnComment(cross(cur), "cmb", id, row, true)
	uassert.Equal(t, 0, cs.boardScore.Size())
	uassert.Equal(t, "", BoardTop("cmb", id, 0, 10))
	// But Newest keeps it, marked — the ordering nothing can be pushed off.
	if !strings.Contains(BoardNewest("cmb", id, 0, 10), "|h|") {
		t.Fatal("Newest must keep a hidden row")
	}

	// Unhiding rejoins at the score it had, not at zero.
	testing.SetRealm(testing.NewUserRealm(bob))
	HideOwnComment(cross(cur), "cmb", id, row, false)
	uassert.Equal(t, 1, cs.boardScore.Size())
	uassert.Equal(t, getStanding(c, alice).score, CommentScore("cmb", id, row))
}

func TestThePartiesHoldAReservedSlot(cur realm, t *testing.T) {
	c, id, alice, bob, _ := topFixture(cur, t, "cmc")
	sid := strconv.FormatUint(id, 10)

	// alice is the author. She comments once, then bob buries her under the cap.
	testing.SetRealm(testing.NewUserRealm(alice))
	PostComment(cross(cur), "cmc", id, 0, "what I meant by the claim")
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)
	getStanding(c, bob).score = sup * ladderFor(c).t3Bps / 10_000
	for i := 0; i < maxBoardRowsPerAuthor; i++ {
		testing.SetRealm(testing.NewUserRealm(bob))
		PostComment(cross(cur), "cmc", id, 0, "noise")
	}

	page := Render("cmc/" + sid + "/board")
	if !strings.Contains(page, "The parties") {
		t.Fatalf("the parties section must render: %q", page)
	}
	// The author's comment appears BEFORE the ranked and time-ordered lists, so
	// volume cannot push a party off page one.
	iParties := strings.Index(page, "what I meant by the claim")
	iList := strings.Index(page, "## Newest")
	if iParties < 0 || iParties > iList {
		t.Fatalf("the author's comment must lead the page, not sit in the lists:\n%s", page)
	}
	// ...and EXACTLY ONCE. The page used to print the parties, then Top, then
	// Newest with no dedup, so a reserved slot was really a second copy.
	if n := strings.Count(page, "what I meant by the claim"); n != 1 {
		t.Fatalf("the author's comment rendered %d times on one page:\n%s", n, page)
	}
	// The same guarantee on the ranked view, which is now its own page.
	top := Render("cmc/" + sid + "/board/top")
	if !strings.Contains(top, "The parties") {
		t.Fatalf("the parties hold their slot against RANK too: %q", top)
	}
	if n := strings.Count(top, "what I meant by the claim"); n != 1 {
		t.Fatalf("the author's comment rendered %d times on the ranked page:\n%s", n, top)
	}
	// And the two orderings link to each other, or one of them is unreachable.
	if !strings.Contains(page, "/board/top") || !strings.Contains(top, "/board)") {
		t.Fatal("each ordering must link to the other")
	}
}

// BoardPartyRows is the reserved slot served to a client that renders its own
// board, and every arm here is a way the same two rows go wrong on the wire.
func TestAPartyRowNamesWhichPartyItIs(cur realm, t *testing.T) {
	c, id, alice, bob, carol := topFixture(cur, t, "cpr")
	cs := mustClaim(c, id)
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)
	for _, w := range []address{bob, carol} {
		getStanding(c, w).score = sup * ladderFor(c).t3Bps / 10_000
	}

	// alice is the author. She comments once, then bob buries her under the cap.
	testing.SetRealm(testing.NewUserRealm(alice))
	aliceRow := PostComment(cross(cur), "cpr", id, 0, "what I meant by the claim")
	for i := 0; i < maxBoardRowsPerAuthor; i++ {
		testing.SetRealm(testing.NewUserRealm(bob))
		PostComment(cross(cur), "cpr", id, 0, "noise")
	}

	rows := strings.Split(strings.TrimRight(BoardPartyRows("cpr", id), "\n"), "\n")
	if len(rows) != 1 {
		t.Fatalf("only the author has commented, so there is one row: %q", rows)
	}
	f := strings.SplitN(rows[0], "|", 6)
	if len(f) != 6 {
		t.Fatalf("BoardPartyRows must publish 6 fields, got %d: %q", len(f), rows[0])
	}
	if f[0] != strconv.FormatUint(aliceRow, 10) || f[1] != alice.String() {
		t.Fatalf("BoardPartyRows field order changed: %q", rows[0])
	}
	if f[2] != "author" {
		t.Fatalf("field 3 is the role: %q", rows[0])
	}
	if f[3] != "." || f[5] != "what I meant by the claim" {
		t.Fatalf("mark/text positions changed: %q", rows[0])
	}
	if n, err := strconv.ParseInt(f[4], 10, 64); err != nil || n <= 0 {
		t.Fatalf("field 5 is the block height: %q", rows[0])
	}

	// THE BURIAL THE READ EXISTS FOR, measured rather than asserted: a client
	// scanning a page of BoardNewest for the author's address does not find it.
	// Same mechanism as the count clamp — BoardNewest serves a bounded page of a
	// 512-row board — at a size a test can afford. Without this the whole read is
	// a convenience over a scan the client could have done itself.
	if strings.Contains(BoardNewest("cpr", id, 0, 5), "what I meant by the claim") {
		t.Fatal("the fixture must actually bury the author's row, or the read proves nothing")
	}

	// THE ANSWERER WAITS FOR THE FREEZE. Set with the claim still live, the
	// answerer's comment is not a party row: an unfrozen answer is not one the
	// realm names as an answer anywhere else. Asserting this while cs.answerer is
	// still empty would prove nothing — no row matches either way, and a mutant
	// that dropped the frozenAt half of the gate would read identically.
	testing.SetRealm(testing.NewUserRealm(carol))
	carolRow := PostComment(cross(cur), "cpr", id, 0, "it is the denominator the WHO published")
	cs.answerer = carol
	if strings.Contains(BoardPartyRows("cpr", id), "answerer") {
		t.Fatal("an answer that is not frozen earns no reserved slot")
	}
	cs.frozenAt = heightNow()
	rows = strings.Split(strings.TrimRight(BoardPartyRows("cpr", id), "\n"), "\n")
	if len(rows) != 2 {
		t.Fatalf("both parties have commented now: %q", rows)
	}
	if !strings.HasPrefix(rows[1], strconv.FormatUint(carolRow, 10)+"|"+carol.String()+"|answerer|") {
		t.Fatalf("the answerer's row must name the answerer: %q", rows[1])
	}

	// A PINNED ROW CAN BE A TOMBSTONE. The reserved slot is not filtered on its
	// mark, so the author's newest comment may be one she withdrew. It keeps its
	// place, its role and its field count, and arrives with empty text — a client
	// that renders the badge and then trusts the text prints a name over nothing.
	testing.SetRealm(testing.NewUserRealm(alice))
	HideOwnComment(cross(cur), "cpr", id, aliceRow, true)
	hidden := strings.Split(strings.TrimRight(BoardPartyRows("cpr", id), "\n"), "\n")[0]
	hf := strings.SplitN(hidden, "|", 6)
	if len(hf) != 6 || hf[2] != "author" || hf[3] != "h" || hf[5] != "" {
		t.Fatalf("a withdrawn party row keeps its place, role and arity: %q", hidden)
	}
}

// THE CASE THE ROLE FIELD EXISTS FOR, and the reason it is packed rather than
// derived from position: a claim whose author never commented returns ONE row,
// and it is the ANSWERER'S. A client reading roles off the ordering prints the
// author's name over the answerer's argument — the same mistake it makes reading
// BoardReplies at BoardNewest's arity.
func TestALonePartyRowIsNotAssumedToBeTheAuthors(cur realm, t *testing.T) {
	c, id, _, bob, _ := topFixture(cur, t, "cps")
	cs := mustClaim(c, id)
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)
	getStanding(c, bob).score = sup * ladderFor(c).t3Bps / 10_000

	testing.SetRealm(testing.NewUserRealm(bob))
	bobRow := PostComment(cross(cur), "cps", id, 0, "the only comment on this claim")
	cs.answerer, cs.frozenAt = bob, heightNow()

	only := strings.TrimRight(BoardPartyRows("cps", id), "\n")
	if strings.Contains(only, "\n") {
		t.Fatalf("the author never commented, so there is one row: %q", only)
	}
	if !strings.HasPrefix(only, strconv.FormatUint(bobRow, 10)+"|"+bob.String()+"|answerer|") {
		t.Fatalf("a lone party row must name its own role, not the first one: %q", only)
	}
}

// scoreIndexPut's guard is unreachable through its current callers — PostComment
// only puts top-level rows, and HideOwnComment only puts after clearing the bit —
// so no lifecycle test can drive it. That makes it look like a permanent gap and
// it is not: the function's contract is reachable by calling it, which an
// in-package test may do. The guard is what will hold when the moderator hide
// lands in the moderation lane and puts from a third place.
func TestTheScoreIndexRefusesRepliesAndHiddenRows(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cmd-alice")
	c, id := boardFixture(cur, "cmd", alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	row := PostComment(cross(cur), "cmd", id, 0, "a real row")
	cs := mustClaim(c, id)
	uassert.Equal(t, 1, cs.boardScore.Size())

	// A HIDDEN row must not be indexed: a tombstone holding a rank it can no
	// longer justify is the failure keeping the index visible-only exists to stop.
	r := mustBoardRow(cs, row)
	scoreIndexDrop(cs, r)
	r.hiddenByAuthor = true
	scoreIndexPut(cs, r)
	uassert.Equal(t, 0, cs.boardScore.Size())
	r.hiddenByAuthor = false

	// A REPLY must not be indexed either — only top-level rows are ranked, and a
	// reply in Top would appear detached from the comment it answers.
	r.parent = 999
	scoreIndexPut(cs, r)
	uassert.Equal(t, 0, cs.boardScore.Size())
	r.parent = 0

	// And the ordinary case still indexes, so the refusals above are about the
	// row and not about the function being broken.
	scoreIndexPut(cs, r)
	uassert.Equal(t, 1, cs.boardScore.Size())
}

// A comment is multi-line by design, and every wire read packs rows as
// "…|…|text\n" with the text last. So a newline in a comment did not wrap — it
// closed its own row and opened another one, with an attacker-chosen id and
// author, in BoardNewest, BoardTop and BoardReplies alike.
func TestACommentCannotForgeAWireRow(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fw1-alice")
	_, id := boardFixture(cur, "fw1", alice)
	forged := "g1forgedforgedforgedforgedforgedforgedfo"

	testing.SetRealm(testing.NewUserRealm(alice))
	row := PostComment(cross(cur), "fw1", id, 0,
		"looks innocent\n999|"+forged+"|0|.|a verdict is coming")

	// The comment survives as ONE row on every wire read.
	for name, wire := range map[string]string{
		"BoardNewest": BoardNewest("fw1", id, 0, 10),
		"BoardTop":    BoardTop("fw1", id, 0, 10),
	} {
		if strings.Contains(wire, "\n999|") {
			t.Fatal(name + " carried a forged row:\n" + wire)
		}
		if strings.Count(strings.TrimRight(wire, "\n"), "\n") != 0 {
			t.Fatal(name + " returned more rows than were posted:\n" + wire)
		}
		if !strings.Contains(wire, "looks innocent") {
			t.Fatal(name + " dropped the comment instead of escaping it")
		}
	}
	// A reply carries the same guarantee — it is the third packer.
	testing.SetRealm(testing.NewUserRealm(alice))
	PostComment(cross(cur), "fw1", id, row, "reply\n998|"+forged+"|.|forged")
	rep := BoardReplies("fw1", id, row)
	if strings.Contains(rep, "\n998|") {
		t.Fatal("BoardReplies carried a forged row:\n" + rep)
	}

	// AND THE TEXT IS STILL MULTI-LINE. Escaping, not refusing: a comment that
	// could not contain a newline would not be the multi-line comment the design
	// asks for, and sanitize.Block on the page would have nothing to do.
	cs := mustClaim(mustCourt("fw1"), id)
	if !strings.Contains(mustBoardRow(cs, row).text, "\n") {
		t.Fatal("the stored comment must keep its newlines; only the wire escapes")
	}
	if !strings.Contains(renderBoardPage("fw1", id), "looks innocent") {
		t.Fatal("the page must still render the comment")
	}
	// The escape must itself be unforgeable: a literal backslash-n in the text
	// must not arrive on the wire indistinguishable from an escaped newline.
	testing.SetRealm(testing.NewUserRealm(alice))
	PostComment(cross(cur), "fw1", id, 0, `a literal \n here`)
	if !strings.Contains(BoardNewest("fw1", id, 0, 10), `a literal \\n here`) {
		t.Fatal("a backslash in the text must be escaped, or the escape is forgeable")
	}
}

// THE BOARD MUST BE REACHABLE, AND ITS SECOND LEVEL MUST BE READABLE. Both were
// broken on the rendered site: the claim page carried no link to the board at
// all, and BoardReplies — the only function that reads a reply — had no caller
// on any render path, so replies were write-only in gnoweb.
func TestTheClaimLinksItsBoardAndRepliesRender(cur realm, t *testing.T) {
	alice := testutils.TestAddress("wire-alice")
	_, id := boardFixture(cur, "wire", alice)
	sid := strconv.FormatUint(id, 10)

	// An empty board still invites: that is the one most worth a first comment.
	claim := Render("wire/" + sid)
	if !strings.Contains(claim, "/board") {
		t.Fatalf("the claim page must link its board:\n%s", claim)
	}
	if !strings.Contains(claim, "no comments yet") {
		t.Fatal("an empty board should say so rather than pretend to be busy")
	}

	testing.SetRealm(testing.NewUserRealm(alice))
	row := PostComment(cross(cur), "wire", id, 0, "the top-level point")
	testing.SetRealm(testing.NewUserRealm(alice))
	PostComment(cross(cur), "wire", id, row, "the answer to the point")

	// The count is on the claim page, because "Comments" alone cannot tell an
	// empty board from a busy one and that is the reason to click.
	claim = Render("wire/" + sid)
	if !strings.Contains(claim, "2 comments") && !strings.Contains(claim, "1 comment") {
		t.Fatalf("the claim page must say how many comments there are:\n%s", claim)
	}

	// THE REPLY'S TEXT, on the page. Not a count, not a link — the text.
	page := Render("wire/" + sid + "/board")
	if !strings.Contains(page, "the answer to the point") {
		t.Fatalf("a reply must render under its parent:\n%s", page)
	}
	if !strings.Contains(page, "> ") {
		t.Fatal("a reply must be visually nested, or depth one is invisible")
	}
	// And it keeps its own deep link, because a reply is quotable evidence too.
	if !strings.Contains(page, "/board/"+strconv.FormatUint(row+1, 10)+")") {
		t.Fatalf("a reply must carry its own link:\n%s", page)
	}

	// A WITHHELD REPLY IS NOT SHOWN. The reply renderer is a third place user
	// text reaches a page, and it needs the same mark check the two orderings
	// have — deleting it left the suite green until this arm existed.
	testing.SetRealm(testing.NewUserRealm(alice))
	HideOwnComment(cross(cur), "wire", id, row+1, true)
	page = Render("wire/" + sid + "/board")
	if strings.Contains(page, "the answer to the point") {
		t.Fatalf("a withdrawn reply must not render its text:\n%s", page)
	}
	if !strings.Contains(page, "Not shown") {
		t.Fatal("and the page must say a reply is there rather than drop it silently")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	HideOwnComment(cross(cur), "wire", id, row+1, false)

	// THE SHOWN BOUND. A parent with more replies than fit must render the first
	// maxBoardRepliesShown and say how many more there are — an unbounded loop
	// here makes one comment's cost O(its replies) on a page that also renders
	// every other comment.
	c := mustCourt("wire")
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)
	bob := testutils.TestAddress("wire-bob")
	c.coin.Mint(bob, 20_000_000_000)
	// Raise the level AND prime the bucket. A promotion deliberately does not top
	// up the allowance (bucketAt keeps the stamp), so raising score alone leaves
	// alice at zero tokens and the loop below panics on the throttle rather than
	// exercising the renderer.
	for _, w := range []address{alice, bob} {
		r := getStanding(c, w)
		r.score = sup * ladderFor(c).t3Bps / 10_000
		r.tokens = postsPerDayAt(ladderFor(c), 3)
	}
	// alice is at the per-author cap after 8 rows, so the tail comes from bob.
	for i := 0; i < 6; i++ {
		testing.SetRealm(testing.NewUserRealm(alice))
		PostComment(cross(cur), "wire", id, row, "alice reply "+strconv.Itoa(i))
	}
	for i := 0; i < 3; i++ {
		testing.SetRealm(testing.NewUserRealm(bob))
		PostComment(cross(cur), "wire", id, row, "bob reply "+strconv.Itoa(i))
	}
	if got := boardReplyCount(mustClaim(c, id), row); got != 10 {
		t.Fatal("the fixture must exceed the shown bound, got " + strconv.Itoa(got))
	}
	page = Render("wire/" + sid + "/board")
	if !strings.Contains(page, "more repl") {
		t.Fatalf("a truncated reply list must say how many are not shown:\n%s", page)
	}
	if strings.Contains(page, "bob reply 2") {
		t.Fatal("the reply list must stop at maxBoardRepliesShown")
	}
}

// The standing page must say where a score came from IN WORDS, and must not
// recite categories the address has nothing in. It used to print
// StandingBreakdown verbatim — a semicolon-separated wire format on a human
// page, listing four categories most of which are zero for most addresses.
func TestTheStandingPageNamesOnlyWhatWasEarned(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sfb-alice")
	c := postingFixture(cur, "sfb", alice, 50_000_000_000)

	// Nothing earned: the page says nothing about categories rather than
	// telling a new participant four things that are not true of them.
	page := renderStanding("sfb", alice.String())
	if strings.Contains(page, "from:") {
		t.Fatalf("an address with no standing must not be given a breakdown:\n%s", page)
	}
	if strings.Contains(page, "score:") || strings.Contains(page, ";highwater:") {
		t.Fatal("the wire format must not reach a human page")
	}

	creditStanding(c, alice, 4_000, standingCatDispute)
	page = renderStanding("sfb", alice.String())
	if !strings.Contains(page, "disputes you prevailed in") {
		t.Fatalf("the page must name the category the standing came from:\n%s", page)
	}
	if !strings.Contains(page, "4000 from") {
		t.Fatal("...and how much came from it")
	}
	// The three categories with nothing in them stay off the page.
	for _, absent := range []string{"quality flags", "rated HIGH", "conviction on resolved"} {
		if strings.Contains(page, absent) {
			t.Fatalf("a zero category must not be listed: %q\n%s", absent, page)
		}
	}
	// StandingBreakdown itself is untouched — it is the qeval read a client
	// parses, and moving the page off it must not have changed the wire.
	if !strings.Contains(StandingBreakdown("sfb", alice), "dispute:4000") {
		t.Fatal("the packed read must still carry the breakdown for clients")
	}
}

// A deep link is a citation handle, and a citation carries a date.
func TestACommentCitesTheBlockItLandedIn(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cite-alice")
	_, id := boardFixture(cur, "cite", alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	row := PostComment(cross(cur), "cite", id, 0, "a statement worth citing")
	at := mustBoardRow(mustClaim(mustCourt("cite"), id), row).at
	if at == 0 {
		t.Fatal("a comment must record the height it landed in")
	}
	want := "block " + strconv.FormatInt(at, 10)
	if !strings.Contains(renderBoardRow("cite", id, strconv.FormatUint(row, 10)), want) {
		t.Fatal("the row's own page must cite its block")
	}
	if !strings.Contains(renderBoardPage("cite", id), want) {
		t.Fatal("and so must the listing")
	}
}

// A claim whose board is one comment must not carry three permanently empty
// trees. The reads all nil-guard already, so deferring the allocation costs a
// branch that was there either way.
func TestTheUnusedIndexesAreNotAllocated(cur realm, t *testing.T) {
	alice := testutils.TestAddress("lz-alice")
	_, id := boardFixture(cur, "lz", alice)
	cs := mustClaim(mustCourt("lz"), id)

	testing.SetRealm(testing.NewUserRealm(alice))
	row := PostComment(cross(cur), "lz", id, 0, "one top-level comment, nothing else")
	if cs.boardKids != nil {
		t.Fatal("a board with no replies must not carry a replies index")
	}
	if cs.boardVoted != nil {
		t.Fatal("a board with no upvotes must not carry a vote index")
	}
	// boardScore IS allocated: a visible top-level row enters the ranked index at
	// score 0, which is what makes Top degenerate to Newest at cold start.
	if cs.boardScore == nil {
		t.Fatal("a visible top-level row must be ranked from the start")
	}

	// And every read is safe against the nil, which is the whole precondition.
	if BoardReplies("lz", id, row) != "" || boardReplyCount(cs, row) != 0 {
		t.Fatal("the replies read must be safe on a board with no replies")
	}
	if HasUpvoted("lz", id, row, alice) {
		t.Fatal("the vote read must be safe on a board with no votes")
	}
	if !strings.Contains(renderBoardPage("lz", id), "one top-level comment") {
		t.Fatal("the page must render with the unused indexes absent")
	}

	// They appear when first written, and work.
	testing.SetRealm(testing.NewUserRealm(alice))
	PostComment(cross(cur), "lz", id, row, "now there is a reply")
	if cs.boardKids == nil || boardReplyCount(cs, row) != 1 {
		t.Fatal("the replies index must appear on the first reply")
	}
	bob := testutils.TestAddress("lz-bob")
	c := mustCourt("lz")
	c.coin.Mint(bob, 20_000_000_000)
	getStanding(c, bob).score = c.coin.PastTotal(c.coin.Epoch()-1) * ladderFor(c).t1Bps / 10_000
	testing.SetRealm(testing.NewUserRealm(bob))
	UpvoteComment(cross(cur), "lz", id, row)
	if cs.boardVoted == nil || !HasUpvoted("lz", id, row, bob) {
		t.Fatal("the vote index must appear on the first upvote")
	}
}

// EVERY CLAIM-TAKING BOARD READ, ON A CLAIM NOBODY HAS EVER COMMENTED ON.
//
// These ten cannot go in z_read_filetest — the meta court has no claims, and
// creating one is a write, which is exactly what that file must not do (the
// budget table keeps it at None so "reads write nothing" stays visible). So the
// dynamic half of their guarantee lives here instead.
//
// Two failure modes, and the realm has now shipped both at least once: a read
// that PANICS where it should answer (the fresh-court sealed-epoch abort, found
// by that filetest), and a read that ALLOCATES (the three lazily-created indexes
// make that a live possibility rather than a hypothetical). Every read below is
// called on a board that does not exist, and then the trees are checked to still
// not exist.
func TestEveryBoardReadAnswersOnAClaimWithNoBoard(cur realm, t *testing.T) {
	alice := testutils.TestAddress("nb-alice")
	c := postingFixture(cur, "nb", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "nb", "a claim nobody comments on")
	cs := mustClaim(c, id)

	// Not one index exists yet — ensureBoard runs on the first comment.
	if cs.board != nil || cs.boardTop != nil || cs.boardWrote != nil {
		t.Fatal("a claim with no comments must carry no board at all")
	}

	// Each read ANSWERS. A panic here is the fresh-court defect in another guise.
	if BoardNewest("nb", id, 0, 10) != "" || BoardTop("nb", id, 0, 10) != "" {
		t.Fatal("the orderings must be empty, not wrong")
	}
	if BoardReplies("nb", id, 1) != "" {
		t.Fatal("replies to a row that does not exist are none, not a panic")
	}
	// The parties read is the one that would NOT answer without its own nil
	// guard: boardPartyRows iterates boardTop unconditionally, and the render
	// reaches it only past its own empty-board early return.
	if BoardPartyRows("nb", id) != "" {
		t.Fatal("a claim with no board has no party rows, and must not panic finding out")
	}
	if BoardSize("nb", id) != 0 {
		t.Fatal("an absent board has size 0")
	}
	if !BoardOpen("nb", id) {
		t.Fatal("a live claim with no comments is open to them")
	}
	if BoardPurgeOrdered("nb", id) || ClaimBoardFrozenUntil("nb", id) != 0 {
		t.Fatal("no order and no freeze on an untouched board")
	}
	if HasUpvoted("nb", id, 1, alice) {
		t.Fatal("nobody has upvoted a row that does not exist")
	}
	if !strings.Contains(renderBoardPage("nb", id), "No comments yet") {
		t.Fatal("the page must say the board is empty")
	}
	if !strings.Contains(renderBoardTop("nb", id), "No comments yet") {
		t.Fatal("and so must the ranked view")
	}
	if !strings.Contains(Render("nb/"+strconv.FormatUint(id, 10)), "no comments yet") {
		t.Fatal("the claim page must invite the first comment")
	}

	// AND NOT ONE OF THEM ALLOCATED. This is the assertion the static census
	// (check-read-purity) makes by name and this one makes by observation; the
	// two disagree only if a read reaches an allocator the census does not know.
	if cs.board != nil || cs.boardTop != nil || cs.boardWrote != nil ||
		cs.boardKids != nil || cs.boardScore != nil || cs.boardVoted != nil {
		t.Fatal("a read allocated an index on a claim with no board")
	}

	// The two that ASSERT rather than answer, because they name a specific row
	// and a caller who names one that is not there has made an error, not a
	// query. They must refuse cleanly rather than reaching for a nil tree.
	uassert.PanicsContains(t, cur, "no such comment", func() {
		CommentScore("nb", id, 1)
	})
	uassert.PanicsContains(t, cur, "no such comment", func() {
		BoardRowState("nb", id, 1)
	})
	if cs.board != nil {
		t.Fatal("even a refused read must not allocate")
	}
}

// AUDIT D1: the per-author cap counts REPLIES, and the party under scrutiny is
// the one it silences.
//
// maxBoardRowsPerAuthor is documented as "a PAGE-COMPOSITION rule and not a rate
// limit... the grief is concentration on one claim". But a reply is not a
// page-level row — it renders nested under its parent — so counting replies
// against a page cap spends the budget on rows that occupy no page slot.
//
// The consequence is not symmetric. A claim's author is structurally the
// most-replied-to participant, and §5 gives them a reserved slot precisely so
// they "can answer a question about their own claim and have the answer seen".
// Answer eight questions and the slot is empty: they cannot post at all, while
// each questioner has spent 1 of their 8.
//
// This test asserts CURRENT behaviour. It is the evidence for the ruling
// recorded in CLAIM_BOARDS.md, not an endorsement.
func TestTheAuthorIsSilencedByAnsweringQuestions(cur realm, t *testing.T) {
	author := testutils.TestAddress("cap-author")
	c, id := boardFixture(cur, "cap", author)
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)

	// Everyone at the top rung with a full bucket: this test is about the cap,
	// not the throttle.
	prime := func(w address) {
		c.coin.Mint(w, 20_000_000_000)
		r := getStanding(c, w)
		r.score = sup * ladderFor(c).t3Bps / 10_000
		r.tokens = postsPerDayAt(ladderFor(c), 3)
	}
	prime(author)

	testing.SetRealm(testing.NewUserRealm(author))
	top := PostComment(cross(cur), "cap", id, 0, "the claim means this")

	// Seven questioners, one question each.
	for i := 0; i < 7; i++ {
		q := testutils.TestAddress("cap-q" + strconv.Itoa(i))
		prime(q)
		testing.SetRealm(testing.NewUserRealm(q))
		PostComment(cross(cur), "cap", id, top, "question "+strconv.Itoa(i))
	}

	// The author answers all seven. That is 1 + 7 = 8 rows, the whole budget.
	for i := 0; i < 7; i++ {
		testing.SetRealm(testing.NewUserRealm(author))
		PostComment(cross(cur), "cap", id, top, "answer "+strconv.Itoa(i))
	}
	if got := boardWroteBy(mustClaim(c, id), author); got != maxBoardRowsPerAuthor {
		t.Fatal("the fixture must land the author exactly on the cap, got " +
			strconv.FormatInt(got, 10))
	}

	// AND NOW THE AUTHOR OF THE CLAIM CANNOT SPEAK ON IT AT ALL — not a reply,
	// and not the top-level clarification their reserved slot exists to hold.
	testing.SetRealm(testing.NewUserRealm(author))
	uassert.AbortsContains(t, cur, "you already have 8 comments on this claim", func() {
		PostComment(cross(cur), "cap", id, 0, "to be clear, the claim means this")
	})

	// While every questioner has seven rows left.
	q0 := testutils.TestAddress("cap-q0")
	if got := boardWroteBy(mustClaim(c, id), q0); got != 1 {
		t.Fatal("a questioner should have spent exactly one row")
	}
	testing.SetRealm(testing.NewUserRealm(q0))
	PostComment(cross(cur), "cap", id, top, "and another question")
}

// AUDIT D2: the 2,000 cap is BYTES and the refusal says "characters".
//
// Not a bug — the same shape as every other length check in this realm — but the
// effective limit depends on the script you write in, and the message does not
// say so. A comment in a three-byte-per-rune script is cut off at ~666 of the
// "2000 characters" it was promised.
func TestTheCommentCapIsBytesNotCharacters(cur realm, t *testing.T) {
	alice := testutils.TestAddress("byt-alice")
	c, id := boardFixture(cur, "byt", alice)
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)
	r := getStanding(c, alice)
	r.score = sup * ladderFor(c).t3Bps / 10_000
	r.tokens = postsPerDayAt(ladderFor(c), 3)

	// 700 three-byte runes = 2,100 bytes: well under 2,000 characters, over the cap.
	wide := strings.Repeat("あ", 700)
	if len(wide) <= maxBoardTextLen {
		t.Fatal("the fixture must exceed the BYTE cap while under the character count")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "at most 2000 characters", func() {
		PostComment(cross(cur), "byt", id, 0, wide)
	})
	// And the same rune count in a one-byte script is accepted, which is the
	// asymmetry itself.
	testing.SetRealm(testing.NewUserRealm(alice))
	PostComment(cross(cur), "byt", id, 0, strings.Repeat("a", 700))
}

// AUDIT D2: a refused comment allocates nothing.
//
// The gate order gives this for free — ensureBoard runs after every refusal —
// and it matters because a query or a rejected write that grows state is state
// nobody paid for. Pinned because "after" is an ordering, and orderings drift.
func TestARefusedCommentAllocatesNoIndex(cur realm, t *testing.T) {
	alice := testutils.TestAddress("d2na-alice")
	c, id := boardFixture(cur, "d2na", alice)
	cs := mustClaim(c, id)

	// Refused on text, before anything is built.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "a comment needs text", func() {
		PostComment(cross(cur), "d2na", id, 0, "   ")
	})
	if cs.board != nil || cs.boardTop != nil || cs.boardWrote != nil {
		t.Fatal("a refused comment built the board")
	}
	// Refused on the depth rule, which reads a row — and reading one on an empty
	// board must not create one either.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "no such comment", func() {
		PostComment(cross(cur), "d2na", id, 99, "replying to nothing")
	})
	if cs.board != nil {
		t.Fatal("a refused reply built the board")
	}
}

// AUDIT D2: the per-claim cap is what bounds every read cost on a board, and
// nothing tested it.
//
// 512 rows is the number renderBoardIn pages against, boardPartyRows scans, and
// BoardSize reports; D1 recorded it as the bound the other five indexes inherit.
// Deleting the gate left the suite green — no test had ever filled a board.
//
// The rows are inserted DIRECTLY rather than posted. The gate reads
// cs.board.Size() and nothing else, and 512 real posts would cost 64 primed
// authors and minutes of suite time to exercise one comparison. What must be
// real is the refusal, and that is.
func TestThePerClaimCapBoundsWhatOneBoardCanCost(cur realm, t *testing.T) {
	alice := testutils.TestAddress("d2fc-alice")
	bob := testutils.TestAddress("d2fc-bob")
	c, id := boardFixture(cur, "d2fc", alice)
	cs := mustClaim(c, id)
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)

	// bob is unblocked by everything except the per-claim cap: top rung, full
	// bucket, and no rows of his own on this claim.
	c.coin.Mint(bob, 20_000_000_000)
	br := getStanding(c, bob)
	br.score = sup * ladderFor(c).t3Bps / 10_000
	br.tokens = postsPerDayAt(ladderFor(c), 3)

	ensureBoard(cs)
	for i := 0; i < maxBoardRowsPerClaim; i++ {
		cs.boardNextID++
		r := &boardRow{id: cs.boardNextID, author: alice, text: "filler", at: 1}
		cs.board.Set(beClaimKey(r.id), r)
	}
	if cs.board.Size() != maxBoardRowsPerClaim {
		t.Fatal("the fixture must sit exactly on the cap, got " + strconv.Itoa(cs.board.Size()))
	}
	if boardWroteBy(cs, bob) != 0 {
		t.Fatal("bob must be clear of the per-author cap, or this tests that instead")
	}

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "this claim's board is full", func() {
		PostComment(cross(cur), "d2fc", id, 0, "one row past the ceiling")
	})
	// A reply is refused by the same ceiling — the cap counts every row, which is
	// what makes it a bound on cost rather than on page slots.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "this claim's board is full", func() {
		PostComment(cross(cur), "d2fc", id, 1, "a reply past the ceiling")
	})
	// And bob's allowance is untouched: the ceiling is a refusal, not a charge.
	if PostsAvailable("d2fc", bob) != postsPerDayAt(ladderFor(c), 3) {
		t.Fatal("a refusal at the per-claim cap must cost no allowance")
	}
}

// AUDIT D4: after a claim settles, a VOTE cannot change the board's order but the
// author's own hide can.
//
// D3 established why voting stops at settlement: a standing-weighted vote
// re-ranks a record nobody can reply to. HideOwnComment has no boardOpen gate, so
// the same board's order is still editable — by the one participant with the most
// reason to edit it, after the verdict is known, with no counter-speech possible.
//
// The row survives at its own link, so this is curation of the LISTING and not
// destruction of evidence. That is exactly why it is a ruling and not a fix: the
// capability is real and might be wanted. This test asserts current behaviour.
func TestASettledBoardsOrderIsStillEditableByItsAuthors(cur realm, t *testing.T) {
	alice := testutils.TestAddress("d4s-alice")
	bob := testutils.TestAddress("d4s-bob")
	c, id := boardFixture(cur, "d4s", alice)
	cs := mustClaim(c, id)
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)

	testing.SetRealm(testing.NewUserRealm(alice))
	row := PostComment(cross(cur), "d4s", id, 0, "a remark that ages badly")
	c.coin.Mint(bob, 20_000_000_000)
	br := getStanding(c, bob)
	br.score = sup * ladderFor(c).t1Bps / 10_000
	br.tokens = postsPerDayAt(ladderFor(c), 1)
	if !topHasRow("d4s", id, row) {
		t.Fatal("the fixture must start with the row ranked")
	}

	// Settle the claim.
	cs.verdictAt = heightNow()

	// A VOTE IS REFUSED — the order of a settled board is fixed, per D3.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "board is closed", func() {
		UpvoteComment(cross(cur), "d4s", id, row)
	})

	// THE AUTHOR'S HIDE IS NOT. Same board, same moment, and it removes the row
	// from the ranked view outright.
	testing.SetRealm(testing.NewUserRealm(alice))
	HideOwnComment(cross(cur), "d4s", id, row, true)
	if topHasRow("d4s", id, row) {
		t.Fatal("the hide did not take effect, so this test proves nothing")
	}
	if BoardRowState("d4s", id, row) != "h" {
		t.Fatal("expected the author's hide bit on a settled claim")
	}
	// And it is reversible, on a settled claim, indefinitely.
	testing.SetRealm(testing.NewUserRealm(alice))
	HideOwnComment(cross(cur), "d4s", id, row, false)
	if !topHasRow("d4s", id, row) {
		t.Fatal("and back again")
	}
	// The deep link served throughout, which is what keeps this curation rather
	// than deletion — and is the argument for leaving it alone.
	if !strings.Contains(renderBoardRow("d4s", id, strconv.FormatUint(row, 10)),
		"a remark that ages badly") {
		t.Fatal("the row must remain readable at its own link")
	}
}

// AUDIT D4: hiding is not a way around the per-author cap.
//
// board.gno states it — "it still counts against its author's per-claim cap.
// Otherwise self-hide would be a way to post nine comments by hiding one" — and
// nothing tested it. boardWrote is a counter that only increments, so the
// property holds by construction; this pins the construction.
func TestHidingDoesNotBuyAnExtraComment(cur realm, t *testing.T) {
	alice := testutils.TestAddress("d4c-alice")
	c, id := boardFixture(cur, "d4c", alice)
	cs := mustClaim(c, id)
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)
	r := getStanding(c, alice)
	r.score = sup * ladderFor(c).t3Bps / 10_000
	r.tokens = postsPerDayAt(ladderFor(c), 3)

	rows := []uint64{}
	for i := 0; i < maxBoardRowsPerAuthor; i++ {
		testing.SetRealm(testing.NewUserRealm(alice))
		rows = append(rows, PostComment(cross(cur), "d4c", id, 0, "row "+strconv.Itoa(i)))
	}
	// Hide every one of them. The counter must not move.
	for _, row := range rows {
		testing.SetRealm(testing.NewUserRealm(alice))
		HideOwnComment(cross(cur), "d4c", id, row, true)
	}
	if got := boardWroteBy(cs, alice); got != maxBoardRowsPerAuthor {
		t.Fatal("hiding changed the author's row count: " + strconv.FormatInt(got, 10))
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "you already have 8 comments on this claim", func() {
		PostComment(cross(cur), "d4c", id, 0, "the ninth, bought by hiding eight")
	})
}

// AUDIT D5: what the display gate actually neutralises, measured rather than
// assumed — and what it deliberately does not.
//
// Nothing asserted any of this. `sanitize.Block` was chosen over `BlockRich` and
// over `InlineText` for stated reasons, and a switch back, or a change inside the
// shared sanitiser, would have been silent. These are the escapes a comment board
// depends on: a comment is attacker-controlled multi-line text on a page people
// stake money on, and gnoweb runs no HTML sanitiser after the realm.
func TestTheDisplayGateNeutralisesBlockInjection(cur realm, t *testing.T) {
	alice := testutils.TestAddress("d5-alice")
	c, id := boardFixture(cur, "d5", alice)
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)
	r := getStanding(c, alice)
	r.score = sup * ladderFor(c).t3Bps / 10_000
	r.tokens = postsPerDayAt(ladderFor(c), 3)
	cs := mustClaim(c, id)

	// NO CLOSURE HELPER HERE, and that is not style. testing.SetRealm does not
	// establish the caller for a crossing call made inside a closure — the same
	// limitation that makes a deferred restore run as the wrong address. A
	// `post := func(...)` helper looked obviously right and every call inside it
	// arrived as nobody, refused at level 0.
	postAndShow := func(row uint64) string { return boardTextVisible(mustBoardRow(cs, row)) }

	// A HEADING cannot be promoted out of a comment: the marker is escaped, so
	// the comment cannot fake realm chrome or restructure the page outline.
	testing.SetRealm(testing.NewUserRealm(alice))
	if out := postAndShow(PostComment(cross(cur), "d5", id, 0, "# Fake heading")); !strings.Contains(out, "\\# Fake heading") {
		t.Fatalf("a line-leading # must be escaped: %q", out)
	}
	// A SETEXT UNDERLINE cannot promote the line above it — including realm text.
	testing.SetRealm(testing.NewUserRealm(alice))
	if out := postAndShow(PostComment(cross(cur), "d5", id, 0, "---")); !strings.Contains(out, "\\---") {
		t.Fatalf("a setext/HR line must be escaped: %q", out)
	}
	// A GFM TABLE ROW cannot start a table that swallows what follows.
	testing.SetRealm(testing.NewUserRealm(alice))
	if out := postAndShow(PostComment(cross(cur), "d5", id, 0, "| a | b |")); !strings.Contains(out, "\\| a | b |") {
		t.Fatalf("a table row must be escaped: %q", out)
	}
	// LIST and BLOCKQUOTE markers cannot restructure the block.
	testing.SetRealm(testing.NewUserRealm(alice))
	if out := postAndShow(PostComment(cross(cur), "d5", id, 0, "* list item")); !strings.Contains(out, "\\* list item") {
		t.Fatalf("a list marker must be escaped: %q", out)
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	if out := postAndShow(PostComment(cross(cur), "d5", id, 0, "> quoted")); !strings.Contains(out, "\\> quoted") {
		t.Fatalf("a blockquote marker must be escaped: %q", out)
	}
	// A LINK REFERENCE DEFINITION is REMOVED, not escaped — it would otherwise
	// bind a name that realm chrome elsewhere on the page might use.
	testing.SetRealm(testing.NewUserRealm(alice))
	if out := postAndShow(PostComment(cross(cur), "d5", id, 0, "[ref]: http://evil")); strings.Contains(out, "http://evil") {
		t.Fatalf("a link reference definition must not survive: %q", out)
	}

	// THE ENVELOPE. Every non-empty result is wrapped in blank lines on both
	// sides, which is what bounds CommonMark HTML block types 6 and 7 — they close
	// on a blank line, so an unclosed <div> cannot extend into the realm's own
	// output that follows.
	testing.SetRealm(testing.NewUserRealm(alice))
	out := postAndShow(PostComment(cross(cur), "d5", id, 0, "<div>unclosed"))
	if !strings.HasPrefix(out, "\n\n") || !strings.HasSuffix(out, "\n\n") {
		t.Fatalf("the block envelope is what contains raw HTML: %q", out)
	}
	// And the containment is real on the whole page: the separator renderBoardOne
	// writes after the comment still stands on its own.
	if !strings.Contains(renderBoardPage("d5", id), "\n\n---\n\n") {
		t.Fatal("an unclosed HTML block reached the realm's own chrome")
	}
}

// AUDIT D5: the wire gate is raw BY CONTRACT, and carries content the page drops.
//
// boardTextFor escapes only what the row format needs — backslash, newline,
// carriage return — because a client sanitises for its own context. The gap
// between the two gates is therefore real and intended, and worth pinning so a
// client author can see it: the wire hands over a link-reference definition that
// the realm's own page removes.
func TestTheWireGateCarriesWhatThePageDrops(cur realm, t *testing.T) {
	alice := testutils.TestAddress("d5w-alice")
	c, id := boardFixture(cur, "d5w", alice)
	cs := mustClaim(c, id)

	testing.SetRealm(testing.NewUserRealm(alice))
	row := PostComment(cross(cur), "d5w", id, 0, "[ref]: http://evil\n# heading")

	wire := BoardNewest("d5w", id, 0, 5)
	if !strings.Contains(wire, "[ref]: http://evil") {
		t.Fatal("the wire is raw by contract; it must not silently sanitise")
	}
	if !strings.Contains(wire, "\\n# heading") {
		t.Fatal("the wire must escape the row delimiter and nothing else")
	}
	// The page, from the same row, drops it.
	if strings.Contains(boardTextVisible(mustBoardRow(cs, row)), "http://evil") {
		t.Fatal("the page must drop what the wire carries")
	}
	// One row on the wire, whatever the text contained — the D2/D3 forgery rule.
	if strings.Count(strings.TrimRight(wire, "\n"), "\n") != 0 {
		t.Fatalf("the wire must stay one row:\n%s", wire)
	}
}

// AUDIT D6: at cold start every row shares a score, and only the row-id half of
// the index key keeps them apart.
//
// boardScoreKey is beInv(score) + beInv(rowID). Drop the id half and two rows
// with equal scores produce the SAME key, so the second Set overwrites the first
// and a row disappears from Top altogether. At cold start every score is 0, so
// the whole board collapses to a single entry — and nothing caught it, because
// every ranking test gave its rows distinct scores.
//
// This is also the mechanism behind "Top reads as Newest until something is
// upvoted": equal scores, descending row id.
func TestColdStartTopListsEveryRowNewestFirst(cur realm, t *testing.T) {
	alice := testutils.TestAddress("d6cs-alice")
	c, id := boardFixture(cur, "d6cs", alice)
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)
	r := getStanding(c, alice)
	r.score = sup * ladderFor(c).t3Bps / 10_000
	r.tokens = postsPerDayAt(ladderFor(c), 3)

	ids := []uint64{}
	for i := 0; i < 4; i++ {
		testing.SetRealm(testing.NewUserRealm(alice))
		ids = append(ids, PostComment(cross(cur), "d6cs", id, 0, "row "+strconv.Itoa(i)))
	}
	for _, row := range ids {
		if CommentScore("d6cs", id, row) != 0 {
			t.Fatal("the fixture must leave every score at zero")
		}
	}

	// EVERY row is in Top, not one. Four rows, four lines.
	top := strings.TrimRight(BoardTop("d6cs", id, 0, 64), "\n")
	lines := strings.Split(top, "\n")
	if len(lines) != len(ids) {
		t.Fatalf("cold-start Top lost rows to key collision: %d of %d\n%s",
			len(lines), len(ids), top)
	}
	// ...and newest first, which is what makes Top degenerate to Newest before
	// anything is upvoted rather than to an arbitrary order.
	for i, line := range lines {
		want := strconv.FormatUint(ids[len(ids)-1-i], 10) + "|"
		if !strings.HasPrefix(line, want) {
			t.Fatalf("cold-start Top is not newest-first at %d: %q", i, line)
		}
	}
	// The two orderings agree exactly while nothing is upvoted — the documented
	// degeneracy, asserted rather than described.
	newest := strings.TrimRight(BoardNewest("d6cs", id, 0, 64), "\n")
	if len(strings.Split(newest, "\n")) != len(ids) {
		t.Fatal("Newest must list every row too")
	}
}

// AUDIT D6: a caller cannot ask for an unbounded page.
//
// Both orderings clamp count to maxBoardRepliesShown*8. Nothing tested it: every
// existing read asks for 5 or 10. The clamp is what bounds the response a single
// query can demand, and offset/count arrive from a client.
func TestBothOrderingsClampThePageTheyWillServe(cur realm, t *testing.T) {
	alice := testutils.TestAddress("d6pg-alice")
	c, id := boardFixture(cur, "d6pg", alice)
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)
	r := getStanding(c, alice)
	r.score = sup * ladderFor(c).t3Bps / 10_000
	r.tokens = postsPerDayAt(ladderFor(c), 3)
	cs := mustClaim(c, id)

	// One more row than the clamp allows, inserted directly: this is about the
	// clamp, not about paying for 65 posts.
	ensureBoard(cs)
	limit := maxBoardRepliesShown * 8
	for i := 0; i < limit+1; i++ {
		cs.boardNextID++
		row := &boardRow{id: cs.boardNextID, author: alice, text: "r" + strconv.Itoa(i), at: 1}
		k := beClaimKey(row.id)
		cs.board.Set(k, row)
		cs.boardTop.Set(k, row)
		scoreIndexPut(cs, row)
	}

	for name, got := range map[string]string{
		"BoardNewest": BoardNewest("d6pg", id, 0, 100_000),
		"BoardTop":    BoardTop("d6pg", id, 0, 100_000),
	} {
		n := len(strings.Split(strings.TrimRight(got, "\n"), "\n"))
		if n > limit {
			t.Fatalf("%s served %d rows for one query; the clamp is %d", name, n, limit)
		}
		if n != limit {
			t.Fatalf("%s served %d, expected the clamp to bind at %d", name, n, limit)
		}
	}
	// A hostile offset is answered, not panicked on: bptree clamps a negative
	// offset itself and returns nothing past the end.
	if BoardNewest("d6pg", id, -5, 10) == "" {
		t.Fatal("a negative offset must read as the start, not as empty")
	}
	if BoardTop("d6pg", id, 1_000_000, 10) != "" {
		t.Fatal("an offset past the end must be empty, not wrapped")
	}
}

// AUDIT D7: the wire contract, which three reads publish and nothing pinned.
//
// No test split a row on "|" or counted a field. Add a column, reorder two, or
// change the mark alphabet and every client breaks with the suite still green —
// and these are the reads a client has no alternative to, since Render() cannot
// know who is asking.
//
// The contract, stated once here so it is testable rather than inferred:
//
//	BoardNewest   id | author | replyCount | mark | at | text   (6 fields)
//	BoardTop      id | author | score      | mark | at | text   (6 fields)
//	BoardReplies  id | author | mark       | at   | text        (5 fields)
//
// `at` is the block height the row landed. It sits BEFORE the text so text stays
// last; it was added because no exported read carried it, leaving a client able
// to order by recency and unable to date a single row.
//
// TEXT IS ALWAYS LAST and MARK ALWAYS SECOND-TO-LAST. That ordering is what lets
// text carry a pipe unescaped: a bounded split (SplitN with the field count)
// recovers it whole, while a naive Split would over-count. The mark alphabet is
// exactly ". h g x", from boardMark.
func TestTheWireContractIsFixed(cur realm, t *testing.T) {
	alice := testutils.TestAddress("d7w-alice")
	bob := testutils.TestAddress("d7w-bob")
	c, id := boardFixture(cur, "d7w", alice)
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)
	for _, w := range []address{alice, bob} {
		c.coin.Mint(w, 20_000_000_000)
		r := getStanding(c, w)
		r.score = sup * ladderFor(c).t3Bps / 10_000
		r.tokens = postsPerDayAt(ladderFor(c), 3)
	}

	// A comment whose text CONTAINS PIPES, which is the case the ordering exists
	// for and which no test had ever produced.
	testing.SetRealm(testing.NewUserRealm(alice))
	top := PostComment(cross(cur), "d7w", id, 0, "a|b|c pipes in the text")
	testing.SetRealm(testing.NewUserRealm(bob))
	reply := PostComment(cross(cur), "d7w", id, top, "a reply|with|pipes")

	// --- BoardNewest: five fields, text last, and the pipes survive whole.
	line := strings.Split(strings.TrimRight(BoardNewest("d7w", id, 0, 5), "\n"), "\n")[0]
	f := strings.SplitN(line, "|", 6)
	if len(f) != 6 {
		t.Fatalf("BoardNewest must publish 6 fields, got %d: %q", len(f), line)
	}
	if f[0] != strconv.FormatUint(top, 10) || f[1] != alice.String() {
		t.Fatalf("BoardNewest field order changed: %q", line)
	}
	if f[2] != "1" {
		t.Fatalf("BoardNewest field 3 is the reply count: %q", line)
	}
	if f[3] != "." {
		t.Fatalf("BoardNewest field 4 is the mark: %q", line)
	}
	// The height is a real number, not an empty field nobody filled: a row cannot
	// have landed at block 0, so this fails if `at` is ever packed unset.
	if n, err := strconv.ParseInt(f[4], 10, 64); err != nil || n <= 0 {
		t.Fatalf("BoardNewest field 5 is the block height: %q", line)
	}
	if f[5] != "a|b|c pipes in the text" {
		t.Fatalf("a bounded split must recover text containing pipes: %q", f[5])
	}

	// A REAL SCORE FIRST. Asserting field 3 while every score is 0 proves nothing:
	// a mutant that hardcodes "0" reads identically. bob upvotes alice's row.
	testing.SetRealm(testing.NewUserRealm(bob))
	UpvoteComment(cross(cur), "d7w", id, top)
	if CommentScore("d7w", id, top) == 0 {
		t.Fatal("the fixture must produce a non-zero score before asserting on it")
	}

	// --- BoardTop: same six, with the score where the reply count was.
	tl := strings.Split(strings.TrimRight(BoardTop("d7w", id, 0, 5), "\n"), "\n")[0]
	tf := strings.SplitN(tl, "|", 6)
	if len(tf) != 6 || tf[0] != strconv.FormatUint(top, 10) || tf[3] != "." {
		t.Fatalf("BoardTop contract changed: %q", tl)
	}
	if tf[2] != strconv.FormatInt(CommentScore("d7w", id, top), 10) {
		t.Fatalf("BoardTop field 3 must be the score the ordering uses: %q", tl)
	}
	// Split at 5 rather than 6 and field 5 reads "at|text": the length check and
	// the mark check both still pass, and the height goes unasserted on this
	// ordering while looking asserted on the other two.
	if n, err := strconv.ParseInt(tf[4], 10, 64); err != nil || n <= 0 {
		t.Fatalf("BoardTop field 5 is the block height: %q", tl)
	}
	if tf[5] != "a|b|c pipes in the text" {
		t.Fatalf("BoardTop must recover text containing pipes too: %q", tf[5])
	}

	// --- BoardReplies: five fields, mark third, height fourth, text last.
	rl := strings.Split(strings.TrimRight(BoardReplies("d7w", id, top), "\n"), "\n")[0]
	rf := strings.SplitN(rl, "|", 5)
	if len(rf) != 5 || rf[0] != strconv.FormatUint(reply, 10) || rf[1] != bob.String() {
		t.Fatalf("BoardReplies contract changed: %q", rl)
	}
	// A reply carries no reply count, so its mark sits one field left of where
	// BoardNewest puts one — and `at` sits between the mark and the text here too.
	if n, err := strconv.ParseInt(rf[3], 10, 64); err != nil || n <= 0 {
		t.Fatalf("BoardReplies field 4 is the block height: %q", rl)
	}
	if rf[2] != "." || rf[4] != "a reply|with|pipes" {
		t.Fatalf("BoardReplies mark/text positions changed: %q", rl)
	}

	// --- CommentsWrittenBy, the read a client shows as "N of 8", untested until
	// now. alice wrote one row, bob wrote one reply.
	if got := CommentsWrittenBy("d7w", id, alice); got != 1 {
		t.Fatalf("CommentsWrittenBy(alice) = %d, want 1", got)
	}
	if got := CommentsWrittenBy("d7w", id, bob); got != 1 {
		t.Fatalf("CommentsWrittenBy(bob) = %d, want 1", got)
	}
	if got := CommentsWrittenBy("d7w", id, testutils.TestAddress("d7w-nobody")); got != 0 {
		t.Fatalf("CommentsWrittenBy(a stranger) = %d, want 0", got)
	}

	// --- A WITHHELD REPLY keeps BoardReplies at four fields too. The reply wire
	// is a separate writer from the two orderings and drifts on its own.
	testing.SetRealm(testing.NewUserRealm(bob))
	HideOwnComment(cross(cur), "d7w", id, reply, true)
	hr := strings.SplitN(strings.Split(strings.TrimRight(BoardReplies("d7w", id, top), "\n"), "\n")[0], "|", 5)
	if len(hr) != 5 || hr[2] != "h" || hr[4] != "" {
		t.Fatalf("a withheld reply must keep 5 fields with an empty text field: %q", hr)
	}
	testing.SetRealm(testing.NewUserRealm(bob))
	HideOwnComment(cross(cur), "d7w", id, reply, false)

	// --- THE MARK ALPHABET, every state, in the same position, with the text
	// field present but empty so the field count never moves.
	testing.SetRealm(testing.NewUserRealm(alice))
	HideOwnComment(cross(cur), "d7w", id, top, true)
	if f := strings.SplitN(strings.Split(BoardNewest("d7w", id, 0, 5), "\n")[0], "|", 6); f[3] != "h" || f[5] != "" {
		t.Fatalf("a hidden row must read mark h with empty text: %q", f)
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	HideOwnComment(cross(cur), "d7w", id, top, false)

	dadmin := ensureGlobalDAO().admin
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalHideRow(cross(cur), "d7w", id, top, "dmca")
	if f := strings.SplitN(strings.Split(BoardNewest("d7w", id, 0, 5), "\n")[0], "|", 6); f[3] != "g" || f[5] != "" {
		t.Fatalf("a redacted row must read mark g with empty text: %q", f)
	}
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalClearRow(cross(cur), "d7w", id, top)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeBoardRow(cross(cur), "d7w", id, top, "csam")
	if f := strings.SplitN(strings.Split(BoardNewest("d7w", id, 0, 5), "\n")[0], "|", 6); f[3] != "x" || f[5] != "" {
		t.Fatalf("a purged row must read mark x with empty text: %q", f)
	}
	// And BoardRowState agrees with the wire, which is the whole point of it.
	if BoardRowState("d7w", id, top) != "x" {
		t.Fatal("BoardRowState must agree with the mark on the wire")
	}
}

// AUDIT D8: the badges, which tell a reader who has money on the question — and
// which nothing tested.
//
// boardBadges' own note says the ordering deliberately does not rank by stake:
// "the reader is told who has money on the question and decides for themselves."
// All five of its behaviours were deletable with the suite green, so a wrong or
// missing badge mis-attributed stake on a page people bet on and nothing noticed.
func TestTheBadgesNameWhoHasMoneyOnTheQuestion(cur realm, t *testing.T) {
	c, id, author, yesStaker, noStaker := topFixture(cur, t, "d8b")
	cs := mustClaim(c, id)
	answerer := testutils.TestAddress("d8b-answerer")
	c.coin.Mint(answerer, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(answerer))
	BuyCommentPass(cross(cur), "d8b")

	// Real positions on both sides, so the SIDE and the AMOUNT are both
	// distinguishable — a badge that named only one would read the same as a
	// badge that named the wrong one.
	testing.SetRealm(testing.NewUserRealm(yesStaker))
	Stake(cross(cur), "d8b", id, sideYES, 3_000_000)
	testing.SetRealm(testing.NewUserRealm(noStaker))
	Stake(cross(cur), "d8b", id, sideNO, 7_000_000)

	// Everyone comments, so every badge has a row to sit on.
	for _, w := range []address{author, yesStaker, noStaker, answerer} {
		testing.SetRealm(testing.NewUserRealm(w))
		PostComment(cross(cur), "d8b", id, 0, "a remark from "+w.String())
	}

	page := renderBoardPage("d8b", id)
	if !strings.Contains(page, "· author") {
		t.Fatalf("the claim's author must be badged:\n%s", page)
	}
	if !strings.Contains(page, "· YES 3000000") {
		t.Fatalf("a YES position must name its side AND amount:\n%s", page)
	}
	if !strings.Contains(page, "· NO 7000000") {
		t.Fatalf("a NO position must name its side AND amount:\n%s", page)
	}
	// The ANSWERER badge is withheld until the claim is FROZEN — before that
	// there is no answer of record to attribute.
	//
	// The answerer is set here and the freeze is NOT: asserting the badge's
	// absence while cs.answerer is still empty proves nothing, because `who ==
	// cs.answerer` is false for everyone either way and a mutant that drops the
	// frozenAt half reads identically. The state has to be "answerer known,
	// claim not yet frozen" for the guard to be observable at all.
	cs.answerer = answerer
	if strings.Contains(renderBoardPage("d8b", id), "· answerer") {
		t.Fatal("the answerer badge must wait for the claim to freeze")
	}
	_ = page

	// A ZERO position earns no badge: an address that staked and fully unstaked
	// still has a stakePos row, and badging it would report money that is not
	// there. Done BEFORE the freeze, because stakes cannot be withdrawn after it.
	testing.SetRealm(testing.NewUserRealm(yesStaker))
	Unstake(cross(cur), "d8b", id, sideYES, 3_000_000)
	after := renderBoardPage("d8b", id)
	if strings.Contains(after, "· YES 0") || strings.Contains(after, "· YES 3000000") {
		t.Fatalf("a closed position must earn no badge:\n%s", after)
	}
	if !strings.Contains(after, "· NO 7000000") {
		t.Fatal("the other side's live position must survive the check")
	}

	// And the answerer badge appears once the claim freezes.
	cs.frozenAt = heightNow()
	if !strings.Contains(renderBoardPage("d8b", id), "· answerer") {
		t.Fatal("once frozen, the answerer must be badged")
	}
}

// AUDIT D8: the page's own counts and its copy, none of which was held.
func TestTheBoardPagesCountsAndCopyAreHeld(cur realm, t *testing.T) {
	alice := testutils.TestAddress("d8p-alice")
	c, id := boardFixture(cur, "d8p", alice)
	cs := mustClaim(c, id)
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)
	r := getStanding(c, alice)
	r.score = sup * ladderFor(c).t3Bps / 10_000
	r.tokens = postsPerDayAt(ladderFor(c), 3)

	// The invitation line: a reader has to be told who may write here, and it was
	// deletable.
	if !strings.Contains(renderBoardPage("d8p", id), "Anyone with standing in this court") {
		t.Fatal("the page must say who may comment")
	}
	// The ranked view says so when nothing is upvoted, and points at the fuller
	// view rather than looking empty.
	if !strings.Contains(renderBoardTop("d8p", id), "No comments yet") {
		t.Fatal("an empty ranked view must say so")
	}

	// MORE ROWS THAN ONE PAGE, inserted directly: this is about the tail count.
	ensureBoard(cs)
	shown := maxBoardRepliesShown * 3
	for i := 0; i < shown+5; i++ {
		cs.boardNextID++
		row := &boardRow{id: cs.boardNextID, author: alice, text: "r" + strconv.Itoa(i), at: 1}
		k := beClaimKey(row.id)
		cs.board.Set(k, row)
		cs.boardTop.Set(k, row)
		scoreIndexPut(cs, row)
	}
	page := renderBoardPage("d8p", id)
	// The parties block holds one of them, so the tail is total - shown - parties.
	if !strings.Contains(page, "older comments") {
		t.Fatalf("a truncated page must say how many rows it is not showing:\n%s", page)
	}
	if strings.Contains(page, "_0 older comments._") {
		t.Fatal("the tail count must be the real remainder, not zero")
	}
	// "Nothing ELSE upvoted yet" fires when every indexed row is already held by
	// a reserved slot — which is a one-row board authored by the claim's author,
	// not a big cold-start board. At cold start every row sits in the index at
	// score 0 and the ranked view lists them all (D6), so the line correctly does
	// NOT appear above; asserting it there was my error, not the page's.
	solo := testutils.TestAddress("d8p-solo")
	c2, id2 := boardFixture(cur, "d8p2", solo)
	testing.SetRealm(testing.NewUserRealm(solo))
	PostComment(cross(cur), "d8p2", id2, 0, "the only row, by the claim's author")
	top2 := renderBoardTop("d8p2", id2)
	if !strings.Contains(top2, "The parties") {
		t.Fatalf("the author's row must fill the reserved slot:\n%s", top2)
	}
	if !strings.Contains(top2, "Nothing else upvoted yet") {
		t.Fatalf("with nothing beyond the slots, the ranked view must say so:\n%s", top2)
	}
	_ = c2

	// A non-numeric comment id is refused AS THAT, not as a missing comment — the
	// two are different facts and a client shows different things for them.
	if !strings.Contains(renderBoardRow("d8p", id, "not-a-number"), "must be a number") {
		t.Fatal("a malformed comment id must be named as malformed")
	}
	if !strings.Contains(renderBoardRow("d8p", id, "99999"), "No comment by that id") {
		t.Fatal("a missing comment must be named as missing")
	}
}

// The count under the link is what the reader will find behind it.
//
// It counted cs.boardTop — the pagination index, which holds only rows with no
// parent — so a board with two threads and two replies advertised "2 comments"
// and then showed four things. BoardSize, the read a client uses, has always
// returned every row: the realm was telling a page and an API different numbers
// about the same board.
func TestTheCommentCountOnAClaimCountsReplies(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cc1-alice")
	bob := testutils.TestAddress("cc1-bob")
	c, id := boardFixture(cur, "cc1", alice)
	path := "cc1/" + strconv.FormatUint(id, 10)

	// With nothing on it, the claim invites rather than counting.
	if !strings.Contains(Render(path), "no comments yet") {
		t.Fatal("an empty board must invite, not print a zero")
	}

	testing.SetRealm(testing.NewUserRealm(alice))
	top := PostComment(cross(cur), "cc1", id, 0, "the objection")
	if !strings.Contains(Render(path), "[1 comment]") {
		t.Fatal("one comment reads singular")
	}

	// A REPLY IS A COMMENT. Written by a person, charged against their daily
	// allowance, hideable, upvotable and purgeable like any other row — and a
	// line on the page the reader is about to open.
	c.coin.Mint(bob, 10_000_000_000) // a pass is burned coin; bob starts with none
	testing.SetRealm(testing.NewUserRealm(bob))
	BuyCommentPass(cross(cur), "cc1")
	testing.SetRealm(testing.NewUserRealm(bob))
	PostComment(cross(cur), "cc1", id, top, "the answer to it")

	page := Render(path)
	if !strings.Contains(page, "[2 comments]") {
		t.Fatal("a reply must be counted; the page said otherwise")
	}
	// The page and the API agree, which is the invariant rather than the
	// literal 2 — a test that only checked the literal would pass again the
	// day one of them drifted.
	if !strings.Contains(page, "["+strconv.Itoa(BoardSize("cc1", id))+" comments]") {
		t.Fatal("the rendered count must equal BoardSize")
	}
}

// A shared comment link arrives with the thing it is arguing about.
//
// This page opened "# Comment 1" over "← the board" and said nothing else — not
// which claim, not which court. A single row is the most-shared unit in the
// realm, so a reader arriving cold is the ordinary case rather than the edge
// one, and they got an opinion with no proposition attached.
func TestASharedCommentCarriesItsClaimAndCourt(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sc1-alice")
	c, id := boardFixture(cur, "sc1", alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	row := PostComment(cross(cur), "sc1", id, 0, "the objection worth sharing")

	page := Render("sc1/" + strconv.FormatUint(id, 10) + "/board/" +
		strconv.FormatUint(row, 10))

	// THE CLAIM IS THE HEADING. The comment number is an ordinal and belongs in
	// the subtitle; the proposition is what the page is about.
	cs := mustClaim(c, id)
	if !strings.HasPrefix(page, "# "+claimTitleFor(c, cs)) {
		t.Fatal("a shared comment must be headed by the claim it argues about")
	}
	if !strings.Contains(page, "Comment "+strconv.FormatUint(row, 10)+" on this claim") {
		t.Fatal("the page must still say which comment it is")
	}
	// AND WHICH COURT, linked. A claim title alone does not say whose docket it
	// is on, and standing, coin and moderators are all per-court.
	if !strings.Contains(page, "["+courtNameFor(c)+"](/r/kourt/kourtv2:sc1)") {
		t.Fatal("a shared comment must name and link its court")
	}
	// Both ways out: to the claim, and to the rest of the argument.
	base := "/r/kourt/kourtv2:sc1/" + strconv.FormatUint(id, 10)
	if !strings.Contains(page, "[← the claim]("+base+")") {
		t.Fatal("a shared comment must link the claim, not only the board")
	}
	if !strings.Contains(page, "comments]("+base+"/board)") {
		t.Fatal("a shared comment must offer the rest of the board")
	}
	// The comment itself is still there — this is context added, not replaced.
	if !strings.Contains(page, "the objection worth sharing") {
		t.Fatal("the comment must still render")
	}
}

// The moderation log says what it actually covers.
//
// It opened "Every moderation act on this court is recorded here", and eleven
// acts — the ten folder verbs and court-desc — emit a ModAct event and never
// call appendLog. A court with three folders and five filings read "No
// moderation acts yet" directly underneath the promise. docs/CLAIM_BOARDS.md
// §19 records the alternative (log the curation) as a ruling.
func TestTheModLogSaysWhatItCovers(cur realm, t *testing.T) {
	mod := testutils.TestAddress("ml1-mod")
	poster := testutils.TestAddress("ml1-poster")
	modFixture(cur, "ml1", mod, poster)
	testing.SetRealm(testing.NewUserRealm(mod))
	CreateFolder(cross(cur), "ml1", "A heading", "")

	page := Render("ml1/mod")
	// The curation happened and is genuinely absent, which is the fact the
	// sentence has to match rather than contradict.
	if !strings.Contains(page, "No moderation acts yet") {
		t.Fatal("the fixture must leave the log empty, or this asserts nothing")
	}
	if strings.Contains(page, "Every moderation act on this court is recorded here") {
		t.Fatal("the log must not claim to hold acts it does not hold")
	}
	if !strings.Contains(page, "CLAIMS and COMMENTS") {
		t.Fatal("the log must say which acts it covers")
	}
	// AND WHERE THE MISSING ONES ARE. Telling a reader something is absent
	// without saying where to look leaves them worse off than the false promise.
	if !strings.Contains(page, "Curation") || !strings.Contains(page, "event stream") {
		t.Fatal("the log must say where curation is visible instead")
	}
	if !strings.Contains(page, "[court page](/r/kourt/kourtv2:ml1)") {
		t.Fatal("the log must link the court page, where the tree renders")
	}
}
