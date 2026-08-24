package kourtv2

import (
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// inbound is the ClaimAssociations row a single incoming edge makes, built from the
// ids the fixture actually handed out rather than from the "1" a fresh court
// happens to start at — claim ids are not reset between tests in this package.
func inbound(from uint64, code string) string {
	return "in:" + strconv.FormatUint(from, 10) + ":" + code
}

// The association bond, and the four things about it worth pinning: who does not
// pay, that a disapproval BURNS, that an unjudged bond comes back, and that the
// figure is settable in two places.
//
// WHY A BOND EXISTS AT ALL is association.gno's own note. What these tests hold is
// the property that keeps it on the right side of COURTS_STRUCTURE.md §5:
// anybody may still attach an edge, and an honest stranger is out the money only
// until somebody looks at it.

func bondFixture(cur realm, t *testing.T, slug string) (*Court, address, address, []uint64) {
	t.Helper()
	author := testutils.TestAddress(slug + "-au")
	stranger := testutils.TestAddress(slug + "-st")
	c := testCourt(cur, slug, author, 50_000_000_000)
	ids := make([]uint64, 0, 2)
	for i := 0; i < 2; i++ {
		testing.SetRealm(testing.NewUserRealm(author))
		ids = append(ids, OpenClaim(cross(cur), slug, "claim "+strings.Repeat("y", i+1)))
	}
	// Enough for several bonds, so a refusal is never about the balance.
	c.coin.Mint(stranger, AssociationBond(slug)*4)
	return c, author, stranger, ids
}

// NOBODY ACCOUNTABLE PAYS. The asserting claim's author has a deposited claim
// behind their name and a moderator is answerable by election, so neither is
// priced — and the test asserts on the BALANCE rather than on the absence of a
// panic, because "it did not refuse me" would also pass if the bond were zero.
//
// THE TWO ROLES ARE HELD BY DIFFERENT ADDRESSES ON PURPOSE, and that is the whole
// reason this test is shaped the way it is. Written the obvious way — the fixture
// author, who is also the court creator and therefore its first moderator — it
// passed while proving only ONE exemption, because the moderator branch alone
// carried both assertions. The corpus row that charges the author survived
// against that version. Here the creator moderates and authors nothing, and the
// poster authors both claims and moderates nothing, so each branch is the only
// thing standing between its caller and a bill.
func TestAnAuthorAndAModeratorPayNoAssociationBond(cur realm, t *testing.T) {
	mod := testutils.TestAddress("bond1-mod")
	poster := testutils.TestAddress("bond1-poster")
	c := testCourt(cur, "bond1", mod, 50_000_000_000)
	c.coin.Mint(poster, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(poster))
	a := OpenClaim(cross(cur), "bond1", "The poster's first claim")
	testing.SetRealm(testing.NewUserRealm(poster))
	b := OpenClaim(cross(cur), "bond1", "The poster's second claim")

	// The asserting claim's own author, who moderates nothing.
	before := c.coin.BalanceOf(poster)
	testing.SetRealm(testing.NewUserRealm(poster))
	AddAssociation(cross(cur), "bond1", a, b, "supports")
	uassert.Equal(t, before, c.coin.BalanceOf(poster))

	// A moderator, who authored neither claim.
	modBefore := c.coin.BalanceOf(mod)
	testing.SetRealm(testing.NewUserRealm(mod))
	AddAssociation(cross(cur), "bond1", b, a, "contests")
	uassert.Equal(t, modBefore, c.coin.BalanceOf(mod))
}

// A DISAPPROVAL BURNS, and the supply is where that shows. Removing the edge
// alone would be indistinguishable from RemoveAssociation; the burn is the part that
// costs a griefer something, so it is asserted against TotalSupply rather than
// against the escrow, which a refund would also empty.
func TestDisapprovingAnAssociationBurnsTheBondAndDropsTheEdge(cur realm, t *testing.T) {
	c, author, stranger, ids := bondFixture(cur, t, "bond2")
	bond := AssociationBond("bond2")

	testing.SetRealm(testing.NewUserRealm(stranger))
	AddAssociation(cross(cur), "bond2", ids[0], ids[1], "contests")
	uassert.True(t, strings.Contains(ClaimAssociations("bond2", ids[1]), inbound(ids[0], "c")))
	supplyWithBond := c.coin.TotalSupply()

	// NEITHER VERB IS THE POSTER'S. Approval that the bonded party could grant
	// themselves is decorative, and a stranger who could disapprove would burn
	// other people's bonds for sport — the same griefing the bond exists to price,
	// one level up.
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "not a moderator of this court", func() {
		ApproveAssociation(cross(cur), "bond2", ids[0], ids[1])
	})
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "not a moderator of this court", func() {
		DisapproveAssociation(cross(cur), "bond2", ids[0], ids[1])
	})
	uassert.Equal(t, supplyWithBond, c.coin.TotalSupply())

	testing.SetRealm(testing.NewUserRealm(author)) // the creator moderates
	DisapproveAssociation(cross(cur), "bond2", ids[0], ids[1])

	uassert.Equal(t, supplyWithBond-bond, c.coin.TotalSupply())
	uassert.False(t, strings.Contains(ClaimAssociations("bond2", ids[1]), inbound(ids[0], "c")))
	// And the money cannot be burned twice: the edge is gone, so the second call
	// has nothing to find.
	testing.SetRealm(testing.NewUserRealm(author))
	uassert.AbortsContains(t, cur, "no such association", func() {
		DisapproveAssociation(cross(cur), "bond2", ids[0], ids[1])
	})
}

// UNJUDGED MEANS APPROVED. A moderator who never looks must not become a
// confiscation engine, so the author may take the bond back once the window has
// closed — and not one second before.
//
// The window is set FORWARD by stamping the edge rather than by skipping 242,000
// blocks: height is shared across every test in this package, and a skip that
// large has broken unrelated fixtures here before.
func TestAnUnjudgedAssociationBondComesBackAfterTheWindow(cur realm, t *testing.T) {
	c, _, stranger, ids := bondFixture(cur, t, "bond3")
	bond := AssociationBond("bond3")
	before := c.coin.BalanceOf(stranger)

	testing.SetRealm(testing.NewUserRealm(stranger))
	AddAssociation(cross(cur), "bond3", ids[0], ids[1], "supports")
	uassert.Equal(t, before-bond, c.coin.BalanceOf(stranger))

	// Too early.
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "has not closed yet", func() {
		ClaimAssociationBond(cross(cur), "bond3", ids[0], ids[1])
	})

	e := mustAssocEdge(c, ids[0], ids[1])
	uassert.Equal(t, bond, e.bond)
	e.bondUntil = nowTime() - 1 // the window has closed

	// ...and not by anybody else, even now.
	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("bond3-nobody")))
	uassert.AbortsContains(t, cur, "only the edge's author", func() {
		ClaimAssociationBond(cross(cur), "bond3", ids[0], ids[1])
	})

	testing.SetRealm(testing.NewUserRealm(stranger))
	ClaimAssociationBond(cross(cur), "bond3", ids[0], ids[1])
	uassert.Equal(t, before, c.coin.BalanceOf(stranger))
	// The EDGE survives the refund. The bond was a deposit against griefing, not
	// a fee for the assertion, so taking it back does not retract what was said.
	uassert.True(t, strings.Contains(ClaimAssociations("bond3", ids[1]), inbound(ids[0], "s")))
	// And it cannot be drawn twice.
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "no bond is held", func() {
		ClaimAssociationBond(cross(cur), "bond3", ids[0], ids[1])
	})
}

// TWO PLACES, and which one wins. A court's override beats the realm default;
// clearing it with 0 falls back. Both setters are gated, and on different
// authorities — the realm admin for the default, an active court moderator for
// the override.
func TestTheAssociationBondIsSetInTwoPlaces(cur realm, t *testing.T) {
	_, author, stranger, _ := bondFixture(cur, t, "bond4")
	base := AssociationBondDefault()

	// The court starts on the realm default.
	uassert.Equal(t, base, AssociationBond("bond4"))

	// A moderator overrides it for this court only.
	testing.SetRealm(testing.NewUserRealm(author))
	SetCourtAssociationBond(cross(cur), "bond4", 7_777)
	uassert.Equal(t, int64(7_777), AssociationBond("bond4"))
	uassert.Equal(t, base, AssociationBondDefault())

	// 0 clears the override rather than making association free — see
	// Court.assocBond on why that sentinel points this way.
	testing.SetRealm(testing.NewUserRealm(author))
	SetCourtAssociationBond(cross(cur), "bond4", 0)
	uassert.Equal(t, base, AssociationBond("bond4"))

	// A stranger sets neither.
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "not a moderator of this court", func() {
		SetCourtAssociationBond(cross(cur), "bond4", 1)
	})
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "only the global DAO admin", func() {
		SetAssociationBondDefault(cross(cur), 1)
	})

	// The realm admin moves the default, and a court on no override follows it.
	admin := ensureGlobalDAO().admin
	testing.SetRealm(testing.NewUserRealm(admin))
	SetAssociationBondDefault(cross(cur), 4_242)
	uassert.Equal(t, int64(4_242), AssociationBond("bond4"))

	// Put it back: assocBondDefault is a package global and every later test in
	// this package reads it.
	testing.SetRealm(testing.NewUserRealm(admin))
	SetAssociationBondDefault(cross(cur), base)
}

// ---- the mass verbs -------------------------------------------------------

// massFixture: a court whose creator moderates, two claims by the creator, and a
// stranger who attaches a bonded edge in EACH direction — the shape both mass
// verbs sweep, and the reason they sweep both.
func massFixture(cur realm, t *testing.T, slug string, mods int, extra ...address) (*Court, address, address, uint64, uint64) {
	t.Helper()
	boss := testutils.TestAddress(slug + "-boss")
	stranger := testutils.TestAddress(slug + "-st")
	c := testCourt(cur, slug, boss, 50_000_000_000)
	if mods > 1 || len(extra) > 0 {
		set := append([]address{boss}, extra...)
		testing.SetRealm(testing.NewUserRealm(boss))
		AppointMods(cross(cur), slug, mods, set...)
	}
	testing.SetRealm(testing.NewUserRealm(boss))
	a := OpenClaim(cross(cur), slug, "The claim being griefed")
	testing.SetRealm(testing.NewUserRealm(boss))
	b := OpenClaim(cross(cur), slug, "The other end of the junk")
	c.coin.Mint(stranger, AssociationBond(slug)*8)

	testing.SetRealm(testing.NewUserRealm(stranger))
	AddAssociation(cross(cur), slug, a, b, "contests") // outbound from a
	testing.SetRealm(testing.NewUserRealm(stranger))
	AddAssociation(cross(cur), slug, b, a, "supports") // inbound to a
	return c, boss, stranger, a, b
}

// ONE TRANSACTION CLEARS A CLAIM, IN BOTH DIRECTIONS. The direction half is the
// point: a stranger may fill a claim's 32 outbound slots as readily as its 64
// inbound ones, because AddAssociation's `from` is any claim in the court and not
// the caller's own — so a sweep that only walked assocIn would leave half the junk
// and half the bonds.
func TestApprovingAllAssociationsSettlesBothDirectionsAtOnce(cur realm, t *testing.T) {
	c, boss, stranger, a, b := massFixture(cur, t, "mass1", 1)
	bond := AssociationBond("mass1")
	held := c.coin.BalanceOf(stranger)

	testing.SetRealm(testing.NewUserRealm(boss))
	n := ApproveAllAssociations(cross(cur), "mass1", a)
	uassert.Equal(t, 2, n)
	uassert.Equal(t, held+bond*2, c.coin.BalanceOf(stranger))

	// Both edges SURVIVE — approval is about the money, not the assertion. Asserted
	// as the whole packed string: the two halves are joined by ";" and not ",", so
	// counting comma-separated fields reads one row where there are two.
	uassert.Equal(t, "out:"+strconv.FormatUint(b, 10)+":c;in:"+
		strconv.FormatUint(b, 10)+":s", ClaimAssociations("mass1", a))
	// And a second sweep finds nothing left to settle rather than paying twice.
	testing.SetRealm(testing.NewUserRealm(boss))
	uassert.Equal(t, 0, ApproveAllAssociations(cross(cur), "mass1", a))
	uassert.Equal(t, held+bond*2, c.coin.BalanceOf(stranger))
}

// Neither mass verb is a stranger's.
func TestTheMassAssociationVerbsAreModeratorsOnly(cur realm, t *testing.T) {
	_, _, stranger, a, _ := massFixture(cur, t, "mass2", 1)

	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "not a moderator of this court", func() {
		ApproveAllAssociations(cross(cur), "mass2", a)
	})
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "not a moderator of this court", func() {
		DisapproveAllAssociations(cross(cur), "mass2", a, "junk")
	})
}

// THE BULK BURN TAKES TWO SIGNATURES, AND ONLY BURNS WHAT THE FIRST ONE SAW.
//
// Both halves matter and they pull against each other. m-of-n is here because
// ninety-six bonds is a different act from one, and the bound on `at` is here
// because between the first signature and the second a stranger may post a bond
// nobody has looked at — and if a bulk verb could take that, "unjudged means
// approved" would not be a rule, just a default.
func TestTheBulkBurnTakesTwoSignaturesAndSparesWhatArrivedMidVote(cur realm, t *testing.T) {
	second := testutils.TestAddress("mass3-second")
	c, boss, stranger, a, b := massFixture(cur, t, "mass3", 2, second)
	bond := AssociationBond("mass3")
	supply := c.coin.TotalSupply()

	// One signature of two: nothing burns yet.
	testing.SetRealm(testing.NewUserRealm(boss))
	uassert.Equal(t, 0, DisapproveAllAssociations(cross(cur), "mass3", a, "coordinated junk"))
	uassert.Equal(t, supply, c.coin.TotalSupply())
	// The same moderator signing again is not a second signature.
	testing.SetRealm(testing.NewUserRealm(boss))
	uassert.Equal(t, 0, DisapproveAllAssociations(cross(cur), "mass3", a, "coordinated junk"))
	uassert.Equal(t, supply, c.coin.TotalSupply())

	// A third claim and a bond posted DURING the vote, one block later so its
	// height is strictly above the proposal's.
	testing.SetRealm(testing.NewUserRealm(boss))
	late := OpenClaim(cross(cur), "mass3", "A claim filed while the vote was open")
	testing.SkipHeights(1)
	testing.SetRealm(testing.NewUserRealm(stranger))
	AddAssociation(cross(cur), "mass3", late, a, "supports")
	lateHeld := c.coin.BalanceOf(stranger)

	// The second signature fires, and takes exactly the two the first one saw.
	testing.SetRealm(testing.NewUserRealm(second))
	uassert.Equal(t, 2, DisapproveAllAssociations(cross(cur), "mass3", a, "coordinated junk"))
	uassert.Equal(t, supply-bond*2, c.coin.TotalSupply())

	// The late edge is untouched: bond still held, edge still there.
	uassert.Equal(t, lateHeld, c.coin.BalanceOf(stranger))
	uassert.Equal(t, bond, mustAssocEdge(c, late, a).bond)
	uassert.True(t, strings.Contains(ClaimAssociations("mass3", a), inbound(late, "s")))
	// And the two it burned are gone from both directions.
	uassert.False(t, strings.Contains(ClaimAssociations("mass3", a), inbound(b, "s")))
	uassert.False(t, strings.Contains(ClaimAssociations("mass3", b), inbound(a, "c")))
}
