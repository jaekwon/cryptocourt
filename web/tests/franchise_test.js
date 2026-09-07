#!/usr/bin/env node
// The meta franchise: what buying any court's coin earns you in the meta court.
//
// THE DEFECT THIS EXISTS FOR, AND IT WAS A DEFECT OF SILENCE. The realm has done
// this since it was written: every Buy calls accrueFranchise(court, buyer,
// spent), which credits the buyer with the GNOT they burned as an entitlement to
// the META court's coin, one for one. Nothing in the page said so — not on the
// court page, not on meta's own page, nowhere.
//
// SO THE DIRECTORY READ AS A CONTRADICTION. Measured on kourt.xyz: covid had
// burned 13,068,599,975 µGNOT and meta's supply read 0, side by side on the
// front page. It looks like the twist is broken. It is not: the seventeen covid
// holders between them held 13,068,599,975 µGNOT of unclaimed entitlement — the
// same figure to the last unit. Everything had accrued and nothing had been
// claimed, because nothing is minted until the holder asks.
//
// WHICH IS THE PART THAT HAS TO BE SAID OUT LOUD. "Supply 0" beside a live
// entitlement is not a small omission; it is the page stating the opposite of
// what is true. Every assertion here is about the page saying it.
const { src, fn } = require("./srcslice");

let fail = 0;
const ok = (n, c, d) => { if (!c) { fail++; console.log("FAIL:", n, d || ""); } else console.log("ok:", n); };

const esc = s => String(s).replace(/[&<>"'`]/g,
  c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;","`":"&#96;"}[c]));
global.esc = esc;
global.META_SLUG = "meta";
// The two money formatters, as the page spells them, so the figures are real.
eval(fn("gnotAmt"));
global.cc = (n, slug) => `${n} CC:${String(slug).toUpperCase()}`;
const html = eval(fn("franchiseHtml") + "; franchiseHtml");

/* ---- the rule is stated whether or not anyone is connected ---------------- */
const anon = html("covid", null, 5105763090, true);
ok("the rule is stated with no wallet connected", /one for one/.test(anon), anon.slice(0, 90));
ok("...and names the meta court as where it lands", /#\/c\/meta/.test(anon));
ok("...and says the burn is what earns it", /GNOT you burn/.test(anon));
/* THE SENTENCE THAT RESOLVES THE CONTRADICTION. A reader looking at meta's zero
   supply needs to be told that minting is deferred, or the zero reads as "this
   does not work". */
ok("...and says nothing is minted until it is claimed",
   /Nothing is minted at the moment of the burn/.test(anon) && /until the holder claims/.test(anon));
ok("...and says what that makes the supply MEAN",
   /counts the people who came to use it/.test(anon), anon);
/* AND NAMES WHOSE SUPPLY IT MEANS. This read "so this court's supply counts…"
   on every page — and the panel sits on covid's page while the supply it is
   describing is META's, so "this court" named the wrong one everywhere except
   meta's own page, where the two readings coincide. That is why it survived
   being written, and why it was only caught by reading the live page. */
ok("...naming the court whose supply that is, not the one being read",
   /the meta court's supply counts/.test(anon), anon);

/* ---- the meta court's own page says it differently ------------------------ */
const onMeta = html("meta", null, 0, true);
ok("on meta's own page the coin is earned, not bought", /not bought/.test(onMeta) && /<b>earned<\/b>/.test(onMeta));
ok("...and it does not link the reader to the page they are on",
   !/#\/c\/meta/.test(onMeta), onMeta.slice(0, 120));
ok("every court page carries the heading", /The meta franchise/.test(anon) && /The meta franchise/.test(onMeta));

/* ---- the reader's own entitlement ----------------------------------------- */
const mine = html("covid", 554400000, 5105763090, true);
ok("a pending entitlement is shown as the GNOT it came from",
   /554\.4 GNOT/.test(mine), mine.slice(mine.indexOf("fr-mine"), mine.indexOf("fr-mine") + 140));
ok("...and says it is claimable whenever they ask",
   /claimable/.test(mine) && /whenever you ask/.test(mine));
/* ZERO IS NOT THE SAME AS NOT CONNECTED. A connected wallet with nothing waiting
   gets told how to start; an unconnected one is told nothing about itself,
   because the page does not know anything about it. */
const zero = html("covid", 0, 5105763090, true);
ok("a connected wallet with nothing waiting is told how to start",
   /nothing waiting here yet/.test(zero) && /starts accruing/.test(zero));
ok("...and an unconnected one is told nothing about itself",
   !/fr-mine/.test(anon), anon);

/* ---- the supply, when it is known ----------------------------------------- */
ok("the claimed supply is shown when the read landed",
   /claimed so far/.test(anon) && /5105763090 CC:META/.test(anon));
ok("...and omitted when the read did not land",
   !/claimed so far/.test(html("covid", null, null, true)));
/* A ZERO IS NOT PRINTED AS A QUANTITY. "minted so far 0.00" beside a court that
   has burned thirteen thousand GNOT is the sentence a reader disbelieves: it
   reads as a measurement of a broken thing. "Nobody has claimed any yet" is a
   different statement and the true one. */
const none = html("covid", null, 0, true);
ok("a supply of zero is said in words, not as a figure",
   /Nobody has claimed any yet/.test(none) && !/claimed so far/.test(none), none);
ok("...and says where it all is instead", /still waiting as an entitlement/.test(none));
/* AND IT IS META'S SUPPLY, NOT THE COURT'S. The panel sits on covid's page and
   the figure it prints is the meta court's — printing covid's there would be the
   same confusion in a new place. */
ok("the supply printed is the meta court's", /CC:META/.test(anon) && !/CC:COVID/.test(anon));

/* ---- the link is offered only where it lands ------------------------------
   route_crawl found this the first time the panel shipped: the offline sample
   has no meta court, so "#/c/meta" dead-ended on "No court by that slug" from
   every court page in demo mode. The SENTENCE is true either way and is said
   either way — only the anchor is conditional, which is the same rule the page
   applies to a claim reference. */
const noMeta = html("covid", null, null, false);
ok("with no meta court to open, the name is not a link", !/<a /.test(noMeta), noMeta);
ok("...but the rule is still stated", /one for one/.test(noMeta) && /meta court/.test(noMeta));
ok("...and with one, it is", /<a href="#\/c\/meta">meta court<\/a>/.test(anon));

/* ---- the wiring ------------------------------------------------------------ */
ok("the read is by ADDRESS, not by court — it is earned everywhere",
   /async function franchiseOf\(addr\)\{/.test(src)
   && /one\(`FranchiseOf\(\$\{gstr\(addr\)\}\)`\)/.test(src));
ok("...and the realm read it calls is the one the realm exports",
   /FranchiseOf\(/.test(src));
ok("every court page carries the slot", /\+ franchiseSlotHtml\(slug\)/.test(src));
/* NOT GATED ON isLive(), unlike the fills around it: the rule is true of the
   sample too, and the sample is the default mode — which is where the silence
   would have been loudest, since most readers never leave it. */
ok("...and it is filled in demo mode as well as live",
   /\n  fillFranchise\(slug\);/.test(src));
ok("the fill decides on the link from whether the court answered",
   /const hasMeta = isLive\(\)\? Number\.isFinite\(supply\) : !!demoCourt\(META_SLUG\);/.test(src));
ok("the fill asks for the reader's pending and meta's supply together",
   /CFG\.addr\? franchiseOf\(CFG\.addr\)/.test(src) && /CoinSupply\(\$\{gstr\(META_SLUG\)\}\)/.test(src));
ok("...and a failed read leaves the rest of the court page alone",
   /catch\(_\)\{ \/\* an unread franchise leaves the rest of the court page intact/.test(src));

console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
process.exit(fail ? 1 : 0);
