#!/usr/bin/env node
// THE VERDICT SIDE, from the read that fetches it to the pill that prints it.
//
// WHY THIS HARNESS EXISTS. "settled" is the claim's terminal state and says
// nothing about what was DECIDED, so a settled-YES row and a settled-NO row
// rendered identically everywhere — docket pill, map tooltip, selection panel.
// The realm's PROVISIONAL status line writes sideName(); its SETTLED line does
// not. The overlay closes that by asking Verdict() once, where claim rows are
// born, and splicing the side into statusText so every surface inherits it.
//
// Every arm below is paired: what must change is asserted beside the ordinary
// input that must NOT change. The conditional is the load-bearing part — the day
// the realm names the side itself, this must go quiet on its own rather than
// become a second source of truth, so "already names a side => never asked" is
// tested as hard as the splice.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname, '..', 'index.html'), 'utf8');
const { slice, fn } = require("./srcslice");
let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };

// ---- the real code under test, lifted from the page ----
global.CFG = { mode:'live', chainid:'dev' };
global.isLive = ()=> CFG.mode==='live';
eval(slice('function esc(', '\n'));
// `const` inside a direct eval stays in that eval's own scope, invisible to the
// separately-eval'd nameTheSide; `var` lands in module scope. Same rewrite the
// DEMO slices in d3_test.js use, and for the same reason.
eval(slice('const sideName =', '\n').replace('const sideName =', 'var sideName ='));
eval(slice('function phaseClass(', 'function statusPill('));
eval(slice('function statusPill(', 'function docketRow('));
// docketSignal is the caption both the docket and the court's policing rows
// draw. sparkSvg is stubbed: the series branch is about the WORDS here, and the
// drawing has its own harness.
eval("function sparkSvg(){ return '<svg/>'; }");
eval(fn('docketSignal'));
eval(slice('async function nameTheSide(', '/* A deeper docket window'));
// The claim page's own title, which carries the verdict. safeInline is esc, so
// the real function goes in rather than a stub.
eval(slice('function safeInline(', '\n'));
// The slice starts at verdictSentence, not claimTitleHtml: the heading calls it
// for the settled branch, so a slice that began one function later would eval a
// title builder whose verdict arm throws.
/* sideOval's `?` is secHelp now — the same control the section headings use —
   so the real one is loaded rather than stubbed: a stub would let these
   assertions keep passing over a control that had stopped being a button. */
eval(fn('secHelp'));
global.SET_MARK = "\u{13080}";
global.ICN_EYE_OPEN = '<svg class="eye eyeopen"></svg>';   // drawn form; the harness needs it to exist, not to render
eval(fn('setMarkHtml'));
eval(slice('function verdictSentence(', '\nfunction verdictBanner('));
eval(fn('verdictBanner'));   // fn takes the closing brace with it

// ---- stubs: the chain, and the batcher that talks to it ----
let asked = [], verdicts = {};
global.gstr = s => JSON.stringify(String(s));
global.inChunks = async (items, size, fn) => { for(const it of items) await fn(it); };
global.one = async expr => {
  asked.push(expr);
  const id = /,\s*(\d+)\)/.exec(expr)[1];
  if(!(id in verdicts)) throw new Error("panic: claim has no verdict yet");
  return verdicts[id];
};
const SETTLED = "settled — every stake withdraws 1×";
const run = async (rows, v, mode) => {
  asked = []; verdicts = v || {}; CFG.mode = mode || 'live';
  await nameTheSide("covid", rows);
  return rows;
};

(async () => {
  // 1. the splice itself, both sides, and the sentence survives it
  let r = await run([{id:2, statusText:SETTLED}, {id:3, statusText:SETTLED}], {2:1, 3:0});
  ok("a settled claim gains its side", r[0].statusText.startsWith("settled NO"));
  ok("side 0 reads YES, side 1 reads NO", r[1].statusText.startsWith("settled YES"));
  ok("the rest of the status is not truncated", r[0].statusText.endsWith("every stake withdraws 1×"));
  ok("one read per row, not one per surface", asked.length === 2);
  ok("the read is scoped to the court", asked[0] === 'Verdict("covid",2)');

  // 2. THE CONDITIONAL. A status that already names a side is never asked about,
  //    so this layer disappears by itself when the realm starts naming it.
  r = await run([{id:4, statusText:"settled NO — every stake withdraws 1×"}], {4:0});
  ok("a status already naming a side is not asked", asked.length === 0);
  ok("and is left exactly as the realm wrote it",
     r[0].statusText === "settled NO — every stake withdraws 1×");

  // 3. rows with nothing to enrich
  r = await run([{id:5, statusText:"open — staking until block 900"},
                 {id:6, statusText:"provisional verdict NO — reopenable until block 900"},
                 {id:7, statusText:"", failed:true}], {5:0, 6:0, 7:0});
  ok("an unsettled claim is not asked", asked.length === 0);
  ok("a failed read is left blank, not decorated", r[2].statusText === "");

  // 4. a read that cannot answer must leave the text alone, never guess
  r = await run([{id:8, statusText:SETTLED}], {});          // Verdict panics
  ok("a claim whose verdict cannot be read keeps its plain status",
     r[0].statusText === SETTLED);
  r = await run([{id:9, statusText:SETTLED}], {9:2});        // out of range
  ok("an out-of-range side prints no dash", r[0].statusText === SETTLED);

  // 5. demo mode has no chain to ask
  r = await run([{id:10, statusText:SETTLED}], {10:1}, 'demo');
  ok("demo mode asks nothing", asked.length === 0 && r[0].statusText === SETTLED);
  CFG.mode = 'live';

  // 6. THE VISIBLE SURFACE. The pill is what the reader actually looks at; it
  //    used to print phaseClass().short alone and drop the side on the floor.
  const pill = statusPill("settled NO — every stake withdraws 1×");
  ok("the pill prints the side", />settled NO</.test(pill));
  ok("the pill adds nothing when there is no side", />settled</.test(statusPill(SETTLED)));
  /* THE PILL TAKES THE VERDICT'S COLOUR. This arm used to assert `pill good` on a
     settled-NO pill — it was pinning the bug. --good and --yes are the same green
     and .pill.good is drawn with --yes-wash and the YES glow, so a claim that
     decided NO was announced in the palette of YES. Reported as "it's confusing
     that there should be a green dot when the verdict is NO". */
  ok("a settled-NO pill takes the NO palette", /class="pill verdict-no"/.test(pill));
  ok("a settled-YES pill keeps the yes palette",
     /class="pill good"/.test(statusPill("settled YES — every stake withdraws 1×")));
  ok("a settled claim of unknown side claims neither",
     /class="pill decided"/.test(statusPill(SETTLED)));

  // 6b. THE SIDE IS READ FROM THE DECIDING WORD, NOT FROM ANYWHERE IN THE TEXT.
  //     The realm's OPEN status is "open — stake YES or NO; unstake freely until
  //     an answer posts" — it names both sides because it is inviting you to pick
  //     one. A bare /\b(YES|NO)\b/ matched that, and every open claim grew a
  //     verdict it had never been given, in demo mode too, where the sentence is
  //     word-for-word the same. Caught by the map-node arm in map_test.js.
  ok("an open status carries no side",
     phaseClass("open — stake YES or NO; unstake freely until an answer posts").side === "");
  ok("and its pill says only open",
     statusPill("open — stake YES or NO; unstake freely").includes(">open<"));
  ok("a settled status still yields its side",
     phaseClass("settled NO — every stake withdraws 1×").side === "NO");
  ok("a provisional verdict still yields its side",
     phaseClass("provisional verdict YES — reopenable by a new dispute").side === "YES");

  // 7. THE MAP'S SELECTION CARD, which is the pill a reader meets on the map
  //    page. It hand-rolled its own `<span class="pill">` from phaseClass and so
  //    kept dropping the side after the shared builder learned to print it —
  //    a second pill builder is a second place to forget.
  const selCard = slice('function mapSelCard(', '\nfunction ');
  ok("the map's selection card uses the shared pill",
     /statusPill\(c\.statusText\)/.test(selCard));
  ok("and hand-rolls no pill of its own", !/class="pill \$\{/.test(selCard));

  // 7b. AND A DECIDED CLAIM'S CARD DROPS THAT PILL, because its sentence now
  //     carries the verdict — struck when the court ruled NO, with the side in
  //     its oval. The same removal the claim page's heading got: a chip reading
  //     "settled NO" above a struck title wearing (NO) is one fact twice, and
  //     the oval is the better of the two, because it is attached to the
  //     sentence the verdict is about.
  //     ASSERTED ON THE SOURCE HERE, and on the RENDERED card in map_test.js,
  //     which is the harness that evals mapSelCard and its body renderer. This
  //     one has the two title builders in scope and not the card, so it pins the
  //     shape of the branch; that one pins what the branch produces. Neither is
  //     the other's substitute: a conditional written the right way round can
  //     still print the wrong markup, and correct markup can be reached from a
  //     condition that reads the phase instead of the side.
  /* THE CONDITION GREW A SECOND ARM. A pill is dropped for a settled side, as it
     always was, and now also for any claim the map badges — those explain
     themselves in a sentence on the card instead of repeating the mark as a chip
     in the dispute's gold. Both arms are pinned, because dropping the pill for
     everything would pass a check that only looked for the badge arm. */
  ok("the card's pill is conditional on the verdict side and the badge",
     /\+ \(side \|\| marked \? "" : statusPill\(c\.statusText\)\)/.test(selCard));
  ok("...and a badged claim gets words in its place",
     /mapMarkWords\(pc, c\)/.test(selCard) && /const marked = mapBadged\(pc\);/.test(selCard));
  ok("...and the side it reads is a SETTLED side, not any phase's",
     /const side = pc\.short === "settled" \? pc\.side : "";/.test(selCard));
  ok("...and its title goes through the shared sentence builder",
     /<p class="mapsel-t">\$\{verdictSentence\(c\.title, side\)\}<\/p>/.test(selCard));

  // 7c. THE SHARED BUILDER ITSELF, which both surfaces now depend on.
  ok("a NO strikes the sentence and rings the side",
     verdictSentence("It is so.", "NO")
       === '<s>It is so.</s> <span class="sidetag vtag n">NO</span>');
  ok("a YES rings the side and leaves the sentence standing",
     verdictSentence("It is so.", "YES")
       === 'It is so. <span class="sidetag vtag y">YES</span>');
  ok("an unknown side returns the bare sentence, not an empty oval",
     verdictSentence("It is so.", "—") === "It is so."
     && verdictSentence("It is so.", "") === "It is so.");
  ok("the sentence is escaped on the way in",
     !verdictSentence("<b>x</b>", "NO").includes("<b>"));
  ok("the claim page's heading is that builder in an h1, and nothing more",
     claimTitleHtml({phase:"settled", verdict:1, title:"It is so."})
       === `<h1 class="page-h">${verdictSentence("It is so.", "NO")}</h1>`);

  // 8. wired at BOTH sources of claim rows — the free newest-50 render and the
  //    deeper pages, which read ClaimStatus directly and would otherwise differ.
  ok("listClaims names the side before returning",
     /await nameTheSide\(slug, out\);\s*\n\s*return out;/.test(src));
  ok("the deep docket page names it too",
     /await nameTheSide\(slug, out\);[^\n]*\n\s*return out\.sort/.test(src));

  // THE NODE AND THE PILL MUST AGREE, which they did not. The map's node label
  // special-cased only "settled" to show a side and printed the bare phase
  // otherwise, while the pill always appends one — so a provisional claim read
  // "settling" on the map and "settling YES" in the panel beside it, for the
  // same claim, at the same moment.
  //
  // AND THE PHASE WORD IS NOT "settling". A provisional verdict is decided and
  // reopenable — the losing side may already withdraw 1x — so a word that reads
  // as "on its way to YES" overclaims finality, while "leaning" would underclaim
  // it into mere sentiment, which is what this product already calls a lean (the
  // claim page's "instantaneous: 64% YES"). The realm's own word is provisional.
  ok("the provisional phase is not called settling",
     phaseClass("provisional verdict YES - reopenable until block 900").short === "provisional");
  ok("nothing still says settling",
     !/short="settling"/.test(src) && !/short===\"settling\"/.test(src));
  ok("mapDotClass followed the rename, or every provisional dot falls through",
     /if\(short==="provisional"\) return "ed";/.test(src));

  // ONE RUNG EARLIER. "answered" told a reader what happened to the claim and
  // nothing about where it stands — and carried no side at all, because the
  // realm's answered line did not name one and the regex only looked for
  // settled|verdict. Both halves are fixed: the realm names it, and the label
  // says the thing that is actually true — one person put this forward and
  // staked a bond, and it is not the court's finding yet.
  ok("the answered side is now parsed",
     phaseClass("answered NO — staking frozen; disputable until block 90").side === "NO");
  ok("the open status still grows no side",
     phaseClass("open — stake YES or NO; unstake freely until an answer posts").side === "");
  ok("the phase is proposed, not answered",
     phaseClass("answered YES — staking frozen").short === "proposed");
  ok("mapDotClass followed this rename as well",
     /if\(short==="proposed"\) return "o";/.test(src));
  ok("the demo mirror names the side, as the realm does",
     /\(d\.answer===0\|\|d\.answer===1\)\? " "\+sideName\(d\.answer\)/.test(src));
  // AND OMITS IT RATHER THAN PRINTING A DASH. sideName(undefined) is "—", so an
  // unguarded mirror emitted "answered — — staking frozen" for the one demo row
  // in phase "answered" with no answer field — unmatchable by the side regex,
  // and reading as a typo.
  ok("a missing answer omits the side instead of printing a dash",
     /: ""/.test(slice('d.phase==="answered"', 'settles undisputed')));

  // ONE RULE FOR THE NODE LABEL, not a case per phase. Each special case was
  // added the day its phase got a side, so settled kept saying "verdict: YES"
  // on the node while its pill said "settled YES" — the same node/pill split
  // that was fixed for provisional and never carried across. A rule cannot be
  // forgotten for a fourth phase the way a case can.
  ok("the node labels every sided phase the same way",
     /rlabel\(pc\.side\? pc\.short\+": "\+pc\.side : pc\.short,/.test(src));
  ok("no per-phase special case is left to drift",
     !/"verdict: "\+pc\.side/.test(src) && !/pc\.short==="provisional" \?/.test(src));
  // And the node now agrees with the pill, which is the defect itself: both
  // read <phase> then <side>, for every phase that has one.
  ok("node and pill agree on settled",
     phaseClass("settled NO — every stake withdraws 1×").short === "settled" &&
     phaseClass("settled NO — every stake withdraws 1×").side === "NO");

  // ------------------------------------------------- the title carries it too
  /* WHY THIS EXISTS. A settled-NO claim page named its verdict in a pill, a
     chip, a banner and a status line, and the sentence at the top of the page —
     the thing a reader actually looks at — read exactly as it did the day it
     was filed. */
  const T = "Q3 city revenue exceeded the June forecast.";
  const titled = (over) => claimTitleHtml(Object.assign({phase:"settled", title:T}, over));

  /* THE ASYMMETRY IS THE POINT, and it is asserted as a pair. A claim is a
     statement and a NO verdict is the court saying it is not so, which is what
     a strikethrough means. Striking a settled YES would state the opposite of
     the record — so this is not a "closed" marker, and the YES arm below is
     what stops it becoming one. */
  ok("a claim the court answered NO is struck through",
     titled({verdict:1}).includes("<s>" + T + "</s>"));
  ok("...and a claim it upheld is NOT struck",
     titled({verdict:0}).includes(">" + T + " <") && !titled({verdict:0}).includes("<s>"));
  ok("both name the side in the shared oval",
     /<span class="sidetag vtag n">NO<\/span>/.test(titled({verdict:1}))
     && /<span class="sidetag vtag y">YES<\/span>/.test(titled({verdict:0})));
  /* THE OVAL IS OUTSIDE THE STRIKE. The claim was contradicted; the verdict was
     not. A strike drawn through both would cross out the court's own finding. */
  ok("the verdict itself is not struck",
     /<\/s> <span class="sidetag vtag n">/.test(titled({verdict:1})));

  /* VERDICT BEATS ANSWER, the precedence verdictBanner uses. This is the real
     sample record: answered NO, settled YES. Reading the wrong field strikes a
     claim the court upheld, which is the worst output this function has. */
  ok("a claim answered NO but settled YES is not struck",
     !titled({verdict:0, answer:1}).includes("<s>")
     && titled({verdict:0, answer:1}).includes('vtag y">YES<'));
  ok("...and the answer is used only when there is no verdict",
     titled({answer:1}).includes("<s>") && titled({answer:0}).includes('vtag y">YES<'));

  /* NOTHING BEFORE SETTLED. A provisional verdict is reopenable by a new
     dispute and an answer is disputable, so either would strike a sentence that
     can still come back. "closed" and "provClose" ended with no decision at
     all, which is not a NO. Every phase the page can be in is listed, so a new
     one cannot quietly inherit the mark. */
  for(const ph of ["open","answered","provisional","closed","provClose"]){
    const h = claimTitleHtml({phase:ph, title:T, verdict:1, answer:1});
    ok(`a ${ph} claim is neither struck nor badged`,
       !h.includes("<s>") && !h.includes("sidetag"));
  }
  /* DISPUTED IS THE ONE EXCEPTION, and only half of it. The rule above exists
     because a strike says "no longer accurate" about a sentence that can still
     come back — that reasoning is about the STRIKE, and it still holds here: a
     disputed claim is never struck, whichever way it was answered.
     The BADGE is different. Under dispute the answered side is on the record and
     is precisely what the vote is contesting, so hiding it left a bare title at
     the one moment a reader most wants to know what is being argued about. It
     wears the oval followed by a question mark, and the question mark is what
     keeps it from reading as a decision. */
  {
    const dn = claimTitleHtml({phase:"disputed", title:T, verdict:1, answer:1});
    const dy = claimTitleHtml({phase:"disputed", title:T, answer:0});
    ok("a disputed claim is badged with the answered side", dn.includes('vtag n">NO<'));
    ok("...taken from the ANSWER, not a provisional verdict", dy.includes('vtag y">YES<'));
/* The contested mark is a real button now, not a span with a title, so it is
   recognised by the class that IS the control. Pinned as .sq rather than as ">?<"
   because the glyph moved into its own element when the target grew to 24px —
   an assertion keyed to the punctuation would have missed that. */
    /* The claim page's heading is not a link, so this is the one surface that
       gets the real control — the fourth argument opts in. Everywhere else the
       sentence rides a flat mark, because a button inside an anchor is invalid
       and the click never reaches it. */
    ok("...marked as contested, by a control and not a hover",
       dn.includes('class="sq"') && dn.includes("Under dispute") && !dn.includes('class="vqm"'));
    ok("...and still never struck, either way",
       !dn.includes("<s>") && !dy.includes("<s>"));
    ok("...and an unreadable side still prints no mark",
       !claimTitleHtml({phase:"disputed", title:T, answer:null}).includes("sidetag"));
  }
  /* AN UNREADABLE SIDE PRINTS NO MARK rather than sideName's dash, the way
     statusText and the pill beside it already refuse. An oval reading "—" makes
     a missing read look like a decision. */
  ok("a settled claim with no readable side gets a plain title",
     claimTitleHtml({phase:"settled", title:T}) === `<h1 class="page-h">${T}</h1>`);
  ok("...and never an oval with a dash in it",
     !claimTitleHtml({phase:"settled", title:T}).includes("—"));

  /* THE TITLE IS STILL ESCAPED, inside the strike as much as outside it. It is
     attacker-supplied text going into innerHTML, and adding a wrapper around it
     is exactly the kind of edit that drops an esc(). */
  const eviltitled = claimTitleHtml({phase:"settled", verdict:1, title:'<img src=x onerror=1>'});
  ok("a hostile title is escaped inside the strike",
     eviltitled.includes("&lt;img") && !eviltitled.includes("<img"));

  // -------------------------------------------- and the pill below it agrees
  /* WHY. phaseClass fixed this for the docket and the map — "the interface was
     announcing a NO verdict in the colour of YES" — and verdictBanner, the
     claim's OWN page, was left behind: a green pill with a tick reading
     "✓ settled NO · undisputed". --good and --yes are the same green, so a
     settled NO wore the palette of the side that lost it. */
  const banner = (over) => verdictBanner(Object.assign({phase:"settled"}, over));
  /* THE SETTLED PILL IS GONE ENTIRELY, and these three assertions replace five
     that described its colour and its route. It printed the verdict a few pixels
     from a title that already carries the verdict in an oval — and strikes the
     sentence when the answer is NO — so "SETTLED · UNDISPUTED" beside a struck
     title wearing (NO) said one fact three ways. The oval wins because it is
     attached to the sentence the verdict is about.
     PINNED AS EMPTY, not as "no colour". An empty string is the whole contract;
     asserting the absence of a class would still pass for a pill that came back
     wearing none. */
  ok("a settled claim gets no pill — the title's oval carries the verdict",
     banner({verdict:1}) === "" && banner({verdict:0}) === "");
  ok("...including a side that did not read", banner({}) === "");
  /* THE ROUTE WENT WITH IT, deliberately: it was the second half of the phrase
     called unnecessary, and it is now on no surface. Pinned so its loss is a
     decision on the record rather than something to be re-added by reflex. */
  ok("...and the route is not printed anywhere in the pill",
     !/undisputed|by vote/.test(banner({verdict:1, route:"undisputed"})));
  /* ONE CONVENTION STILL, for the two surfaces that DO carry a pill. The docket
     and the map have no title beside their rows, so they keep both the side and
     the colour; this pins them to phaseClass so they cannot drift apart. The
     claim page is no longer one of them. */
  ok("the docket and map pills agree on every side",
     phaseClass("settled YES — x").cls === "good"
     && phaseClass("settled NO — x").cls === "verdict-no"
     && phaseClass("settled — x").cls === "decided");

  /* NO TICK. It asserts a valence a court does not have: a NO verdict is not a
     failure and a YES is not a success, they are answers. */
  ok("no branch of the pill ticks a verdict",
     !["settled","provClose","closed","disputed","provisional","answered","open"]
       .some(ph => verdictBanner({phase:ph, verdict:1, answer:1, provisional:1}).includes("✓")));

  /* THE DOCKET KEEPS ITS SIDE. There is no title beside those rows, so dropping
     the word there would leave a coloured pill as the only clue — and colour
     alone is not a reading. Pinned so the two surfaces are not "unified". */
  ok("the docket pill still names the side",
     statusPill("settled NO — every stake withdraws 1×").includes("NO"));

  /* THE OVAL IS SIZED AGAINST THE VIEWPORT, NOT THE HEADING. .page-h is
     clamp(26px,3.4vw,36px), so the shared rule's .86em would set the side in
     31px type inside a 40px pill — a second heading rather than a mark on the
     first. Pinned because inheriting the shared size is the obvious
     simplification and it is wrong at every width. */
  ok("the title's oval does not inherit the shared em size",
     /\.page-h \.vtag\{font-size:clamp\(/.test(src));
  /* And the strike is drawn in the losing side's hue: a grey rule through a
     title reads as "deleted", and nothing here was deleted.
     EVERY SURFACE THAT STRIKES IN HTML. verdictSentence builds one <s> for the
     claim page's heading, the map's selection card and the related rows, so a
     hue scoped to .page-h alone would leave the others' rule in ink — the one thing this mark
     must not say. The selector is read as a whole rather than by substring: the
     shape being pinned is that the card is IN the rule, and a bare
     /.page-h s/ matched before the card existed. */
  ok("the strike carries the verdict's colour, not ink",
     /\.page-h s,\.mapsel-t s,\.crow \.t s\{[^}]*text-decoration-color:var\(--no\)/.test(src));


  /* ONE NAME FOR ONE STATE. The claim page's pill said "dispute under way" while
     phaseClass — the classifier this file's own header calls the one every
     status surface agrees on — has said "in dispute" all along, and the docket
     rows and map dots have been saying it. A reader moving between them met two
     names for one state.
     Asserted as a RELATIONSHIP, not as the string: pinning the literal would let
     the two drift apart again so long as somebody updated this line too. What
     must hold is that the pill uses the classifier's word. */
  ok("the dispute pill uses the classifier's own word for the state", (()=>{
    const pill = verdictBanner({phase:"disputed"});
    const short = phaseClass("disputed — a sealed vote is deciding").short;
    return short && pill.includes(short);
  })());
  ok("...and does not name it a second way", (()=>{
    return !verdictBanner({phase:"disputed"}).includes("under way");
  })());
  /* The state pills read as states, the way their neighbours do. An event
     phrase here would be the shape that let the two names diverge. */
  ok("...and the neighbouring pills are states too", (()=>{
    return verdictBanner({phase:"answered", answer:0}).includes("answered")
        && verdictBanner({phase:"closed"}).includes("closed")
        && verdictBanner({phase:"open"}).includes("open");
  })());


  /* WHAT IS BEING DISPUTED, on the docket. Reported from the court page: the
     rows say "IN DISPUTE" and should say which side is on the table. It was the
     one status that named none — settled, provisional and answered all do — so a
     reader scanning a court could see which way every claim went except the ones
     still being fought over.
     "YES?" rather than "in dispute YES", which reads as though YES had won it.
     The colour still carries the phase, so the question mark is not doing that
     job alone. */
  ok("a disputed row names the side under dispute", (()=>{
    const p = statusPill("disputed YES — a sealed vote is deciding; principal is never withheld");
    return p.includes(">YES?<") && !p.includes("in dispute");
  })());
  ok("...on either side", (()=>{
    return statusPill("disputed NO — a sealed vote is deciding").includes(">NO?<");
  })());
  ok("...keeping the dispute colour, so the phase is not carried by punctuation", (()=>{
    const p = statusPill("disputed YES — a sealed vote is deciding");
    return p.includes(`class="pill ${phaseClass("disputed YES — x").cls}"`);
  })());
  /* A realm older than the side-naming status line answers without one. Saying
     less is right there; inventing a side would not be. */
  ok("...and falls back to the bare phase when no side is readable", (()=>{
    const p = statusPill("disputed — a sealed vote is deciding; principal is never withheld");
    return p.includes(">in dispute<") && !p.includes("?");
  })());
  /* The side regex is anchored to the words that carry a decision. "open — stake
     YES or NO" is the sentence that made an earlier unanchored version give every
     open claim a side, so adding a fourth word to the anchor is asserted against
     exactly that string. */
  ok("...and no side leaks onto an open claim from its own instructions", (()=>{
    return phaseClass("open — stake YES or NO; unstake freely until an answer posts").side === ""
        && !statusPill("open — stake YES or NO; unstake freely").includes("?");
  })());


  /* WHAT THE FIGURE IS, said beside it. The caption read "YES now" next to a
     title that already carries the answer's oval, so the row said YES? on one
     line and "YES now" on the next about two different things — one the verdict
     under dispute, the other the share of STAKE. Reported on #19.
     And "no trend", not "no trend yet": the yet promises one is coming, and on a
     claim that never moves again none is. */
  ok("the percentage says it is stake, not a verdict", (()=>{
    const t = docketSignal(null, 53.14);
    return t.includes("53.1%") && t.includes("staked YES") && !t.includes("YES now");
  })());
  /* A MISSING SPARKLINE IS NOT NEWS. This asserted the caption SAID "no trend" (and
     did not say "no trend yet"). Both spent half the caption on the absence of a
     decoration — a reader who has never seen the line cannot miss it, and one who has
     can see the row has none by looking at it. The rule is now the stronger one: the
     absence is never narrated, in any wording. */
  ok("...and says nothing at all about the missing line", (()=>{
    const t = docketSignal(null, 53.14);
    return !/trend/i.test(t) && !/no history|not enough/i.test(t);
  })());
  ok("...so both captions read identically, with or without a line", (()=>{
    const withLine = docketSignal([10, 20, 53.14], 53.14);
    const without = docketSignal(null, 53.14);
    // The same words; the only difference is the line in front of them. sparkSvg is
    // stubbed to "<svg/>" at the top of this file, so the strip matches that shape
    // as well as a real one — the assertion is about the WORDS either side of it.
    return withLine.replace(/<svg[\s\S]*?(?:<\/svg>|\/>)/, "") === without;
  })());
  ok("...and nothing at all before anyone stakes", (()=>{
    return docketSignal(null, null).includes("not staked yet");
  })());
  /* THE DOCKET WEARS THE CONTESTED OVAL TOO. Every other surface put a disputed
     claim's answer on its sentence with a mark after it; the docket kept a pill.
     Source-asserted: no harness loads docketRow — they all slice up TO it — so
     this pins that the flag reaches the builder rather than the pixels. */
  ok("the docket row passes the contested flag to the sentence",
     src.includes("${verdictSentence(c.title, dSide, dv.contested)}"));
  ok("...taking both halves from one answer, not re-deriving one",
     src.includes("const dv = rowVerdict(c.statusText);"));

  /* THE SET MARK IS DRAWN, NOT PRINTED — and only the exact codepoint is.
     A governed set is a claim whose title opens with U+13080, and that character
     is what the chain stores: the realm decides the claim is a set heading by
     matching it, so the overlay cannot substitute anything at the source. What
     it CAN do is draw the mark instead of printing it, which is what a reader
     without a hieroglyph font needs — they would otherwise see an empty box.
     THE NEAR-MISS ARM IS THE ONE THAT MATTERS. U+13079 is a different eye and is
     one picture with U+13080 at title size. If the overlay drew the mark for it,
     a claim the chain does NOT consider a set would wear a set's badge — the
     more dangerous direction, because it is the one a reader would believe. It
     has to come through as the raw character, exactly as any other unusual first
     letter would. Confirmed in a browser as well: the near-miss renders as its
     font glyph and the mark as the drawn SVG, visibly different. */
  {
    const M = "\u{13080}", NEAR = "\u{13079}";
    const marked = verdictSentence(M + " Lab leak evidence", "YES");
    ok("the mark is replaced by a drawn eye",
       /class="setmark"/.test(marked) && /<svg/.test(marked));
    ok("...and the codepoint itself is gone from the output", !marked.includes(M));
    ok("...while the name it prefixed survives intact", marked.includes("Lab leak evidence"));
    ok("an unmarked title gets no mark",
       !/class="setmark"/.test(verdictSentence("An ordinary claim", "YES")));
    const near = verdictSentence(NEAR + " A near-miss eye", "YES");
    ok("a near-miss eye is NOT drawn as the mark", !/class="setmark"/.test(near));
    ok("...and comes through as the raw character", near.includes(NEAR));
    // The delimiter is required, or "𓂀Name" and "𓂀 Name" become two spellings.
    ok("the mark without its space is not a prefix",
       !/class="setmark"/.test(verdictSentence(M + "NoSpace", "YES")));
  }

  console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
  process.exit(fail?1:0);
})();
