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
const { src, fn, slice } = require("./srcslice");

let fail = 0;
const ok = (n, c, d) => { if (!c) { fail++; console.log("FAIL:", n, d || ""); } else console.log("ok:", n); };

const esc = s => String(s).replace(/[&<>"'`]/g,
  c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;","`":"&#96;"}[c]));
global.esc = esc;
global.META_SLUG = "meta";
// The two money formatters, as the page spells them, so the figures are real.
eval(fn("gnotAmt"));
global.cc = (n, slug) => `${n} CC:${String(slug).toUpperCase()}`;
/* btn is the page's one signing control and is 6000 lines away; the panel only
   needs to hand it a label and an entrypoint, so it is stubbed as the pair it
   passes. The real one is held to its own contract by its own harnesses. */
global.btn = (label, func, args, cls, sub) =>
  `<button data-func="${func}" data-args='${JSON.stringify(args||{})}'>${label}</button>`
  + (sub? `<span class="sub">${sub}</span>` : "");
/* THE RULE SENTENCE LIVES BESIDE franchiseHtml NOW, NOT INSIDE IT, because it is
   said in two places: the Join panel a reader can come back to, and the dialog
   that follows their first burn. Sliced in the same way and in dependency order
   — this harness evaluates one function at a time, so a callee that is not
   pulled in is a ReferenceError at call time rather than at parse time. */
eval(fn("franchiseMetaName"));
eval(fn("franchiseRule"));
const html = eval(fn("franchiseHtml") + "; franchiseHtml");

/* ---- the rule is stated whether or not anyone is connected ---------------- */
const anon = html("covid", null, 5105763090, true, null, "");
/* RE-POINTED OFF "one for one", which this arm used as its proxy for "the rule
   is stated". The phrase went because it misled: a reader asked whether being
   first into a new court — where their GNOT buys the most of that court's coin —
   also earns more META. It does not. The entitlement banks the GNOT SPENT, so
   equal GNOT earns equal entitlement in any court at any time; what varies is
   what it BUYS, since claiming runs it through meta's own curve. "One for one"
   reads as token-for-token and says none of that.
   The property is unchanged — the rule must be stated to a reader with no
   wallet — and it is now proxied on the two clauses that carry the substance,
   the crediting and the price-dependence, rather than on a phrase whose whole
   problem was that it carried neither. */
ok("the rule is stated with no wallet connected",
   /credited again there/.test(anon) && /price on the day/.test(anon),
   anon.slice(0, 120));
ok("...and names the meta court as where it lands", /#\/c\/meta/.test(anon));
// Re-pointed off "one for one with what you burn": the phrase went because it
// reads as token-for-token when the credit is measured in GNOT. What this arm
// is for — that the BURN is named as the thing that earns — is now proxied on
// the clause that says so.
ok("...and says the burn is what earns it",
   /same GNOT credited again there/.test(anon), anon.slice(0, 120));
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
const onMeta = html("meta", null, 0, true, null, "");
ok("on meta's own page the coin is earned, not received for GNOT",
   /not received for GNOT/.test(onMeta) && /<b>earned<\/b>/.test(onMeta));
ok("...and it does not link the reader to the page they are on",
   !/#\/c\/meta/.test(onMeta), onMeta.slice(0, 120));
ok("every court page carries the heading", /The meta franchise/.test(anon) && /The meta franchise/.test(onMeta));

/* ---- the reader's own entitlement ----------------------------------------- */
const mine = html("covid", 554400000, 5105763090, true, null, "");
ok("a pending entitlement is shown as the GNOT it came from",
   /554\.4 GNOT/.test(mine), mine.slice(mine.indexOf("fr-mine"), mine.indexOf("fr-mine") + 140));
/* THE BUTTON IS WHAT SAYS IT IS CLAIMABLE. The line used to say "claimable as
   meta coin at whatever the curve stands at when you claim" and then a control
   labelled "Claim your meta coin" sat under it saying the same thing. The label
   is the shorter of the two and it is the one you can press. */
ok("...and offers it as a labelled control rather than as prose",
   /Claim your meta coin/.test(mine) && !/claimable as/.test(mine));
/* AND A WAY TO TAKE IT. Telling a reader what is owed and offering no control is
   the same silence one step on — the entitlement is claimed by an ordinary
   transaction and there was nowhere on the site to make it. */
ok("...and offers the transaction that takes it",
   /data-func="ClaimMetaFranchise"/.test(mine), mine.slice(mine.indexOf("<button"), 200));
ok("...with no arguments, because the realm reads the caller off the frame",
   /data-args='\{\}'/.test(mine));
/* AND CARRIES NO SECOND SENTENCE UNDER IT. There was a sub-line reading "mints
   what you have accrued; the rest of your holdings are untouched" — true, and
   a third statement of a rule the paragraph two lines above already makes. The
   stubbed btn() renders a sub as <span class="sub">, so its absence is
   measurable rather than a matter of reading the source. */
ok("...with no explanatory sub-line under the button",
   !/class="sub"/.test(mine), mine.slice(mine.indexOf("<button"), mine.indexOf("<button") + 220));
ok("the confirmation names the claim", /ClaimMetaFranchise: "your meta claim"/.test(src));
/* ZERO IS NOT THE SAME AS NOT CONNECTED. A connected wallet with nothing waiting
   gets told how to start; an unconnected one is told nothing about itself,
   because the page does not know anything about it. */
const zero = html("covid", 0, 5105763090, true, null, "");
ok("a connected wallet with nothing waiting is told how to start",
   /nothing waiting here yet/.test(zero) && /burn for any court's coin/.test(zero));
/* NOT OFFERED WHEN THERE IS NOTHING TO CLAIM. A control that signs a no-op is a
   control that spends a fee to do nothing. */
ok("no claim control when nothing is waiting", !/ClaimMetaFranchise/.test(zero), zero);
ok("...nor with no wallet connected", !/ClaimMetaFranchise/.test(anon));
ok("...and an unconnected one is told nothing about itself",
   !/fr-mine/.test(anon), anon);

/* THE REGISTER IS BURN AND RECEIVE, NEVER BUY. The owner's call, held over the
   rendered page by vocab_receive.js: GNOT goes one way to a keyless address and
   coin comes back, so "buy" would carry a seller, a price and a way out at that
   price. This copy said "buying", "purchase" and "buy into" in its first draft
   and the browser check caught all three. */
for (const [what, t] of [["a court page", anon], ["meta's own page", onMeta],
                         ["a wallet with nothing waiting", zero]])
  /* A TAG BECOMES A SPACE, NOT NOTHING. Stripped to "", the heading runs
     straight into the paragraph — "…franchiseBuying this court's coin…" — and
     there is no word boundary left for `\bbuy` to find. Measured: the mutation
     that puts "Buying" back SURVIVED this arm while the browser check caught it,
     which is the arm quietly testing nothing. */
  ok(`${what} never says buy`, !/\bbuy|\bpurchas/i.test(t.replace(/<[^>]*>/g, " ")), t);

/* ---- what you already hold, which is the other half of the question --------
   "How much meta do people have" has an exact answer — the balance — and it was
   missing entirely: the panel showed only what was WAITING. A reader who had
   already claimed saw nothing about the coin they were holding. */
const holds = html("covid", 0, 5105763090, true, 120000, "");
ok("a holder is told what they hold", /you hold/.test(holds) && /120000 CC:META/.test(holds), holds);
ok("...in meta's coin, not the court whose page this is", !/CC:COVID/.test(holds));
ok("a zero balance is not printed as a holding",
   !/you hold/.test(html("covid", 0, 5105763090, true, 0, "")));
ok("...nor is an unread one", !/you hold/.test(zero));
/* HOLDING AND WAITING ARE DIFFERENT THINGS and both can be true at once: coin
   already claimed, plus burn accrued since. */
const both = html("covid", 554400000, 5105763090, true, 120000, "");
ok("holding and waiting are shown together when both are true",
   /you hold/.test(both) && /yours, waiting/.test(both));
ok("...and the claim control is still offered", /ClaimMetaFranchise/.test(both));
/* AND WHATEVER FIGURE THE PANEL DOES PRINT IS META'S, NOT THE COURT'S. It sits
   on covid's page and everything it counts belongs to the meta court — the held
   balance, the entitlement — so a figure carrying the viewed court's symbol
   would be the same confusion in a new place. */
ok("no figure in the panel wears the viewed court's coin", !/CC:COVID/.test(anon), anon);
ok("...and the ones that are shown wear meta's", /CC:META/.test(holds));

/* THE ENTITLEMENT IS NOT QUOTED IN COIN, and that is deliberate rather than
   lazy. ClaimMetaFranchise mints crv.Minted(position, owed) — what it is worth
   depends on where meta's curve stands at the moment of the claim, and the curve
   moves as it mints. Dividing by the current price would overstate it, and the
   realm exposes no quote to read instead. So the figure shown is the one that is
   true — GNOT burned — and the sentence says what turns it into coin. */
ok("the waiting figure is stated in the units it is kept in",
   /of burn/.test(mine) && !/of burn.{0,40}CC:META/.test(mine));
/* AND THE PRICING IS SAID ONCE. It is the rule's job — "how much of that coin
   the credit becomes depends on the meta court's price on the day you claim it"
   — and the waiting line used to say it again in its own words. Two phrasings
   of one fact read as two facts, and a reader goes looking for the difference.
   ASSERTED AS ONCE, NOT MERELY AS PRESENT, because "present" is what let the
   duplicate sit there through three rewordings. */
ok("...and the panel prices the claim exactly once",
   (mine.match(/on the day you claim/g) || []).length === 1
   && !/curve stands at/.test(mine),
   JSON.stringify((mine.match(/on the day you claim|curve stands at/g) || [])));

/* ---- the supply, when it is known ----------------------------------------- */
/* THE SUPPLY IS NOT REPEATED IN THE PANEL. It is the coin supply, and the stat
   strip three inches above already carries it — a panel restating the number
   beside it asks the reader to check whether the two agree. Removed on the
   owner's call: "that's already on the top 3-bar in the middle". */
ok("the panel does not restate the coin supply",
   !/claimed so far/.test(anon) && !/5105763090/.test(anon), anon);
/* AND SAYS NOTHING ABOUT CLAIMING WHEN THERE IS A SUPPLY. The zero sentence is
   the answer to "why does this court look empty"; printed beside a supply of
   five billion it is simply false. */
ok("...nor claims nobody has claimed, when somebody plainly has",
   !/Nobody has claimed/.test(anon), anon);
/* THE ZERO CASE IS KEPT, though, and it is the one that is not a figure. A court
   showing nothing minted, next to courts that have burned thousands, reads as
   broken rather than as unclaimed — which is the report this whole thread came
   from. That sentence answers it; the supply figure never did. */
const none = html("covid", null, 0, true, null);
ok("a supply of zero is said in words, not as a figure",
   /Nobody has claimed any yet/.test(none) && !/claimed so far/.test(none), none);
ok("...and says where it all is instead", /still waiting as an entitlement/.test(none));


/* ---- the link is offered only where it lands ------------------------------
   route_crawl found this the first time the panel shipped: the offline sample
   has no meta court, so "#/c/meta" dead-ended on "No court by that slug" from
   every court page in demo mode. The SENTENCE is true either way and is said
   either way — only the anchor is conditional, which is the same rule the page
   applies to a claim reference. */
const noMeta = html("covid", null, null, false, null, "");
ok("with no meta court to open, the name is not a link", !/<a /.test(noMeta), noMeta);
ok("...but the rule is still stated",
   /credited again there/.test(noMeta) && /meta court/.test(noMeta), noMeta.slice(0, 120));
ok("...and with one, it is", /<a href="#\/c\/meta">meta court<\/a>/.test(anon));

/* ---- and How it works explains it, once, in prose --------------------------
   The panel on a court page states the rule where it is earned. This is the
   place a reader goes when they want the whole shape, and it was the obvious
   omission: the page described the one-way curve — burn GNOT, receive coin —
   and then never mentioned that the same burn earns coin somewhere else too. */
/* COLLAPSED TO ONE LINE FIRST. This is prose in a template literal, wrapped at
   the file's own margin, so a phrase to match against may sit across a newline
   and several spaces of indent — "…cannot be received for\n      GNOT directly".
   Matching the source verbatim tests where the author happened to wrap. */
const about = src.slice(src.indexOf("<h2>The meta court</h2>"),
                        src.indexOf("<h2>Claims, and staking</h2>")).replace(/\s+/g, " ");
ok("How it works has a section for the meta court", about.length > 200, String(about.length));
ok("...saying every burn in every court earns it",
   /Every burn, in every court, also earns you coin/.test(about));
// The about page carries the fullest version, so it is held to the whole
// mechanism rather than to a phrase: the credit is in GNOT, and what it becomes
// is settled at claim time. That pair is exactly what "one for one" failed to
// convey and what a reader had to ask about.
ok("...the credit is measured in GNOT, and the coin is settled at claim time",
   /measured in GNOT, not in coin/.test(about) &&
   /settled when\s+you claim it/.test(about.replace(/\s+/g, " ")), about.slice(0, 160));
ok("...and that nothing else earns it",
   /cannot be received for GNOT directly/.test(about));
/* THE SENTENCE THE WHOLE REPORT TURNED ON. A reader who has seen meta at zero
   beside a court that burned thousands needs this said plainly, or the zero
   reads as the feature being broken. */
ok("...and that a burn does not mint it, so zero supply is owed rather than absent",
   /It is not minted when you burn/.test(about) && /the coin is owed, not absent/.test(about));
ok("...and that claiming is an ordinary transaction that can wait",
   /the entitlement keeps until you make it/.test(about));
/* THE REGISTER HOLDS HERE TOO. vocab_receive reads #/about among its routes, and
   the first draft of this section said "what that BUYS the design" — caught on
   the rendered page, not here, because this file reads the source where an HTML
   comment is still present. */
ok("...without ever saying buy",
   !/\bbuy|\bpurchas/i.test(about.replace(/<!--[\s\S]*?-->/g, " ").replace(/<[^>]*>/g, " ")),
   about.slice(0, 120));

/* ---- and the sample has a meta court to open ------------------------------
   Demo is the DEFAULT mode and the sample had no meta court, so "the meta court"
   was a phrase with no page behind it: the panel had to withhold its own link,
   and meta's own wording — this coin is not received for GNOT, it is earned —
   had nowhere to appear at all. route_crawl caught the link dead-ending; this
   catches the court going away again.
   SMALL BUT NOT EMPTY, on purpose. On the live chain meta reads zero across the
   board because nobody has claimed yet, and a sample that copies that shows the
   reader exactly the screen that confused them in the first place. */
const sample = src.slice(src.indexOf("const DEMO_CHAIN = {"),
                         src.indexOf("/* ===== END GENERATED"));
ok("the sample has a meta court", /\n\s*meta:\{ name:"The Meta Court", tier:\d/.test(sample));
ok("...with some claimed supply, so 'claimed so far' has a case offline",
   /meta:\{[\s\S]{0,220}?supply:[1-9]/.test(sample), (sample.match(/meta:\{[\s\S]{0,200}/)||[""])[0]);
/* AND NO BURN OF ITS OWN, which is the fact the whole feature turns on: you do
   not burn FOR meta, you burn for another court and meta is what that earns. A
   sample that gave meta a burn figure would teach the opposite. */
ok("...and no burn of its own — you do not burn for meta",
   /meta:\{[\s\S]{0,120}?burned:0,/.test(sample), (sample.match(/meta:\{[\s\S]{0,140}/)||[""])[0]);

/* ---- and the positions page says what is waiting --------------------------
   "How much do I have" is asked on #/me, and that page knew about coin HELD and
   nothing about coin OWED — so a reader who had never claimed saw no meta
   anywhere, while being owed the whole of what they had ever burned. */
ok("the positions page reads the franchise", /const \[nowH, pendingFr\] = await Promise\.all\(\[/.test(src));
/* FOR THE ADDRESS BEING VIEWED, not the connected wallet. #/me looks up any
   address you paste, and "what is waiting for them" is the same question asked
   about somebody else — reading CFG.addr there would answer about the wrong
   person and look right. */
ok("...for the address being viewed, not the connected wallet",
   /franchiseOf\(addr\)\.catch/.test(src) && !/franchiseOf\(CFG\.addr\)\.catch\(\)=>null\]\)/.test(src));
ok("...and shows it as its own tile", /waiting in the meta court/.test(src));
/* AND THE STRIP ACTUALLY CARRIES IT. Building the tile and never inserting it
   leaves every assertion above green and the page unchanged — measured: deleting
   `${frStat}` from the strip survived this file until this arm existed. The same
   shape as a tile that exists in a variable nobody renders. */
/* AND A WAY TO TAKE IT, WHERE THE FIGURE IS. The claim control lived only on a
   court page, so this page said "554.4 GNOT waiting" and offered nothing to do
   about it — a reader would have to know that the way to act on a number shown
   here is to go and find some other court's page. */
ok("the positions page offers the claim beside the figure",
   /btn\("Claim your meta coin", "ClaimMetaFranchise", \{\}, "",\s*\n\s*"mints what you have accrued across every court/.test(src));
/* ONLY FOR THE READER'S OWN ADDRESS, and this is the arm that matters. The page
   reads any address you paste. Offering to claim somebody else's entitlement is
   offering a transaction that mints to THEM and is signed by you — it would not
   fail, it would just be a gift the page implied was yours to take. */
ok("...only when it is the reader's own address, and they are connected",
   /pendingFr > 0 && CFG\.addr && addr === CFG\.addr/.test(src));
ok("...and nothing at all when it is not", /: ""\)\s*\n\s*\+ `<\/section>`;/.test(src));

ok("...and the positions strip renders it, not just builds it",
   /\$\{heldStat\}\s*\n\s*\$\{frStat\}/.test(src));
ok("...saying none rather than a bare zero when there is none",
   /pendingFr > 0 \? gnotAmt\(pendingFr\) : "none"/.test(src));
ok("...and the tile is omitted when the read did not land",
   /const frStat = pendingFr == null \? ""/.test(src));

/* ---- the sample can show both halves --------------------------------------
   Holding and waiting are different things and both are true of anyone who has
   claimed once and kept burning since. Without both in the sample, half the
   panel has no case offline. */
ok("the sample reader holds some meta coin", /balances:\{[^}]*meta:[1-9]/.test(src));
ok("...and has some waiting too", /const DEMO_FRANCHISE = \{ \[DEMO_ME\]: [0-9_]+ \};/.test(src));
/* AND IT IS DECLARED AFTER THE ADDRESS IT IS KEYED BY. Written inside the DEMO
   object it sat in DEMO_ME's temporal dead zone — a top-level const initialised
   from one declared thirty lines below — and threw "Cannot access 'DEMO_ME'
   before initialization" on every page load. The SECOND time that shape has bitten
   in this file; the first was REF_SET_MARKS reading SET_MARK. Both were invisible
   to every source harness, because a harness sets those names as globals before
   evaluating the region, and both were caught only by loading the real page. */
ok("...declared after the address it is keyed by, not inside the demo object",
   src.indexOf("const DEMO_ME =") < src.indexOf("const DEMO_FRANCHISE ="),
   `DEMO_ME at ${src.indexOf("const DEMO_ME =")}, map at ${src.indexOf("const DEMO_FRANCHISE =")}`);

/* ---- what was burned to earn meta's coin -----------------------------------
   The realm records nothing: Buy calls reindexBurn beside the mint and
   ClaimMetaFranchise does not, because the GNOT was already burned into
   whichever court the claimant bought. So CourtBurnedGNOT("meta") is zero
   forever, by construction — and the figure is still exactly recoverable,
   because meta sits on the SAME curve as every other court and a position
   implies the GNOT that reached it. */
const burn = eval(slice("const metaBurnFromCurve", "\nasync function").replace(/^const /, "var ") + "; metaBurnFromCurve");
/* PINNED TO A MEASUREMENT, NOT TO THE ARITHMETIC RESTATED. Read off kourt.xyz
   after three accounts claimed: CurvePosition("meta") was 2,007,984,062, and the
   entitlement those three claims consumed was 2,016.0 GNOT. The curve gives
   2,015,999,997 µGNOT — the same number to a rounding remainder of one
   micro-unit, which is what makes this a derivation rather than a guess. */
ok("the curve cost of meta's live position matches what was actually consumed",
   burn(2007984062) === 2015999997, String(burn(2007984062)));
ok("...and it is ceil, so a part-unit of burn is never rounded away",
   burn(1) === 1 && burn(44721) === 1, `${burn(1)} ${burn(44721)}`);
ok("a court at position zero has burned nothing", burn(0) === 0);
ok("...and an unread position gives no figure rather than a wrong one",
   burn(null) === null && burn(undefined) === null);

/* ---- the second acknowledgement, on meta's buy panel only ------------------
   Meta's coin is the one coin on this site nobody needs to burn for: every burn
   on every OTHER court earns it, one for one, and waits to be claimed. A reader
   who arrives at meta's buy panel and burns GNOT has paid for something they
   were already owed for nothing — and the panel said so nowhere, because it is
   the same panel every court gets. The curve is one way, so that mistake cannot
   be undone. */
ok("meta's buy panel carries a second acknowledgement",
   /I understand that receiving \$\{sym\} here is not necessary/.test(src));
// Re-pointed off the old phrasing, which spanned a line break in the source and
// carried "one for one". The property is that the checkbox says WHERE the coin
// comes from instead of merely warning — so it is proxied on the crediting
// clause, which is what now carries that.
ok("...saying where the coin comes from instead",
   /every GNOT `\s*\n\s*\+ `burned on any other court is credited to me again here/.test(src));
/* ONLY THERE. Every other court's coin has to be burned for, so this warning
   would be false on any of them — and a checkbox that is false is worse than no
   checkbox, because it trains the reader to tick without reading. */
ok("...and only on meta, where it is true",
   /const ack2 = slug === META_SLUG\s*\n\s*\? `<label class="ack small">/.test(src));
/* AND IT GATES. Advisory would not do: the panel already carries one tick, so a
   second one that changed nothing would read as the same kind of formality. */
ok("...and it gates the button, rather than merely being said",
   /const acked2 = slug !== META_SLUG \|\| !!buyFormFor\(slug\)\.ack2;/.test(src)
   && /!acked \|\| !acked2/.test(src));
ok("...remembered across a repaint, like the first tick",
   /function rememberBuyAck2\(el\)\{/.test(src)
   && /ev\.target\.id==="buyack2"/.test(src));
ok("...and it starts unticked", /const ack2Attr = form\.ack2\? " checked" : "";/.test(src));
/* AND BOTH BUY PANELS ACTUALLY PRINT IT. There are two — one for a live quote
   and one for the no-quote fallback — and building the label without inserting
   it leaves every assertion above green and the panel unchanged. Measured:
   deleting `${ack2}` from the markup survived this file until this arm existed. */
ok("...and both buy panels render it, not just build it",
   (src.match(/\n        \$\{ack2\}\n/g) || []).length === 2,
   String((src.match(/\n        \$\{ack2\}\n/g) || []).length));

/* ---- the chain says it on meta's own page, and the site does not -----------
   The rule is meta's court DESCRIPTION now, written to the realm with
   SetCourtDesc, and the court page already renders a description in its lead.
   Printing it again here is the site restating a chain fact three inches below
   the chain's own words. Asked for directly: "i thought this was supposed to be
   description of the court on chain, not custom site language". */
const metaOnChain = html("meta", 0, 2007984062, true, null, "the chain's own sentence");
ok("meta's panel does not restate a description the chain carries",
   !/not received for GNOT/.test(metaOnChain), metaOnChain);
ok("...but still shows what only a read can say", /nothing waiting here yet/.test(metaOnChain));
/* AND NOTHING AT ALL WHEN THERE IS NOTHING TO SAY. On meta's own page, with the
   chain carrying the description and no wallet connected, every part of this
   panel is empty — and what shipped was a bordered box with a heading and no
   body, which reads as a section that failed to load. A heading is not content. */
ok("an empty panel is not drawn as an empty box",
   html("meta", null, 2007984062, true, null, "the chain's own sentence") === "",
   JSON.stringify(html("meta", null, 2007984062, true, null, "the chain's own sentence")));
ok("...but it appears the moment there is something to report",
   /yours, waiting/.test(html("meta", 554400000, 2007984062, true, null, "chain")));
/* THE FALLBACK STAYS. A deployment whose moderators never wrote one would
   otherwise say nothing at all about how this coin is got. */
ok("...and says it itself when the chain has none",
   /not received for GNOT/.test(html("meta", 0, 2007984062, true, null, "")));
ok("...treating whitespace as none", /not received for GNOT/.test(html("meta", 0, 1, true, null, "   ")));
/* AND ANY OTHER COURT KEEPS ITS SENTENCE, which is not a duplicate there: it is
   about what burning HERE earns you SOMEWHERE ELSE — not that court's
   description, and on its page in no other form. */
ok("another court keeps the sentence even when it has a description of its own",
   /also earns you the/.test(html("covid", 0, 5105763090, true, null, "covid's own description")));

/* ---- the wiring ------------------------------------------------------------ */
ok("the read is by ADDRESS, not by court — it is earned everywhere",
   /async function franchiseOf\(addr\)\{/.test(src)
   && /one\(`FranchiseOf\(\$\{gstr\(addr\)\}\)`\)/.test(src));
ok("...and the realm read it calls is the one the realm exports",
   /FranchiseOf\(/.test(src));
/* WHERE THE SLOT IS, not merely that it exists. It used to be a section of its
   own between the stat strip and the folders — a rule about what a burn earns
   you elsewhere, printed above the reader had burned anything. It is inside the
   Join panel now, which is both where the burn happens and where a reader
   returns to claim.
   ASSERTED AS "inside #join", because "the call exists somewhere" is what this
   arm used to say and that stayed true through the move. Matching the panel's
   own markup is what makes the arm able to fail. */
const joinSrc = (src.match(/function joinPanel\(slug, s\)\{[\s\S]*?\n\}/) || [""])[0];
ok("the Join panel is where the slot lives", /franchiseSlotHtml\(slug\)/.test(joinSrc),
   joinSrc? "found joinPanel, no slot in it" : "could not slice joinPanel at all");
ok("...and no second copy is left at the top of the court page",
   !/\+ franchiseSlotHtml\(slug\)\n/.test(src));
/* NOT GATED ON isLive(), unlike the fills around it: the rule is true of the
   sample too, and the sample is the default mode — which is where the silence
   would have been loudest, since most readers never leave it. */
ok("...and it is filled in demo mode as well as live",
   /\n  fillFranchise\(slug, chainDesc\);/.test(src));
/* AND IT IS HANDED THE COURT'S OWN DESCRIPTION, which the route has already read
   — so the panel can tell whether the chain has said this itself without a
   second read for a string the page is holding. */
ok("...and handed the description the route already read",
   /async function fillFranchise\(slug, desc\)\{/.test(src)
   && /franchiseHtml\(slug, r\.pending, r\.supply, r\.hasMeta, r\.held, desc\)/.test(src));
/* ---- the follow-up dialog -------------------------------------------------- */
/* THE SAME SENTENCE IN BOTH PLACES, which is the whole reason franchiseRule was
   pulled out of franchiseHtml. Said twice in two hand-written copies, a rule
   this easy to paraphrase drifts — and the two readers who see them are the
   same reader at two moments. */
const frDlg = (src.match(/async function franchiseFollowup\(slug\)\{[\s\S]*?\n\}/) || [""])[0];
ok("the dialog exists at all", !!frDlg);
/* NOT PINNED TO HOW hasMeta IS SPELLED, only to the sentence coming from the
   shared function. The dialog used to take it from a chain read's result and
   now works it out without reading anything — which is a different second
   argument and the same property. */
ok("...and takes its sentence from the same franchiseRule the panel uses",
   /franchiseRule\(slug, /.test(frDlg));
/* AND ASKS THE CHAIN FOR NOTHING TO SAY IT. This is what made the dialog wait
   out the seven-second settle: the sentence needs no read, only the figure
   does. An await in here is that regression coming back. */
ok("...without waiting on a read to do it", !/await franchiseRead\(\)/.test(frDlg));
/* NOT ON META, where a burn earns no franchise at all: accrueFranchise skips it
   because Buy mints there directly. Without this the dialog congratulates a
   reader for earning something they did not. */
ok("...and never fires on meta's own court", /slug === META_SLUG\) return;/.test(frDlg));
/* ONCE, EVER. The panel is the copy that persists; a dialog after every burn is
   a nag. Both exits write the flag, because a native dialog closes on Escape
   and on the backdrop whatever the button says — and a follow-up that came back
   because it was closed the wrong way is exactly the nag being avoided. */
ok("...and is dismissed for good, not per-burn",
   /store\.get\(FRANCHISE_SEEN\)\) return;/.test(frDlg)
   && (frDlg.match(/store\.set\(FRANCHISE_SEEN,"1"\)/g) || []).length >= 2);
/* TWO MOMENTS, AND THEY ARE DIFFERENT ON PURPOSE. Reported as "the metacoin
   popup came up pretty slow after page refresh": the whole dialog used to sit
   below the repaint, seven seconds after the reader pressed the button, because
   it quoted a total that is only true once the chain holds the burn. The three
   reads behind that total measure about 230ms against the live node — the seven
   seconds were the whole delay.
   SO THE SENTENCE OPENS AT THE LANDING and the FIGURE fills after the settle.
   Both halves are asserted, because either one drifting back to the other's
   moment is a regression: the first would be slow again, the second would quote
   a pre-burn total. */
ok("the dialog opens the moment the transaction lands",
   /landed = true;\n[\s\S]{0,400}?if\(func === "Buy"\) franchiseFollowup\(args && args\.slug\);/.test(src));
ok("...and only the figure waits for the repaint",
   /await render\(\); window\.scrollTo\(0, y\);\n[\s\S]{0,400}?if\(func === "Buy"\) franchiseFollowupFigure\(\);/.test(src));
/* THE FIGURE IS THE HALF THAT READS, and it re-checks the dialog is still there
   after the read — a reader who presses Got it while three reads are in flight
   must not be written to. */
const frFig = (src.match(/async function franchiseFollowupFigure\(\)\{[\s\S]*?\n\}/) || [""])[0];
ok("the figure reads the chain and the sentence does not", /await franchiseRead\(\)/.test(frFig));
ok("...and gives up if the dialog was dismissed mid-read",
   (frFig.match(/getElementById\("frwait"\)/g) || []).length >= 2, frFig.slice(0, 200));
/* AND IT NAMES WHERE THE COPY LIVES. This dialog cannot be reopened once
   dismissed, so telling the reader where the rule stays is what makes
   dismissing it safe. */
ok("...and points the reader back at the Join panel",
   /Join this court/.test(frDlg));

ok("the fill decides on the link from whether the court answered",
   /const hasMeta = isLive\(\)\? Number\.isFinite\(supply\) : !!demoCourt\(META_SLUG\);/.test(src));
ok("the fill asks for all three at once — pending, supply, and what is held",
   /CFG\.addr\? franchiseOf\(CFG\.addr\)/.test(src)
   && /CoinSupply\(\$\{gstr\(META_SLUG\)\}\)/.test(src)
   && /CFG\.addr\? balanceOf\(META_SLUG, CFG\.addr\)/.test(src));
ok("...and a failed read leaves the rest of the court page alone",
   /catch\(_\)\{ \/\* an unread franchise leaves the rest of the court page intact/.test(src));

console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
process.exit(fail ? 1 : 0);
