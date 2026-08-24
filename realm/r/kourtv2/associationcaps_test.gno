package kourtv2

import (
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// A PHANTOM SOURCE. AddAssociation checks that BOTH endpoints exist in this court,
// and only the target side was held: deleting `mustClaim(c, from)` survived the
// whole suite. What it buys an attacker is not a missing error — it is a claim
// page that says "#99999 contests this" about a claim that does not exist and
// therefore cannot be read, argued back against, or moderated. assocTextGone hides
// PURGED endpoints by asking the moderation index, and a non-existent claim has no
// entry there, so `lookupClaimMod` returns nil and the phantom is shown rather
// than hidden. It also consumes one of the target's 64 inbound slots.
//
// Both directions are asserted, because only one of them was guarded, and the
// pairing is the ordinary edge between two real claims — otherwise a version that
// refused everything would satisfy the refusals.
func TestAnAssociationNeedsBothItsClaimsToExist(cur realm, t *testing.T) {
	alice, ids := assocFixture(cur, t, "ascx", 2)
	const phantom = uint64(99_999)

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "no such claim", func() {
		AddAssociation(cross(cur), "ascx", phantom, ids[0], "contests")
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "no such claim", func() {
		AddAssociation(cross(cur), "ascx", ids[0], phantom, "contests")
	})

	// The ordinary edge it must NOT refuse.
	testing.SetRealm(testing.NewUserRealm(alice))
	AddAssociation(cross(cur), "ascx", ids[0], ids[1], "supports")

	// And neither refusal left anything behind in either index — a phantom that
	// landed would show up here as an extra entry.
	want := "out:" + strconv.FormatUint(ids[1], 10) + ":s;in:"
	if got := ClaimAssociations("ascx", ids[0]); got != want {
		t.Fatalf("the refused edges must leave no trace: %q, want %q", got, want)
	}
	wantIn := "out:;in:" + strconv.FormatUint(ids[0], 10) + ":s"
	if got := ClaimAssociations("ascx", ids[1]); got != wantIn {
		t.Fatalf("the target's inbound list is wrong: %q, want %q", got, wantIn)
	}
}

// THE TWO WHOLE-CLAIM CAPS, neither of which was pinned. maxAssocOut and maxAssocIn
// bound a claim page's render — the seriesRowCap discipline, stated in this file's
// own comment as "the caps bound a READ, not a writer's enthusiasm" — and three
// separate mutations of them survived: both boundary operators, and the outbound
// scan's prefix guard, whose inversion makes the outbound count come out as zero
// so the cap never fires at all.
//
// FILLED DIRECTLY, for the same reason the folder cap test fills a folder's list
// directly: the cap scans count keys under a prefix and nothing else, so occupying
// the prefix is enough, while reaching 32 and 64 through the front door would cost
// 96 opened claims and 16 addresses. The per-author cap is NOT what is being
// measured here — TestAssociationPerAuthorInboundCap has it — so the filled inbound
// edges carry a different author from the caller, which is what keeps `mine` at
// zero and lets the whole-claim cap be the thing that fires.
//
// Each half asserts the LAST allowed write lands before asserting the next one is
// refused. Without that, a cap that was simply off by a hundred would pass the
// refusal half on its own.
func TestTheAssociationCapsBindAtTheirStatedNumbers(cur realm, t *testing.T) {
	alice, ids := assocFixture(cur, t, "ascc", 4)
	c := mustCourt("ascc")
	ensureAssocs(c)
	filler := testutils.TestAddress("ascc-filler")

	// ---- outbound: ids[0] already asserts maxAssocOut-1 edges ----
	for i := 0; i < maxAssocOut-1; i++ {
		to := uint64(500_000 + i)
		e := &assocEdge{stance: assocSupports, author: filler, at: heightNow()}
		c.assocOut.Set(assocKey(ids[0], to), e)
		c.assocIn.Set(assocKey(to, ids[0]), e)
	}
	// The last slot is usable.
	testing.SetRealm(testing.NewUserRealm(alice))
	AddAssociation(cross(cur), "ascc", ids[0], ids[1], "supports")
	// And the next one is not.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "already asserts", func() {
		AddAssociation(cross(cur), "ascc", ids[0], ids[2], "contests")
	})

	// ---- inbound: ids[2] already carries maxAssocIn-1 edges, none of them the
	// caller's, so the per-author cap cannot be what fires ----
	for i := 0; i < maxAssocIn-1; i++ {
		from := uint64(700_000 + i)
		e := &assocEdge{stance: assocContests, author: filler, at: heightNow()}
		c.assocIn.Set(assocKey(ids[2], from), e)
		c.assocOut.Set(assocKey(from, ids[2]), e)
	}
	// bob authored neither endpoint, so he posts the association bond on each
	// attempt that gets far enough to spend. Fund both tries; the second is
	// refused by the inbound cap before it costs him anything.
	bob := testutils.TestAddress("ascc-bob")
	c.coin.Mint(bob, AssociationBond("ascc")*2)
	testing.SetRealm(testing.NewUserRealm(bob))
	AddAssociation(cross(cur), "ascc", ids[1], ids[2], "supports")
	// A FOURTH claim as the source, and the reason is worth a line: ids[0] now
	// asserts its own 32 outbound edges, so reusing it here refused with "already
	// asserts 32" and the inbound cap was never reached. The first version of this
	// test asserted the wrong message for exactly that reason.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "already carries", func() {
		AddAssociation(cross(cur), "ascc", ids[3], ids[2], "contests")
	})
}

// THE READ STAYS BOUNDED WHATEVER IS WRITTEN, which is the property the caps exist
// for and the one a cap alone does not establish: the filled state above is
// exactly what an attacker who paid for every slot leaves behind, and the page
// must still answer in bounded size. Asserted on the SEPARATOR count rather than
// on bytes, because the row count is what the cap governs.
func TestAClaimPageStaysBoundedUnderAFullAssociationLoad(cur realm, t *testing.T) {
	_, ids := assocFixture(cur, t, "ascb", 2)
	c := mustCourt("ascb")
	ensureAssocs(c)
	filler := testutils.TestAddress("ascb-filler")
	for i := 0; i < maxAssocOut; i++ {
		to := uint64(800_000 + i)
		e := &assocEdge{stance: assocSupports, author: filler, at: heightNow()}
		c.assocOut.Set(assocKey(ids[0], to), e)
	}
	for i := 0; i < maxAssocIn; i++ {
		from := uint64(900_000 + i)
		e := &assocEdge{stance: assocContests, author: filler, at: heightNow()}
		c.assocIn.Set(assocKey(ids[0], from), e)
	}
	out := ClaimAssociations("ascb", ids[0])
	parts := strings.SplitN(out, ";in:", 2)
	if len(parts) != 2 {
		t.Fatalf("the read must carry both halves: %q", out)
	}
	outRows := strings.Split(strings.TrimPrefix(parts[0], "out:"), ",")
	inRows := strings.Split(parts[1], ",")
	if len(outRows) != maxAssocOut {
		t.Fatalf("a full outbound load reads %d rows, want the %d cap",
			len(outRows), maxAssocOut)
	}
	if len(inRows) != maxAssocIn {
		t.Fatalf("a full inbound load reads %d rows, want the %d cap",
			len(inRows), maxAssocIn)
	}
}
