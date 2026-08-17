package govern

import (
	"chain/runtime/unsafe"

	grc20votes "gno.land/p/kourt/grc20votes/v0"
)

// The token's identity, and the clock it quantises history on.
//
// Fixed here rather than configurable: a realm cannot be redeployed at its
// path, so there is nothing to configure and nothing to get wrong later. A
// realm wanting a different name changes these two lines before deploying —
// the ledger takes them as arguments precisely so it does not have to be
// forked to do it.
const (
	tokenName = "Kourt Governance"
	// KOURT, not COURT. kourtv2's slug deny-list reserves "court" precisely so
	// that no user can mint a coin which displays as COURT beside the platform
	// ticker — a wallet keys display on symbol, not package path — and shipping
	// the governance token AS COURT would have had the platform doing the exact
	// thing it forbids its users. The symbol is part of tokenID below, so it is
	// wire identity: free to choose now, unfixable after deploy, because a realm
	// cannot be redeployed at its path.
	//
	// No collision is possible in the other direction either: "kourt" is itself
	// a reserved slug, so no court coin can ever carry this symbol. The scheme
	// reads whole — KOURT is the platform token, a court coin is uppercase(slug)
	// rendered KOURT:SLUG, and the review court is KOURT:META.
	tokenSymbol   = "KOURT"
	tokenDecimals = 6
	tokenID       = "gno.land/r/kourt/govern." + tokenSymbol
)

// epochBlocks is an hour at gno's five-second cadence, and the figure every
// storage measurement in docs/DESIGN.md was taken at.
const epochBlocks = int64(720)

// ledger is this realm's token. Unexported and never handed out: a consumer
// holding a *Ledger can call every mutator on it without passing through the
// authentication above, so publishing it would publish the mint.
//
// See gno-security-guide.md §4 — this is the encapsulation pattern grc20 sets,
// with the `cur.IsCurrent()` check moved from a teller to the entrypoints,
// which is where the caller actually is.
var ledger = grc20votes.NewLedger(tokenName, tokenSymbol, tokenDecimals, epochBlocks)

// minter is the only address that may mint, until the holders vote it away.
// The ledger holds no minter of its own — who may create supply is a policy,
// and policy belongs where the caller is known.
var minter address

func init() {
	ledger.SetID(tokenID)

	// Whoever deploys owns minting.
	//
	// init has no `cur` to ask, and MsgAddPackage sets OriginCaller to the
	// creator — so this is the deployer, and it is the only moment at which it
	// can be read without a caller being able to influence it.
	minter = unsafe.OriginCaller()
}

// Minter is the only address that may mint, until the holders vote it away.
//
// CHECK THIS IMMEDIATELY AFTER DEPLOYING. An empty Minter() means a dead realm
// that cannot be revived: no minter, so no supply; no supply, so no voting
// power; no voting power, so no proposal can pass — including the one that
// would appoint a minter. A realm cannot be redeployed at its path.
//
// MsgAddPackage sets OriginCaller to the creator, so it should not happen on a
// chain. It does happen where there is no deployer at all — a filetest
// importing this realm gets an empty one.
//
// Not defended with a panic in init, which would refuse to load the realm in
// every test harness; nor with claim-on-first-call, which is a race worth more
// than the failure it prevents.
func Minter() address { return minter }

// ---------------------------------------------------------------- reading --

// The GRC20 reads, with the names that standard uses, answering about NOW.
//
// Governance does not read any of these. It asks PastVotes and PastTotalVotes,
// which answer about a sealed epoch — the distinction the whole realm turns on,
// and the reason these are grouped apart from them.

func GetName() string    { return ledger.Name() }
func GetSymbol() string  { return ledger.Symbol() }
func GetDecimals() int   { return ledger.Decimals() }
func TotalSupply() int64 { return ledger.TotalSupply() }

func BalanceOf(owner address) int64            { return ledger.BalanceOf(owner) }
func Allowance(owner, spender address) int64   { return ledger.Allowance(owner, spender) }
func VotesOf(who address) int64                { return ledger.VotesOf(who) }
func DelegateOf(who address) address           { return ledger.DelegateOf(who) }
func PastVotes(who address, at uint32) int64   { return ledger.PastVotes(who, at) }
func PastTotalVotes(at uint32) int64           { return ledger.PastTotal(at) }
func Epoch() uint32                            { return ledger.Epoch() }

// ---------------------------------------------------------------- writing --
//
// Each of these is the same three steps: refuse a stale realm, ask who is
// acting, and hand the ledger an address. The ledger cannot do the first two —
// a /p/ package has no crossing frame to check and no caller to read — and
// this realm should not do the third, which is why the split falls here.

// Transfer moves the caller's own tokens.
func Transfer(cur realm, to address, amount int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	ledger.Transfer(cur.Previous().Address(), to, amount)
}

// Approve lets a spender move some of the caller's balance.
func Approve(cur realm, spender address, amount int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	ledger.Approve(cur.Previous().Address(), spender, amount)
}

// TransferFrom spends an allowance.
func TransferFrom(cur realm, from, to address, amount int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	ledger.TransferFrom(cur.Previous().Address(), from, to, amount)
}

// Mint creates tokens. Only the minter, and only while there is one.
func Mint(cur realm, to address, amount int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	// An empty minter is nobody: the supply has been fixed by vote and there
	// is no address a caller could present that equals it.
	if minter == "" {
		panic("govern: the supply is fixed; minting was given up")
	}
	if cur.Previous().Address() != minter {
		panic("govern: only the minter may mint")
	}
	ledger.Mint(to, amount)
}

// Burn destroys the caller's own tokens.
func Burn(cur realm, amount int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	ledger.Burn(cur.Previous().Address(), amount)
}

// Delegate points the caller's voting power at someone else.
func Delegate(cur realm, to address) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	ledger.Delegate(cur.Previous().Address(), to)
}
