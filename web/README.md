# Kourt web overlay (V2)

A single, self-contained page that reads a deployed `r/kourt/kourtv2` realm and
renders it. **The chain carries all the information; this overlay only makes it
prettier.** Every screen here can also be served by the realm's own `Render` (see the
"as the chain serves it →" link on every court and claim), and every button is a normal
gnoweb transaction link with its arguments pre-filled — never a private API. The overlay
is optional, not load-bearing.

## Running it

Open `index.html` in any browser — no build, no dependencies, no server needed.

- **Demo (default):** a faithful offline sample so you can explore every screen and
  state (open · answered · disputed-and-sealed · provisional-in-escrow · settled-by-vote ·
  closed-without-decision · closed-never-answered · flagged · counter-flag-window) without a node. In demo mode the page makes **no network calls**.
- **Live node:** in the left rail, switch **Source → Live node** and enter an RPC
  endpoint (a local `gnodev` is `http://127.0.0.1:26657`) and the gnoweb host used to
  build the transaction links (default `https://gno.land`). The page then reads the real
  realm.

Your choices persist in `localStorage`; nothing leaves the page except the ABCI queries
to the node you name and the transaction links you click.

## Court chat (optional)

Each court page can carry a chat panel at its foot. It is **off unless you turn it on**,
and it is the only part of this page that talks to anything other than a gno node — so
it is worth being exact about what it changes:

- **`chat.js` is a second file, and the only one `index.html` ever loads.** Everything
  above stays true: the page opened on its own, with no `chat.js` beside it, renders
  every court and claim exactly as before. Every call into the panel is guarded, and a
  browser check renders a court with the file blocked at the network layer to prove it.
- **Demo mode still makes no network calls.** With no endpoint configured, the panel
  shows a short sample thread rather than hiding, because an empty box would
  misrepresent the feature and guessing an origin would be worse.
- **It is not the chain, and it is not a private API of the chain.** Chat cannot live in
  a realm: it needs a client address, a wall clock and a mutable moderation record, and a
  deterministic VM has none of those — on-chain chat would also be permanent and
  unmoderatable, which is the opposite of what a timeout system is for. So it is an
  off-chain service in this repo (`cmd/kourtchat`), and turning chat on means naming its
  address under **court chat (optional)** in the left rail. Nothing about a court's
  claims, stakes or verdicts passes through it, and the overlay stays optional and not
  load-bearing with or without it.
- **Names are unverified and nobody owns one.** The six characters after each name are
  derived from the sender's connection and rotate daily, so two people typing "alice"
  are visibly different people. It is recognition inside one conversation, never an
  identity to trust across days.

The design, the moderation rules and how to run it are in [CHAT.md](../CHAT.md).

## The wallet (optional)

With the [Adena](https://adena.app) extension installed, **Connect Adena** in the
left rail links your address: "Your positions" and "What needs you" read it
automatically, and — in **live mode** — every action gains a **✍ Sign** button
that signs and broadcasts through the wallet — demo mode never signs, since its
entities don't exist on any chain. Each argument is confirmed before signing, and
`Buy` asks for the ugnot amount (which is burned). The page still works fully
without a wallet: every action remains a gnoweb link and a copyable `gnokey`
command. Note: browser extensions do not run on `file://` pages — to use the
wallet, serve the folder (`python3 -m http.server`) and open it over http.

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

## Sharing: the embed, the card, and the one thing this file cannot do

Polymarket's market pages travel two ways: an `<iframe>` served from a separate
embed host (`?market=…&theme=…`, 400×400, a live number updating inside someone
else's article), and a link preview whose image is a picture of *that* market.
Kourt has equivalents of both, and one of them is honestly different.

**The embed is a route, not a host.** `#/embed/<court>` and `#/embed/<court>/<id>`
render the same data as the full page with the chrome removed. Because it is the
same file, an embed reads the chain in live mode and the sample offline exactly
as every other screen does — there is no second deployment to keep in step, and
nothing about the embed can drift from the page it quotes. `?theme=light|dark`
pins it to the host page's palette (an iframe cannot see the theme around it);
with no `theme` it follows the reader's own. Links inside an embed carry
`?from=embed` and open the top window, the same signal Polymarket gets from
`utm_medium=embed`.

The snippet's default sizes are **measured, not copied**: 400×340 for a claim
and 400×180 for a court. Polymarket's 400×400 is square because their card holds
a price chart; ours holds a sentence and a stake bar, and 400 tall left 120px of
dead space. Every card in the sample was measured at 320px wide — the narrowest
column an article gives a `max-width:100%` iframe — where the tallest claim came
to 325px and the tallest court to 153px. The claim title is clamped to four
lines so the dominant term is bounded rather than open-ended; the worst case is
pinned in `web/tests/browser/embed_layout.js`, so a claim that beats it fails a
gate instead of quietly growing a scrollbar in somebody's article.

**The share card is drawn in the browser, and this is the real difference.** A
link preview is minted by a server: the crawler asks for the URL, the server
renders that market and returns a PNG. This page has no server, and a crawler
never runs its JavaScript — so `#/c/orem/1` and `#/` are the *same document* to
every unfurler. That means:

- The `og:`/`twitter:` tags here are **site-level and truthful**. They describe
  Kourt, not the claim being linked.
- There is **no `og:image`**. A `data:` URI is ignored by every major crawler,
  and a fixed hosted image would show a picture of a claim that is not the one
  being shared. Faking a per-claim preview is the one thing this file must not
  do.
- Instead, **share → Download PNG** draws the actual claim — title, stake split,
  status — onto a 1200×630 canvas, the size every unfurler crops to. The sharer
  attaches it. The picture is of the real claim because it was drawn from the
  real claim.

**What a server would have to do** to get automatic per-claim previews, if one
is ever put in front of this file: answer crawler requests for `/c/<court>/<id>`
(a real path, not a `#` fragment — fragments are never sent to the server) with
the same HTML plus `og:title` set to the claim's verbatim title, `og:description`
to its status line, and `og:image` pointing at a render of that claim. The
drawing code is already here and already the right size; only the fragment→path
routing and the render endpoint would be new.
