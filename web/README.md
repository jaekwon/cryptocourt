# Kourt web overlay (V2)

A single, self-contained page that reads a deployed `r/kourt/courtv2` realm and
renders it. **The chain carries all the information; this overlay only makes it
prettier.** Every screen here can also be served by the realm's own `Render` (see the
"as the chain serves it →" link on every court and claim), and every button is a normal
gnoweb transaction link with its arguments pre-filled — never a private API. The overlay
is optional, not load-bearing.

## Running it

Open `index.html` in any browser — no build, no dependencies, no server needed.

- **Demo (default):** a faithful offline sample so you can explore every screen and
  state (open · answered · disputed-and-sealed · settled-by-vote · closed-without-decision
  · flagged) without a node. In demo mode the page makes **no network calls**.
- **Live node:** in the left rail, switch **Source → Live node** and enter an RPC
  endpoint (a local `gnodev` is `http://127.0.0.1:26657`) and the gnoweb host used to
  build the transaction links (default `https://gno.land`). The page then reads the real
  realm.

Your choices persist in `localStorage`; nothing leaves the page except the ABCI queries
to the node you name and the transaction links you click.

## How it queries the chain

Two ABCI queries, exactly what gnoweb and `gnokey query` use:

| what | call | example |
|---|---|---|
| a rendered page (lists) | `vm/qrender` | `gno.land/r/kourt/kourtv2:orem/3` |
| a typed read (scalars)  | `vm/qeval`   | `gno.land/r/kourt/kourtv2.CoinPrice("orem")` |

The **court and claim lists come from `Render`** — the realm's own markdown, parsed for
its links — so the directory and docket are always whatever the chain says. The
**scalars** behind the widgets come from `qeval` of the realm's public reads
(`StakePools`, `PoolConviction`, `TrailingOI`/`TrailingYes`, `ClaimStatus`, `QualityTier`,
`FlagState`, `DisputeBondNext`, `SettleDeadline`, `DrawSlices`, `StakeOf`, `ConvictionOf`,
…). Nothing is invented.

## What the screens obey (§7.4 interface contract)

- **Titles render verbatim**, never paraphrased, and are HTML-escaped wherever they
  appear — the integrity argument depends on both.
- **No live tally is ever shown.** While a dispute or flag vote is open, the claim reads
  only "the tally is sealed until the vote closes."
- **A verdict shows its route** — *undisputed* or *by vote*.
- **Principal is never framed as a wager.** It always returns 1×; only the reward
  (conviction) is at stake. There is **no** "backing", "redeem", "cash out", "APR", or
  return-percentage language, and the inflation ceiling is never rendered.
- **The four things** a participant must understand lead every court page; the hidden
  mechanics (floors, bond slices, the step-down schedule) stay hidden.

## The screens

directory · a court · a claim (the **stake panel** with its three ratio series —
instantaneous, trailing-week, and lifetime-conviction — plus the resolution and quality
lanes) · **your positions** · **what needs you** (answers on claims you've staked, flagged
when they run against your side) · **how it works** · and **the same page as the chain
alone serves it**.

## Deploying for testnet

1. Point the deploy at your testnet: open the page, switch **Source → Live node**, set the
   RPC to your node and the gnoweb host to your testnet's web host (both persist).
2. Host `index.html` on any static host (it is fully self-contained), or just share the
   file — it runs from `file://`.
3. The transaction links resolve to `<gnoweb-host>/r/kourt/kourtv2$help&func=…`; the
   realm's functions are crossing (`func F(cur realm, …)`), so gnoweb injects `cur` and the
   links carry only the ordinary arguments. `Buy` needs a GNOT `-send`, which the user
   attaches in the gnoweb help form.
