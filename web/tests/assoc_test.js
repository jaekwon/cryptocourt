// B8 harness: associationSection + resolutionLadder + demo-data ripples.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing "+to);
  return src.slice(a, b);
}
global.document = { addEventListener: ()=>{}, getElementById: ()=>null };
global.CFG = { mode:'demo' };
global.isLive = ()=> CFG.mode==='live';
global.localStorage = { getItem:()=>null, setItem:()=>{}, removeItem:()=>{} };
const NOWm = src.match(/const NOW\s*=\s*([0-9_]+)/); global.NOW = Number(NOWm[1].replace(/_/g,''));
const BSm = src.match(/const BLOCK_SECS\s*=\s*([0-9_]+)/); global.BLOCK_SECS = Number(BSm[1].replace(/_/g,''));

let code = '';
code += slice('function esc(', '\n');
code += slice('function fmtN(', 'function ugnot(');
code += slice('const sideName', '\n');
code += slice('function wall(', 'function pctYes');
code += 'var NOW='+global.NOW+';\n';
// Round 28 split the literal: DEMO_CHAIN (generated) + DEMO_OVERLAY
// (hand-written: desc, nested folders, relations, voteEndsAt), joined by
// mergeDemo. Build the merged object the way the page does.
code += slice('const DEMO_OVERLAY = {', '/* ===== BEGIN GENERATED').replace('const DEMO_OVERLAY = {','var DEMO_OVERLAY = {') + '\n';
code += slice('const DEMO_CHAIN = {', '/* ===== END GENERATED').replace('const DEMO_CHAIN = {','var DEMO_CHAIN = {') + '\n';
code += slice('function mergeDemo(', 'const DEMO = mergeDemo') + '\n';
code += 'var DEMO = mergeDemo(DEMO_CHAIN, DEMO_OVERLAY);\n';
code += slice('function statusText(', '\n/* =');
code += 'function safeInline(x){ return esc(String(x)); }\n';
code += slice('function phaseClass(', 'function docketRow');
code += "var store={get:k=>{try{return localStorage.getItem(k)}catch(_){return null}},set:()=>{},del:()=>{}};\n";
code += "const demoCourt = slug => Object.hasOwn(DEMO.courts, slug)? DEMO.courts[slug] : null;\n";
code += slice('const CURATION_V', '/* ======').replace('const CURATION_V','var CURATION_V');
code += slice('function assocRow(', '/* ======================= local curation');
code += 'var BLOCK_SECS=' + src.match(/const BLOCK_SECS\s*=\s*(\d+)/)[1] + ';\n';
code += slice('const MON=', 'function resolutionLadder(').replace(/^const MON=/m,'var MON=');
code += slice('function resolutionLadder(', 'function resolutionSection');
code += slice('function demoCensus(', 'function courtRecordPanel');
code += slice('function folderCount(', 'function folderMeta');
eval(code);

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };

// ---- data ripples ----
ok("orem has 11 claims", DEMO.courts.orem.claims.length===11);
ok("all 11 claim objects exist", DEMO.courts.orem.claims.every(i=>DEMO.claims["orem/"+i]));
const cen = demoCensus("orem");
ok("census live-now 5→8", cen.live===8);
ok("census sums to 11", cen.undis+cen.vote+cen.nodec+cen.unans+cen.live===11);
const f = DEMO.courts.orem.folders;
ok("folder counts 4/3/3 (+1 nested)", folderCount(f[0])===4 && folderCount(f[1])===3 && folderCount(f[2])===3);
ok("relations well-formed: every endpoint exists", DEMO.relations.orem.every(r=>DEMO.claims["orem/"+r.from] && DEMO.claims["orem/"+r.to]));
ok("one parent max per claim", (()=>{ const p={}; for(const r of DEMO.relations.orem){ if(r.type==="part"){ if(p[r.from]) return false; p[r.from]=1; } } return true; })());

// ---- association section: #9 the parent ----
const demoLookup = i => { const dd=DEMO.claims["orem/"+i]; return dd? {title:dd.title, statusText:statusText(dd)} : null; };
const h9 = associationSection("orem", 9, demoLookup);
ok("#9: section renders", h9.includes("Where this claim sits"));
// The heading must not name ONE of the two axes it renders — COURTS_STRUCTURE
// §5 keeps containment and association separate, and the old head merged them.
ok("#9: heading names neither axis alone", !h9.includes("The argument"));
ok("#9: sample label", h9.includes("sample curation — the chain stores no relations"));
ok("#9: rests on 3, 1 settled", h9.includes("1 of 3 parts settled"));
ok("#9: undecided banner", h9.includes("2 of 3 parts are still undecided — any verdict here is reached without them"));
ok("#9: children rows 3/4/7 as 'one part'", ["/3","/4","/7"].every(x=>h9.includes(`#/c/orem${x}`)) && (h9.match(/one part/g)||[]).length===3);
ok("#9: #6 supports (incoming)", h9.includes(">supports<") && h9.includes("#/c/orem/6"));
ok("#9: fineprint", h9.includes("Curation, not mechanics: relations move no stake, no bond, no bar, no verdict"));
ok("#9: no yes% or sparkline in rows", !h9.includes("YES now") && !h9.includes("spark"));

// ---- #3: part-of line + contradicts (incoming) ----
const h3 = associationSection("orem", 3, demoLookup);
// The parent is a ROW like every other relation, on the containment axis with
// "Rests on" rather than in the association graph under "Related". It was a bare
// paragraph: no chip, and no status pill on the whole it is a part of.
ok("#3: Part of subsection", h3.includes(">Part of<"));
// "the whole" asserted the parent was the top of the tree. Containment is a
// tree and the design runs three levels, so a parent is usually a part too.
ok("#3: parent is a row, chipped by its relation", /assocrow[^]*?#\/c\/orem\/9/.test(h3) && h3.includes(">contains this<"));
ok("#3: chip does not claim to be the top of the tree", !h3.includes(">the whole<"));
ok("#3: parent row carries the whole's status", h3.slice(h3.indexOf(">Part of<")).slice(0,700).includes("pill"));
ok("#3: parent is NOT filed under Related", h3.indexOf(">Part of<") < (h3.includes(">Related<")? h3.indexOf(">Related<") : Infinity));
ok("#3: #11 contradicts", h3.includes(">contradicts<") && h3.includes("#/c/orem/11"));
ok("#3: no rests-on subsection", !h3.includes("Rests on"));

// ---- #5: superseded (incoming supersedes) ----
const h5 = associationSection("orem", 5, demoLookup);
ok("#5: #10 supersedes", h5.includes(">supersedes<") && h5.includes("#/c/orem/10"));

// ---- #10: outgoing supersedes ----
const h10 = associationSection("orem", 10, demoLookup);
ok("#10: superseded by this", h10.includes("superseded by this") && h10.includes("#/c/orem/5"));

// ---- #6: outgoing supports ----
const h6 = associationSection("orem", 6, demoLookup);
ok("#6: supported by this", h6.includes("supported by this") && h6.includes("#/c/orem/9"));

// ---- #11: outgoing contradicts ----
const h11 = associationSection("orem", 11, demoLookup);
ok("#11: contradicted by this", h11.includes("contradicted by this") && h11.includes("#/c/orem/3"));

// ---- relationless + live ----
ok("#1: section omitted", associationSection("orem",1,demoLookup)==="");
ok("#2: section omitted", associationSection("orem",2,demoLookup)==="");
CFG.mode='live';
ok("live: section absent", associationSection("orem",9,demoLookup)==="");
CFG.mode='demo';

// ---- status pills in rows reflect phases ----
// #4's answer was NO and its verdict YES — a dispute that overturned the answer —
// so "settled YES" also pins the precedence: the pill follows the VERDICT.
ok("#9 rows: #4 settled pill, #3 in-dispute pill",
   h9.includes(">settled YES<") && h9.includes(">in dispute<"));

// ---- resolution ladder ----
const d2 = Object.assign({id:2}, DEMO.claims["orem/2"], {answered:true});
const L2 = resolutionLadder(d2, NOW);
ok("ladder #2: derived answered rung labeled", L2.includes("derived: settle deadline − 72h"));
ok("ladder #2: settle deadline rung", L2.includes("settle deadline"));
ok("ladder #2: now rung", L2.includes(">now<") || L2.includes("now <small>chain height</small>") || L2.includes("chain height"));
const d1 = Object.assign({id:1}, DEMO.claims["orem/1"]);
const L1 = resolutionLadder(d1, NOW);
ok("ladder #1 (open): awaiting-answer future rung", L1.includes("awaiting an answer"));
ok("ladder #1: no fabricated heights (only now)", (L1.match(/≈block/g)||[]).length===1);
const d4 = Object.assign({id:4}, DEMO.claims["orem/4"]);
const L4 = resolutionLadder(d4, NOW);
ok("ladder #4 (settled): closing rung, no future promise", L4.includes("settled — every stake withdraws 1×"));
const d3l = Object.assign({id:3}, DEMO.claims["orem/3"], {answered:true});
const L3 = resolutionLadder(d3l, NOW);
ok("ladder #3 (disputed w/ voteEndsAt): vote closes rung", L3.includes("vote closes"));
const d3n = Object.assign({}, d3l); delete d3n.voteEndsAt;
const L3n = resolutionLadder(d3n, NOW);
// NO LONGER "unexposed". DisputeVoteCloses publishes the height, so a missing
// one means the read failed — and the copy has to say which, because "the chain
// does not publish this" and "we could not reach the chain" send a reader to
// different places.
ok("ladder disputed w/o voteEndsAt: the close is reported unread, not unpublished",
   L3n.includes("its close height could not be read")
   && !L3n.includes("unexposed") && !L3n.includes("no close height is published"));

// ---- the dispute rounds, on the timeline where the other events are --------
// They came off the ballot. The chain stamps a round's opening NOWHERE
// (ClaimTimeline, clock.gno:118), so the one thing that must not happen is a
// date appearing beside one — a guess set in the same type as the chain's own
// record is worse than an em-dash.
ok("the live round rides the close row it belongs to", L3.includes("vote closes · round 2"));
ok("...and the failed ones are counted, not listed one per line",
   L3.includes("1 failed round") && !L3.includes("2 failed round"));
// ORDER. Appended after the body it came out below "now" and below "vote
// closes", reading as something still to come — and a failed round is the most
// recent thing that already happened. It is sorted in on a key half a block
// before now, and its date cell is an em-dash, not the sort key rendered.
// The legacy branch renders "now <small>chain height</small>", NOT ">now<" —
// that is the dated branch's markup, and searching for it here returned -1,
// which made the comparison true for the wrong reason.
// The "now" row lost its <small>chain height</small> gloss with every other
// row's — the label already says what it is — so the order is read off the
// label itself. Anchored to the row's own markup so a "now" inside some other
// sentence cannot satisfy it.
ok("...sorted in before now, not appended after the future rows",
   /class="r">now<\/span>/.test(L3)
   && L3.indexOf("failed round") < L3.search(/class="r">now<\/span>/)
   && L3.indexOf("failed round") < L3.indexOf("vote closes"));
ok("...and its sort key never reaches the page as a height",
   /class="l tnum">—<\/span><span class="r">1 failed round/.test(L3)
   && !/≈block 4,799,999|≈block NaN/.test(L3));
ok("...singular at one, plural above it",
   resolutionLadder(Object.assign({}, d3l, {round:3}), NOW).includes("3 failed rounds"));
ok("...and a claim with no failed round says nothing at all",
   !resolutionLadder(Object.assign({}, d3l, {round:0}), NOW).includes("failed round"));
ok("the unexposed-close note names its round too", L3n.includes("round 2 is voting"));
// The em-dash is the assertion. The failed-rounds row must not acquire a height.
{
  const row = L3.split("failed round")[0].split('<div class="line">').pop();
  ok("a round carries an em-dash where every other row carries a height",
     row.includes(">—<") && !/≈block/.test(row));
}

// ---- the same rows on the DATED branch ------------------------------------
// A different code path with its own renderer: the legacy branch above builds
// [h, what, sub] tuples, this one builds objects and sorts them by timestamp.
// Asserting only one of them is how the two drift.
{
  const T0 = 1750000000, tl = {opened:{t:T0-900000,h:1000}, answered:{t:T0-600000,h:2000},
                               now:{t:T0,h:4800000}};
  const D = Object.assign({}, d3l, {round:2, phase:"disputed", voteEndsAt:NOW+70000});
  const L = resolutionLadder(D, NOW, tl);
  ok("dated ladder: the close row names the round", L.includes("vote closes · round 3"));
  // The gloss went with every other row's. What the round COST is still on the
  // page — the notice above the ballot names the failed rounds and the ballot
  // itself quotes the next bond — and the ladder is a ladder of WHEN, not a
  // place to explain the rules of quorum in six point type.
  ok("dated ladder: the failed rounds are one dateless row",
     L.includes("2 failed rounds") && !L.includes("quorum was not met"));
  // The row's t is a SORT KEY (nowT - 0.5), not a time. Glossed, sinceWords
  // renders it as "1 min ago" — a precise, confident lie about rounds that may
  // have run for weeks. THE DATE CELL IS ASSERTED WHOLE: the first version of
  // this banned the words "just now" and "minutes ago", neither of which
  // sinceWords produces, so the ablation that restored the gloss walked past it.
  // No <small> to skip past any more — the label is the whole cell.
  ok("dated ladder: the dateless row's date cell is an em-dash and nothing else",
     /failed rounds<\/div><div class="dt"[^>]*>—<\/div>/.test(L));
  ok("dated ladder: it sorts before now, not after",
     L.indexOf("failed rounds") < L.indexOf(">now<"));
  ok("dated ladder: and it says why it has no date",
     L.includes("publishes no stamp for a dispute round"));
  ok("dated ladder: the ticket carries no heading of its own, the section names it",
     !L.includes("<h3>"));
  // THE DATED BRANCH HAS ITS OWN fut2, and only the legacy one was covered — an
  // ablation that reverted this branch to "no close height is published" passed
  // with every other assertion green. Both branches carry the same claim about
  // the same fact, so both are asserted.
  const Ln = resolutionLadder(Object.assign({}, D, {voteEndsAt:undefined}), NOW, tl);
  ok("dated ladder: a missing close is reported unread, not unpublished",
     Ln.includes("its close height could not be read")
     && !Ln.includes("no close height is published") && !Ln.includes("unexposed"));
  ok("dated ladder: ...and it names the round it is about", Ln.includes("round 3 is voting"));
}

// ---- banned words in all new surfaces ----
ok("no banned words", ![h9,h3,h5,h10,h6,h11,L1,L2,L4].some(x=>/backing|redeem\b|profit|APR|odds|price/i.test(x)));

// relation-chip layout + colour (owner report: "contradicts" overlapped the
// wrapped title from orem/3; the contradiction family must read bright red)
ok("chip cluster is right-aligned in its own column", src.includes(".docket a.crow.assocrow{grid-template-columns:52px minmax(0,1fr) 268px"));
ok("specificity matches .docket a.crow (which sets the docket grid)", !src.includes("\n.crow.assocrow{grid-template-columns"));
ok("both pills ride one .rt cluster", src.includes('<span class="rt"><span class="pill ${/contradict/.test(chip)?"contra":"void"}">'));
ok("contradiction family wears .contra", (()=>{
  const r=assocRow("orem",11,"contradicts",()=>({title:"t",statusText:"open"}));
  const r2=assocRow("orem",11,"contradicted by this",()=>({title:"t",statusText:"open"}));
  const r3=assocRow("orem",4,"one part",()=>({title:"t",statusText:"open"}));
  return /pill contra/.test(r) && /pill contra/.test(r2) && /pill void/.test(r3);
})());
ok("--contra token defined for both themes", (src.match(/--contra:/g)||[]).length===4);
ok("the map's contradicts edge speaks the same colour", src.includes(".medge.bears.no{stroke:var(--contra)"));
ok("narrow screens stack the chip under the title", src.includes(".docket a.crow.assocrow .rt{grid-column:2"));
console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
process.exit(fail?1:0);
