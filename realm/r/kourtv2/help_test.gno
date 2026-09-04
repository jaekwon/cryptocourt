package kourtv2

import (
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// The help page is reachable, and reachable from the pages a stranger actually
// lands on — which is the whole difference between a help page and a file.
func TestTheHelpPageIsReachableFromWhereStrangersLand(cur realm, t *testing.T) {
	alice := testutils.TestAddress("hp1-alice")
	c, id := boardFixture(cur, "hp1", alice)
	_ = c
	sid := strconv.FormatUint(id, 10)

	page := Render(helpPath)
	if !strings.Contains(page, "# How Kourt works") {
		t.Fatal("the help route must render the help page")
	}
	// The load-bearing surprise has to be IN it. A help page that omits the one
	// thing a reader's prior model gets wrong is decoration.
	for _, must := range []string{
		"cannot lose your stake",
		"1×",
		"A court is a subject",
		"Comments are where the argument is",
		"entry pass",
		"moderation log",
	} {
		if !strings.Contains(page, must) {
			t.Fatal("the help page must explain: " + must)
		}
	}

	// LINKED FROM EVERY COLD ENTRY POINT. Each of these is somewhere a reader
	// can arrive without having seen any other page.
	for _, from := range []string{
		"",                  // the directory — the front door
		"hp1",               // a court — reached from a court list anywhere
		"hp1/" + sid + "/board", // a comment board — every comment is a deep link
	} {
		if !strings.Contains(Render(from), "/r/kourt/kourtv2:"+helpPath) {
			t.Fatalf("no way to reach help from %q", from)
		}
	}
}

// The route cannot be taken by a court, and does not take a court's route.
func TestTheHelpRouteCannotCollideWithACourt(cur realm, t *testing.T) {
	// It is longer than any slug may be, so the sets are disjoint by
	// construction — this is the property the carve relies on, asserted rather
	// than assumed.
	if len(helpPath) <= maxSlugLen {
		t.Fatal("the help path must be too long to be a slug, or a court can shadow it")
	}
	mod := testutils.TestAddress("hp2-mod")
	testing.SetRealm(testing.NewUserRealm(mod))
	uassert.AbortsContains(t, cur, "a slug is 1..11 characters", func() {
		StartCourt(cross(cur), helpPath, "Impostor")
	})

	// And the carve did not eat an ordinary court: a real slug still renders its
	// court, not the help page.
	testing.SetRealm(testing.NewUserRealm(mod))
	StartCourt(cross(cur), "hp2", "Ordinary Court")
	got := Render("hp2")
	if strings.Contains(got, "How Kourt works\n") && !strings.Contains(got, "# Ordinary Court") {
		t.Fatal("the help carve swallowed a court")
	}
	if !strings.Contains(got, "# Ordinary Court") {
		t.Fatal("an ordinary slug must still render its court")
	}
}

// The claims come before the accounting, and the accounting is still all there.
func TestACourtLeadsWithItsClaimsNotItsPlumbing(cur realm, t *testing.T) {
	alice := testutils.TestAddress("hp3-alice")
	c, _ := boardFixture(cur, "hp3", alice)
	_ = c
	page := Render("hp3")

	claims := strings.Index(page, "## Claims")
	coin := strings.Index(page, "## This court's coin")
	if claims < 0 || coin < 0 {
		t.Fatal("a court page needs both its claims and its coin")
	}
	if claims > coin {
		t.Fatal("the claims must come before the coin accounting, not after it")
	}
	// NOTHING WAS DROPPED IN THE MOVE. Every figure that was above the claims is
	// still on the page — this is a reordering, not a deletion.
	for _, must := range []string{
		"ugnot per coin", "in circulation:", "paid out as rewards so far:",
		"reward reservoir:", "already owed to earlier earners",
	} {
		if !strings.Contains(page, must) {
			t.Fatal("the move lost a figure: " + must)
		}
	}
	// Each house term is glossed where it is printed, not in a legend elsewhere.
	for _, gloss := range []string{"waiting to be earned", "there is no sell side"} {
		if !strings.Contains(page, gloss) {
			t.Fatal("an unglossed house term: " + gloss)
		}
	}
}

// A court with no claims still shows its coin — somebody deciding whether to be
// early is exactly who wants the price.
func TestAnEmptyCourtStillShowsItsCoin(cur realm, t *testing.T) {
	mod := testutils.TestAddress("hp4-mod")
	testing.SetRealm(testing.NewUserRealm(mod))
	StartCourt(cross(cur), "hp4", "Empty Court")
	page := Render("hp4")
	if !strings.Contains(page, "_No claims yet._") {
		t.Fatal("an empty court says so")
	}
	if !strings.Contains(page, "## This court's coin") {
		t.Fatal("an empty court must still show its coin and price")
	}
}

// The two "put your address on the end of the path" hints give the WHOLE path.
//
// Both elided the court slug — "…/9/<your-address>" and "covid/me/<address>" —
// which is precisely the half a reader cannot supply from the page they are on.
// A hint that assumes the convention it is explaining is not a hint.
func TestThePathHintsAreCompleteEnoughToFollow(cur realm, t *testing.T) {
	mod := testutils.TestAddress("hp5-mod")
	poster := testutils.TestAddress("hp5-poster")
	modFixture(cur, "hp5", mod, poster)
	testing.SetRealm(testing.NewUserRealm(poster))
	cid := OpenClaim(cross(cur), "hp5", "A claim to have a position on.")

	claim := Render("hp5/" + strconv.FormatUint(cid, 10))
	want := "/r/kourt/kourtv2:hp5/" + strconv.FormatUint(cid, 10) + "/<your address>"
	if !strings.Contains(claim, want) {
		t.Fatal("the claim page must give the positions path in full")
	}
	if strings.Contains(claim, "…/") {
		t.Fatal("a path hint must not elide the part a reader cannot supply")
	}

	me := Render("hp5/me")
	if !strings.Contains(me, "/r/kourt/kourtv2:hp5/me/<address>") {
		t.Fatal("the standing index must give its path in full")
	}
	// AND IT DEFINES ITS OWN JARGON. The three thresholds below it are quoted in
	// bps and are meaningless without it.
	if !strings.Contains(me, "hundredth of a percent") {
		t.Fatal("a page that quotes bps must say what a bp is")
	}
}

// Every price a reader is invited to pay names its unit.
//
// The pass price printed as a bare "190585" in all three places it appears. Each
// court's coin is its own and interchangeable with nothing — which is the whole
// design, stated on the court page and in the help page — so a bare number on
// the one action a new reader is being invited to take is the last place a unit
// can be left to inference. A reader cannot tell 190585 ugnot from 190585 of a
// coin they have never heard of.
func TestEveryPriceNamesItsUnit(cur realm, t *testing.T) {
	mod := testutils.TestAddress("hp6-mod")
	stranger := testutils.TestAddress("hp6-stranger")
	modFixture(cur, "hp6", mod, testutils.TestAddress("hp6-poster"))
	c := mustCourt("hp6")
	unit := qualifiedSymbol(c)
	price := strconv.FormatInt(passPriceFor(c), 10)

	// A stranger at level zero: the invitation they are shown.
	page := Render("hp6/me/" + stranger.String())
	if !strings.Contains(page, "You cannot comment here yet") {
		t.Fatal("a stranger must be told they cannot comment yet")
	}
	if !strings.Contains(page, price+" "+unit) {
		t.Fatal("the pass price on the standing page must name its unit")
	}
	// And the index, which quotes the same price to somebody who has not even
	// given an address.
	if !strings.Contains(Render("hp6/me"), price+" "+unit) {
		t.Fatal("the standing index's pass price must name its unit")
	}
	// The unit is this court's own coin, not a generic one — the distinction the
	// realm exists to keep.
	if !strings.Contains(unit, "HP6") {
		t.Fatal("the unit must be the court's own symbol")
	}
	// THE "NEVER EARNED" LINE, whose whole job is to let a reader check things
	// off a list — which they cannot do for a coin the page never names. It went
	// untested and a mutant reverting it to a bare "CC" survived.
	if !strings.Contains(page, "buying "+unit+", or buying the pass") {
		t.Fatal("the never-earned list must name the coin it says does not count")
	}
	if strings.Contains(page, "buying CC") {
		t.Fatal("the standing page must not quote a generic CC")
	}
}

// The SLASHED user's page names its unit too — a different branch, and the one
// where getting it wrong costs the most.
//
// A stranger and a slashed user are offered the pass by two different sentences,
// and only the stranger's was covered: the mutant that stripped the unit from
// the slashed line survived. This person has already burned a pass once and had
// it taken, so "buy a new pass for 190585" is a price they are being asked to
// pay a second time with no unit on it.
func TestASlashedUserIsQuotedTheUnitToo(cur realm, t *testing.T) {
	mod := testutils.TestAddress("hp7-mod")
	poster := testutils.TestAddress("hp7-poster")
	modFixture(cur, "hp7", mod, poster)
	c := mustCourt("hp7")

	// Up to the top rung, then all the way down — so highWater exceeds score,
	// which is what selects the slashed sentence.
	r := getStanding(c, poster)
	r.score = levelFloor(c, 3) * 2
	r.highWater = r.score
	testing.SetRealm(testing.NewUserRealm(mod))
	SlashStanding(cross(cur), "hp7", poster, 3, boardCodeAbuse)
	if postLevel(c, poster) != 0 {
		t.Fatal("the fixture must leave the poster at level 0")
	}
	if r.highWater <= r.score {
		t.Fatal("the fixture must leave highWater above score, or the slashed " +
			"sentence is not the one that renders")
	}

	page := Render("hp7/me/" + poster.String())
	if !strings.Contains(page, "A moderator slash took your standing to zero") {
		t.Fatal("a slashed user must be told a slash is why")
	}
	if !strings.Contains(page, "buy a new pass for "+
		strconv.FormatInt(passPriceFor(c), 10)+" "+qualifiedSymbol(c)) {
		t.Fatal("the slashed user's pass price must name its unit")
	}
	// And this is NOT the stranger's sentence — the two branches are distinct,
	// so a test that matched either would pass against the wrong one.
	if strings.Contains(page, "You cannot comment here yet") {
		t.Fatal("a slashed user must not read as somebody who never had standing")
	}
}

// The help page names the RIGHT currency, and does not repeat the log's
// false universal.
//
// An earlier draft said "Stake GNOT on YES or NO". Staking is in the court's own
// coin — stake.gno: "Stake backs one side of a claim with CC" — and this is the
// worst sentence on the surface to get wrong: a reader who believes they are
// staking GNOT has the model upside down before paragraph two, and every later
// sentence about 1× and about earning reads against the wrong asset.
func TestTheHelpPageNamesTheRightCurrency(cur realm, t *testing.T) {
	page := Render(helpPath)

	// GNOT APPEARS EXACTLY WHERE IT BELONGS — buying the coin — and nowhere near
	// staking.
	if strings.Contains(page, "Stake GNOT") {
		t.Fatal("staking is in the court's coin, not GNOT")
	}
	if !strings.Contains(page, "GNOT buys a court's coin") {
		t.Fatal("the page must say what GNOT is actually for")
	}
	if !strings.Contains(page, "that coin is what you stake") {
		t.Fatal("the page must say what is staked, before it says what staking does")
	}
	if !strings.Contains(page, "Stake the court's coin on YES or NO") {
		t.Fatal("the staking sentence must name the court's coin")
	}
	if !strings.Contains(page, "burns GNOT one way") {
		t.Fatal("the page must still say the purchase is one-way")
	}

	// COIN AND STANDING ARE DIFFERENT THINGS. The page ran them together as "the
	// court's coin … is what gives you a voice", which is the one claim the
	// design exists to falsify: a balance buys nothing but a single pass.
	if !strings.Contains(page, "separate thing") || !strings.Contains(page, "cannot buy") {
		t.Fatal("the page must distinguish standing from a coin balance")
	}
	if !strings.Contains(page, "not the coin you hold") {
		t.Fatal("the comments section must say standing is not a balance")
	}

	// AND IT MUST NOT REPEAT THE LOG'S FALSE UNIVERSAL (§19). Curation emits an
	// event and writes no row, so "every act is written to the log" is wrong
	// here too — and worse here, because this is the page read first, where no
	// empty list contradicts it.
	if strings.Contains(page, "Every act is written") {
		t.Fatal("the help page must not promise a log that holds every act")
	}
	if !strings.Contains(page, "What they do to a claim or a comment is written") {
		t.Fatal("the help page must scope the log the way the log itself does")
	}
}

// The claim page's own numbers say what they count.
//
// "staked now: 84000000" was the first figure on the first page most readers
// see, and nothing anywhere on it said what 84000000 was. It could have been
// ugnot, GNOT, or a coin they had never heard of — and the answer, the court's
// own coin, is the fact the whole design turns on. Asking that question about a
// rendered page is what surfaced the help page teaching the wrong currency
// (§20.1), so the gap was load-bearing twice over.
func TestTheClaimPageNumbersNameTheirCoin(cur realm, t *testing.T) {
	alice := testutils.TestAddress("hp8-alice")
	bob := testutils.TestAddress("hp8-bob")
	c, id := boardFixture(cur, "hp8", alice)
	unit := qualifiedSymbol(c)
	path := "hp8/" + strconv.FormatUint(id, 10)

	c.coin.Mint(bob, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "hp8", id, sideYES, 4_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "hp8", id, sideNO, 1_000_000)

	page := Render(path)
	if !strings.Contains(page, "- staked now: 5000000 "+unit+" (YES 4000000 / NO 1000000)") {
		t.Fatalf("the live stake line must name the court's coin:\n%s", page)
	}
	// NOT A GENERIC "CC". qualifiedSymbol exists because a bare symbol lets one
	// court's coin read as another's, or as the platform's.
	if strings.Contains(page, "CC units") {
		t.Fatal("a claim page must not quote a generic CC")
	}
	// And the unit is this court's, not some other court's.
	if !strings.Contains(unit, "HP8") {
		t.Fatal("the unit must be this court's own symbol")
	}

	// EVERY OTHER BRANCH OF THIS PAGE, because an open claim renders one of
	// them. Four mutants survived a version of this test that stopped above:
	// the answered figures, the unwithdrawn line, the flag bond and the reward
	// pools are all on paths a live open claim never takes, so stripping their
	// units cost nothing a test could see. The fields are set directly, the way
	// the claimStatus test drives the same lifecycle.
	cs := mustClaim(c, id)
	cs.frozenAt = 100
	cs.answer = int8(sideNO)
	cs.answerBond0 = 7000
	cs.yesStakeAtFreeze = 4_000_000
	cs.noStakeAtFreeze = 1_000_000
	// The size rating's two figures, so the ratio line renders and its coin
	// naming is actually checked. Without them the claim reads as one answered
	// before ratings existed, which is a real branch — it has its own test —
	// but not the one this fixture is for.
	cs.xBarFrozen, cs.tierRef = 5_000_000, 4_000_000
	answered := Render(path)
	for _, want := range []string{
		"- staked when answered: 5000000 " + unit + " (YES 4000000 / NO 1000000)",
		"- still unwithdrawn: 5000000 " + unit,
		"(bond 7000 " + unit + ")",
		"- disputing this answer costs a bond of ",
		// "anyone may challenge that rating once" is gone from this list on
		// purpose — the rating is the claim's own size now, frozen at the
		// answer, so the offer named a transaction that could not move the
		// number beside it. Its absence is asserted below.
		"- the rating is the money that showed up, not a vote",
	} {
		if !strings.Contains(answered, want) {
			t.Fatalf("an answered claim must render %q:\n%s", want, answered)
		}
	}
	if strings.Contains(answered, "challenge that rating") {
		t.Fatalf("the rating is set by size and cannot be challenged:\n%s", answered)
	}
	// BOTH SIDES OF THE RATIO NAME THE COIN, which is what this test exists for:
	// a ratio with one unlabelled side is half a number, and the reference was
	// rendering bare when this line was first written.
	if strings.Contains(answered, "against a typical") &&
		!strings.Contains(answered, unit+" here") {
		t.Fatalf("the reference figure must name the coin too:\n%s", answered)
	}
	// The two bond lines and the flag bond all name the coin.
	if strings.Count(answered, unit) < 5 {
		t.Fatalf("every figure on an answered claim names the coin:\n%s", answered)
	}
	if strings.Contains(answered, "CC units") {
		t.Fatal("an answered claim must not quote a generic CC")
	}

	// CRYSTALLIZED, which is a different branch again — and mutually exclusive
	// with the flag slot, since the switch takes only one arm.
	cs.crystallized = true
	cs.drawWinners, cs.drawAuthor, cs.drawAnswerer, cs.carrotPool = 11, 22, 33, 44
	done := Render(path)
	if !strings.Contains(done, "- rewards open — pools ("+unit+"): accuracy 11") {
		t.Fatalf("the reward pools must name the coin:\n%s", done)
	}
	if strings.Contains(done, "CC units") {
		t.Fatal("a crystallized claim must not quote a generic CC")
	}
}

// The help page's three endings are the ones claimStatus actually prints.
//
// The page says it quotes them "verbatim as the claim list prints them, so a
// reader who saw 'disputed' on a court page finds the same word here rather
// than a synonym they have to guess is the same thing" — and nothing tied the
// two, so they drifted the first time claimStatus changed. It learned to name
// the winning side ("settled YES — every stake withdraws 1×") and the help page
// went on saying "settled — answered", which is the exact failure the promise
// was about.
//
// Substring rather than equality, because claimStatus interpolates a side and a
// block height that a help page has no business quoting. What is pinned is that
// the phrase a reader carries away from here appears in what they will actually
// see.
func TestTheHelpPageQuotesTheRealStatusWords(cur realm, t *testing.T) {
	alice := testutils.TestAddress("hp9-alice")
	c, id := boardFixture(cur, "hp9", alice)
	cs := mustClaim(c, id)
	page := Render(helpPath)

	for _, tc := range []struct {
		name  string
		set   func()
		help  string
	}{
		{"settled", func() {
			cs.verdictAt, cs.provisional = 100, int8(sideYES)
		}, "every stake withdraws 1×"},
		{"disputed", func() {
			cs.verdictAt, cs.disputeOpen = 0, true
		}, "a sealed vote is deciding; principal is never withheld"},
		{"closed", func() {
			cs.disputeOpen, cs.closed = false, true
		}, "never answered; every stake exited 1×, the deposit refunded"},
	} {
		tc.set()
		real := claimStatus(cs)
		if !strings.Contains(page, tc.help) {
			t.Fatalf("the help page must list the %s ending", tc.name)
		}
		if !strings.Contains(real, tc.help) {
			t.Fatalf("the help page's %s wording is not what claimStatus prints:\n"+
				"  help: %q\n  real: %q", tc.name, tc.help, real)
		}
	}

	// And the side is named, since claimStatus names it and a reader deciding
	// whether to look wants to know a settled claim says which way it went.
	if !strings.Contains(page, "settled YES") || !strings.Contains(page, "settled NO") {
		t.Fatal("the help page must say a settled claim names its side")
	}
}

// UNRATED IS NOT LOW, and the difference is the difference between being paid
// and not.
//
// cs.tier is the ZERO VALUE — which is tierLowX — until a settle or a finalize
// writes mid, so every answered-but-unsettled claim rendered "quality: low".
// And the tier is a payout multiplier: crystallize computes tier × midGross,
// and low is 0. The page therefore told the answerer and every staker that the
// claim currently pays nothing, when its outcome absent a flag vote is mid.
// THE SAME HAZARD, ONE DESIGN LATER. The old failure was that cs.tier's zero
// value IS tierLowX, so every answered-but-unsettled claim rendered "quality:
// low" — telling the answerer and every staker the claim paid NOTHING when its
// actual outcome was mid, i.e. full pay.
//
// The tier is derived from size now and has no zero-value trap, but the shape
// recurs one step earlier: BEFORE the answer, xBarFrozen is unset, so a
// multiplier printed then would be the 0.25x floor — the page would again tell
// a staker their claim pays a quarter when nothing has been decided at all.
// This is that case, and the two assertions after it are the ones the old test
// carried: say what sets the number, and never sell a challenge that cannot
// move it.
func TestAnUnansweredClaimIsNotReportedAtTheFloor(cur realm, t *testing.T) {
	alice := testutils.TestAddress("hp10-alice")
	c, id := boardFixture(cur, "hp10", alice)
	cs := mustClaim(c, id)
	path := "hp10/" + strconv.FormatUint(id, 10)

	if cs.frozenAt != 0 {
		t.Fatal("the fixture must be unanswered")
	}
	page := Render(path)
	if strings.Contains(page, "0.25×") {
		t.Fatalf("an unanswered claim must not be reported at the floor:\n%s", page)
	}
	if !strings.Contains(page, "not set until the claim is answered") {
		t.Fatalf("an unanswered claim must say the rating is not set yet:\n%s", page)
	}

	// ANSWERED: the number appears, with the two figures it is a ratio of. A
	// multiplier without its reference cannot be checked against anything.
	cs.frozenAt, cs.answer = 100, int8(sideYES)
	cs.xBarFrozen, cs.tierRef = 3_000_000, 2_000_000
	rated := Render(path)
	if !strings.Contains(rated, "pays 1.50×") {
		t.Fatalf("an answered claim reports its multiplier:\n%s", rated)
	}
	if !strings.Contains(rated, "3000000") || !strings.Contains(rated, "2000000") {
		t.Fatalf("the page shows the claim's size and the court's typical:\n%s", rated)
	}
	// WHAT THE RATING IS FOR, and where it comes from. Without this it reads as
	// an editorial opinion of the claim rather than as what it pays.
	if !strings.Contains(rated, "the money that showed up, not a vote") {
		t.Fatal("the page must say what sets the rating")
	}
	// AND IT MUST NOT SELL A CHALLENGE. A flag can no longer move this number,
	// so offering one would be offering a transaction that cannot do what the
	// sentence next to it says.
	if strings.Contains(rated, "challenge that rating") {
		t.Fatalf("the rating is not challengeable any more:\n%s", rated)
	}
	// The clamps are named, so a reader can tell 2.00x from "the top".
	if !strings.Contains(rated, "capped at 0.25× and 2.00×") {
		t.Fatal("the page must name the clamps")
	}

	// A CLAIM ANSWERED BEFORE RATINGS EXISTED has no reference recorded. The
	// multiplier falls back to par, which is right — but the PAGE rendered the
	// ratio anyway and printed "held 0 against a typical 0", two figures that
	// are MISSING presented as if they were measurements. This is that branch.
	cs.xBarFrozen, cs.tierRef = 0, 0
	legacy := Render(path)
	if strings.Contains(legacy, "against a typical 0") {
		t.Fatalf("a missing reference must not render as a measured zero:\n%s", legacy)
	}
	if !strings.Contains(legacy, "answered before ratings were recorded") {
		t.Fatalf("the legacy case must say why it pays what it pays:\n%s", legacy)
	}
	if !strings.Contains(legacy, "pays 1.00×") {
		t.Fatalf("a claim with no reference pays par, not the floor:\n%s", legacy)
	}
}

// A delisted court is told it was delisted.
//
// A global DAO member may set a court to tierHidden, which removes it from the
// directory and from every listing read. A hidden CLAIM gets one of four
// banners naming the authority that hid it; a hidden COURT got nothing, so its
// creator and its holders watched it vanish from the front page with no page
// anywhere saying it had been an act rather than a fault.
func TestADelistedCourtSaysSo(cur realm, t *testing.T) {
	mod := testutils.TestAddress("hp11-mod")
	poster := testutils.TestAddress("hp11-poster")
	modFixture(cur, "hp11", mod, poster)
	c := mustCourt("hp11")

	// Listed: no banner, and it appears in the directory.
	if c.tier != tierListed {
		t.Fatal("a new court must start listed, or this test asserts nothing")
	}
	if strings.Contains(Render("hp11"), "Delisted") {
		t.Fatal("a listed court must carry no delisting banner")
	}
	if !inTier("hp11", tierListed) {
		t.Fatal("a listed court must be in the listed tier")
	}

	testing.SetRealm(testing.NewUserRealm(ensureGlobalDAO().admin))
	SetTier(cross(cur), "hp11", int(tierHidden))

	// GONE FROM EVERY LISTING, which is the fact that needs explaining.
	if inTier("hp11", tierListed) {
		t.Fatal("a delisted court must leave the listed tier")
	}
	page := Render("hp11")
	if !strings.Contains(page, "Delisted by the global DAO") {
		t.Fatalf("a delisted court must say who delisted it:\n%s", page)
	}
	// AND THAT NOTHING ELSE CHANGED. Without it a holder reads a delisting as a
	// freeze on their money, which it is not.
	if !strings.Contains(page, "still stake, answer, settle and pay out") {
		t.Fatal("the banner must say the lifecycle is unaffected")
	}
	// Still reachable, and still renders its claims — the banner is a
	// disclosure, not a tombstone.
	if !strings.Contains(page, "## Claims") {
		t.Fatal("a delisted court must still render normally below the banner")
	}
}

// inTier asks the listing index directly. Render("") is capped at
// renderPageSize, so asking the PAGE whether a court is listed answers a
// different question — one whose answer depends on how many courts the package
// happens to hold, which is why the first version of this test passed alone and
// failed in company.
func inTier(slug string, tier uint8) bool {
	for _, s := range ListByTier(int(tier)) {
		if s == slug {
			return true
		}
	}
	return false
}

// The two money-at-risk actions are explained before a reader meets them.
//
// Everything else on the help page is about a stake that cannot be lost, which
// is precisely what makes a bond dangerous to leave unexplained: a reader who
// has absorbed "you cannot lose your stake" will meet a bond and assume the
// same protection covers it. It does not, and the page now says so on both
// surfaces — here in general, and on the claim page with the live figure.
func TestTheHelpPageExplainsWhatCanActuallyBeLost(cur realm, t *testing.T) {
	page := Render(helpPath)
	for _, must := range []string{
		"Two things you can actually lose",
		"Challenging an answer",
		"Challenging a rating",
		// The doctrine, in words: nothing passes between adversaries.
		"a forfeit is destroyed, a compensation is newly issued",
		// And the reassurance that is actually true, stated as strongly as the
		// warning, because the asymmetry is the point.
		"**Your stake is never at risk in either.**",
	} {
		if !strings.Contains(page, must) {
			t.Fatalf("the help page must explain: %q", must)
		}
	}
}

// The claim page says what a dispute costs AND what it does.
//
// It quoted a price and stopped: a reader was told what a dispute costs and not
// what winning or losing does with the money. dispute.gno's own header carries
// the doctrine — forfeitures burn, compensation mints, nothing moves between
// adversaries — and none of it reached any surface.
func TestTheClaimPageSaysWhatADisputeDoesNotJustItsPrice(cur realm, t *testing.T) {
	alice := testutils.TestAddress("hp12-alice")
	c, id := boardFixture(cur, "hp12", alice)
	cs := mustClaim(c, id)
	cs.frozenAt, cs.answer, cs.answerBond0 = 100, int8(sideNO), 5000
	cs.xBarFrozen = 1_000_000 // so the bond quote is positive

	page := Render("hp12/" + strconv.FormatUint(id, 10))
	if !strings.Contains(page, "disputing this answer costs a bond of") {
		t.Fatalf("the price must still render:\n%s", page)
	}
	for _, must := range []string{
		"win and the answerer's bond is burned and you are compensated",
		"lose and yours burns instead",
		"a forfeit is burned, a compensation is newly issued",
		// The quorum-less path, which is neither a win nor a loss and costs half.
		"half your bond burns",
		"three such rounds close the claim undecided",
		// The sentence that decides whether a reader can weigh any of it.
		"**your stake is not at risk either way**",
	} {
		if !strings.Contains(page, must) {
			t.Fatalf("the dispute block must say %q:\n%s", must, page)
		}
	}
}

// THE PAGE REPORTS BOTH MULTIPLIERS, and names a discarded claim for what it is.
//
// A claim's draw is scaled twice — by its size, and by the deciding round's spam
// share — so a page showing only the first reports DOUBLE what a claim a quarter
// of the voters flagged actually pays. And a discarded claim carries provClose,
// so without its own status line it reads as "three rounds failed quorum": the
// same words for the opposite event, on the line a reader uses to judge whether
// the system worked.
func TestTheClaimPageShowsTheSpamCutAndNamesADiscard(cur realm, t *testing.T) {
	alice := testutils.TestAddress("spamcut-alice")
	c, id := boardFixture(cur, "spamcut", alice)
	cs := mustClaim(c, id)
	path := "spamcut/" + strconv.FormatUint(id, 10)

	// Answered and rated by size, with no round decided yet: one multiplier, and
	// no spam line at all — zero spam and "nobody voted" must not read alike.
	cs.frozenAt, cs.answer = 100, int8(sideYES)
	cs.xBarFrozen, cs.tierRef = 4_000_000, 2_000_000
	page := Render(path)
	if !strings.Contains(page, "pays 2.00×") {
		t.Fatalf("the size rating must show:\n%s", page)
	}
	if strings.Contains(page, "flagged it as spam") {
		t.Fatalf("no round has decided, so there is no spam share to report:\n%s", page)
	}

	// A round decided with a quarter of the weight flagging spam: the cut is
	// reported, with BOTH figures — a bare "0.50×" cannot tell a large claim the
	// crowd cut down from a small one nobody touched.
	cs.spamW, cs.spamTotalW = 25, 100
	cut := Render(path)
	if !strings.Contains(cut, "and 0.50× of that") {
		t.Fatalf("the spam cut must show beside the size rating:\n%s", cut)
	}
	if !strings.Contains(cut, "25 of 100 of the weight cast") {
		t.Fatalf("the cut must carry the share it came from:\n%s", cut)
	}
	// The size rating is still there — the two compose, and hiding either makes
	// the other unreadable.
	if !strings.Contains(cut, "pays 2.00×") {
		t.Fatal("the size rating must survive beside the cut")
	}

	// A round where nobody flagged spam reports no cut, rather than "1.00× of
	// that", which is noise dressed as information.
	cs.spamW = 0
	if clean := Render(path); strings.Contains(clean, "flagged it as spam") {
		t.Fatalf("a clean round has no cut to report:\n%s", clean)
	}

	// AND A DISCARD IS NAMED. Not "closed without a decision" — the court
	// decided, and decided the claim should not have been asked.
	cs.spamClosed, cs.provClose = true, true
	cs.verdictAt = heightNow()
	st := claimStatus(cs)
	if !strings.Contains(st, "discarded") || !strings.Contains(st, "called this claim spam") {
		t.Fatalf("a discarded claim must say so, got %q", st)
	}
	if strings.Contains(st, "failed quorum") {
		t.Fatalf("a discard is not a failed quorum, got %q", st)
	}
	// The three dispositions a reader needs are on that line.
	if !strings.Contains(st, "withdraws 1×") || !strings.Contains(st, "bonds return") ||
		!strings.Contains(st, "fee burns") {
		t.Fatalf("the status must say who is paid and what burns, got %q", st)
	}
}
