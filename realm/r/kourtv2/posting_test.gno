package kourtv2

import (
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// postingFixture makes a court whose SEALED supply is non-zero, which every
// threshold here reads. testCourt mints in the current epoch, and the ladder
// reads PastTotal(epoch-1), so without crossing an epoch boundary every rung
// sits at zero and every test would pass for the wrong reason.
func postingFixture(cur realm, slug string, who address, cc int64) *Court {
	c := testCourt(cur, slug, who, cc)
	testing.SkipHeights(epochBlocks * 2)
	return c
}

// THE NAMED PATH check-spend-paths.py DEMANDS. Its rule: staked CC stays in the
// holder's balance, so the ledger cannot refuse a second commitment of the same
// coins — only this realm can, and only if every spend path asks. A pass burns
// from a balance rather than moving coin into the escrow, so if it did not ask,
// an address could stake its whole balance and then destroy the same coins,
// leaving the realm owing CC it does not hold.
func TestAPassCannotBeBoughtWithCommittedCoin(cur realm, t *testing.T) {
	alice := testutils.TestAddress("po1-alice")
	c := postingFixture(cur, "po1", alice, 50_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "po1", "does a pass respect a lock?")

	// Stake everything that is left after the claim deposit and fee.
	free := disposable(c, alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "po1", id, sideYES, free)
	uassert.Equal(t, int64(0), disposable(c, alice))

	price := PassPrice("po1")
	if price <= 0 {
		t.Fatalf("setup: the pass must be priced: %d", price)
	}
	supplyBefore := c.coin.TotalSupply()
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "kourtv2:", func() {
		BuyCommentPass(cross(cur), "po1")
	})
	// The refusal must not have burned anything on the way out.
	uassert.Equal(t, supplyBefore, c.coin.TotalSupply())
	uassert.False(t, HoldsPass("po1", alice))

	// Freed, it goes through — so the refusal was about the lock, not the price.
	testing.SetRealm(testing.NewUserRealm(alice))
	Unstake(cross(cur), "po1", id, sideYES, price)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.Equal(t, price, BuyCommentPass(cross(cur), "po1"))
	uassert.True(t, HoldsPass("po1", alice))
	uassert.Equal(t, supplyBefore-price, c.coin.TotalSupply())
}

func TestTheEntryPassBurnsAndIsOneShot(cur realm, t *testing.T) {
	alice := testutils.TestAddress("po2-alice")
	c := postingFixture(cur, "po2", alice, 50_000_000_000)

	// Level 0 with nothing: no standing, no pass, no posts. Not a small
	// allowance — zero, because any free per-address allowance is a free flood.
	uassert.Equal(t, int64(0), PostLevel("po2", alice))
	uassert.Equal(t, int64(0), PostsPerDay("po2", alice))
	uassert.Equal(t, int64(0), PostsAvailable("po2", alice))

	before := c.coin.BalanceOf(alice)
	supply := c.coin.TotalSupply()
	testing.SetRealm(testing.NewUserRealm(alice))
	price := BuyCommentPass(cross(cur), "po2")

	// BURNED, not escrowed: the balance falls, the supply falls with it, and the
	// escrow is untouched. An escrowed pass would put a refund in a moderator's
	// hands and park CC where votableAt nets it out of the quorum bar.
	uassert.Equal(t, before-price, c.coin.BalanceOf(alice))
	uassert.Equal(t, supply-price, c.coin.TotalSupply())
	uassert.Equal(t, int64(0), c.coin.BalanceOf(c.escrow))
	uassert.Equal(t, int64(1), PostLevel("po2", alice))

	// And it credits NO standing — the record must not be purchasable.
	uassert.Equal(t, int64(0), Standing("po2", alice))

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "already holds a pass", func() {
		BuyCommentPass(cross(cur), "po2")
	})
}

func TestStandingClimbsTheLadderAboveThePass(cur realm, t *testing.T) {
	alice := testutils.TestAddress("po3-alice")
	c := postingFixture(cur, "po3", alice, 50_000_000_000)
	l := ladderFor(c)
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)
	if sup <= 0 {
		t.Fatal("setup: the sealed supply must be non-zero")
	}

	// Just under t1 is still level 0 without a pass: the thresholds are read, not
	// approximated.
	r := getStanding(c, alice)
	r.score = sup*l.t1Bps/10_000 - 1
	uassert.Equal(t, int64(0), PostLevel("po3", alice))

	for _, k := range []struct {
		bps  int64
		want int64
		rate int64
	}{
		{l.t1Bps, 1, l.postsEntry},
		{l.t2Bps, 2, l.postsT2},
		{l.t3Bps, 3, l.postsT3()},
	} {
		r.score = sup * k.bps / 10_000
		uassert.Equal(t, k.want, PostLevel("po3", alice))
		uassert.Equal(t, k.rate, PostsPerDay("po3", alice))
	}

	// The top rung is exactly the frozen ratio above entry. That relation is what
	// bounds a splitter's gain and what farming standing is worth in throughput,
	// so it is asserted as arithmetic and not left to the constants' comments.
	uassert.Equal(t, l.postsEntry*ladderTopRatio, l.postsT3())

	// The two doors compose rather than compete: a pass floors at 1 and standing
	// lifts above it, so buying in never caps what earning reaches.
	r.score = sup * l.t3Bps / 10_000
	testing.SetRealm(testing.NewUserRealm(alice))
	BuyCommentPass(cross(cur), "po3")
	uassert.Equal(t, int64(3), PostLevel("po3", alice))
}

func TestTheThrottleSpendsRefillsAndCapsAtADay(cur realm, t *testing.T) {
	alice := testutils.TestAddress("po4-alice")
	c := postingFixture(cur, "po4", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	BuyCommentPass(cross(cur), "po4")
	rate := PostsPerDay("po4", alice)
	if rate < 2 {
		t.Fatalf("setup: the entry rate must allow more than one post: %d", rate)
	}

	// TIME IS DRIVEN BY THE STAMP, NOT BY SkipHeights, and that is a property of
	// the thing under test rather than a shortcut. The bucket gates on WALL-CLOCK
	// deliberately (clock.gno: a deadline a user plans around cannot gate on a
	// height, because a height only means a date if the chain's pace never
	// changes), and SkipHeights moves height while time.Now() does not follow. So
	// a test that skipped blocks would assert nothing about refilling.
	r := getStanding(c, alice)

	// A first-ever poster starts FULL, not empty: an empty bucket would make the
	// pass buy nothing until a day had passed.
	uassert.Equal(t, rate, PostsAvailable("po4", alice))

	for i := int64(0); i < rate; i++ {
		mustSpendPost(c, alice)
	}
	uassert.Equal(t, int64(0), PostsAvailable("po4", alice))
	// PanicsContains, NOT AbortsContains: an abort is what a CROSSING call does,
	// and mustSpendPost is an internal helper called in-realm. The first version
	// used the abort form, the panic escaped the assertion, and the test failed
	// with the very message it was asserting.
	uassert.PanicsContains(t, cur, "allowance for now is spent", func() {
		mustSpendPost(c, alice)
	})

	// NOTHING HERE COMPARES TWO READS OF THE CLOCK. nowTime() is real wall-clock
	// in a test (tcNow falls through to time.Now when the test clock is unarmed),
	// so an assertion like `want := nowTime()-tick; ...; got == want` fails
	// whenever a second ticks over between the two calls. The first version of
	// this test did exactly that and was flaky by construction. Offsets are
	// written from one captured base, and the one stamp assertion is stated as
	// "did not move" rather than as an absolute value.

	// A full day back refills the whole rate.
	r.tokens, r.lastRefill = 0, nowTime()-secsPerDay
	uassert.Equal(t, rate, PostsAvailable("po4", alice))

	// A week back does NOT bank a week: the bucket caps at one day.
	r.tokens, r.lastRefill = 0, nowTime()-secsPerDay*7
	uassert.Equal(t, rate, PostsAvailable("po4", alice))

	// THE REMAINDER IS KEPT. A poster who checks after less than one post's worth
	// of time gains nothing yet — and the stamp must NOT jump to now, or the
	// fraction already earned is discarded every time anyone looks, making the
	// effective rate a function of how often the page was opened.
	r.tokens, r.lastRefill = 0, nowTime()-(secsPerDay/rate-2)
	uassert.Equal(t, int64(0), PostsAvailable("po4", alice))
	stamp := r.lastRefill
	refill(c, alice, r) // the write path: no whole post earned yet
	uassert.Equal(t, stamp, r.lastRefill)

	// Past the boundary, one post lands — the earlier fraction still counted.
	r.tokens, r.lastRefill = 0, nowTime()-secsPerDay/rate
	uassert.Equal(t, int64(1), PostsAvailable("po4", alice))
}

func TestTheLadderInheritsUntilACourtOverridesIt(cur realm, t *testing.T) {
	alice := testutils.TestAddress("po5-alice")
	postingFixture(cur, "po5", alice, 50_000_000_000)

	if !strings.Contains(Ladder("po5"), ";inherited:1") {
		t.Fatal("a fresh court inherits")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	SetCourtLadder(cross(cur), "po5", 10, 50, 200, 5, 20)
	if !strings.Contains(Ladder("po5"), ";inherited:0") {
		t.Fatal("an overridden court must not read as inheriting")
	}
	if !strings.Contains(Ladder("po5"), ";l3:50") {
		t.Fatal("the top rung is DERIVED from entry x the frozen ratio, never stored")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	ClearCourtLadder(cross(cur), "po5")
	if !strings.Contains(Ladder("po5"), ";inherited:1") {
		t.Fatal("cleared must inherit again")
	}
}

func TestTheLadderBoundsCannotBeSetThrough(cur realm, t *testing.T) {
	alice := testutils.TestAddress("po6-alice")
	stranger := testutils.TestAddress("po6-stranger")
	postingFixture(cur, "po6", alice, 50_000_000_000)

	bad := [][]int64{
		{25, 25, 200, 3, 10},  // t1 not below t2
		{25, 10, 200, 3, 10},  // t1 above t2
		{5, 200, 100, 3, 10},  // t2 above t3
		{0, 25, 200, 3, 10},   // t1 at zero
		{5, 25, 20_000, 3, 10}, // t3 out of range
		{5, 25, 200, 0, 10},   // a zero entry rate is level 1 buying nothing
		{5, 25, 200, 10, 10},  // entry not below l2
		{5, 25, 200, 10, 5},   // l2 below entry
		{5, 25, 200, 10, 200}, // l2 at or above the DERIVED top (10 x 10 = 100)
		// The coupled one: t3 below 100x the pass price. Lowering t3 alone makes a
		// unit of standing worth more than the flag lane's burn can cover.
		{5, 25, passPriceOfT3*passPriceBps - 1, 3, 10},
	}
	for _, b := range bad {
		testing.SetRealm(testing.NewUserRealm(alice))
		uassert.AbortsContains(t, cur, "kourtv2:", func() {
			SetCourtLadder(cross(cur), "po6", b[0], b[1], b[2], b[3], b[4])
		})
	}
	// The shipped default is itself a legal setting, or the bound would be
	// refusing the thing it was written to describe.
	d := ladderDefault
	testing.SetRealm(testing.NewUserRealm(alice))
	SetCourtLadder(cross(cur), "po6", d.t1Bps, d.t2Bps, d.t3Bps, d.postsEntry, d.postsT2)

	// And authority: a stranger moves neither the court's ladder nor the realm's.
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "kourtv2:", func() {
		SetCourtLadder(cross(cur), "po6", d.t1Bps, d.t2Bps, d.t3Bps, d.postsEntry, d.postsT2)
	})
	uassert.AbortsContains(t, cur, "kourtv2:", func() {
		ClearCourtLadder(cross(cur), "po6")
	})
	uassert.AbortsContains(t, cur, "global DAO admin", func() {
		SetLadderDefault(cross(cur), d.t1Bps, d.t2Bps, d.t3Bps, d.postsEntry, d.postsT2)
	})
}

func TestThePassPriceIsLiddedByTheStandingWorthRelation(cur realm, t *testing.T) {
	// TWO COURT SIZES, and the small one is the whole point. At the default
	// calibration the bps price and the lid are the SAME number — passPriceBps is
	// 1 and t3 is 100 bps, so sup/10000 == (sup/100)/100 exactly — which means a
	// large court cannot tell a working lid from a missing one. The lid only
	// binds where passPriceMinCC binds, i.e. on a court too small for the bps
	// price to reach the floor. A test on the large court alone passed with the
	// lid deleted; measured.
	for _, k := range []struct {
		slug string
		cc   int64
	}{
		{"po7", 50_000_000_000}, // large: bps price, lid not binding
		{"po8", 200_000_000},    // small: the floor would exceed t3/100
	} {
		alice := testutils.TestAddress(k.slug + "-alice")
		c := postingFixture(cur, k.slug, alice, k.cc)
		sup := c.coin.PastTotal(c.coin.Epoch() - 1)
		price := PassPrice(k.slug)
		t3 := sup * ladderFor(c).t3Bps / 10_000
		if price*passPriceOfT3 > t3 {
			t.Fatalf("%s: the pass price must stay inside t3/100: price %d, t3 %d, supply %d",
				k.slug, price, t3, sup)
		}
	}
}

// bucketAt IS PURE AND TAKES `now`, so it can be tested with explicit numbers
// and no clock at all. That matters twice over: the assertions cannot drift when
// a real second ticks over mid-test, and the arithmetic is reachable without a
// court, a pass or a level.
func TestBucketArithmetic(cur realm, t *testing.T) {
	const rate = int64(3)
	win := secsPerDay / rate // one post's worth of time
	const now = int64(1_700_000_000)

	// A first-ever bucket starts FULL, and its stamp is NOW.
	avail, stamp := bucketAt(0, 0, rate, now)
	uassert.Equal(t, rate, avail)
	uassert.Equal(t, now, stamp)

	// THE STAMP MUST NOT JUMP TO NOW WHEN A PARTIAL POST IS LEFT OVER. One and a
	// half windows elapsed earns one post and leaves half a window standing to
	// the poster's credit; a stamp set to `now` would throw that half away, and
	// would do so again on every read, making the effective rate a function of
	// how often the page was opened.
	avail, stamp = bucketAt(0, now-win-win/2, rate, now)
	uassert.Equal(t, int64(1), avail)
	uassert.Equal(t, now-win/2, stamp)
	if stamp == now {
		t.Fatal("the leftover fraction was discarded")
	}

	// Under one window earns nothing AND moves nothing: the fraction is carried
	// by leaving the stamp where it was.
	avail, stamp = bucketAt(0, now-win+1, rate, now)
	uassert.Equal(t, int64(0), avail)
	uassert.Equal(t, now-win+1, stamp)

	// A week away banks a day, not a week.
	avail, _ = bucketAt(0, now-secsPerDay*7, rate, now)
	uassert.Equal(t, rate, avail)

	// A zero rate is a zero bucket, and it must not move the stamp either.
	avail, stamp = bucketAt(2, now-secsPerDay, 0, now)
	uassert.Equal(t, int64(0), avail)
	uassert.Equal(t, now-secsPerDay, stamp)
}

// AND THE FIRST-EVER BRANCH IS NOT REDUNDANT, which is the non-obvious half.
// Falling through it looks harmless — the gain from a zero stamp is enormous and
// the cap trims it to `rate` either way — but the STAMP it computes lands far in
// the future, so once the bucket is spent down, `now - lastRefill` is negative
// forever and it never refills again. Deleting that branch does not change what
// a fresh poster sees; it silently bricks them after their first burst.
func TestAFreshBucketStillRefillsAfterItIsSpent(cur realm, t *testing.T) {
	alice := testutils.TestAddress("po9-alice")
	c := postingFixture(cur, "po9", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	BuyCommentPass(cross(cur), "po9")
	rate := PostsPerDay("po9", alice)

	r := getStanding(c, alice) // lastRefill is still 0 here: nothing has posted
	uassert.Equal(t, int64(0), r.lastRefill)
	for i := int64(0); i < rate; i++ {
		mustSpendPost(c, alice)
	}
	uassert.Equal(t, int64(0), PostsAvailable("po9", alice))

	// A day later it must be full again. With the branch gone the stamp is in the
	// far future and this reads zero forever.
	r.lastRefill -= secsPerDay
	uassert.Equal(t, rate, PostsAvailable("po9", alice))
}

// A SLASH LOWERS THE RATE IN THE SAME BLOCK. §4's "there is no banked balance a
// sanction fails to reach" is delivered by bucketAt's cap sitting OUTSIDE the
// gain branch — with no time elapsed there is no gain, so a cap inside it would
// leave a slashed top-rung poster their whole banked burst for a day.
func TestASlashReachesTheBankedAllowanceImmediately(cur realm, t *testing.T) {
	mod := testutils.TestAddress("bank-mod")
	who := testutils.TestAddress("bank-who")
	c := postingFixture(cur, "bank", mod, 50_000_000_000)
	c.coin.Mint(who, 20_000_000_000)
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)

	r := getStanding(c, who)
	r.score, r.highWater = sup*ladderFor(c).t3Bps/10_000, sup*ladderFor(c).t3Bps/10_000
	// A full top-rung bucket, banked and unspent.
	testing.SetRealm(testing.NewUserRealm(who))
	id := OpenClaim(cross(cur), "bank", "something to bank an allowance against")
	testing.SetRealm(testing.NewUserRealm(who))
	PostComment(cross(cur), "bank", id, 0, "one post, to set the stamp")
	r.tokens = postsPerDayAt(ladderFor(c), 3)
	if r.tokens < 30 {
		t.Fatal("the fixture needs a full top-rung bucket")
	}

	// Slash to the entry rung. NO TIME PASSES — that is the whole test.
	testing.SetRealm(testing.NewUserRealm(mod))
	SlashStanding(cross(cur), "bank", who, 2, boardCodeSpam)
	if postLevel(c, who) != 1 {
		t.Fatal("the fixture must land on the entry rung")
	}
	if got := PostsAvailable("bank", who); got > ladderFor(c).postsEntry {
		t.Fatal("a slashed poster kept a banked burst the sanction should have " +
			"taken in the same block: " + strconv.FormatInt(got, 10) + " available")
	}
}

// THE §16 LID IS PROVABLY INERT AT THE SHIPPED CALIBRATION, and this test is the
// record of that rather than a test of the clamp firing.
//
//	p_bps = sup * passPriceBps / 10_000            = sup/10_000  (passPriceBps 1)
//	lid   = sup * t3Bps / 10_000 / passPriceOfT3   = sup*t3/1e6  (passPriceOfT3 100)
//
// so lid > p_bps exactly when t3 > 100, and mustLadder already refuses t3 < 100.
// At t3 == 100 the two are EQUAL; above it the lid is slack. The clamp therefore
// never changes an answer, and §16's relation is carried entirely by mustLadder's
// own `t3Bps >= passPriceOfT3*passPriceBps` check.
//
// It is kept, not deleted, and this comment is why: §15.3 wants passPrice's floor
// and bps to become a realm ceiling a court may lower. The moment passPriceBps is
// per-court, lid stops tracking p_bps and the clamp becomes the only thing making
// §16 hold at every supply — while mustLadder would still be comparing against
// the REALM default. The dead clamp is the live half of that future.
func TestTheSixteenRelationHoldsAtEveryLadderSetting(cur realm, t *testing.T) {
	mod := testutils.TestAddress("lid-mod")
	c := postingFixture(cur, "lid", mod, 900_000_000_000)

	for _, t3 := range []int64{100, 5_000, 10_000} {
		testing.SetRealm(testing.NewUserRealm(mod))
		SetCourtLadder(cross(cur), "lid", 2, 3, t3, 3, 10)
		sup := c.coin.PastTotal(c.coin.Epoch() - 1)
		price := passPriceFor(c)
		if price*passPriceOfT3 > sup*t3/10_000 {
			t.Fatal("§16 broken at t3=" + strconv.FormatInt(t3, 10) + ": price " +
				strconv.FormatInt(price, 10))
		}
		testing.SetRealm(testing.NewUserRealm(mod))
		ClearCourtLadder(cross(cur), "lid")
	}
}

// AND ON A YOUNG COURT THE PASS IS ALL BUT FREE, which the floor was written to
// prevent and does not. passPriceMinCC is 0.1 CC, but the lid at the default
// ladder is exactly sup/10_000, so it clamps the floor straight back off for
// every court under 1000 CC of sealed supply — i.e. every new one.
//
// Pinned rather than fixed: raising the floor without raising t3 breaks §16, and
// which of the two moves is a calibration call. docs/CLAIM_BOARDS.md §7.8
// carries it.
func TestOnAYoungCourtTheEntryPassIsNearlyFree(cur realm, t *testing.T) {
	mod := testutils.TestAddress("young-mod")
	c := postingFixture(cur, "young", mod, 15_000_000) // 15 CC
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)
	price := passPriceFor(c)

	if price >= passPriceMinCC {
		t.Fatal("if the floor now binds, the calibration changed and §7.8 is stale")
	}
	if price != sup/10_000 {
		t.Fatal("the lid, not the floor, is what sets a young court's pass price")
	}
	// The relation still holds, which is why this is a calibration note and not
	// a bug: the pass is cheap, and a unit of standing is correspondingly cheap.
	if price*passPriceOfT3 > sup*ladderFor(c).t3Bps/10_000 {
		t.Fatal("§16 must hold even where the floor is cancelled")
	}

	// BUT THE FLOOR IS NOT DEAD — it is cancelled at the DEFAULT ladder and live
	// above it, and the difference is exactly where the lid stops tracking the
	// bps price. Raise t3 and the lid goes slack; then the floor is the only
	// thing between a 100 CC court and a 0.001 CC pass. Deleting the floor
	// survived every test until this arm, because every fixture ran the default
	// ladder where the lid cancels it.
	testing.SetRealm(testing.NewUserRealm(mod))
	SetCourtLadder(cross(cur), "young", 5, 25, 10_000, 3, 10)
	c.coin.Mint(mod, 100_000_000)
	testing.SkipHeights(epochBlocks * 2)
	if sup2 := c.coin.PastTotal(c.coin.Epoch() - 1); sup2 < 10_000_000 || sup2 >= 1_000_000_000 {
		t.Fatal("the fixture must sit in the band where the floor binds, got " +
			strconv.FormatInt(sup2, 10))
	}
	if got := passPriceFor(c); got != passPriceMinCC {
		t.Fatal("above the default ladder the floor must bind, got " +
			strconv.FormatInt(got, 10))
	}
}

// A BRAND-NEW COURT'S BOARD MUST REFUSE, NOT PANIC ON AN INTERNAL MESSAGE.
//
// Every board threshold is quoted against PastTotal(Epoch()-1), and grc20votes'
// mustBeSealed panics on `at == 0`, so a court whose coin has not reached epoch 2
// hit that panic head-on: PostComment aborted with "grc20votes: that epoch has
// not been sealed yet", and PassPrice, PostLevel and the whole /me page — all
// READS — panicked outright.
//
// Every unit test skipped two epochs in its fixture (postingFixture says so in
// its own comment), so the suite could not see it. z_read_filetest found it on
// the first run after the board reads were added there.
func TestAFreshCourtsBoardRefusesInsteadOfPanicking(cur realm, t *testing.T) {
	who := testutils.TestAddress("fresh-who")
	// testCourt, NOT postingFixture: the fixture's whole job is to skip the
	// epochs this test is about.
	c := testCourt(cur, "fresh", who, 50_000_000_000)
	if c.coin.Epoch() >= 2 {
		t.Fatal("the fixture must be a court with no sealed epoch")
	}

	// The reads answer instead of aborting.
	if got := PassPrice("fresh"); got != 0 {
		t.Fatal("an unpriceable pass must read 0, not panic: " + strconv.FormatInt(got, 10))
	}
	if PostLevel("fresh", who) != 0 || PostsPerDay("fresh", who) != 0 {
		t.Fatal("no sealed epoch means no rung, for everyone")
	}
	if PostsAvailable("fresh", who) != 0 {
		t.Fatal("and no allowance")
	}
	if levelFloor(c, 3) != 0 {
		t.Fatal("every rung is 0 before there is a supply to quote it against")
	}
	// The page renders, and says the true thing rather than aborting.
	page := renderStanding("fresh", who.String())
	if !strings.Contains(page, "too new to have a board") {
		t.Fatalf("the standing page must render on a fresh court:\n%s", page)
	}

	// The writes refuse, and name the real reason — not "earn standing, or buy
	// an entry pass", which is advice you cannot take on a court that cannot
	// sell you one.
	testing.SetRealm(testing.NewUserRealm(who))
	id := OpenClaim(cross(cur), "fresh", "a claim on a court with no sealed epoch")
	testing.SetRealm(testing.NewUserRealm(who))
	uassert.AbortsContains(t, cur, "has not completed a sealed epoch yet", func() {
		PostComment(cross(cur), "fresh", id, 0, "too early")
	})
	testing.SetRealm(testing.NewUserRealm(who))
	uassert.AbortsContains(t, cur, "has not completed a sealed epoch yet", func() {
		BuyCommentPass(cross(cur), "fresh")
	})

	// AND IT OPENS BY ITSELF once an epoch seals — no act required, or the
	// refusal above would be a permanent state wearing a temporary message.
	testing.SkipHeights(epochBlocks * 2)
	if c.coin.Epoch() < 2 {
		t.Fatal("the test clock must roll the coin's epoch")
	}
	testing.SetRealm(testing.NewUserRealm(who))
	BuyCommentPass(cross(cur), "fresh")
	testing.SetRealm(testing.NewUserRealm(who))
	PostComment(cross(cur), "fresh", id, 0, "and now it works")
	if PostLevel("fresh", who) != 1 {
		t.Fatal("a pass-holder on a sealed court is at the entry rung")
	}
}

// AUDIT D11: what throughput COSTS, as an executable number.
//
// §13 records that §4's convexity condition is evaluated at the wrong point and,
// corrected, is unsatisfiable by any multi-rung ladder — and that the pass makes
// it moot anyway, because `level = max(fromStanding, 1)` means a splitter
// allocates no standing to sybils and buys `n x rate(1)` directly. The honest
// bound it asks for is a PRICE: passPrice per rate(1) posts a day.
//
// Standing cannot be split profitably — below t1 a sybil is level 0 — so the
// only purchasable throughput is the pass, and it scales linearly in CC with no
// ceiling. This test states that price against the shipped calibration so a
// ladder or floor change that moves it is caught rather than argued about.
func TestWhatThroughputCosts(cur realm, t *testing.T) {
	buyer := testutils.TestAddress("d11-buyer")
	c := postingFixture(cur, "d11", buyer, 900_000_000_000)
	l := ladderFor(c)
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)
	price := passPriceFor(c)

	// SPLITTING STANDING IS PROFITABLE AT THE SHIPPED LADDER, and this asserts the
	// measured factor rather than the intended property.
	//
	// §4 asks for convexity: concentrating standing must be at least as good as
	// splitting it, which requires rate(l)/tau(l) to be NON-DECREASING in the
	// rung. Shipped it is strictly decreasing — 3/5 = 0.6, 10/25 = 0.4,
	// 30/100 = 0.3 — so every rung below the top pays better per unit of standing:
	//
	//	rung  tau   rate  rate/tau  split into  posts/day  vs concentrated
	//	 1      5     3     0.600       20         60          2.00x
	//	 2     25    10     0.400        4         40          1.33x
	//	 3    100    30     0.300        1         30          1.00x
	//
	// §13 predicted it ("corrected, the condition demands tau(2) <= tau(1) and is
	// unsatisfiable by any multi-rung ladder") and nothing measured it. The ruling
	// is in CLAIM_BOARDS.md; this test pins the factor so a recalibration is
	// visible as a change here.
	whole := getStanding(c, buyer)
	whole.score = sup * l.t3Bps / 10_000
	if postLevel(c, buyer) != 3 {
		t.Fatal("the fixture must put one address at the top rung")
	}
	concentrated := postsPerDayAt(l, 3)

	for _, tc := range []struct {
		rung  int64
		bps   int64
		parts int64
	}{{2, l.t2Bps, l.t3Bps / l.t2Bps}, {1, l.t1Bps, l.t3Bps / l.t1Bps}} {
		split := int64(0)
		for i := int64(0); i < tc.parts; i++ {
			w := testutils.TestAddress("d11-s" + strconv.FormatInt(tc.rung, 10) + "-" + strconv.FormatInt(i, 10))
			getStanding(c, w).score = sup * tc.bps / 10_000
			got := postLevel(c, w)
			if got != tc.rung {
				t.Fatalf("each part must land on rung %d, got %d", tc.rung, got)
			}
			split += postsPerDayAt(l, got)
		}
		if split <= concentrated {
			t.Fatalf("the ladder became convex at rung %d (%d vs %d) — good news, "+
				"and this test and the ruling in CLAIM_BOARDS.md are now stale",
				tc.rung, split, concentrated)
		}
	}

	// THE PURCHASABLE RATE. A pass is the only way to buy throughput, and it buys
	// exactly rate(1) a day, for ever, per burn.
	if postsPerDayAt(l, 1) != l.postsEntry {
		t.Fatal("a pass buys the entry rate")
	}
	perPostPerDay := price / l.postsEntry
	if perPostPerDay <= 0 {
		t.Fatalf("throughput is FREE at this calibration: price %d for %d posts/day",
			price, l.postsEntry)
	}

	// AND THE BURN IS REAL: supply falls by exactly the price, so throughput is
	// bought from the court's own float rather than transferred to anyone.
	// THE PRICE, AGAINST AN INDEPENDENT COMPUTATION. Asserting `paid ==
	// passPriceFor(c)` is tautological: both sides run the same code, so any
	// mutant inside it satisfies both. The bps arithmetic is written out here so
	// the assertion has something of its own to compare with — the third time
	// this session a surviving mutant turned out to be an assertion against
	// itself rather than a gap in the code.
	wantPrice := sup * passPriceBps / 10_000
	if price != wantPrice {
		t.Fatalf("the pass price is bps of sealed supply: got %d, want %d",
			price, wantPrice)
	}
	before := c.coin.TotalSupply()
	testing.SetRealm(testing.NewUserRealm(buyer))
	paid := BuyCommentPass(cross(cur), "d11")
	if paid != wantPrice || c.coin.TotalSupply() != before-wantPrice {
		t.Fatalf("the pass must burn exactly its price: paid %d, supply %d -> %d",
			paid, before, c.coin.TotalSupply())
	}
}

// AUDIT D11: the price of filling one claim's entire board, on a young court.
//
// The per-claim caps bound concentration — 512 rows, 8 per author — so filling a
// board takes 64 distinct addresses. Each needs a pass. On a court below 1000 CC
// of sealed supply the lid cancels passPriceMinCC entirely (recorded in §7.8), so
// that fixed cost is a fraction of a fraction, and this test says what fraction.
//
// It is a calibration record, not a defect: the caps still hold, the time cost
// still binds at rate(1) a day, and every pass is a real burn. But "what does it
// cost to fill a board" should be a number somebody can read.
func TestThePriceOfFillingAYoungCourtsBoard(cur realm, t *testing.T) {
	mod := testutils.TestAddress("d11y-mod")
	c := postingFixture(cur, "d11y", mod, 15_000_000) // 15 CC
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)
	price := passPriceFor(c)

	if price >= passPriceMinCC {
		t.Fatal("if the floor now binds on a young court, §7.8 is stale")
	}
	addressesNeeded := int64(maxBoardRowsPerClaim / maxBoardRowsPerAuthor) // 64
	total := addressesNeeded * price
	// Expressed as basis points of the court's own sealed supply, which is the
	// only scale-free way to say it.
	bps := total * 10_000 / sup
	if bps > 100 {
		t.Fatalf("filling a board costs %d bps of supply; the calibration moved "+
			"and §7.8's arithmetic needs revisiting", bps)
	}
	if bps == 0 {
		t.Fatalf("filling a board rounds to FREE at this calibration: %d passes "+
			"at %d each against supply %d", addressesNeeded, price, sup)
	}
	// The time cost is what actually binds, and it is the entry rate: eight rows
	// per address at rate(1) a day.
	days := int64(maxBoardRowsPerAuthor) / ladderFor(c).postsEntry
	if days < 2 {
		t.Fatalf("one address can fill its whole per-claim quota in %d days; the "+
			"throttle is not the binding cost it is meant to be", days)
	}
}

// AUDIT D12: your LEVEL falls as the court grows, with no act by anyone — and
// nothing tested it or said it.
//
// §2.3 says "Standing never decays. It falls only by a logged moderator slash."
// That is true of STANDING and misleading about LEVEL, which is what actually
// gates posting: the rungs are bps of a sealed supply that only grows, so an
// untouched score crosses back down a rung on its own. The page printed
// "25 bps of supply" — the machinery — and never the consequence.
func TestALevelFallsAsTheCourtGrowsWithNoSlash(cur realm, t *testing.T) {
	who := testutils.TestAddress("d12-who")
	c := postingFixture(cur, "d12", who, 100_000_000)
	l := ladderFor(c)
	sup := c.coin.PastTotal(c.coin.Epoch() - 1)

	// Exactly on the second rung, and nothing else.
	r := getStanding(c, who)
	r.score = sup * l.t2Bps / 10_000
	r.highWater = r.score
	if postLevel(c, who) != 2 {
		t.Fatal("the fixture must sit exactly on rung 2")
	}

	// The court grows. No slash, no moderator, no act against this address.
	c.coin.Mint(testutils.TestAddress("d12-whale"), sup*3)
	testing.SkipHeights(epochBlocks * 2)
	if c.coin.PastTotal(c.coin.Epoch()-1) <= sup {
		t.Fatal("the fixture must seal a larger supply")
	}

	if got := postLevel(c, who); got != 1 {
		t.Fatalf("the level must fall as the bar rises, got %d", got)
	}
	// The SCORE is untouched, which is what makes §2.3 true and incomplete.
	if r.score != sup*l.t2Bps/10_000 || r.highWater != r.score {
		t.Fatal("no standing was taken; only the bar moved")
	}
	// RestoreStanding has NOTHING TO RESTORE, and that is the point rather than an
	// accident: it raises score toward highWater, the two are equal because no
	// slash happened, and the remedy for a slash cannot give back a rung the bar
	// took. Worth pinning, because a user who lost a rung will reach for it — and
	// here `who` is the court's own 1-of-1 moderator, so the refusal is on the
	// state and not on authority.
	testing.SetRealm(testing.NewUserRealm(who))
	uassert.AbortsContains(t, cur, "nothing to restore", func() {
		RestoreStanding(cross(cur), "d12", who)
	})

	// AND THE PAGE SAYS IT. A reader who dropped a rung with no notice needs to
	// know why, and "bps of supply" alone does not tell them.
	page := renderStanding("d12", who.String())
	if !strings.Contains(page, "share of this court's supply") {
		t.Fatalf("the page must say the bar moves with the court:\n%s", page)
	}
}

/* THE REFUSAL A FIRST-TIME READER ACTUALLY GETS, and the reason it needs a test
   of its own: mustSpendPost refuses a level-0 caller TWICE OVER. The `lvl == 0`
   arm says "earn standing, or buy an entry pass"; delete it and the same caller
   falls through to the throttle, which refuses just as firmly and says "your
   posting allowance for now is spent — level 0 allows 0 a day".

   Both panic, so the mutation corpus scored it a survivor and the gaps file
   recorded it as unkillable — "the corpus cannot tell the two panics apart".
   That is true of the corpus and not of a test. The two messages are not
   interchangeable: one tells a newcomer what to DO, the other tells them to wait
   for an allowance that will never arrive, because level 0 has none. For
   somebody who has never posted, the message is the whole of the refusal.

   SEALED, deliberately. The unsealed court has its own third message, and this
   asserts the arm that survives sealing — postingFixture crosses two epochs so
   the supply the ladder reads is non-zero. */
func TestALevelZeroPosterIsToldWhatToDoNotToWait(cur realm, t *testing.T) {
	stranger := testutils.TestAddress("po-lvl0")
	c := postingFixture(cur, "polvl0", stranger, 50_000_000_000)
	if _, sealed := boardSupply(c); !sealed {
		t.Fatal("setup: the court must have a sealed epoch, or the third message answers")
	}
	if got := postLevel(c, stranger); got != 0 {
		t.Fatalf("setup: the poster must be level 0, got %d", got)
	}

	func() {
		defer func() {
			r := recover()
			if r == nil {
				t.Fatal("a level-0 poster was allowed to post")
			}
			msg, _ := r.(string)
			if !strings.Contains(msg, "earn standing, or buy an entry pass") {
				t.Fatalf("a level-0 poster was refused with the wrong advice: %q", msg)
			}
			// ...and NOT the throttle's, which is what the deleted arm falls to.
			if strings.Contains(msg, "allowance for now is spent") {
				t.Fatalf("the throttle answered for the ladder: %q", msg)
			}
		}()
		mustSpendPost(c, stranger)
	}()
}
