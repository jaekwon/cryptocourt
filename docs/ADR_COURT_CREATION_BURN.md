# ADR: opening a court can require a minimum GNOT burn, set by the admin

## Context

Opening a court took no payment. `StartCourt` validated the slug, refused the
reserved `meta`, and built the court; the only cost was gas and the per-byte
storage deposit the chain charges for the `Court`, its coin, its governor and
its curve.

That was a decision, not an oversight. MODERATION.md §13.5 item 5 recorded it as
**RESOLVED (v0.8.2): no GNOT fee**, on two arguments:

1. **A fee cannot be sized.** GNOT has no on-chain USD oracle, so any figure
   written into the source is a guess that becomes wrong at some future price,
   and nothing in the realm can notice when it does. The storage deposit is
   protocol-set and reprices itself, so leaving floods to it was strictly better
   than inventing a constant.
2. **It keeps `StartCourt` realm-callable.** Taking payment means reading
   `unsafe.OriginSend()`, and reading it safely means demanding
   `cur.Previous().IsUserCall()` — which a realm cannot satisfy. A mandatory fee
   would therefore have locked every realm out of court creation.

The owner has since asked for a minimum GNOT burn on court creation, settable by
an administrator.

## Decision

Add `courtCreationBurn`, µGNOT, in `realm/r/kourtv2/courtburn.gno`:

* `SetCourtCreationBurn(cur realm, amount int64)` — gated on
  `ensureGlobalDAO().admin`, matching `SetAssociationBondDefault`. The two are
  the same kind of knob (a realm-wide default pricing a stranger's entry) and
  splitting their authority would be a distinction with no meaning. Not
  moderator-settable: a court's moderators govern *their* court, and there is no
  court yet when this price is charged.
* `CourtCreationBurn() int64` — published so a page can quote the figure before a
  user signs a transaction that would otherwise panic on them.
* Charged by `takeCourtCreationBurn(cur)` from `StartCourt` and `StartCourtP`,
  never from `startCourt`, which realm init uses to build the meta court before a
  DAO, an admin or a bank balance exists.
* **Default 0, which is off.**

Argument 1 is answered rather than dismissed: the figure is not a constant. The
admin sets it at the day's price and moves it when the price moves. That is the
oracle the objection said was missing, in the form the objection did not
consider — a human. Argument 2 is preserved by the default: at 0 the burn path
returns *before* the `IsUserCall` check, so an unconfigured realm behaves exactly
as it did, including realm-callability. Both properties are asserted, not
assumed, in `TestCourtCreationBurnShipsOff`.

## The whole payment burns

The first implementation copied `Buy`: burn the price, refund the excess.
`check-nontransferable` refused it, and it was right to. A refund is **GNOT
leaving the realm to a user**, which is precisely the property REGULATIONS.md's
position rests on never happening — "the payment is burned, nothing ever
redeems". `Buy`'s remainder send is the single sanctioned exception, and it
exists because a bonding curve genuinely cannot spend the last ugnot past the
curve's `d`; there is no such arithmetic in a flat fee.

So the refund was deleted rather than argued for, and the semantics improved as a
result: **send at least the minimum, and all of it burns**. That is a true
minimum rather than a price with change, needs no refund path, and never pays a
coin back out. Nobody is overcharged by surprise, because the figure is published
and the page attaches exactly it; a caller who deliberately sends more has
deliberately burned more.

The single remaining `SendCoins` is registered in `check-nontransferable`
alongside a **new rule**: every send in a sink-only file must name
`burnSinkPath`. Without it the registration would be a blank cheque — a later
edit could point that one send at a user address and the count would still read
1. Ablated both ways (swap the destination; add a second send); each fires a
different arm against a control that fires nothing.

## Not the court's own burn

`reindexBurn`/`accrueFranchise` are deliberately not called. The directory ranks
its listed tier on `burnedGNOT` because that figure is *voluntary* and cannot be
faked (§3.2). A mandatory toll every court pays identically adds a constant to
every row: it moves no ranking, says nothing about a court, and would make the
one un-sybil-able signal in the directory slightly less honest. Asserted in
`TestCourtCreationBurnBurnsTheWholePayment`, not left to a comment.

## Alternatives considered

* **A constant in the source.** This is what v0.8.2 rejected and the rejection
  still stands; nothing here reintroduces one. `courtCreationBurnInit` is 0, and
  a test fails if it ever is not.
* **Exact payment, no overpayment.** Would also avoid a refund, but turns a
  fat-fingered send into a refusal and makes the setting a price rather than a
  minimum. Burning the excess is friendlier and matches the word the owner used.
* **Registering the `SendCoins` exemption without a rule.** Cheaper, and it
  would have let a future user-destined send through unnoticed. Rejected.
* **Per-court pricing by moderators.** There is no court to moderate at the
  moment the fee is charged.

## Consequences

* An administrator can price court creation, and turn it off again with 0.
* While priced, `StartCourt` requires a direct user call. A realm that opens
  courts programmatically will break the moment the burn is set — this is
  inherent to taking payment, not incidental, and it is why the default is off.
* `BurnedGNOT()` now includes creation burns as well as curve burns. Per-court
  `CourtBurnedGNOT` does not.
* The figure is visible with every other realm-wide setting at `/admin-params`
  and in `AdminParams()`.

## Harness notes

Four facts about the Gno test harness cost most of the implementation time and
are recorded in the test file so the next person does not rediscover them:

* `testing.SetRealm`'s caller override **does not survive a helper's return**.
  `buy_test.gno`'s `fundAndBuy` works only because it makes its call inside
  itself.
* Nor does it reach a `cross()` made from **inside a nested closure**; a probe
  reading `cur.Previous()` that way panics "frame not found: cannot seek beyond
  origin caller override". An authorized call therefore cannot be wrapped in
  `uassert.AbortsContains`.
* A fixture calling `ensureGlobalDAO()` must **open its own court first**, or it
  panics "no court exists yet".
* A plain in-package panic needs `uassert.PanicsContains`, not `AbortsContains` —
  an *abort* is what a crossing call raises. This is why the negative-amount
  check was lifted into `mustSanePrice`, which needs no caller.
