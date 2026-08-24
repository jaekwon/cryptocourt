package kourtv2

import (
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// A PHANTOM SOURCE. AddArgument checks that BOTH endpoints exist in this court,
// and only the target side was held: deleting `mustClaim(c, from)` survived the
// whole suite. What it buys an attacker is not a missing error — it is a claim
// page that says "#99999 contests this" about a claim that does not exist and
// therefore cannot be read, argued back against, or moderated. argTextGone hides
// PURGED endpoints by asking the moderation index, and a non-existent claim has no
// entry there, so `lookupClaimMod` returns nil and the phantom is shown rather
// than hidden. It also consumes one of the target's 64 inbound slots.
//
// Both directions are asserted, because only one of them was guarded, and the
// pairing is the ordinary edge between two real claims — otherwise a version that
// refused everything would satisfy the refusals.
func TestAnArgumentEdgeNeedsBothItsClaimsToExist(cur realm, t *testing.T) {
	alice, ids := argFixture(cur, t, "argx", 2)
	const phantom = uint64(99_999)

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "no such claim", func() {
		AddArgument(cross(cur), "argx", phantom, ids[0], "contests")
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "no such claim", func() {
		AddArgument(cross(cur), "argx", ids[0], phantom, "contests")
	})

	// The ordinary edge it must NOT refuse.
	testing.SetRealm(testing.NewUserRealm(alice))
	AddArgument(cross(cur), "argx", ids[0], ids[1], "supports")

	// And neither refusal left anything behind in either index — a phantom that
	// landed would show up here as an extra entry.
	want := "out:" + strconv.FormatUint(ids[1], 10) + ":s;in:"
	if got := ClaimArguments("argx", ids[0]); got != want {
		t.Fatalf("the refused edges must leave no trace: %q, want %q", got, want)
	}
	wantIn := "out:;in:" + strconv.FormatUint(ids[0], 10) + ":s"
	if got := ClaimArguments("argx", ids[1]); got != wantIn {
		t.Fatalf("the target's inbound list is wrong: %q, want %q", got, wantIn)
	}
}

// THE TWO WHOLE-CLAIM CAPS, neither of which was pinned. maxArgOut and maxArgIn
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
// measured here — TestArgumentPerAuthorInboundCap has it — so the filled inbound
// edges carry a different author from the caller, which is what keeps `mine` at
// zero and lets the whole-claim cap be the thing that fires.
//
// Each half asserts the LAST allowed write lands before asserting the next one is
// refused. Without that, a cap that was simply off by a hundred would pass the
// refusal half on its own.
func TestTheArgumentCapsBindAtTheirStatedNumbers(cur realm, t *testing.T) {
	alice, ids := argFixture(cur, t, "argc", 4)
	c := mustCourt("argc")
	ensureArgs(c)
	filler := testutils.TestAddress("argc-filler")

	// ---- outbound: ids[0] already asserts maxArgOut-1 edges ----
	for i := 0; i < maxArgOut-1; i++ {
		to := uint64(500_000 + i)
		e := &argEdge{stance: argSupports, author: filler, at: heightNow()}
		c.argOut.Set(argKey(ids[0], to), e)
		c.argIn.Set(argKey(to, ids[0]), e)
	}
	// The last slot is usable.
	testing.SetRealm(testing.NewUserRealm(alice))
	AddArgument(cross(cur), "argc", ids[0], ids[1], "supports")
	// And the next one is not.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "already asserts", func() {
		AddArgument(cross(cur), "argc", ids[0], ids[2], "contests")
	})

	// ---- inbound: ids[2] already carries maxArgIn-1 edges, none of them the
	// caller's, so the per-author cap cannot be what fires ----
	for i := 0; i < maxArgIn-1; i++ {
		from := uint64(700_000 + i)
		e := &argEdge{stance: argContests, author: filler, at: heightNow()}
		c.argIn.Set(argKey(ids[2], from), e)
		c.argOut.Set(argKey(from, ids[2]), e)
	}
	// bob authored neither endpoint, so he posts the association bond on each
	// attempt that gets far enough to spend. Fund both tries; the second is
	// refused by the inbound cap before it costs him anything.
	bob := testutils.TestAddress("argc-bob")
	c.coin.Mint(bob, AssociationBond("argc")*2)
	testing.SetRealm(testing.NewUserRealm(bob))
	AddArgument(cross(cur), "argc", ids[1], ids[2], "supports")
	// A FOURTH claim as the source, and the reason is worth a line: ids[0] now
	// asserts its own 32 outbound edges, so reusing it here refused with "already
	// asserts 32" and the inbound cap was never reached. The first version of this
	// test asserted the wrong message for exactly that reason.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "already carries", func() {
		AddArgument(cross(cur), "argc", ids[3], ids[2], "contests")
	})
}

// THE READ STAYS BOUNDED WHATEVER IS WRITTEN, which is the property the caps exist
// for and the one a cap alone does not establish: the filled state above is
// exactly what an attacker who paid for every slot leaves behind, and the page
// must still answer in bounded size. Asserted on the SEPARATOR count rather than
// on bytes, because the row count is what the cap governs.
func TestAClaimPageStaysBoundedUnderAFullArgumentLoad(cur realm, t *testing.T) {
	_, ids := argFixture(cur, t, "argb", 2)
	c := mustCourt("argb")
	ensureArgs(c)
	filler := testutils.TestAddress("argb-filler")
	for i := 0; i < maxArgOut; i++ {
		to := uint64(800_000 + i)
		e := &argEdge{stance: argSupports, author: filler, at: heightNow()}
		c.argOut.Set(argKey(ids[0], to), e)
	}
	for i := 0; i < maxArgIn; i++ {
		from := uint64(900_000 + i)
		e := &argEdge{stance: argContests, author: filler, at: heightNow()}
		c.argIn.Set(argKey(ids[0], from), e)
	}
	out := ClaimArguments("argb", ids[0])
	parts := strings.SplitN(out, ";in:", 2)
	if len(parts) != 2 {
		t.Fatalf("the read must carry both halves: %q", out)
	}
	outRows := strings.Split(strings.TrimPrefix(parts[0], "out:"), ",")
	inRows := strings.Split(parts[1], ",")
	if len(outRows) != maxArgOut {
		t.Fatalf("a full outbound load reads %d rows, want the %d cap",
			len(outRows), maxArgOut)
	}
	if len(inRows) != maxArgIn {
		t.Fatalf("a full inbound load reads %d rows, want the %d cap",
			len(inRows), maxArgIn)
	}
}
