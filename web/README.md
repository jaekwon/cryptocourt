# CryptoCourt web overlay

A single, self-contained page that reads a deployed `r/cryptocourt/court` realm and
renders the ten wireframe screens over it. **The chain carries all the information;
this overlay only makes it prettier.** Every screen here can also be served by the
realm's own `Render` (see the "as the chain serves it →" link on every court and
claim), and every button is a normal gnoweb transaction link with its arguments
pre-filled — never a private API. The overlay is optional, not load-bearing.

## Running it

Open `index.html` in any browser — no build, no dependencies, no server needed.

- **Demo (default):** a faithful offline sample so you can explore every screen and
  state (open · answered · disputed-and-sealed · resolved-by-vote) without a node.
- **Live node:** in the left rail, switch **Source → Live node** and enter an RPC
  endpoint (a local `gnodev` is `http://127.0.0.1:26657`) and the gnoweb host used to
  build the transaction links (default `https://gno.land`). The page then reads the
  real realm.

Your choices persist in `localStorage`; nothing leaves the page except the ABCI
queries to the node you name and the transaction links you click.

## How it queries the chain

Two ABCI queries, exactly what gnoweb and `gnokey query` use:

| what | call | example |
|---|---|---|
| a rendered page (lists) | `vm/qrender` | `gno.land/r/cryptocourt/court:orem/3` |
| a typed read (scalars)  | `vm/qeval`   | `gno.land/r/cryptocourt/court.CoinPrice("orem")` |

The **court and claim lists come from `Render`** — the realm's own markdown, parsed
for its links — so the directory and docket are always whatever the chain says they
are. The **scalars** behind the widgets (price, backing, open interest, best bid/ask,
your positions) come from `qeval` of the realm's public reads. Nothing is invented.

## What the screens obey

Straight from `docs/COURTS_STRUCTURE.md §10` (the interface contract):

- **Titles render verbatim**, never paraphrased — the integrity argument depends on it.
- **A live dispute tally is never shown.** While a vote is open the claim reads only
  "a dispute is under way — the tally is sealed until the vote closes."
- **A verdict shows its route** — *undisputed* or *by vote (71%)*.
- **Backing sits beside the price** — the number a first-time buyer needs most.
- **Time is wall-clock** ("about 4 days"), block height subordinate.
- **Untrusted text has one home:** a claim body is framed as its author's words and
  its markup is escaped; a title is inline-escaped wherever it appears in a list.
- **The four things** a participant must understand lead every court page; the
  deliberately-hidden mechanics (floors, bond slices, the OI ceiling) stay hidden.

## The ten screens

directory · a court · a claim (with its market and the **order ticket**) · **your
page** · **what needs you** (answers on claims you hold, flagged when they run
against your side) · and **the same page as the chain alone serves it**. The map,
sections, and the in-session vote screen are V2 surfaces the realm does not yet
expose; they appear when it does.
