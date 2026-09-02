// The map's chain relations: chainMapRelations + mergeRelations.
//
// WHY THIS IS ITS OWN HARNESS. map_test.js slices mapLayout/mapSvg and verifies
// GEOMETRY — it never touches the fetch, so the map drew curation's relations and
// none of the chain's for as long as associations have existed, and nothing here
// failed. The page's own caption said so out loud ("no relations are recorded on
// chain") in three of its four branches, which is how the gap survived: the copy
// and the code agreed with each other and both were stale.
//
// What is pinned is the two things that can silently halve or double the graph:
// the OUT-HALF-ONLY rule, and the dedup against curation.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname, '..', 'index.html'), 'utf8');
const { slice } = require("./srcslice");

global.CFG = { mode:'live', chainid:'dev' };
global.isLive = ()=> CFG.mode === 'live';
global.unesc = x => x;
global.gstr = s => JSON.stringify(String(s));

// One answer per (read, claim). A missing entry THROWS, so a test that forgets to
// stub a claim finds out rather than reading undefined as "no edges".
let ASSOC = {}, SUP = {}, CALLS = [];
global.one = async expr => {
  CALLS.push(expr);
  const m = /Claim(Associations|Supersedes)\("[^"]*",(\d+)\)/.exec(expr);
  if(!m) throw new Error("unexpected " + expr);
  const id = Number(m[2]);
  const table = m[1] === "Associations" ? ASSOC : SUP;
  if(!(id in table)) throw new Error("no such read");
  return table[id];
};

eval(slice('async function inChunks(', '\n/* --- your positions'));
eval(slice('async function chainMapRelations(', '\nfunction curationFor('));

let fail = 0;
const ok = (n, c) => { if(!c){ fail++; console.log("FAIL:", n); } else console.log("ok:", n); };
const key = r => `${r.from}>${r.to}:${r.type}${r.stance ? ":" + r.stance : ""}`;

(async () => {
  // THE DOUBLING THIS PREVENTS. The realm reports edge 2->11 twice: as `out` on
  // claim 2 and as `in` on claim 11. A map that read both halves would draw the
  // line on top of itself, and the lane allocator would reserve two channels for
  // one relation.
  ASSOC = { 2: "out:11:s;in:", 11: "out:;in:2:s" };
  SUP = { 2: "of:;by:", 11: "of:;by:" };
  let rows = await chainMapRelations("covid", [2, 11]);
  ok("an edge reported on both claims yields ONE row", rows.length === 1);
  ok("and it is the out-half's direction", rows[0] && rows[0].from === 2 && rows[0].to === 11);
  ok("stance s reads as supports", rows[0] && rows[0].stance === "supports");
  ok("rows are tagged as the chain's", rows[0] && rows[0].chain === true);

  ASSOC = { 5: "out:11:c;in:" }; SUP = { 5: "of:;by:" };
  rows = await chainMapRelations("covid", [5]);
  ok("stance c reads as contradicts", rows[0] && rows[0].stance === "contradicts");
  ok("the type is the one curation uses", rows[0] && rows[0].type === "bears");

  // `of:X` is "this claim re-files X" — a row FROM this claim. `by:` is the same
  // edge seen from the other end, and taking it would double every re-filing.
  ASSOC = { 13: "out:;in:", 11: "out:;in:" };
  SUP = { 13: "of:11;by:", 11: "of:1;by:13" };
  rows = await chainMapRelations("covid", [13, 11]);
  const sups = rows.filter(r => r.type === "supersedes").map(key).sort();
  ok("`of` becomes a supersedes row from this claim", sups.includes("13>11:supersedes"));
  ok("`by` does not, so a re-filing is drawn once",
     sups.length === 2 && sups.includes("11>1:supersedes"));

  // A claim whose read fails must not take the rest of the map with it: the
  // realm hides edges on purged and globally redacted claims, so a refusal is an
  // ordinary answer here rather than an outage.
  ASSOC = { 3: "out:4:s;in:" }; SUP = { 3: "of:;by:" }; // 9 stubbed nowhere
  rows = await chainMapRelations("covid", [3, 9]);
  ok("one claim's failed read does not lose the others",
     rows.length === 1 && rows[0].from === 3);

  ASSOC = {}; SUP = {};
  rows = await chainMapRelations("covid", []);
  ok("no claims, no queries", rows.length === 0 && CALLS.length > 0);

  CFG.mode = 'demo';
  rows = await chainMapRelations("covid", [1, 2]);
  ok("demo mode reads no chain", rows.length === 0);
  CFG.mode = 'live';

  // ---- mergeRelations ----
  const chainR = [{from:2, to:11, type:"bears", stance:"supports", chain:true}];
  const curR = [{from:2, to:11, type:"bears", stance:"contradicts"},
                {from:2, to:1, type:"part"}];
  const merged = mergeRelations(chainR, curR);
  ok("a duplicate (from,to,type) is drawn once", merged.length === 2);
  ok("and the chain's version is the one kept",
     merged.some(r => r.from === 2 && r.to === 11 && r.stance === "supports"));
  ok("curation keeps what the chain cannot hold",
     merged.some(r => r.type === "part"));
  ok("merging nothing is not an error", mergeRelations(null, null).length === 0);

  // §7.4 and the token-naming rule, applied to what this change added.
  //
  // WORD-BOUNDED, unlike dispute_test.js's copy of the same list. That one runs
  // against rendered HTML, where an identifier never appears; this runs against
  // SOURCE, and the unbounded pattern flagged `chainMapRelations` on the "apR"
  // inside its own name. An assertion that fires on the function it is guarding
  // teaches the next reader to delete it.
  const added = slice('/* THE SAME EDGES, COURT-WIDE', '\nfunction curationFor(')
    + slice('const chainRelNote =', 'const legendDots');
  ok("no banned economic framing",
     !/\b(backing|redeem|APR|profit|return on)\b/i.test(added));
  ok("the token is never called money", !/\bmoney\b/i.test(added));

  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
