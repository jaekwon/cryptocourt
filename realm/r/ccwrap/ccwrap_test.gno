package ccwrap

import (
	"chain"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
	"gno.land/r/demo/defi/grc20reg"
	"gno.land/r/kourt/kourtv2"
)

const (
	kourtPath  = "gno.land/r/kourt/kourtv2"
	ccwrapPath = "gno.land/r/kourt/ccwrap"
)

func vault() address { return chain.PackageAddress(ccwrapPath) }

// fundAndBuy is kourtv2's own test idiom, reproduced here because this package
// is OUTSIDE kourtv2 and cannot mint from the ledger. Buying through the curve
// is the more honest fixture anyway: it is the only way coin exists on chain.
func fundAndBuy(cur realm, slug string, who address, gnot int64) {
	if !kourtv2.Exists(slug) {
		testing.SetRealm(testing.NewUserRealm(who))
		kourtv2.StartCourt(cross(cur), slug, "Wrap Court "+slug)
	}
	testing.IssueCoins(chain.PackageAddress(kourtPath), chain.Coins{{Denom: "ugnot", Amount: gnot}})
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: gnot}})
	testing.SetRealm(testing.NewUserRealm(who))
	kourtv2.Buy(cross(cur), slug)
	testing.SetOriginSend(nil)
}

// A wrapped court coin is exactly what gnoswap resolves, and the assertion is
// gnoswap's own resolution path rather than a paraphrase of it: CreatePool calls
// common.MustRegistered on both token paths, and common.MustRegistered is
// grc20reg.Get(key) != nil. So if MustGet answers here with the right symbol and
// scale, the pool would be creatable — and if grc20reg ever stopped accepting a
// slug, or fqname changed its separator, this fails rather than the deploy.
func TestEnableRegistersATokenGnoswapCanResolve(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cw-alice")
	fundAndBuy(cur, "cw1", alice, 300_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	key := Enable(cross(cur), "cw1")

	// The key is rlmPath + "." + SYMBOL, not the slug: grc20reg derives it from
	// token.GetSymbol() and ignores its own slug argument for keying.
	uassert.Equal(t, ccwrapPath+".wCW1", key)
	uassert.Equal(t, TokenKey("cw1"), key)
	uassert.True(t, Enabled("cw1"))

	tok := grc20reg.MustGet(key)
	if tok == nil {
		t.Fatal("gnoswap could not resolve the token it would be asked to trade")
	}
	uassert.Equal(t, "w"+kourtv2.CourtSymbol("cw1"), tok.GetSymbol())

	// The scale must match the coin being claimed, or every quote against it is
	// off by a factor of a million. Read from kourtv2 rather than restated, so
	// the day coinDecimals moves there this fails instead of mispricing.
	uassert.Equal(t, kourtv2.CoinDecimals(), tok.GetDecimals())

	// Nothing exists yet. An Enable nobody has deposited into is inert, which is
	// what makes leaving it permissionless safe.
	uassert.Equal(t, int64(0), tok.TotalSupply())
}

// A second Enable must be refused, because grc20reg.Register is a tree Set: it
// would REPLACE the token behind the key, orphaning the balances of every pool
// holding the old one while the new token reported zero against a full escrow.
// This is the one irrecoverable move the package can make.
func TestEnableTwiceIsRefused(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cw-alice2")
	fundAndBuy(cur, "cw2", alice, 300_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	Enable(cross(cur), "cw2")

	before := grc20reg.MustGet(TokenKey("cw2"))

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "ccwrap: already enabled: cw2", func() {
		Enable(cross(cur), "cw2")
	})

	// And the ordinary input it must NOT refuse: a DIFFERENT court still
	// enables. Without this the test above passes just as well against an Enable
	// that refuses everything.
	fundAndBuy(cur, "cw2b", alice, 300_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Enable(cross(cur), "cw2b")
	uassert.True(t, Enabled("cw2b"))

	// The registered pointer is untouched, which is the property that matters —
	// not merely that the second call panicked. And it would hold with ccwrap's
	// guard removed, because grc20reg refuses a duplicate key itself; the guard
	// only buys a clearer message.
	uassert.True(t, before == grc20reg.MustGet(TokenKey("cw2")))
}

// An unknown court cannot be enabled, and the message says who may fix it.
func TestEnableRefusesAnUnknownCourt(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cw-alice3")
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "ccwrap: no such court: nope", func() {
		Enable(cross(cur), "nope")
	})
}

// The round trip, asserted on all three ledgers at once: the holder's court
// coin, the escrow's, and the wrapped supply. Any one of them alone can be made
// to look right by a bug that loses coin somewhere else.
func TestWrapAndUnwrapConserveEverything(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cw-alice4")
	fundAndBuy(cur, "cw3", alice, 300_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	Enable(cross(cur), "cw3")

	start := kourtv2.CoinBalanceOf("cw3", alice)
	uassert.True(t, start > 0)
	const amt = int64(1_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	kourtv2.ApproveCC(cross(cur), "cw3", vault(), amt)
	testing.SetRealm(testing.NewUserRealm(alice))
	Wrap(cross(cur), "cw3", amt)

	uassert.Equal(t, start-amt, kourtv2.CoinBalanceOf("cw3", alice))
	uassert.Equal(t, amt, kourtv2.CoinBalanceOf("cw3", vault()))
	uassert.Equal(t, amt, WrappedSupply("cw3"))
	uassert.Equal(t, amt, grc20reg.MustGet(TokenKey("cw3")).BalanceOf(alice))

	// The allowance was consumed exactly, so a second wrap of the same size
	// cannot ride on it. An allowance that survived its spend would let one
	// approval be drawn against forever.
	uassert.Equal(t, int64(0), kourtv2.AllowanceCC("cw3", alice, vault()))

	testing.SetRealm(testing.NewUserRealm(alice))
	Unwrap(cross(cur), "cw3", amt)

	uassert.Equal(t, start, kourtv2.CoinBalanceOf("cw3", alice))
	uassert.Equal(t, int64(0), kourtv2.CoinBalanceOf("cw3", vault()))
	uassert.Equal(t, int64(0), WrappedSupply("cw3"))
}

// THE LOAD-BEARING TEST. Committed coin cannot be wrapped, which is the only
// reason transferability is safe: if it could, a holder would sell the coin
// backing a live claim deposit, a stake or a bond and keep both the proceeds and
// the position. The gate is kourtv2's mustSpendable on the OWNER, reached
// through TransferFromCC — so this also pins that the gate keys on `from` and
// not on the spender, since ccwrap's own balance is unconstrained.
//
// Paired, as it must be, with the amount it must NOT refuse: the spendable
// remainder wraps fine. Without that half, a Wrap that refused everything would
// pass.
func TestCommittedCoinCannotBeWrapped(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cw-alice5")
	fundAndBuy(cur, "cw4", alice, 300_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	Enable(cross(cur), "cw4")

	// STAKE is the lock. A claim deposit was the obvious candidate and is the
	// wrong one: OpenClaim MOVES the deposit and its fee into the court escrow,
	// so the coin leaves the balance entirely and LockedOf stays 0. Only Stake
	// locks in place — that is lock.gno's whole doctrine, "a lock, not custody" —
	// and it is therefore the only fixture that exercises spendable().
	//
	// Side 0 is YES. kourtv2's side constants are unexported and its public
	// Stake takes a plain int, so an external caller passes the number; named
	// here rather than left bare.
	testing.SetRealm(testing.NewUserRealm(alice))
	id := kourtv2.OpenClaim(cross(cur), "cw4", "Is committed coin unsellable?")
	//
	// THREE QUARTERS, not a half, and the ratio is now load-bearing: maxWrapBps is
	// a SECOND, independent gate, and this fixture's subject is the first one. With
	// half staked the remaining spendable is about half of votable, which the 35%
	// cap refuses — so the "and the half that must succeed" arm below would fail
	// for a reason this test is not about, and the refusal arm would start passing
	// on the cap's message instead of the stake's. Staking three quarters leaves
	// spendable near a quarter of votable, comfortably under the cap, so the stake
	// gate is the only thing being measured.
	testing.SetRealm(testing.NewUserRealm(alice))
	kourtv2.Stake(cross(cur), "cw4", id, 0, kourtv2.SpendableOf("cw4", alice)*3/4)

	locked := kourtv2.LockedOf("cw4", alice)
	if locked <= 0 {
		t.Fatal("fixture is vacuous: nothing is locked, so nothing is being " +
			"refused for the right reason")
	}
	spend := kourtv2.SpendableOf("cw4", alice)
	bal := kourtv2.CoinBalanceOf("cw4", alice)
	uassert.Equal(t, bal-locked, spend)

	// Approve the FULL balance. The allowance is deliberately larger than
	// spendable, because that is the case the gate exists for — and it also
	// records that approving does not reserve and does not lock.
	testing.SetRealm(testing.NewUserRealm(alice))
	kourtv2.ApproveCC(cross(cur), "cw4", vault(), bal)

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, notEnoughUnstaked, func() {
		Wrap(cross(cur), "cw4", spend+1)
	})

	// Nothing moved on the failed attempt. A partial wrap would have minted an
	// unbacked claim.
	uassert.Equal(t, bal, kourtv2.CoinBalanceOf("cw4", alice))
	uassert.Equal(t, int64(0), WrappedSupply("cw4"))

	// And the half that must succeed.
	testing.SetRealm(testing.NewUserRealm(alice))
	Wrap(cross(cur), "cw4", spend)
	uassert.Equal(t, spend, WrappedSupply("cw4"))
	uassert.Equal(t, locked, kourtv2.CoinBalanceOf("cw4", alice))
}

// notEnoughUnstaked is kourtv2's refusal, quoted so this test fails if the
// refusal it is relying on is ever replaced by a different one — including by a
// weaker one that no longer mentions being committed.
const notEnoughUnstaked = "kourtv2: not enough unstaked CC — staked coins stay " +
	"in your balance and keep voting, but they are committed and cannot also " +
	"back a deposit, a bond, or another stake"

// Without an allowance there is no wrap. This is what makes the realm
// unprivileged: it cannot reach anyone's coin unasked.
func TestWrapNeedsAnAllowance(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cw-alice6")
	fundAndBuy(cur, "cw5", alice, 300_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	Enable(cross(cur), "cw5")

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "grc20votes: allowance exceeded", func() {
		Wrap(cross(cur), "cw5", 1_000)
	})
	uassert.Equal(t, int64(0), WrappedSupply("cw5"))

	// The ordinary input it must not refuse.
	testing.SetRealm(testing.NewUserRealm(alice))
	kourtv2.ApproveCC(cross(cur), "cw5", vault(), 1_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Wrap(cross(cur), "cw5", 1_000)
	uassert.Equal(t, int64(1_000), WrappedSupply("cw5"))
}

// Unwrapping more than you hold takes nothing out of the escrow. The burn runs
// first for exactly this reason, and the escrow balance is the assertion that
// distinguishes "refused" from "refused after paying out".
func TestUnwrapCannotOverdraw(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cw-alice7")
	bob := testutils.TestAddress("cw-bob7")
	fundAndBuy(cur, "cw6", alice, 300_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	Enable(cross(cur), "cw6")
	testing.SetRealm(testing.NewUserRealm(alice))
	kourtv2.ApproveCC(cross(cur), "cw6", vault(), 5_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Wrap(cross(cur), "cw6", 5_000)

	// Bob holds no wrapped coin at all and must not be able to drain the escrow
	// alice filled.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "insufficient balance", func() {
		Unwrap(cross(cur), "cw6", 1)
	})
	uassert.Equal(t, int64(5_000), kourtv2.CoinBalanceOf("cw6", vault()))
	uassert.Equal(t, int64(5_000), WrappedSupply("cw6"))
	uassert.Equal(t, int64(0), kourtv2.CoinBalanceOf("cw6", bob))
}
// Wrapped coin is a bearer claim that moves by approve + transferFrom — the
// sequence gnoswap's pool uses to pull tokens on a swap and on a mint. What is
// pinned here is that the TOKEN supports it and that a stranger who acquires the
// wrapped coin can redeem it for real court coin, which is what makes it worth a
// price to someone who has never touched the court.
//
// Actor supplied by ImpersonateTeller rather than CallerTeller. Not a shortcut:
// CallerTeller derives its actor from cur.Previous(), and a gno test with the
// realm set to a plain user has no previous frame to read — it aborts with
// "cannot seek beyond origin caller override". Both tellers are the same fnTeller
// over the same ledger with a different actor function, so the ledger path under
// test is the one a pool would take; the frame-derived actor is what a live chain
// supplies, and the registry-resolution test above is what covers the resolution
// a pool actually performs.
func TestWrappedCoinMovesTheWayAPoolWouldMoveIt(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cw-alice8")
	bob := testutils.TestAddress("cw-bob8")
	fundAndBuy(cur, "cw7", alice, 300_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	Enable(cross(cur), "cw7")
	testing.SetRealm(testing.NewUserRealm(alice))
	kourtv2.ApproveCC(cross(cur), "cw7", vault(), 9_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Wrap(cross(cur), "cw7", 9_000)

	w := mustWrapped("cw7")
	// The same object the registry hands a pool — asserted, so this cannot pass
	// against a ledger nothing else can reach.
	uassert.True(t, w.tok == grc20reg.MustGet(TokenKey("cw7")))

	if err := w.led.ImpersonateTeller(alice).Approve(0, cur, bob, 4_000); err != nil {
		t.Fatal(err)
	}
	if err := w.led.ImpersonateTeller(bob).TransferFrom(0, cur, alice, bob, 4_000); err != nil {
		t.Fatal(err)
	}
	uassert.Equal(t, int64(5_000), w.tok.BalanceOf(alice))
	uassert.Equal(t, int64(4_000), w.tok.BalanceOf(bob))

	// Bob never touched the court and can still unwrap into real court coin.
	testing.SetRealm(testing.NewUserRealm(bob))
	Unwrap(cross(cur), "cw7", 4_000)
	uassert.Equal(t, int64(4_000), kourtv2.CoinBalanceOf("cw7", bob))
	uassert.Equal(t, int64(5_000), kourtv2.CoinBalanceOf("cw7", vault()))
}

// Two courts do not share an escrow. The vault address is one account holding
// every court's coin, and the ledgers are what keep them apart — so this asserts
// the separation rather than assuming it, and it is the test that would catch a
// wrap keyed on the wrong slug.
func TestTwoCourtsDoNotShareTheEscrow(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cw-alice9")
	fundAndBuy(cur, "cw8a", alice, 300_000_000)
	fundAndBuy(cur, "cw8b", alice, 300_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	Enable(cross(cur), "cw8a")
	testing.SetRealm(testing.NewUserRealm(alice))
	Enable(cross(cur), "cw8b")

	testing.SetRealm(testing.NewUserRealm(alice))
	kourtv2.ApproveCC(cross(cur), "cw8a", vault(), 3_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Wrap(cross(cur), "cw8a", 3_000)

	uassert.Equal(t, int64(3_000), WrappedSupply("cw8a"))
	uassert.Equal(t, int64(0), WrappedSupply("cw8b"))
	uassert.Equal(t, int64(3_000), kourtv2.CoinBalanceOf("cw8a", vault()))
	uassert.Equal(t, int64(0), kourtv2.CoinBalanceOf("cw8b", vault()))

	// The two tokens are distinct objects under distinct keys.
	uassert.True(t, grc20reg.MustGet(TokenKey("cw8a")) != grc20reg.MustGet(TokenKey("cw8b")))
	uassert.NotEqual(t, TokenKey("cw8a"), TokenKey("cw8b"))
}

// Wrapping before Enable says who can fix it, rather than failing obscurely on a
// nil map read.
func TestWrapBeforeEnableSaysWhatToDo(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cw-alice10")
	fundAndBuy(cur, "cw9", alice, 300_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur,
		"ccwrap: not enabled for court cw9; anyone can call Enable", func() {
			Wrap(cross(cur), "cw9", 1)
		})
}

// Non-positive amounts are refused at both doors. Cheap, and the kind of thing
// that turns into a mint-for-free if a signed amount ever reaches the ledger.
func TestNonPositiveAmountsAreRefused(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cw-alice11")
	fundAndBuy(cur, "cw10", alice, 300_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	Enable(cross(cur), "cw10")

	for _, n := range []int64{0, -1, -1_000_000} {
		testing.SetRealm(testing.NewUserRealm(alice))
		uassert.AbortsContains(t, cur, "ccwrap: wrap amount must be positive", func() {
			Wrap(cross(cur), "cw10", n)
		})
		testing.SetRealm(testing.NewUserRealm(alice))
		uassert.AbortsContains(t, cur, "ccwrap: unwrap amount must be positive", func() {
			Unwrap(cross(cur), "cw10", n)
		})
	}
}

// The wrappable-slug bound, from both sides. A court whose slug uses kourtv2's
// full 11 characters cannot be wrapped, because grc20's symbol bound is also 11
// and the wrapped symbol spends one on the "w". Asserted against the real
// constants rather than the numbers 10 and 11, so it tracks either moving —
// including the good case, where kourtv2 drops to 10 and this whole hole closes.
func TestTheWrappableSlugBoundIsRealOnBothSides(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cw-alice12")

	// Exactly at kourtv2's limit: legal court, unwrappable.
	long := "abcdefghijk"
	uassert.Equal(t, 11, len(long))
	uassert.False(t, WrappableSlug(long))
	fundAndBuy(cur, long, alice, 300_000_000)
	uassert.True(t, kourtv2.Exists(long))
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "ccwrap: slug too long to wrap", func() {
		Enable(cross(cur), long)
	})

	// One shorter, which must work — otherwise the assertion above is satisfied
	// by an Enable that refuses everything, and the bound is not being tested.
	short := "abcdefghij"
	uassert.Equal(t, 10, len(short))
	uassert.True(t, WrappableSlug(short))
	fundAndBuy(cur, short, alice, 300_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	key := Enable(cross(cur), short)
	uassert.Equal(t, ccwrapPath+".wABCDEFGHIJ", key)
	uassert.Equal(t, 11, len(grc20reg.MustGet(key).GetSymbol()))
}

// Symbols stay injective across slugs, which matters more than it looks: the
// registry keys on the symbol, so two slugs mapping to one symbol would mean the
// second court's Enable is refused forever with a message about a token it never
// registered.
//
// THIS TEST USED TO PROVE IT WITH A HYPHEN, and the pair it used no longer
// exists. It was "ab-c" against "abc": under the old alphabet the wrap symbol
// had to preserve the hyphen or the two collided into wABC. kourtv2's slug
// alphabet is alphanumeric now, so that collision is unconstructible — and
// injectivity stopped being something the symbol builder has to be careful
// about, because uppercasing [a-z0-9] cannot fold two slugs together.
//
// Rewritten rather than deleted. The property is still worth pinning: what
// changed is that it now follows from the alphabet instead of from remembering
// to keep a character. Two slugs that differ only by length are the sharpest
// pair the new alphabet allows.
func TestWrappedSymbolsStayInjectiveAcrossSlugs(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cw-alice13")
	fundAndBuy(cur, "abc", alice, 300_000_000)
	fundAndBuy(cur, "abcd", alice, 300_000_000)

	uassert.NotEqual(t, TokenKey("abc"), TokenKey("abcd"))

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.Equal(t, ccwrapPath+".wABC", Enable(cross(cur), "abc"))
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.Equal(t, ccwrapPath+".wABCD", Enable(cross(cur), "abcd"))
}

// THE WRAP CAP — liquidity may not strand the court's own governance.
//
// Wrapped coin sits at this realm's address, which no key can vote (Enable, Wrap
// and Unwrap are the whole surface), while kourtv2's `votable` nets out only the
// court escrow. So every unit wrapped stays in the DENOMINATOR of the
// supply-denominated bars and leaves every numerator. Measured on the uncapped
// tree: sinking 95% of votable put unanimous castable turnout at exactly 100% of a
// 5%-of-votable bar and 25% at 98% — an election that can never install, arriving
// from the wrapper being POPULAR rather than from any attack.
//
// The cap is derived, not chosen: quorum needs castable > votable/3 on a claim
// staking a third of the court, so the vault must stay under 66.7%; 60% leaves a
// fifth of the remaining room.
//
// PAIRED, and the pair is the point — a cap that refuses ordinary wrapping is the
// flagMinCC trap, and the first version of this one did exactly that by reading
// votable at a sealed epoch (0 on a young court) and refusing everything.
func TestWrapCapKeepsTheCourtAbleToVote(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cap-alice")
	fundAndBuy(cur, "capc", alice, 40_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Enable(cross(cur), "capc")

	bal := kourtv2.CoinBalanceOf("capc", alice)
	room := WrapRoom("capc")
	if room <= 0 || room >= bal {
		t.Fatalf("fixture is vacuous: room=%d must be positive and below the "+
			"holder's %d for a cap to be demonstrable", room, bal)
	}

	// ORDINARY WRAPPING WORKS, right up to the cap.
	testing.SetRealm(testing.NewUserRealm(alice))
	kourtv2.ApproveCC(cross(cur), "capc", vault(), bal)
	testing.SetRealm(testing.NewUserRealm(alice))
	Wrap(cross(cur), "capc", room)
	uassert.Equal(t, room, kourtv2.CoinBalanceOf("capc", vault()))
	uassert.Equal(t, int64(0), WrapRoom("capc"))

	// ONE UNIT MORE IS REFUSED, so the cap is a bound and not a suggestion.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "too little of the court's coin able to vote",
		func() { Wrap(cross(cur), "capc", 1) })

	// AND THE PROPERTY IT EXISTS FOR: the coin that can still vote clears both bar
	// shapes. Asserted on the arithmetic the bars are built from rather than on a
	// bar reader, because an election needs moderation state this fixture has no
	// reason to build.
	votable := kourtv2.CoinSupply("capc") -
		kourtv2.CoinBalanceOf("capc", kourtv2.CourtEscrow("capc"))
	castable := votable - kourtv2.CoinBalanceOf("capc", vault())
	if castable <= votable/3 {
		t.Fatalf("at the cap the castable pool %d must still exceed votable/3 "+
			"(%d), or a claim staking a third of the court has no electorate",
			castable, votable/3)
	}
	if castable <= votable*500/10000 {
		t.Fatalf("at the cap the castable pool %d must still exceed the 5%% bars "+
			"(%d)", castable, votable*500/10000)
	}

	// UNWRAPPING FREES ROOM — it can only move the vault away from the bound, so it
	// is uncapped, and the cap must not be a one-way ratchet.
	testing.SetRealm(testing.NewUserRealm(alice))
	Unwrap(cross(cur), "capc", room/2)
	if got := WrapRoom("capc"); got <= 0 {
		t.Fatalf("unwrapping must free room, got %d", got)
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	Wrap(cross(cur), "capc", room/2)
}

// THE CAP IS A PRECONDITION, AND ITS NUMBER IS DERIVED WITH THE ESCROW IN IT.
//
// maxWrapBps reads votable ONCE, at Wrap. The escrow keeps growing afterwards and
// every unit entering it shrinks votable while the vault stays put, so the vault's
// SHARE of votable climbs with no further wrapping and nothing re-checks it.
// Measured at the old 60%: wrap to the cap on an empty escrow, let the escrow reach
// 20% of supply, and the vault is 75% of votable with the quality lane's votable/3
// bar unreachable by the entire castable electorate.
//
// So the number answers a BOUND, not an invariant. Wrapping at the worst moment
// puts vault = k·supply, and for a later escrow share e the votable/3 bar stays
// reachable while k < (2/3)(1 − e), i.e. up to e = 1 − 3k/2. At k = 35% that is
// 47.5% of supply escrowed.
//
// THIS TEST ASSERTS THE BOUND, NOT THE CONSTANT, and the difference is the whole
// point. A first version pinned "the vault holds ~35% of supply at the cap", which
// meant every ablation tripped that one precondition and the derivation was never
// exercised — one assertion catching both directions is evidence for neither. Here
// the bound is COMPUTED from whatever the cap actually is, so raising the cap fails
// (its bound collapses: 60% only reaches 10% escrow) while tightening it passes,
// which is the correct asymmetry for a safety bound.
func TestTheWrapCapHoldsTheBarsUpToItsEscrowBound(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cap2-alice")
	fundAndBuy(cur, "capb", alice, 40_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Enable(cross(cur), "capb")

	// Wrap to the cap at the worst moment: nothing escrowed, so votable is supply
	// and the vault takes its largest possible absolute share.
	if esc := kourtv2.CoinBalanceOf("capb", kourtv2.CourtEscrow("capb")); esc != 0 {
		t.Fatalf("fixture is vacuous: this arm needs an empty escrow to be the "+
			"worst case, found %d", esc)
	}
	room := WrapRoom("capb")
	if room <= 0 {
		t.Fatal("fixture is vacuous: no room to wrap, so no cap is being exercised")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	kourtv2.ApproveCC(cross(cur), "capb", vault(), room)
	testing.SetRealm(testing.NewUserRealm(alice))
	Wrap(cross(cur), "capb", room)

	supply := kourtv2.CoinSupply("capb")
	vaultHeld := kourtv2.CoinBalanceOf("capb", vault())

	// AND kourtv2's OWN "votable" READER STILL CONTAINS THE VAULT, which is the
	// property its corrected doc now states and the reason this cap exists at all.
	// Asserted from here because kourtv2 cannot see the vault and so cannot test it:
	// the court nets out its escrow and nothing else, so a wrapper's holdings are
	// inside the figure a client reads as "what can vote". If that ever stops being
	// true — if someone nets the vault out on the court side — this fails and the
	// cap's whole justification needs revisiting.
	testing.SkipHeights(720 * 2)
	if raw, esc, votable := kourtv2.VotableSupply("capb"); raw > 0 {
		if votable != raw-esc {
			t.Fatalf("votable should be raw minus escrow only: %d vs %d-%d",
				votable, raw, esc)
		}
		if votable-vaultHeld >= votable {
			t.Fatalf("fixture is vacuous: the vault holds %d, so subtracting it "+
				"must reduce votable=%d", vaultHeld, votable)
		}
		if vaultHeld > votable {
			t.Fatalf("the vault (%d) cannot exceed a votable (%d) that contains it",
				vaultHeld, votable)
		}
	}

	// The largest escrow share at which votable/3 is still reachable, found by
	// walking e upward against the shipped vault rather than by trusting algebra.
	var bound int64 = -1
	for e := int64(0); e <= 99; e++ {
		votable := supply - supply*e/100
		if votable-vaultHeld <= votable/3 {
			break
		}
		bound = e
	}
	t.Logf("vault holds %d of supply %d (%d bps); votable/3 stays reachable up to "+
		"escrow %d%%", vaultHeld, supply, vaultHeld*10000/supply, bound)

	// THE CLAIM: 47.5% of supply escrowed, so 47 must hold. Raising the cap
	// collapses this — 60% of supply in the vault only reaches 10% escrow.
	if bound < 47 {
		t.Fatalf("the cap must keep votable/3 reachable to at least 47%% escrow, "+
			"reaches only %d%% — a vault of %d bps of supply is looser than the "+
			"derivation k < (2/3)(1-e) allows", bound, vaultHeld*10000/supply)
	}
	// And the 5% bars, which are slacker and must not be the binding term.
	for _, e := range []int64{0, 20, 40, 47} {
		votable := supply - supply*e/100
		if votable-vaultHeld <= votable*500/10000 {
			t.Fatalf("at escrow %d%% the castable pool %d must still exceed the "+
				"5%% bars (%d); they should never bind before votable/3",
				e, votable-vaultHeld, votable*500/10000)
		}
	}
	// The bound is a real edge, not an open-ended pass: past it the arm does go.
	// Without this a cap of zero would satisfy everything above.
	votable := supply - supply*(bound+1)/100
	if votable-vaultHeld > votable/3 {
		t.Fatalf("escrow %d%% is meant to be past the bound, but votable/3 is "+
			"still reachable (%d vs %d) — the walk above found the wrong edge",
			bound+1, votable-vaultHeld, votable/3)
	}
}

// A court's name cannot write markup onto the wrap page.
//
// Enable derives the wrapped token's name as `"Wrapped " + kourtv2.CourtName(slug)`
// and Render writes that name into an H1. kourtv2's mustCourtName validates LENGTH
// ONLY, 1..100 characters — mustCourtDesc beside it walks the string and refuses
// newlines, the name does not — so by the time it reaches this realm it is free-form
// user text, and gnoweb runs no HTML sanitiser after a realm.
//
// WHAT IS NOT REACHABLE, measured rather than assumed, because the first version of
// this test asserted it and failed: block structure. grc20's validName rejects every
// rune below 0x20, so a newline in a court name aborts Enable inside NewToken with
// "invalid token name (empty, too long, or contains control chars)" and Render is
// never reached at all. Headings, list rows and CommonMark §4.6 HTML blocks each
// need a line of their own, so none of them can get here.
//
// WHAT IS REACHABLE is everything inline. validName's own comment says it "permits
// Unicode letters, digits, punctuation, and spaces — name is purely a display
// field", and that includes < > & [ ] ( ) * _ ` #. So `<img src=x onerror=1>` is a
// legal court name and lands in an H1 as live markup.
//
// THE ASSERTION IS ON THE BACKSLASH, NOT ON THE PAYLOAD. `Contains(out, "<img")`
// matches the ESCAPED `\<img` exactly as well as the raw one, so it passes whether
// the sanitiser ran or not — that mistake cost three wrong versions of an earlier
// render test. markdown.EscapeInline writes '\\' before each byte in its set, so the
// invariant is: every `<` on this page is preceded by a backslash. Nothing else in
// the template can produce one — the other three fields are a symbol constrained to
// [A-Za-z0-9_-], a token path, and an integer.
func TestACourtNameCannotWriteMarkupOntoTheWrapPage(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cw-inject")

	// 33 bytes, so "Wrapped " + this is 41 — inside grc20's MaxNameLen of 64.
	hostile := "<img src=x onerror=1> [f](u) **b**"
	testing.SetRealm(testing.NewUserRealm(alice))
	kourtv2.StartCourt(cross(cur), "wrapinj", hostile)
	testing.SetRealm(testing.NewUserRealm(alice))
	Enable(cross(cur), "wrapinj")

	out := Render("wrapinj")
	for i := 0; i < len(out); i++ {
		if out[i] == '<' && (i == 0 || out[i-1] != '\\') {
			t.Errorf("the wrap page carries an unescaped '<' at byte %d, so a court "+
				"name reaches the reader as markup:\n%s", i, out)
			break
		}
	}

	// Paired with the ordinary name it must NOT mangle: letters and spaces are in no
	// escape set, so an ordinary court still renders as its own heading. Without this
	// arm a Render that emitted nothing at all would satisfy the loop above.
	testing.SetRealm(testing.NewUserRealm(alice))
	kourtv2.StartCourt(cross(cur), "wrapok", "Acme Arbitration")
	testing.SetRealm(testing.NewUserRealm(alice))
	Enable(cross(cur), "wrapok")
	if ok := Render("wrapok"); !strings.Contains(ok, "# Wrapped Acme Arbitration\n") {
		t.Errorf("an ordinary court name no longer renders as its own heading:\n%s", ok)
	}
}

// A court whose name is too long to wrap is told so HERE, by this realm.
//
// mustCourtName allows 100 characters and this realm prepends "Wrapped ", where
// grc20's MaxNameLen is 64 — so a court name of 57 or more can never become a token
// name. Enable already does exactly this arithmetic for the SLUG and says why in its
// own comment: "Caught here with the reason, rather than surfacing as grc20's
// ErrInvalidSymbol from three frames down." The NAME had the same failure mode and no
// guard, so a long-named court aborted inside NewToken behind a message that names
// neither courts nor names nor what to do about it.
//
// It matters more than a nicer string. A court's name cannot be changed after
// StartCourt, so for that court the failure is permanent, and the only thing anyone
// gets is the message.
func TestACourtNameTooLongToWrapIsRefusedHere(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cw-longname")

	long := ""
	for len(long) < 57 {
		long += "n"
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	kourtv2.StartCourt(cross(cur), "wraplong", long)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "too long to wrap", func() {
		Enable(cross(cur), "wraplong")
	})

	// And the boundary it must NOT refuse. 56 is the longest that fits, so this arm
	// is what makes the guard a bound rather than an off-by-one that costs a court
	// its wrapping for no reason.
	fits := ""
	for len(fits) < 56 {
		fits += "y"
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	kourtv2.StartCourt(cross(cur), "wrapfit", fits)
	testing.SetRealm(testing.NewUserRealm(alice))
	Enable(cross(cur), "wrapfit")
	uassert.True(t, Enabled("wrapfit"))
}
