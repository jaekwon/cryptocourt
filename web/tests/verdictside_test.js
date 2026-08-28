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
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing "+to);
  return src.slice(a, b);
}
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
eval(slice('async function nameTheSide(', '/* A deeper docket window'));

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
     /\+ statusPill\(c\.statusText\)/.test(selCard));
  ok("and hand-rolls no pill of its own", !/class="pill \$\{/.test(selCard));

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

  console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
  process.exit(fail?1:0);
})();
