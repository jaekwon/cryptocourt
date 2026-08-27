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

  console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
  process.exit(fail?1:0);
})();
