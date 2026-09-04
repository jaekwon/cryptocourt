package kourtv2

import (
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// ClaimHead exists to be ONE query where the overlay asked thirty-eight, so the
// property that matters is not that it returns a string — it is that every
// column equals what the single reader would have said. A packed reader that
// drifts is worse than the queries it saved: the page would draw a bond, a
// deadline or a verdict that the claim page's own buttons contradict.
//
// It is written as a composition of those readers for exactly this reason, and
// this test is what holds that claim true after somebody edits one of them.
func headFields(slug string, id uint64, window int64) []string {
	return strings.Split(ClaimHead(slug, id, window), "\t")
}

func TestClaimHeadAgreesWithEveryReaderItReplaces(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ch-alice")
	bob := testutils.TestAddress("ch-bob")
	testCourt(cur, "ch", alice, 40_000_000_000)
	c := mustCourt("ch")
	c.coin.Mint(bob, 40_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "ch", "a claim to answer and dispute")
	// matureOI is answer_test's own helper: PostAnswer refuses until the claim
	// carries enough stake HISTORY, not merely enough stake, so the position has
	// to be built across epochs rather than in one block.
	matureOI(cur, "ch", id, alice, 4_000_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "ch", id, sideNO, 1_000_000_000)
	testing.SkipHeights(priorityWindowBlocks + answerWindow)
	testing.SetRealm(testing.NewUserRealm(bob))
	PostAnswer(cross(cur), "ch", id, sideYES)

	const window = int64(120960)
	f := headFields("ch", id, window)
	if len(f) != claimHeadFields {
		t.Fatalf("want %d columns, got %d: %q", claimHeadFields, len(f), ClaimHead("ch", id, window))
	}

	yes, no := StakePools("ch", id)
	cy, cn := PoolConviction("ch", id)
	oi, oiM := TrailingOI("ch", id, window)
	ty, tyM := TrailingYes("ch", id, window)
	who := Answerer("ch", id)
	want := []string{
		strconv.FormatInt(yes, 10), strconv.FormatInt(no, 10),
		strconv.FormatInt(cy, 10), strconv.FormatInt(cn, 10),
		strconv.FormatInt(oi, 10), boolDigit(oiM),
		strconv.FormatInt(ty, 10), boolDigit(tyM),
		boolDigit(HasAnswer("ch", id)), boolDigit(DisputeOpen("ch", id)),
		boolDigit(Settled("ch", id)), boolDigit(ProvClose("ch", id)),
		strconv.Itoa(Provisional("ch", id)), boolDigit(ClaimClosed("ch", id)),
		strconv.Itoa(AnswerVerdict("ch", id)), strconv.FormatInt(AnswerBond("ch", id), 10),
		strconv.FormatInt(SettleDeadline("ch", id), 10), who.String(),
		strconv.Itoa(AnswerRecord("ch", who)),
		strconv.FormatInt(FailedRounds("ch", id), 10),
		strconv.FormatInt(DisputeBondNext("ch", id), 10),
		strconv.FormatInt(EscrowUntil("ch", id), 10),
		"0", "0", // quorum and vote-close: no dispute is open on this fixture
		"-1", "", // verdict and route: not settled
		boolDigit(RewardsOpened("ch", id)), "0", "0", "0", "0",
		ClaimAuthor("ch", id).String(),
		boolDigit(HiddenFromListing("ch", id)), boolDigit(TextRedacted("ch", id)),
		boolDigit(ClaimPurged("ch", id)), boolDigit(ClaimSeeded("ch", id)),
		strconv.FormatInt(CourtStakeOpenDelay("ch"), 10),
		strconv.Itoa(BoardSize("ch", id)), boolDigit(BoardOpen("ch", id)),
	}
	for k := range want {
		if f[k] != want[k] {
			t.Fatalf("column %d: packed %q, the single reader says %q", k, f[k], want[k])
		}
	}
	// and the fixture is not all zeroes, or the comparison above proves nothing
	if f[0] == "0" || f[8] != "1" {
		t.Fatal("the fixture staked and answered nothing — agreement is vacuous")
	}
}

// A CLAIM WITH NO ANSWER STILL ANSWERS WITH EVERY COLUMN. A record whose width
// depends on its content is one a client has to parse twice, and the second
// parse is where a field lands in the wrong variable.
func TestClaimHeadIsAlwaysTheSameWidth(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ch2-alice")
	testCourt(cur, "ch2", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	bare := OpenClaim(cross(cur), "ch2", "nobody has answered this")

	f := headFields("ch2", bare, int64(120960))
	if len(f) != claimHeadFields {
		t.Fatalf("an unanswered claim answers %d columns, want %d", len(f), claimHeadFields)
	}
	if f[8] != "0" {
		t.Fatalf("answered should be 0 on a claim nobody answered: %q", f[8])
	}
	// the answer block is zeroed, not absent
	if f[14] != "-1" || f[15] != "0" || f[17] != "" {
		t.Fatalf("the answer block should be zero on an unanswered claim: %q", f[14:18])
	}
	// and the author is still there — it is not part of the answer block
	if f[31] != ClaimAuthor("ch2", bare).String() || f[31] == "" {
		t.Fatalf("the author is missing from an unanswered claim: %q", f[31])
	}
}

// It refuses a claim this court does not have, exactly as the single readers do.
// Answering zeroes for a claim that is not there would let a client draw a page
// for something that does not exist.
func TestClaimHeadRefusesAClaimThatIsNotThere(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ch3-alice")
	testCourt(cur, "ch3", alice, 10_000_000_000)
	// PanicsContains, not AbortsContains: ClaimHead is a plain read, not a
	// crossing function, so it panics where a transaction would abort.
	uassert.PanicsContains(t, cur, "no such claim", func() { ClaimHead("ch3", 999, int64(120960)) })
	uassert.PanicsContains(t, cur, "no such court", func() { ClaimHead("nosuchcourt", 1, int64(120960)) })
}

// NO COLUMN MAY CONTAIN THE SEPARATOR. Every free-text field was deliberately
// left out of this record; the ones that remain are numbers, flags, addresses
// and a short route word. If one of them ever carries a tab, every column after
// it shifts by one and the page draws the wrong numbers with no error anywhere.
func TestClaimHeadCarriesNoTabsInsideAField(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ch4-alice")
	bob := testutils.TestAddress("ch4-bob")
	testCourt(cur, "ch4", alice, 20_000_000_000)
	mustCourt("ch4").coin.Mint(bob, 20_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "ch4", "a claim whose title has\ttabs and\nnewlines in it")
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "ch4", id, sideYES, 1_000_000_000)

	got := ClaimHead("ch4", id, int64(120960))
	if strings.Count(got, "\t") != claimHeadFields-1 {
		t.Fatalf("a title's tabs reached the record: %d separators, want %d",
			strings.Count(got, "\t"), claimHeadFields-1)
	}
	if strings.Contains(got, "\n") {
		t.Fatalf("the record must be one line: %q", got)
	}
}
