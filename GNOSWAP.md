# Trading court coins on gnoswap

*Read out of `gnolang/gnoswap@c1a9173f` and the installed `$GNOROOT/examples`, not
from memory. File:line citations are to those trees.*

---

## Short answer

**Two transactions, both permissionless, both callable by anyone:**

```
1.  ccwrap.Enable(cross, "<slug>")                → creates + registers wKOURT-<SLUG>
2.  pool.CreatePool(cross, token0, token1, fee, sqrtPriceX96)   → the market exists
```

Then `position.Mint` to add liquidity and `router.*` to swap, as with any pair.
Transaction 1 is free. Transaction 2 costs the GNS pool-creation fee, pulled from
the caller by `TransferFrom`, so the caller must `gns.Approve` the pool first.

Transaction 1 is now implemented and tested (`realm/r/ccwrap/`). Transaction 2 is
gnoswap's own entrypoint and needs nothing from us.

---

## Why the coin cannot be listed directly

gnoswap resolves every token through one function:

```go
// contract/r/gnoswap/common/grc20reg_helper.gno
func GetToken(tokenKey string) *grc20.Token { return grc20reg.MustGet(tokenKey) }
```

`grc20reg.MustGet` **type-asserts `*grc20.Token`** — a pointer to a concrete
struct whose `PrivateLedger` lives in the token's own realm. A court coin is a
`grc20votes.Ledger`, a different type whose write methods take the acting address
instead of reading it:

```go
// realm/p/grc20votes/grc20votes.gno
func (l *Ledger) Transfer(from, to address, amount int64) { l.move(from, to, amount) }
```

That signature is the whole reason `kourtv2` can gate every move on
`spendable()`. No adapter can bridge the gap, because the registry stores the
struct pointer and asserts it — there is nothing to implement.

**And the mismatch is load-bearing, not incidental.** If a court coin *were* a
real `*grc20.Token`, then registering it would hand every caller in the world its
`CallerTeller`, and `Transfer` would move **staked** coin with no `spendable()`
check at all. The lock would become decorative. "Just make CC a `grc20.Token`" is
not a shortcut past the wrapper — it is the one design that breaks the court.

---

## What gnoswap actually gates on

`CreatePool` — `contract/r/gnoswap/pool/v1/manager.gno` — has **no admin check, no
role check, no whitelist**. In order:

| Check | What it is |
|---|---|
| `rlm.IsCurrent()` | not a spoofed realm |
| `assertPoolUnlocked` / `halt.AssertIsNotHaltedPool` | not paused |
| `assertIsSupportedFeeTier(fee)` | fee tier exists |
| `assertIsNotExistsPoolPath` | pool not already created |
| `assertIsNotEqualsTokens` | the two paths differ after wrapping |
| **`common.MustRegistered(token0Path, token1Path)`** | **the only real gate** |
| `gns.TransferFrom(caller → pool, poolCreationFee)` | a fee, if nonzero |

`common.MustRegistered` is `grc20reg.Get(key) != nil`. So **registry membership
is the listing requirement**, and it is self-service: `grc20reg.Register` keys on
`cur.Previous().PkgPath()`, so a realm can register its own tokens and nobody
else's.

Two things checked because they could have blocked the design and did not:

- **Token paths get no format validation.** `poolCreateConfig.update()`
  (`pool/v1/factory_param.gno:60`) validates only the price and lexicographic
  ordering. A dotted registry key is a fine token path.
- **No separator collision.** `fqname.Construct` joins with `.`; gnoswap's
  `GetPoolPath` joins with `:`.

---

## The shape that was built

One wrapper realm, `r/kourt/ccwrap`, serving **every** court:

- `grc20reg` keys on `rlmPath + "." + token.GetSymbol()`, and `grc20.NewToken`
  binds only `origRealm`, so one realm can mint and register many tokens.
- **This is what makes it permissionless at all.** A Gno realm cannot deploy a
  realm, so a one-realm-per-court design would have needed a human with a deploy
  key for every court, forever.

`Enable` / `Wrap` / `Unwrap`. Wrapped coin is escrowed at the realm's address and
the wrapped token is a 1:1 bearer claim on it.

**`kourtv2` gained exactly three entrypoints — `ApproveCC`, `TransferFromCC`,
`AllowanceCC` — and no imports.** It does not know `ccwrap` exists. The wrapper
moves coin the way any other holder would, so every guard applies to it
unchanged, including `mustSpendable` **on the owner**. Consequences worth stating:

- A bug in `ccwrap` cannot corrupt court state. It can only mismanage the escrow
  of holders who opted in.
- A better wrapper can be written and used without `kourtv2` changing.
- `kourtv2` gains no deploy-time dependency on `grc20reg`, which would have made
  the court undeployable on a chain that lacks it.

`Approve` is deliberately **not** gated on `spendable()`. An approve-time check
proves nothing about spend time — the balance moves freely in between — and it
would forbid approving future coin, which is normal. The gate belongs at the
spend, keyed on `from`. So **an allowance can exceed spendable, and approving
neither reserves nor locks.**

---

## What it costs

**The holder.** Wrapped coin sits at the escrow address, so while wrapped it
cannot stake, cannot vote, and earns no conviction. Wrapping is choosing
liquidity over participation. Conviction was never a property of holding anyway —
it accrues on a claim position keyed `(address, side)` — which is why selling coin
has never carried conviction with it, and `transfer_test.gno` pins both halves:
conviction does not travel, voting power does.

**The court.** Wrapping does not change `TotalSupply`, but it **does** shrink the
votable pool. Both bars that could have been stranded by that are already floored
against the votable pool rather than supply — the quorum floor is
`max(1, min(X̄frozen, votable/3))` and the demotion bar is capped at `votable/3`,
both from the v0.31 structural fixes. **Any new bar written against `TotalSupply`
must be checked against this.**

**The pricing consequence already accepted with transferability itself:** six
bars are denominated in % of court supply and were calibrated when the only way
in was a one-way curve burning GNOT at a rising price. A secondary market can
clear below that.

---

## The one hole, kept visible

`grc20.MaxSymbolLen` is **11**. `kourtv2` chose `maxSlugLen = 11` for exactly
that reason — `upper(slug)` is the court coin's symbol and had to fit. The
wrapped symbol is `"w" + symbol`, which needs a twelfth character.

**A court whose slug uses the full 11 characters cannot be wrapped.**
`Enable` refuses it with the reason; `WrappableSlug(slug)` reports it beforehand.

Both workarounds fail on something that matters:

- **Truncating breaks injectivity.** Since the registry keys on the *symbol*, two
  slugs colliding on one symbol collide on one key, and the second court's
  `Enable` would be refused forever with a message about a token it never
  registered.
- **Dropping the `w`** makes the claim indistinguishable from the coin it is a
  claim on, in the one place — a DEX listing — where the difference decides
  whether it can stake.

A narrow, announced, tested hole beats either. The fix is available at court
creation: use ten characters. If `kourtv2` ever drops `maxSlugLen` to 10, the
hole closes and `TestTheWrappableSlugBoundIsRealOnBothSides` will say so, because
it asserts against the constants rather than the numbers.

---

## Corrections to earlier drafts of this analysis

Recorded because both were wrong in a way that would have shipped.

1. **The installed `grc20`/`grc20reg` differ from the checked-out monorepo copy.**
   `NewToken` is `(name, symbol string, decimals int, id seqid.ID, rlm realm)`,
   not `(_ int, rlm realm, name, symbol string, decimals int)`.
2. **`grc20reg.Register` ignores its own `slug` argument for keying** — it keys on
   `token.GetSymbol()`, verifies `Token.ID()` originated from the registering
   realm, and **panics** on a duplicate key. An earlier draft asserted in a code
   comment that `Register` was a bare tree `Set` which would silently replace a
   registered token and orphan every pool holding the old one. That was false.
   `ccwrap.Enable`'s own already-enabled guard is therefore a better error
   message, **not** the thing standing between a pool and having its token
   replaced — and its test asserts the registered pointer is unchanged rather
   than merely that a panic happened.

---

## Not done

- **No gnoswap contracts are staged into the test harness**, so no test here
  creates a real pool or swaps. What is pinned instead is gnoswap's *resolution
  path* — `grc20reg.MustGet(key)` answering with the right symbol and scale, which
  is precisely what `common.MustRegistered` and `GetToken` perform. Vendoring
  gnoswap's `pool`, `position`, `router`, `gns`, `common`, `access`, `halt` and
  `emission` into `gnoroot.py` would let a txtar test go end to end; it is a
  substantial lift and has not been attempted.
- **No liquidity strategy.** Nothing here says who provides the first LP position
  or at what price, and a registered token with no pool is untradeable in
  practice.
- **The GNS pool-creation fee is not funded by anything in this repo.** Whoever
  calls `CreatePool` pays it.
