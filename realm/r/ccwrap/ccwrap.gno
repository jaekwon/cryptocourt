// Package ccwrap makes a court coin tradeable on a DEX without giving the DEX
// any authority inside the court.
//
// THE PROBLEM. gnoswap identifies a token by a registry key and resolves it with
// grc20reg.MustGet, which type-asserts *grc20.Token — a pointer to a concrete
// struct whose ledger the token's own realm holds. A court coin is not that
// type: it is a grc20votes.Ledger, whose write methods take the acting address
// rather than reading it, precisely so that kourtv2 can gate every move on
// spendable(). The two cannot be bridged by wrapping the type, because the
// registry stores the struct pointer and asserts it, so no adapter can satisfy it.
//
// AND THE MISMATCH IS LOAD-BEARING, not incidental. If a court coin WERE a real
// *grc20.Token, then registering it would hand every caller in the world its
// CallerTeller, and `Transfer` would move staked coin with no spendable() check
// at all. The lock would become decorative. So "just make CC a grc20.Token" is
// not a shortcut past this package; it is the one design that breaks the court.
//
// THE SHAPE. This realm mints, per court, a separate 1:1 claim on court coin it
// holds in escrow — a real *grc20.Token, registered in grc20reg, so one realm
// serves every court and no per-court deployment is needed. grc20reg keys on
// rlmPath + "." + token.GetSymbol() (the `slug` argument is validated and
// emitted but does NOT form the key), and gnoswap does no path-format validation
// beyond lexicographic ordering and registry membership, so the key doubles as
// the token path a pool is created against.
//
//	Enable(slug)  — permissionless, once per court. Mints the wrapped token and
//	                registers it. One transaction, by anyone. After it, anyone
//	                can call gnoswap's pool.CreatePool, which is likewise
//	                permissionless apart from a GNS creation fee.
//	Wrap(slug, n) — pulls n CC into escrow, mints n wCC to you.
//	Unwrap(slug, n) — burns n wCC, returns n CC.
//
// WHAT THIS REALM IS TRUSTED WITH: nothing, by kourtv2. It holds only coin users
// hand it, and it moves that coin through the same ApproveCC/TransferFromCC that
// any other holder would use — every guard, including mustSpendable on the owner,
// applies to it unchanged. kourtv2 does not import this package and has no
// knowledge of it. A better wrapper can be written and used without kourtv2
// changing, and a bug in this realm cannot corrupt court state; it can only
// mismanage the escrow of holders who opted in.
//
// WHAT IT COSTS THE HOLDER, stated plainly because it is the whole trade:
// wrapped coin is escrowed at this realm's address, so while wrapped it cannot
// stake on a claim, cannot vote, and earns no conviction. Wrapping is choosing
// liquidity over participation. Unwrapping restores both — and conviction was
// never a property of holding anyway: it accrues on a claim position keyed
// (address, side), which is why selling coin has never carried conviction with it.
//
// THE ONE THING THAT MUST STAY TRUE. The court's supply-denominated safety bars
// count escrowed coin, since wrapping moves coin between addresses and does not
// change TotalSupply. The votable pool DOES shrink. Both bars that could have
// been stranded by that are already floored against the votable pool rather than
// supply — the quorum floor is max(1, min(X̄frozen, votable/3)) and the demotion
// bar is capped at votable/3 — so heavy wrapping cannot make them unreachable.
// Any NEW bar written against TotalSupply must be checked against this.
package ccwrap

import (
	"strings"

	"gno.land/p/demo/tokens/grc20"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
	ufmt "gno.land/p/nt/ufmt/v0"
	"gno.land/r/demo/defi/grc20reg"
	"gno.land/r/kourt/kourtv2"
)

// coinDecimals mirrors kourtv2's, which fixes every court coin's shape. A
// wrapped coin that reported a different scale would price wrong everywhere it
// was quoted, so this is pinned by a test against kourtv2's own reader rather
// than trusted to stay in step.
const coinDecimals = 6

// maxWrappableSlug is 10, and it is grc20's symbol bound minus the prefix.
//
// grc20.MaxSymbolLen is 11. kourtv2 chose maxSlugLen = 11 for exactly that
// reason — upper(slug) is the court coin's symbol and had to fit. The wrapped
// symbol needs one more character for the "w", so it fits only for slugs of 10
// or fewer, and a court whose slug uses the full 11 CANNOT be wrapped.
//
// Refused rather than papered over. The two workarounds both fail on something
// that matters: truncating breaks injectivity, and two slugs colliding on one
// symbol would collide on the registry KEY, so the second court's Enable would
// be refused forever with no way to tell why; and dropping the "w" makes the
// claim indistinguishable from the coin it is a claim on, in the one place — a
// DEX listing — where the difference decides whether it can stake. A narrow,
// visible, announced hole beats either. WrappableSlug reports it before the
// attempt, and the fix is available at court creation: use ten characters.
const maxWrappableSlug = 10

type wrapped struct {
	tok *grc20.Token
	led *grc20.PrivateLedger
	key string // grc20reg's own answer, not a reconstruction
}

// slug -> *wrapped. One entry per court that anyone has enabled.
var wraps = avl.NewTree()

// nextTokenID distinguishes tokens minted by this realm. grc20 folds it into
// Token.ID() as pkgPath + "." + symbol + "." + id, and grc20reg checks that
// ID() is prefixed by the key it computed — so the id is not the identity, the
// symbol is. It exists so two tokens from one realm are not the same object.
var nextTokenID seqid.ID

// Enable creates and registers the wrapped token for a court. Anyone, once.
//
// PERMISSIONLESS ON PURPOSE. There is nothing here to gatekeep: the token this
// mints is a claim on coin that must be deposited before any of it exists, so an
// unwanted Enable creates a token with zero supply and no way to give it one
// except by someone depositing real coin. The court is not consulted because the
// court is not affected.
//
// A SECOND CALL IS REFUSED HERE AND WOULD BE REFUSED BELOW ANYWAY. grc20reg
// panics with "token already registered" when the key exists, and the key is
// derived from the symbol, so a re-Enable cannot overwrite the registered token
// even if this guard were removed. That is worth knowing rather than assuming:
// the guard is a better error message and a cheaper failure, NOT the thing
// standing between a pool and having its token replaced underneath it. If it is
// ever deleted, nothing breaks — which is precisely why the test for it asserts
// the registered pointer is unchanged rather than merely that a panic happened.
//
// Returns the grc20reg key, which is the token path gnoswap wants.
func Enable(cur realm, slug string) string {
	if !cur.IsCurrent() {
		panic("ccwrap: stale realm; call through a crossing function")
	}
	if !kourtv2.Exists(slug) {
		panic("ccwrap: no such court: " + slug)
	}
	if wraps.Has(slug) {
		panic("ccwrap: already enabled: " + slug)
	}
	if len(slug) > maxWrappableSlug {
		// Caught here with the reason, rather than surfacing as grc20's
		// ErrInvalidSymbol from three frames down.
		panic("ccwrap: slug too long to wrap: a wrapped symbol is \"w\" plus " +
			"the court symbol and GRC20 allows 11 characters, so a court can " +
			"be wrapped only if its slug is 10 or fewer")
	}
	// The wrapped name and symbol are derived from the court's own, so a holder
	// reading a pool can tell what it is a claim on. The w- prefix is what says
	// it is the claim and not the coin: the two are not interchangeable, since
	// only the unwrapped one can stake.
	name := "Wrapped " + kourtv2.CourtName(slug)
	symbol := wrappedSymbol(slug)
	tok, led := grc20.NewToken(name, symbol, coinDecimals, nextTokenID.Next(), cur)
	// Registered BEFORE being recorded here, so a rejected registration leaves
	// no local entry claiming a token nothing can resolve. The key is grc20reg's
	// own return value rather than a reconstruction of it — TokenKey predicts the
	// same string and a test asserts they agree, but the stored one is the truth.
	key := grc20reg.Register(cross(cur), tok, slug)
	wraps.Set(slug, &wrapped{tok: tok, led: led, key: key})
	return key
}

// wrappedSymbol is "w" + the court's own symbol, which is its upper-cased slug.
// Injective because kourtv2's slugs are injective and it keeps hyphens: without
// that, "ab-c" and "abc" would produce one symbol and therefore one registry
// key, and the second court could never be enabled.
func wrappedSymbol(slug string) string { return "w" + strings.ToUpper(slug) }

// WrappableSlug reports whether a court can be wrapped at all, so a UI can say
// so before offering the button. False only for slugs of full length; see
// maxWrappableSlug.
func WrappableSlug(slug string) bool { return len(slug) > 0 && len(slug) <= maxWrappableSlug }

// Wrap escrows `amount` court coin and mints you the same amount of wrapped.
//
// Requires an allowance: call kourtv2.ApproveCC(slug, <this realm's address>,
// amount) first. That is the standard two-step, and it is not extra friction in
// context — gnoswap requires an approve before every swap and every mint, so a
// holder heading for a pool is already doing them. The alternative, a privileged
// push from inside kourtv2, would mean kourtv2 importing this realm and trusting
// it; the allowance is what buys this package its complete lack of privilege.
//
// MINT AFTER THE PULL, always. The pull can fail — no allowance, or the owner
// has since committed the coin to a stake or a bond and mustSpendable refuses —
// and a mint before it would hand out an unbacked claim on a failed deposit.
// Ordering it this way makes the 1:1 backing a structural property rather than
// something the tests have to keep watching.
func Wrap(cur realm, slug string, amount int64) {
	if !cur.IsCurrent() {
		panic("ccwrap: stale realm; call through a crossing function")
	}
	if amount <= 0 {
		panic("ccwrap: wrap amount must be positive")
	}
	w := mustWrapped(slug)
	who := cur.Previous().Address()
	kourtv2.TransferFromCC(cross(cur), slug, who, cur.Address(), amount)
	if err := w.led.Mint(who, amount); err != nil {
		panic(err)
	}
}

// Unwrap burns `amount` wrapped and returns the same amount of court coin.
//
// BURN BEFORE THE RELEASE, the mirror of Wrap's order and for the mirror
// reason: releasing first would let a reentrant caller — or simply a bug in a
// future edit here — draw twice against one balance. Burn is also the step that
// can legitimately fail, on a holder who does not have the wrapped coin, and it
// is better that it fail before anything has left the escrow.
func Unwrap(cur realm, slug string, amount int64) {
	if !cur.IsCurrent() {
		panic("ccwrap: stale realm; call through a crossing function")
	}
	if amount <= 0 {
		panic("ccwrap: unwrap amount must be positive")
	}
	w := mustWrapped(slug)
	who := cur.Previous().Address()
	if err := w.led.Burn(who, amount); err != nil {
		panic(err)
	}
	kourtv2.TransferCC(cross(cur), slug, who, amount)
}

// TokenKey is the grc20reg key, which is also the token path gnoswap wants.
//
// Keyed on the SYMBOL, not the slug: grc20reg computes rlmPath + "." +
// token.GetSymbol() and ignores the slug argument for key purposes. Answerable
// before Enable so a caller can see what to expect, and identical to what
// Enable returns — asserted, because a predictor that drifts from the registry
// would send a pool at a path with nothing behind it.
func TokenKey(slug string) string {
	return realmPath + "." + wrappedSymbol(slug)
}

const realmPath = "gno.land/r/kourt/ccwrap"

// Enabled reports whether a court has a wrapped token yet.
func Enabled(slug string) bool { return wraps.Has(slug) }

// WrappedSupply is how much court coin this realm holds in escrow for a court,
// which by construction equals the wrapped token's total supply. Exposed as one
// number read off the wrapped side; the escrow side is kourtv2's BalanceOf on
// this realm's address, and a test asserts they agree.
func WrappedSupply(slug string) int64 { return mustWrapped(slug).tok.TotalSupply() }

func mustWrapped(slug string) *wrapped {
	w := wraps.Get(slug)
	if w == nil {
		panic("ccwrap: not enabled for court " + slug + "; anyone can call Enable")
	}
	return w.(*wrapped)
}

func Render(path string) string {
	if path != "" {
		w := mustWrapped(path)
		return ufmt.Sprintf("# %s\n\n- symbol: %s\n- token path: %s\n- wrapped: %d\n",
			w.tok.GetName(), w.tok.GetSymbol(), TokenKey(path), w.tok.TotalSupply())
	}
	s := "# Wrapped court coins\n\n" +
		"A 1:1 claim on court coin, held here in escrow, in a shape a DEX can " +
		"trade. Wrapped coin cannot stake, vote, or earn conviction.\n\n"
	n := 0
	wraps.Iterate("", "", func(slug string, v any) bool {
		n++
		w := v.(*wrapped)
		s += ufmt.Sprintf("- **%s** (%s) — %d wrapped — `%s`\n",
			slug, w.tok.GetSymbol(), w.tok.TotalSupply(), TokenKey(slug))
		return false
	})
	if n == 0 {
		s += "None enabled yet. Anyone can call Enable(slug) for any court.\n"
	}
	return s
}
