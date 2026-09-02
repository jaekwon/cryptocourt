package kourtv2

import (
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// The holder leaderboard.
//
// Every assertion here is about a property the ordering has to have rather than
// about one arrangement of one fixture: that the ranking is by balance, that it
// is total (no ties left to chance), that the court's own escrow is not in it,
// and that a zero balance is not a holding.

func rowsOf(s string) [][2]string {
	out := [][2]string{}
	if s == "" {
		return out
	}
	for _, r := range strings.Split(s, ";") {
		i := strings.LastIndex(r, ":")
		if i < 0 {
			continue
		}
		out = append(out, [2]string{r[:i], r[i+1:]})
	}
	return out
}

func TestTopHoldersRanksByBalance(cur realm, t *testing.T) {
	alice := testutils.TestAddress("hold1a")
	bob := testutils.TestAddress("hold1b")
	carol := testutils.TestAddress("hold1c")
	testCourt(cur, "hold1", alice, 1_000_000_000)

	c := mustCourt("hold1")
	c.coin.Mint(bob, 5_000_000)
	c.coin.Mint(carol, 9_000_000)

	rows := rowsOf(TopHolders("hold1", 0))
	if len(rows) < 3 {
		t.Fatalf("setup: expected at least three holders, got %d", len(rows))
	}
	// Descending, and asserted as an ORDER over the whole page rather than by
	// naming who is first: a fixture that happens to be sorted proves nothing.
	prev := int64(1<<62 - 1)
	for i, r := range rows {
		v := int64(0)
		for _, ch := range r[1] {
			v = v*10 + int64(ch-'0')
		}
		if v > prev {
			t.Fatalf("row %d is larger than the row above it: %s", i, r[1])
		}
		prev = v
	}
	// alice was funded with a thousand times what the others hold, so she leads.
	uassert.Equal(t, string(alice), rows[0][0])
}

func TestTopHoldersExcludesTheCourtsOwnEscrow(cur realm, t *testing.T) {
	alice := testutils.TestAddress("hold2a")
	testCourt(cur, "hold2", alice, 1_000_000_000)
	c := mustCourt("hold2")

	// Put coin in escrow the way a deposit would, then check it is not ranked.
	// Without the exclusion the court itself tops its own leaderboard, above
	// every person in it.
	c.coin.Mint(c.escrow, 500_000_000_000)

	for _, r := range rowsOf(TopHolders("hold2", 0)) {
		if r[0] == string(c.escrow) {
			t.Fatal("the court's escrow is not a holder and must not be ranked")
		}
	}
	uassert.False(t, strings.Contains(TopHolders("hold2", 0), string(c.escrow)))
}

func TestAZeroBalanceIsNotAHolding(cur realm, t *testing.T) {
	alice := testutils.TestAddress("hold3a")
	bob := testutils.TestAddress("hold3b")
	testCourt(cur, "hold3", alice, 1_000_000_000)
	c := mustCourt("hold3")

	before := HolderCount("hold3")
	// Mint then burn it all back: the account stays in the ledger at zero,
	// because the balance path never removes — removal would drop the delegate
	// and the vote history with it.
	c.coin.Mint(bob, 3_000_000)
	uassert.Equal(t, before+1, HolderCount("hold3"))
	c.coin.Burn(bob, 3_000_000)

	uassert.Equal(t, before, HolderCount("hold3"))
	for _, r := range rowsOf(TopHolders("hold3", 0)) {
		if r[0] == string(bob) {
			t.Fatal("an account at zero is in the ledger but is not a holder")
		}
	}
}

func TestTopHoldersLimitIsBoundedAndTotal(cur realm, t *testing.T) {
	alice := testutils.TestAddress("hold4a")
	testCourt(cur, "hold4", alice, 1_000_000_000)
	c := mustCourt("hold4")
	for i := 0; i < 6; i++ {
		c.coin.Mint(testutils.TestAddress("hold4-"+string(rune('a'+i))), int64(i+1)*1_000_000)
	}

	uassert.Equal(t, 3, len(rowsOf(TopHolders("hold4", 3))))
	// Zero means the cap, not zero rows — the shape every paged read here uses.
	uassert.True(t, len(rowsOf(TopHolders("hold4", 0))) > 3)
	// Over the cap clamps rather than refusing.
	uassert.True(t, len(rowsOf(TopHolders("hold4", 10_000))) <= topHoldersMax)

	// THE ORDER IS TOTAL: two reads of unchanged state give the same page. Ties
	// are broken by address because the walk is address-ascending and the
	// insertion is stable, so equal balances cannot swap between reads and make
	// the page appear to move while nothing happened.
	uassert.Equal(t, TopHolders("hold4", 0), TopHolders("hold4", 0))
}

func TestTopHoldersOnACourtWithNoHolders(cur realm, t *testing.T) {
	alice := testutils.TestAddress("hold5a")
	// StartCourt directly, not testCourt: that helper mints the balance it is
	// given and the ledger refuses a zero mint ("amount must be positive"), so
	// asking it for an empty court panics in the setup rather than testing one.
	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourt(cross(cur), "hold5", "Empty Court")
	// Nothing minted to anyone: the empty string, not a row of zeroes.
	uassert.Equal(t, "", TopHolders("hold5", 0))
	uassert.Equal(t, 0, HolderCount("hold5"))
}

func TestTopHoldersNoteSaysWhatIsNotCounted(cur realm, t *testing.T) {
	// The figure excludes staked coin, and the surface showing it has to say so.
	// Pinned because the omission is invisible in the number: a committed staker
	// can rank below somebody who never staked, and nothing about "12.5" says
	// why.
	n := TopHoldersNote()
	uassert.True(t, strings.Contains(n, "staked"))
	uassert.True(t, strings.Contains(n, "custody"))
}
