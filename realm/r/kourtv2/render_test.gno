package kourtv2

import (
	"strconv"
	"strings"
	"testing"

	grc20votes "gno.land/p/kourt/grc20votes/v0"
	testutils "gno.land/p/nt/testutils/v0"
)

func TestRenderPagesAndSanitization(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rn-alice")
	c := testCourt(cur, "rn1", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "rn1", "Hostile [link](x) *title* <tag>")
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "rn1", id, sideYES, 3_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "rn1", id, sideNO, 1_000_000_000)

	dir := Render("")
	if !strings.Contains(dir, "principal always returns 1×") {
		t.Fatal("the directory leads with the differentiator")
	}
	if strings.Contains(dir, "backing") {
		t.Fatal("no backing figure may ever render")
	}
	court := Render("rn1")
	if !strings.Contains(court, "Test Court rn1") || !strings.Contains(court, "reservoir") {
		t.Fatal("the court page shows supply/emission/reservoir")
	}
	claim := Render("rn1/1")
	if !strings.Contains(claim, "75.00% YES") {
		t.Fatalf("instantaneous ratio must render: %s", claim)
	}
	if strings.Contains(claim, "[link](x)") {
		t.Fatal("attacker markdown must be sanitized")
	}
	if !strings.Contains(claim, "open — stake YES or NO") {
		t.Fatal("the status line renders")
	}
	if !strings.Contains(Render("rn1/99"), "Not found") ||
		!strings.Contains(Render("nope"), "Not found") ||
		!strings.Contains(Render("rn1/abc"), "must be a number") {
		t.Fatal("not-found routes")
	}
	_ = c
}

func TestRenderLifecycleLines(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rl-alice")
	c := testCourt(cur, "rl1", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "rl1", "Lifecycle lines")
	cs := mustClaim(c, id)

	mustContain := func(stage, want string) {
		t.Helper()
		out := Render("rl1/1")
		if !strings.Contains(out, want) {
			t.Fatalf("%s: missing %q in:\n%s", stage, want, out)
		}
	}
	mustContain("open", "open — stake YES or NO")

	// Answered: crafted state (the dispute tests exercise the real paths;
	// render only reads).
	cs.frozenAt, cs.answer, cs.answerBond0, cs.answerHeight = 10, sideNO, 777, 10
	cs.xBarFrozen = 1_000_000 // so the dispute-bond quote is positive
	mustContain("answered", "settles undisputed")
	mustContain("answered", "answer: NO (bond 777 "+qualifiedSymbol(mustCourt("rl1"))+")")
	mustContain("answered", "disputing this answer costs a bond of")

	cs.disputeOpen, cs.round = true, 1
	mustContain("disputed", "sealed vote")
	mustContain("disputed", "sealed until the vote closes")
	if strings.Contains(Render("rl1/1"), "yes:") {
		t.Fatal("an open vote must never render a running tally")
	}

	cs.disputeOpen, cs.provisional, cs.escrowUntil, cs.failedRounds = false, int8(sideNO), 99999, 1
	mustContain("provisional", "provisional verdict NO")
	mustContain("provisional", "withdraw 1× now")
	mustContain("provisional", "failed dispute rounds: 1 of 3")

	// The SAME arm on the OTHER side, because sideYES is 0 and the guard reads
	// `cs.provisional >= 0`. Exercised only on NO, tightening that bound to
	// `> 0` still matches NO and the line still renders, so the boundary is
	// invisible — and the arm it falls through to says "answered — staking
	// frozen", dropping the sentence that tells the losing side it may withdraw
	// 1× now. A two-valued arm tested on one value leaves the boundary unpinned
	// when the boundary sits at the other value.
	cs.provisional = int8(sideYES)
	mustContain("provisional YES", "provisional verdict YES")
	mustContain("provisional YES", "withdraw 1× now")
	cs.provisional = int8(sideNO)

	cs.verdictAt, cs.route, cs.tier = 100, "vote", tierMidX
	// THE SETTLED LINE NAMES THE SIDE, and both values are checked for the same
	// reason the provisional arm above checks both: it reads provisional through
	// sideName, and an arm exercised on one value leaves the other free to render
	// "settled —". provisional is still sideNO from the arm above.
	mustContain("settled", "settled NO — every stake withdraws 1×")
	cs.provisional = int8(sideYES)
	mustContain("settled YES", "settled YES — every stake withdraws 1×")
	cs.provisional = int8(sideNO)
	mustContain("settled", "verdict: NO — vote")
	mustContain("settled", "quality: mid (not final")
	mustContain("settled", "anyone may challenge that rating once")
	cs.tier, cs.tierFinal = tierHighX, true
	mustContain("quality", "quality: high (final)")
	cs.flagOpen = true
	mustContain("flagging", "flag vote open — the tally is sealed")
	cs.flagOpen = false
	cs.crystallized, cs.drawWinners, cs.carrotPool = true, 12345, 77
	mustContain("crystallized", "accuracy 12345")
	mustContain("crystallized", "participation remaining 77")

	cs.provClose = true
	mustContain("provclose", "closed without a decision")
}

func TestRenderPositionsPage(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rp-alice")
	bob := testutils.TestAddress("rp-bob")
	c := testCourt(cur, "rp1", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "rp1", "Positions page claim")
	matureOI(cur, "rp1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "rp1", id, sideNO, 300_000_000)

	// Bad inputs degrade gracefully.
	if !strings.Contains(Render("rp1/1/not-an-address"), "not a valid address") {
		t.Fatal("an invalid address must render the not-found notice")
	}
	if !strings.Contains(Render("nope/1/"+bob.String()), "No court") {
		t.Fatal("unknown court must render not-found")
	}

	// Bob's page: his NO stake and conviction show; staking-open hint.
	out := Render("rp1/1/" + bob.String())
	if !strings.Contains(out, "# Positions on this claim") || !strings.Contains(out, bob.String()) {
		t.Fatal("the page must name the address, and not address the reader as its owner")
	}
	if strings.Contains(out, "Your positions") {
		t.Fatal("this route renders for ANY address; it must not call them the reader's")
	}
	// AND WHICH COURT. Everything below is denominated in that court's coin and
	// gated by its rules, and the page named only the claim.
	if !strings.Contains(out, "](/r/kourt/kourtv2:rp1)") {
		t.Fatal("the positions page must name and link its court")
	}
	if !strings.Contains(out, qualifiedSymbol(mustCourt("rp1"))+" base units") {
		t.Fatal("a stake figure must name the court's own coin, not a generic CC")
	}
	if !strings.Contains(out, "## This address's "+qualifiedSymbol(mustCourt("rp1"))+
		" in this court") {
		t.Fatal("the wallet heading must name the court's own coin too")
	}
	if strings.Contains(out, "Your CC") {
		t.Fatal("the wallet heading must not be a generic CC addressed to the reader")
	}
	// The claim is a LINK, not just a name: this page is where a reader lands
	// from a bare address and the claim is the thing they will want next.
	if !strings.Contains(out, "](/r/kourt/kourtv2:rp1/1)") {
		t.Fatal("the positions page must link the claim, not only name it")
	}
	if !strings.Contains(out, "NO: 300000000") {
		t.Fatalf("bob's live NO stake must show:\n%s", out)
	}
	if !strings.Contains(out, "staking is open") {
		t.Fatal("pre-answer, the hint is that staking is open")
	}
	// The court-wide wallet picture. Bob holds 10,000 CC and has committed 300 of
	// them, so 9,700 are free. Since staking became a lock in place the balance
	// alone is misleading — the staked CC is still in it — and a client that shows
	// only the balance tells him he can bond coins that are already committed.
	//
	// The PARTITION is the assertion that matters: held must equal committed plus
	// free. Checking the three numbers separately would pass just as well if the
	// page printed the balance three times under different labels.
	if !strings.Contains(out, "held: 10000000000") {
		t.Fatalf("the page must show what bob holds:\n%s", out)
	}
	if !strings.Contains(out, "committed as stake: 300000000") {
		t.Fatalf("the page must show what is committed:\n%s", out)
	}
	// Bob has not voted here, so the vote lock is zero and the two "free" figures
	// coincide. Both are asserted anyway: a page that printed only one of them, or
	// printed the same number under a label naming the wrong gate, is exactly what
	// this line replaced.
	if !strings.Contains(out, "committed by voting: 0") {
		t.Fatalf("the page must show the vote commitment, zero or not:\n%s", out)
	}
	if !strings.Contains(out, "free to stake: 9700000000") {
		t.Fatalf("the page must show what a stake draws on:\n%s", out)
	}
	if !strings.Contains(out, "free to bond, deposit or transfer: 9700000000") {
		t.Fatalf("the page must show what a bond draws on:\n%s", out)
	}
	if got := LockedOf("rp1", bob) + SpendableOf("rp1", bob); got != CoinBalanceOf("rp1", bob) {
		t.Fatalf("committed + free = %d, but bob holds %d", got, CoinBalanceOf("rp1", bob))
	}
	// It is labelled court-wide, because the stake figures above it are this
	// claim's and the two would otherwise be read as the same scope.
	if !strings.Contains(out, "all claims") {
		t.Fatal("the wallet section must say it is court-wide, not claim-scoped")
	}
	// The claim page links to the positions route.
	if !strings.Contains(Render("rp1/1"), "/r/kourt/kourtv2:rp1/1/<your address>") {
		t.Fatal("the claim page must give the positions path in full, not elided")
	}

	// After answer + settle, the hint flips to withdraw.
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "rp1", id, sideYES)
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "rp1", id)
	if !strings.Contains(Render("rp1/1/"+bob.String()), "withdraw your principal") {
		t.Fatal("post-verdict, the hint is to withdraw principal")
	}
}

func TestRenderCourtPaginatesClaims(cur realm, t *testing.T) {
	alice := testutils.TestAddress("pg-alice")
	testCourt(cur, "pg1", alice, 500_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	// Open one past a page so truncation triggers.
	n := renderPageSize + 5
	for i := 0; i < n; i++ {
		OpenClaim(cross(cur), "pg1", "Claim number "+strconv.Itoa(i))
	}
	out := Render("pg1")
	// The newest claim shows; the oldest (id 1) does not; the truncation note does.
	if !strings.Contains(out, "pg1/"+strconv.Itoa(n)+")") {
		t.Fatal("the newest claim must be on the page")
	}
	if strings.Contains(out, "pg1/1)") {
		t.Fatal("the oldest claim must be paged off")
	}
	if !strings.Contains(out, "older; open any by id") {
		t.Fatalf("a truncation hint must appear:\n%s", out[len(out)-300:])
	}
	// The page renders a bounded number of claim bullets (page + hint), not n.
	if got := strings.Count(out, "kourtv2:pg1/"); got > renderPageSize+2 {
		t.Fatalf("the claim loop must be bounded: %d links", got)
	}
}

func TestRenderShowsAnswererRecord(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rr-alice")
	testCourt(cur, "rr1", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "rr1", "Record badge claim")
	matureOI(cur, "rr1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "rr1", id, sideYES)
	out := Render("rr1/1")
	if !strings.Contains(out, "has been challenged and upheld 0 time(s) in this court") {
		t.Fatalf("the answerer record line must render:\n%s", out)
	}
	// Gate is cold (0 qualified < coldStart) → no priority line yet.
	if strings.Contains(out, "answer priority is live") {
		t.Fatal("the priority line must be hidden until the gate is armed")
	}
}

// math-audit MED-1: pct must not wrap when num is a conviction-CC value (stake×
// time, NOT bounded by supply). A whale on a long-open claim can drive
// convToCC past MaxInt64/10000; the 128-bit pct must still yield a sane ratio.
func TestPctNoOverflowAtWhaleConviction(cur realm, t *testing.T) {
	// yc near the convToCC ceiling (~7e18); a bare yc*10000 would wrap negative.
	yc := int64(7_000_000_000_000_000_000)
	if got := pct(yc, yc); got != "100.00%" {
		t.Fatalf("pct(yc,yc) must be 100%%, got %q (bare *10000 would have wrapped)", got)
	}
	// ~two-thirds split at huge magnitude stays sane, never negative.
	out := pct(2*(yc/3), yc)
	if len(out) == 0 || out[0] == '-' {
		t.Fatalf("pct must never render a negative/garbage ratio: %q", out)
	}
	// Degenerate guards.
	if pct(0, 0) != "—" || pct(-1, 10) != "—" {
		t.Fatal("pct guards den<=0 and num<0")
	}
}

// §7.4 across EVERY render path, not one word on one page. The existing coverage
// checks only the literal "backing" and only the DIRECTORY, while §7.4 forbids four
// things — backing, redeem, APR, and the inflation ceiling — and the court and claim
// pages are the ones carrying money numbers. An owner-locked constraint enforced on a
// quarter of its surface is close to unenforced.
//
// Driven through a FULL lifecycle so the pages have real figures to leak: stake, an
// answer, a flag with a conclusive tier, settle, and crystallize. A page that renders
// nothing cannot violate §7.4, so an empty-state check would prove little.
func TestNoRenderPathLeaksTheForbiddenTerms(cur realm, t *testing.T) {
	alice := testutils.TestAddress("s74-alice")
	flagger := testutils.TestAddress("s74-flag")
	voter := testutils.TestAddress("s74-voter")
	c := testCourt(cur, "s74", alice, 50_000_000_000)
	c.coin.Mint(flagger, 10_000_000_000)
	c.coin.Mint(voter, 20_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "s74", "A claim with real numbers on it")
	matureOI(cur, "s74", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "s74", id, sideYES)
	testing.SetRealm(testing.NewUserRealm(flagger))
	OpenFlag(cross(cur), "s74", id)
	testing.SetRealm(testing.NewUserRealm(voter))
	VoteQuality(cross(cur), "s74", id, qualityMid)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), "s74", id)
	SettleUndisputed(cross(cur), "s74", id)
	testing.SkipHeights(priorityWindowBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "s74", id)

	idStr := strconv.FormatUint(id, 10)
	pages := map[string]string{
		"directory": Render(""),
		"court":     Render("s74"),
		"claim":     Render("s74/" + idStr),
		"positions": Render("s74/" + idStr + "/" + alice.String()),
	}
	// Lowercased, because §7.4 is about what a reader sees, not about casing. "apr"
	// is checked as a whole word: it is a substring of ordinary English ("appraisal"),
	// and a guard that fires on those would be deleted by the next person.
	for name, body := range pages {
		if body == "" {
			t.Fatalf("%s rendered nothing, so it proves nothing about §7.4", name)
		}
		low := lowerASCII(body)
		for _, banned := range []string{"backing", "redeem", "inflation", "ceiling"} {
			if containsSub(low, banned) {
				t.Fatalf("§7.4: the %s page renders %q", name, banned)
			}
		}
		if hasWordAPR(low) {
			t.Fatalf("§7.4: the %s page renders APR", name)
		}
	}
}

// lowerASCII folds A-Z; the realm imports no strings package and §7.4 is
// case-insensitive from a reader's point of view.
func lowerASCII(s string) string {
	b := []byte(s)
	for i := 0; i < len(b); i++ {
		if b[i] >= 'A' && b[i] <= 'Z' {
			b[i] += 32
		}
	}
	return string(b)
}

// hasWordAPR finds "apr" only as a whole word, so "appraisal" does not trip it.
func hasWordAPR(s string) bool {
	for i := 0; i+3 <= len(s); i++ {
		if s[i:i+3] != "apr" {
			continue
		}
		if i > 0 && isAlnumByte(s[i-1]) {
			continue
		}
		if i+3 < len(s) && isAlnumByte(s[i+3]) {
			continue
		}
		return true
	}
	return false
}

func isAlnumByte(ch byte) bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')
}

// N3, the render's page bound, found by the audit-marker sweep. The mutation that
// removes it does not merely survive — it HANGS the suite past ten minutes, which is
// itself the finding: the bound is what stops an attacker-openable, deposit-priced claim
// count turning a page render into unbounded work. Deep links still reach anything the
// capped list omits, so the cap costs no reachability.
//
// Pinned by asserting the cap BINDS on a court with more claims than a page, rather than
// by removing the constant — a fixture that has to survive its own mutation cannot use a
// mutation that hangs.
func TestClaimListIsPageBounded(cur realm, t *testing.T) {
	alice := testutils.TestAddress("n3p-alice")
	c := testCourt(cur, "n3p", alice, 500_000_000_000)
	// The bound is written here INDEPENDENTLY of the constant. Sizing the setup from
	// renderPageSize instead made this fixture self-referential — mutating the constant
	// moved the setup and the expectation together, so the mutation survived. A
	// deliberate page-size change must now update this line, which is the point.
	const wantPage = 50
	if renderPageSize != wantPage {
		t.Fatalf("N3's page bound changed (%d, expected %d): confirm the new cost bound "+
			"is intended, then update this fixture", renderPageSize, wantPage)
	}
	over := wantPage + 5
	for i := 0; i < over; i++ {
		testing.SetRealm(testing.NewUserRealm(alice))
		OpenClaim(cross(cur), "n3p", "claim "+strconv.Itoa(i))
	}
	if c.nextID != uint64(over) {
		t.Fatalf("setup: %d claims must exist, got %d", over, c.nextID)
	}

	page := Render("n3p")
	// The court page emits ONE other link under this prefix — the moderation log
	// at :<slug>/mod — so a bare prefix count reads 51 and the cap looks breached.
	// Subtracting it is the whole correction: the prefix identifies the ROUTE, not
	// the claim list, and a route added later will surface here rather than be
	// silently counted as a claim.
	listed := countSub(page, "](/r/kourt/kourtv2:n3p/") -
		countSub(page, "](/r/kourt/kourtv2:n3p/mod)")
	if listed > wantPage {
		t.Fatalf("N3: the claim list must cap at %d entries, rendered %d",
			wantPage, listed)
	}
	if listed < wantPage {
		t.Fatalf("fixture must EXCEED one page so the cap actually binds: listed %d of %d",
			listed, over)
	}
}

// countSub counts non-overlapping occurrences; the realm imports no strings package.
func countSub(s, sub string) int {
	n, i := 0, 0
	for i+len(sub) <= len(s) {
		if s[i:i+len(sub)] == sub {
			n++
			i += len(sub)
			continue
		}
		i++
	}
	return n
}

// The front page's two curation rules, both unpinned until measured.
// TestDirectoryRanksByBurn tests the INDEX (ListedCourtsBy) and never the PAGE,
// and it even exercises the "new" ordering to prove both paginate — which is
// exactly what made the mutation invisible: both keys are valid and separately
// tested, so swapping which one writeListedByBurn passes changes nothing the
// index test looks at. A TEST OF THE PRIMITIVE DOES NOT PIN THE CALLER'S CHOICE
// OF ARGUMENT; only an assertion on the rendered page can.
func TestFrontPageRanksByBurnAndSkipsHidden(cur realm, t *testing.T) {
	a := testutils.TestAddress("fp-a")
	testCourt(cur, "fpburnhi", a, 1_000_000)
	testCourt(cur, "fpburnlo", a, 1_000_000)
	testCourt(cur, "fphidden", a, 1_000_000)
	// Burns far above anything another test sets, so all three sit inside the
	// first renderPageSize rows of the burn-ordered index and what follows is
	// about ORDER rather than about pagination.
	reindexBurn(mustCourt("fpburnhi"), 900_000_000_000)
	reindexBurn(mustCourt("fphidden"), 850_000_000_000)
	reindexBurn(mustCourt("fpburnlo"), 800_000_000_000)

	// tierHidden is curation, not custody: the court still works for anyone
	// holding its address, it just leaves the directory. SetTier is a global-DAO
	// power, and DirectoryAdmin() must be read AFTER a court exists or it is the
	// zero address — which is a silent no-op rather than a refusal.
	dadmin := DirectoryAdmin()
	if dadmin == "" {
		t.Fatal("the directory admin must exist before SetTier can be called")
	}
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetTier(cross(cur), "fphidden", int(tierHidden))
	// A FEATURED court is the case the in-loop tier check actually protects.
	// listedPage already drops tierHidden before writeListedByBurn ever sees a
	// row, so hidden cannot reach that check — but it lets tierFeatured through,
	// and the check is what keeps a featured court out of the plain list where it
	// would appear a second time under its own section. Probing with hidden alone
	// measures listedPage and leaves this guard untouched.
	testCourt(cur, "fpfeat", a, 1_000_000)
	reindexBurn(mustCourt("fpfeat"), 870_000_000_000)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetTier(cross(cur), "fpfeat", int(tierFeatured))

	page := Render("")
	hi := strings.Index(page, "fpburnhi")
	lo := strings.Index(page, "fpburnlo")
	if hi < 0 || lo < 0 {
		t.Fatalf("both listed courts must appear on the front page: hi=%d lo=%d", hi, lo)
	}
	if hi > lo {
		t.Fatal("the front page must rank by GNOT burn DESCENDING, so the higher-burn court comes first")
	}
	// The hidden court out-burns the lower one, so under burn ordering alone it
	// would sit BETWEEN the two above. Its absence is therefore about the tier
	// and not about pagination or about where it would have landed.
	if strings.Contains(page, "fphidden") {
		t.Fatal("a hidden court must not appear in the front-page directory")
	}
	// The featured court IS on the page — renderDirectory writes "## Featured"
	// before "## Courts" — so its absence has to be asserted against the plain
	// section alone, not the whole page. Everything from "## Courts" to the end
	// IS that section, because it is written last.
	if !strings.Contains(page, "fpfeat") {
		t.Fatal("a featured court must still appear on the front page, in its own section")
	}
	plain := page[strings.Index(page, "## Courts"):]
	if strings.Contains(plain, "fpfeat") {
		t.Fatal("a featured court must not ALSO be listed in the plain ## Courts section")
	}
	// ...and the two listed courts are in that section, so the assertion above is
	// about the tier and not about a section that turned out to be empty.
	if !strings.Contains(plain, "fpburnhi") || !strings.Contains(plain, "fpburnlo") {
		t.Fatal("both listed courts belong in the plain ## Courts section")
	}
}

// §7.4 swept across claim STATES, which the existing sweep cannot reach.
//
// TestNoRenderPathLeaksTheForbiddenTerms above already walks all four render paths, so
// the pages themselves are covered. What it cannot cover is the STATE it renders them in:
// it drives one claim through its whole life and reads the pages at the END, after
// Crystallize. renderClaim branches on state, and several of those branches exist ONLY
// before that point — the flag-slot line, the counter-re-vote line, the escrowed-slash
// line. Copy on any of them is invisible to a sweep taken at the end.
//
// Measured, not assumed: injecting "backing" into the flag-slot branch — reachable only
// while `!crystallized && !slotConsumed && !provClose` — is caught HERE and not by the
// sweep above.
//
// "ceiling" is included though §7.4 names only the inflation ceiling: a bare "ceiling" in
// public copy is the same disclosure by a shorter name, and the four pages were checked
// to confirm no legitimate copy uses the word.
func TestNoRenderSurfaceLeaksTheForbiddenVocabulary(cur realm, t *testing.T) {
	forbidden := []string{"backing", "redeem", "apr", "inflation", "ceiling"}
	alice := testutils.TestAddress("r74-alice")
	bob := testutils.TestAddress("r74-bob")
	c := testCourt(cur, "r74", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "r74", "a claim to render")
	matureOI(cur, "r74", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "r74", id, sideNO, 300_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "r74", id, sideYES)

	sweep := func(state string) {
		t.Helper()
		paths := []string{"", "r74", "r74/" + strconv.FormatUint(id, 10),
			"r74/" + strconv.FormatUint(id, 10) + "/" + bob.String()}
		for _, p := range paths {
			out := strings.ToLower(Render(p))
			if len(out) == 0 {
				t.Fatalf("%s: path %q rendered nothing, so this sweep proves nothing "+
					"about it", state, p)
			}
			for _, w := range forbidden {
				if strings.Contains(out, w) {
					t.Fatalf("%s: path %q renders the forbidden term %q (§7.4)",
						state, p, w)
				}
			}
		}
	}

	// Every state a reader can arrive at a page in: live, settled, and drawn.
	sweep("answered")
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "r74", id)
	sweep("settled")
	testing.SkipHeights(100_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "r74", id)
	sweep("crystallized")
}

// No user string can open page structure of its own, on ANY page.
//
// A court name and a claim title are free text from whoever creates them and
// NEITHER is validated at the door: StartCourt stores `name` unchecked and
// OpenClaim stores `title` the same way. The render-time sanitizer is the only
// thing between them and the page — and four of its five call sites had nothing
// holding them, so a name could add a heading and a list row of its own to the
// directory, to the court page, and to the positions page.
//
// The payload is what an attacker would actually write: a forged verdict line
// under a heading that looks like the realm's own.
func TestNoUserStringOpensStructureOnAnyPage(cur realm, t *testing.T) {
	const inject = "x\n## Ratified by the foundation\n- verdict: YES"
	who := testutils.TestAddress("inj-a")
	testing.SetRealm(testing.NewUserRealm(who))
	StartCourt(cross(cur), "aaa-inj", inject)
	c := mustCourt("aaa-inj")
	c.coin.Mint(who, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(who))
	id := OpenClaim(cross(cur), "aaa-inj", inject)

	pages := []string{
		Render(""),                              // the directory: the court name
		Render("aaa-inj"),                          // the court page: the name and the title
		Render("aaa-inj/" + strconv.FormatUint(id, 10)),
		Render("aaa-inj/" + strconv.FormatUint(id, 10) + "/" + who.String()),
	}
	if !strings.Contains(pages[0], "/r/kourt/kourtv2:aaa-inj)") {
		t.Fatal("setup: the injecting court is not on the directory page, so the " +
			"directory arm below would prove nothing — the list is capped at " +
			"renderPageSize per tier and this suite creates many courts, which is " +
			"why the slug is chosen to sort first")
	}
	for i, page := range pages {
		if strings.Contains(page, "\n## Ratified") {
			t.Errorf("page %d: a user string opened a heading of its own:\n%s", i, page)
		}
		if strings.Contains(page, "\n- verdict: YES") {
			t.Errorf("page %d: a user string opened a list row of its own:\n%s", i, page)
		}
	}
}

// claimStatus names every phase, and the precedence between them.
//
// The states are set outright rather than driven through the lifecycle: this is
// the RENDERER under test, and reaching six phases through the machine would test
// the machine six times and the renderer once.
//
// The sharpest of these is the provisional line. sideYES is ZERO, so the guard has
// to be `provisional >= 0`; written `> 0` a provisional YES verdict falls through
// and the page reports the claim as merely answered — hiding both the escrow
// window it can be reopened in and the losing side's right to withdraw now.
func TestTheClaimStatusNamesEveryPhase(cur realm, t *testing.T) {
	who := testutils.TestAddress("cst-a")
	c := testCourt(cur, "cst1", who, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(who))
	id := OpenClaim(cross(cur), "cst1", "every phase")
	cs := mustClaim(c, id)

	if got := claimStatus(cs); !strings.Contains(got, "open — stake") {
		t.Errorf("a fresh claim reads %q", got)
	}
	cs.frozenAt, cs.answerHeight = 100, 100
	if got := claimStatus(cs); !strings.Contains(got, "answered — staking frozen") {
		t.Errorf("an answered claim reads %q", got)
	}
	cs.provisional, cs.escrowUntil = sideYES, 500
	if got := claimStatus(cs); !strings.Contains(got, "provisional verdict YES") {
		t.Errorf("a provisional YES verdict reads %q — sideYES is zero, so a bar "+
			"written `> 0` hides this whole phase", got)
	}
	cs.disputeOpen = true
	if got := claimStatus(cs); !strings.Contains(got, "disputed") {
		t.Errorf("an open dispute reads %q", got)
	}
	cs.disputeOpen = false
	cs.verdictAt = 200
	if got := claimStatus(cs); !strings.Contains(got, "settled") {
		t.Errorf("a settled claim reads %q", got)
	}
	cs.provClose = true
	if got := claimStatus(cs); !strings.Contains(got, "closed without a decision") {
		t.Errorf("a claim closed without a decision reads %q", got)
	}
	cs.provClose = false
	cs.closed = true
	if got := claimStatus(cs); !strings.Contains(got, "closed — never answered") {
		t.Errorf("a closed claim reads %q — dropped, it invites staking on a claim "+
			"that can never be answered", got)
	}
}

// The two names a verdict page turns on. sideName decides what the verdict SAYS,
// and it had nothing on it: every side rendering as NO is a page that reports the
// opposite outcome on every YES claim in the realm.
func TestSideAndTierNamesAreNotSwapped(t *testing.T) {
	if got := sideName(sideYES); got != "YES" {
		t.Errorf("sideYES renders as %q", got)
	}
	if got := sideName(sideNO); got != "NO" {
		t.Errorf("sideNO renders as %q", got)
	}
	if got := tierName(tierLowX); got != "low" {
		t.Errorf("tierLowX renders as %q", got)
	}
	if got := tierName(tierHighX); got != "high" {
		t.Errorf("tierHighX renders as %q", got)
	}
	if got := tierName(tierMidX); got != "mid" {
		t.Errorf("tierMidX renders as %q", got)
	}
}

// An escrowed slash is announced, found surviving. Without the line the page falls
// through to the flag-slot row and OFFERS a slot whose bond is already committed
// elsewhere — it invites a user to pay for something the claim is not in a state
// to sell.
func TestAnEscrowedSlashIsAnnounced(cur realm, t *testing.T) {
	who := testutils.TestAddress("esl-a")
	c := testCourt(cur, "esl1", who, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(who))
	id := OpenClaim(cross(cur), "esl1", "an escrowed slash")
	cs := mustClaim(c, id)
	cs.frozenAt, cs.answerHeight, cs.answerBond0 = 100, 100, 1000
	cs.pendingSlash = 500

	page := Render("esl1/" + strconv.FormatUint(id, 10))
	if !strings.Contains(page, "slash is escrowed") {
		t.Errorf("the page does not mention the escrowed slash:\n%s", page)
	}
	if strings.Contains(page, "anyone may challenge that rating") {
		t.Errorf("the page offers a quality challenge while a slash is escrowed:\n%s", page)
	}
}

// The DIRECTORY's N3 page bound, which was unheld while its twin on the claims
// list was already covered by TestRenderCourtPaginatesClaims.
//
// The bound is on the WORK, not the output: a court list that grows with an
// attacker-openable, deposit-priced count makes the cost of the page every user
// reads grow with it. Deep links reach whatever the cap omits, which is what makes
// capping it safe rather than lossy.
//
// It creates only as many courts as it needs to cross the cap, and asserts it HAS
// crossed it. The first version created 51 outright and tripled the mutation
// batch's wall clock — 51 ledger allocations on every one of 673 runs — for a
// property that only needs the population to exceed renderPageSize by one.
func TestTheDirectoryListIsBounded(t *testing.T) {
	if renderPageSize != 50 {
		t.Fatalf("renderPageSize is %d; this test reasons about its exact value", renderPageSize)
	}
	// Registered directly rather than through StartCourt. writeTier reads only a
	// court's name and claim count, and StartCourt allocates a whole ledger per
	// court — which the mutation batch then pays for on all 673 runs. Constructing
	// what the renderer actually reads is both cheaper and narrower.
	for i := len(ListByTier(int(tierListed))); i <= renderPageSize; i++ {
		slug := "n3dir" + strconv.Itoa(i)
		courts.Set(slug, &Court{id: slug, name: "dir court " + strconv.Itoa(i), tier: tierListed})
	}
	listed := len(ListByTier(int(tierListed)))
	if listed <= renderPageSize {
		t.Fatalf("setup: %d listed courts does not exceed the %d-row cap, so nothing "+
			"below can discriminate", listed, renderPageSize)
	}

	dir := Render("")
	if n := strings.Count(dir, "](/r/kourt/kourtv2:"); n > 2*renderPageSize {
		t.Errorf("the directory rendered %d rows across its two tiers, past the "+
			"%d-per-tier bound", n, renderPageSize)
	}
	if !strings.Contains(dir, "more; open any court directly") {
		t.Errorf("the directory does not say what it omitted:\n%s", dir)
	}

	// ---- the FEATURED tier, which is the arm writeTier actually serves -------
	// Everything above registers tierLISTED courts, and v0.49 moved the listed
	// tier to burn-ranking in writeListedByBurn — leaving writeTier serving
	// FEATURED alone. So this test stopped reaching writeTier's bound at all, and
	// a mutation making that bound unbounded survived a full 843-row batch: the
	// test kept passing under a name that had stopped describing what it measured.
	for i := len(ListByTier(int(tierFeatured))); i <= renderPageSize; i++ {
		slug := "n3feat" + strconv.Itoa(i)
		courts.Set(slug, &Court{
			id: slug, name: "feat court " + strconv.Itoa(i), tier: tierFeatured,
			// writeTier renders qualifiedSymbol, so unlike the listed loop above
			// these need a coin: it iterates ListByTier directly, while
			// writeListedByBurn pages a burn index nothing here is in. A bare
			// Ledger is the whole requirement — no governor, curve or claim book.
			coin: grc20votes.NewLedger(slug, courtSymbol(slug), coinDecimals, epochBlocks),
		})
	}
	if featured := len(ListByTier(int(tierFeatured))); featured <= renderPageSize {
		t.Fatalf("setup: %d featured courts does not exceed the %d-row cap, so "+
			"nothing below can discriminate", featured, renderPageSize)
	}

	// writeTier's OWN section, isolated. Counting the whole page cannot pin this:
	// the listed tier is capped too, so a page-wide count stays under its bound
	// even with writeTier unbounded. writeTier writes "## Featured";
	// writeListedByBurn writes "## Courts" after it.
	dir = Render("")
	fstart, fend := strings.Index(dir, "## Featured"), strings.Index(dir, "## Courts")
	if fstart < 0 || fend <= fstart {
		t.Fatalf("both tier sections must be present for this to measure writeTier:\n%s", dir)
	}
	feat := dir[fstart:fend]
	if n := strings.Count(feat, "](/r/kourt/kourtv2:"); n > renderPageSize {
		t.Errorf("the featured tier rendered %d rows, past its own %d-row bound", n, renderPageSize)
	}
	if !strings.Contains(feat, "more; open any court directly") {
		t.Errorf("the featured tier does not say what it omitted:\n%s", feat)
	}
}

// An OPEN counter re-vote is announced and its tally sealed, found surviving —
// the flag-vote line beside it was held and this one was not. Same failure: the
// page falls through and offers a flag slot while a re-vote is running.
func TestAnOpenCounterReVoteIsAnnounced(cur realm, t *testing.T) {
	who := testutils.TestAddress("ocr-a")
	c := testCourt(cur, "ocr1", who, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(who))
	id := OpenClaim(cross(cur), "ocr1", "an open counter re-vote")
	cs := mustClaim(c, id)
	cs.frozenAt, cs.answerHeight, cs.answerBond0 = 100, 100, 1000
	cs.counterOpen = true

	page := Render("ocr1/" + strconv.FormatUint(id, 10))
	if !strings.Contains(page, "counter re-vote open") {
		t.Errorf("the page does not announce the open counter re-vote:\n%s", page)
	}
	if strings.Contains(page, "flag slot open") {
		t.Errorf("the page offers a flag slot during a counter re-vote:\n%s", page)
	}
}

// Render's path handling: the shapes it accepts and the ones it must refuse.
//
// Three legs were unheld. The TRIM is what makes a leading slash work at all, and
// without it every "/slug" link lands on "no court by that slug". A FOURTH
// SEGMENT has to be refused rather than folded into the address — that used to be
// SplitN's cap of three doing the work, and since the board's per-row deep link
// needs a fourth segment the cap is four and an explicit arm refuses the shapes
// that are not a board row. The assertion below is unchanged and the reason under
// it is not. And a non-numeric id has to be refused as one rather than falling
// through as id zero.
func TestRenderAcceptsAndRefusesEveryPathShape(cur realm, t *testing.T) {
	who := testutils.TestAddress("rp-a")
	testCourt(cur, "rps1", who, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(who))
	id := OpenClaim(cross(cur), "rps1", "path shapes")
	sid := strconv.FormatUint(id, 10)

	// A leading or trailing slash names the same page as none.
	if Render("/rps1") != Render("rps1") {
		t.Errorf("a leading slash changes the court page:\n%s", Render("/rps1"))
	}
	if Render("rps1/"+sid+"/") != Render("rps1/"+sid) {
		t.Error("a trailing slash changes the claim page")
	}
	// A claim id that is not a number is refused as that, not as a missing claim.
	if got := Render("rps1/notanumber"); !strings.Contains(got, "must be a number") {
		t.Errorf("a non-numeric id renders %q", got)
	}
	// A fourth segment that is not a board row is refused. It is no longer the
	// SplitN cap that does this — see the note above the function.
	if got := Render("rps1/" + sid + "/" + who.String() + "/extra"); !strings.Contains(got, "Not found") {
		t.Errorf("a fourth path segment rendered a page:\n%s", got)
	}
	// AND A FIFTH, which is a different guard now. The SplitN cap is what folds
	// everything past the fourth segment INTO parts[3], so the arm above sees
	// one over-long argument and refuses it. Unbound the split and a five-segment
	// path falls past every length arm to renderClaim — the claim page served for
	// a URL nobody wrote, with the tail silently ignored. That mutant survived
	// until this line existed.
	for _, p := range []string{
		"rps1/" + sid + "/" + who.String() + "/extra/more",
		"rps1/" + sid + "/board/1/extra",
	} {
		if got := Render(p); !strings.Contains(got, "Not found") {
			t.Errorf("a five-segment path %q rendered a page:\n%s", p, got)
		}
	}
}

// THE WALLET PANEL WITH A VOTE LOCK ON IT, which is the only state where its two
// "free" figures differ — and therefore the only state where the page can be wrong
// about which gate binds.
//
// FOUND BY TWO SURVIVING MUTANTS. Splitting "free to commit" into "free to stake"
// (spendable, what mustStakable allows) and "free to bond, deposit or transfer"
// (disposable, which nets the vote lock too) came with three mutation rows. Two
// survived the whole suite: swapping disposable for spendable, and zeroing the vote
// commitment. Both are invisible in a fixture where nobody has voted, because there
// the two figures are equal and the commitment is zero — so the existing positions
// test could not see either. A row that survives is the corpus reporting missing
// coverage, and this is the coverage.
func TestTheWalletPanelSeparatesTheTwoGates(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rpg-alice")
	whale := testutils.TestAddress("rpg-whale")
	voter := testutils.TestAddress("rpg-voter")
	c := testCourt(cur, "rpg", alice, 40_000_000_000)
	c.coin.Mint(whale, 60_000_000_000)
	c.coin.Mint(voter, 10_000_000_000)

	// A stake AND a vote, on different claims, so both locks are live at once and
	// neither figure is the other by accident.
	other := stakeAnswerDispute(cur, "rpg", alice, whale)
	testing.SetRealm(testing.NewUserRealm(alice))
	fresh := OpenClaim(cross(cur), "rpg", "Something to stake on")
	testing.SetRealm(testing.NewUserRealm(voter))
	Stake(cross(cur), "rpg", fresh, sideYES, 1_000_000_000)
	testing.SetRealm(testing.NewUserRealm(whale))
	OpenDispute(cross(cur), "rpg", other)
	testing.SetRealm(testing.NewUserRealm(voter))
	VoteDispute(cross(cur), "rpg", other, "no")

	bal := c.coin.BalanceOf(voter)
	staked := lockedOf(c, voter)
	voted := VoteLockedOf("rpg", voter)
	free1 := spendable(c, voter)
	free2 := disposable(c, voter)
	// The instrument's own precondition: the two gates must actually disagree here,
	// or the assertions below would pass against a page that printed one number
	// twice — which is the bug this test exists for.
	if staked <= 0 || voted <= staked || free2 >= free1 {
		t.Fatalf("fixture is vacuous: need a live stake (%d) below a larger vote "+
			"commitment (%d) so the free figures differ (%d vs %d)",
			staked, voted, free1, free2)
	}

	out := Render("rpg/" + itoa(int64(other)) + "/" + voter.String())
	for _, want := range []string{
		"held: " + itoa(bal),
		"committed as stake: " + itoa(staked),
		"committed by voting: " + itoa(voted),
		"free to stake: " + itoa(free1),
		"free to bond, deposit or transfer: " + itoa(free2),
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("the wallet panel must show %q:\n%s", want, out)
		}
	}

	// BOTH PARTITIONS, which is what stops the page printing plausible numbers that
	// do not add up. The locks OVERLAP rather than stack — staked coin still votes —
	// so the second is a max, not a sum.
	if staked+free1 != bal {
		t.Fatalf("stake partition broken: committed %d + free-to-stake %d != "+
			"held %d", staked, free1, bal)
	}
	most := staked
	if voted > most {
		most = voted
	}
	if most+free2 != bal {
		t.Fatalf("disposal partition broken: max(stake %d, voting %d) + "+
			"free-to-dispose %d != held %d — the locks OVERLAP, so this is a max "+
			"and not a sum", staked, voted, free2, bal)
	}
}

// TestBothSettleRoutesNameTheVerdictSide drives a claim to a verdict on EACH of
// the two real routes and reads the status back, because claimStatus's settled
// line renders sideName(cs.provisional) and the arm above it sets that field by
// hand. Crafted state proves the sentence is formatted; it cannot prove the
// routes fill the field in. If a future terminal path sets verdictAt and forgets
// provisional, the status silently reads "settled —" and nothing else notices —
// sideName has no error value, and every other assertion about a settled claim
// is about its money.
//
// The status is checked AGAINST Verdict(), not against a literal side, so the
// test states the property that matters — the one-line status and the read agree
// about what was decided — on whichever side the route happens to produce.
func TestBothSettleRoutesNameTheVerdictSide(cur realm, t *testing.T) {
	check := func(route, slug string, id uint64) {
		st := ClaimStatus(slug, id)
		want := "settled " + sideName(Verdict(slug, id))
		if !strings.HasPrefix(st, want) {
			t.Fatalf("%s route: status %q does not start with %q", route, st, want)
		}
		// The shape of the bug this closes, named directly: the em-dash clause
		// following "settled" with no side in between.
		if strings.HasPrefix(st, "settled —") {
			t.Fatalf("%s route: the settled status names no side: %q", route, st)
		}
	}

	alice := testutils.TestAddress("vsd-alice")
	bob := testutils.TestAddress("vsd-bob")

	c := testCourt(cur, "vsd1", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	check("undisputed", "vsd1", settledClaim(cur, c, "vsd1", alice, bob))

	c2 := testCourt(cur, "vsd2", alice, 50_000_000_000)
	c2.coin.Mint(bob, 10_000_000_000)
	id2 := parkedClaim(cur, c2, "vsd2", alice, bob)
	testing.SetRealm(testing.NewUserRealm(bob)) // a participant: Finalize is theirs first
	Finalize(cross(cur), "vsd2", id2)
	check("vote", "vsd2", id2)
}
